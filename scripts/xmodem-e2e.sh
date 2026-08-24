#!/bin/sh
# XMODEM download end to end on the host lane against a real receiver:
# a small CLI harness (scanner + telnet + xmodem, the same byte path
# bbs.cla uses, minus the menus -- the host runtime has no UI lane, so
# bbs.cla itself only runs on the Mac) listens on TCP, starts sending
# sample.bin on CONNECT, and lrz -X receives it, first with checksum
# then with CRC. Needs socat and lrzsz. Usage: scripts/xmodem-e2e.sh [port]
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

func connected() {
    log("connected")
    telnetSend(modem, "Start your XMODEM receive now...\x0D\x0A")
    xmodemSendStart("sample.bin")
}
func disconnected() { log("disconnected") }
func inputChar(c: char) { xmodemChar(c) }
func telnetOut(s: string) { modem.send(s) }
func xferOut(s: string) { telnetSend(modem, s) }
func xferDone(ok: bool) {
    if ok { log("transfer ok") } else { log("transfer failed") }
    quit
}

// No every-ticks timer here: it would make this a UI program the host lane
// can't build; the unit suite covers the timeouts.

on App.startCLI(args: list of string) {
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
head -c 3000 /dev/urandom > "$WORK/sample.bin"

# socat EXEC: wires the driver's stdin AND stdout to the socket, so the
# CONNECT line reaches the scanner and lrz then owns both directions.
run_one() {   # $1 = lrz flags, $2 = output name
    (cd "$WORK" && CLARUS_SERIAL_MODEM=listen:$PORT ./harness > "harness-$2.log" 2>&1) &
    HARNESS=$!
    sleep 1
    cat > "$WORK/drive.sh" <<EOF
#!/bin/sh
printf '\r\nCONNECT 57600\r\n'; sleep 1
cd "$WORK" && exec lrz $1 "$2"
EOF
    chmod +x "$WORK/drive.sh"
    socat TCP:localhost:$PORT EXEC:"$WORK/drive.sh" 2>"$WORK/lrz-$2.log" || true
    sleep 1
    kill $HARNESS 2>/dev/null || true
    wait $HARNESS 2>/dev/null || true
    # XMODEM carries no length: the receiver pads the last block with ^Z
    # to a 128-byte multiple, so compare the payload and expect 3072 bytes.
    if head -c 3000 "$WORK/$2" | cmp - "$WORK/sample.bin" \
        && [ "$(wc -c < "$WORK/$2")" -eq 3072 ] \
        && grep -q "transfer ok" "$WORK/harness-$2.log"; then
        echo "ok: $2"
    else
        echo "FAIL: $2"; cat "$WORK/lrz-$2.log" "$WORK/harness-$2.log"; exit 1
    fi
}

run_one "-X -b" checksum.bin
run_one "-X -b -c" crc.bin
echo "xmodem e2e passed"
