# README media

The pictures the README shows are not in the repository. `omarchy plugin add`
clones the whole default branch onto every user's disk, so media travels as
assets on the plugin's GitHub Release and the README links to them by URL,
pinned to the matching tag. This directory is ignored except for this file.

**Every shot has to be retaken whenever the UI it shows changes**, because
`just bump` repoints the README at the new tag's assets. A stale screenshot is
worse than none: it shows a reader controls that are no longer there.

The shots, all taken live on an RTL-SDR Blog V4:

- `window.png`: the expanded window on 104.1 MHz WFM stereo, showing the
  spectrum, the waterfall, the bandplan label, and the receiver settings.
- `popover.png`: the bar popover on NOAA weather radio, 162.55 MHz NFM,
  with presets and the signal meter.
- `desktop.png`: the window tiled beside omastorm, both plugins on the same
  Omarchy theme.
- `help.png`: the frequency reference window, scrolled to a section with a
  table in it so the formatting shows.
- `search.png`: the nearby search with results, showing both the airband and
  the repeater sections and the markers painted over the spectrum behind it.

Recapture by hand with the Omarchy screenshot binding, then downscale to
1600 px wide and quantize, which keeps text crisp and cuts each file to
roughly a third:

```sh
just shot ~/Pictures/<capture>.png <name>
```

Publish with `just publish-media`, which uploads to the release for the
version in `manifest.json`, and keep the README URLs pointing at that tag.
`just release` does the same upload as its last step.

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
