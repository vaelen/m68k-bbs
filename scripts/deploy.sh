#!/bin/sh
# Build, refresh the app on snow/hdd2.img, and (re)start Snow.
# Snow must not have the image open while hfsutils touches it, so the
# script quits Snow first and starts it again after.
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

scripts/build.sh

osascript -e 'quit app "Snow"' 2>/dev/null || true
sleep 2
if pgrep -x Snow > /dev/null; then
    echo "Snow did not exit; aborting before touching the disk image" >&2
    exit 1
fi

# hfsutils keeps state in $HOME/.hcwd -- use a scratch HOME.
export HOME="$ROOT/build/hfs-scratch"
mkdir -p "$HOME"
hmount "$ROOT/snow/hdd2.img"
hdel :68kBBS 2>/dev/null || true
hcopy -m "$ROOT/build/68kBBS.bin" :
humount

cd "$ROOT/snow"
nohup ./Snow --serial-bridge-a tcp:1235 "$PWD/MacII.snoww" > snow.log 2>&1 &
sleep 3
grep -i "SCSI ID #1\|bridge enabled" snow.log
echo "Snow running; app deployed."
