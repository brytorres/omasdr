#!/usr/bin/python3
"""OmaSDR daemon: a GNU Radio receiver behind a JSON-lines Unix socket.

One resident process owns the SDR device and a single flowgraph. Clients (the
Omarchy shell plugin, or anything else) connect to $XDG_RUNTIME_DIR/omasdr/
control.sock, send one JSON object per line, and receive one JSON object per
line back. The contract is docs/protocol.md; keep the two in step.

The daemon reuses GNU Radio for everything: gr-osmosdr opens the device,
gnuradio.analog demodulates, gnuradio.audio plays. Nothing here does DSP.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path

PROTOCOL_VERSION = 1
PLUGIN_ID = "com.omasdr.radio"


def _version() -> str:
    """The version of the checkout this daemon was launched from. Read once,
    at import, so a running daemon keeps reporting the build it is actually
    executing after a plugin update rewrites the file. The UI compares the
    two and offers a restart."""
    try:
        manifest = Path(__file__).resolve().parent.parent / "manifest.json"
        return str(json.loads(manifest.read_text())["version"])
    except (OSError, ValueError, KeyError, TypeError):
        return "unknown"


VERSION = _version()

# OMASDR_RUNTIME_DIR lets a check run a scratch daemon without moving
# XDG_RUNTIME_DIR, which PipeWire's ALSA plugin also needs to find its server.
RUNTIME_DIR = Path(os.environ.get("OMASDR_RUNTIME_DIR") or (Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "omasdr"))
SOCKET_PATH = RUNTIME_DIR / "control.sock"
FFT_SOCKET_PATH = RUNTIME_DIR / "fft.sock"
PID_PATH = RUNTIME_DIR / "daemon.pid"
LOG_PATH = RUNTIME_DIR / "daemon.log"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "omasdr"
SETTINGS_PATH = CONFIG_DIR / "settings.json"
PRESETS_PATH = CONFIG_DIR / "presets.json"
GQRX_BOOKMARKS = Path.home() / ".config" / "gqrx" / "bookmarks.csv"
GQRX_BANDPLAN = Path.home() / ".config" / "gqrx" / "bandplan.csv"

# Spectrum frames (docs/protocol.md, FFT socket): 1024 log-power bins over
# the whole sampled band, 15 a second, quantised to a byte each and sent as
# a JSON array of ints: dB = value * FFT_DB_STEP + FFT_DB_MIN.
FFT_SIZE = 1024
FFT_FPS = 15
FFT_DB_MIN = -128.0
FFT_DB_STEP = 0.5
LEVEL_HZ = 4            # signal-level messages per second on the control socket

IDLE_TIMEOUT_S = 10 * 60

# Demod catalogue. `step` is the default scroll-to-step in hertz (AGENTS.md:
# step size follows demod); `bw` is the channel bandwidth the flowgraph
# filters to before demodulation. Order is the order the UI lists them.
DEMODS = [
    {"id": "wfm", "label": "WFM", "step": 100_000, "bw": 200_000, "audio_rate": 48_000},
    {"id": "wfm_stereo", "label": "WFM stereo", "step": 100_000, "bw": 200_000, "audio_rate": 48_000},
    {"id": "nfm", "label": "NFM", "step": 12_500, "bw": 12_500, "audio_rate": 48_000},
    {"id": "am", "label": "AM", "step": 10_000, "bw": 10_000, "audio_rate": 48_000},
    {"id": "usb", "label": "USB", "step": 1_000, "bw": 3_000, "audio_rate": 48_000},
    {"id": "lsb", "label": "LSB", "step": 1_000, "bw": 3_000, "audio_rate": 48_000},
    {"id": "cw", "label": "CW", "step": 100, "bw": 500, "audio_rate": 48_000},
    {"id": "raw", "label": "RAW", "step": 1_000, "bw": 0, "audio_rate": 48_000},
]
DEMOD_IDS = [d["id"] for d in DEMODS]

# Offset tuning: the hardware is tuned this far above the wanted channel and
# the channel filter shifts it back, keeping the dongle's DC spike and
# centre-frequency noise out of the passband (gqrx does the same, 362 kHz).
TUNE_OFFSET_HZ = 300_000

SETTINGS_SCHEMA = 2
DEFAULT_SETTINGS = {
    "schema": SETTINGS_SCHEMA,
    "frequency": 104_100_000,
    "demod": "wfm",
    "gain": 25.4,            # "auto" or a number in dB; R82x tuner AGC pumps, so fixed by default
    "ppm": 0,
    "sample_rate": 2_400_000,
    "squelch": -150.0,       # dB; effectively open
    "volume": 0.5,
    "keep_running": False,
    "device": "",            # osmosdr device string; "" means first found
    "step_override": 0,      # 0 means follow demod
    "record_dir": str(Path.home() / "Audio" / "OmaSDR"),
}


def log(*parts):
    line = time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts)
    print(line, file=sys.stderr, flush=True)


# --------------------------------------------------------------------- devices

@dataclass
class DeviceInfo:
    index: int
    name: str
    serial: str
    args: str            # osmosdr device string, e.g. "rtl=0"
    usb_path: str = ""   # /dev/bus/usb/BBB/DDD
    status: str = "free"  # free | ours | busy | missing
    held_by: str = ""     # process name when busy


def enumerate_devices() -> list[DeviceInfo]:
    """RTL-SDR dongles by USB id. Other backends arrive with multi-device work."""
    devices: list[DeviceInfo] = []
    lsusb = shutil.which("lsusb")
    if not lsusb:
        return devices
    try:
        out = subprocess.run([lsusb], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return devices
    index = 0
    for line in out.splitlines():
        m = re.match(r"Bus (\d+) Device (\d+): ID ([0-9a-f]{4}):([0-9a-f]{4}) (.*)", line)
        if not m:
            continue
        bus, dev, vid, pid, desc = m.groups()
        if (vid, pid) not in {("0bda", "2838"), ("0bda", "2832")}:
            continue
        info = DeviceInfo(index=index, name=desc.strip(), serial="", args=f"rtl={index}",
                          usb_path=f"/dev/bus/usb/{bus}/{dev}")
        info.serial, product = usb_strings(bus, dev)
        if product:
            info.name = product
        devices.append(info)
        index += 1
    return devices


def usb_strings(bus: str, dev: str) -> tuple[str, str]:
    """Serial and product from sysfs, without touching the device."""
    base = Path("/sys/bus/usb/devices")
    for entry in base.iterdir():
        try:
            if (entry / "busnum").read_text().strip() != str(int(bus)):
                continue
            if (entry / "devnum").read_text().strip() != str(int(dev)):
                continue
            serial = (entry / "serial").read_text().strip() if (entry / "serial").exists() else ""
            product = (entry / "product").read_text().strip() if (entry / "product").exists() else ""
            manufacturer = (entry / "manufacturer").read_text().strip() if (entry / "manufacturer").exists() else ""
            return serial, " ".join(p for p in (manufacturer, product) if p)
        except (OSError, ValueError):
            continue
    return "", ""


def holder_of(usb_path: str) -> str:
    """Name of the process holding the USB node open, or "" when free.
    fuser prints PIDs on stdout and everything else on stderr."""
    fuser = shutil.which("fuser")
    if not fuser or not usb_path:
        return ""
    try:
        r = subprocess.run([fuser, usb_path], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    for pid in r.stdout.split():
        if not pid.isdigit() or int(pid) == os.getpid():
            continue
        try:
            return Path(f"/proc/{pid}/comm").read_text().strip() or pid
        except OSError:
            return pid
    return ""


# ------------------------------------------------------------------- flowgraph

class FftTap:
    """Holds the newest spectrum frame and the in-channel signal level.
    Built as a GNU Radio sync block once gnuradio is imported (see make)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.seq = 0
        self.bins = b""
        self.level_db = -150.0
        self.channel = (FFT_SIZE // 2, 4)   # centre bin, half-width in bins

    def make(self):
        import numpy as np
        from gnuradio import gr as _gr
        tap = self

        class _Block(_gr.sync_block):
            def __init__(self):
                _gr.sync_block.__init__(self, "omasdr_fft_tap", in_sig=[(np.float32, FFT_SIZE)], out_sig=None)

            def work(self, input_items, output_items):
                frame = input_items[0][-1]
                q = np.clip((frame - FFT_DB_MIN) / FFT_DB_STEP, 0, 255).astype(np.uint8)
                c, hw = tap.channel
                lo, hi = max(0, c - hw), min(FFT_SIZE, c + hw + 1)
                level = float(10 * np.log10(np.mean(10 ** (frame[lo:hi] / 10)) + 1e-30)) if hi > lo else -150.0
                with tap.cond:
                    tap.bins = q.tobytes()
                    tap.level_db = level
                    tap.seq += 1
                    tap.cond.notify_all()
                return len(input_items[0])

        return _Block()

    def wait_frame(self, last_seq: int, timeout: float) -> int:
        with self.cond:
            if self.seq == last_seq:
                self.cond.wait(timeout)
            return self.seq


class Receiver:
    """The one flowgraph. Built lazily; rebuilt when device or rate change."""

    def __init__(self):
        self.tb = None
        self.src = None
        self.demod_id = None
        self.running = False
        self.error = ""
        self.gain_range: list[float] = []
        self._volume = None
        self._squelch = None
        self._audio_rate = 48_000
        self.offset = 0
        self._wav = None
        self.recording = ""        # path of the file being written, or ""
        self.recording_started = 0.0
        self.fft = FftTap()
        self.rate = 0
        self.bw = 0

    def _import(self):
        global gr, analog, audio, filter_, blocks, osmosdr, logpwrfft
        from gnuradio import gr, analog, audio, blocks
        from gnuradio import filter as filter_
        from gnuradio.fft import logpwrfft
        import osmosdr  # noqa: F401

    def start(self, settings: dict, device_args: str):
        self.stop()
        self.error = ""
        try:
            self._import()
            self._build(settings, device_args)
            self.tb.start()
            self.running = True
        except Exception as exc:  # any GNU Radio construction error is user-facing
            self.error = short_error(exc)
            self.tb = None
            self.src = None
            self.running = False
            raise

    def record(self, path: str) -> bool:
        """Start writing a WAV at `path`; empty path stops. Returns success."""
        if self._wav is None:
            return False
        if self.recording:
            self._wav.close()
            self.recording = ""
        if path:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            if not self._wav.open(path):
                return False
            self.recording = path
            self.recording_started = time.time()
        return True

    def stop(self):
        if self.recording:
            self.record("")
        if self.tb is not None:
            try:
                self.tb.stop()
                self.tb.wait()
            except Exception:
                pass
        self.tb = None
        self.src = None
        self._blocks = []
        self.running = False

    def _build(self, s: dict, device_args: str):
        demod = next(d for d in DEMODS if d["id"] == s["demod"])
        self.demod_id = demod["id"]
        rate = int(s["sample_rate"])
        audio_rate = demod["audio_rate"]
        self._audio_rate = audio_rate

        tb = gr.top_block("omasdr")
        src = osmosdr.source(args=f"numchan=1 {device_args}")
        src.set_sample_rate(rate)
        self.offset = min(TUNE_OFFSET_HZ, rate // 4)
        src.set_center_freq(int(s["frequency"]) + self.offset, 0)
        src.set_freq_corr(int(s["ppm"]), 0)
        self._apply_gain(src, s["gain"])
        self.gain_range = gain_steps(src.get_gain_range())

        # Channel: decimate the wideband stream down to a rate the demod likes.
        if demod["id"] in ("wfm", "wfm_stereo"):
            quad = 240_000
        elif demod["id"] in ("nfm", "am"):
            quad = 48_000
        else:
            quad = 48_000
        decim = max(1, rate // quad)
        chan_rate = rate // decim
        bw = demod["bw"] or quad
        taps = filter_.firdes.low_pass(1.0, rate, bw / 2, bw / 4)
        # The wanted channel sits at -offset in the sampled band; translate it to 0.
        chan = filter_.freq_xlating_fir_filter_ccf(decim, taps, -self.offset, rate)
        # Integer decimation rarely lands exactly on the demod rate (2.048 MS/s
        # gives 256 kHz, not 240 kHz); an arbitrary resampler makes it exact so
        # every demod sees the rate it was built for and audio comes out at
        # the sink's rate with no pitch shift.
        resampler = None
        if chan_rate != quad:
            resampler = filter_.pfb.arb_resampler_ccf(quad / chan_rate)
            chan_rate = quad

        squelch = analog.simple_squelch_cc(float(s["squelch"]), 0.001)
        self._squelch = squelch

        if demod["id"] == "wfm":
            dm = analog.wfm_rcv(quad_rate=chan_rate, audio_decimation=max(1, chan_rate // audio_rate))
            audio_in = dm
            resamp = None
        elif demod["id"] == "wfm_stereo":
            dm = analog.wfm_rcv_pll(demod_rate=chan_rate, audio_decimation=max(1, chan_rate // audio_rate), deemph_tau=75e-6)
            audio_in = dm
            resamp = None
        elif demod["id"] == "nfm":
            dm = analog.nbfm_rx(audio_rate=audio_rate, quad_rate=chan_rate, tau=75e-6, max_dev=5e3)
            audio_in = dm
            resamp = None
        elif demod["id"] == "am":
            dm = analog.am_demod_cf(channel_rate=chan_rate, audio_decim=max(1, chan_rate // audio_rate), audio_pass=5000, audio_stop=5500)
            audio_in = dm
            resamp = None
        elif demod["id"] in ("usb", "lsb", "cw"):
            # Weaver-free SSB: shift the wanted sideband to baseband and take
            # the real part. Good enough for listening; refined later.
            offset = 1500 if demod["id"] != "cw" else 700
            if demod["id"] == "lsb":
                offset = -offset
            shift = analog.sig_source_c(chan_rate, analog.GR_COS_WAVE, -offset, 1.0)
            mixer = blocks.multiply_cc()
            to_real = blocks.complex_to_real()
            agc = analog.agc2_ff(1e-1, 1e-2, 0.3, 1.0)
            tb.connect(squelch, (mixer, 0))
            tb.connect(shift, (mixer, 1))
            tb.connect(mixer, to_real, agc)
            dm = None
            audio_in = agc
            resamp = None
        else:  # raw: magnitude of the channel, useful as a signal presence check
            dm = blocks.complex_to_mag()
            audio_in = dm
            resamp = None

        # Two sink inputs make the ALSA device open in stereo; mono demods
        # feed the same signal to both. One volume block per channel so the
        # PLL demod's L and R stay independent.
        vol_l = blocks.multiply_const_ff(float(s["volume"]))
        vol_r = blocks.multiply_const_ff(float(s["volume"]))
        self._volume = (vol_l, vol_r)
        sink = audio.sink(audio_rate, "pipewire", True)

        if resampler is not None:
            tb.connect(src, chan, resampler, squelch)
        else:
            tb.connect(src, chan, squelch)
        if dm is not None:
            tb.connect(squelch, dm)
        if demod["id"] == "wfm_stereo":
            tb.connect((dm, 0), vol_l)
            tb.connect((dm, 1), vol_r)
        else:
            tb.connect(audio_in, vol_l)
            tb.connect(audio_in, vol_r)
        tb.connect(vol_l, (sink, 0))
        tb.connect(vol_r, (sink, 1))
        # Recording tap: the sink must exist at build time, so it is created
        # on a scratch file and closed at once; record() reopens it on the
        # real path. A closed wavfile_sink drops what it receives.
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        scratch = RUNTIME_DIR / "scratch.wav"
        wav = blocks.wavfile_sink(str(scratch), 2, audio_rate, blocks.FORMAT_WAV, blocks.FORMAT_PCM_16, False)
        wav.close()
        try:
            scratch.unlink()
        except OSError:
            pass
        tb.connect(vol_l, (wav, 0))
        tb.connect(vol_r, (wav, 1))
        self._wav = wav

        # Spectrum tap on the whole sampled band, DC in the middle. The
        # tuned channel sits at -offset; the tap averages power over its
        # bandwidth for the level meter.
        pwr = logpwrfft.logpwrfft_c(rate, FFT_SIZE, 1.0, FFT_FPS, 0.5, True, shift=True)
        self.rate, self.bw = rate, bw
        centre_bin = int(round(FFT_SIZE / 2 - self.offset / rate * FFT_SIZE))
        half = max(1, int(bw / 2 / rate * FFT_SIZE))
        self.fft.channel = (centre_bin, half)
        tap_block = self.fft.make()
        tb.connect(src, pwr, tap_block)
        # Python blocks (the tap, and logpwrfft's hier block) must stay
        # referenced from Python: GNU Radio only holds the C++ side, and a
        # collected Python block segfaults the scheduler on start.
        self._blocks = [src, chan, resampler, squelch, dm, vol_l, vol_r, sink, wav, pwr, tap_block]

        self.tb = tb
        self.src = src

    # Live changes: no rebuild needed.
    def set_frequency(self, hz: int):
        if self.src is not None:
            self.src.set_center_freq(int(hz) + self.offset, 0)

    def set_gain(self, gain):
        if self.src is not None:
            self._apply_gain(self.src, gain)

    def set_ppm(self, ppm: int):
        if self.src is not None:
            self.src.set_freq_corr(int(ppm), 0)

    def set_volume(self, v: float):
        if self._volume is not None:
            for block in self._volume:
                block.set_k(float(v))

    def set_squelch(self, db: float):
        if self._squelch is not None:
            self._squelch.set_threshold(float(db))

    @staticmethod
    def _apply_gain(src, gain):
        if gain == "auto":
            src.set_gain_mode(True, 0)
        else:
            src.set_gain_mode(False, 0)
            src.set_gain(float(gain), 0)


# The R820T/R828D tuner's discrete gains (rtl_test -t). gr-osmosdr's Python
# binding cannot return the per-step list (meta_range_t.values() has no
# converter), so when the range matches this tuner the table is used; other
# devices get a uniform sweep by the reported step.
R82X_GAINS = [0.0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9, 25.4,
              28.0, 29.7, 32.8, 33.8, 36.4, 37.2, 38.6, 40.2, 42.1, 43.4, 43.9, 44.5, 48.0, 49.6]


def gain_steps(rng) -> list[float]:
    try:
        start, stop, step = float(rng.start()), float(rng.stop()), float(rng.step())
    except Exception:
        return []
    if abs(start) < 0.01 and abs(stop - 49.6) < 0.01:
        return list(R82X_GAINS)
    if step <= 0 or stop <= start:
        return [round(start, 1)]
    count = int((stop - start) / step) + 1
    if count > 200:
        step = (stop - start) / 199
        count = 200
    return [round(start + i * step, 1) for i in range(count)]


def short_error(exc: BaseException) -> str:
    text = str(exc).strip().splitlines()
    return text[-1] if text else exc.__class__.__name__


# --------------------------------------------------------------------- presets

def load_json(path: Path, fallback):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)


def import_gqrx_bookmarks(presets: list[dict]) -> tuple[list[dict], int, int]:
    """Merge gqrx bookmarks into presets. Existing frequencies are never
    overwritten (AGENTS.md); returns (presets, added, skipped)."""
    if not GQRX_BOOKMARKS.exists():
        raise FileNotFoundError(str(GQRX_BOOKMARKS))
    known = {int(p["frequency"]) for p in presets}
    added = skipped = 0
    section = ""
    mode_map = {"wfm_st": "wfm_stereo", "wfm": "wfm", "wfm_st_oirt": "wfm_stereo", "nfm": "nfm", "fm": "nfm",
                "am": "am", "am-sync": "am", "usb": "usb", "lsb": "lsb", "cw": "cw", "cwl": "cw", "cwu": "cw", "raw": "raw"}
    for raw in GQRX_BOOKMARKS.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            section = line.lstrip("#").strip().lower()
            continue
        if not section.startswith("frequency"):
            continue
        cols = [c.strip() for c in line.split(";")]
        if len(cols) < 3:
            continue
        try:
            hz = int(float(cols[0]))
        except ValueError:
            continue
        if hz in known:
            skipped += 1
            continue
        name = cols[1]
        mode_raw = cols[2].lower().replace(" ", "_").replace("(", "").replace(")", "")
        demod = mode_map.get(mode_raw, "nfm")
        tags = [t.strip() for t in cols[4].split(",")] if len(cols) > 4 and cols[4] else []
        presets.append({"name": name, "frequency": hz, "demod": demod, "tags": tags})
        known.add(hz)
        added += 1
    presets.sort(key=lambda p: p["frequency"])
    return presets, added, skipped


def load_bandplan() -> list[dict]:
    """gqrx's bandplan.csv: min, max, mode, step, color, name. Missing file
    means no labels; the UI copes."""
    bands = []
    try:
        for raw in GQRX_BANDPLAN.read_text(errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            cols = [c.strip() for c in line.split(",")]
            if len(cols) < 6:
                continue
            try:
                bands.append({"start": int(float(cols[0])), "stop": int(float(cols[1])), "mode": cols[2],
                              "step": int(float(cols[3])), "color": cols[4], "name": ",".join(cols[5:])})
            except ValueError:
                continue
    except OSError:
        pass
    return bands


# ---------------------------------------------------------------------- daemon

@dataclass
class Daemon:
    settings: dict = field(default_factory=dict)
    presets: list = field(default_factory=list)
    receiver: Receiver = field(default_factory=Receiver)
    clients: set = field(default_factory=set)
    lock: threading.RLock = field(default_factory=threading.RLock)
    last_activity: float = field(default_factory=time.monotonic)
    stopping: bool = False
    device: DeviceInfo | None = None
    sender: socket.socket | None = None
    bandplan: list = field(default_factory=load_bandplan)

    # -- state ---------------------------------------------------------------
    def state(self) -> dict:
        demod = next(d for d in DEMODS if d["id"] == self.settings["demod"])
        step = int(self.settings.get("step_override") or demod["step"])
        return {
            "v": PROTOCOL_VERSION,
            "type": "state",
            "version": VERSION,
            "playing": self.receiver.running,
            "frequency": int(self.settings["frequency"]),
            "demod": demod["id"],
            "step": step,
            "gain": self.settings["gain"],
            "gain_range": self.receiver.gain_range,
            "ppm": int(self.settings["ppm"]),
            "sample_rate": int(self.settings["sample_rate"]),
            "squelch": float(self.settings["squelch"]),
            "volume": float(self.settings["volume"]),
            "keep_running": bool(self.settings["keep_running"]),
            "recording": self.receiver.recording,
            "recording_started": self.receiver.recording_started if self.receiver.recording else 0,
            "record_dir": self.settings["record_dir"],
            "device": self.device_json(),
            "error": self.receiver.error,
        }

    def device_json(self) -> dict:
        d = self.device
        if d is None:
            return {"status": "missing", "name": "", "serial": "", "args": "", "held_by": ""}
        return {"status": d.status, "name": d.name, "serial": d.serial, "args": d.args, "held_by": d.held_by}

    def hello(self) -> dict:
        return {"v": PROTOCOL_VERSION, "type": "hello", "version": VERSION, "demods": DEMODS,
                "presets": self.presets, "socket": str(SOCKET_PATH), "fft_socket": str(FFT_SOCKET_PATH),
                "bandplan": self.bandplan}

    def refresh_device(self):
        found = enumerate_devices()
        wanted = self.settings.get("device") or ""
        chosen = None
        for d in found:
            if not wanted or d.args == wanted or (d.serial and d.serial == wanted):
                chosen = d
                break
        if chosen is None:
            self.device = None
            return
        if self.receiver.running:
            chosen.status = "ours"
        else:
            holder = holder_of(chosen.usb_path)
            if holder:
                chosen.status, chosen.held_by = "busy", holder
            else:
                chosen.status = "free"
        self.device = chosen

    # -- commands ------------------------------------------------------------
    def handle(self, msg: dict, sender: socket.socket | None = None) -> dict | None:
        """Run one command. The reply goes to the sender only; state and preset
        changes are broadcast to every other client so nobody sees a message
        twice."""
        t = msg.get("type")
        with self.lock:
            self.sender = sender
            self.last_activity = time.monotonic()
            if t == "get_state":
                self.refresh_device()
                return self.state()
            if t == "play":
                return self.play()
            if t == "stop":
                self.receiver.stop()
                self.refresh_device()
                return self.broadcast_state()
            if t == "set_frequency":
                hz = int(msg["frequency"])
                if hz <= 0:
                    return self.error("Frequency must be positive")
                self.settings["frequency"] = hz
                self.receiver.set_frequency(hz)
                return self.persist_and_broadcast()
            if t == "step":
                demod = next(d for d in DEMODS if d["id"] == self.settings["demod"])
                step = int(self.settings.get("step_override") or demod["step"])
                hz = max(1, int(self.settings["frequency"]) + step * int(msg.get("delta", 1)))
                self.settings["frequency"] = hz
                self.receiver.set_frequency(hz)
                return self.persist_and_broadcast()
            if t == "set_demod":
                if msg.get("demod") not in DEMOD_IDS:
                    return self.error("Unknown demod: %r" % msg.get("demod"))
                self.settings["demod"] = msg["demod"]
                self.settings["step_override"] = 0
                if self.receiver.running:
                    return self.play()
                return self.persist_and_broadcast()
            if t == "set_step":
                self.settings["step_override"] = max(0, int(msg.get("step", 0)))
                return self.persist_and_broadcast()
            if t == "set_gain":
                gain = msg.get("gain", "auto")
                self.settings["gain"] = "auto" if gain == "auto" else float(gain)
                self.receiver.set_gain(self.settings["gain"])
                return self.persist_and_broadcast()
            if t == "set_ppm":
                self.settings["ppm"] = int(msg.get("ppm", 0))
                self.receiver.set_ppm(self.settings["ppm"])
                return self.persist_and_broadcast()
            if t == "set_sample_rate":
                self.settings["sample_rate"] = int(msg["sample_rate"])
                if self.receiver.running:
                    return self.play()
                return self.persist_and_broadcast()
            if t == "set_squelch":
                self.settings["squelch"] = float(msg.get("squelch", -150))
                self.receiver.set_squelch(self.settings["squelch"])
                return self.persist_and_broadcast()
            if t == "set_volume":
                self.settings["volume"] = min(1.0, max(0.0, float(msg.get("volume", 0.5))))
                self.receiver.set_volume(self.settings["volume"])
                return self.persist_and_broadcast()
            if t == "record":
                if not msg.get("enabled", True):
                    self.receiver.record("")
                    return self.broadcast_state()
                if not self.receiver.running:
                    return self.error("Start playback before recording")
                stamp = time.strftime("%Y%m%d-%H%M%S")
                name = f"{stamp}-{int(self.settings['frequency']) / 1e6:.3f}MHz-{self.settings['demod']}.wav"
                path = str(Path(os.path.expanduser(self.settings["record_dir"])) / name)
                if not self.receiver.record(path):
                    return self.error("Could not open " + path)
                return self.broadcast_state()
            if t == "set_record_dir":
                self.settings["record_dir"] = str(msg.get("record_dir") or DEFAULT_SETTINGS["record_dir"])
                return self.persist_and_broadcast()
            if t == "set_keep_running":
                self.settings["keep_running"] = bool(msg.get("enabled", False))
                return self.persist_and_broadcast()
            if t == "set_device":
                self.settings["device"] = str(msg.get("device", ""))
                if self.receiver.running:
                    return self.play()
                self.refresh_device()
                return self.persist_and_broadcast()
            if t == "list_devices":
                return {"v": PROTOCOL_VERSION, "type": "devices",
                        "devices": [vars(d) for d in enumerate_devices()]}
            if t == "save_preset":
                return self.save_preset(msg)
            if t == "delete_preset":
                hz = int(msg["frequency"])
                self.presets = [p for p in self.presets if int(p["frequency"]) != hz]
                save_json(PRESETS_PATH, self.presets)
                return self.broadcast_presets()
            if t == "import_gqrx":
                try:
                    self.presets, added, skipped = import_gqrx_bookmarks(self.presets)
                except FileNotFoundError as exc:
                    return self.error("No gqrx bookmarks at " + str(exc))
                save_json(PRESETS_PATH, self.presets)
                presets_msg = self.broadcast_presets()
                if sender is not None:
                    sender.sendall((json.dumps(presets_msg) + "\n").encode())
                return {"v": PROTOCOL_VERSION, "type": "imported", "added": added, "skipped": skipped}
            if t == "quit":
                self.stopping = True
                return {"v": PROTOCOL_VERSION, "type": "bye"}
            return self.error("Unknown command: %r" % t)

    def play(self) -> dict:
        self.refresh_device()
        if self.device is None:
            self.receiver.error = "No RTL-SDR device found"
            return self.broadcast_state()
        if self.device.status == "busy":
            self.receiver.error = "Device held by " + self.device.held_by
            return self.broadcast_state()
        try:
            self.receiver.start(self.settings, self.device.args)
        except Exception:
            log("start failed:", traceback.format_exc())
            self.refresh_device()
            return self.broadcast_state()
        self.refresh_device()
        return self.persist_and_broadcast()

    def save_preset(self, msg: dict) -> dict:
        hz = int(msg.get("frequency") or self.settings["frequency"])
        entry = {"name": str(msg.get("name") or f"{hz / 1e6:.3f} MHz"), "frequency": hz,
                 "demod": msg.get("demod") or self.settings["demod"], "tags": list(msg.get("tags") or [])}
        self.presets = [p for p in self.presets if int(p["frequency"]) != hz] + [entry]
        self.presets.sort(key=lambda p: p["frequency"])
        save_json(PRESETS_PATH, self.presets)
        return self.broadcast_presets()

    def error(self, message: str) -> dict:
        return {"v": PROTOCOL_VERSION, "type": "error", "message": message}

    def persist_and_broadcast(self) -> dict:
        save_json(SETTINGS_PATH, self.settings)
        return self.broadcast_state()

    def broadcast_state(self) -> dict:
        state = self.state()
        self.broadcast(state)
        return state

    def broadcast_presets(self) -> dict:
        msg = {"v": PROTOCOL_VERSION, "type": "presets", "presets": self.presets}
        self.broadcast(msg)
        return msg

    def broadcast(self, msg: dict):
        data = (json.dumps(msg) + "\n").encode()
        for conn in list(self.clients):
            if conn is self.sender:
                continue
            try:
                conn.sendall(data)
            except OSError:
                self.clients.discard(conn)

    # -- transport -----------------------------------------------------------
    def serve(self):
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        if SOCKET_PATH.exists():
            SOCKET_PATH.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(SOCKET_PATH))
        server.listen(8)
        server.settimeout(1.0)
        PID_PATH.write_text(str(os.getpid()))
        log("listening on", SOCKET_PATH)
        self.refresh_device()
        threading.Thread(target=self.serve_fft, daemon=True).start()
        threading.Thread(target=self.level_loop, daemon=True).start()
        try:
            while not self.stopping:
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    self.idle_check()
                    continue
                threading.Thread(target=self.client, args=(conn,), daemon=True).start()
        finally:
            self.receiver.stop()
            server.close()
            for p in (SOCKET_PATH, FFT_SOCKET_PATH, PID_PATH):
                try:
                    p.unlink()
                except OSError:
                    pass
            log("stopped")

    def serve_fft(self):
        """Second socket: one JSON line per spectrum frame while playing."""
        if FFT_SOCKET_PATH.exists():
            FFT_SOCKET_PATH.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(FFT_SOCKET_PATH))
        server.listen(8)
        server.settimeout(1.0)
        while not self.stopping:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=self.fft_client, args=(conn,), daemon=True).start()
        server.close()

    def fft_client(self, conn: socket.socket):
        hello = {"v": PROTOCOL_VERSION, "type": "fft_hello", "n": FFT_SIZE, "fps": FFT_FPS,
                 "db_min": FFT_DB_MIN, "db_step": FFT_DB_STEP}
        seq = 0
        try:
            conn.sendall((json.dumps(hello) + "\n").encode())
            while not self.stopping:
                tap = self.receiver.fft
                new_seq = tap.wait_frame(seq, 1.0)
                if new_seq == seq or not self.receiver.running:
                    continue
                seq = new_seq
                with tap.lock:
                    bins = tap.bins
                frame = {"v": PROTOCOL_VERSION, "type": "fft", "seq": seq,
                         "center": int(self.settings["frequency"]) + self.receiver.offset,
                         "rate": self.receiver.rate, "freq": int(self.settings["frequency"]),
                         "bw": self.receiver.bw, "n": FFT_SIZE, "bins": list(bins)}
                conn.sendall((json.dumps(frame) + "\n").encode())
        except OSError:
            pass
        finally:
            conn.close()

    def level_loop(self):
        """Signal level in the tuned channel, a few times a second, to every
        control client while playing. Small, so it rides the control socket."""
        last = None
        while not self.stopping:
            time.sleep(1.0 / LEVEL_HZ)
            if not self.receiver.running or not self.clients:
                continue
            with self.receiver.fft.lock:
                level = round(self.receiver.fft.level_db, 1)
            if level == last:
                continue
            last = level
            with self.lock:
                self.sender = None
                self.broadcast({"v": PROTOCOL_VERSION, "type": "level", "db": level})

    def idle_check(self):
        """On demand (AGENTS.md): with keep_running off, exit after a quiet
        spell. A connected but idle client (the bar widget) does not count as
        activity; otherwise the daemon would never leave while the shell runs."""
        with self.lock:
            if self.settings.get("keep_running") or self.receiver.running:
                self.last_activity = time.monotonic()
                return
            if time.monotonic() - self.last_activity > IDLE_TIMEOUT_S:
                log("idle for %d s, exiting" % IDLE_TIMEOUT_S)
                self.stopping = True

    def client(self, conn: socket.socket):
        self.clients.add(conn)
        try:
            with self.lock:
                self.refresh_device()
                conn.sendall((json.dumps(self.hello()) + "\n").encode())
                conn.sendall((json.dumps(self.state()) + "\n").encode())
            buf = b""
            while not self.stopping:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        reply = self.handle(json.loads(line), conn)
                    except Exception as exc:
                        log("command failed:", traceback.format_exc())
                        reply = self.error(short_error(exc))
                    if reply is not None:
                        conn.sendall((json.dumps(reply) + "\n").encode())
        except OSError:
            pass
        finally:
            self.clients.discard(conn)
            with self.lock:
                self.last_activity = time.monotonic()
            conn.close()


# ------------------------------------------------------------------------ cli

def running_pid() -> int:
    try:
        pid = int(PID_PATH.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="omasdrd", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("run", help="run in the foreground (default)")
    sub.add_parser("ensure", help="start the daemon in the background if it is not running")
    sub.add_parser("stop", help="ask a running daemon to exit")
    sub.add_parser("status", help="print whether the daemon is running")
    sub.add_parser("devices", help="list RTL-SDR devices and who holds them")
    args = parser.parse_args(argv)
    cmd = args.cmd or "run"

    if cmd == "status":
        pid = running_pid()
        print(f"running (pid {pid})" if pid else "not running")
        return 0 if pid else 1
    if cmd == "devices":
        for d in enumerate_devices():
            holder = holder_of(d.usb_path)
            print(f"{d.args}\t{d.name}\tSN {d.serial or '?'}\t{'held by ' + holder if holder else 'free'}")
        return 0
    if cmd == "stop":
        pid = running_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)
        return 0
    if cmd == "ensure":
        if running_pid():
            return 0
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "ab") as logf:
            subprocess.Popen([sys.executable, __file__, "run"], stdout=logf, stderr=logf,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        return 0

    if running_pid():
        log("already running")
        return 1
    daemon = Daemon()
    saved = load_json(SETTINGS_PATH, {})
    if isinstance(saved, dict) and saved.get("schema", 1) < 2 and saved.get("gain") == "auto":
        saved["gain"] = DEFAULT_SETTINGS["gain"]      # schema 1 shipped auto gain; see DEFAULT_SETTINGS
    daemon.settings = {**DEFAULT_SETTINGS, **saved, "schema": SETTINGS_SCHEMA}
    if daemon.settings["demod"] not in DEMOD_IDS:
        daemon.settings["demod"] = "wfm"
    daemon.presets = load_json(PRESETS_PATH, [])

    def on_signal(*_):
        daemon.stopping = True
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    daemon.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
