#!/bin/sh
# Compact one board on the host (scripts/boardtool.cla):
#   scripts/boardtool.sh DIR BOARD [KEEPDAYS]
# DIR/Boards holds a copy of the board's files (BRDnn.*) taken while the BBS
# was NOT running; copy them back to the Mac afterwards. Builds with
# the installed clarusc into build/boardtool.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 2 ] || { echo "usage: $0 DIR BOARD [KEEPDAYS]" >&2; exit 1; }
DIR=$1
shift
mkdir -p "$ROOT/build"
CFLAGS="-O1 -w" clarusc build -o "$ROOT/build/boardtool" "$ROOT/scripts/boardtool.cla"
cd "$DIR"
"$ROOT/build/boardtool" "$@"
