#!/usr/bin/env python3
# Copyright 2026, Andrew C. Young <andrew@vaelen.org>
# SPDX-License-Identifier: MIT
#
# SyncTERM's telnet layer as a stdio filter, so the e2e rig can run a
# transfer the way a telnet-mode caller does. Mirrors
# src/syncterm/telnet_io.c + conn_telnet.c (sbbs master, Aug 2026):
#
#   connect: WILL SGA, DO SGA, WILL BINARY, DO BINARY, DO ECHO; the
#            option state is set optimistically on request and only
#            falls back when the server refuses
#   receive: IAC commands answered (BINARY/ECHO/TERM-TYPE/SGA/NAWS
#            acknowledged, everything else refused), IAC IAC -> 0xFF,
#            TERM-TYPE SEND -> IS "ansi" + WILL NAWS, DO NAWS -> 80x24;
#            unless the server said WILL BINARY, a CR is held and a NUL
#            (or IAC) right after it is dropped
#   send:    IAC doubled; unless the server said DO BINARY, every CR
#            gets an LF appended (RFC 5198) and a following LF is not
#            doubled
#
# Usage: telnet-shim.py CMD [ARG...]   (under socat EXEC:, stdio = the
# socket). Prints the modem's CONNECT line and the connect-time
# negotiation, waits a second, then runs CMD with its stdin/stdout
# behind the filter. Whole text lines arriving before CMD starts are
# the BBS's announcement: a terminal would have displayed them, so they
# are dropped (lrz would otherwise take them as line noise and purge
# block 1 along with them); whatever follows the last CR LF -- the
# receiver's one-shot C/NAK prod or ZRINIT header in the upload legs,
# which the timer-less harness never repeats -- is handed to CMD.
# TELNET_SHIM_LOG=path appends a timestamped hex dump of both directions.
import os
import subprocess
import sys
import threading
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
BINARY, ECHO, SGA, TERMTYPE, NAWS = 0, 1, 3, 24, 31
TERM_IS, TERM_SEND = 0, 1
CR, LF = 13, 10

local_opt = {}    # what we do: DO = on (server asked/agreed)
remote_opt = {}   # what the server does: WILL = on
cmd = bytearray()
last_was_lf = False
child = None
pending = bytearray()   # data received before the child started
out_lock = threading.Lock()
t0 = time.monotonic()
logf = open(os.environ["TELNET_SHIM_LOG"], "a") if os.environ.get("TELNET_SHIM_LOG") else None


def trace(tag, b):   # TELNET_SHIM_LOG=path: hex dump of both wire directions
    if logf:
        logf.write("%.3f %s %s\n" % (time.monotonic() - t0, tag, bytes(b).hex(" ")))
        logf.flush()


def put(b):
    trace("TX", b)
    with out_lock:
        os.write(1, bytes(b))


def ack(c):
    return {DO: WILL, DONT: WONT, WILL: DO, WONT: DONT}[c]


def request(c, opt):
    if c in (DO, DONT):
        if remote_opt.get(opt) == ack(c):
            return
        remote_opt[opt] = ack(c)
    else:
        if local_opt.get(opt) == ack(c):
            return
        local_opt[opt] = ack(c)
    put([IAC, c, opt])


def negotiate(c, opt):
    if c in (DO, DONT):
        if local_opt.get(opt) != c:
            if opt in (BINARY, TERMTYPE, SGA, NAWS):
                local_opt[opt] = c
                put([IAC, ack(c), opt])
            elif c == DO:
                put([IAC, WONT, opt])
        if c == DO and opt == NAWS:
            put([IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE])
    else:
        if remote_opt.get(opt) != c:
            if opt in (BINARY, ECHO, TERMTYPE, SGA, NAWS):
                remote_opt[opt] = c
                put([IAC, ack(c), opt])
            elif c == WILL:
                put([IAC, DONT, opt])


def interpret(buf):
    out = bytearray()
    for b in buf:
        if remote_opt.get(BINARY) != WILL:
            if len(cmd) == 1 and cmd[0] == CR:
                out.append(CR)
                if b not in (0, IAC):
                    out.append(b)
                del cmd[:]
                if b != IAC:
                    continue
            if b == CR and not cmd:
                cmd.append(CR)
                continue
        if b == IAC and len(cmd) == 1:
            del cmd[:]
            out.append(IAC)
            continue
        if b == IAC or cmd:
            cmd.append(b)
            if len(cmd) >= 2 and cmd[1] == SB:
                if b == SE and cmd[-2] == IAC:
                    if cmd[2] == TERMTYPE and cmd[3] == TERM_SEND:
                        put([IAC, SB, TERMTYPE, TERM_IS] + list(b"ansi") + [IAC, SE])
                        request(WILL, NAWS)
                    del cmd[:]
            elif len(cmd) == 2 and b < WILL:
                del cmd[:]
            elif len(cmd) >= 3:
                negotiate(cmd[1], cmd[2])
                del cmd[:]
        else:
            out.append(b)
    return out


def expand(buf):
    global last_was_lf
    out = bytearray()
    expand_cr = local_opt.get(BINARY) != DO
    if last_was_lf and buf[:1] == b"\n":
        buf = buf[1:]
    last_was_lf = False
    for b in buf:
        if b == LF and last_was_lf:
            continue
        last_was_lf = False
        if b == IAC:
            out.append(IAC)
        out.append(b)
        if expand_cr and b == CR:
            last_was_lf = True
            out.append(LF)
    return out


def pump_rx():
    while True:
        data = os.read(0, 4096)
        if not data:
            break
        trace("RX", data)
        data = interpret(data)
        if child is None:
            pending.extend(data)
        else:
            child.stdin.write(data)
            child.stdin.flush()
    if child is not None:
        child.stdin.close()


def main():
    global child
    put(b"\r\nCONNECT 57600\r\n")
    request(WILL, SGA)
    request(DO, SGA)
    request(WILL, BINARY)
    request(DO, BINARY)
    request(DO, ECHO)
    threading.Thread(target=pump_rx, daemon=True).start()
    time.sleep(1)
    child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    child.stdin.write(pending.rpartition(b"\r\n")[2])
    child.stdin.flush()
    while True:
        data = child.stdout.read1(4096)
        if not data:
            break
        put(expand(data))
    sys.exit(child.wait())


main()
