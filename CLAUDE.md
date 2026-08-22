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
bin/clarusc bbs.cla   # check only
scripts/build.sh      # 68k Mac app -> build/68kBBS.bin (MacBinary)
scripts/test.sh       # run every tests/*.cla on the host lane
scripts/deploy.sh     # build + refresh snow/BBSHD.hda + restart Snow
```

Toolbox includes come from the snapshot too
(`include "vendor/toolbox/osutils.cla"`). The live-repo wrapper scripts
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
- `user.cla` — `User` record (name, authenticated, passwordHash,
  screen, input mode, buffer) + global `user`; `hashPassword` (djb2,
  non-cryptographic). `terminal.cla` — `Terminal` record (columns,
  rows, color, type: ASCII/ANSI/VT100) + global `terminal`, `Color`
  enum, and pure ANSI sequence builders (`colorSeq`, `backgroundSeq`,
  clear consts). `termio.cla` — modem-facing send wrappers over those
  (gated on `terminal.color`).
- `bbs.cla` — app/UI declarations, session flow. `dataChar` assembles
  input (Line mode: buffer until CR; Character mode: each char).
  `processInput` dispatches on `user.screen`: login → password →
  terminal-type menu → main menu. Menu conventions: `gotoScreen(s)`
  sets the screen and draws menu + prompt; `displayMenu`/`displayPrompt`
  switch on `user.screen`; choices are case-insensitive (`upperStr`);
  `?` redraws the menu; invalid main-menu input redraws only the
  prompt; the terminal menu redraws fully and defaults to VT100 on
  empty input. Logoff paces `+++` / `ATH` through a `every 30 ticks`
  timer (`hangupPhase`) to honor the Hayes guard time; the resulting
  NO CARRIER resets the session. Sessions reset in `connected()`
  (`new User` / `new Terminal`).

Tests (`tests/*.cla`, run by `scripts/test.sh`) are host-lane CLI
programs that include a module and assert on it; they can only include
files with no UI and no connection method calls — which is why
`terminal.cla` (pure) and `termio.cla` (modem I/O) are separate files.

## Known compiler limitations (workarounds in use)

Tracked in `docs/language-gaps.md` (which also specs the positioned
file I/O needed for the planned vDB database — see `~/repos/libvdb/db.md`):

- Method calls on a connection held in a parameter/local don't compile
  ("receiver kind 13") — use the global `modem`.
- `emit68k` caps string temps per statement ("bump cgBigTmpSlots") —
  split long `+` chains across statements.
- The host emit lane can't compile UI programs or connection calls, so
  `bbs.cla` itself can't run on the host — only the emulator.
- `include "toolbox/..."` doesn't resolve against the compiler's
  catalog — include `vendor/toolbox/...` instead.

## Commits

Commit messages are short — one sentence preferred, two or three at most —
and never mention Claude or AI co-authorship (no Co-Authored-By trailers).

## Layout

- `bbs.cla` — app entry: UI, session flow, menus (includes the rest)
- `scanner.cla`, `user.cla`, `terminal.cla`, `termio.cla` — modules above
- `tests/` — host-lane test suites; `scripts/` — build/test/deploy
- `bin/`, `vendor/` — pinned compiler + runtime/toolbox snapshot
- `docs/` — language reference + Snow how-to (symlinks), language-gaps.md
- `snow/` — emulator, ROM, boot disk, workspace, BBSHD.hda (untracked)
- `simple-modem-emulator/` — Hayes modem bridge (tracked in this repo)
