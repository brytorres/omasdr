#!/usr/bin/env bash
# Exercise the daemon over its socket: start a scratch daemon on a private
# runtime dir, walk the protocol, and stop it. No device needed for most of
# it; with a free dongle it also plays for two seconds.
set -euo pipefail
cd "$(dirname "$0")/.."
# Scratch runtime and config so the check never touches the real daemon,
# presets, or settings. XDG_RUNTIME_DIR itself stays put: PipeWire's ALSA
# plugin finds its server through it.
SCRATCH="$(mktemp -d)"
export OMASDR_RUNTIME_DIR="$SCRATCH/omasdr"
export XDG_CONFIG_HOME="$SCRATCH/config"
cleanup() {
  status=$?
  /usr/bin/python3 daemon/omasdrd.py stop >/dev/null 2>&1 || true
  if (( status != 0 )) && [[ -f "$OMASDR_RUNTIME_DIR/daemon.log" ]]; then
    echo "--- daemon log (last 30 lines)"; tail -30 "$OMASDR_RUNTIME_DIR/daemon.log"
  fi
  rm -rf "$SCRATCH"
  exit $status
}
trap cleanup EXIT
/usr/bin/python3 -m py_compile daemon/omasdrd.py
/usr/bin/python3 daemon/omasdrd.py ensure
for _ in $(seq 40); do [[ -S "$OMASDR_RUNTIME_DIR/control.sock" ]] && break; sleep 0.1; done
/usr/bin/python3 - <<'PY'
import json, os, socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.environ["OMASDR_RUNTIME_DIR"] + "/control.sock"); s.settimeout(20)
buf = b""
def read():
    global buf
    while b"\n" not in buf: buf += s.recv(65536)
    line, buf = buf.split(b"\n", 1); return json.loads(line)
def until(*types):
    while True:
        m = read()
        if m["type"] in types: return m
def send(m): s.sendall((json.dumps(m) + "\n").encode())
def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond: raise SystemExit(1)

hello = until("hello"); check(hello["v"] == 1 and len(hello["demods"]) >= 6, "hello with demods")
state = until("state"); check(state["type"] == "state", "initial state")
send({"type": "set_frequency", "frequency": 101_100_000}); r = until("state"); check(r["frequency"] == 101_100_000, "set_frequency")
send({"type": "step", "delta": -1}); r = until("state"); check(r["frequency"] == 101_000_000, "step follows demod (100 kHz for WFM)")
send({"type": "set_demod", "demod": "nfm"}); r = until("state"); check(r["demod"] == "nfm" and r["step"] == 12_500, "set_demod changes step")
send({"type": "set_step", "step": 5000}); r = until("state"); check(r["step"] == 5000, "set_step override")
send({"type": "set_demod", "demod": "wfm"}); r = until("state"); check(r["step"] == 100_000, "demod change clears override")
send({"type": "set_demod", "demod": "nope"}); r = until("error"); check("Unknown demod" in r["message"], "bad demod refused")
send({"type": "save_preset", "name": "A", "frequency": 90_300_000, "demod": "wfm"}); r = until("presets"); check(len(r["presets"]) == 1, "save_preset")
send({"type": "save_preset", "name": "B", "frequency": 90_300_000, "demod": "nfm"}); r = until("presets"); check(len(r["presets"]) == 1 and r["presets"][0]["name"] == "B", "same frequency replaces")
send({"type": "delete_preset", "frequency": 90_300_000}); r = until("presets"); check(len(r["presets"]) == 0, "delete_preset")
send({"type": "get_state"}); r = until("state")
dev = r["device"]; print("  device:", dev["status"], dev["name"], dev["held_by"])
if dev["status"] == "free":
    send({"type": "play"}); r = until("state")
    check(r["playing"] and r["device"]["status"] == "ours", "play opens the device (" + r["error"] + ")")
    check(len(r["gain_range"]) > 5, "gain_range read from tuner")
    time.sleep(2)
    send({"type": "set_frequency", "frequency": 104_100_000}); r = until("state"); check(r["playing"], "live retune")
    # Spectrum socket: hello, then frames while playing; level messages ride the control socket.
    f = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); f.connect(os.environ["OMASDR_RUNTIME_DIR"] + "/fft.sock"); f.settimeout(10)
    fbuf = b""
    def fread():
        global fbuf
        while b"\n" not in fbuf: fbuf += f.recv(65536)
        line, fbuf = fbuf.split(b"\n", 1); return json.loads(line)
    fh = fread(); check(fh["type"] == "fft_hello" and fh["n"] == 1024, "fft hello")
    fr = fread(); bins = fr["bins"]
    check(fr["type"] == "fft" and len(bins) == fr["n"] == 1024 and fr["center"] == 104_100_000 + 300_000, "fft frame: 1024 bins, centre carries the tuning offset")
    check(30 < max(bins) < 256 and min(bins) < max(bins), "fft frame has dynamic range (%d..%d)" % (min(bins), max(bins)))
    t0 = time.time(); n = 0
    while time.time() - t0 < 1.0: fread(); n += 1
    check(8 <= n <= 20, "fft rate about 15/s (%d in 1 s)" % n)
    f.close()
    lvl = until("level"); check(-150 < lvl["db"] < 0, "level message on control socket (%.1f dB)" % lvl["db"])
    send({"type": "set_record_dir", "record_dir": os.environ["OMASDR_RUNTIME_DIR"] + "/rec"}); until("state")
    send({"type": "record", "enabled": True}); r = until("state"); check(r["recording"].endswith(".wav"), "record starts")
    time.sleep(1.5)
    send({"type": "record", "enabled": False}); r = until("state"); check(r["recording"] == "", "record stops")
    import glob, wave
    files = glob.glob(os.environ["OMASDR_RUNTIME_DIR"] + "/rec/*.wav")
    with wave.open(files[0]) as w: check(w.getnchannels() == 2 and w.getframerate() == 48000 and w.getnframes() > 40000, "wav is stereo 48 kHz with >1 s of audio (%d frames)" % w.getnframes())
    send({"type": "stop"}); r = until("state"); check(not r["playing"] and r["device"]["status"] == "free", "stop releases the device")
elif dev["status"] == "busy":
    send({"type": "play"}); r = until("state"); check(not r["playing"] and "held by" in r["error"].lower(), "busy device reported, not crashed")
else:
    print("  skip playback: no device")
send({"type": "quit"}); check(until("bye")["type"] == "bye", "quit")
print("all checks passed")
PY
