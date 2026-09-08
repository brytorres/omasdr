## What and why

<!-- What changes, and what it fixes or enables. Link an issue if there is one. -->

## Checks

<!-- `just test` runs both. Say if hardware kept part of it from running. -->

- [ ] `bash scripts/check.sh` passes
- [ ] `omarchy plugin validate .` passes
- [ ] Tried in the live shell (`just sync`) or standalone (`just run`)

Tested on: <!-- dongle and OS, e.g. RTL-SDR Blog V4, Arch aarch64 -->

## If this touches...

- [ ] **the daemon's messages** — `docs/protocol.md` is updated in this same commit
- [ ] **anything a user sees** — the README says so
- [ ] **something now settled** — AGENTS.md has a dated decision, or a ticked item under Testing

<!--
The PR title becomes the squashed commit subject on main, so write it as a
conventional commit: `type: summary`, e.g. `fix: keep the daemon alive while
recording`. Merging ships to users, since `omarchy plugin update`
fast-forwards the default branch onto their machines.
-->
