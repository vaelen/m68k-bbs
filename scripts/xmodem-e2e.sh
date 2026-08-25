#!/bin/sh
# XMODEM / XMODEM-1K / YMODEM / ZMODEM transfers end to end on the host
# lane against a real peer: a small CLI harness (scanner + telnet +
# xmodem + zmodem, the same byte path bbs.cla uses, minus the menus --
# the host runtime has no UI lane, so bbs.cla itself only runs on the
# Mac) listens on TCP and on CONNECT either sends sample.bin (arg
# X/1/Y/Z; lrz receives it) or receives into recv/ (arg RX/R1/RY/RZ;
# lsz sends sample.bin). Needs socat and lrzsz.
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
include "$REPO/zmodem.cla"

var modem: connection
var mode: char = 'X'
var recv: bool = false

func connected() {
    log("connected")
    // The same wording files.cla sends, so this rig catches a capital C
    // (or NAK/CAN) creeping back into the announcement: senders take
    // those as the handshake and start mid-sentence.
    if recv {
        telnetSend(modem, "Send your file now. Two ^X abort.\x0D\x0A")
    } else {
        telnetSend(modem, "Start your XMODEM receive now. Two ^X abort.\x0D\x0A")
    }
    if mode == 'Z' {
        // a different wire name: lrz won't overwrite the YMODEM leg's file
        if recv { zmodemRecvStart("") } else { zmodemSendStart("sample.bin", "zsample.bin") }
    } else if recv {
        xmodemRecvStart(mode, "", "upload.bin")
    } else {
        xmodemSendStart("sample.bin", "sample.bin", mode)
    }
}
func xferReceived(name: string, bytes: int) { log("received " + name + " " + string(bytes)) }
func xferAcceptName(name: string): bool { return true }
func disconnected() { log("disconnected") }
func inputChar(c: char) {
    if mode == 'Z' { zmodemChar(c) } else { xmodemChar(c) }
}
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
    if args.count > 0 {
        if args[0].length == 2 {
            recv = true
            mode = args[0][1]
        } else {
            mode = args[0][0]
        }
    }
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
# The announcement a caller sees just before arming their side must not
# contain an XMODEM handshake byte (capital C = CRC start, 0x15 NAK,
# 0x18 CAN) -- a sender takes one as the go-ahead and starts mid-line.
if grep -n 'sendLine("Start your\|sendLine("Send your' files.cla | grep -q 'C[a-z]*'; then
    echo "FAIL: transfer announcement in files.cla contains a capital C" >&2
    grep -n 'sendLine("Start your\|sendLine("Send your' files.cla >&2
    exit 1
fi

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

# Uploads: the harness runs in recv/ (so the file lands there) and lsz
# sends sample.bin from the driver.
run_up() {   # $1 = mode (RX/R1/RY), $2 = lsz flags, $3 = expected name, $4 = expected size
    (cd "$WORK/recv" && CLARUS_SERIAL_MODEM=listen:$PORT ../harness $1 > "../harness-up-$1.log" 2>&1) &
    HARNESS=$!
    sleep 1
    cat > "$WORK/drive.sh" <<EOF
#!/bin/sh
printf '\r\nCONNECT 57600\r\n'; sleep 1
cd "$WORK" && exec lsz $2 sample.bin
EOF
    chmod +x "$WORK/drive.sh"
    rm -f "$WORK/recv/$3"
    socat TCP:localhost:$PORT EXEC:"$WORK/drive.sh" 2>"$WORK/lsz-$1.log" || true
    sleep 1
    kill $HARNESS 2>/dev/null || true
    wait $HARNESS 2>/dev/null || true
    if head -c 3000 "$WORK/recv/$3" | cmp - "$WORK/sample.bin" \
        && [ "$(wc -c < "$WORK/recv/$3")" -eq "$4" ] \
        && grep -q "received $3 $4" "$WORK/harness-up-$1.log" \
        && grep -q "transfer ok" "$WORK/harness-up-$1.log"; then
        echo "ok: upload $1 -> $3"
    else
        echo "FAIL: upload $1"; cat "$WORK/lsz-$1.log" "$WORK/harness-up-$1.log"; exit 1
    fi
}

run_one X "-X -b" checksum.bin 3072 checksum.bin
run_one X "-X -b -c" crc.bin 3072 crc.bin
run_one 1 "-X -b -c" xmodem1k.bin 3072 xmodem1k.bin
run_one Y "--ymodem -b" sample.bin 3000 ""      # YMODEM names the file itself
run_up RX "-X -b" upload.bin 3072
run_up R1 "-X -b -k" upload.bin 3072
run_up RY "--ymodem -b" sample.bin 3000
run_one Z "--zmodem -b" zsample.bin 3000 ""    # ZMODEM names the file too
run_up RZ "--zmodem -b" sample.bin 3000
echo "xmodem e2e passed"
