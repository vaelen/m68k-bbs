# fnemsi — the 68kBBS FidoNet bridge

A design brief for the host-side half of 68kBBS's FidoNet support: a
program in **libftn** (`~/repos/libftn`, ISO C89, MIT) that answers the
Mac's modem-side mail call and relays packets to a binkp uplink, plus
the small changes to **simple-modem-emulator** (`68kbbs/simple-modem-
emulator/`, C) that let the Mac dial it. The Mac side is finished and
verified (`docs/fidonet.md`, "Status"); this document is everything the
bridge author needs without reading that code.

## 1. What exists and what is missing

68kBBS is a leaf node on an FTN network (fsxNet first). The Mac has no
TCP/IP, so it speaks classic FTN over its modem port: Hayes dialing,
an **EMSI** handshake (FSC-0056), **ZMODEM** file transfer, and
**type-2+ `.pkt`** files (FSC-0048), uncompressed. The network's hub
speaks **binkp** over TCP. The bridge sits between them:

```
 Mac (Snow or real hardware)         host                                    Internet
┌─────────────────────────┐  serial ┌──────────────┐ stdio ┌───────────────┐ binkp ┌────────┐
│ 68kBBS: scan → ATDT →   │ ══════▶ │ modem        │ ◀═══▶ │ fnemsi        │       │ fsxNet │
│ EMSI → ZMODEM send →    │ TCP:1234│ emulator     │       │ (EMSI+ZMODEM  │       │  hub   │
│ ZMODEM receive → +++ATH │         │ ATDT → exec: │       │  answerer)    │       │        │
│ → toss                  │         └──────────────┘       │ fnmailer ◀════════════▶│        │
└─────────────────────────┘                                │ (binkp, BSO)  │       └────────┘
                                                           └───────────────┘
```

Already there:

- **68kBBS** (Clarus, in `68kbbs/`): the whole Mac side — `emsi.cla`
  (the EMSI *caller*), `zmodem.cla`, `ftnpkt.cla`/`ftntoss.cla`
  (packets, toss/scan), the Networks database and sysop screens.
- **libftn**: `fnmailer` (binkp client, single-shot or daemon, per-network
  `inbox`/`outbox` directories, BSO helpers in `bso.c`), `ftn_packet_*`
  (type-2/2+ read/write), `ftn_message_*` (kludges, MSGID, dates),
  `dupechk.c`, `config.c` (INI, see `CONFIG.md`), `net.c`, `log.c`.
- **simple-modem-emulator**: a TCP bridge that turns a telnet caller
  into `CONNECT`/`NO CARRIER` on the emulated serial port, with just
  enough Hayes to hang up (`+++`, `ATH`, `ATO`; every other `AT…` gets
  `OK`). It only connects to the serial port while a caller is on.
- **`68kbbs/scripts/emsi-peer.py`**: a ~120-line Python *reference
  answerer* — the exact session `fnemsi` must reproduce, already proven
  against the Mac. Treat it as the executable specification; read it
  before writing C. `68kbbs/scripts/ftn-e2e.sh` drives it on the host.

Missing (this brief):

1. **`fnemsi`** — the EMSI/ZMODEM *answering* mailer over stdio, with
   its store-and-forward hand-off to `fnmailer` (§4–§6).
2. **Modem emulator dialing** — a persistent serial connection, `ATDT`
   with a dial table, and `exec:` targets (§7).
3. **Tests** that replace the Python peer in `ftn-e2e.sh` with the real
   thing (§8).

Everything else — tossing, dupes, threading, AreaFix requests — happens
on the Mac. The bridge never opens a packet.

## 2. Design: store-and-forward around the call

The bridge is a transparent relay that **presents the uplink's address
to the Mac and the Mac's address to the uplink**; packets pass through
untouched. A poll looks like this:

```
Mac                       modem emulator              fnemsi / fnmailer            hub
 │ ATDT<number>\r ─────────▶│ dial table: exec:…        │                            │
 │                          │ spawn wrapper ───────────▶│ fnmailer --once ══════════▶│ binkp: push any
 │                          │                           │   (pre-poll)  ◀═══════════│ held outbound,
 │                          │                           │                            │ fetch inbound
 │ ◀── \r\nCONNECT 57600\r\n│◀── first byte from child ─│ **EMSI_REQ…\r             │
 │ **EMSI_INQ, **EMSI_DAT ─▶│ ────────────────────────▶ │ check pw, **EMSI_ACK ×2,   │
 │ ◀────────────────────────│ ◀──────────────────────── │ **EMSI_DAT (uplink's addr) │
 │ **EMSI_ACK ×2 ──────────▶│                           │                            │
 │ ZMODEM send (our .pkt) ─▶│ ────────────────────────▶ │ ZMODEM receive → outbox/   │
 │ ◀────────────────────────│ ◀──────────────────────── │ ZMODEM send inbox/*.pkt    │
 │ +++ … ATH\r ────────────▶│ SIGTERM child, OK to Mac  │ (child exits)              │
 │ ◀── \r\nNO CARRIER\r\n   │                           │ fnmailer --once ══════════▶│ push what the
 │ toss                     │                           │   (post-poll)              │ Mac just sent
```

Why this shape: no protocol interleaving (binkp never runs while ZMODEM
runs), `fnmailer` is used as-is, the Mac sees a perfectly ordinary
answering mailer, and every failure leaves files on disk to be retried.
The few seconds of binkp before `CONNECT` look like ringing to the Mac,
whose dial timeout is 60 s.

## 3. The Mac's side of the wire (the contract)

This is what `emsi.cla`/`zmodem.cla` actually do. `fnemsi` must accept
all of it; `emsi-peer.py` shows one way.

### 3.1 Modem layer

- The Mac sends `ATDT<dial string>\r` and then waits up to **60 s** for
  `\r\nCONNECT <digits>\r\n`. Anything else it receives in command mode
  (`OK`, `ERROR`, `BUSY`) is ignored; `\r\nNO CARRIER\r\n` or the
  timeout ends the poll with result *no carrier*. Its scanner
  recognises exactly two result codes: `CONNECT <n>` and `NO CARRIER`.
- After the session the Mac sends `+++` (with ~1 s of silence around
  it) and then `ATH\r`, and expects `\r\nNO CARRIER\r\n` back; that is
  what triggers its toss. If it never connected it sends `ATH\r` alone.
- The Mac hangs up on any failure; a 15-minute whole-session cap
  guards against a wedged peer.

### 3.2 EMSI (FSC-0056), Mac = calling system

- After `CONNECT` the Mac waits 1 s, then sends a bare `CR` once a
  second until any byte arrives. It watches for `**EMSI_REQ` (the CR
  that terminates a sequence is required). If none arrives in 20 s it
  sends `**EMSI_INQ` twice unprompted; at 60 s it gives up (*not a
  mailer*).
- On `**EMSI_REQ` it sends `**EMSI_INQ` and immediately its
  `**EMSI_DAT`, then waits for `**EMSI_ACK` (retrying the DAT every
  20 s, six tries; `**EMSI_NAK` also triggers a resend; `**EMSI_HBT`
  resets its timer). After the ACK it waits up to 60 s for *our*
  `**EMSI_DAT`, ACKs it twice, and checks it.
- Sequences are `**EMSI_XXX<crc16><CR>`; the CRC is CRC-16/XMODEM
  (poly 0x1021, init 0, no reflection) over the bytes *after* `**` —
  `EMSI_INQ`→`C816`, `EMSI_REQ`→`A77E`, `EMSI_ACK`→`A490`,
  `EMSI_NAK`→`EEC3`, `EMSI_HBT`→`EAEE`. Hex is uppercase from the Mac;
  accept either case.
- `**EMSI_DAT<len4><data><crc4><CR>`: `len4` is the hex length of
  `<data>`; the CRC covers `EMSI_DAT<len4><data>`. The Mac strips the
  high bit of every received byte before parsing.
- The Mac's DAT data:
  `{EMSI}{21:1/141}{<session password>}{8N1,PUA}{ZMO,NRQ}{00}{68kBBS}{0.2}{0.2}{IDENT}{[68kBBS][][<sysop>][-Unpublished-][57600][]}`
  — one address (its own, with `.point` only if nonzero), a plain
  password, link codes `8N1,PUA`, compatibility `ZMO,NRQ` (plain
  ZMODEM only, no file requests), product code `00` (unregistered).
- What the Mac checks in *our* DAT: field 1 (space-separated address
  list) must contain the uplink's address exactly as configured on the
  Mac (`21:1/100`, no point); field 2 must equal the Mac's session
  password case-insensitively (only when the Mac has one configured).
  Mismatch → it logs, hangs up, records *address mismatch* / *bad
  password*. Fields 6/7 (mailer name/version) are only logged.
  Everything else is ignored, so `{8N1,PUA}{ZMO,NRQ}{FE}{fnemsi}{0.1}{}`
  is fine; a bad DAT CRC gets `**EMSI_NAK` and the Mac keeps waiting.

### 3.3 ZMODEM, the Mac sending first

The caller (Mac) transmits its batch first, then receives ours.

- **Mac as sender.** `rz\r` then a hex `ZRQINIT`; it resends ZRQINIT
  every 5 s and gives up after 60 s without a `ZRINIT`. From our
  `ZRINIT` it honours `CANFC32` (then it uses CRC-32 binary frames,
  `ZBIN32`) and `ESCCTL`. It sends one `ZFILE` (`<8 hex>.pkt` NUL
  `<size>` NUL, `ZCBIN` conversion, no mtime/mode), waits for `ZRPOS`,
  then per 1024-byte block a `ZDATA(pos)` + subpacket ending `ZCRCW`,
  and **waits for `ZACK(pos)`** after each (ack-clocked, one block in
  flight). `ZRPOS` from us rewinds it; it counts ten errors then
  cancels. After the last block: `ZEOF(size)`; on our `ZRINIT` it sends
  `ZFIN`; on our `ZFIN` it sends `OO` and reports success. If we answer
  its `ZFILE` with **`ZCRC(n)`** it replies `ZCRC` with the CRC-32 of
  its first `n` bytes (0 = whole file) so we can resume a partial;
  `ZSKIP` makes it treat the file as delivered. **Empty batch:** when
  the Mac has nothing to send it still runs `rz\r` + `ZRQINIT` and
  answers our `ZRINIT` straight away with `ZFIN`; expect that (lrz
  handles it).
- **Mac as receiver.** After its send completes (our `ZFIN` and its
  `OO`) it sends `ZRINIT` with buffer 1024 and flags `CANFDX|CANFC32`,
  repeating it every 5 s while nothing arrives, 60 s limit. It ignores
  the `rz\r` prefix and handles `ZSINIT`. Each `ZFILE` name is vetted
  (1–31 bytes, no `:`); a refused name gets `ZSKIP`. It then sends
  `ZRPOS(0)` — or, if a partial file of that name exists from an
  interrupted session, `ZCRC(<partial length>)` and, when our `ZCRC`
  answer matches, `ZRPOS(<partial length>)` (else `ZRPOS(0)` and it
  restarts the file). It accepts `ZCRCW`, `ZCRCG` (streaming — `lsz`'s
  default), `ZCRCQ` and `ZCRCE` subpackets, CRC-16 or CRC-32 per the
  header type, `ZACK`s the W/Q ones, writes data at the running offset
  and answers a wrong offset with `ZRPOS`. `ZEOF` at the right offset
  completes the file; then `ZRINIT` for the next. Our `ZFIN` gets its
  `ZFIN`, then it swallows our `OO`. Five `CAN`s from us abort it; it
  cancels with 8×`CAN` 8×`BS`.
- Timeouts on the Mac: 10 s per expected reply, ten-error ceiling.
  Blocks are 1024 bytes; it never uses 8 K (ZedZap) frames. It does
  not require `ESCCTL` and does not escape control characters unless
  asked, and the serial path is 8-bit clean (no telnet layer here).
- Reference implementation with a full unit suite:
  `68kbbs/zmodem.cla` and `68kbbs/tests/zmodem-test.cla`; the same
  engine has been tested against `lrz`/`lsz` in both directions
  (`68kbbs/scripts/xmodem-e2e.sh`). The bridge only needs to be as
  tolerant as `lrz`/`lsz` are — the Python peer literally runs them.

### 3.4 Files

- **Packets only**, type 2+ (FSC-0048), **uncompressed** (no ARCmail
  bundles), any name ending `.pkt`. Outbound from the Mac: one packet
  per poll named `<8 uppercase hex>.pkt` (hex of the Mac's clock), so
  names are unique across polls. Inbound to the Mac: `fnemsi` should
  send the files as it received them from the hub, names unchanged
  (the Mac keeps them only until tossed, and needs them stable only
  for ZCRC resume).
- Packet header password: whatever is configured for the link on the
  Mac; the Mac only *checks* it on inbound packets when it has one
  set. The uplink link on `fnmailer` must be configured with **no
  packer** (the hub sends raw `.pkt`), or `fnemsi`/`fnmailer` must
  unbundle before handing files to the Mac (out of scope for now).

## 4. `fnemsi` — the program

A single C program, `bin/fnemsi`, built from libftn like the other
utilities. **Answer mode only** for now (the Mac never answers). The
line is **stdin/stdout** (raw bytes, 8-bit clean; no line discipline,
no echo, `O_BINARY` where that matters) so the same binary runs under
the modem emulator's `exec:` target, under `socat`, or under a test
harness. Diagnostics go to **stderr** / libftn's `log.c`, never stdout.

```
fnemsi --config FILE --network NAME --answer   [--listen PORT] [--verbose]
```

- `--network` names the `[network]` section (`CONFIG.md`) whose link
  this is; one Mac ↔ one network section. `address` there is the
  **Mac's** FTN address (it is what `fnmailer` presents to the hub),
  `hub` is the uplink. `fnemsi` presents `hub` in its `EMSI_DAT` and
  expects the Mac to present `address`.
- New keys in the network section (all optional except the password):
  - `emsi_password` — the session password the Mac sends (its
    "session password" field). Compared case-insensitively.
  - `emsi_tmp` — where partial ZMODEM receives live (default
    `<outbox>/.emsi-tmp`); completed files are moved into `outbox`.
  - `emsi_sent` — if set, files delivered to the Mac are moved here
    instead of deleted.
  - `emsi_banner` — optional text sent before `EMSI_REQ` (keep it
    free of `*`; the Mac ignores everything but EMSI sequences).
- `--listen PORT` (test mode): accept one TCP connection, expect
  `ATDT…\r`, answer `\r\nCONNECT 57600\r\n`, then behave exactly as in
  answer mode, and on `+++`/`ATH` (or EOF) send `\r\nNO CARRIER\r\n`.
  This makes `fnemsi` a drop-in for `emsi-peer.py` in
  `68kbbs/scripts/ftn-e2e.sh` (§8) without the modem emulator.

### 4.1 Session state machine (answering side, FSC-0056 2A/2B)

1. On start, send `EMSI_REQ` (after the optional banner). **The first
   byte written is what makes the modem emulator send `CONNECT`** to
   the Mac (§7), so do the `fnmailer` pre-poll *before* starting
   `fnemsi`, never inside it.
2. Read the line. Each received `CR` (the Mac whacking) → resend
   `EMSI_REQ`, at most once per second. Ignore everything that is not
   an EMSI sequence. Strip bit 7 before matching.
3. On `**EMSI_INQ`: nothing to send (we already sent REQ); on
   `**EMSI_DAT`: validate length and CRC — bad → `EMSI_NAK`; good →
   `EMSI_ACK` twice, then check field 1 contains `address` and field 2
   equals `emsi_password`. Mismatch → log it and **close the line**
   (exit 1) so the emulator drops carrier — a NAK would only make the
   Mac resend. The Mac records *transfer failed* and its sysop sees
   the failure on the network card.
4. Send our `EMSI_DAT`:
   `{EMSI}{<hub address>}{<emsi_password>}{8N1,PUA}{ZMO,NRQ}{FE}{fnemsi}{<libftn version>}{}`
   and wait up to 60 s for `**EMSI_ACK` (resend every 20 s, six tries;
   `**EMSI_NAK` → resend). Ignore a second `EMSI_ACK`.
5. **Receive** the Mac's batch (ZMODEM receiver, §5) into `emsi_tmp`;
   each completed file is renamed into `outbox`. An empty batch
   (immediate `ZFIN`) is normal.
6. **Send** every `*.pkt` in `inbox` (ZMODEM sender, §5), oldest
   first. After each file's `ZEOF` is acknowledged (the Mac's
   `ZRINIT`), delete it (or move to `emsi_sent`). A `ZSKIP` counts as
   delivered. Nothing to send → send `ZRQINIT`, expect `ZRINIT`, send
   `ZFIN` (the mirror of the Mac's empty batch — `lsz` with no files
   would not do this, so implement it).
7. Wait for the line to drop. In `exec:` mode the emulator kills us
   with `SIGTERM` on the Mac's `ATH` — handle it (flush logs, exit 0).
   In `--listen` mode read until `+++`/`ATH` or EOF and send
   `NO CARRIER`. Exit status: 0 = session completed, 1 = handshake
   failure, 2 = transfer failure (something to retry next poll).

Timeouts on our side: 60 s for the Mac's first sequence, 10 s per
expected ZMODEM reply, ten errors then cancel, and a whole-session cap
of 15 minutes.

### 4.2 The wrapper

The emulator's `exec:` target is a shell script the sysop can edit;
ship it as `scripts/fnemsi-session.sh` in libftn:

```sh
#!/bin/sh
# One Mac poll: pre-poll the hub, answer the Mac, post-poll the hub.
set -e
CFG=${1:?config}; NET=${2:?network}
fnmailer --config "$CFG" --network "$NET" 2>>"$LOG" || true   # fetch inbound, push held
fnemsi   --config "$CFG" --network "$NET" --answer 2>>"$LOG"
fnmailer --config "$CFG" --network "$NET" 2>>"$LOG" || true   # push what the Mac sent
```

(`fnmailer` needs a `--network` filter and a single-network single
shot if it does not have one; check `ftn_mailer_single_shot`.) The
first `fnmailer` must not print to stdout — stdout is the Mac's line.
Redirect it. If the pre-poll fails (hub down) still answer the Mac:
its outbound is captured for the next attempt.

## 5. ZMODEM in C

Decision to make first (§9); recommendation: **implement it in libftn**
(`src/zmodem.c`, `include/ftn/zmodem.h`), for the reasons below. The
alternative is to `fork`/`exec` `lrz`/`lsz` on the line, which the
Python peer does and which works, but leaves resume, per-file
accounting and error reporting in someone else's hands, adds a GPL
runtime dependency to an MIT tool, and behaves differently across
lrzsz versions.

What it must cover (all exercised by the Mac):

- Frames: hex headers (`**\x18B` + 2-hex type + 8-hex + 4-hex CRC-16 +
  CR LF, XON except after ZFIN/ZACK), binary CRC-16 (`*\x18A`) and
  CRC-32 (`*\x18C`) headers; ZDLE escaping (`\x18`, `\x10`, `\x11`,
  `\x13`, `\x90`, `\x91`, `\x93`, and a CR after `@`); subpacket
  ends `ZCRCE/G/Q/W` with CRC-16 or CRC-32 per header type; `ESCCTL`
  when requested by the peer's ZRINIT (the Mac doesn't request it).
- Receiver: `ZRINIT` (offer `CANFDX|CANFC32`, buffer 0 or 1024), parse
  `ZFILE` (name NUL size [mtime mode …]), partial-file resume via
  `ZCRC` then `ZRPOS`, `ZDATA` at the running offset (wrong offset →
  `ZRPOS`), `ZACK` for W/Q subpackets, `ZEOF`, next `ZRINIT`, `ZFIN` +
  swallow `OO`. Accept ZCRCG streaming from `lsz` for the `--listen`
  test path.
- Sender: `rz\r` + `ZRQINIT`, honour the receiver's CRC-32/ESCCTL
  flags, `ZFILE` per file (name NUL size NUL), `ZRPOS`/`ZCRC` handling
  (answer `ZCRC(n)` with the CRC-32 of the first `n` bytes), 1024-byte
  `ZDATA` blocks; use `ZCRCW` (ack-clocked) — the Mac's receiver takes
  streaming too, but ack-clocked keeps the serial path simple; `ZEOF`,
  `ZRINIT`, `ZFIN`, `OO`; `ZSKIP` = delivered; empty batch.
- Cancel: five `CAN`s in a row from the peer = abort; ours is 8×`CAN`
  8×`BS`. Ten-error ceiling; 10 s reply timeouts.
- Byte-at-a-time parser driven from a `read()` loop with a `select()`
  timeout, so the same code serves stdio and a test socket.

Port the state machines from `68kbbs/zmodem.cla` (≈900 lines including
comments; the file header documents every state) and the assertions
from `68kbbs/tests/zmodem-test.cla`. CRC-16/XMODEM and CRC-32 already
exist in libftn (`src/crc.c`, `src/binkp/crc.c`) — reuse them.

## 6. Directories and hand-off to `fnmailer`

Per network section (paths from `CONFIG.md`):

| Path | Written by | Read by | Notes |
|---|---|---|---|
| `inbox` | `fnmailer` (from the hub) | `fnemsi` sends each `*.pkt` to the Mac, deletes (or moves to `emsi_sent`) after its ZEOF is acknowledged | Names unchanged; a file the Mac already holds partially is resumed by ZCRC, so **never rename** a file between polls. |
| `emsi_tmp` | `fnemsi` (partial receives from the Mac) | `fnemsi` | A partial stays here across sessions for resume; complete files are `rename(2)`d into `outbox`. |
| `outbox` | `fnemsi` (the Mac's packets) | `fnmailer` sends them to the hub | If `fnmailer` uses BSO flow files rather than a flat outbox, `fnemsi` must create the `.out`/`.flo` the same way `fnmailer` expects — check `bso.c`/`mailer.c` and follow whatever it does; do not invent a second convention. |

Only `.pkt` files move; anything else in `inbox` is left alone and
logged once. No packet is ever opened by the bridge — packet passwords,
addresses and compression are the endpoints' business.

## 7. Modem emulator changes (`68kbbs/simple-modem-emulator/modem.c`)

Keep everything that exists (a telnet caller on `listen_port` →
`CONNECT`/`NO CARRIER` on the serial side, `+++`/`ATH`/`ATO`), and add:

1. **Persistent serial connection.** Connect to `localhost:connect_port`
   at start and reconnect with backoff (1, 2, 4… up to 30 s) whenever it
   drops (Snow restarted). Callers arriving while the serial side is
   down get dropped as today. Command-mode bytes from the Mac (`AT…`)
   must be parsed *all the time*, not just during a call.
2. **`ATDT<number>` / `ATD<number>`** from the serial side. Look the
   number up in a dial table (a small config file, path from argv or
   `dial.conf` next to the binary; `#` comments; `number = target`):
   - `tcp:host:port` — connect out; on success send `CONNECT 57600`,
     then bridge as for an inbound caller (this is how the Mac calls
     another BBS over telnet — useful on its own).
   - `exec:command line` — spawn `/bin/sh -c "<command line>"` with
     stdin/stdout on a socketpair or pipes bridged to the serial side;
     stderr inherited. **Send `\r\nCONNECT 57600\r\n` when the child
     writes its first byte**, not when it starts — the child does its
     binkp pre-poll first, and the Mac's 60 s dial timeout covers that.
     Child exit or EOF before any output → `\r\nNO CARRIER\r\n`
     (result stays "no carrier" on the Mac). Child exit/EOF later →
     `NO CARRIER`. `+++` then `ATH` from the Mac → `SIGTERM` the child,
     reap it, and answer `\r\nNO CARRIER\r\n` exactly as the emulator
     answers `ATH` today (its README) — the Mac's scanner reacts only
     to `NO CARRIER`, and that is what starts its toss.
   - Unknown number → `\r\nNO CARRIER\r\n` after a short delay.
3. Plain `AT`, `ATZ`, `ATE0`, `ATV1` etc. → `\r\nOK\r\n` (already the
   default). Optional, not needed by the Mac: `RING` for an inbound
   caller before `CONNECT` (the Mac ignores it today).
4. One call at a time, as now: a telnet caller during an outbound call
   is dropped; `ATDT` during a call is ignored.

Suggested `dial.conf` for a sysop:

```
# number = target
555      = exec:/usr/local/bin/fnemsi-session.sh /etc/fnemsi.ini fsxnet
5551212  = tcp:bbs.example.org:23
```

The Mac's network record holds the dial string (`555`), nothing else
about the bridge.

## 8. Testing

1. **Unit tests in libftn** (`tests/test_emsi.c`, `tests/test_zmodem.c`):
   EMSI sequence CRCs (the five constants in §3.2), DAT framing and
   field parsing (nested `[]` in IDENT), the answering state machine
   driven by canned bytes; ZMODEM frame encode/decode round trips and
   a socketpair loopback of the sender against the receiver (with a
   simulated cut and resume).
2. **Against `lrz`/`lsz`** over a socketpair or `socat`: `fnemsi`'s
   receiver vs `lsz --zmodem -b` (streaming ZCRCG) and its sender vs
   `lrz --zmodem -b`, including an interrupted transfer resumed.
3. **Against the Mac side on the host**: in `68kbbs/scripts/ftn-e2e.sh`
   replace `python3 scripts/emsi-peer.py --port …` with
   `fnemsi --config … --network … --answer --listen …` and keep every
   assertion (the harness's packet lands in `outbox`, the fixture
   packets in `inbox` reach the harness and are tossed, marks move).
   The two fixture packets are `68kbbs/tests/fixtures/*.pkt` (real
   fsxNet packets: one echomail for `FSX_ADS`, one Areafix netmail).
4. **Against the real Mac** (Snow): modem emulator with the dial
   table → `fnemsi-session.sh`; on the Mac, Sysop → Networks → Show →
   `P` queues a poll that runs at logoff (or `FidoNet > Poll All
   Networks` from the Mac's menu). Expect on the Mac's network card:
   `Last poll … (ok)`; the hub's echomail on the mapped board; the
   Mac's post in the hub's inbound. `68kbbs/docs/fidonet.md` §"Status"
   describes the same run done with the Python peer.
5. **Against fsxNet for real**: `fnmailer` link configured with no
   packer on the hub side (ask the hub sysop), the Mac subscribed via
   AreaFix from its sysop menu.

## 9. Open decisions (make them early, write them down in the code)

1. **ZMODEM: implement in C (recommended) or exec `lrz`/`lsz`.** §5.
2. **`fnmailer` single-network single shot**: does `ftn_mailer_single_shot`
   accept a network filter, and does it exit nonzero when the hub is
   unreachable? The wrapper depends on both.
3. **Outbox convention**: flat `outbox/*.pkt` or BSO flow files —
   whichever `fnmailer` already sends from (§6). If the hub link ever
   needs a packer, this is where bundling would go.
4. **Where the `exec:` child's stderr goes** (`$LOG` in the wrapper vs
   the emulator's own stderr).
5. **libftn does not currently build on this machine** (`src/ftn.c`,
   6 compiler errors at `make`, 2026-08-26). Fix that first; the
   packet tools (`pktview`, `pktlist`) are also how the Mac's packets
   get inspected.

## 10. References

- Protocol texts: `68kbbs/docs/ftn/` (all FTSC documents; libftn's own
  `docs/` has the same set). Essential: FSC-0056 (EMSI), FTS-0001 and
  FSC-0048 (packets), FTS-0004 (echomail), FSC-0016 (session startup),
  the ZMODEM reference (Forsberg's `zmodem.txt`; the Mac code comments
  in `68kbbs/zmodem.cla` summarise the parts used).
- The Mac side: `68kbbs/docs/fidonet.md` (design), `68kbbs/emsi.cla`
  (caller state machine, with the exact timeouts and byte sequences),
  `68kbbs/zmodem.cla`, `68kbbs/tests/emsi-test.cla` (the canned
  session, readable as a transcript).
- The executable spec of the answering side:
  `68kbbs/scripts/emsi-peer.py`; its harness `68kbbs/scripts/ftn-e2e.sh`.
- libftn: `CONFIG.md`, `FNMAILER.md`, `include/ftn/{bso,mailer,packet,
  binkp}.h`, `src/crc.c`.
