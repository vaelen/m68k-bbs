#!/bin/sh
# The BASIC interpreter as a host program (basic/basic-host.cla), built
# with the pinned toolchain into build/basic-host.
#   scripts/basic-host.sh [file.bas]     serve it on TCP port $PORT (default
#                                        2345); connect with nc localhost 2345
#   scripts/basic-host.sh --build        just build build/basic-host
#   scripts/basic-host.sh --export DIR   write main.c, the C runtime and
#                                        basic.sh to DIR, to compile with any
#                                        cc (Linux): cd DIR && ./basic.sh
# For a session in this terminal use scripts/basic.sh instead.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST="$ROOT/vendor/runtime/host"
emit() { "$ROOT/bin/clarusc" emit --rtdir "$ROOT/vendor/runtime/clarus/" -o "$1" "$ROOT/basic/basic-host.cla"; }
case "$1" in
--build)
    mkdir -p "$ROOT/build"
    emit "$ROOT/build/basic-host.c"
    cc -O1 -I "$HOST" -o "$ROOT/build/basic-host" "$ROOT/build/basic-host.c" "$HOST/rt.c"
    exit 0 ;;
--export)
    [ -n "$2" ] || { echo "usage: $0 --export DIR" >&2; exit 2; }
    mkdir -p "$2"
    emit "$2/main.c"
    cp "$HOST"/rt.c "$HOST"/rt.h "$HOST"/rt_mem.h "$HOST"/*.inc "$ROOT/scripts/basic.sh" "$2"/
    echo "exported to $2: cd $2 && ./basic.sh [file.bas]" >&2
    exit 0 ;;
esac
"$0" --build
echo "BASIC listening on port ${PORT:-2345}; connect with: nc localhost ${PORT:-2345}" >&2
CLARUS_SERIAL_MODEM="listen:${PORT:-2345}" exec "$ROOT/build/basic-host" "$@"
