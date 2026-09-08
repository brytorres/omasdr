# README media

The pictures the README shows are not in the repository. `omarchy plugin add`
clones the whole default branch onto every user's disk, so media travels as
assets on the plugin's GitHub Release (`v0.1.0`) and the README links to them
by URL. This directory is ignored except for this file.

The three shots, all taken live on an RTL-SDR Blog V4:

- `window.png`: the expanded window on 104.1 MHz WFM stereo, showing the
  spectrum, the waterfall, the bandplan label, and the receiver settings.
- `popover.png`: the bar popover on NOAA weather radio, 162.55 MHz NFM,
  with presets and the signal meter.
- `desktop.png`: the window tiled beside omastorm, both plugins on the same
  Omarchy theme.

Recapture by hand with the Omarchy screenshot binding, then downscale to
1600 px wide and quantize, which keeps text crisp and cuts each file to
roughly a third:

```sh
just shot ~/Pictures/<capture>.png <name>
```

Publish with `just publish-media` (or `gh release upload v0.1.0 --clobber
docs/media/*.png`) and keep the README URLs pointing at that tag.
