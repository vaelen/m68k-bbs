# File Transfers

How 68kBBS moves files over the modem: the transfer plumbing in
`bbs.cla`, the XMODEM sender in `xmodem.cla`, what the caller sees,
how to test it, and where ZMODEM, Kermit and uploads plug in. The
storage side (areas, file entries, `filePath`) is `docs/files.md`.

**Status:** XMODEM, XMODEM-1K and YMODEM download (BBS → caller), data
fork only. No uploads, no ZMODEM/Kermit, no MacBinary yet.

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
  re-enters the engine.

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

## Testing

- **Unit:** `tests/xmodem-test.cla` (via `scripts/test.sh`) drives the
  engine with a captured `xferOut`/`xferDone`: CRC check value, framing
  and CRC/checksum bytes, ACK/NAK sequencing, byte-identical resends,
  padding, block-number wrap, EOT handling, peer cancel, timeouts, the
  error ceiling, empty and missing files, 1K STX blocks with a 128-byte
  tail, and the YMODEM block 0 / `C` / end-of-batch handshake.
- **Host lane, real receiver:** `scripts/xmodem-e2e.sh` builds a small
  CLI harness — `scanner.cla` + `termio.cla` (telnet) + `xmodem.cla`,
  the same byte path as `bbs.cla` minus the menus — listening on TCP,
  and receives with `lrz -X` (checksum), `lrz -X -c` (CRC), `lrz -X -c`
  against 1K mode, and `lrz --ymodem` (exact 3000-byte file) through
  `socat`. `bbs.cla` itself cannot run on the host: window/menu/`every`
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
