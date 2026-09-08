# OmaSDR development and release tasks. Run `just` to list them.
#
# The scripts under scripts/ stay the source of truth for what these do;
# every recipe here is a shortcut to one of them, not a second implementation.

id := "com.omasdr.radio"
version := `jq -r .version manifest.json`
py := "/usr/bin/python3"
log := `echo "${XDG_RUNTIME_DIR:-/tmp}/omasdr/daemon.log"`

[private]
default:
    @just --list --unsorted

# Copy this checkout into the live shell and enable it (--section, --watch, --remove).
[group('dev')]
sync *ARGS:
    bash scripts/dev-sync.sh {{ARGS}}

# Keep syncing on every change until ctrl-c (needs inotify-tools).
[group('dev')]
watch:
    bash scripts/dev-sync.sh --watch

# Disable and delete the copy in the plugin directory.
[group('dev')]
unsync:
    bash scripts/dev-sync.sh --remove

# Open the expanded window standalone, without the Omarchy shell.
[group('dev')]
run *ARGS:
    bash scripts/run.sh {{ARGS}}

# Restart the shell so it picks up changed UI components.
[group('dev')]
restart:
    omarchy restart shell

# Say whether a daemon is running, and its pid.
[group('daemon')]
status:
    @{{py}} daemon/omasdrd.py status

# Stop the running daemon; the next play starts a fresh one.
[group('daemon')]
stop:
    @{{py}} daemon/omasdrd.py stop

# List RTL-SDR devices and say who is holding them.
[group('daemon')]
devices:
    @{{py}} daemon/omasdrd.py devices

# Follow the daemon log.
[group('daemon')]
log:
    tail -f {{log}}

# Walk the protocol against a scratch daemon (most of it needs no hardware).
[group('check')]
check:
    bash scripts/check.sh

# Run the manifest check the shell applies.
[group('check')]
validate:
    omarchy plugin validate .

# Both checks. AGENTS.md: run this before every commit and before tagging.
[group('check')]
test: check validate

# Verify every assumption OmaSDR makes, installing nothing.
[group('check')]
doctor:
    bash scripts/setup.sh --check

# Install missing packages and verify the dongle.
[group('check')]
setup:
    bash scripts/setup.sh

# Downscale a capture into docs/media, e.g. `just shot ~/Pictures/x.png window`.
[group('media')]
shot SRC NAME:
    @mkdir -p docs/media
    magick {{SRC}} -resize 1600x -strip -colors 256 -depth 8 docs/media/{{NAME}}.png
    @ls -lh docs/media/{{NAME}}.png

# Show what is waiting in docs/media for the next upload.
[group('media')]
media:
    @ls -lh docs/media/*.png 2>/dev/null || echo "no captures in docs/media"

# Upload docs/media to the release the README images point at.
[group('media')]
publish-media:
    gh release upload v{{version}} --clobber docs/media/*.png

# Print the version every recipe here reads, from manifest.json.
[group('release')]
version:
    @echo {{version}}

# Set a new version in manifest.json and the three places the README repeats it.
[group('release')]
bump NEW:
    #!/usr/bin/env bash
    set -euo pipefail
    old={{version}}
    new={{NEW}}
    [[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: $new" >&2; exit 1; }
    {{py}} - "$old" "$new" <<'PY'
    import io, json, sys
    old, new = sys.argv[1], sys.argv[2]
    m = json.load(io.open("manifest.json", encoding="utf-8"))
    m["version"] = new
    io.open("manifest.json", "w", encoding="utf-8").write(json.dumps(m, indent=2) + "\n")
    r = io.open("README.md", encoding="utf-8").read()
    subs = [
        ("[![version %s]" % old,         "[![version %s]" % new),
        ("badge/version-%s-" % old,      "badge/version-%s-" % new),
        ("Beta, at `v%s`" % old,         "Beta, at `v%s`" % new),
        ("releases/download/v%s/" % old, "releases/download/v%s/" % new),
    ]
    for a, b in subs:
        if a not in r:
            sys.exit("README.md: could not find %r -- bump it by hand" % a)
        r = r.replace(a, b)
    io.open("README.md", "w", encoding="utf-8").write(r)
    PY
    echo "bumped $old -> $new in manifest.json and README.md"
    echo "next: review the diff, commit it, then: just release"

# Tag the committed version, push, publish the GitHub release, upload the media.
[group('release')]
[confirm("Tag, push, and publish this version as a GitHub release?")]
release:
    #!/usr/bin/env bash
    set -euo pipefail
    v=v{{version}}
    [[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first" >&2; exit 1; }
    just test
    git tag -a "$v" -m "OmaSDR $v" 2>/dev/null || echo "tag $v already exists, reusing it"
    git push origin HEAD "$v"
    gh release create "$v" --title "OmaSDR $v" --generate-notes 2>/dev/null \
      || echo "release $v already exists, reusing it"
    if compgen -G "docs/media/*.png" >/dev/null; then
      gh release upload "$v" --clobber docs/media/*.png
    else
      echo "no docs/media/*.png to upload; the README images will 404"
    fi
    gh release view "$v" --web
