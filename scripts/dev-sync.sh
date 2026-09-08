#!/usr/bin/env bash
# Copy this checkout into the Omarchy plugin directory so the running shell
# loads it. Symlinks are rejected by the plugin validator, so this is a
# real copy; saving under the plugin directory hot-reloads, and re-running
# this script after edits here is the dev loop. --watch keeps syncing on
# every change (needs inotifywait). --remove disables and deletes the copy.
set -euo pipefail
cd "$(dirname "$0")/.."
id=com.omasdr.radio
target="$HOME/.config/omarchy/plugins/$id"

sync_once() {
  mkdir -p "$target"
  local before after
  before=$(sha256sum "$target/daemon/omasdrd.py" 2>/dev/null | cut -c1-16)
  changed=$(rsync -ai --delete --exclude .git --exclude __pycache__ --exclude 'PLAN.md' ./ "$target/" | grep -v '^\.d' || true)
  omarchy plugin validate "$target"
  # The shell's hot reload does not reliably refresh a panel-kind component
  # (the expanded window kept an old layout until a restart), so any UI
  # change restarts the shell. The bar blinks for a second; that is the cost.
  if grep -q ' ui/' <<<"$changed" && [[ ${NO_RESTART:-} != 1 ]]; then
    UI_CHANGED=1
  fi
  after=$(sha256sum "$target/daemon/omasdrd.py" | cut -c1-16)
  # A running daemon keeps executing the old code; stop it so the next play
  # (or popover open) starts the new one. Playback is interrupted on purpose.
  if [[ $before != "$after" ]] && /usr/bin/python3 "$target/daemon/omasdrd.py" status >/dev/null 2>&1; then
    /usr/bin/python3 "$target/daemon/omasdrd.py" stop
    echo "daemon changed: stopped the running daemon (it restarts on the next play)"
  fi
}

case ${1:-} in
  --remove)
    omarchy plugin disable "$id" >/dev/null 2>&1 || true
    rm -rf "$target"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    echo "removed $target"
    ;;
  --watch)
    command -v inotifywait >/dev/null || { echo "inotifywait missing: omarchy pkg add inotify-tools" >&2; exit 1; }
    UI_CHANGED=0; sync_once; echo "synced; watching for changes (ctrl-c to stop)"
    while inotifywait -qq -r -e modify,create,delete,move --exclude '(\.git|__pycache__)' . ; do
      UI_CHANGED=0; sync_once && echo "synced $(date +%H:%M:%S)"
      (( UI_CHANGED )) && omarchy restart shell >/dev/null 2>&1 && echo "restarted the shell"
    done
    ;;
  *)
    # --section left|center|right places the bar widget on first enable, the
    # same choice `omarchy plugin add --enable` asks for interactively.
    # NO_RESTART=1 skips the shell restart after UI changes.
    section=""
    [[ ${1:-} == --section ]] && section="${2:-}"
    UI_CHANGED=0
    sync_once
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    if [[ -n $section ]]; then omarchy plugin enable "$id" --section "$section" >/dev/null 2>&1 || true
    else omarchy plugin enable "$id" >/dev/null 2>&1 || true; fi
    echo "synced $PWD -> $target and enabled $id${section:+ in the $section section}"
    if (( UI_CHANGED )); then
      omarchy restart shell >/dev/null 2>&1 && echo "ui changed: restarted the shell so the new components load"
    fi
    ;;
esac
