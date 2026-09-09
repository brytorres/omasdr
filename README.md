# OmaSDR

[![version 0.3.0](https://img.shields.io/badge/version-0.3.0-0f766e?style=flat-square)](https://github.com/brytorres/omasdr/releases)
[![status: beta](https://img.shields.io/badge/status-beta-f59e0b?style=flat-square)](#status)
[![license: MIT](https://img.shields.io/badge/license-MIT-64748b?style=flat-square)](LICENSE)
[![Omarchy plugin](https://img.shields.io/badge/Omarchy-plugin-1793d1?style=flat-square&logo=archlinux&logoColor=white)](https://omarchy.org)
[![GNU Radio](https://img.shields.io/badge/GNU%20Radio-daemon-a42e2b?style=flat-square)](https://www.gnuradio.org)
[![RTL-SDR Blog V4](https://img.shields.io/badge/RTL--SDR-Blog%20V4%20tested-475569?style=flat-square)](#hardware)

A software-defined radio receiver that lives in your Omarchy bar. Click the
antenna, type a frequency, press play.

OmaSDR is an Omarchy shell plugin plus a small headless daemon built on GNU
Radio. Treat it as an extension of [gqrx](https://gqrx.dk) rather than a
replacement for it. It reuses gqrx's bookmarks and bandplan, and it
deliberately does not reimplement everything gqrx does, so expect the
everyday things to be here and the deep ones not to be. What you get instead
is a radio that is always one click away and never needs a window open.

If something you want is missing, [open an
issue](https://github.com/brytorres/omasdr/issues) and say what you were
trying to do. That is the right response to a gap, not a surprise.

![The OmaSDR window: spectrum and waterfall across the FM broadcast band, tuned to 104.1 MHz in WFM stereo](https://github.com/brytorres/omasdr/releases/download/v0.3.0/window.png)

## What you get

- **A bar widget.** An antenna that lights up while you are receiving.
  Middle-click plays and stops. Scroll on it to step frequency.
- **A tuner popover.** Type a frequency in kHz or MHz, scroll or arrow to
  step, pick a demodulator, save presets, record, and watch a signal meter.
- **A full window.** A live spectrum plot and waterfall across the whole
  sampled band. Click the plot to tune there.
- **Eight demodulators.** WFM, WFM stereo, NFM, AM, USB, LSB, CW, and raw.
- **Recording.** One button writes stereo WAV files to `~/Audio/OmaSDR`.
- **A frequency reference.** A searchable window of what to listen to and
  which mode to use, written for somewhere in the world rather than one
  country.
- **A search for what is near you.** Type a town and get the local airport's
  tower and ATIS and the repeaters around you, ready to save as presets. No
  account, no API key, and it never asks where you are without being told.
- **A daemon that gets out of the way.** It starts when you need it and
  exits after ten idle minutes, unless you ask it to stay.

Everything follows your Omarchy theme, waterfall colours included.

![The tuner popover in the bar, on NOAA weather radio at 162.55 MHz in NFM](https://github.com/brytorres/omasdr/releases/download/v0.3.0/popover.png)

*The popover: everything you need without a window open.*

![The OmaSDR window tiled beside the omastorm radar window, both on the same Omarchy theme](https://github.com/brytorres/omasdr/releases/download/v0.3.0/desktop.png)

*Beside [omastorm](https://github.com/wesleygrimes/omastorm), on the same theme.*

![The frequency reference window, showing a table of monitoring targets with their frequencies and modes](https://github.com/brytorres/omasdr/releases/download/v0.3.0/help.png)

*FREQ HELP: what to listen to and which mode to use, searchable, and yours to
edit.*

![The nearby search, listing airband frequencies and repeaters near a town with their distances](https://github.com/brytorres/omasdr/releases/download/v0.3.0/search.png)

*FREQ SEARCH: the local tower and the repeaters around you, one click from
being presets.*

## Status

Beta, at `v0.3.0`. Everything listed above is in use daily on the
maintainer's machine, but that is one dongle on one distribution, and the
setup script has never run on a system that was missing packages. Expect
rough edges, and please report them. The daemon protocol is settled and
changes to it stay additive, so an older client keeps working.

## Hardware

**Tested:** the [RTL-SDR Blog V4](https://www.rtl-sdr.com/v4/). That is the
only dongle this has actually been used with, on Arch Linux ARM under Asahi.

**Should work unchanged:** any RTL2832U dongle that reports USB id
`0bda:2838` or `0bda:2832`. That covers the RTL-SDR Blog V3, NooElec sticks,
and most generic R820T2 dongles. Only the tuner differs; everything above it
is the same code path. If you try one, please open an issue and say how it
went.

**Not found yet:** rebadged RTL dongles that report some other USB id, and
every non-RTL radio. The signal-processing layer underneath is
[gr-osmosdr](https://osmocom.org/projects/gr-osmosdr/wiki), which already
speaks HackRF, Airspy, bladeRF, USRP, SDRplay through SoapySDR, and
`rtl_tcp`. Only the device detection is RTL-only. Broadening it is on the
roadmap; see [AGENTS.md](AGENTS.md).

## Install

You need Omarchy with its Quickshell shell, and one of the dongles above.

```sh
omarchy plugin add https://github.com/brytorres/omasdr --enable
bash ~/.config/omarchy/plugins/com.omasdr.radio/scripts/setup.sh
```

The installer asks which bar section the antenna should sit in. Move it
later with `omarchy bar move com.omasdr.radio --section left`.

The setup script does the rest: installs missing packages, unbinds the
kernel's TV driver if it grabbed your dongle, checks udev, finds the device,
runs `rtl_test`, confirms the Python bindings, and adds OmaSDR to your app
selector with an icon that follows your theme. Run it again whenever you want; it only installs what is missing,
and `--check` verifies without changing anything.

It installs these, all from the Arch `extra` repository:

| Package | Why |
|---|---|
| `rtl-sdr` | driver, udev rules, `rtl_test` |
| `gnuradio-osmosdr` | opens the dongle; pulls in `gnuradio` and `python-gnuradio` |
| `usbutils` | `lsusb`, to find the dongle |
| `psmisc` | `fuser`, to tell you which program is holding the dongle |

Expect a big first download. `gnuradio` depends on `libuhd`, which pulls in
`dpdk` at around 280 MiB. Nothing has gone wrong.

Then click the antenna in your bar, or open OmaSDR from the app selector
(SUPER+SPACE, then Apps), which opens the expanded window straight away.

## Updating

```sh
omarchy plugin update com.omasdr.radio   # omit the id to update every plugin
omarchy restart shell
```

The restart matters. The shell caches plugin components, so without it the
bar and the expanded window can keep running the version you had before.

The receiver daemon is separate, and it keeps running whatever code it
started with. After an update the popover notices the mismatch and offers a
**restart** button, which stops the old daemon so the next play starts the
new one. Your presets, settings, and recordings are untouched by any of this.

## Using it

Tune to a local FM station to prove it works: type `101.1`, press Enter,
choose **WFM stereo**, press **PLAY**.

- **Frequency.** Type a number and press Enter. The button beside the field
  switches between MHz and kHz and remembers your choice. A unit in the text
  wins over the button, so `162.55m` and `162550k` both reach the same
  weather channel.
- **Stepping.** Scroll on the field or press Up and Down. The step follows
  the demodulator: 100 kHz for WFM, 12.5 kHz for NFM, 10 kHz for AM, 1 kHz
  for sideband, 100 Hz for CW.
- **Presets.** The star saves where you are, under a name. Click one to go
  back. Saving on top of an existing preset asks first.
- **Record.** The red button writes a stereo 16-bit WAV to `~/Audio/OmaSDR`,
  named by time, frequency, and mode. It needs playback running, and stops
  when playback does. Change the folder in the full window.
- **The spectrum.** Expand to see the whole band the dongle is sampling.
  The red line is where you are tuned, the shaded strip is the passband you
  are listening through. Click anywhere to tune there, scroll to step, hover
  for a frequency readout.
- **Frequency help.** **FREQ HELP**, under the presets, opens a reference
  window: which mode to use where, how long to cut an antenna, and what is
  worth tuning, with the regional differences marked. Type in its search box
  to narrow it to one thing. It is
  [docs/frequencies.md](docs/frequencies.md) in the plugin folder and the
  window follows the file as you edit it, so your own notes can live there.
  Float it or tile it like any other window.
- **Near you.** **FREQ SEARCH**, beside FREQ HELP, asks what is worth hearing
  where you are. Type a town, a postcode, a Maidenhead grid square like
  `IO91wm`, or a coordinate pair; nothing is detected about you and nothing is
  sent anywhere except the place you type. You get the nearest airband
  frequencies — tower, ATIS, ground — and the nearest analogue FM repeaters,
  each with its distance, offset and CTCSS tone. Click a row to tune it, the
  star to keep it, or **add all** to fill your presets with the frequencies
  of where you actually live. Digital repeaters (DMR, D-STAR, YSF, P25) are
  left out because OmaSDR cannot decode them.

  The data comes from [OurAirports](https://ourairports.com/data/) (public
  domain) and [hearham.com](https://hearham.com/repeaters), downloaded the
  first time you search and cached under `~/.cache/omasdr`. After that it
  works offline, and the **REFRESH** button fetches it again. Places are resolved by
  [Nominatim](https://nominatim.openstreetmap.org/); a grid square or a
  coordinate pair never leaves your machine at all.
- **Gain.** OmaSDR starts at a fixed 25.4 dB. The tuner's own automatic gain
  is in the full window, but it pumps and distorts on strong stations, so a
  fixed value usually sounds better. A dongle at zero gain looks exactly
  like a dead one: flat noise, no stations.

## Optional: gqrx

**You do not need gqrx.** OmaSDR runs on its own. Installing it buys you two
things, and one of them does not even need gqrx itself.

**Bandplan labels** on the spectrum plot, naming the amateur, aviation, and
broadcast segments you are looking at. OmaSDR reads
`~/.config/gqrx/bandplan.csv`, and no package ships that file, so put it
there yourself:

```sh
mkdir -p ~/.config/gqrx
curl -o ~/.config/gqrx/bandplan.csv \
  https://raw.githubusercontent.com/gqrx-sdr/gqrx/master/resources/bandplan.csv
```

That works whether or not gqrx is installed. The file that ships upstream
covers the United States; edit it for your country.

**Bookmark import.** If you already keep bookmarks in gqrx, the `gqrx`
button in the popover pulls them in as presets. Run it as often as you like:
it only adds frequencies you do not already have, and never overwrites a
preset you have edited. This one needs gqrx, since gqrx writes the
bookmarks file:

```sh
omarchy pkg add gqrx
```

**One program at a time.** An RTL-SDR can only be opened by one process. If
gqrx (or `rtl_tcp`, or `rtl_433`) is holding your dongle, OmaSDR says so by
name and refuses to play. Close the other program and press play again. It
works the other way too, so stop OmaSDR before starting gqrx.

## Troubleshooting

**"No device."** Plug the dongle straight into the machine. Some USB-C hubs
silently fail to pass it through, with nothing in `lsusb` and nothing in
`dmesg`. Try a different port before anything else.

**"Held by ..."** Another program has the dongle. The message names it.

**I updated and nothing changed.** Run `omarchy restart shell`. The shell
caches plugin components, so the bar widget and the windows keep running the
code they started with until it restarts. If a version notice is still in the
popover afterwards, it is the *daemon* that is stale, not the shell: press the
**restart** button in that notice and play again. See
[Updating](#updating).

**It plays but sounds terrible.** Check the demodulator matches the signal:
WFM stereo for broadcast FM, NFM for ham and public safety, AM for airband.
Then try a gain step or two either way in the full window.

**Nothing at all on HF (below 28.8 MHz), on a V4.** Just tune to the
frequency you want. Do not enable direct sampling and do not set an LNB
offset; that is V3 advice. The V4's upconverter is handled in the driver
already.

**Frequencies are slightly off.** Set ppm correction in the full window. The
V4's temperature-compensated oscillator needs 0 to 1. Older dongles drift by
tens of ppm; `rtl_test -p` estimates yours.

**`rtl_test -t` only works with sudo.** The udev rules did not apply. Rerun
the setup script and replug the dongle.

For anything else, `bash scripts/setup.sh --check` prints a pass/fail report
of every assumption OmaSDR makes.

## Where things are saved

| File | What |
|---|---|
| `~/.config/omasdr/settings.json` | frequency, demod, gain, ppm, sample rate, squelch, volume, recordings folder |
| `~/.config/omasdr/presets.json` | your presets |
| `~/.config/omasdr/ui.json` | the kHz/MHz choice |
| `~/Audio/OmaSDR/` | recordings, unless you moved the folder |
| `~/.cache/omasdr/nearby-*.json` | the airband and repeater data FREQ SEARCH uses; safe to delete |
| `~/.local/share/applications/omasdr.desktop` | the app selector entry |
| `~/.local/share/icons/hicolor/scalable/apps/omasdr.svg` | its icon, repainted on each theme change |
| `~/.config/omarchy/hooks/theme-set.d/omasdr-theme-icon.sh` | the hook that repaints it |

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers local development.
[AGENTS.md](AGENTS.md) holds the design decisions and the roadmap.
[docs/protocol.md](docs/protocol.md) documents the daemon's socket protocol,
which anything can speak, not just this plugin.
[docs/frequencies.md](docs/frequencies.md) is the frequency reference the
help window renders; corrections and additions for regions this misses are
very welcome.

## Credits

FREQ SEARCH is only as good as the people who keep its data:
[OurAirports](https://ourairports.com/data/), which puts 80,000 airports and
their frequencies in the public domain, and
[hearham.com](https://hearham.com/repeaters), which publishes an open repeater
listing for anyone to use. Place lookup is
[Nominatim](https://nominatim.openstreetmap.org/), from OpenStreetMap.
Neither dataset is redistributed here; OmaSDR fetches it on your machine when
you ask it to.

## License

MIT. See [LICENSE](LICENSE).
