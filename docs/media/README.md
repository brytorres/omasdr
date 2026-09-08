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

## The social card

The picture X, Slack, and Discord show when someone links the repository is
not a file here and not a release asset: it is a repository setting, uploaded
by hand at Settings > General > Social preview. There is no REST API and no
`gh` command for it, so it is a one-time click in a browser per change. Left
unset, GitHub generates a card from the repository name, description, and
owner avatar.

Build one from a capture, 1280x640 and well under the 1 MB limit:

```sh
just social ~/Pictures/<capture>.png          # centre crop
just social ~/Pictures/<capture>.png north    # keep the readout, drop the settings row
```

It lands in `docs/media/social/card.png`, outside the `docs/media/*.png` glob
`just media` and `just publish-media` use, so it never rides along into a
release. Those platforms cache cards hard; a replacement can take a day, or a
re-share through the platform's own link debugger, to appear.
