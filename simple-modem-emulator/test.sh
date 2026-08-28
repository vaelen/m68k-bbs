#!/bin/sh
# Copyright 2026, Andrew C. Young <andrew@vaelen.org>
# SPDX-License-Identifier: MIT
# Smoke test: fake "serial port" on 1235, modem on 2324, python plays the
# caller, the serial port and any dialed peer.
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
import socket, subprocess, time, sys, os, tempfile

CONNECT = b"\r\nCONNECT 57600\r\n"
NOCARRIER = b"\r\nNO CARRIER\r\n"
OK = b"\r\nOK\r\n"
ERROR = b"\r\nERROR\r\n"
BUSY = b"BUSY, PLEASE TRY AGAIN LATER\r\n"
NOANSWER = b"NO ANSWER, PLEASE TRY AGAIN LATER\r\n"

def rd(s, n=1024, t=2):
    s.settimeout(t)
    try: return s.recv(n)
    except socket.timeout: return b""

def rd_until(s, want, t=3):
    got = b""; end = time.time() + t
    while want not in got and time.time() < end:
        got += rd(s, t=0.5)
    return got

def call():
    return socket.create_connection(("127.0.0.1", 2324))

def listener(port):
    l = socket.socket(); l.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    l.bind(("127.0.0.1", port)); l.listen(1); l.settimeout(3)
    return l

conf = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
conf.write("# name = target\n"
           "bbs = tcp:127.0.0.1:1236\n"
           "echo = exec:echo hi; cat\n"
           "quiet = exec:true\n"
           "slow = exec:sleep 5\n")
conf.close()
ser = listener(1235)
m = subprocess.Popen(["./modem", "2324", "1235", conf.name], stderr=subprocess.DEVNULL)
try:
    local, _ = ser.accept()                     # the modem is on the line from the start
    # 1. inbound call: CONNECT, data both ways
    caller = call(); assert rd(local) == CONNECT
    caller.sendall(b"hello"); assert rd(local) == b"hello"
    local.sendall(b"world"); assert rd(caller) == b"world"
    # 2. "+++" without guard time is plain data
    local.sendall(b"a+++b"); x = rd(caller); assert x == b"a+++b", x
    # 3. escape: quiet, +++, quiet -> OK, not forwarded; ATO -> CONNECT
    time.sleep(1.1); local.sendall(b"+++")
    assert rd(local) == OK; assert rd(caller) == b""
    local.sendall(b"ATO\r"); assert rd(local) == CONNECT
    local.sendall(b"more"); assert rd(caller) == b"more"
    # 4. escape then ATH0 -> NO CARRIER; caller dropped; serial line stays up
    time.sleep(1.1); local.sendall(b"+++"); assert rd(local) == OK
    local.sendall(b"ATH0\r"); assert rd(local) == NOCARRIER
    assert rd(caller) == b""; caller.close()
    local.sendall(b"AT\r"); assert rd(local) == OK
    local.sendall(b"ATH\r"); assert rd(local) == OK      # on-hook already
    # 5. caller hangs up -> NO CARRIER; line still answers commands
    caller = call(); assert rd(local) == CONNECT
    caller.close(); assert rd(local) == NOCARRIER
    local.sendall(b"AT\r"); assert rd(local) == OK
    # 6. serial port closes mid-call -> caller dropped; modem reconnects (~10 s)
    caller = call(); assert rd(local) == CONNECT
    local.close(); assert rd(caller) == b""; caller.close()
    ser.settimeout(12); local, _ = ser.accept()
    caller = call(); assert rd(local) == CONNECT
    caller.close(); assert rd(local) == NOCARRIER
    # 8. ATDT host:port with no dial.conf -> CONNECT, bridged both ways
    peer_l = listener(1236)
    local.sendall(b"ATDT127.0.0.1:1236\r"); peer, _ = peer_l.accept()
    assert rd(local) == CONNECT
    local.sendall(b"out"); assert rd(peer) == b"out"
    peer.sendall(b"in"); assert rd(local) == b"in"
    # 9. a caller during an outbound call is BUSY; ATD while online is ERROR
    c = call(); assert rd(c) == BUSY; c.close()
    time.sleep(1.1); local.sendall(b"+++"); assert rd(local) == OK
    local.sendall(b"ATDT1.2.3.4\r"); assert rd(local) == ERROR
    local.sendall(b"ATO\r"); assert rd(local) == CONNECT
    # 10. the dialed side hangs up -> NO CARRIER
    peer.close(); assert rd(local) == NOCARRIER
    # 11. unknown number, refused port (spaces/dashes are stripped)
    local.sendall(b"ATDT555\r"); assert rd(local) == NOCARRIER
    local.sendall(b"ATDT 127.0.0.1:1\r"); assert rd(local, t=5) == NOCARRIER
    local.sendall(b"AT\r"); assert rd(local) == OK
    # 12. address book: a tcp entry by name; hanging up closes the peer
    local.sendall(b"ATDTbbs\r"); peer, _ = peer_l.accept(); assert rd(local) == CONNECT
    time.sleep(1.1); local.sendall(b"+++"); assert rd(local) == OK
    local.sendall(b"ATH\r"); assert rd(local) == NOCARRIER
    assert rd(peer) == b""; peer.close(); peer_l.close()
    # 13. exec entry: CONNECT on the child's first byte, then bridged
    local.sendall(b"ATDTecho\r")
    got = rd_until(local, b"hi\n"); assert got.startswith(CONNECT) and got.endswith(b"hi\n"), got
    local.sendall(b"ping\n"); assert rd(local) == b"ping\n"
    time.sleep(1.1); local.sendall(b"+++"); assert rd(local) == OK
    local.sendall(b"ATH\r"); assert rd(local) == NOCARRIER
    # 14. a child that exits without output -> NO CARRIER
    local.sendall(b"ATDTquiet\r"); assert rd(local) == NOCARRIER
    # 15. a byte from the computer aborts a dial in progress, promptly
    local.sendall(b"ATDTslow\r"); time.sleep(0.5); t0 = time.time()
    local.sendall(b"ATH\r"); assert rd(local) == NOCARRIER and time.time() - t0 < 2
    local.sendall(b"AT\r"); assert rd(local) == OK
    # 7. serial port down -> caller rejected with NO ANSWER
    ser.close(); local.close(); time.sleep(0.3)
    caller = call(); assert rd(caller) == NOANSWER
    print("ok")
finally:
    m.kill(); os.unlink(conf.name)
PY
