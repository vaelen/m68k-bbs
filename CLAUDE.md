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
`Mail.*`, `Areas.*`, `ARE*` — then reseed. The vDB format is identical on both lanes (big-endian),
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
  unknown WILL → DONT, other DO/DONT → WONT), releases clean bytes to
  `inputChar`, drops NVT CR NUL's NUL, applies NAWS to
  `terminal.columns/rows` (clamped 20-132 / 10-60) and records
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
  (160-byte records: username/hash/email/access/created/lastSeen;
  vDB record ID = user ID; username indexed case-insensitively).
  `boardsdb.cla` — the "Boards" database (name/description/network,
  record ID = board ID). `postsdb.cla` — one board's posts at a time
  (`postsOpen(boardId)`): header records in `BRD<nn>.*` (sender/
  created/threadId/subject, thread ID indexed; 0 = thread starter,
  else the starter's post ID) plus exact-fit bodies in an append-only
  `BRD<nn>.MSG` heap, written and flushed before the journaled header
  add so a crash only orphans heap bytes. `maildb.cla` — the "Mail"
  database (256-byte header records: from/to names, from/to user IDs
  with the recipient indexed, created, flags bit 0 = read) plus an
  append-only `Mail.MSG` body heap, same write ordering as posts
  (`docs/mail.md`). `areasdb.cla` — the "Areas" database (256-byte
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
  non-cryptographic). `terminal.cla` — `Terminal` record (columns,
  rows, color, echo — on by default, linemode — off by default, set per screen by
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
  echoed hotkey style with a newline). Numbered lists (boards, areas,
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
  empty name cancels; first account gets sysop access). Logins are
  checked against the Users database (case-insensitive; wrong
  password returns to login). Last-seen is updated at login; the
  "Welcome back / Last on / You have N new message(s)" banner is
  printed by `applyTerminal` once the terminal type is known, just
  before the main menu (`returning`/`previousSeen` carry it across).
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
  buffer.
- `sysop.cla` — the sysop menu tree (gated on `user.access`): paged
  user/board lists (`listFromId` cursor, `[Enter] More` prompt),
  detail cards, lettered-field edit cards (buffered; `S` saves, `Q`
  discards; a sysop cannot change their own access level or delete
  their own account), Y/N delete confirmations over the detail card,
  the New Board wizard, and the same L/S/E/N/D tree over file areas
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
  next/previous file, sysop-only `D` delete, `Q` up one level. No
  download yet (transfers are a later step); read-only browsing.
- `mail.cla` — private mail UI: main-menu `M` → paged inbox (`*`
  marks unread, newest first) → framed message view (viewing marks
  read; `R` reply, `D` delete with Y/N confirm, `>`/`<` between
  messages) → compose via `editor.cla` with `editTarget = 'M'`:
  `To:` must resolve to a local user (`findUserId`), empty `To:`
  cancels.
- `editor.cla` — WWIV-style line editor for new posts, replies, and
  private mail (`editTarget` picks the save target). Each numbered
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

The **next** file-area steps (upload/download, sysop import, area-folder
management, deletion cleanup, MacBinary preservation) do need runtime
features that are not there yet — directory listing, file metadata
query, file delete, arbitrary-file resource-fork bytes, set
type/creator, mkdir, rename. Plain data-fork transfers need none of
them. The full list, with what each unlocks, is `docs/language-gaps.md`.

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
  file list, framed file view (browse-only; no transfers yet)
- `mail.cla` — private mail: inbox, message view, compose/reply
- `editor.cla` — line editor for new posts, replies, and mail (/S /A
  /L /D /E /I /R)
- `scanner.cla`, `telnet.cla`, `user.cla`, `usersdb.cla`, `boardsdb.cla`,
  `postsdb.cla`, `maildb.cla`, `areasdb.cla`, `filesdb.cla`,
  `terminal.cla`, `termio.cla`, `btree.cla`, `vdb.cla` — modules above
- `tests/` — host-lane test suites; `scripts/` — build/test/deploy
- `bin/`, `vendor/` — pinned compiler + runtime/toolbox snapshot
- `docs/` — language reference + Snow how-to (symlinks), language-gaps.md
- `snow/` — emulator, ROM, boot disk, workspace, BBSHD.hda (untracked)
- `simple-modem-emulator/` — Hayes modem bridge (tracked in this repo)
