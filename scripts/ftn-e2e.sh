#!/bin/sh
# An FTN poll end to end on the host lane: the harness (scanner +
# emsi + ftntoss + zmodem, the byte path bbs.cla uses) dials a Python
# stand-in for the bridge (scripts/emsi-peer.py), sends its outbound
# packet (received by lrz), receives the fixture packets (sent by lsz),
# hangs up and tosses. Asserts the packet arrived intact, the fixtures
# landed in the right board and inbox, and the marks moved.
# Needs python3 and lrzsz. Usage: scripts/ftn-e2e.sh [port]
set -e
cd "$(dirname "$0")/.."
REPO=$PWD
PORT=${1:-4322}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/peer-in" "$WORK/peer-out"
cp tests/fixtures/echomail.pkt tests/fixtures/netmail.pkt "$WORK/peer-out/"

cat > "$WORK/harness.cla" <<EOF
include "$REPO/scanner.cla"
include "$REPO/termio.cla"
include "$REPO/emsi.cla"

var modem: connection
var isConnected: bool = false
var hangupPhase: int = 0
var hungUp: bool = false
var failures: int = 0

func xferOut(t: text) { modem.send(t) }
func telnetOut(s: string) { modem.send(s) }
func ftnModemSend(s: string) { modem.send(s) }
func ftnSysopName(): string { return "sysop" }
func xferDone(ok: bool) { emsiXferDone(ok) }
func xferReceived(name: string, bytes: int) { emsiFileReceived(name, bytes) }
func xferAcceptName(name: string): bool { return emsiAcceptName(name) }
func inputChar(c: char) { emsiChar(c) }

func expect(cond: bool, name: string) {
    if cond {
        log("PASS " + name)
    } else {
        log("FAIL " + name)
        failures = failures + 1
    }
}

func connected() {
    isConnected = true
    telnetReset()
    telnetIntercept = false
    log("CONNECT")
    emsiConnected()
}

func disconnected() {
    isConnected = false
    log("NO CARRIER")
    emsiDisconnected()
    report()
    quit
}

func report() {
    var ids: list of int
    log("result " + pollResultName(emResult))
    expect(emResult == pollOk, "poll ok")
    expect(postsOpen(1) and postCount() == 2, "board 1 has the local post and the tossed echomail")
    expect(loadPost(2) and post.sender == "Rixter", "tossed post is Rixter's")
    postsClose()
    inboxIds(1, ids)
    expect(ids.count == 1 and loadMessage(ids[0]) and message.fromName == "Areafix", "Areafix netmail in the sysop's inbox")
    expect(loadBoard(1) and board.lastExported == 1, "lastExported advanced")
    expect(not file.exists(ftnOutPath(1)), "outbound packet gone")
    if failures > 0 {
        log("ftn-e2e: FAILED")
        quit 1
    }
    log("ftn-e2e: all passed")
}

func seed() {
    var n: Network
    var body: text
    usersOpen()
    boardsOpen()
    mailOpen()
    networksOpen()
    user.name = "sysop"
    user.access = accessSysop
    createUser()
    n.name = "fsxNet"
    n.addr = parseAddress("21:1/141")
    n.uplink = parseAddress("21:1/100")
    n.sessionPw = "SECRET"
    n.dial = "555"
    n.utcOffset = 540
    n.flags = netFlagEnabled
    createNetwork(n)
    createBoard("Ads", "adverts", "FSX_ADS", 1)
    postsOpen(1)
    body = "\x01MSGID: 21:1/141 00000001\nHello fsxNet from the harness\n"
    addPostFtn("andrew", 0, 0, "Harness post", body, msgIdCrc("21:1/141 00000001"), parseAddress("21:1/141"), 0)
    postsClose()
    ftnEnsureFolders()
}

// No every-ticks timer on the host lane: hangupPhase is polled after
// each received chunk instead (bbs.cla paces +++/ATH on its timer).
on App.startCLI(args: list of string) {
    seed()
    modem.open(serial "modem:57600")
}
on modem.opened {
    ftnPollRequest(1)
}
on modem.received(data: text) {
    var i: int = 0
    while i < data.length {
        feedChar(data[i])
        i = i + 1
    }
    if hangupPhase == 1 and not hungUp {
        hungUp = true
        modem.send("+++")
        modem.send("ATH\x0D")
    }
}
on modem.failed(err: error) {
    log("modem error: " + err.message)
    quit 1
}
EOF

bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$WORK/harness.c" "$WORK/harness.cla"
cc -O1 -I vendor/runtime/host -o "$WORK/harness" "$WORK/harness.c" vendor/runtime/host/rt.c

python3 scripts/emsi-peer.py --port "$PORT" --inbound "$WORK/peer-in" --outbound "$WORK/peer-out" > "$WORK/peer.log" 2>&1 &
PEER=$!
sleep 1
( cd "$WORK" && CLARUS_SERIAL_MODEM="connect:127.0.0.1:$PORT" ./harness ) 2>&1 | tee "$WORK/harness.log"
wait $PEER || { echo "peer failed"; cat "$WORK/peer.log"; exit 1; }
cat "$WORK/peer.log"

# the packet the peer received must be a type-2+ packet with our post
PKT=$(ls "$WORK"/peer-in/*.pkt | head -1)
[ -n "$PKT" ] || { echo "FAIL: no packet received by the peer"; exit 1; }
python3 - "$PKT" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert struct.unpack('<H', d[18:20])[0] == 2 and struct.unpack('<H', d[44:46])[0] == 1, "not type 2+"
assert b"AREA:FSX_ADS\r" in d and b"Hello fsxNet from the harness" in d, "post missing"
assert b"\x01MSGID: 21:1/141 00000001\r" in d and b"SEEN-BY: 1/100 1/141\r" in d, "kludges missing"
assert d.endswith(b"\x00\x00"), "no trailer"
print("packet ok:", len(d), "bytes")
EOF
grep -q "ftn-e2e: all passed" "$WORK/harness.log" && echo "ftn-e2e: PASS"
