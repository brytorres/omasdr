#!/usr/bin/env bash
# Open the expanded window standalone (no Omarchy shell needed). The daemon
# is started on demand by the window itself.
set -euo pipefail
cd "$(dirname "$0")/.."
export OMASDR_ROOT="$PWD"
exec quickshell -p ui/shell.qml "$@"
