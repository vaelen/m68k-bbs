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

ser = listener(1235)
m = subprocess.Popen(["./modem", "2324", "1235"], stderr=subprocess.DEVNULL)
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
    # 7. serial port down -> caller rejected with NO ANSWER
    ser.close(); local.close(); time.sleep(0.3)
    caller = call(); assert rd(caller) == NOANSWER
    print("ok")
finally:
    m.kill()
PY
