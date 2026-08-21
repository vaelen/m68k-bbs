#!/bin/sh
# Copyright 2026, Andrew C. Young <andrew@vaelen.org>
# SPDX-License-Identifier: MIT
# Smoke test: fake "serial port" on 1235, modem on 2324, python as the caller.
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
import socket, subprocess, time, sys
def rd(s, n=1024):
    s.settimeout(2); 
    try: return s.recv(n)
    except socket.timeout: return b""
ser = socket.socket(); ser.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ser.bind(("127.0.0.1", 1235)); ser.listen(1)
m = subprocess.Popen(["./modem", "2324", "1235"], stderr=subprocess.DEVNULL)
time.sleep(0.3)
try:
    # 1. call comes in, local accepts -> CONNECT to local, data flows both ways
    caller = socket.create_connection(("127.0.0.1", 2324))
    local, _ = ser.accept()
    assert rd(local) == b"CONNECT 57600\r"
    caller.sendall(b"hello"); assert rd(local) == b"hello"
    local.sendall(b"world"); assert rd(caller) == b"world"
    # 2. "+++" without guard time is plain data
    local.sendall(b"a+++b"); x = rd(caller); assert x == b"a+++b", x
    # 3. escape: quiet, +++, quiet -> OK, not forwarded; then ATO -> CONNECT
    time.sleep(1.1); local.sendall(b"+++")
    assert rd(local) == b"OK\r"; assert rd(caller) == b""
    local.sendall(b"ATO\r"); assert rd(local) == b"CONNECT 57600\r"
    local.sendall(b"more"); assert rd(caller) == b"more"
    # 4. escape then ATH0 -> NO CARRIER, both sides closed
    time.sleep(1.1); local.sendall(b"+++"); assert rd(local) == b"OK\r"
    local.sendall(b"ATH0\r"); assert rd(local) == b"NO CARRIER\r"
    assert rd(local) == b"" and rd(caller) == b""
    local.close(); caller.close()
    # 5. caller hangs up -> NO CARRIER, local closed
    caller = socket.create_connection(("127.0.0.1", 2324))
    local, _ = ser.accept(); assert rd(local) == b"CONNECT 57600\r"
    caller.close(); assert rd(local) == b"NO CARRIER\r"; assert rd(local) == b""
    local.close()
    # 6. local closes -> caller dropped
    caller = socket.create_connection(("127.0.0.1", 2324))
    local, _ = ser.accept(); rd(local); local.close()
    assert rd(caller) == b""
    # 7. serial port refuses -> caller rejected
    ser.close()
    caller = socket.create_connection(("127.0.0.1", 2324))
    assert rd(caller) == b""
    print("ok")
finally:
    m.kill()
PY
