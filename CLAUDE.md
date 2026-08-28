# 68kBBS

A simple BBS for 68k Macintosh (System 6/7), written in Clarus, serving
callers over the Mac's modem serial port.

## Language: Clarus

Clarus is a small, compiled, event-driven language for native System 6/7
Mac apps. The normative spec is `docs/clarus-language-reference.md`
(symlink into the compiler repo, `clarus-src/` → `~/repos/clarus`).

Key points:

- No `main`; execution starts at `on App.launch`, then `App.startEmpty`
  (bare launch) or `App.openDocument`. All code lives in event handlers,
  `func`s, and `every N ticks` timer blocks.
- Source files are `.cla`, **MacRoman-encoded** — keep program text ASCII;
  use `\xHH` escapes for high bytes (e.g. `\xC9` for `…`). `\n` emits CR
  (the Mac newline).
- Statements end at newline. No `+=`/`++`. `var` declarations only at the
  top of a body. Strings are Pascal strings (≤255 bytes), `text` is an
  unbounded buffer. No float — `fixed` (16.16). No int-to-string builtin;
  write an `intStr` helper (see `~/repos/clarus/examples/serialecho.cla`).
- UI is declarative: `window`/`menu` blocks with widgets (`textview`,
  `button`, `field`, `table`…); handlers go in `extend WindowName { }` /
  `extend MenuName { }` blocks. `menu Edit { standard edit }` gives the
  standard Edit menu.
- Serial: `conn.open(serial "modem:9600")`; events `on conn.opened`,
  `on conn.received(data: text)`, `on conn.failed(err: error)`. Binary
  safe, 8N1 fixed. A serial connection never fires `closed`.
- `log(msg)` writes diagnostics; subscribe with `on App.log(line: string)`
  to mirror them into the UI (our log window does this).
- Mac textview `text` property caps at 32,000 bytes (TextEdit limit);
  oversized stores truncate silently and set `lastError`.
- `now()` is Mac-epoch seconds, already past 2^31 in 2026, so
  timestamps are **negative** as Clarus `int`s. Storing, comparing
  for equality, and `dateTimeStr` all work; never use `< 0` / `-1`
  as an "unset" sentinel on a timestamp — use a separate flag or 0.

## Compiler

The compiler is `clarusc` (self-hosted, in `clarus-src/clarusc/`). This
project uses a **fully pinned toolchain**, so work here continues even
while the compiler repo is mid-change:

- `bin/clarusc` — pinned copy of a known-good compiler build
- `vendor/runtime/`, `vendor/toolbox/` — matching snapshot of the
  runtime `.cla` sources, host C runtime, and toolbox catalog

Refresh the pin deliberately (all pieces together — a pinned binary with
a newer runtime can mismatch):
`cp clarus-src/build-run/clarusc bin/clarusc && cp clarus-src/runtime/clarus/*.cla vendor/runtime/clarus/ && cp clarus-src/runtime/host/rt* vendor/runtime/host/ && cp clarus-src/toolbox/*.cla vendor/toolbox/`

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla   # check only
scripts/build.sh      # 68k Mac app -> build/68kBBS.bin (MacBinary)
scripts/test.sh       # run every tests/*.cla on the host lane
scripts/deploy.sh     # build + refresh snow/BBSHD.hda + restart Snow
```

Always pass `--rtdir vendor/runtime/clarus/` (the scripts do): the
pinned binary can't find the runtime on its own from this repo, and
`include "toolbox/..."` resolves against the rtdir's `../../toolbox/`
sibling — i.e. `vendor/toolbox/`. The live-repo wrapper scripts
(`clarus-src/scripts/build-68k.sh`, `clarus-run.sh`) still work but
bootstrap the live compiler — only reach for them when testing new
compiler features. (The old `./clarus` symlink to the frozen Go host
compiler was removed — it predates `app` sections and `App.log`; don't
resurrect it.)

For host-side serial testing, the host lane maps the modem port via env:
`CLARUS_SERIAL_MODEM=listen:PORT` (or `connect:HOST:PORT`).

## Emulator: Snow (Mac II)

`snow/` holds a Snow emulator setup: `snow/run-snow.sh` boots a Mac II
(System 7) from `snow/hdd0.img` (SCSI 0) with the emulated **modem port
bridged to TCP port 1234** (`--serial-bridge-a tcp:1234`). Connect a test
client with `nc localhost 1234` while the emulator runs.

The workspace is `snow/MacII.snoww` (plain JSON; SCSI ID 1 is free for a
build disk).

## Shell notes (zsh)

The workstation shell is zsh, which unlike bash aborts on two things
that look innocent: an unmatched glob is an error, not a literal
(`rm -f Users.*` fails with "no matches found" when nothing matches —
guard with `rm -f Users.* 2>/dev/null || true` or check first), and a
word starting with `=` triggers `=command` expansion (`echo =====`
fails with "===== not found" — quote it).

## Modem emulator

`simple-modem-emulator/` is a tiny C TCP bridge that makes a telnet
client look like a Hayes modem to the emulated serial port
(`telnet → :2323 → modem → :1234 → Snow`). Andrew usually has it running
on port 2323. On caller connect it sends `\r\nCONNECT 57600\r\n` to the
serial side; on caller disconnect, `\r\nNO CARRIER\r\n` — exactly what
`scanner.cla` watches for. It also honors `+++`/`ATH` (hang up) and `ATO`
from the Mac side, replying `OK`/`CONNECT` in Hayes verbose framing. One
call at a time. So: test the BBS with `telnet localhost 2323` rather than
raw `nc` to port 1234. See `simple-modem-emulator/README.md`.

## Getting a build into the emulator

`snow/BBSHD.hda` is a persistent 5 MB device image ("BBS HD"), attached at
SCSI ID 1 in `MacII.snoww`. It is **reused every time** — don't recreate
it. `scripts/deploy.sh` does the whole cycle (build, quit Snow, refresh
the app on the image with hfsutils, restart Snow); the manual steps, if
needed, are in its source and `docs/snow-hdd-howto.md`.

Rules: only touch the image while Snow is NOT running; quit Snow cleanly
(`osascript -e 'quit app "Snow"'`), never `kill`, or the HFS structures
can be left half-written. Files the emulated Mac writes to "BBS HD"
persist in the image and can be pulled out with `hcopy` after Snow exits.
Full background: `docs/snow-hdd-howto.md`.

Before an e2e test run against the emulator, delete all database files
from the image (while Snow is stopped) so every run starts from the
same baseline: `hdel` the vDB files — `Users.*`, `Boards.*`, `BRD*`,
`Mail.*`, `Areas.*`, `ARE*`, `Networks.*`, `Wall.*` — plus
`Logins.txt`, `MOTD.txt` and the `FTN` folder (empty `FTN:In`, `FTN:Out`, `FTN:Tmp`, then `hrmdir`),
then reseed. The vDB format is identical on both lanes (big-endian),
so seed data can be built with a host-lane CLI program and `hcopy -r`'d
onto the image (file type/creator don't matter; the app opens by name).

## Reading the Mac-side log

`log(...)` lines land in the app's log window (timestamped) and in the
runtime's exit log, which the Mac writes to a file named `out` on
"BBS HD" when the app quits. To read it after quitting Snow cleanly:
`HOME=scratch hmount snow/BBSHD.hda && hcopy -t :out ./out.txt && humount`.
The file also contains the runtime's UI trace (`T OPEN ...`) and exit
code — useful for verifying a session after the fact.

## Architecture

The received-byte path is:
`modem.received → feedChar (scanner.cla) → dataChar (telnet.cla) →
inputChar (bbs.cla) → processInput`.

- `scanner.cla` — a state machine that watches the raw stream for the
  Hayes result codes `\r\nCONNECT <digits>\r\n` / `\r\nNO CARRIER\r\n`
  (state persists across chunks). It is also a *filter*: bytes it
  releases as ordinary data go to `dataChar`; candidate result-code
  bytes are held and either discarded (match → calls `connected()` /
  `disconnected()`) or replayed (mismatch). CR/LF always pass through
  immediately, so the one hang-up artifact is a single empty line just
  before disconnect. The including program defines `connected`,
  `disconnected`, and `dataChar`.
- `telnet.cla` — telnet option processor between the scanner and the
  app: consumes/answers IAC sequences (WILL TERMINAL-TYPE/SPEED → SB
  SEND; the probe also offers WILL ECHO and WILL/DO SGA, so telnet
  clients go character-at-a-time with local echo off — the client's
  DO ECHO/SGA are agreed silently, DONT ECHO clears terminal.echo;
  BINARY (RFC 856) agreed both ways — `tnBinaryIn`/`tnBinaryOut`,
  and `telnetBinaryRequest()` asks for what's still off at transfer
  start, since NVT mode mangles CR in binary data;
  unknown WILL → DONT, other DO/DONT → WONT), releases clean bytes to
  `inputChar`, drops NVT CR NUL's NUL unless the client sends BINARY, applies NAWS to
  `terminal.columns/rows` via `setColumns`/`setRows` (clamped 20-132 /
  10-60 physical) and records
  TERMINAL-TYPE/SPEED replies. Interception is on only while
  `telnetIntercept` is set (the connect-time probe, then only if the
  client negotiated). `telnetSend(conn, s)` is the outgoing chokepoint:
  doubles IAC bytes when `terminal.telnet`. The including program
  defines `inputChar(c)` and `telnetOut(s)` (raw wire bytes, never
  escaped).
- `btree.cla` — reusable file-based B-tree (multi-level, lazy
  deletion) over a `filehandle`; `vdb.cla` — journaled page database
  with secondary indexes on top of it (formats: `docs/vdb-clarus.md`;
  design: `docs/vdb.md`). `usersdb.cla` — the "Users" vDB database
  (160-byte records: username/hash/email/access flags (i32)/created/
  lastSeen; vDB record ID = user ID; username indexed
  case-insensitively).
  `boardsdb.cla` — the "Boards" database (256-byte records:
  name/description/echo tag/networkId — 0 = local — /lastExported —
  the scan high-water mark — /flags, record ID = board ID;
  `boardNetworked()`). `postsdb.cla` — one board's posts at a time
  (`postsOpen(boardId)`): header records in `BRD<nn>.*` (sender/
  created/threadId/subject, thread ID indexed; 0 = thread starter,
  else the starter's post ID; plus the FTN fields msgidCrc — indexed,
  `findPostByMsgId` — origin address and flags bit 0 = inbound;
  `addPostFtn` takes them, `addPost` zeroes them) plus exact-fit
  bodies in an append-only `BRD<nn>.MSG` heap, written and flushed
  before the journaled header add so a crash only orphans heap bytes.
  `maildb.cla` — the "Mail" database (256-byte header records: from/to
  names, from/to user IDs with the recipient indexed, created, flags
  bit 0 = read, bit 1 = sent; from/to FTN addresses and msgidCrc at
  214+ — `toUserId` 0 with a `toAddr` is outbound netmail, `fromUserId`
  0 with a `fromAddr` inbound; `sendMailFtn`, `markSent`,
  `outboundMailIds`) plus an append-only `Mail.MSG` body heap, same
  write ordering as posts (`docs/mail.md`). `networksdb.cla` — the
  "Networks" database (256-byte records: name/domain/our address/uplink
  address/session, packet and AreaFix passwords/AreaFix robot/dial
  string/UTC offset/poll interval/flags bit 0 = enabled/lastPoll/
  lastResult; `findNetworkByZone`, `findNetworkByName`;
  `docs/fidonet.md`). `areasdb.cla` — the "Areas" database (256-byte
  records: name/description/folder path/access byte, record ID =
  area ID). `filesdb.cla` — one area's file entries at a time
  (`filesOpen(areaId)`): header records in `ARE<nn>.*` (filename
  indexed case-insensitively, uploader name, description, created,
  size, downloads, flags: pending/offline) plus long descriptions in
  an append-only `ARE<nn>.MSG` heap, same write ordering as posts;
  the file itself lives at `<area folder>:<name>` (`filePath`) —
  storage only so far, no UI or transfers (`docs/files.md`).
- `user.cla` — `User` record (name, authenticated, passwordHash,
  screen, buffer, id, email, access, created, lastSeen)
  + global `user`; `hashPassword` (djb2,
  non-cryptographic). `access` is a bit set: `enum Access` (Login,
  SendMail, PostBoards, UploadFiles, ApproveUploads, PostWall, Games,
  Sysop, BasicRepl — member value = bit number), `getBit`/`setBit`/
  `clearBit`, `hasPermission(f)`/`setPermission(f, grant)`/
  `accessHas(v, f)`, `accessLabel`, `accessDefault` (the caller bits)
  and `accessAllFlags`. Every gate checks its own bit — Sysop implies
  nothing else (`docs/access.md`). `accessAll`/`accessSysop` chars are
  the file-area byte only. `config.cla` — `Config.txt` (`key=value`
  per CR line, `#` comments, unknown keys ignored, missing file/key =
  the compiled default, missing file written out at launch):
  `config: Config` record (`newUserAccess`, default `accessDefault`),
  `configLoad`/`configSave`; Sysop menu `C` edits it (`docs/config.md`).
  `terminal.cla` — `Terminal` record (columns —
  stored as the physical width **minus one** via `setColumns`, so
  the last column is never written: SyncTERM/ANSI.SYS auto-wrap
  there while Unix terminals need the newline; layouts compare
  against `minimumWideTerminalWidth` (79) and tables total 79/39 —
  rows via `setRows`, color, echo — on by default, linemode — off by default, set per screen by
  `displayPrompt` via `lineScreen`, type: ASCII/ANSI/VT100, ansi — set for the ANSI and
  VT100 types, telnet, reportedTerminalType, reportedSpeed) + global
  `terminal`, `Color`
  enum, and pure ANSI sequence builders (`colorSeq`, `backgroundSeq`,
  clear consts), plus the box-drawing/table builders (`boxChar`,
  `ruleLine`, `rowLine`, `pad`, `center` — see `docs/tables.md`).
  `termio.cla` — connection-facing send wrappers over those (take a
  `connection` parameter, gated on `terminal.color`).
- `bbs.cla` — app/UI declarations, session flow. `inputChar` assembles
  input (`terminal.linemode` on — text prompts, editor lines and the
  number prompts: buffer until CR, BS/DEL rubs out; off — menus, Y/N,
  pagers, list screens: each key acts at once, Enter arrives as "",
  echoed hotkey style; the newline after the echo is deferred —
  `hotkeyPending`/`freshLine` — until the screen's first output, so
  handlers get the bare key and a no-echo screen gets no newline). Numbered lists (boards, areas,
  posts, files, mail — `numberScreen`) have a `V` key that opens a
  line-mode number prompt (`boardnum`/`areanum`/`postnum`/`filenum`/
  `mailnum`, via `promptNumber`); a digit pressed on the list opens
  the same prompt pre-filled with that digit, empty Enter returns to
  the list and echoes it back when `terminal.echo` (classic remote
  echo; CR echoes as `terminal.eol`, echo fully off on the probe and
  logoff screens, characters hidden — newline still echoed — on the
  password screens and the sysop password reset). Echo hard-wraps at
  `terminal.columns` and a rubout that would cross a display row
  redraws the prompt (`displayPrompt`) plus the remaining buffer on a
  fresh row — BS can't step back across a soft wrap, and the
  terminal's last-column "pending wrap" state is unreliable to undo.
  `sendData` feeds `trackOutput` so `termCol` (terminal.cla) knows
  the cursor column.
  Caller-facing output goes through `sendData` (→ `telnetSend`); only
  modem commands (+++/ATH) and `telnetOut` use `modem.send` raw. On
  connect, `connected()` sends the telnet probe (DO TERMINAL-TYPE /
  NAWS / TERMINAL-SPEED) and "Checking for telnet support...", parks
  the session on the input-swallowing "probe" screen for 2 firings of
  the 30-tick timer (`telnetProbe`), then `telnetProbeDone` clears the
  input buffer and shows the login prompt.
  `processInput` dispatches on `user.screen`: login → password →
  terminal-type menu → main menu; typing NEW at the login prompt
  enters the signup flow (newname → newpass → newpass2 → newemail,
  empty name cancels; first account gets `accessAllFlags`, later ones
  `config.newUserAccess`). Logins are checked against the Users database
  (case-insensitive; wrong password returns to login; a correct
  password on an account without the Login flag says "This account is
  disabled." and hangs up). Last-seen is updated at login. Once the
  terminal type is known, `applyTerminal` runs the once-per-login
  chain when `postLogin` is set (`loginOk`/`newEmail`): "Welcome back
  / Last on" (or "Welcome" for a new account) → `pause` → the
  wall table → "Sign the wall?" → the MOTD and another
  `pause` (both skipped when `motdText` is empty) → "You have N new
  message(s)" (plus, for sysops, "N file(s) are awaiting approval."
  via `pendingFileCount`) → main menu (`returning`/`previousSeen`
  carry the banner across). `showPause(next)` parks on the
  input-swallowing `"pause"` screen and `pauseChoice` runs
  `pauseNext`. Main-menu `W` runs the wall (`wallFromMenu`, back to
  main after), `D` shows the MOTD then a pause, `G` opens the (still
  empty) `games` menu (`docs/games.md`).
  Main-menu `T` returns to the terminal-type menu; `applyTerminal`
  re-sends the VT100 init and comes back to the main menu (no chain). Main-menu
  `L` draws the last 20 sessions from the login log
  (`drawRecentLogins`); `sessionName`/`sessionStart`/`sessionNew`
  are set at login/signup and `disconnected()` appends the record.
  Menu conventions: `gotoScreen(s)`
  sets the screen and draws menu + prompt; `displayMenu`/`displayPrompt`
  switch on `user.screen`; choices are case-insensitive (`upperStr`);
  `?` redraws the menu; invalid main-menu input redraws only the
  prompt; the terminal menu redraws fully and defaults to VT100 on
  empty input. Logoff paces `+++` / `ATH` through a `every 30 ticks`
  timer (`hangupPhase`) to honor the Hayes guard time; the resulting
  NO CARRIER resets the session. Sessions reset in `connected()`
  (`new User` / `new Terminal`). bbs.cla also owns the shared
  connection-facing table senders (`sendRule`, `sendTableTitle`,
  `sendTableHeader`, `sendTableFooter` — see `docs/tables.md`), the
  helpers (`intStr`, `upperStr`, `trimStr`, `sendLine` — which sends
  payload and eol separately so a full 255-byte line keeps its line
  ending), and a BEL when a caller types past the 255-byte input
  buffer. File transfers are the `"xfer"` screen: `inputChar` hands
  every raw byte to `xferChar` before any assembly, the 30-tick timer
  calls `xferTick`, `disconnected()` calls `xferAbort`, and engines
  send through `xferOut(text)` (→ `telnetSend` in 255-byte slices, no
  cursor tracking); `xferStart(proto, path, name)`/`xferChar`/
  `xferTick`/`xferAbort` switch on `xferProto` (`'X'`/`'1'`/`'Y'`
  `xmodem.cla`, `'Z'` `zmodem.cla`). `docs/file-transfers.md`.
- `sysop.cla` — the sysop menu tree (gated on the Sysop flag): paged
  user/board lists (`listFromId` cursor, `[Enter] More` prompt),
  detail cards, lettered-field edit cards (buffered; `S` saves, `Q`
  discards; the user card's `A` opens the `useraccess` flag table —
  `N | Access Level | Granted`, a flag number toggles the buffered bit,
  Enter returns to `accessReturn` — the card, or the Configuration
  menu where it saves `newUserAccess` at once; a sysop cannot change their own access
  or delete their own account), Y/N delete confirmations over the detail card,
  the New Board wizard, folder-syntax help (`sendFolderHelp`) before
  both area folder prompts, and the same L/S/E/N/D tree over file areas
  (`Areas` database: name/description/folder/access; Sysop menu `F`).
  `parseIntStr` (all-digits or 0) lets ID-or-name prompts
  disambiguate naturally.
- `boards.cla` — the caller-facing reader: main-menu `B` → board
  picker (unpaged table; `V`/digit → `Board ID:` prompt) → paged post
  list (newest first, numbered from 1 per page, post IDs hidden,
  `Page X of Y` footer; `V`/digit → `Post number:` prompt) → framed
  post view (subject title bar, From/Date meta, body wrapped by
  `wrapText` and paged). Keys: `+`/Enter next page, `-` previous,
  `L` redraw, `>`/`.` and `<`/`,` next/previous post, `R` reply,
  `N` new post, sysop-only `D` delete (confirms over the drawn
  post), `Q` up one level.
- `files.cla` — the caller-facing file-area reader: main-menu `F` →
  area picker (unpaged, sysop-only areas hidden) → paged file list
  (newest first, `pending` files hidden from non-sysops, `# | Name`
  narrow / `+ Size + Description` wide) → framed file view
  (Name title bar, From/Date/Size/Downloads meta, long description
  wrapped by `wrapText` and paged). Keys mirror the board reader:
  `+`/Enter next page, `-` previous, `L` redraw, `>`/`.` and `<`/`,`
  next/previous file, `D` download (offline files refused → protocol
  menu `xferproto`: `X` XMODEM, `1` XMODEM-1K, `Y` YMODEM, `Z`
  ZMODEM → `startDownload` → `xferStart`; `xferDone` bumps the download count
  and redraws the view), sysop-only `X` delete and `A` approve on a
  pending entry, `E` edit descriptions (short prompt, then the line
  editor pre-loaded via `seedEditorBody` with `editTarget 'F'`; `/S` replaces the long description
  via `setFileLongDesc`, `/A` keeps it), `Q` up one level. The list's
  `U` uploads (`upproto` → `upname` for XMODEM/1K, YMODEM and ZMODEM
  carry the name → `xferStartReceive`);
  `xferReceived` queues each received file and the describe loop then
  prompts short description + long-description editor per file before
  `addFile` (`fileFlagPending` unless the uploader is a sysop).
- `mail.cla` — private mail UI: main-menu `M` → paged inbox (`*`
  marks unread, newest first) → framed message view (viewing marks
  read; `R` reply, `D` delete with Y/N confirm, `>`/`<` between
  messages) → compose via `editor.cla` with `editTarget = 'M'`:
  `To:` must resolve to a local user (`findUserId`), empty `To:`
  cancels.
- `xmodem.cla` — XMODEM / XMODEM-1K / YMODEM sender **and receiver**:
  a pure state machine (`xmodemSendStart(path, name, mode)` /
  `xmodemRecvStart(mode, folder, name)`, `xmodemChar`,
  `xmodemTick`, `xmodemAbort`) over a `filehandle`; mode `'X'`
  128-byte blocks, `'1'` 1K `STX` blocks with a 128-byte tail, `'Y'`
  1K plus block 0 (name NUL size NUL) and the empty end-of-batch
  block; CRC-16 (`text.crc16x` — `text.crc16` is the Kermit CRC,
  not XMODEM's) or checksum on a NAK start (not YMODEM), ½-second
  ticks for the 60 s start / 10 s ACK timeouts, ten-error ceiling,
  CAN CAN handling; the receive side prods with C/NAK, assembles
  frames byte by byte, NAKs only after the line goes quiet, and
  reports each file through `xferReceived(name, bytes)` with wire
  names vetted by `xferAcceptName`. **Nothing sent to a caller who is
  about to start their sender may contain a capital C, NAK or CAN
  byte** — they are the XMODEM handshake bytes (docs/file-transfers.md,
  "Text around a transfer"; the e2e script enforces it).
  `tests/xmodem-test.cla` unit-tests it; `scripts/xmodem-e2e.sh`
  receives with `lrz` over `socat`, raw and again through
  `scripts/telnet-shim.py` (a SyncTERM-faithful telnet layer)
  (`docs/file-transfers.md`).
- `zmodem.cla` — ZMODEM sender **and** receiver
  (`zmodemSendStart(path, name)` / `zmodemRecvStart(folder)`,
  `zmodemChar`, `zmodemTick`, `zmodemAbort`): one parser for hex,
  CRC-16 and CRC-32 binary headers and ZDLE-escaped subpackets
  (`text.crc16x` / `text.crc32`), builders that write into `zmWire`
  and resend `zmLast`; sender: `rz` + ZRQINIT → ZFILE (name NUL
  size NUL) → per 1 KB ZDATA + ZCRCW subpacket, ACK-clocked, ZRPOS
  rewinds, ZEOF → ZFIN → `OO`; receiver: ZRINIT (1 KB buffer,
  CANFC32 — `lsz` ignores the buffer and streams ZCRCG, which the
  one-byte-per-call parser handles), ZFILE names vetted by
  `xferAcceptName` (refused → ZSKIP), data written at the running
  offset, ZEOF → `xferReceived` → ZRINIT for the next file, ZFIN
  answered and the sender's `OO` swallowed before `xferDone`; five
  CANs = peer cancel, 8 CAN + 8 BS = ours; 10 s waits, ten-error
  ceiling. Resume via a `ZCRC`/`text.crc32` prefix check: the sender
  answers `ZCRC` (download resume rides the existing `ZRPOS`), and on
  upload a partial with no DB entry is ZCRC-verified and resumed from
  its end or truncated+restarted on a mismatch (`zmFileCrc`,
  `zrWaitCrc`). Multi-file uploads loop the receiver over each `ZFILE`.
  `tests/zmodem-test.cla`; the e2e script's `Z`/`RZ`, multi-upload and
  resume legs. Deferred: tag-and-download multi-file (`TODO.md`).
- FidoNet (`docs/fidonet.md` — the design, record layouts and
  protocol rules; read it before touching any of these). `ftnaddr.cla`
  — `FtnAddress` (zone/net/node/point), `parseAddress`/`addressStr`/
  `address3D`/`netNodeStr`, the 8-byte big-endian record form.
  `ftnpkt.cla` — pure text conventions and packets: `^A` kludges
  (`findKludge`, `kludgeValue`, `stripKludges` — readers hide `^A`
  lines), MSGID serials (`newMsgId`, `msgIdCrc`), FTS-0001 dates and
  TZUTC (`ftnDateStr`/`ftnDateParse`/`tzMinutes`/`tzStr`), and a
  type-2+ packet reader/writer over a `filehandle` (`pktOpenRead`/
  `pktNextMsg` into the globals `pktMsg`/`pktBody`, `pktCreate`/
  `pktAddMsg`/`pktClose`; `ftnNormalize` keeps kludges, drops
  `AREA:`/`SEEN-BY:`/`^APATH:`, ASCII-fies). `ftntoss.cla` — toss
  (`tossInbound`: every packet in `:FTN:In`, echomail to the board
  with that tag on that network with MSGID dupe check and REPLY
  threading, netmail to the named user or the sysop, then deleted) and
  scan (`scanNetwork(netId)` rebuilds `:FTN:Out:<id>.pkt` from posts
  past `lastExported` and unsent netmail; `scanCommit` moves the marks
  only after an acknowledged send). `emsi.cla` — the poll: `ftnPollRequest`/
  `ftnPollAll`/`ftnSchedule` queue polls (`ftnQueue`), `ftnPollStart`
  scans and dials, then the EMSI caller handshake (FSC-0056), a ZMODEM
  send of the packet (or `zmodemSendEmpty`), a ZMODEM receive into
  `:FTN:Tmp` (complete files moved to `:FTN:In`), hang-up via
  `hangupPhase`, and on NO CARRIER `emsiDisconnected` tosses, commits
  and records `lastPoll`/`lastResult`. Hooks the program provides:
  `ftnModemSend`, `ftnSysopName`, `xferOut`, and `files.cla`'s
  `xferDone`/`xferReceived`/`xferAcceptName` branch to the `emsi*`
  versions while `ftnPolling`. In `bbs.cla` the poll is screen
  `"ftn"` (`inputChar` → `emsiChar`), the 30-tick timer calls
  `emsiTick` and `ftnSchedule` once a minute, `connected()`/
  `disconnected()` branch on `ftnPolling`, and the `FidoNet > Poll
  All Networks` menu polls from the Mac; the remote sysop's `P` on the
  network card queues one for after logoff. Local posts on a
  networked board and outbound netmail get their MSGID/REPLY kludges
  at creation (`editKludges` in `editor.cla`). `scripts/ftn-e2e.sh`
  runs a whole poll on the host against `scripts/emsi-peer.py` (a
  Python EMSI answerer driving `lrz`/`lsz`) — the bridge's stand-in.
- `banned.cla` — banned usernames, `Banned.txt` (TEXT/ttxt, one name
  per CR line; hand-editable, LF tolerated): loaded into `bannedNames`
  at launch (`bannedLoad`; missing file → the 31 defaults written out),
  `isBanned` case-insensitive, `bannedAdd`/`bannedRemove` save at once.
  Signup refuses a banned name ("That username is not allowed."); a
  banned name at the login prompt hangs up straight away (`hangupPhase`,
  no message, no login-log record). Sysop menu `X` lists/adds/deletes.
  `docs/banned.md`.
- `walldb.cla` — the "Wall" vDB (160-byte records:
  name/created/message ≤120 chars — `wallMessageMax`; no indexes, ID
  order is time order; `addWallEntry`, `loadWallEntry` into
  `wallName/wallCreated/wallMessage`, `recentWallIds(n, ids)`).
  `wall.cla` — the screens: `startWall` draws the newest
  `wallRecent` (20) as a table (wide Date·Name·Message 17·16·34; narrow
  Who·Message 12·20 with name and date — no time — stacked), message cells wrapped
  by `wrapText` and rows expanded to fit, a joint rule between entries;
  pages are closed boxes of `terminal.rows - 1` lines — an entry that
  won't fit starts the next page — with `wallmore` ("Display More?
  (Y/[N])") on the last row, `Y` reopening the box at `wallIndex`/
  `wallRow`; then
  `wallask` (Y → `wallentry`, a line prompt capped at 120) and
  `wallDone` (main menu or `postLoginMotd`). `docs/wall.md`.
- `motd.cla` — the Message of the Day, `MOTD.txt` (TEXT/ttxt):
  `motdText` loaded at launch (`motdLoad`, missing → empty), `motdSave`
  writes and updates it; shown wrapped by `showMotd` (bbs.cla). Sysop
  menu `M` edits it in the line editor (`editTarget 'D'`).
  `docs/motd.md`.
- `basic/num.cla`, `basic/basic.cla` — the BASIC interpreter
  (`docs/basic.md`, caller-facing `basic/langref.md`). `Num` is a
  software float (`m * 2^e`, 31-bit mantissa; Clarus has no float and
  SANE is Mac-only) with GW-BASIC 7-digit print formatting. `basic.cla`
  keeps source per line (`srcLines`/`srcNumbers`), tokenizes on `RUN`
  into one flat `prog: list of Tok` (pc = token index, no AST),
  evaluates by recursive descent into `Val {isStr, n, s}`, and never
  blocks: `INPUT` parks in `BWaitLine`, `INKEY$`/`SLEEP` in
  `BWaitKey`/`BSleeping`; every error is an `abort` caught in
  `basicStep`. It knows nothing of the BBS — the including program
  defines `basicOut(s)`, `basicScreen(op, a, b)`, `basicPath(name,
  write)`, `basicEnv(name)` and drives `basicNew`/`basicLoad`/
  `basicRun`/`basicPrompt`/`basicStep(budget)`/`basicLine`/`basicKey`/
  `basicStop` off `basicState`. `games/basic.cla` is the BBS wrapper:
  the Games menu lists `:BASIC:*.BAS` (`gamenum` prompt), sysops get
  `B` = the `Ok` prompt in `:BASIC:<user>:`, screens `basic`
  (character mode, no echo) / `basicline` (line mode), `basicPump()`
  from input and the `every 2 ticks` block in bbs.cla,
  `disconnected()` → `basicStop()`. `basic/basic-host.cla` +
  `scripts/basic-host.sh` run it on the host over the TCP serial port
  (`nc localhost 2345`); the host lane can't build `every` blocks, so
  that wrapper pumps to completion per receive. The 68k backend can't
  pass a fixed array by value or `return m.get(...)` directly — use
  ints/locals. Tests: `tests/num-test.cla`, `tests/basic-test.cla`
  (`runProgram(src, inputs)` harness; `tests/fixtures/sst.bas` is the
  Star Trek acceptance run).
- `loginlog.cla` — the login log, `Logins.txt` (TEXT/ttxt): one
  65-byte fixed-width, tab-delimited text line per session — new flag
  (`*`/space), name padded to 31, `dateTimeStr` of the login, padded
  `durationStr` — appended on disconnect; `loginLogRecent(n, out)`
  reads the newest n in one positioned read, newest first; field
  offsets are the `login*At` consts.
- `editor.cla` — WWIV-style line editor for new posts, replies,
  private mail, file long descriptions, and the MOTD (`editTarget`
  picks the save target; `'F'` routes /S and /A to files.cla's
  `fileDescSave`/`fileDescAbort`, `'D'` to `motdSave` / back to the
  sysop menu, and `seedEditorBody(body)` pre-loads the rows from an
  existing body for edits). Each numbered
  line is one display row (`lineLimit = terminal.columns - 5`, set by
  `editBodyPrompt`): typing past the end of a row starts the next row
  with no newline in the text (`inputSoft`), Enter ends a row with a
  newline, and backspace at the start of a row (`editJoinPrevious`,
  called from `inputChar`) pops the previous row back into the buffer
  — dropping its newline — and redisplays it; the first row has no
  previous. Rows are stored with their own trailing CR when hard
  (`rowText`/`rowHard`), so the body is the rows joined end to end
  and readers reflow paragraphs. Commands: `/S` save, `/A` abort, `/L`
  list, `/D n`, `/E n` (keeps the row's newline status), `/I n`, `/R n`
  (Original/Replacement text swap), `/?`. Replies default the subject
  to `Re: <orig>` and thread to the starter's ID.

Tests (`tests/*.cla`, run by `scripts/test.sh`) are host-lane CLI
programs that include a module and assert on it; pure modules test
best, which is why `terminal.cla` (pure sequence builders) and
`termio.cla` (connection I/O) are separate files.

## Compiler limitations

None block current features: every gap this project filed for the
message-base and mail work (positioned file I/O via `filehandle`,
`crc16`, LE/word `text` accessors and `set*At` writers, `string(n)`,
toolbox include resolution via rtdir, connection-typed parameters, the
68k string-temp cap) shipped and is in the pinned toolchain. vDB
(`~/repos/libvdb/db.md`) is implementable in pure Clarus.

The filesystem API the file-area follow-ups needed — `file.list`,
`file.info`, `file.exists`, `file.delete`, `file.makeDir` (one level),
`file.rename`, `file.move` — shipped in the 2026-08-26 pin and the
FidoNet code uses it (`ftntoss.cla`, `emsi.cla`). The one gap left is
arbitrary-file resource-fork bytes (MacBinary preservation). The full
list, with what each unlocks, is `docs/language-gaps.md`.

## Commits

Commit messages are short — one sentence preferred, two or three at most —
and never mention Claude or AI co-authorship (no Co-Authored-By trailers).

## Layout

- `bbs.cla` — app entry: UI, session flow, screen dispatch, shared
  helpers and table senders (includes the rest)
- `sysop.cla` — sysop menu tree: paged user/board/file-area lists,
  detail cards, lettered field editors, delete confirmations
- `boards.cla` — caller-facing bulletin board reader: board picker,
  paged post list, framed post view
- `files.cla` — caller-facing file-area reader: area picker, paged
  file list, framed file view, XMODEM download
- `xmodem.cla` — XMODEM / XMODEM-1K / YMODEM sender and receiver
- `zmodem.cla` — ZMODEM sender and receiver (CRC-32/CRC-16 framing)
- `ftnaddr.cla`, `ftnpkt.cla`, `ftntoss.cla`, `emsi.cla` — FidoNet:
  addresses, packets/kludges, toss/scan, the EMSI poll
- `basic/` — the BASIC interpreter (`num.cla`, `basic.cla`), the host
  wrapper (`basic-host.cla`), `langref.md`, and the sample program;
  `games/basic.cla` — its BBS wrapper (Games menu, sysop prompt)
- `mail.cla` — private mail and netmail: inbox, message view,
  compose/reply
- `editor.cla` — line editor for new posts, replies, and mail (/S /A
  /L /D /E /I /R)
- `loginlog.cla` — fixed-width text login log + newest-N reader
- `banned.cla` — banned-username list (`Banned.txt`), sysop-editable
- `config.cla` — `Config.txt` settings with compiled defaults
- `walldb.cla`, `wall.cla` — wall database and screens
- `motd.cla` — Message of the Day file
- `scanner.cla`, `telnet.cla`, `user.cla`, `usersdb.cla`, `boardsdb.cla`,
  `postsdb.cla`, `maildb.cla`, `areasdb.cla`, `filesdb.cla`,
  `networksdb.cla`, `terminal.cla`, `termio.cla`, `btree.cla`,
  `vdb.cla` — modules above
- `tests/` — host-lane test suites (`tests/fixtures/` — real fsxNet
  packets, `sst.bas`); `scripts/` — build/test/deploy, `xmodem-e2e.sh`
  (lrz over socat, raw and via `telnet-shim.py`), `ftn-e2e.sh` (a poll
  against `emsi-peer.py`), `basic-host.sh` (BASIC over TCP)
- `bin/`, `vendor/` — pinned compiler + runtime/toolbox snapshot
- `docs/` — language reference + Snow how-to (symlinks), language-gaps.md,
  telnet-negotiation-reference.md and vt100.codes.txt (protocol notes)
- `snow/` — emulator, ROM, boot disk, workspace, BBSHD.hda (untracked)
- `simple-modem-emulator/` — Hayes modem bridge (tracked in this repo)
