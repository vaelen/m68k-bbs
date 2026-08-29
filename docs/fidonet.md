# FidoNet support (v0.2) — design

Netmail and echomail for 68kBBS as a **leaf node** on an FTN network
(fsxNet first), over the modem port, with the binkp side handled by a
bridge on the host. Standards referenced are in `docs/ftn/`;
`docs/fidonet-standards.md` lists the ones that matter.

## Scope

In v0.2:

- One uplink per network, no downlinks, no points of our own, no
  routing. Echomail is never forwarded; SEEN-BY/PATH are read and
  dropped. Netmail always goes to the uplink for routing.
- The Mac only **polls** (calls out). It never answers a mail call.
- Type-2+ packets (FSC-0048), uncompressed both ways. The uplink link
  is configured with no packer; ARCmail bundles are not handled.
- Session protocol EMSI (FSC-0056) with plain ZMODEM (`ZMO`), reusing
  `zmodem.cla`.
- ASCII text both ways (high bytes become `?`).

Deferred (`TODO.md`): CP437/LATIN-1/UTF-8 ↔ MacRoman tables,
ARCmail/inflate, bridge-as-caller (crash mail; needs the Mac's EMSI
answer side), an outbound netmail queue screen, a per-user netmail
gate, a registered FTSC product code, an in-app binkp client once
Clarus has TCP.

## Architecture

```
68kBBS (Mac, modem port)              host
┌──────────────────────┐   serial    ┌──────────────────┐  stdio  ┌─────────┐  binkp  ┌────────┐
│ scan → dial → EMSI → │ ══════════▶ │ modem emulator   │ ◀═════▶ │ fnemsi  │ ◀═════▶ │ fsxNet │
│ ZMODEM → hang up →   │  ATDT nnn   │ ATDT → exec:...  │         │ fnmailer│         │  hub   │
│ toss                 │             │ CONNECT/NO CARRIER         │ (libftn)│         └────────┘
└──────────────────────┘             └──────────────────┘         └─────────┘
```

The Mac speaks real FTN over a modem: Hayes dialing, EMSI, ZMODEM,
`.pkt` files. Nothing on the Mac knows about binkp. The bridge is a
store-and-forward relay that presents the uplink's address to the Mac
and the Mac's address to the uplink; packets pass through it untouched.
A real modem on a real line to a real mailer works with no changes.

## Modules (Mac side)

| File | Purpose |
|---|---|
| `ftnaddr.cla` | `FtnAddress` record (zone/net/node/point), `parseAddress`, `addressStr` |
| `networksdb.cla` | the "Networks" vDB |
| `ftnpkt.cla` | type-2+ packet reader/writer over a `filehandle` — pure, no DB knowledge |
| `ftntoss.cla` | toss (inbound packets → boards/mail) and scan (boards/mail → outbound packet) |
| `emsi.cla` | EMSI caller state machine and the poll sequence |
| `boardsdb.cla`, `postsdb.cla`, `maildb.cla` | record layouts extended (below) |
| `sysop.cla` | Networks menu tree; Network/Echo tag fields on the board card and wizard |
| `mail.cla`, `boards.cla`, `editor.cla` | netmail addressing, MSGID/REPLY generation, `^A` line hiding |
| `bbs.cla` | `"ftn"` screen routing, `Network` menu, scheduler hook in the 30-tick timer |

## Data

All records are big-endian vDB records (`docs/vdb-clarus.md`). Formats
are not frozen: existing `Boards.*`, `Mail.*` and `BRD*` files on test
images are recreated, no migration code.

### Networks (`networksdb.cla`, "Networks", 256 bytes, record ID = network ID)

| Off | Size | Field |
|---|---|---|
| 0 | 32 | name (Pascal), e.g. `fsxNet` |
| 32 | 32 | domain (Pascal), e.g. `fsxnet` |
| 64 | 8 | our address: zone, net, node, point (4 × u16) |
| 72 | 8 | uplink address (4 × u16) |
| 80 | 16 | session password (Pascal) |
| 96 | 8 | packet password (Pascal; FTS-0001 caps it at 8) |
| 104 | 16 | AreaFix password (Pascal) |
| 120 | 32 | AreaFix robot name (Pascal; default `AreaFix`) |
| 152 | 32 | dial string (Pascal; what follows `ATDT`) |
| 184 | 2 | UTC offset, minutes (i16) |
| 186 | 2 | poll interval, minutes (u16; 0 = manual only) |
| 188 | 2 | flags (u16; bit 0 = enabled) |
| 190 | 4 | lastPoll (i32, Mac-epoch seconds; 0 = never) |
| 194 | 1 | lastResult (u8, see Poll results) |
| 195+ | | reserved |

Addresses are entered and shown as `21:1/100` or `21:1/100.5`.

### Boards (`boardsdb.cla`, 256 bytes; replaces the 16-byte `network` string)

| Off | Size | Field |
|---|---|---|
| 0 | 64 | name (Pascal) |
| 64 | 64 | description (Pascal) |
| 128 | 64 | echo tag (Pascal; empty = local board) |
| 192 | 4 | networkId (i32; 0 = local) |
| 196 | 4 | lastExported (i32; highest post ID already scanned out) |
| 200 | 2 | flags (u16; bit 0 = subscribed via AreaFix) |
| 202+ | | reserved |

A board is *networked* when `networkId ≠ 0` and the tag is non-empty.
One board ↔ one echo. Tag lookup at toss time uses a list of all tags
loaded once per toss (≤ 99 boards); no index. `lastExported` is
written only by scan; deleting posts never touches it.

### Posts (`postsdb.cla`, 160 bytes — the 16 reserved bytes)

| Off | Size | Field |
|---|---|---|
| 144 | 4 | msgidCrc (u32, indexed: `crc32` of the full `MSGID` string; 0 = none) |
| 148 | 8 | origin address (4 × u16; zeros for local) |
| 156 | 2 | flags (u16; bit 0 = inbound from the network) |
| 158 | 2 | reserved |

### Mail (`maildb.cla`, 256 bytes — bytes 214+)

| Off | Size | Field |
|---|---|---|
| 214 | 8 | fromAddr (4 × u16) |
| 222 | 8 | toAddr (4 × u16) |
| 230 | 4 | msgidCrc (u32) |

The existing `flags` field (offset 212) gains bit 1 = *sent*.

`toAddr ≠ 0` with `toUserId = 0` is outbound netmail; `fromAddr ≠ 0`
with `fromUserId = 0` is inbound. Local mail leaves both zero.

## Message text conventions

- Lines end in CR (the Mac newline). On input, LF is dropped and
  soft-CR `0x8D` is dropped.
- Kludge lines start with `^A` (0x01). Echomail's first line is
  `AREA:TAG` with no `^A`.
- Stored bodies **keep** `^A` kludges (`MSGID`, `REPLY`, `CHRS`,
  `TZUTC`, `PID`, …) and **drop** `AREA:`, `SEEN-BY:` and `^APATH:`.
  Tearline (`--- …`) and ` * Origin:` stay visible.
- Readers (boards, mail) hide lines beginning with `^A`.
- Charset (v0.2): outbound bytes ≥ 0x80 become `?` and messages carry
  `^ACHRS: ASCII 1`; inbound bytes ≥ 0x80 become `?` regardless of the
  sender's `CHRS`. The stored `CHRS` kludge lets old messages be
  re-rendered when the tables land.

## MSGID, REPLY and threading (FTS-0009)

- Every post created on a networked board, and every outbound netmail,
  gets `^AMSGID: <our address> <8-hex serial>` at the top of its body
  at creation. Serial = `now()`, bumped past a global `lastSerial` so
  two messages in one second stay unique. `msgidCrc = crc32(MSGID)`.
- A locally written reply gets `^AREPLY: <parent's MSGID>` from the
  parent's body at compose time (the editor knows the parent). Scan
  emits what is stored.
- Inbound `REPLY:` → look up its CRC in the board's index → `threadId`
  = that post's `threadId`, or its own ID if it is a starter. No match
  → thread starter.
- Dupe: a message whose `msgidCrc` already exists in the target board
  is dropped (logged and counted). CRC-32 collisions at leaf volume are
  accepted. Messages without a `MSGID` are never dupe-checked.

## Packets (`ftnpkt.cla`)

Type-2+ (FSC-0048): the 58-byte header with `capWord = 0x0001` and
`capValid`, orig/dest zone, net, node, point, product code, the 8-byte
packet password from the network record; packed messages per FTS-0001
(type 2; orig/dest net + node; attributes; cost; 20-byte
`dd Mon yy  hh:mm:ss` date; To/From/Subject NUL-terminated within
36/36/72; body NUL-terminated); `00 00` trailer. All integers
little-endian via `text`'s LE accessors.

API: `pktOpenRead(path): bool`, `pktNextMsg(msg: PktMsg): bool`,
`pktCreate(path, net: Network): bool`, `pktAddMsg(msg)`, `pktClose()`.
Packet header time is local time at creation. Dates convert with
`SecondsToDate`/`DateToSeconds` (`toolbox/osutils.cla`).

Files:

- `:FTN:`, `:FTN:In:`, `:FTN:Out:`, `:FTN:Tmp:` beside the app,
  created on first use — each guarded by `file.exists` and made with
  one `file.makeDir` call, parent first (`makeDir` is one level and
  fails on an existing folder).
- Inbound files are **received into `:FTN:Tmp:`** under the names the
  bridge sends (`<8-hex>.pkt`) and **moved into `:FTN:In:`**
  (`file.move`) when their ZEOF is acknowledged. So `:FTN:In:` only
  ever holds complete packets, and a partial stays in `:FTN:Tmp:`
  where the ZMODEM receiver's ZCRC resume looks for it.
- Outbound is `:FTN:Out:<nn>.pkt` per network ID, rebuilt by every
  scan and deleted after an acknowledged send (handle closed first —
  `file.delete` fails on an open file on the Macintosh).

## Toss (`ftntoss.cla`)

Runs after a poll, with the line idle. For every file in `:FTN:In:`:

1. Skip folders (`file.info(path).isDir`); `file.list` returns both.
2. Header sanity: type 2, dest address equals our address on some
   enabled network, packet password matches ours if set. Else log,
   skip the file.
3. Per message:
   - `AREA:` present → echomail. Find the board with that tag
     (case-insensitive) on that network; unknown → counted, dropped.
     Dupe check. Date + `TZUTC` → Mac-epoch (no `TZUTC` → taken as
     our local time). Body normalized. `addPost` with sender name,
     subject, thread per REPLY, origin address, flag *inbound*.
   - No `AREA:` → netmail. `To:` → `findUserId` (case-insensitive);
     unknown recipient → delivered to the sysop (user 1) with the
     original name kept in `toName`. `fromUserId = 0`, `fromAddr`,
     `toAddr`, `msgidCrc` set. AreaFix replies arrive this way.
4. `pktClose()`, then delete the file. Log `tossed n echomail,
   m netmail, d dupes, x expired, u unknown areas`. Before the dupe
   check, a message older than the board's `keepDays` (0 = never) is
   counted as *expired* and not stored (`docs/maintenance.md`).

A crash mid-toss re-tosses the file next time; dupe checking makes that
safe.

## Scan (`ftntoss.cla`)

Runs before dialing, per network:

- Echomail: posts with `id > lastExported` on the network's boards
  whose flag *inbound* is clear. Each becomes: `AREA:TAG`, the body's
  kludges, `^ATZUTC`, `^APID: 68kBBS 0.2`, body, `--- 68kBBS 0.2`,
  ` * Origin: <BBS name> (<our address>)`,
  `SEEN-BY: <our net/node> <uplink net/node>`, `^APATH: <our net/node>`.
- Netmail: Mail records with `fromUserId ≠ 0`, `toUserId = 0`, *sent*
  clear. Dest = the recipient's address; `^AINTL <dest> <orig>` always;
  `^AFMPT`/`^ATOPT` only for nonzero points; attributes Private + Local.
- Nothing pending → no packet; the poll still runs for pickup.
- Marks (`lastExported`, *sent* bits) advance only after the ZMODEM send
  of the packet was acknowledged. A failed session resends next time.

## Netmail in Mail (`mail.cla`)

- Compose: `To:` as today; when the name is not a local user, prompt
  `Address (zone:net/node):` — empty cancels, unparsable re-prompts.
  The zone picks the network (first enabled network whose address has
  that zone; none → `No network for zone N`). Stored with `fromAddr` =
  our address on that network, `MSGID` kludge, *sent* clear. Any
  authenticated user may send netmail.
- Inbox/view: inbound netmail shows `Name (21:1/100)` for the sender;
  the To line shows the original name when delivered to the sysop as
  unknown-recipient mail. `R` replies to `fromName` at `fromAddr` with
  `Re:` and a `REPLY` kludge, no address prompt.
- Outbound netmail is in no inbox. After an acknowledged send it is
  marked *sent* and kept. The network card shows `Pending: n netmail,
  m posts`.

## Sysop screens (`sysop.cla`)

- Sysop menu `N`etworks: the same L/S/E/N/D tree as boards and areas
  over the Networks record, plus on the detail card **`P` Poll**
  (queues a poll for after logoff — the sysop is on the line) and
  **`A` AreaFix** (prompt for `+TAG`, `-TAG` or `%LIST`; queues a
  netmail to the robot with the AreaFix password as the subject).
  Card shows last poll time, result and pending counts.
- Board card and New Board wizard gain **Network** (ID-or-name via
  `parseIntStr`; 0/blank = local) and **Echo tag**. Board lists show
  the tag beside networked boards.
- Mac menu bar: `Network > Poll All Networks` for the sysop at the
  machine (runs now if the line is idle).

## Poll (`emsi.cla`, screen `"ftn"`)

Triggers, all through `ftnPollRequest(netId)`: the 30-tick scheduler
(no caller, network enabled, `pollInterval > 0`, `now() - lastPoll ≥
interval`); the Mac menu; the remote sysop's queued `P`, started by
`disconnected()` once the modem is back in command mode. One network
at a time; the line is off-hook so no caller can connect.

`inputChar` hands raw bytes to `emsiChar` while `user.screen == "ftn"`;
the 30-tick timer calls `emsiTick`; `disconnected()` calls `emsiAbort`.
Output goes through `xferOut`.

1. **Scan** builds the outbound packet if anything is pending.
2. **Dial** `ATDT<dial string>`. Scanner `CONNECT` → `connected()`
   sees `ftnPolling` and enters `"ftn"` instead of the telnet probe.
   `NO CARRIER`, or no `CONNECT` within 60 s → `ATH`, result
   *no carrier*.
3. **Init** (FSC-0056 step 1): wait 1 s; send `CR` once a second until
   any byte arrives; on `**EMSI_REQ` send `**EMSI_INQ`; none within
   20 s → send `EMSI_INQ` twice and keep watching; 60 s → *not a
   mailer*.
4. **Handshake** (2B, then 2A): send our `EMSI_DAT`
   `{EMSI}{<our address>}{<session pw>}{8N1,PUA}{ZMO,NRQ}{00}{68kBBS}{0.2}{<build>}{IDENT}{[<BBS name>][][<sysop>][-Unpublished-][57600][]}`,
   retried every 20 s up to 6 times until `EMSI_ACK`. Then receive
   theirs: check length and CRC-16 (`text.crc16x`), `ACK` twice, parse.
   Their address list must include the uplink's address (*address
   mismatch*); their password must equal ours (*bad password*).
   `EMSI_HBT` resets the wait; `EMSI_NAK` → resend. Product code `00`
   until one is registered.
5. **Send**: the caller goes first. `zmodemSendStart` on the outbound
   packet, or an **empty batch** (ZRQINIT → ZRINIT → ZFIN → `OO`) when
   nothing is pending — the one addition the ZMODEM sender needs.
6. **Receive**: `zmodemRecvStart(":FTN:Tmp:")` until the peer's ZFIN;
   `xferReceived` moves each completed file into `:FTN:In:`. ZCRC
   resume covers a file cut off last time.
7. **Hang up** via `hangupPhase` (`+++`, `ATH`); `NO CARRIER` resets
   the line.
8. **After**: toss; delete the outbound packet and advance the marks if
   step 5 was acknowledged; write `lastPoll` and `lastResult`; log
   `<net>: sent n, received m files, tossed …`.

Any failure → `emsiAbort`, hang up, result recorded, marks untouched.
Carrier loss during a transfer arrives as the scanner's `NO CARRIER`.
A 15-minute whole-session cap guards against a wedged peer.

Poll results (`lastResult`): 0 never, 1 ok, 2 no carrier, 3 not a
mailer, 4 bad password, 5 address mismatch, 6 transfer failed,
7 timeout.

## Bridge contract (host side)

### `simple-modem-emulator`

- Connects to Snow's serial bridge (`:1234`) at start; reconnects every
  10 s, silently, when it drops. Keeps listening on `:2323` for human
  callers (`CONNECT 57600`, `NO CARRIER`; no `RING`) as before.
- Hayes from the serial side: `AT`, `ATZ` → `OK`; `ATDT<number>`;
  `+++`/`ATH` as today. Numbers resolve through an optional `dial.conf`:
  `name = tcp:host:port` (telnet out to another system) or
  `name = exec:<command>` (spawn with stdin/stdout on the line, as
  `socat exec:` does); a string with no entry is dialed as `host[:port]`.
  Unknown → `NO CARRIER`.
- `exec:` targets: `CONNECT 57600` is sent when the child writes its
  first byte; child exit before any output, or exit/EOF later →
  `NO CARRIER`; `ATH` → `SIGTERM` the child, `OK`. The child does its
  binkp pre-poll before its first byte; the Mac's 60 s dial timeout
  covers it.
- No libftn dependency; no protocol knowledge.

### `fnemsi` (libftn)

A serial-line EMSI/ZMODEM mailer over stdio, run as the `exec:` target
through a wrapper: `fnmailer --once` → `fnemsi --answer` →
`fnmailer --once`. Answer mode only in v0.2. Toward the Mac:

- Presents the **uplink's** address in `EMSI_DAT`; checks the Mac's
  session password against its own `[link]` config. The Mac never
  holds the binkp password. Sends `EMSI_REQ` on start and on each
  `CR`; link codes `8N1`, compat `ZMO,NRQ`.
- Receives the caller's batch first, then sends its own. ZCRC resume
  both ways; `ZSKIP` for a name it already has complete.
- Uncompressed type-2+ packets only. Files to the Mac come from
  `fnmailer`'s inbound directory with their `<8-hex>.pkt` names kept
  stable until the Mac's ZEOF is acknowledged, then deleted. The Mac's
  `<nn>.pkt` goes into the BSO outbound for the uplink (`bso.c`;
  merged `pktjoin`-style with an unsent `.out`).
- The uplink link is configured with the Mac's address and no packer.
- ZMODEM in C: implement in libftn (`zmodem.c`; the Mac side and
  `tests/zmodem-test.cla` are a working reference) rather than exec
  `lrz`/`lsz`. Detailed in the libftn spec.

## Testing

- Host-lane units (`scripts/test.sh`): `tests/ftnaddr-test.cla`,
  `tests/ftnpkt-test.cla` (round-trip; libftn `examples/*.pkt`
  fixtures), `tests/ftntoss-test.cla` (threads, dupes, unknown areas,
  netmail to user/sysop, date + TZUTC; scan back out), `tests/emsi-test.cla`
  (canned handshakes, retry, bad CRC, wrong password, address
  mismatch). Boards/Mail DB tests updated for the new layouts.
- Cross-check: our packets validated with libftn's `pktview`/`pktlist`;
  `pktnew` packets tossed by us.
- `scripts/ftn-e2e.sh`: host-lane BBS (`CLARUS_SERIAL_MODEM`) ⇄ modem
  emulator ⇄ `fnemsi` in loopback with a local `fnmailer` peer as the
  hub; asserts the outbound packet arrives byte-identical, the inbound
  packet lands in the right board with the right thread links, marks
  advanced and files deleted.
- Snow: `scripts/deploy.sh`, `Poll All Networks`, then read `out` for
  the summary line; board lists show the tossed messages.

## Language features required

All shipped in the Clarus filesystem-api phase (2026-08-26) and in the
pinned toolchain; the as-shipped shapes and what the design does about
them:

- `file.makeDir(path): bool` — one level, parent must exist, existing
  folder is a failure → guard with `file.exists`, create parent first.
- `file.delete(path): bool` — fails on an open file (Mac) → close
  handles before deleting.
- `file.list(path, names: list of string): bool` — leaf names of files
  and folders, catalog order → toss skips `isDir` entries.
- `file.move(path, dirPath): bool` — completed inbound packets move
  from `:FTN:Tmp:` to `:FTN:In:`, replacing any "is this file
  complete?" heuristic.
- `file.exists`, `file.info` — folder guards; `isDir`; a pending
  outbound packet is simply `file.exists(":FTN:Out:<nn>.pkt")`.

Spikes, now answered (Clarus filesystem-api phase, Task 1, 2026-08-26):
`file.open` on nested partial paths (`:FTN:In:x.pkt`) opens natively
with no code changes — verified on Mini vMac/System 6. Host-lane C
glue for `ReadDateTime`/`SecondsToDate`/`DateToSeconds` shipped the
same phase (Task 6), so a host-lane toss/scan build links against all
three.

## Build order

1. ~~Language features + spikes~~ — done (toolchain pin refreshed
   2026-08-26).
2. Data: Networks DB, Boards/Posts/Mail layouts, `ftnaddr.cla`, sysop
   Networks tree and board fields.
3. `ftnpkt.cla` + toss/scan, MSGID/REPLY generation, `^A` hiding,
   netmail compose/view. Fully testable on the host lane with fixture
   packets.
4. `emsi.cla`, empty-batch ZMODEM send, scheduler, Mac menu, queued
   poll.
5. Bridge: modem emulator dialing; `fnemsi` in libftn (own spec);
   `scripts/ftn-e2e.sh`.

## Status (2026-08-26)

The Mac side is built: `ftnaddr.cla`, `networksdb.cla`, `ftnpkt.cla`,
`ftntoss.cla`, `emsi.cla`, the record changes in `boardsdb.cla`/
`postsdb.cla`/`maildb.cla`, netmail in `mail.cla`, the sysop Networks
tree in `sysop.cla`, and the poll wiring in `bbs.cla` (screen `"ftn"`,
the `FidoNet > Poll All Networks` menu, the scheduler). Host-lane
suites cover every module, and `scripts/ftn-e2e.sh` runs a whole poll
against a Python stand-in for the bridge (`scripts/emsi-peer.py`) with
real `lrz`/`lsz`. Two deviations from the text above: the Mac menu is
named `FidoNet` (a `Network` menu would clash with the `Network`
record type), and the wire name of our outbound packet is
`<8-hex of now()>.pkt` rather than `<nn>.pkt`, so the bridge never sees
two polls' packets under one name. Verified on Snow (Mac II, System 7) as well: with the sysop's queued
poll dialing through the modem emulator and `emsi-peer.py --connect`
answering as the mailer, the Mac's packet arrived intact, both fixture
packets were tossed into the right board and inbox, and the network
card recorded the poll as ok. The bridge (`fnemsi` in libftn and the
modem emulator's dialing) is the remaining piece; the deferrals are in
`TODO.md`.

Update (2026-08-29): the modem emulator side of the bridge is done —
persistent serial connection, `ATDT` to `host[:port]`, `dial.conf`
`tcp:`/`exec:` targets, `CONNECT` on the child's first byte, `SIGTERM` on
hang-up (`simple-modem-emulator/README.md`). Wiring `fnemsi` is one
`dial.conf` line (`dial.conf.example`). `scripts/emsi-peer.py --connect`,
which faked a successful dial by calling in, is gone.
