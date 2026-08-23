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
`modem.received → feedChar (scanner.cla) → dataChar (bbs.cla) → processInput`.

- `scanner.cla` — a state machine that watches the raw stream for the
  Hayes result codes `\r\nCONNECT <digits>\r\n` / `\r\nNO CARRIER\r\n`
  (state persists across chunks). It is also a *filter*: bytes it
  releases as ordinary data go to `dataChar`; candidate result-code
  bytes are held and either discarded (match → calls `connected()` /
  `disconnected()`) or replayed (mismatch). CR/LF always pass through
  immediately, so the one hang-up artifact is a single empty line just
  before disconnect. The including program defines `connected`,
  `disconnected`, and `dataChar`.
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
  screen, input mode, buffer, id, email, access, created, lastSeen)
  + global `user`; `hashPassword` (djb2,
  non-cryptographic). `terminal.cla` — `Terminal` record (columns,
  rows, color, type: ASCII/ANSI/VT100) + global `terminal`, `Color`
  enum, and pure ANSI sequence builders (`colorSeq`, `backgroundSeq`,
  clear consts), plus the box-drawing/table builders (`boxChar`,
  `ruleLine`, `rowLine`, `pad`, `center` — see `docs/tables.md`).
  `termio.cla` — connection-facing send wrappers over those (take a
  `connection` parameter, gated on `terminal.color`).
- `bbs.cla` — app/UI declarations, session flow. `dataChar` assembles
  input (Line mode: buffer until CR; Character mode: each char).
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
  picker (unpaged table) → paged post list (newest first, numbered
  from 1 per page, post IDs hidden, `Page X of Y` footer) → framed
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
  private mail (`editTarget` picks the save target): numbered line
  prompts; `/S` save, `/A` abort, `/L` list, `/D n`,
  `/E n`, `/I n`, `/R n` (Original/Replacement text swap), `/?`.
  Replies default the subject to `Re: <orig>` and thread to the
  starter's ID. Lines are stored as typed (≤255 bytes, no column
  limit) and re-wrapped per reader; bodies join lines with CR.

Tests (`tests/*.cla`, run by `scripts/test.sh`) are host-lane CLI
programs that include a module and assert on it; pure modules test
best, which is why `terminal.cla` (pure sequence builders) and
`termio.cla` (connection I/O) are separate files.

## Compiler limitations

None currently. Every gap this project filed (positioned file I/O via
`filehandle`, `crc16`, LE/word `text` accessors and `set*At` writers,
`string(n)`, toolbox include resolution via rtdir, connection-typed
parameters, the 68k string-temp cap) shipped and is in the pinned
toolchain — see `docs/language-gaps.md` for the record. vDB
(`~/repos/libvdb/db.md`) is now implementable in pure Clarus.

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
- `scanner.cla`, `user.cla`, `usersdb.cla`, `boardsdb.cla`,
  `postsdb.cla`, `maildb.cla`, `areasdb.cla`, `filesdb.cla`,
  `terminal.cla`, `termio.cla`, `btree.cla`, `vdb.cla` — modules above
- `tests/` — host-lane test suites; `scripts/` — build/test/deploy
- `bin/`, `vendor/` — pinned compiler + runtime/toolbox snapshot
- `docs/` — language reference + Snow how-to (symlinks), language-gaps.md
- `snow/` — emulator, ROM, boot disk, workspace, BBSHD.hda (untracked)
- `simple-modem-emulator/` — Hayes modem bridge (tracked in this repo)
