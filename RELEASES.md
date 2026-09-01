# Releases

## Unreleased — v0.5

## v0.4 — 2026-09-01

Door games, custom welcome screens, and a modem the sysop controls:

- Games menu (`gamesdb.cla`, `gamedata.cla`): entries live in a Games
  database (sysop `G` tree + New Game wizard; types Basic, ZCode,
  Native, Hermes — BASIC runs today), and running games read and write
  through the `:GameData:<game>:<user>` sandbox with per-user /
  shared / bundled fallback. `docs/games.md`.
- BASIC speed: an on-disk token cache (`<file>.TOK`, keyed to source
  size+date) cuts game load from ~26 s to ~4 s on the Mac II, and the
  expression evaluator was rewritten as precedence climbing (3.2x on
  the game-start benchmark). `scripts/basic.sh` runs the interpreter
  in a terminal; `basic-host.sh --export` emits compilable C.
- Welcome screens (`screens.cla`): terminal-specific files under
  `:Screens:` (`80`/`40` x `Color`/`Monochrome` x type), with a
  fallback ladder (Color → Monochrome, type → ASCII, 80 → 40 at each
  rung); the m68k.club screens live in the repo. PETSCII defaults to
  white text (C64 terminals run white-on-black).
- IP banning: the modem emulator parses full Hayes command lines
  (chained, extended `+NAME` syntax), logs caller IPs with timestamps,
  and `AT+BAN` strikes the current caller — 5 minutes, then an hour,
  then a day, with a quiet day resetting the record. The BBS hangs up
  banned login names with `AT+BAN;H`.
- Modem control: `Config.txt` `modemInit` (default
  `AT&FE1Q0V1X4&C1&D2S0=0`, sysop Configuration `M`) is sent after a
  paced hang-up at startup and from `Maintenance > Initialize Modem`;
  `Maintenance > Hang Up` (Cmd-H) drops the line by hand; every modem
  command is logged as sent.
- `systemName` (`Config.txt`, sysop Configuration `N`) names the
  board on FTN Origin lines and EMSI IDENT.
- Board picker shows each board's last-post date and network name
  (`lastPost` stamped at post time, backfilled at launch); over-long
  table cells end in `...`.
- Scan commits `lastExported` over the inbound prefix at once, so
  FidoNet polls no longer re-walk all tossed echomail (a multi-minute
  freeze per poll); the log window trims its oldest lines so long
  runs never hit the 32,000-byte TextEdit cap.

## v0.3 — 2026-08-30

Daily maintenance, a working modem bridge for polling, and a FidoNet
node that runs unattended:

- Maintenance (`maint.cla`, `heap.cla`): boards carry an expiry
  (`E) Expire after` on the board card; inbound echomail past it is
  dropped at toss time), and a daily run at `maintenanceHour`
  (`Config.txt`, default 4) expires posts and compacts every
  database — header records and the append-only body heaps, with
  crash recovery on open. Callers are refused while it runs; the
  Mac's Maintenance menu toggles and starts it by hand. Measured
  on the Mac II test instance. `docs/maintenance.md`.
- B-tree overflow pages: one key holds unboundedly many values
  (e.g. every thread starter), so busy boards no longer fill a page.
- Incremental tossing: one packet, message or delete per timer tick
  while the line is idle, paused by a caller; netmail dupes dropped;
  `FidoNet > Toss Inbound Packets` starts a run by hand and the log
  shows "Tossing packet X of Y".
- FTN polling switch (`FidoNet > Toggle FTN Polling`, Sysop >
  Networks `P`): off keeps requests queued; a hang-up watchdog
  repeats +++/ATH and abandons the line rather than staying in
  progress.
- Modem emulator: stays connected to the serial port and reconnects
  when it drops; dials out (`ATDT host[:port]` or a `dial.conf`
  `tcp:`/`exec:` entry, so the FidoNet poll can run a bridge as a
  child); serial-side output is queued so a streaming peer cannot
  swallow `+++`; refused callers get NO ANSWER / BUSY.
- Log window: every line carries the heap's free/largest-block
  figures, auto-scrolls to the newest line (Maintenance > Toggle Log
  Auto-Scroll), and the toolchain pin's call-temp leak fix keeps
  long toss runs from running out of memory.
- Test instance: the repo's Snow runs on serial bridge 1235 / modem
  2324 with a 100 MB `snow/hdd2.img`; production stays on 1234/2323.

## v0.2 — 2026-08-28

FidoNet-technology networking as a leaf node (fsxNet first), over the
modem port:

- Networks database and sysop screens (address, uplink, passwords,
  dial string, UTC offset, poll schedule, AreaFix requests).
- Boards map to echomail areas (network + echo tag); posts carry
  MSGID/REPLY kludges with threading and duplicate detection.
- Netmail through the Mail system: send to any FTN address, replies to
  inbound netmail, unknown recipients delivered to the sysop.
- Type-2+ packet toss and scan (`ftnpkt.cla`, `ftntoss.cla`).
- The poll (`emsi.cla`): dial, EMSI handshake, ZMODEM send and
  receive, hang up, toss; scheduled by interval, from the Mac's
  FidoNet menu, or queued by the remote sysop.
- Requires a binkp bridge on the host (`docs/fidonet.md`, "Bridge
  contract") — in progress in libftn.

Also in this release:

- Banned usernames (`Banned.txt`): signup refuses them, a banned name
  at the login prompt hangs up; Sysop menu `X` edits the list.
- The Wall (`W`): short messages from callers, newest first, paged;
  shown after login with a "Sign the wall?" prompt.
- Message of the Day (`D`): sysop-edited in the line editor (Sysop
  menu `M`), shown after the wall at login.
- The main menu is grouped (boards/files/mail/games, then the
  informational screens, then quit).
- Games: a BASIC interpreter (`basic/basic.cla`, GW-BASIC dialect with
  a software float, sequential files, `PRINT USING`, `ON ERROR`/
  `RESUME`, `INKEY$`/`SLEEP`, `CLS`/`LOCATE`/`COLOR` over ANSI). `G) Games` lists and runs the `.BAS` files in the
  `BASIC` folder; sysops get the `Ok` prompt (`LIST`, `RUN`, `LOAD`,
  `SAVE`, `FILES`). Runs Super Star Trek. Also runs on the host over
  TCP (`scripts/basic-host.sh`). `docs/basic.md`, `basic/langref.md`.
  Ctrl-C breaks a running program.
- Access flags: per-user permissions (login, mail, boards, uploads,
  approve uploads, wall, games, sysop, BASIC prompt) edited from the
  sysop user card; `Config.txt` holds the new-user default (Sysop menu
  `C`).
- Terminals: PETSCII support for Commodore callers (C= line drawing,
  colors, case and key translation), a nine-entry terminal menu (ANSI,
  VT100, Apple II ASCII/VT52, C64) shown before login so the login
  screen renders for the chosen terminal, terminal-aware formatting
  helpers (color, bold, underline, blink, reverse, clear, cursor) that
  degrade to plain text, and boxed title bars on the main, sysop, and
  games menus.

## v0.1 — 2026-08-26

The first fully working BBS. Runs on a 68k Macintosh (System 6/7),
answering callers on the modem serial port, with telnet clients
supported through a Hayes-modem bridge.

- Login and signup with a Users database; the first account is the sysop.
- Terminal support: ASCII, ANSI, and VT100, with telnet negotiation
  (terminal type, window size, speed, echo, binary).
- Message boards: board picker, paged post lists, threaded replies,
  a WWIV-style line editor.
- Private mail between users.
- File areas: browse, upload, and download via XMODEM, XMODEM-1K,
  YMODEM, and ZMODEM (with ZMODEM resume).
- Sysop menu: manage users, boards, and file areas; approve uploads.
- Login log with a recent-callers screen.
