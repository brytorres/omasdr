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
  import, recording, a signal meter, a spectrum plot with waterfall, and a
  frequency reference window, and a nearby search for local airband and
  repeaters.
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

**Spectrum view is centred on the tuned channel, not on the frame
(2026-09-08).** The frame arrives centred on the hardware, and offset tuning
puts the hardware 300 kHz above the wanted channel, so drawing the frame as
sent leaves the red marker at 37.5 % of the width instead of the middle —
which is exactly how it looked. The view is a window onto the frame instead:
centred on `freq`, spanning `rate - 2 × offset`, so 1.8 MHz of a 2.4 MS/s
band. Bins are consequently placed **by frequency** in both the plot and the
waterfall, through `binAt` / `binHz`; do not put `i / (n - 1) * w` back, it
assumes the view is the whole frame. The outer 300 kHz at each edge goes
unshown, which is the price of the marker sitting where the user is actually
listening. A degenerate offset falls back to the frame as sent.

**Nearby channels over the spectrum (2026-09-08).** `Spectrum.markers` draws
search results as yellow ticks with labels, and `RadioWindow` feeds it only
while the search window is open: they are a reading aid, not receiver state.
Labels are dropped where they would collide with the previous one, which only
works drawing left to right — the results arrive in distance order, and using
that order suppressed labels at random rather than by position.

**Expanded window layout (2026-09-08).** The top band, about a third of the
height, holds the tuner card (presets beside it when the window is at
least 1040 px wide, under it otherwise) and the receiver settings. The
spectrum plot and waterfall span the full width below in a padded box;
the plot takes 30 % of that box. Nested Qt layouts fill by default, so
the band and caption rows set `Layout.fillHeight: false` explicitly. Python GNU Radio blocks (the FFT tap,
logpwrfft) must stay referenced from Python or the scheduler segfaults on
start; `Receiver._blocks` exists for that reason alone.

**Frequency reference window (2026-09-08).** `docs/frequencies.md` is the
content and `ui/FreqHelp.qml` renders it at runtime, so the reference is edited
as markdown and an open window follows the file as it changes (the `FileView`
watches it). Nothing is duplicated in QML.

- **Its own `FloatingWindow`, held by `Session`.** Both the bar popover and the
  expanded window open it and there must only ever be one, so it hangs off the
  singleton behind a `LazyLoader` keyed on `Session.helpOpen` rather than off
  whichever card was clicked. Inside that loader do not write
  `FreqHelp { session: session }`: the right-hand `session` resolves to
  `FreqHelp`'s own property, not to this singleton, and the window comes up
  unthemed with no document. It already defaults to `Session`.
- **Own markdown reader (`ui/Markdown.js`), not `Text.MarkdownText`.** Qt does
  parse GitHub-dialect tables, but it draws them with its own spacing, no
  borders and no colour control, and this document is mostly tables. The reader
  handles exactly the subset the document uses — headings, paragraphs, block
  quotes, fenced code, bullet lists, tables — and the window styles those
  blocks like the rest of the plugin. Keep the document inside that subset.
- **Tables keep natural column widths and scroll sideways** rather than
  wrapping, so the frequency columns line up down the page. Every cell sets
  `Layout.fillWidth` or its background stops where its text does and the row
  shading looks ragged; the slack goes to the first column through
  `Layout.horizontalStretchFactor`.
- **Results are listed in frequency order, not distance order.** The daemon
still *picks* the nearest N of each kind — that is what makes it a nearby
search — but a list of channels reads the way a band does, and the distance
stays in its own column. The reload control is the word `RELOAD` rather than
a ↻ glyph, which rendered closer to a hook in the theme's monospace face; it
carries a hover tooltip saying what it re-downloads.

**Search keeps context.** A matching heading brings its whole section, a
  matching row brings its headings back with it, and tables narrow to their
  matching rows unless the section itself was the match.
- **The document is region-aware on purpose.** A region-neutral core, then
  clearly headed sections for the United States and Canada, Europe and ITU
  Region 1, and Asia-Pacific. Do not quietly promote a national number into
  the core, and say which country a number belongs to.

**The popover is the tuner; the window owns the daemon (2026-09-08).** "keep
daemon running" moved out of the shared tuner card into the expanded window's
bottom bar beside "stop daemon", so the two daemon controls sit together and
the bar popover carries none. That left the popover with no footer, so the row
under the presets carries FREQ HELP and FREQ SEARCH on the left and EXPAND on
the right, with a spacer between them. In the expanded window the same row
loses only EXPAND.

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

## Nearby search (2026-09-08)

The second button under the presets, beside FREQ HELP: what is worth hearing
from where the user actually is. **Framed as "near you", not as a repeater
finder.** This radio cannot transmit, and a repeater directory is mostly a
transmit-side tool; the local airport is the target that reliably has
something on it. The output is not a list to read, it is **presets to add in
one click** — that is the point of the feature, and it is what makes the
preset store pay off for a new user.

**Sources, decided after checking each one live rather than from memory.**

- **Airband: OurAirports.** `airport-frequencies.csv` (~1.3 MB, refreshed
  nightly) plus `airports.csv` for coordinates, from
  `davidmegginson.github.io/ourairports-data/`. Public domain, 80,000
  airports worldwide, tower/ground/ATIS/approach. No key, no terms
  conversation. This is the half of the feature with zero legal friction.
- **Repeaters: hearham.com.** `https://hearham.com/api/repeaters/v1`, no key
  and no required headers. Verified 2026-09-08: 200, 9.5 MB, 22,659 records.
  Fields include `callsign, latitude, longitude, city, group, mode, encode,
  decode, frequency, offset, description, operational`. **Frequency and offset
  are already integer hertz** (`145270000`, `-600000`), which matches this
  project's rule exactly, and CTCSS tones are present. Coverage by coordinate
  bucket: 15,074 North America, 5,688 Europe, 1,445 Australia/NZ, 217 Asia,
  96 South America, 52 Africa; 19,185 flagged operational.
  Known dirt to handle: no proximity query (fetch all, filter client-side),
  inconsistent mode strings (`D-STAR` / `D-star` / `DMR   ` with trailing
  spaces), and some double-encoded city strings (`VÃ¤stra GÃ¶taland`).

**Sources ruled out, so they do not get re-proposed.**

- **RepeaterBook.** Better data, but as of 2026-03-03 the API is restricted to
  approved clients: every call needs an `X-RB-App-Token`, either a shared app
  token granted on application or a per-user token each user generates. Terms
  require written permission for offline bundling or redistribution. Revisit
  only if someone wants to apply; per-user tokens are the signup this feature
  exists to avoid.
- **OpenStreetMap / Overpass.** Not a data source. Queried 2026-09-08:
  38 objects worldwide for `communication:amateur_radio=repeater`, zero for
  `amateur_radio=repeater`. Do not spend time on this again.
- **RadioReference.** Paid subscription API.
- **NOAA Weather Radio.** No machine-readable station list; weather.gov offers
  only an HTML listing that would have to be scraped once and shipped as a
  snapshot, and it is US-only. Not in the first version.
- Marine, FRS/GMRS, PMR446 and the rest are fixed channel plans that need no
  lookup at all. They are already in `docs/frequencies.md`.

**Location: asked once, remembered, never guessed.** A field taking a
Maidenhead locator (`FL96`) or raw coordinates, plus city and postcode
resolved through **Nominatim**, which needs no key. Nominatim's policy binds
us: a real identifying User-Agent, at most one request a second, and the
daemon enforces that on itself rather than trusting that a user cannot click
quickly. The resolved coordinates persist in the daemon's own
`settings.json` and ride back on `state.location`, so a reopened window
searches again without geocoding; `ui.json` was the first plan and was wrong,
because the daemon does the resolving and already owns that file. Do **not**
build on GeoClue2: its Wi-Fi positioning depended on Mozilla Location
Service, which shut down in 2024.

**Data reaches disk by download on first use, cached, refreshed on demand.**
Nothing ships in the repository — `omarchy plugin add` clones the whole branch
onto every user's disk, the same reason screenshots are release assets, and
redistributing hearham's data is the part its terms least clearly permit.
Cache under `~/.cache/omasdr/`. **A stale cache is a fine cache**: the search
must work offline against whatever was last fetched, because everything else
in OmaSDR works offline and this is the first thing that will not.

**Attribution, and the licence position, stated plainly.** OurAirports is
public domain. hearham publishes the endpoint openly and says the data is
"free to use in your application", but points only at a generic terms page,
so there is no explicit licence. Decision: use it, credit hearham
prominently in the results panel and the README, and stop if they ask us to.
That is an assumption, recorded here as one. Anyone who gets a written answer
from them should replace this paragraph with it.

**Where the fetch lives: the daemon**, in its own module `daemon/nearby.py`.
It already owns the config directory, speaks JSON, and has Python's HTTP
client; QML would have to parse 9.5 MB on the UI thread. A separate module
because HTTP, CSV and geocoding are not radio work and should not thicken
`omasdrd.py`.

**`search_nearby` answers twice, and that is deliberate.** `Daemon.handle()`
holds the daemon lock for the whole of a command, and this one geocodes and
may download 14 MB, so doing it inline would freeze every client and the
receiver with it. The reply is `{"status": "searching"}`; the result arrives
later as a second unsolicited `nearby` message to the requesting client
alone. A client that disconnected meanwhile never gets it, which is fine. The
worker takes the lock only to store the location and broadcast `state`, and
clears `self.sender` first so that broadcast reaches everyone.

**Indexes are derived, and the raw downloads are thrown away.**
`airports.csv` is 12 MB and only three of its columns matter, so it is
streamed rather than buffered, joined against the airband rows, and written
out as a compact index. Same for hearham: 9.5 MB in, analogue FM entries with
coordinates out. Rebuild weekly, or on `refresh`. **If a rebuild fails and a
cached index exists, that is not an error** — the old index is returned with
a note, because the search working offline matters more than it being current.

**Digital-only repeaters are dropped at build time.** DMR, D-STAR, YSF and
P25 are filtered by looking for a bare `FM` token in the mode string, which
keeps mixed-mode entries like `YSF/FM` and drops `C4FM`. OmaSDR demodulates
none of them, so listing them would only waste the user's time. The window
says so rather than leaving the absence unexplained.

**Airband results rank inside an airport.** One airport contributes a dozen
frequencies at the same distance, so distance alone would sort them
alphabetically and bury the tower. `ROLES` carries a rank next to each label,
and the sort is distance, then rank: tower, ATIS, ground first.

**hearham's city strings are double-encoded at the source**
(`VÃ¤stra GÃ¶taland`). `_repair()` undoes it when the string round-trips
through latin-1 cleanly and leaves it alone when it does not.

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
│   ├── omasdrd.py         flowgraph, both sockets, presets, CLI. System python3
│   └── nearby.py          the nearby search: sources, cache, geocoding
├── docs/
│   ├── protocol.md        the daemon ↔ UI contract
│   ├── frequencies.md     the frequency reference the help window renders
│   └── media/README.md    how to recapture and publish README shots
├── share/                 what setup.sh copies into $XDG_DATA_HOME
│   ├── applications/
│   │   └── omasdr.desktop the app-selector entry
│   └── icons/hicolor/scalable/apps/
│       └── omasdr.svg     the antenna mark as an app icon
├── scripts/
│   ├── setup.sh           dependency install and device verification
│   ├── omasdr-theme-icon.sh  paints the app icon in the theme's ink; also
│   │                      installed as a theme-set hook
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
    ├── FreqHelp.qml       the frequency reference window
    ├── FreqSearch.qml     the nearby search window
    ├── Session.qml        singleton: connection, theme, on-demand daemon start
    ├── Theme.qml          Omarchy palette, parsed by Toml.js
    ├── AntennaMark.qml    the icon
    ├── Freq.js            the only code that knows about kHz and MHz
    ├── Markdown.js        the markdown subset FreqHelp renders
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

The social card that link previews show is neither: it is a repository
setting uploaded through Settings > General, with no API to automate.
`just social` builds one into `docs/media/social/`, outside the glob the
release upload uses. See `docs/media/README.md`.

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

Open checks:

- [x] **`scripts/setup.sh` on a clean machine or container.** Done
      2026-09-08 in an `archlinux` aarch64 container holding none of the
      packages: all four required packages installed, the DVB blacklist and
      the udev rules landed, and gnuradio 3.10.12.0 and osmosdr imported
      under `/usr/bin/python3`. The device steps are not reachable that way,
      since a container enumerates the dongle through sysfs but cannot claim
      it without USB passthrough, so `rtl_test -t` still rests on the
      maintainer's hardware. The run also turned up an unbound `$USER` under
      `set -u`, fixed the same day.
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

**The app selector entry is an XDG file setup.sh copies (2026-09-08).**
The Omarchy menu's Apps list is fed by `DesktopEntries.applications`
(`/usr/share/omarchy/shell/services/AppLibrary.qml`), so appearing there
means shipping a `.desktop` file, not registering with anything Omarchy
owns. It lives at `share/applications/omasdr.desktop` and `setup.sh`
copies it to `$XDG_DATA_HOME/applications`. Its `Exec` is the same IPC
the bar widget's EXPAND button sends,
`omarchy shell shell toggle com.omasdr.radio {}`, because there is no
standalone binary to launch; the consequence, accepted, is that the entry
does nothing when the Omarchy shell is not running. `setup.sh` never
overwrites an entry that differs from the shipped copy, so a user's own
edits survive an update.

The icon is our own mark, not a stock freedesktop name:
`share/icons/hicolor/scalable/apps/omasdr.svg` redraws the whip and two
arcs of `ui/AntennaMark.qml` as SVG, with heavier strokes (2.2 and 1.9
against the QML's 1.6 and 1.3) because the bar glyph's weight disappears
at app-icon sizes, and with the base lifted off `y=15` so the thicker
round caps stay inside the 16-unit box. The two files are kept in step by
hand; the QML draws on a Canvas at runtime and cannot share a source with
a static file.

**The app icon follows the theme through a hook (2026-09-08).** A flat
white icon reads on every dark theme and vanishes on the light ones
(`catppuccin-latte`, `flexoki-light`, `white`), and a `.desktop` icon is
a file, so it cannot follow a palette on its own. The shipped SVG is
therefore a template in which every colour is `#ffffff`, and
`scripts/omasdr-theme-icon.sh` substitutes the active theme's ink into
the copy under `$XDG_DATA_HOME`. `setup.sh` runs it at install time and
installs it into `~/.config/omarchy/hooks/theme-set.d/`, so a theme
switch repaints it; the shell's `AppLibrary` rescans
`~/.local/share/icons` when the menu opens, so the new colour appears
without restarting anything. The ink is `[menu] text` from the theme's
`shell.toml`, the colour the menu draws its own rows in, falling back to
`[popups] text`, then `colors.toml` `foreground`, then white. The script
reads `~/.local/state/omarchy/current/theme` rather than the slug the
hook is passed in `$1`, because that is the path `ui/Theme.qml` watches
and the icon must not disagree with the running UI. Consequences,
accepted: the installed icon is generated, so edits to it are
overwritten, and unlike the `.desktop` entry it gets no
leave-your-version-alone guard. A hook left behind by a plugin removal
finds no template and exits 0 rather than failing every theme switch.

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
- Commit subjects are conventional commits, `type: summary`. Changes reach
  `main` through a pull request and land squashed under the PR title;
  `main` is protected, and it is what `omarchy plugin add` installs, so it
  stays installable at every commit.
- Any change to the socket protocol updates `docs/protocol.md` in the same
  commit.
- A new device the daemon has been tested with gets notes under
  `~/Projects/3_dev/60_devices/<name>/` and a summary in the README Devices
  section.
