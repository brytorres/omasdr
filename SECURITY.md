# Security

## Reporting

Report a vulnerability privately through GitHub's
[report a vulnerability](https://github.com/brytorres/omasdr/security/advisories/new)
form. Please do not open a public issue for it.

This is a single-maintainer hobby project. Expect a first reply within a
week, and a fix in the next release rather than on a schedule.

## Supported versions

The most recent release only. OmaSDR is pre-1.0 and installs by tracking a
git branch, so `omarchy plugin update` is the upgrade path for every fix.

## What OmaSDR touches

Worth knowing before you look for a hole, and worth saying plainly for
anyone deciding whether to install it:

- **It makes no network connections.** There is no telemetry, no update
  check, and no remote anything. Both sockets are `AF_UNIX`, in
  `$XDG_RUNTIME_DIR/omasdr/`, which is private to your user account.
- **It runs as you**, never as root. The setup script is the one part that
  uses `sudo`, and only to install pacman packages and unload the kernel's
  DVB driver.
- **It reads and writes** `~/.config/omasdr/` (settings, presets), writes
  recordings to `~/Audio/OmaSDR` or wherever you point it, and reads
  `~/.config/gqrx/bookmarks.csv` and `bandplan.csv` if they exist.
- **It opens your SDR dongle** through gr-osmosdr, which needs the udev rule
  the `rtl-sdr` package ships. That rule uses `uaccess`, granting the
  logged-in seat user access without adding anyone to a group.
- **The socket protocol is unauthenticated by design.** Anything that can
  reach the socket can tune and record, which means any process running as
  you. That is the same trust boundary as your files.

The signal processing is GNU Radio and gr-osmosdr, installed from your
distribution. Vulnerabilities in those belong upstream.
