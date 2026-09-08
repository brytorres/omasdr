# Working on OmaSDR

OmaSDR is an Omarchy-native software-defined radio receiver: a Quickshell/QML
bar plugin fed by a headless GNU Radio daemon. It is a simpler, desktop-
integrated alternative to gqrx, not a rewrite of it. The repository is the
plugin and is installed with `omarchy plugin add`.

This file records decisions that are settled. Do not re-open them without
asking the maintainer. Add new decisions here as they are made, with the date.

## Product intent

- The app should not need to be "open". A small bar widget opens a popover
  with the essential controls; an "expand" action opens a larger panel for
  the waterfall and spectrum plot.
- Shipped so far: device detection, frequency entry with a kHz/MHz toggle,
  scroll-to-step tuning, eight demodulators, presets with a repeatable gqrx
  import, recording, a signal meter, and a spectrum plot with waterfall.
- Still ahead, roughly in order:
  - Manual or frozen dB range for the spectrum, if auto-range annoys in use.
  - **RDS on FM**: the station name and song text a car radio shows. See the
    section below for where it taps in and what decodes it.
  - Multi-device selection: `list_devices` in the window, a picker calling
    `set_device`, and selection by serial.
  - Per-demod filter widths and squelch defaults.
  - AGC mode, DC offset, and I/Q balance controls (`gnuradio-iqbal` is
    already installed).
  - Preset tags and filtering in the popover.
  - **Keyboard shortcuts**, meaning both a Hyprland binding that summons the
    popover (with an example for `~/.config/hypr/bindings.lua` in the README)
    and keys inside it for play, stop, step, record, and jumping to a preset,
    listed somewhere discoverable.
  - Other gr-osmosdr backends, once someone can test one.

  Design the daemon protocol so these stay additive rather than breaking.

## Architecture decisions (2026-09-08)

**Backend: custom Python daemon on GNU Radio, reusing everything possible.**
Do not reimplement DSP. Everything below already ships in the system packages:

- Device access via `gr-osmosdr` (`osmosdr.source`). This also gives free
  support for HackRF, Airspy, SDRplay, and rtl_tcp remotes later.
- Demodulators from `gnuradio.analog`: WFM, WFM stereo, NFM, AM, USB, LSB,
  CW, RAW. These are the "main ones" the UI lists.
- Squelch, filters, and resamplers from `gnuradio.analog` / `gnuradio.filter`.
- FFT for the waterfall from `gnuradio.fft` (`logpwrfft`).
- Audio out via `gnuradio.audio.sink` through the PipeWire ALSA shim.

**Daemon lifecycle: on demand, with a "keep running" option.** The plugin
starts the daemon when a popover or window opens or when play is pressed
while offline; the bar icon alone never starts or restarts it. The daemon
exits after 10 minutes without playback or a command unless "keep running"
is set; a connected but silent client (the bar widget) does not count as
activity. GNU Radio takes about a second to start, so never spawn a process
per action; the daemon stays resident while in use.

**Protocol: JSON lines over a Unix socket.** Same shape omastorm uses between
its engine and its QML. One request per line, one response per line, plus
unsolicited state events. FFT frames for the waterfall go over a second
channel so control traffic never waits behind them. Document the contract in
`docs/protocol.md`. A rigctl-compatible TCP port is explicitly out of scope
unless the maintainer asks for it.

**Receiver defaults (2026-09-08, after the first listening comparison with
gqrx).** Offset tuning: the hardware is tuned 300 kHz above the wanted
channel and the channel filter shifts it back, so the RTL dongle's DC spike
and centre-frequency noise never sit in the passband (gqrx uses 362 kHz).
Default gain is a fixed 25.4 dB, not tuner AGC: the R82x tuner's AGC pumps
and overloads on strong stations. The audio sink opens in stereo; mono
demods feed both channels, WFM stereo keeps L and R separate.

**Spectrum transport (2026-09-08).** A second Unix socket
(`fft.sock`) streams one JSON line per frame: 1024 log-power bins over the
whole sampled band at 15 frames a second, each bin a byte
(`dB = b * 0.5 - 128`) sent as a JSON array of ints. JSON lines rather
than binary framing so the Quickshell side stays a `Socket` +
`SplitParser`; base64 was tried and dropped because Qt's `atob` is
deprecated and not byte-exact. ~4 KB a frame is nothing on a Unix socket. Frames flow only
while playing and only to connected subscribers. The in-channel signal
level rides the control socket as `level` messages at 4 Hz for the
popover's meter.

**Waterfall rendering: a ring buffer, never a copy (2026-09-08).** One
Canvas holds the history. Each frame writes a single row at a decreasing
index and wraps, and two `ShaderEffectSource` views show the two slices in
order with the newest on top. Colour comes from a theme-derived lookup
(background → accent → yellow → red), painted as `fillRect` runs because
`putImageData` is a no-op on Quickshell's canvas.

Do not replace this with a scrolling copy. Three copy designs were measured
with a marker row every 15 frames: a canvas drawn onto itself, and two
canvases ping-ponging, each under both render strategies. The ring buffer
put its markers exactly 30 device pixels apart every time; all three copy
designs produced 60 with unpredictable doubling, which is what made the
waterfall appear to jump. Copying is also fragile for a second reason: a
canvas-to-canvas `drawImage` takes its source rectangle in device pixels
and its destination in logical ones, and a canvas drawn onto itself reads
rows it has already overwritten. The ring buffer copies nothing, so none of
that applies, and it is O(1) per frame rather than O(area).

**Spectrum auto-range: snapped and hysteretic (2026-09-08).** Targets are
rounded to 5 dB and adopted only once they are a full step from the current
value. Lerping towards a target every frame, which is what shipped first,
made the trace and its grid crawl continuously; that reads as jitter even
though the data is fine. The signal moves, the axis should not.

**Expanded window layout (2026-09-08).** The top band, about a third of the
height, holds the tuner card (presets beside it when the window is at
least 1040 px wide, under it otherwise) and the receiver settings. The
spectrum plot and waterfall span the full width below in a padded box;
the plot takes 30 % of that box. Nested Qt layouts fill by default, so
the band and caption rows set `Layout.fillHeight: false` explicitly. Python GNU Radio blocks (the FFT tap,
logpwrfft) must stay referenced from Python or the scheduler segfaults on
start; `Receiver._blocks` exists for that reason alone.

**Presets: own JSON store with a repeatable gqrx import.**

- Store lives in `~/.config/omasdr/presets.json`.
- Import reads `~/.config/gqrx/bookmarks.csv` and can be run any number of
  times.
- On import, a preset whose frequency already exists in the store is never
  overwritten. New frequencies are added; existing ones are left alone.
- gqrx's `bandplan.csv` may be read for labelling the spectrum later.

**Tuning step follows demod.** Scroll-to-step uses a per-demod default (for
example 100 kHz for WFM, 12.5 kHz for NFM, 9 or 10 kHz for AM, 1 kHz for
SSB/CW) with a manual override in the popover.

**Frequency entry.** A text field with a kHz/MHz toggle. Internally the daemon
and the protocol always use integer hertz; only the UI converts. The field
follows the daemon unless the user is part-way through typing, tracked by an
explicit `editing` flag. Do not gate that on `activeFocus`: the arrow keys
and the wheel step *while the field holds focus*, and gating on focus meant
those steps did not show up until the popover was reopened. The expanded
window also has to call `forceActiveFocus()` on the tuner when it becomes
visible; the bar popover gets focus from `KeyboardPanel.focusTarget`, but
nothing does it for the window, and without it the field ignores the
keyboard entirely.

**Preset rows.** Fixed-width columns, not an elastic row: the name takes the
slack, then the frequency value right-aligned in its own lane, then the unit,
then the mode. That is what makes the numbers line up down the list. Hovering
a row shows a tooltip with the full name (the row elides it), frequency,
mode, and tags, sections separated by `|`. It lives outside the `ListView` so
it is not clipped, which is why the `clip` sits on the list rather than on the
box around it.

**Hardware scope (2026-09-08).** The RTL-SDR Blog V4 is the only radio this
has been tested on. Device detection matches USB ids `0bda:2838` and
`0bda:2832` only, so any RTL2832U dongle reporting those should work
unchanged (the tuner differs, nothing above it does), a rebadged dongle with
another id will not be found, and no non-RTL radio will be either. The DSP
layer is gr-osmosdr, which already speaks HackRF, Airspy, bladeRF, USRP,
SoapySDR, and rtl_tcp, so broadening support is a detection and picker job,
not a signal-processing one. Say exactly this in the README rather than
implying wider support than has been tried.

**Device setup.** MVP detects the single connected device and shows its name,
serial, and whether it is free, held by OmaSDR, held by another process
(gqrx), or missing. Only one process can open an RTL-SDR at a time; the
popover must say so instead of failing silently. Multi-device selection is
still ahead.

**Plugin identity.** id `com.omasdr.radio`, display name `OmaSDR`. Kinds
`bar-widget` and `panel`, mirroring omastorm's manifest.

**Version and updates (2026-09-08).** `manifest.json` `version` is the single
source of truth: the daemon reads it at import rather than carrying its own
constant, so a running daemon keeps reporting the build it is actually
executing after `omarchy plugin update` rewrites the file. The popover
compares that against the manifest on disk and, when they differ, shows a
notice with a restart button that stops the old daemon; the next play starts
the new one. The README tells users to run `omarchy restart shell` after an
update, because the shell caches plugin components.

**Icon.** A custom mark drawn in QML (like omastorm's `RadarMark`): a whip
antenna with radiating arcs. No font glyphs.

**Language.** Daemon in Python 3 using the system `python-gnuradio` package,
not a venv. GNU Radio bindings do not install cleanly through pip. UI in
Quickshell QML.

**Dependencies are declared, not assumed.** The README lists every pacman
package the project needs and a setup script checks for them. This is a FOSS
project; the README is written for the end user, not the developer.

**Setup script: `scripts/setup.sh` (decided 2026-09-08).** One idempotent
bash script that takes a machine from nothing to a verified dongle.

- Required packages: `rtl-sdr`, `gnuradio-osmosdr` (pulls `gnuradio` and
  `python-gnuradio`), `usbutils`. Optional: `gqrx`, only for bookmark
  import; the script offers it but never requires it.
- Installs only what `pacman -Q` reports missing, via `omarchy pkg add`.
  Re-running on a complete system installs nothing.
- Runs in a terminal and uses `sudo` where needed (package install, module
  unload). Never `pkexec`.
- Steps, in order: check packages and install missing; unload
  `dvb_usb_rtl28xxu` if loaded (the package ships the blacklist but that
  only stops future autoloads); after a fresh install, reload and trigger
  udev and tell the user to replug; check `lsusb` for `0bda:2838` and print
  the USB-hub warning from the device notes if absent; run `rtl_test -t`
  under a timeout, look for the tuner line and the V4 banner, explain that
  the trailing "No E4000 tuner found" is harmless, and name the process
  holding the device if it is busy; import `gnuradio` and `osmosdr` under
  the system Python and print versions; end with a pass/fail table and a
  non-zero exit on any failure.
- `--check` does everything except install and unload. The daemon runs
  `setup.sh --check` when it fails to start for a dependency reason and the
  popover shows the result with a "run setup" hint.
- The `uaccess` udev tag grants seat users access without the `rtlsdr`
  group; suggest the group only for headless or SSH use.
- README notes that `dpdk` (about 280 MiB) arrives through `libuhd`, which
  `gnuradio` depends on, so a large install is expected and not a mistake.

## RDS and HD Radio (researched 2026-09-08, not built)

**RDS** (RBDS in North America) is the data a car radio displays: an FM
station adds a subcarrier at 57 kHz, three times the 19 kHz stereo pilot,
carrying 1187.5 bits a second in error-checked 104-bit groups. The fields
worth surfacing are `PS` (the 8-character station name), `RadioText` (64
free-form characters, usually artist and title), `RT+` (tags marking which
part of RadioText is the artist and which is the title, which is how newer
car displays split them cleanly), `PI` (a station code that maps to call
letters here), and `PTY` (program type).

**Where it taps in.** The data is already flowing through the daemon and
being thrown away. The WFM path decimates 2.4 MS/s to a 240 kHz channel,
which comfortably contains the 57 kHz subcarrier; it is the demodulator's
decimation to 48 kHz audio that discards it. So this is a tap on the
discriminator output at the channel rate, not a restructuring. Anything
below roughly 120 kHz cannot carry the subcarrier at all.

**What decodes it.** `redsea` (AUR, 1.3.1) is a small standalone binary that
reads demodulated MPX on stdin and prints one JSON object per group; the
documented pipeline is `rtl_fm -M fm -s 171k ... | redsea -r 171k`. That is
the pragmatic route. `gr-rds` would sit in the flowgraph directly but is not
packaged for Arch and needs a source build against GNU Radio 3.10. SDRangel
is in the repos and has RDS built in, which makes it a good reference to
check results against.

**Expect it to be unreliable on weak signals.** A local station locks in a
second or two; a marginal one produces garbled text or never synchronises.
Surface it as "no data yet" rather than blank, and never let it block audio.

**Fit.** Station name belongs in the popover header beside the frequency,
song text on a line beneath it. On the wire it is additive: either new
optional fields on `state`, or a separate message type, so an older client
keeps working.

**HD Radio (NRSC-5) is the other option**, and a bigger one. Many US
stations broadcast digital sidebands carrying station name, artist, title,
and album art, far more reliably than RDS. `nrsc5-git` is in the AUR and
works with an RTL-SDR, but it wants about 1.5 MS/s, noticeably more CPU, and
a stronger signal than analogue FM needs. Treat it as a separate feature
from RDS, not a replacement.

## Repository layout

```
OmaSDR/
├── manifest.json          plugin manifest (id com.omasdr.radio, version, kinds)
├── justfile               dev and release shortcuts; `just` lists them
├── README.md              the user-facing document
├── CONTRIBUTING.md        local development setup
├── AGENTS.md              this file: settled decisions
├── CLAUDE.md              pointer to this file
├── LICENSE                MIT
├── daemon/
│   └── omasdrd.py         flowgraph, both sockets, presets, CLI. System python3
├── docs/
│   ├── protocol.md        the daemon ↔ UI contract
│   └── media/README.md    how to recapture and publish README shots
├── scripts/
│   ├── setup.sh           dependency install and device verification
│   ├── check.sh           protocol walk against a scratch daemon
│   ├── dev-sync.sh        copy the checkout into the live shell
│   └── run.sh             open the window without the shell
└── ui/
    ├── RadioBar.qml       bar-widget entry: mark + popover host. Needs qs.Ui
    ├── Popover.qml        the tuner card, shared by the bar and the window
    ├── RadioWindow.qml    the expanded window
    ├── Panel.qml          its panel-kind plugin entry
    ├── Spectrum.qml       plot and waterfall (two ping-pong canvases)
    ├── Engine.qml         control-socket client
    ├── FftStream.qml      spectrum-socket client
    ├── Session.qml        singleton: connection, theme, on-demand daemon start
    ├── Theme.qml          Omarchy palette, parsed by Toml.js
    ├── AntennaMark.qml    the icon
    ├── Freq.js            the only code that knows about kHz and MHz
    ├── shell.qml          standalone launcher (scripts/run.sh)
    └── qmldir             component registrations
```

Everything tracked here lands on every user's disk, since `omarchy plugin
add` clones the whole default branch. Keep generated output and working
notes out of git.

## README requirements

The README is the only document a user reads. It is written for someone who
has just plugged in a dongle, not for a contributor. Keep it in this shape:

- What it is, in two sentences, and honestly positioned against gqrx.
- **Hardware**, split three ways and never blurred: tested (the V4 alone),
  should work unchanged (RTL2832U dongles on the two matched USB ids), and
  not found yet (other ids, and every non-RTL radio). See the hardware-scope
  decision above.
- Install: the two commands, what the setup script does, the package table,
  and a warning that `dpdk` makes the first download about 280 MiB.
- Using it: a one-line first success (tune an FM station), then frequency,
  stepping, presets, recording, spectrum, and gain.
- **gqrx is optional and the README must lead with that.** It buys bandplan
  labels and bookmark import. The bandplan is a CSV no package ships; the
  curl command to fetch it into `~/.config/gqrx/bandplan.csv` works with or
  without gqrx installed. Bookmark import needs gqrx, because gqrx writes
  that file. Both mention that only one program can hold the dongle.
- Troubleshooting in symptom-first form, ending at `setup.sh --check`.
- Where files are saved, and links to CONTRIBUTING, AGENTS, and the protocol.

Facts about a device belong in the README itself, summarised from the
maintainer's notes below; a user cannot see those notes.

**README media ships as release assets, never in the tree (2026-09-08).**
`omarchy plugin add` clones the whole default branch onto every user's
disk, so screenshots would cost every install and every update forever;
three shots weigh more than three times the entire repository history.
They live in `docs/media/`, which is ignored except for its README, and
are uploaded to the GitHub Release for the matching tag with
`gh release upload v<version> --clobber docs/media/*.png`. The README
links them by absolute URL pinned to that tag. This follows omastorm,
which does the same thing for the same reason. The tradeoff, accepted:
the images do not render for someone reading the README offline inside
their plugin clone. Downscale to 1600 px wide and quantize to 256
colours before uploading; text stays crisp and each file drops to about
a third.

## Device notes (maintainer-local, not in the clone)

The source material for the README Devices section lives outside this repo
at `~/Projects/3_dev/60_devices/<name>/` on the maintainer's machine. For the
RTL-SDR Blog V4 that is `~/Projects/3_dev/60_devices/rtl-sdr/`:

- `README.md`: verified setup on Omarchy aarch64 (Asahi), the USB hub that
  does not pass the dongle through, blacklist and udev details, gqrx
  settings, HF behaviour of the V4 (built-in upconverter; never enable
  direct sampling or set an LNB LO).
- `frequencies.md`: monitoring targets and per-mode band notes. Use it as
  the seed for default presets and the demod-to-step table.
- `init.conf`: the gqrx config that works with this dongle.

Read those before touching device detection, presets, or the README Devices
section. Summarise into the README; do not copy the files into the repo.

## Testing

The suite that runs anywhere:

```sh
bash scripts/check.sh          # protocol walk against a scratch daemon
omarchy plugin validate .      # the manifest check the shell applies
```

`just test` runs both. The scripts stay the source of truth; the justfile
is shortcuts over them, never a second implementation.

`check.sh` covers tuning, stepping, demod switching, presets, and refusals
with no hardware. With a free dongle it also plays, reads the tuner's gain
steps, streams spectrum frames, and records a WAV it then verifies. It uses a
private runtime and config directory, so it never touches real presets or a
running daemon. Run both before every commit, and both before tagging.

Everything else has been verified on the maintainer's machine: all eight
demodulators build and run on the V4 at 2.4 and 2.048 MS/s, the bar popover
and expanded window work in the live shell, audio and stereo are confirmed by
ear, and the spectrum and waterfall have been compared against gqrx.

Two checks remain open:

- [ ] **`scripts/setup.sh` on a clean machine or container.** It has only
      ever run on a system that already had every package. Paste its output
      into a PR. This is the last thing standing between the current state
      and a `v0.1.0` tag.
- [ ] **Whether the spectrum needs a manual dB range or a "freeze range"
      toggle.** Auto-range follows the noise floor and the peaks, which is
      right on a busy band and may drift annoyingly on a quiet one. Decide
      from use, not from theory. This is the last item before `v0.2.0`.

## Distribution

- The repository is the plugin. `omarchy plugin add` clones the default
  branch into `~/.config/omarchy/plugins/com.omasdr.radio`, and
  `omarchy plugin update` fast-forwards it.
- `manifest.json` `version` is the plugin version; tag the same commit
  `v<version>`. Run the checks under Testing before tagging. The README's
  version badge, its Status section, and the release URLs its screenshots
  point at repeat that number for display only; `just bump <version>`
  rewrites all of them together and refuses if any is missing. The badges
  are static because the repository is not reachable publicly yet; once it
  is, the version badge can read the manifest directly with shields.io's
  `dynamic/json` endpoint against the raw `manifest.json` and stop needing
  a manual bump.
- Symlinks anywhere in the plugin folder make the validator reject it, which
  is why development copies rather than links (`scripts/dev-sync.sh`).

## Licensing

**MIT, settled 2026-09-08.** A `LICENSE` file at the repository root and a
`license` field in `manifest.json`, matching the convention third-party
Omarchy plugins follow (omastorm does the same). The shell's validator
checks neither, so this is convention rather than a requirement. Keep the
two in step, and keep the copyright line as the maintainer's name.

The reasoning, so it does not get re-opened: GNU Radio and gr-osmosdr are
GPLv3 and `daemon/omasdrd.py` imports them at runtime, which raises the
question of whether the glue must be GPL too. It does not, for two reasons.
Nothing GPL is redistributed here, since users install those packages from
pacman themselves and the combination only happens on their machine. And
MIT is GPL-compatible in the direction that matters, so anyone who does
distribute the combination can do so under GPLv3 without a conflict. The
upside of MIT is that the parts of this repository with nothing to do with
GNU Radio stay reusable anywhere: the frequency parsing, the waterfall
renderer, the Quickshell canvas workarounds, the theme reader.

Changing this later needs every contributor to agree, so it was decided
before the first public release rather than after.

## Working conventions

- Reuse before writing. If GNU Radio, gr-osmosdr, or an Omarchy shell
  component already does it, use that.
- Never edit anything under `/usr/share/omarchy/`. Read it freely for
  reference; `omarchy plugin clone` is the way to copy a built-in widget.
- Frequency is always integer hertz in code, config, protocol, and presets.
- Any change to the socket protocol updates `docs/protocol.md` in the same
  commit.
- A new device the daemon has been tested with gets notes under
  `~/Projects/3_dev/60_devices/<name>/` and a summary in the README Devices
  section.
