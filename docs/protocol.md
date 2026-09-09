# Daemon protocol

The daemon (`daemon/omasdrd.py`) listens on a Unix socket at
`$XDG_RUNTIME_DIR/omasdr/control.sock`. Every message is one JSON object on
one line, terminated by `\n`. Every message from the daemon carries
`"v": 1`; a client that sees another value must stop and report an
incompatible daemon rather than guess.

Frequencies are integer hertz everywhere. Only the UI converts to kHz or MHz.

Any change to this contract lands in the same commit as the daemon change.

## Connection

On connect the daemon sends, in order:

1. `hello` with the demod catalogue and the preset list.
2. `state`, the full receiver state.

After that the client sends commands. Each command gets exactly one reply.
The daemon also broadcasts `state` and `presets` to every client whenever
either changes, so a client must accept those at any time, not only as a
reply.

## Control socket: messages from the daemon

### hello

```json
{"v": 1, "type": "hello", "version": "0.1.0", "socket": "/run/user/1000/omasdr/control.sock",
 "fft_socket": "/run/user/1000/omasdr/fft.sock", "bandplan": [...],
 "demods": [{"id": "wfm", "label": "WFM", "step": 100000, "bw": 200000, "audio_rate": 48000}, ...],
 "presets": [{"name": "KEXP", "frequency": 90300000, "demod": "wfm", "tags": ["FM"]}, ...]}
```

`demods` is ordered the way the UI should list it. `step` is the default
scroll-to-step for that demod in hertz.

### state

```json
{"v": 1, "type": "state", "version": "0.1.0",
 "playing": true,
 "frequency": 104100000,
 "demod": "wfm",
 "step": 100000,
 "gain": "auto",
 "gain_range": [0.0, 0.9, 1.4, ...],
 "ppm": 0,
 "sample_rate": 2400000,
 "squelch": -150.0,
 "volume": 0.5,
 "keep_running": false,
 "recording": "",
 "recording_started": 0,
 "record_dir": "/home/you/Audio/OmaSDR",
 "device": {"status": "ours", "name": "RTLSDRBlog Blog V4", "serial": "00000001", "args": "rtl=0", "held_by": ""},
 "location": {"name": "Melbourne, Brevard County, Florida", "latitude": 28.0785, "longitude": -80.6078, "source": "OpenStreetMap"},
 "error": ""}
```

- `step` is the effective step: the demod default unless `set_step` overrode it.
- `gain` is `"auto"` or a number in dB. `gain_range` is the tuner's stepped
  list; it is empty until the device has been opened once. The default is a
  fixed 25.4 dB: the R82x tuner's own AGC pumps and overloads on strong
  stations.
- `frequency` is the wanted channel. The daemon tunes the hardware 300 kHz
  above it and shifts back digitally (offset tuning), so the dongle's DC
  spike never sits in the passband. Clients never see the offset.
- `device.status` is one of `free`, `ours`, `busy`, `missing`. `held_by` is
  the process name when `busy` (for example `gqrx`).
- `recording` is the WAV path being written, or empty; `recording_started`
  is its Unix start time. Recording stops with playback.
- `error` is the last receiver failure in one line, or empty. It is cleared
  by the next successful `play`.
- `location` is where the user last searched from, `{}` until they say. It is
  never guessed: the daemon has no geolocation of any kind.

### presets

```json
{"v": 1, "type": "presets", "presets": [...]}
```

Sent to every client after any preset change. Sorted by frequency.

### devices

Reply to `list_devices`.

```json
{"v": 1, "type": "devices", "devices": [{"index": 0, "name": "...", "serial": "...", "args": "rtl=0", "usb_path": "/dev/bus/usb/001/002", "status": "free", "held_by": ""}]}
```

### imported

Reply to `import_gqrx`, after the `presets` broadcast.

```json
{"v": 1, "type": "imported", "added": 12, "skipped": 3}
```

### nearby

Reply to `search_nearby`, and then again when the search finishes. Only the
requesting client hears both.

```json
{"v": 1, "type": "nearby", "status": "searching"}
```

```json
{"v": 1, "type": "nearby", "status": "ok",
 "location": {"name": "Melbourne, Brevard County, Florida", "latitude": 28.0785, "longitude": -80.6078, "source": "OpenStreetMap"},
 "results": [
   {"kind": "airband", "name": "KMLB Tower", "frequency": 118200000, "demod": "am",
    "distance_km": 4.2, "detail": "Melbourne Orlando International Airport · Tower", "tags": ["airband"]},
   {"kind": "repeater", "name": "K4RPT", "frequency": 146745000, "demod": "nfm",
    "distance_km": 1.5, "detail": "Melbourne, Florida · -600 kHz · CTCSS 107.2", "tags": ["repeater"]}],
 "sources": [{"kind": "airband", "name": "OurAirports", "note": "public domain", "built": 1788912592, "count": 27722},
             {"kind": "repeaters", "name": "hearham.com", "note": "free to use, credited", "built": 1788912600, "count": 13959}],
 "notes": [], "hint": "digital-only repeaters (DMR, D-STAR, YSF, P25) are not listed"}
```

```json
{"v": 1, "type": "nearby", "status": "error", "message": "Nowhere called 'asdfgh'"}
```

- **Two replies, not one.** The first arrives immediately; the second may take
  a quarter of a minute the first time, because the daemon is geocoding and
  downloading. The command handler holds the daemon lock, so this work happens
  on a thread and the answer is unsolicited. A client that has disconnected by
  then simply never receives it.
- Every result carries exactly what `save_preset` wants — `name`, `frequency`,
  `demod`, `tags` — so "add as a preset" is one message with no translation.
- `results` are grouped by kind, nearest first inside each; each kind is
  limited separately so neither buries the other. Airband entries at the same
  airport arrive tower, ATIS, ground first rather than alphabetically.
- `sources` must be shown to the user: crediting both is the condition this
  feature ships under. `built` is when that index was last downloaded.
- `notes` carries anything degraded, such as a source being unreachable and a
  cached copy being used instead. A stale cache is not an error.
- A successful search also broadcasts `state`, because it stores `location`.

### error

Reply when a command was refused. Only the sender hears it.

```json
{"v": 1, "type": "error", "message": "Unknown demod: 'ssb'"}
```

### bye

Reply to `quit`, then the daemon exits.

## Control socket: commands from the client

| type | fields | reply | notes |
|---|---|---|---|
| `get_state` | | `state` | re-checks the device |
| `play` | | `state` | opens the device and starts audio; `state.error` says why not |
| `stop` | | `state` | stops the flowgraph, releases the device |
| `set_frequency` | `frequency` (Hz) | `state` | live retune |
| `step` | `delta` (±1, ±10, …) | `state` | moves by `state.step × delta` |
| `set_demod` | `demod` (id) | `state` | restarts the receiver if playing; resets any step override |
| `set_step` | `step` (Hz, 0 = follow demod) | `state` | manual override |
| `set_gain` | `gain` (`"auto"` or dB) | `state` | live |
| `set_ppm` | `ppm` (int) | `state` | live |
| `set_sample_rate` | `sample_rate` (S/s) | `state` | restarts the receiver if playing |
| `set_squelch` | `squelch` (dB) | `state` | live; -150 is open |
| `set_volume` | `volume` (0..1) | `state` | live |
| `set_keep_running` | `enabled` (bool) | `state` | off: daemon exits after 10 idle minutes |
| `record` | `enabled` (bool) | `state` or `error` | writes `<record_dir>/<stamp>-<MHz>-<demod>.wav`, stereo 16-bit 48 kHz; needs playback |
| `set_record_dir` | `record_dir` (path) | `state` | `~` is expanded |
| `set_device` | `device` (osmosdr args or serial, `""` = first) | `state` | restarts the receiver if playing |
| `list_devices` | | `devices` | |
| `save_preset` | `name`, `frequency`, `demod`, `tags` | `presets` | replaces a preset at the same frequency |
| `delete_preset` | `frequency` | `presets` | |
| `import_gqrx` | | `imported` | never overwrites an existing frequency |
| `search_nearby` | `place` or `latitude`+`longitude`; optional `kinds`, `limit`, `radius_km`, `refresh` | `nearby`, twice | `place` takes a Maidenhead locator, a coordinate pair, or anything Nominatim resolves; omit everything to reuse the stored location |
| `quit` | | `bye` | |

## FFT socket

`$XDG_RUNTIME_DIR/omasdr/fft.sock` (also under `OMASDR_RUNTIME_DIR`) streams
spectrum frames, one JSON line each, only while the receiver is playing.
Control traffic stays on `control.sock` so it never waits behind frames.
Clients send nothing; connect to subscribe, close to stop.

On connect:

```json
{"v": 1, "type": "fft_hello", "n": 1024, "fps": 15, "db_min": -128.0, "db_step": 0.5}
```

Then per frame:

```json
{"v": 1, "type": "fft", "seq": 812, "center": 104400000, "rate": 2400000, "freq": 104100000, "bw": 200000, "n": 1024, "bins": [131, 129, ...]}
```

- `bins` is `n` integers 0..255, DC in the middle, spanning `center ± rate/2`.
  dB for a value `b` is `b * db_step + db_min`. Plain integers rather than
  base64 because Qt's `atob` is deprecated and not byte-exact; a frame is
  about 4 KB, which is nothing on a Unix socket.
- `center` is the hardware centre, which sits `offset` above `freq` (see
  offset tuning); `freq` and `bw` locate the tuned channel in the frame.
- Frames are log-power with exponential averaging (alpha 0.5) at 15 a
  second. A slow client just sees fewer frames; nothing is queued.

## Level messages

While playing, the control socket also carries the signal level in the
tuned channel to every client, a few times a second and only when it
changes:

```json
{"v": 1, "type": "level", "db": -47.3}
```

## Bandplan

`hello` carries `bandplan`: gqrx's `~/.config/gqrx/bandplan.csv` as rows of
`{start, stop, mode, step, color, name}` (frequencies in Hz, colour as
written in the file, usually `#AARRGGBB`). Empty when the file is missing.

## Files

| Path | Owner | Content |
|---|---|---|
| `~/.config/omasdr/settings.json` | daemon | last receiver settings; loaded on start |
| `~/.config/omasdr/presets.json` | daemon | the preset list |
| `~/.config/omasdr/ui.json` | plugin | UI preferences the daemon never reads (`unit`) |
| `$XDG_RUNTIME_DIR/omasdr/control.sock` | daemon | the control socket (`OMASDR_RUNTIME_DIR` overrides the directory, for checks) |
| `$XDG_RUNTIME_DIR/omasdr/fft.sock` | daemon | the spectrum socket |
| `$XDG_RUNTIME_DIR/omasdr/daemon.pid` | daemon | pid of the running daemon |
| `$XDG_RUNTIME_DIR/omasdr/daemon.log` | daemon | stderr of a daemon started with `ensure` |
| `~/.cache/omasdr/nearby-airband.json` | daemon | derived airband index; rebuilt weekly or on `refresh` |
| `~/.cache/omasdr/nearby-repeaters.json` | daemon | derived repeater index; same |

## Nearby search

`search_nearby` answers "what is worth hearing from here" out of two datasets
that need no API key, downloaded on first use and cached under
`~/.cache/omasdr`:

- **OurAirports** (public domain) for VHF airband, 118–137 MHz: tower, ATIS,
  ground, approach and the rest, at 80,000 airports worldwide.
- **hearham.com** for analogue FM amateur repeaters. Digital-only repeaters
  (DMR, D-STAR, YSF, P25) are dropped when the index is built, because
  OmaSDR demodulates none of them.

Neither dataset is redistributed with the plugin; the raw downloads are not
kept either, only the derived indexes. Indexes rebuild when they are older
than a week or when `refresh` is set, and **a stale index is used happily**:
the search works offline against whatever was last fetched.

Geocoding goes through Nominatim, which needs no key but binds the daemon to
its usage policy: an identifying `User-Agent` and at most one request a
second, which the daemon enforces on itself. A Maidenhead locator or a
coordinate pair is resolved locally and never reaches the network.

## Lifecycle

`omasdrd.py ensure` starts a daemon in the background if none is running and
returns at once. The plugin calls it when a popover or window opens, when
play is pressed while offline, and every 15 s while such a surface is open
and the daemon is unreachable. The bar icon alone never starts it. With
`keep_running` off the daemon exits after 10 minutes without playback or a
command; a connected but silent client does not keep it alive. `omasdrd.py stop` asks it to exit; `status` and
`devices` are diagnostics.
