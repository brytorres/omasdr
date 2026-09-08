#!/usr/bin/env bash
# Recolour the OmaSDR app-selector icon to the current Omarchy theme.
#
#   bash scripts/omasdr-theme-icon.sh          write the icon for the active theme
#
# setup.sh runs this at install time and installs it as a theme-set hook, so a
# theme switch repaints the icon. The shell's AppLibrary rescans
# ~/.local/share/icons when the menu opens, so the new colour appears live.
#
# The theme-set hook is passed the new theme slug in $1; this deliberately
# ignores it and reads ~/.local/state/omarchy/current/theme, the same path
# ui/Theme.qml watches, so the icon can never disagree with the running UI.
set -uo pipefail

THEME_DIR="${OMASDR_THEME_DIR:-$HOME/.local/state/omarchy/current/theme}"
REL="icons/hicolor/scalable/apps/omasdr.svg"
OUT="${XDG_DATA_HOME:-$HOME/.local/share}/$REL"

# The template is the flat-white SVG in the plugin: from an explicit root, from
# this script's own checkout, or from the installed plugin when running as the
# hook copy in ~/.config/omarchy/hooks/theme-set.d/.
self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for candidate in \
  "${OMASDR_ROOT:-}/share/$REL" \
  "$self_dir/../share/$REL" \
  "$HOME/.config/omarchy/plugins/com.omasdr.radio/share/$REL"
do
  [[ -f $candidate ]] && { TEMPLATE=$candidate; break; }
done
# No template means no plugin: a stale hook left behind by a removal must not
# fail every theme switch from here on.
[[ -n ${TEMPLATE:-} ]] || exit 0

# First hex literal on the key's line, so `border = "hyprland.active-border"`
# and trailing comments are skipped rather than mistaken for a colour.
toml_hex() { # <file> <section, empty for top level> <key>
  [[ -f $1 ]] || return 1
  awk -v want="$2" -v key="$3" '
    /^[[:space:]]*\[/ { section = $0; gsub(/[][[:space:]]/, "", section); next }
    { line = $0; k = line; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k) }
    section == want && k == key && match(line, /#[0-9a-fA-F]{6}/) {
      print substr(line, RSTART, 7); exit
    }
  ' "$1"
}

# The menu draws its rows in [menu] text; the icon sits among them. Popups and
# the raw palette are the fallbacks, white the last resort.
INK=$(toml_hex "$THEME_DIR/shell.toml" menu text)
[[ $INK =~ ^#[0-9a-fA-F]{6}$ ]] || INK=$(toml_hex "$THEME_DIR/shell.toml" popups text)
[[ $INK =~ ^#[0-9a-fA-F]{6}$ ]] || INK=$(toml_hex "$THEME_DIR/colors.toml" "" foreground)
[[ $INK =~ ^#[0-9a-fA-F]{6}$ ]] || INK="#ffffff"

tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT
sed "s/#ffffff/$INK/g" "$TEMPLATE" >"$tmp" || exit 1

# Only touch the file when the colour actually moved: the icon index is
# rescanned on change, and a no-op rewrite would churn it on every theme set.
if cmp -s "$tmp" "$OUT"; then
  exit 0
fi
mkdir -p "$(dirname "$OUT")" && cp "$tmp" "$OUT"
