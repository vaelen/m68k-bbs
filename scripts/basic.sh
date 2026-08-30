#!/bin/sh
# Run the BASIC interpreter in this terminal:
#   scripts/basic.sh            the Ok prompt (SYSTEM quits)
#   scripts/basic.sh game.bas   run a program; files it opens live in
#                               the current directory
# A Clarus host program has no stdin/stdout, only the TCP-mapped serial
# port, so this starts build/basic-host listening on $PORT (default
# 2345) and attaches nc in the foreground. Line mode with local echo;
# INKEY$ sees keys after Enter. In a bundle from
# `scripts/basic-host.sh --export` (main.c beside this script) it
# compiles main.c with cc first, so it runs wherever cc and nc do.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/main.c" ]; then
    BIN="$HERE/basic-host"
    [ "$BIN" -nt "$HERE/main.c" ] || cc -O1 -I "$HERE" -o "$BIN" "$HERE/main.c" "$HERE/rt.c"
else
    "$HERE/basic-host.sh" --build
    BIN="$HERE/../build/basic-host"
fi
PORT=${PORT:-2345}
CLARUS_SERIAL_MODEM="listen:$PORT" "$BIN" "$@" &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT
# The listener takes a moment; nc fails fast (refused) until it is up.
# No port probe: the runtime accepts exactly one connection.
until nc localhost "$PORT" 2>/dev/null; do
    kill -0 $PID 2>/dev/null || exit 1
    sleep 0.1
done
