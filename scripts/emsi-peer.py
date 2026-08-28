#!/usr/bin/env python3
"""A fake modem + answering EMSI/ZMODEM mailer for scripts/ftn-e2e.sh.

Listens on --port; the harness connects (CLARUS_SERIAL_MODEM=connect:).
Reads "ATDT<n>\r", answers CONNECT, runs the EMSI answer side, receives
the caller's batch with lrz into --inbound, sends every file in
--outbound with lsz, then answers +++/ATH with NO CARRIER. Stands in
for the bridge (docs/fidonet.md, "Bridge contract") on the host lane;
on Snow the modem emulator's dial.conf points at fnemsi instead.
"""
import argparse
import glob
import os
import socket
import subprocess
import sys


def crc16x(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def seq(name: bytes) -> bytes:
    return b"**" + name + b"%04X" % crc16x(name) + b"\r"


def dat(fields: bytes) -> bytes:
    body = b"EMSI_DAT" + b"%04X" % len(fields) + fields
    return b"**" + body + b"%04X" % crc16x(body) + b"\r"


def read_until(sock, marker, limit=8192):
    buf = b""
    while marker not in buf and len(buf) < limit:
        chunk = sock.recv(1)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True, help="listen here as the harness's modem")
    ap.add_argument("--address", default="21:1/100")
    ap.add_argument("--password", default="SECRET")
    ap.add_argument("--inbound", required=True)
    ap.add_argument("--outbound", required=True)
    a = ap.parse_args()
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", a.port))
    ls.listen(1)
    sock, _ = ls.accept()
    print("peer: harness connected", flush=True)
    line = read_until(sock, b"\r")
    if not line.startswith(b"ATDT"):
        print("peer: expected ATDT, got %r" % line)
        sys.exit(1)
    sock.sendall(b"\r\nCONNECT 57600\r\n")
    sock.sendall(seq(b"EMSI_REQ"))
    read_until(sock, b"**EMSI_INQ")
    read_until(sock, b"\r")                       # the INQ's crc + CR
    theirs = read_until(sock, b"\r")              # their EMSI_DAT
    if not theirs.startswith(b"**EMSI_DAT"):
        print("peer: expected EMSI_DAT, got %r" % theirs)
        sys.exit(1)
    n = int(theirs[10:14], 16)
    body = theirs[2:14 + n]
    if int(theirs[14 + n:18 + n], 16) != crc16x(body):
        print("peer: bad DAT crc")
        sys.exit(1)
    fields = theirs[14:14 + n].split(b"}")
    addr, pw = fields[1][1:], fields[2][1:]
    print("peer: caller %s password %s" % (addr.decode(), pw.decode()), flush=True)
    if pw.decode() != a.password:
        print("peer: password mismatch")
        sys.exit(1)
    sock.sendall(seq(b"EMSI_ACK") + seq(b"EMSI_ACK"))
    sock.sendall(dat(b"{EMSI}{%s}{%s}{8N1,PUA}{ZMO,NRQ}{FE}{emsi-peer}{0.1}{}"
                     % (a.address.encode(), a.password.encode())))
    read_until(sock, b"**EMSI_ACK")
    read_until(sock, b"\r")
    fd = sock.fileno()
    r = subprocess.run(["lrz", "--zmodem", "-b", "-q", "-y"], cwd=a.inbound,
                       stdin=fd, stdout=fd, stderr=subprocess.DEVNULL)
    print("peer: lrz exit %d, inbound %s" % (r.returncode, sorted(os.listdir(a.inbound))), flush=True)
    files = sorted(glob.glob(os.path.join(a.outbound, "*.pkt")))
    r = subprocess.run(["lsz", "--zmodem", "-b", "-q"] + files,
                       stdin=fd, stdout=fd, stderr=subprocess.DEVNULL)
    print("peer: lsz exit %d, sent %s" % (r.returncode, [os.path.basename(f) for f in files]), flush=True)
    # the caller hangs up: +++/ATH reach us directly from the harness,
    # or the modem emulator acts on them and just drops us (EOF)
    tail = b""
    while b"ATH" not in tail:
        chunk = sock.recv(64)
        if not chunk:
            break
        tail += chunk
    try:
        sock.sendall(b"\r\nNO CARRIER\r\n")
    except OSError:
        pass
    sock.close()
    print("peer: hung up", flush=True)


if __name__ == "__main__":
    main()
