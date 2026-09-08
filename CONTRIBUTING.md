# Contributing to OmaSDR

Read [AGENTS.md](AGENTS.md) first. It holds the settled decisions, the open
tests, and the conventions, and it explains *why* several non-obvious things
are the way they are. This file is about getting a working development
setup.

## Layout

```
manifest.json          Omarchy plugin manifest (id com.omasdr.radio)
daemon/omasdrd.py      the whole daemon: flowgraph, sockets, presets, CLI
docs/protocol.md       the daemon <-> UI contract
ui/RadioBar.qml        bar-widget entry: antenna mark and popover host
ui/Popover.qml         the tuner card, shared by the bar and the window
ui/RadioWindow.qml     the expanded window; ui/Panel.qml is its plugin entry
ui/Spectrum.qml        spectrum plot and waterfall
ui/Engine.qml          control socket client; ui/FftStream.qml the spectrum one
ui/Session.qml         singleton owning the connection, theme, and daemon start
ui/Freq.js             the only code that knows about kHz and MHz
ui/AntennaMark.qml     the icon; ui/Theme.qml reads the Omarchy palette
scripts/setup.sh       dependency install and device verification
scripts/check.sh       protocol walk against a scratch daemon
scripts/dev-sync.sh    copy the checkout into the live shell
scripts/run.sh         open the window without the shell
```

## Prerequisites

Omarchy with its Quickshell shell, an RTL-SDR dongle, and the packages the
setup script installs:

```sh
bash scripts/setup.sh
```

The daemon uses the system interpreter at `/usr/bin/python3` on purpose:
GNU Radio's Python bindings ship as pacman packages and do not install
through pip. If you use mise, pyenv, or a venv, they must not shadow it.

## Run the plugin in the live shell

The repository *is* the plugin, but the shell's validator rejects symlinks
inside the plugin directory, so development uses a copy:

```sh
bash scripts/dev-sync.sh                  # copy in, validate, rescan, enable
bash scripts/dev-sync.sh --section left   # same, choosing the bar section
bash scripts/dev-sync.sh --watch          # resync on every save (inotify-tools)
bash scripts/dev-sync.sh --remove         # disable and delete the copy
```

The loop is: edit here, sync, look at the bar.

The shell's own hot reload is not enough for this plugin. It keeps the
`Session` singleton and its timers alive, and it serves a stale
`RadioWindow` to the expanded window. So `dev-sync.sh` restarts the shell
whenever anything under `ui/` changed, and says so. The bar blinks for a
second. `NO_RESTART=1` skips it when you know the change is safe.

Syncing a changed `daemon/omasdrd.py` also stops a running daemon, since it
would otherwise keep executing the old code. It restarts on the next play.

Watch the shell's log while you work:

```sh
journalctl --user -u omarchy-shell -f
```

If a QML error leaves the widget blank, the message is there. Quickshell
also writes its own log; read the newest with:

```sh
quickshell log "$(ls -t $XDG_RUNTIME_DIR/quickshell/by-id/*/log.qslog | head -1)"
```

## Run the window standalone

The expanded window does not need the shell at all, which makes it the
fastest way to iterate on the spectrum and the tuner card:

```sh
bash scripts/run.sh
```

It starts the daemon on demand, exactly as the plugin does. The bar widget
needs the shell's `qs.Ui` components, so that one can only be tested
through `dev-sync.sh`.

## Talk to the daemon by hand

```sh
/usr/bin/python3 daemon/omasdrd.py devices   # what is plugged in, who holds it
/usr/bin/python3 daemon/omasdrd.py ensure    # start in the background
/usr/bin/python3 daemon/omasdrd.py status
/usr/bin/python3 daemon/omasdrd.py stop
tail -f "$XDG_RUNTIME_DIR/omasdr/daemon.log"
```

One-off commands over the socket:

```sh
printf '{"type":"set_frequency","frequency":101100000}\n' |
  socat - "UNIX-CONNECT:$XDG_RUNTIME_DIR/omasdr/control.sock"
```

The full contract is [docs/protocol.md](docs/protocol.md). Any change to the
daemon's messages updates that file in the same commit.

## Branches and commits

**`main` is what users install.** `omarchy plugin add` clones the default
branch onto their disk and `omarchy plugin update` fast-forwards it, so
there is no staging between a merge and a stranger's bar widget. Keep `main`
installable at every commit: it is protected against force-pushes and
deletion, and changes arrive through a pull request.

Work on a branch, open a PR, and it lands as a single squashed commit whose
subject is the PR title.

Commit subjects are [conventional commits](https://www.conventionalcommits.org),
`type: summary` in the imperative:

```
feat: add RDS station name to the popover
fix: keep the daemon alive while recording
docs: explain the dpdk download size
chore: bump the manifest to 0.2.0
```

`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, and `chore` cover
everything here. Because the PR title becomes the commit subject, write the
title that way too.

Two rules from AGENTS.md that a PR is checked against:

- A change to the daemon's messages updates `docs/protocol.md` in the same
  commit.
- Something newly settled gets a dated decision in AGENTS.md, and a closed
  question ticks its item under Testing.

## Check before you commit

```sh
bash scripts/check.sh          # protocol walk against a scratch daemon
omarchy plugin validate .      # the manifest check the shell applies
```

`just test` runs both; `just` on its own lists every other shortcut.

`check.sh` covers tuning, stepping, demod switching, presets, and refusal
cases with no hardware. With a free dongle it also plays, reads the tuner's
gain steps, streams spectrum frames, and records a WAV it then verifies. It
runs on a private runtime and config directory, so it never touches your
presets or a daemon you have running.

## Things that will bite you

All of these are already handled in the code; this is so you do not undo
them by accident. [AGENTS.md](AGENTS.md) has the full reasoning.

- **Python GNU Radio blocks must stay referenced from Python.** The block
  gateway holds a non-owning handle, so a block passed straight into
  `connect()` is freed and the scheduler segfaults. `Receiver._blocks`
  exists only to hold them.
- **Quickshell's canvas ignores `putImageData`.** The waterfall paints rows
  as `fillRect` runs instead.
- **A canvas-to-canvas `drawImage` takes device pixels** on both rectangles,
  not logical ones, and a canvas drawn onto *itself* reads rows it has
  already overwritten. That is why the waterfall is two canvases that
  ping-pong.
- **Nested Qt layouts fill by default.** Rows in the window that should stay
  compact say `Layout.fillHeight: false` on purpose.
- **Frequencies are integer hertz** everywhere: code, config, and the wire.
  Only `ui/Freq.js` converts to kHz or MHz.

## Conventions

- Reuse GNU Radio blocks before writing any signal processing yourself.
- Never edit `/usr/share/omarchy/`; read it freely for reference.
- Add a dated decision to AGENTS.md when you settle something new, and tick
  an item under its Testing section when you close one.
