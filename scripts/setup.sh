#!/usr/bin/env bash
# OmaSDR setup: install what the daemon needs and verify the dongle.
# Idempotent. Run it from a terminal; it uses sudo where it must.
#
#   bash scripts/setup.sh          install missing packages, then verify
#   bash scripts/setup.sh --check  verify only, install nothing, unload nothing
#
# Exit status is non-zero when any check fails. The daemon runs --check when it
# cannot start for a dependency reason, and the popover shows the result.
set -uo pipefail

CHECK_ONLY=0
[[ ${1:-} == --check ]] && CHECK_ONLY=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

REQUIRED=(rtl-sdr gnuradio-osmosdr usbutils psmisc)
OPTIONAL=(gqrx)

pass=() ; fail=() ; warn=()
ok()   { pass+=("$1"); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { warn+=("$1"); printf '  \033[33m!\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

step "Packages"
missing=()
for p in "${REQUIRED[@]}"; do
  if pacman -Q "$p" >/dev/null 2>&1; then ok "$p $(pacman -Q "$p" | awk '{print $2}')"; else missing+=("$p"); fi
done
if (( ${#missing[@]} )); then
  if (( CHECK_ONLY )); then
    bad "missing: ${missing[*]} (run: bash scripts/setup.sh)"
  else
    echo "  installing: ${missing[*]}"
    echo "  note: gnuradio depends on libuhd, which pulls dpdk (about 280 MiB). That is expected."
    if command -v omarchy >/dev/null 2>&1; then
      omarchy pkg add "${missing[@]}"
    else
      sudo pacman -S --needed "${missing[@]}"
    fi
    for p in "${missing[@]}"; do
      if pacman -Q "$p" >/dev/null 2>&1; then ok "$p installed"; else bad "$p failed to install"; fi
    done
    FRESH_INSTALL=1
  fi
fi
for p in "${OPTIONAL[@]}"; do
  if pacman -Q "$p" >/dev/null 2>&1; then ok "$p (optional, for bookmark import)"; else note "$p not installed (optional: omarchy pkg add gqrx, only for importing its bookmarks)"; fi
done

step "Kernel driver"
# The rtl-sdr package ships /usr/lib/modprobe.d/rtlsdr.conf blacklisting the
# DVB driver, but a module that was already bound stays bound until unloaded.
if lsmod | grep -q '^dvb_usb_rtl28xxu'; then
  if (( CHECK_ONLY )); then
    bad "dvb_usb_rtl28xxu is loaded and will hold the dongle (run: sudo modprobe -r dvb_usb_rtl28xxu)"
  else
    echo "  unloading dvb_usb_rtl28xxu"
    if sudo modprobe -r dvb_usb_rtl28xxu; then ok "dvb_usb_rtl28xxu unloaded"; else bad "could not unload dvb_usb_rtl28xxu"; fi
  fi
else
  ok "DVB driver not bound"
fi
if [[ -f /usr/lib/modprobe.d/rtlsdr.conf || -f /etc/modprobe.d/blacklist-rtl-sdr.conf ]]; then
  ok "DVB blacklist present"
else
  note "no DVB blacklist file found; the rtl-sdr package normally ships one"
fi

step "udev"
if [[ -f /usr/lib/udev/rules.d/10-rtl-sdr.rules ]]; then
  ok "10-rtl-sdr.rules installed (uaccess: logged-in users need no group)"
  if [[ ${FRESH_INSTALL:-0} == 1 ]]; then
    sudo udevadm control --reload-rules && sudo udevadm trigger
    note "rules reloaded: unplug and replug the dongle so the new permissions apply"
  fi
else
  bad "udev rules missing; reinstall rtl-sdr"
fi
if [[ -z ${XDG_SESSION_TYPE:-} || ${XDG_SESSION_TYPE:-} == tty ]] && ! id -nG | grep -qw rtlsdr; then
  note "no graphical seat detected: for SSH or headless use add yourself to the rtlsdr group (sudo usermod -aG rtlsdr ${USER:-$(id -un)})"
fi

step "Device"
if command -v lsusb >/dev/null 2>&1 && lsusb | grep -qi '0bda:283[28]'; then
  ok "$(lsusb | grep -i '0bda:283[28]' | head -1 | sed 's/^Bus [0-9]* Device [0-9]*: //')"
  DEVICE_PRESENT=1
else
  bad "no RTL-SDR on USB (0bda:2838). Plug it straight into the machine: some USB-C hubs do not pass it through and give no error at all."
  DEVICE_PRESENT=0
fi

if (( DEVICE_PRESENT )); then
  step "Driver claim (rtl_test -t)"
  usb_node=$(lsusb | grep -i '0bda:283[28]' | head -1 | sed -E 's|Bus ([0-9]+) Device ([0-9]+):.*|/dev/bus/usb/\1/\2|')
  holder=$(fuser "$usb_node" 2>/dev/null | tr -s ' ' | sed 's/^ //')
  if [[ -n $holder ]]; then
    names=$(for pid in $holder; do cat "/proc/$pid/comm" 2>/dev/null; done | sort -u | tr '\n' ' ')
    note "device is held by: ${names:-pid $holder}. Close it to run the tuner check."
  else
    out=$(timeout 8 rtl_test -t 2>&1)
    if grep -q 'Found Rafael Micro\|Found Elonics\|Found Fitipower\|Found FCI' <<<"$out"; then
      ok "$(grep -m1 'Found .* tuner' <<<"$out")"
      grep -q 'Blog V4 Detected' <<<"$out" && ok "RTL-SDR Blog V4 detected"
      ok "\"No E4000 tuner found, aborting\" at the end is expected and harmless"
    else
      bad "rtl_test could not claim the device:"
      sed 's/^/      /' <<<"$out" | tail -5
    fi
  fi
fi

step "Python bindings (system /usr/bin/python3)"
if /usr/bin/python3 - <<'PY' 2>/dev/null
from gnuradio import gr, analog, audio, filter, fft, blocks
import osmosdr
print("  gnuradio", gr.version())
PY
then ok "gnuradio and osmosdr import"; else bad "python-gnuradio or gnuradio-osmosdr bindings missing for /usr/bin/python3"; fi

step "Desktop entry"
# Puts OmaSDR in the app selector (SUPER+SPACE, Apps): the XDG entry and the
# icon it names. The entry's Exec is the shell IPC the bar's EXPAND button
# sends, so it needs the Omarchy shell running; there is no standalone binary
# behind it. An existing file that differs is left alone, so local edits
# survive an update.
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
install_share() { # <relative path under share/> <label>
  local src="$ROOT/share/$1" dest="$data_home/$1"
  if [[ ! -f $src ]]; then
    note "shipped $2 missing at $src"
  elif [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    ok "$2 installed"
  elif [[ -f $dest ]]; then
    note "$dest differs from the shipped copy; leaving your version alone"
  elif (( CHECK_ONLY )); then
    note "$2 not installed (run: bash scripts/setup.sh)"
  else
    mkdir -p "$(dirname "$dest")"
    if cp "$src" "$dest"; then ok "$2 installed"; else bad "could not write $dest"; fi
  fi
}
install_share applications/omasdr.desktop "app selector entry"
if (( ! CHECK_ONLY )) && command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$data_home/applications" >/dev/null 2>&1
fi

# The icon is generated rather than copied: omasdr-theme-icon.sh paints the
# shipped white template in the active theme's colour, so it stays legible on
# the light themes too. Edits to the installed file are overwritten by design.
icon_src="$ROOT/share/icons/hicolor/scalable/apps/omasdr.svg"
icon="$data_home/icons/hicolor/scalable/apps/omasdr.svg"
if [[ ! -f $icon_src ]]; then
  note "shipped app icon missing at $icon_src"
elif (( CHECK_ONLY )); then
  if [[ -f $icon ]]; then ok "app icon installed"; else note "app icon not installed (run: bash scripts/setup.sh)"; fi
elif bash "$ROOT/scripts/omasdr-theme-icon.sh" && [[ -f $icon ]]; then
  ok "app icon installed ($(grep -o '#[0-9a-fA-F]\{6\}' "$icon" | head -1))"
else
  bad "could not write $icon"
fi

# Same script as a theme-set hook, so a theme switch repaints the icon.
hook_src="$ROOT/scripts/omasdr-theme-icon.sh"
hook_dest="$HOME/.config/omarchy/hooks/theme-set.d/omasdr-theme-icon.sh"
if [[ ! -f $hook_src ]]; then
  note "theme hook script missing at $hook_src"
elif [[ -f $hook_dest ]] && cmp -s "$hook_src" "$hook_dest"; then
  ok "theme-set hook installed"
elif (( CHECK_ONLY )); then
  note "theme-set hook missing or out of date (run: bash scripts/setup.sh)"
elif command -v omarchy >/dev/null 2>&1 && omarchy hook install theme-set "$hook_src" >/dev/null 2>&1; then
  ok "theme-set hook installed"
else
  mkdir -p "$(dirname "$hook_dest")"
  if cp "$hook_src" "$hook_dest" && chmod 755 "$hook_dest"; then
    ok "theme-set hook installed"
  else
    bad "could not install the theme-set hook"
  fi
fi

step "Summary"
printf '  %d passed, %d warnings, %d failed\n' "${#pass[@]}" "${#warn[@]}" "${#fail[@]}"
(( ${#fail[@]} == 0 ))
