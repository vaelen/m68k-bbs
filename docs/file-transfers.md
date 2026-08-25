# File Transfers

How 68kBBS moves files over the modem: the transfer plumbing in
`bbs.cla`, the senders and receivers in `xmodem.cla` and `zmodem.cla`,
what the caller sees, how to test it, and where Kermit plugs in. The storage
side (areas, file entries, `filePath`) is `docs/files.md`.

**Status:** XMODEM, XMODEM-1K, YMODEM and ZMODEM in both directions —
download (BBS → caller) and upload (caller → BBS, entered pending sysop
approval). ZMODEM resumes an interrupted transfer either way, and a
ZMODEM or YMODEM upload takes several files in one batch. Data fork
only. No Kermit, no MacBinary yet.

## The plumbing

A transfer is just another `user.screen`, `"xfer"`, so the existing
session dispatch carries it:

- **Bytes in.** `inputChar` (bbs.cla) checks for `"xfer"` first and
  hands every raw byte to `xferChar(c)` — before the linemode/hotkey
  assembly, so nothing is buffered, echoed or interpreted. The
  scanner and telnet layers stay in front, on purpose: telnet clients
  in binary mode send data byte 0xFF as `IAC IAC`, which `telnet.cla`
  already folds back to one byte, and the scanner still notices a
  `NO CARRIER` if the line drops mid-transfer.
- **Bytes out.** `xferOut(t: text)` sends the frame through
  `telnetSend(modem, …)` in 255-byte slices (frames are 1 KB and
  more; strings cap at 255): IAC doubling for telnet callers, no
  `trackOutput` (binary doesn't move the cursor).
- **Time.** The `every 30 ticks` timer calls `xferTick()` on the `"xfer"`
  screen. One tick = ½ s, the unit for every engine timeout.
- **Echo.** `echoActive()` is false on `"xfer"` (like the probe and
  logoff screens) so ACKs never bounce back onto the line.
- **Line drop.** `disconnected()` calls `xferAbort()` before the session
  reset: the engine closes its file and says nothing.
- **Done.** The engine calls `xferDone(ok)` (files.cla) once it is
  already idle, so the callback may safely redraw screens and never
  re-enters the engine. An upload also calls `xferReceived(name, bytes)`
  once per file, before `xferDone`, and vets names off the wire through
  `xferAcceptName(name)` (1-31 characters, no colon, not already in
  this area).

`xferStart(proto, path, name)` / `xferChar` / `xferTick` / `xferAbort`
are a `switch` on `xferProto: char` — `'X'`, `'1'` and `'Y'` go to
`xmodem.cla`, `'Z'` to `zmodem.cla`. A new protocol is a new module
plus one case in each.

## The XMODEM/YMODEM sender (`xmodem.cla`)

One engine, three modes (`xmodemSendStart(path, name, mode)`):

- `'X'` **XMODEM**: 128-byte blocks; CRC-16 if the receiver opens with
  `C`, 8-bit checksum if it opens with NAK.
- `'1'` **XMODEM-1K**: 1024-byte `STX` blocks while at least 1 KB
  remains, 128-byte `SOH` blocks for the tail (less padding). CRC or
  checksum as above.
- `'Y'` **YMODEM**: XMODEM-1K/CRC plus **block 0** before the data —
  `SOH 00 FF`, `"name NUL size NUL"` NUL-padded to 128, CRC — and an
  all-NUL block 0 after the EOT to close the batch. The receiver
  learns the exact size, so no `^Z` padding survives. One file per
  batch. NAK at the start is ignored (YMODEM is CRC-only).

Pure: it touches the world only through `readAt` on its own
`filehandle`, `xferOut`, `xferDone`, and `log`. One unit of work per
byte or tick; it never waits.

| State | Byte | Action |
|---|---|---|
| waitStart | `C` (or NAK, not `'Y'`) | set CRC/checksum; `'Y'`: send block 0 → waitHeaderAck; else send block 1 (or EOT if empty) |
| waitStart | 120 ticks (60 s) | give up: `CAN CAN CAN`, `xferDone(false)` |
| waitHeaderAck | ACK | → waitDataStart |
| waitDataStart | `C` | send block 1 (or EOT) |
| waitAck | ACK | advance by the block's data bytes; next block, or EOT past the end |
| waitAck | NAK or 20 ticks (10 s) | error + 1; resend the same frame |
| waitEotAck | ACK | `'Y'`: → waitBatchStart; else `xferDone(true)` |
| waitEotAck | NAK or 20 ticks | error + 1; resend EOT |
| waitBatchStart | `C` | send the empty block 0 → waitEndAck |
| waitEndAck | ACK | `xferDone(true)` |
| any | `CAN CAN` (consecutive) | caller cancelled: `xferDone(false)`, nothing sent |
| any | 10th error | `CAN CAN CAN`, `xferDone(false)` |

Frames: `SOH, blk, 255-blk, 128 data bytes` or `STX, blk, 255-blk,
1024 data bytes`, then `CRC-16 hi, lo` or the 8-bit sum. The last
block is padded with `^Z` (0x1A); XMODEM carries no length, so an
XMODEM receiver's file is rounded up to a block multiple — inherent
to the protocol (YMODEM's block 0 fixes it). Block numbers start at 1
and wrap 255 → 0. The last frame is kept in `xmLast` (a `text`) and
resent verbatim. The two YMODEM waits for a `C` have nothing to
resend: a timeout there just counts an error. Other bytes in any
state are ignored (a receiver re-sending `C` while a block is in
flight, prompt echo, line noise).

The CRC is the runtime's `text.crc16x` — CRC-16/XMODEM (poly `0x1021`,
init 0, no reflection, no final XOR; `"123456789"` → `0x31C3`). The
runtime's `text.crc16` is CRC-16/KERMIT, a different algorithm.

`conn.send` on the Mac is `PBWriteSync`: a 1029-byte frame blocks the
event loop for ~0.2 s at 57600 bps, during which incoming bytes queue
in the 8 KB serial buffer — harmless for a half-duplex protocol.

## Receiving (uploads)

`xmodemRecvStart(mode, folder, name)` runs the same three modes
backwards, in its own `rv*` state machine (the public
`xmodemChar`/`Tick`/`Abort` dispatch to whichever direction is live):

- **Starting.** Send `C` at once and again every 3 s; for `'X'`/`'1'`,
  after four unanswered `C`s fall back to `NAK` (checksum) for old
  senders. Nothing after 60 s → `CAN CAN CAN`, `xferDone(false)`.
- **A frame** is assembled byte by byte — `SOH`/`STX` picks 128/1024,
  then block number, complement, payload, CRC or checksum. A good
  frame with the expected number → `writeAt` at the running offset,
  `ACK`. A repeat of the previous block means our `ACK` was lost:
  `ACK` again and store nothing.
- **A bad frame** (complement or check mismatch) → wait for 1 s of
  silence, then `NAK`, so the rest of the in-flight block isn't parsed
  as a new one. Ten errors → `CAN CAN CAN`.
- **`EOT`** → `ACK`, `flush`, and for YMODEM `setSize` to the size
  block 0 gave (trimming the `^Z` padding), then `xferReceived`.
  `'X'`/`'1'` finish there; `'Y'` sends `C` for the next block 0.
- **YMODEM block 0** carries `name NUL size NUL`; a path is reduced to
  its last segment, the name is vetted through `xferAcceptName`, and
  an all-NUL block 0 ends the batch (`xferDone(true)`).

An aborted upload leaves the partial file on disk — there is no
`file.delete` yet (`docs/language-gaps.md` §3) — but no database entry,
so the same name can simply be uploaded again (`file.create`
truncates).

## ZMODEM (`zmodem.cla`)

One module, both directions, the same four hooks and callbacks.
Frames: **hex headers** (`** ZDLE B` + type and four little-endian
position/flag bytes as hex + CRC-16 as hex + CR LF, XON after all but
ZFIN/ZACK) for everything a receiver says and for ZRQINIT/ZFIN;
**binary headers** (`* ZDLE C` + escaped bytes + CRC-32 low byte
first, or `* ZDLE A` + CRC-16 high byte first) for ZFILE/ZDATA/ZEOF;
**data subpackets** (escaped bytes, `ZDLE` + frame end `h`/`i`/`j`/`k`
= ZCRCE/ZCRCG/ZCRCQ/ZCRCW, CRC over data and frame end). CRC-32 is
`text.crc32` (seed and final XOR applied by the engine; `"123456789"`
→ `0xCBF43926`); CRC-16 is `text.crc16x`. We send CRC-32 frames when
the receiver's ZRINIT has CANFC32 (lrz always does), CRC-16 otherwise;
a frame's CRC width follows its header format on the way in. ZDLE
escaping covers ZDLE, DLE/XON/XOFF (with and without bit 7), CR after
`@`, and — when the receiver asks (ESCCTL) — every control byte plus
`ZRUB0`/`ZRUB1` for 0x7F/0xFF. Five consecutive CANs from the peer end
the transfer (`xferDone(false)`, nothing sent); our own give-up is
eight CANs and eight backspaces.

**Download** (`zmodemSendStart(path, name)`):

| State | Event | Action |
|---|---|---|
| waitRinit | start | `rz` CR + ZRQINIT (hex); repeat every 10 s, give up at 60 s |
| waitRinit | ZRINIT | note CANFC32/ESCCTL; ZFILE (binary) + `name NUL size NUL` subpacket (ZCRCW) → waitRpos |
| waitRpos/waitAck | ZCRC(n) | reply ZCRC with the CRC-32 of our first n bytes (0 = all) so the receiver can verify a partial |
| waitRpos | ZRPOS(p) | resume at p: ZDATA(p) + 1 KB subpacket (ZCRCW) → waitAck |
| waitRpos | ZSKIP | receiver has it: ZFIN → waitFin, ends `xferDone(false)` |
| waitAck | ZACK(p) | continue from p: next ZDATA + subpacket, or ZEOF(size) → waitEofAck |
| waitAck | ZRPOS(p) | error + 1; rewind to p |
| waitEofAck | ZRINIT | ZFIN (hex) → waitFin |
| waitFin | ZFIN | `OO`, `xferDone(true)` |
| any | ZNAK, bad CRC, 10 s silence | error + 1; resend the last frame |
| any | 10th error | cancel, `xferDone(false)` |

Every data subpacket is ZCRCW — the receiver ACKs each 1 KB before
the next goes out — so a download is ACK-clocked like XMODEM-1K and
nothing is in flight while the event loop runs. ponytail: ZCRCG
streaming off a fast timer if a real modem link ever needs the
throughput.

**Download resume** needs nothing special from the sender beyond
obeying `ZRPOS(p)`, which it already does — a receiver resuming an
interrupted download (`lrz -r`, or a terminal's resume option) keeps
its partial and replies `ZRPOS(partial length)` to our ZFILE. A
receiver that verifies first sends `ZCRC(n)`; we answer with the
CRC-32 of our file's first n bytes (`zmFileCrc`, chunked through
`text.crc32`).

**Upload** (`zmodemRecvStart(folder)`):

| State | Event | Action |
|---|---|---|
| waitFile | start, ZRQINIT, 5 s silence | ZRINIT (hex; 1 KB buffer, CANFDX + CANFC32); ten unanswered → cancel |
| waitFile | ZFILE + subpacket | name (last path segment) through `xferAcceptName`; refused → ZSKIP; an existing partial (no DB entry) → ask ZCRC(size) → waitCrc; else create `<folder>:<name>`, ZRPOS(0) → waitData |
| waitCrc | ZCRC(crc) | crc matches our partial → resume: ZRPOS(size) → waitData; mismatch → truncate, ZRPOS(0) → waitData |
| waitFile | ZSINIT + subpacket | ZACK (the attention string is ignored) |
| waitData | ZDATA(p) | p must be the running offset, else ZRPOS(offset) and the frame is junk |
| waitData | good subpacket | `writeAt(offset)`; ZCRCW/ZCRCQ → ZACK(offset) |
| waitData | bad CRC, 10 s silence | error + 1; ZRPOS(offset) |
| waitData | ZEOF(p) | p == offset: flush, close, `xferReceived`, ZRINIT → waitFile; else ZRPOS |
| waitFile | ZFIN | (an open file is dropped, no entry) ZFIN → waitOO |
| waitOO | `OO` or 1 s | `xferDone(true)` — the `OO` must not reach the menus |
| any | ZABORT/ZFERR | ZFIN, `xferDone(false)` |

A ZMODEM batch describes each received file in turn, like YMODEM's —
`lsz file1 file2 file3` (and `lsz --ymodem …`) sends them back to back
and the receiver loops ZFILE→ZEOF→ZRINIT per file.

**Upload resume:** an interrupted upload leaves a partial in the area
folder with no database entry (`xferAcceptName` only refuses names that
have an entry, so a partial passes). When a later ZFILE names it, the
receiver opens the partial and asks the sender for the CRC-32 of its
own first *size* bytes (`ZCRC`); if it matches our partial we reply
`ZRPOS(size)` and the sender streams from there, otherwise the on-disk
file is a different file of the same name — we truncate it and restart
at 0. `lsz -r` and plain `lsz` both answer the ZCRC and honor the
`ZRPOS`. The completed file becomes a normal pending entry. (There is
still no `file.delete`, so an *abandoned* partial lingers until its
name is uploaded again — now that just resumes or overwrites it.)
The 1 KB buffer we advertise is the protocol's way of asking a sender
to wait for ZACK after each 1 KB, and `lsz` **ignores it**: it streams
the whole file as back-to-back ZCRCG subpackets at the line rate. The
receiver copes because the parser does one byte per call and never
waits (the 8 KB serial buffer is the only slack); on the Mac II in
Snow that receive path runs at roughly 0.5 KB/s (a YMODEM upload of
the same file, half-duplex, does ~1 KB/s; a ZMODEM download ~1.5 KB/s
— 800 KB in nine minutes, byte-exact), and a CRC failure from an
overrun costs a ZRPOS and a rewind rather than the transfer.

ZMODEM has no handshake-byte hazard like XMODEM's `C`: a receiver
starts on our ZRQINIT and a sender on our ZRINIT, and both skip junk
until a `*` ZDLE. The one byte to keep out of nearby text is CAN
(0x18), five in a row being a cancel; the announcements are
`Start your ZMODEM receive now.` and `Send your file now.` (no
"two ^X" — ZMODEM's cancel is five).

## Text around a transfer

**Nothing sent to a caller who is about to start their sender may
contain a capital `C`, a `NAK` (0x15) or a `CAN` (0x18).** Those are
the XMODEM handshake bytes: a sender that sees a `C` takes it as the
receiver's CRC go-ahead and starts transmitting mid-sentence, then
reads the rest of the line as ACKs (`lsz` reports
`Got 6f for sector ACK` / `NAK on sector`); a `CAN` makes it abort
outright ("Receiver Cancelled"). This is why the announcements read
`Send your file now. Two ^X abort.` rather than the obvious
"(Ctrl-X twice to cancel)" — that wording broke every upload from a
real sender, while the host-lane rig (which happened to print
different text) passed. `scripts/xmodem-e2e.sh` now sends the same
wording and fails if a capital C reappears in those lines.

The same hazard bites test rigs: a scripted caller that never *reads*
the session leaves the connect-time telnet probe (`FF FD 18` — option
24 is a `CAN` byte) sitting in the socket, and the sender it launches
swallows that first. A real terminal displayed those bytes long ago; a
rig must drain everything up to the announcement before handing the
socket to `lsz`.

## What the caller sees

In the file view (`docs/files.md`): `D) Download File`. Offline files
refuse with `That file is offline.` Otherwise the protocol menu:

```
Download sample.bin (3000 bytes)

X) XMODEM
1) XMODEM-1K
Y) YMODEM
Z) ZMODEM
Q) Cancel

Protocol:
```

The letter prints `Start your <protocol> receive now. Two ^X abort.`
(`Start your ZMODEM receive now.` — most terminals start a ZMODEM
receive by themselves) and the session is in the transfer. Pick what
the caller's terminal offers: ZMODEM when it has it (exact size, CRC-32,
auto-start), YMODEM next (exact size, 1K blocks), XMODEM-1K for XMODEM
receivers that take 1K frames, plain XMODEM for the rest. Afterwards `Transfer complete.`
(download count incremented and saved) or `Transfer failed.` (the log
window has the reason: cancelled, too many errors, no receiver, file
wouldn't open), then the file view is redrawn. Sysop delete from the
view is `X` (it was `D`); the list-side delete is unchanged.

Uploading: `U) Upload File` on the file list → the same protocol menu →
`Filename:` (XMODEM and XMODEM-1K only; YMODEM and ZMODEM carry the
name) → `Send your file now. Two ^X abort.` (ZMODEM: `Send your file
now.`) — the transfer starts at once. Descriptions come **after** it:
for each file that arrived (a YMODEM or ZMODEM batch describes each in
turn), `Describe <name> (<n> bytes)` prompts
for a one-line description and then opens the line editor
(`docs/boards.md`'s editor, `editTarget 'F'`) for the long
description — `/S` saves the entry with it, `/A` saves the entry
without one (the file is already on disk either way). Ordinary
callers' entries are stored with `fileFlagPending` — hidden from
everyone but sysops until one opens the file and presses
`A) Approve File`; a sysop's own uploads are listed immediately. A
failed transfer still describes whatever fully arrived.

Sysops also get `E) Edit Descriptions` in the file view:
`Description [<current>]:` (empty keeps it), then the same editor
**pre-loaded with the existing long description** (`seedEditorBody`
splits it back into the editor's hard/soft rows and lists it) — `/S`
replaces it (`setFileLongDesc`: the old heap bytes are orphaned, like
deleted posts), `/A` keeps it; the short description saves either
way. The view re-reads and re-wraps the description after the save,
and a sysop's login banner counts pending files across all areas
(`pendingFileCount`).

## Testing

- **Unit:** `tests/xmodem-test.cla` (via `scripts/test.sh`) drives the
  engine with a captured `xferOut`/`xferDone`: CRC check value, framing
  and CRC/checksum bytes, ACK/NAK sequencing, byte-identical resends,
  padding, block-number wrap, EOT handling, peer cancel, timeouts, the
  error ceiling, empty and missing files, 1K STX blocks with a 128-byte
  tail, and the YMODEM block 0 / `C` / end-of-batch handshake.
  `tests/zmodem-test.cla` covers the ZMODEM engine: the CRC-32 check
  value, hex/binary header and subpacket round trips through the
  engine's own parser (every byte value, ESCCTL, a corrupted byte),
  the full download and upload handshakes against scripted peers,
  rewinds, ZSKIP, refused names, wrong offsets, bad CRCs, timeouts,
  the error ceiling, peer cancel, and the `OO` swallow.
- **Host lane, real sender and receiver:** `scripts/xmodem-e2e.sh` builds a small
  CLI harness — `scanner.cla` + `termio.cla` (telnet) + `xmodem.cla`,
  the same byte path as `bbs.cla` minus the menus — listening on TCP,
  and receives with `lrz -X` (checksum), `lrz -X -c` (CRC), `lrz -X -c`
  against 1K mode, `lrz --ymodem` and `lrz --zmodem` (exact 3000-byte
  files) through `socat`, then runs the uploads the other way with
  `lsz -X`, `lsz -X -k`, `lsz --ymodem` and `lsz --zmodem` into the
  harness's receiver. `bbs.cla` itself cannot run on the host: window/menu/`every`
  declarations make it a UI program and the host runtime has no UI
  lane. Needs `socat` and `lrzsz` (Homebrew).
- **Snow:** reset the image to the baseline (CLAUDE.md), `hcopy -r` a
  host-built `Users.*`/`Areas.*`/`ARE01.*` seed plus the sample file
  next to the app, `scripts/deploy.sh`, double-click 68kBBS, then
  with the modem emulator on :2323:

  ```sh
  cat > drive.sh <<'EOF'
  #!/bin/sh
  sleep 3                       # CONNECT + telnet probe
  printf 'sysop\r'; sleep 1; printf 'pw\r'; sleep 1
  printf '\r'; sleep 2          # terminal type: default
  printf 'F'; sleep 1; printf '1\r'; sleep 1; printf '1\r'; sleep 1
  printf 'D'; sleep 1; printf 'X'; sleep 1
  exec lrz -X -b -c out.bin          # or: printf 'Y' ... exec lrz --ymodem -b
                                     # or: printf 'Z' ... exec lrz --zmodem -b
  EOF
  chmod +x drive.sh && socat TCP:localhost:2323 EXEC:./drive.sh
  head -c 3000 out.bin | cmp - sample.bin
  ```

  Quit Snow cleanly afterwards and read `out` for the
  `XMODEM send: sample.bin` line.

## The seam for later

Each of these reuses the four hooks and two callbacks unchanged.

- **YMODEM batch:** several files per session is the block-0 loop
  again with a file list; nothing in the engine assumes one, except
  that `xferDone` fires after the end block.
- **ZMODEM streaming:** the sender could send ZCRCG subpackets back
  to back off a fast `every N ticks` timer (one 1 KB subpacket per
  firing keeps the line busy while the receive pump drains between
  passes) instead of waiting for a ZACK per subpacket; the ZRPOS
  rewind already works. Only worth it on a link with real latency.
- **Multi-file downloads** (tag-and-download): the engines can already
  loop a queue, but the caller has no way to tag several files on the
  list. The UI and engine sketch is in the repo-root `TODO.md`.
- **Kermit** (`kermit.cla`): packet engine shaped like XMODEM's;
  `text.crc16` (CRC-16/KERMIT) fits as-is; adds control-character
  prefixing and the S/F/D/Z/B negotiation.
- **MacBinary:** encode on download / decode on upload once
  resource-fork access and `setInfo` exist (`docs/language-gaps.md`
  §4–5); the file entry's reserved flag bits mark wrapped files.
