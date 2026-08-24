#!/bin/sh
# XMODEM / XMODEM-1K / YMODEM download end to end on the host lane
# against a real receiver: a small CLI harness (scanner + telnet +
# xmodem, the same byte path bbs.cla uses, minus the menus -- the host
# runtime has no UI lane, so bbs.cla itself only runs on the Mac)
# listens on TCP, starts sending sample.bin on CONNECT in the mode
# given as its argument, and lrz receives it. Needs socat and lrzsz.
# Usage: scripts/xmodem-e2e.sh [port]
set -e
cd "$(dirname "$0")/.."
REPO=$PWD
PORT=${1:-4321}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/harness.cla" <<EOF
include "$REPO/scanner.cla"
include "$REPO/termio.cla"
include "$REPO/xmodem.cla"

var modem: connection
var mode: char = 'X'

func connected() {
    log("connected")
    telnetSend(modem, "Start your receive now...\x0D\x0A")
    xmodemSendStart("sample.bin", "sample.bin", mode)
}
func disconnected() { log("disconnected") }
func inputChar(c: char) { xmodemChar(c) }
func telnetOut(s: string) { modem.send(s) }
func xferOut(t: text) {
    var i: int = 0
    var n: int = 0
    while i < t.length {
        n = t.length - i
        if n > 255 { n = 255 }
        telnetSend(modem, t[i, n])
        i = i + n
    }
}
func xferDone(ok: bool) {
    if ok { log("transfer ok") } else { log("transfer failed") }
    quit
}

// No every-ticks timer here: it would make this a UI program the host lane
// can't build; the unit suite covers the timeouts.

on App.startCLI(args: list of string) {
    if args.count > 0 { mode = args[0][0] }
    modem.open(serial "modem:57600")
}
on modem.received(data: text) {
    var i: int = 0
    while i < data.length {
        feedChar(data[i])
        i = i + 1
    }
}
on modem.failed(err: error) {
    log("modem error: " + err.message)
    quit 1
}
EOF
bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$WORK/harness.c" "$WORK/harness.cla"
cc -O1 -I vendor/runtime/host -o "$WORK/harness" "$WORK/harness.c" vendor/runtime/host/rt.c
head -c 3000 /dev/urandom > "$WORK/sample.bin"   # 2 x 1K + a 952-byte tail

# socat EXEC: wires the driver's stdin AND stdout to the socket, so the
# CONNECT line reaches the scanner and lrz then owns both directions.
mkdir -p "$WORK/recv"
run_one() {   # $1 = mode (X/1/Y), $2 = lrz flags, $3 = output name, $4 = expected size, $5 = lrz name arg
    (cd "$WORK" && CLARUS_SERIAL_MODEM=listen:$PORT ./harness $1 > "harness-$3.log" 2>&1) &
    HARNESS=$!
    sleep 1
    cat > "$WORK/drive.sh" <<EOF
#!/bin/sh
printf '\r\nCONNECT 57600\r\n'; sleep 1
cd "$WORK/recv" && exec lrz $2 $5
EOF
    chmod +x "$WORK/drive.sh"
    socat TCP:localhost:$PORT EXEC:"$WORK/drive.sh" 2>"$WORK/lrz-$3.log" || true
    sleep 1
    kill $HARNESS 2>/dev/null || true
    wait $HARNESS 2>/dev/null || true
    # XMODEM carries no length: the receiver pads the last block with ^Z
    # to a 128-byte multiple (3072); YMODEM's block 0 carries the size,
    # so its file is exact (3000).
    if head -c 3000 "$WORK/recv/$3" | cmp - "$WORK/sample.bin" \
        && [ "$(wc -c < "$WORK/recv/$3")" -eq "$4" ] \
        && grep -q "transfer ok" "$WORK/harness-$3.log"; then
        echo "ok: $3"
    else
        echo "FAIL: $3"; cat "$WORK/lrz-$3.log" "$WORK/harness-$3.log"; exit 1
    fi
}

run_one X "-X -b" checksum.bin 3072 checksum.bin
run_one X "-X -b -c" crc.bin 3072 crc.bin
run_one 1 "-X -b -c" xmodem1k.bin 3072 xmodem1k.bin
run_one Y "--ymodem -b" sample.bin 3000 ""      # YMODEM names the file itself
echo "xmodem e2e passed"
