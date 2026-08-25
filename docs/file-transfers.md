# File Transfers

How 68kBBS moves files over the modem: the transfer plumbing in
`bbs.cla`, the sender and receiver in `xmodem.cla`, what the caller
sees, how to test it, and where ZMODEM and Kermit plug in. The storage
side (areas, file entries, `filePath`) is `docs/files.md`.

**Status:** XMODEM, XMODEM-1K and YMODEM in both directions — download
(BBS → caller) and upload (caller → BBS, entered pending sysop
approval). Data fork only. No ZMODEM/Kermit, no MacBinary yet.

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
  `telnetSend(modem, …)` in 255-byte slices (frames are up to 1029
  bytes; strings cap at 255): IAC doubling for telnet callers, no
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
are a `switch` on `xferProto: char` — `'X'`, `'1'` and `'Y'` all go to
`xmodem.cla` today. A new protocol is a new module plus one case in
each.

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

`crcXmodem` is CRC-16/XMODEM (poly `0x1021`, init 0, no reflection,
no final XOR; `"123456789"` → `0x31C3`), a bitwise loop. The runtime's
`text.crc16` is CRC-16/KERMIT, a different algorithm. A table-driven
`text.crc16x` is filed in `docs/language-gaps.md` §8; when it lands,
`crcXmodem` becomes one call.

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
Q) Cancel

Protocol:
```

The letter prints `Start your <protocol> receive now (Ctrl-X twice to
cancel)...` and the session is in the transfer. Pick what the caller's
terminal offers: YMODEM when it has it (exact size, 1K blocks),
XMODEM-1K for XMODEM receivers that take 1K frames, plain XMODEM for
the rest. Afterwards `Transfer complete.`
(download count incremented and saved) or `Transfer failed.` (the log
window has the reason: cancelled, too many errors, no receiver, file
wouldn't open), then the file view is redrawn. Sysop delete from the
view is `X` (it was `D`); the list-side delete is unchanged.

Uploading: `U) Upload File` on the file list → the same protocol menu →
`Filename:` (XMODEM and XMODEM-1K only; YMODEM carries the name) →
`Send your file now. Two ^X abort.` — the transfer starts at once.
Descriptions come **after** it: for each file that arrived (a YMODEM
batch describes each in turn), `Describe <name> (<n> bytes)` prompts
for a one-line description and then opens the line editor
(`docs/boards.md`'s editor, `editTarget 'F'`) for the long
description — `/S` saves the entry with it, `/A` saves the entry
without one (the file is already on disk either way). Ordinary
callers' entries are stored with `fileFlagPending` — hidden from
everyone but sysops until one opens the file and presses
`A) Approve File`; a sysop's own uploads are listed immediately. A
failed transfer still describes whatever fully arrived.

Sysops also get `E) Edit Descriptions` in the file view:
`Description [<current>]:` (empty keeps it), then the same editor for
the long description — `/S` replaces it (`setFileLongDesc`: the old
heap bytes are orphaned, like deleted posts), `/A` keeps it; the
short description saves either way.

## Testing

- **Unit:** `tests/xmodem-test.cla` (via `scripts/test.sh`) drives the
  engine with a captured `xferOut`/`xferDone`: CRC check value, framing
  and CRC/checksum bytes, ACK/NAK sequencing, byte-identical resends,
  padding, block-number wrap, EOT handling, peer cancel, timeouts, the
  error ceiling, empty and missing files, 1K STX blocks with a 128-byte
  tail, and the YMODEM block 0 / `C` / end-of-batch handshake.
- **Host lane, real sender and receiver:** `scripts/xmodem-e2e.sh` builds a small
  CLI harness — `scanner.cla` + `termio.cla` (telnet) + `xmodem.cla`,
  the same byte path as `bbs.cla` minus the menus — listening on TCP,
  and receives with `lrz -X` (checksum), `lrz -X -c` (CRC), `lrz -X -c`
  against 1K mode, and `lrz --ymodem` (exact 3000-byte file) through
  `socat`, then runs the three uploads the other way with `lsz -X`,
  `lsz -X -k` and `lsz --ymodem` into the harness's receiver. `bbs.cla` itself cannot run on the host: window/menu/`every`
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
- **ZMODEM** (`zmodem.cla`): the sender streams `ZDATA` subpackets but
  must return to the event loop after each — `PBWriteSync` blocks
  ~0.2 s per KB at 57600, and the receive pump only drains between
  passes. One subpacket per pass keeps `ZRPOS`/`ZACK` flowing. Needs
  CRC-32: `text.crc32`, filed with `crc16x` in
  `docs/language-gaps.md` §8; not worth a Clarus bit loop at
  streaming rates.
- **Kermit** (`kermit.cla`): packet engine shaped like XMODEM's;
  `text.crc16` (CRC-16/KERMIT) fits as-is; adds control-character
  prefixing and the S/F/D/Z/B negotiation.
- **Upload** (any protocol): a receiving engine writes with `writeAt`
  to `filePath`, then `addFile(..., fileFlagPending, ...)` for sysop
  review. Wire filenames sanitized to Mac rules (≤ 31 chars, no `:`);
  XMODEM carries no name, so its upload prompts for one first. An
  aborted upload leaves a partial file until `file.delete` exists
  (`docs/language-gaps.md` §3).
- **MacBinary:** encode on download / decode on upload once
  resource-fork access and `setInfo` exist (`docs/language-gaps.md`
  §4–5); the file entry's reserved flag bits mark wrapped files.
