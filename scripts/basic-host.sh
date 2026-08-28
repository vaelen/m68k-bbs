#!/bin/sh
# Build basic/basic-host.cla with the pinned toolchain on the host lane
# and run it, serving the interpreter on TCP port $PORT (default 2345):
#   scripts/basic-host.sh [file.bas]      then      nc localhost 2345
set -e
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$WORK/main.c" basic/basic-host.cla
cc -O1 -I vendor/runtime/host -o "$WORK/basic-host" "$WORK/main.c" vendor/runtime/host/rt.c
echo "BASIC listening on port ${PORT:-2345}; connect with: nc localhost ${PORT:-2345}" >&2
CLARUS_SERIAL_MODEM="listen:${PORT:-2345}" "$WORK/basic-host" "$@"
