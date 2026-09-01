# Games — the Games database, plan and research notes

How 68kBBS offers games to callers, and how a sysop adds their own.
Main-menu `G` opens the `games` menu (`games/basic.cla`), drawn from
the Games database below. The rest of this page records the options
weighed on 2026-08-27, the plan, and what the Hermes externals
research established so far.

## The Games database

`gamesdb.cla` — the "Games" vDB, one record per menu entry; the vDB
record ID is the game ID and the menu order. 256-byte records:

| offset | field |
|---|---|
| 0 | name, 64-byte Pascal field |
| 64 | description, 64-byte Pascal field (shown after the name on wide terminals) |
| 128 | filename, 64-byte Pascal field — a bare file name inside the type's folder, never an HFS path (the BASIC sandbox refuses colons) |
| 192 | type, 1 byte: the `GameType` member value |
| 193 | flags, 1 byte: bit 0 = enabled (listed on the Games menu) |
| 194+ | reserved, zero |

`enum GameType { Basic, ZCode3, ZCode5, Native, Hermes22, Hermes31, Hermes35 }` — the
member value is the on-disk byte, so members are appended, never
renumbered; a byte no member owns loads as `Basic` (`gameTypeFromByte`)
rather than raising `GameType()`'s runtime error. The type says how
the game runs and where its file lives: `Basic` = `:BASIC:<filename>`
run by the interpreter (stage 2 below); `ZCode3`/`ZCode5` = a story
file for the Z-machine interpreter to come; `Native` and the `Hermes*`
versions = a code resource in `:Externals:` (stages 1 and 3, not yet
implemented — picking one says so and returns to the menu). Folding the
Hermes API version into the type saves a column.

API, the `areasdb.cla` shape: `gamesOpen`/`gamesClose`, `createGame`,
`loadGame(id)` into the global `game`, `saveGame`, `gameCount`,
`gamesNextId`, `gameTypeName`. `tests/gamesdb-test.cla`.

## Game data — where a game may read and write

`gamedata.cla`. Every interpreter resolves a game's bare file names
through `gameDataPath(gameId, userId, name, write, programFolder)`
(BASIC's `basicPath` while a game runs; the Z-machine's save/restore
later). The folders live next to the application:

| path | holds |
|---|---|
| `:GameData:<gameId>:` | data shared by every caller of that game — high-score tables, a persistent world |
| `:GameData:<gameId>:<userId>:` | one caller's own files — saves |

The game names files with no path. A plain name is the caller's own
file; a leading `_` means the shared one. **Writes** go to that folder,
creating `:GameData`, the game's and the caller's folders on first
use (`gameDataEnsure`; `file.makeDir` is one level at a time).
**Reads** of a plain name look in the caller's folder, then the shared
one, then `programFolder` (`:BASIC:` — data installed with the game,
read-only), and name the caller's path when nothing exists so the
interpreter's own "file not found" fires; `_name` reads the shared
folder only. `""` is the folder itself (BASIC's `FILES`). A colon
anywhere is refused, so no name reaches outside the sandbox. The keys
are record IDs, not names: a renamed game or user keeps its data, a
deleted one orphans it (deleting never touches files). Hermes
externals do their own Mac file I/O and cannot be sandboxed this way.
`tests/gamedata-test.cla`.

**Sysop menu `G`** (`sysop.cla`) is the usual L/S/E/N/D tree: paged
list (ID/Name narrow; + Type/File/On wide), detail card, lettered edit
card (`N`ame, `D`escription, `T`ype, `F`ile, `E`nabled toggles; `S`
saves), Y/N delete over the card, and the New Game wizard: name →
description → type (`B`, the default) → file name, created enabled.
Deleting a row never touches the game's file. Adding a BASIC game is
therefore: put the `.BAS` file in `:BASIC:`, then register it here.

Running a BASIC game tokenizes the source (slow on the 68k — minutes
on an 8 MHz SE) into a token cache next to it (`<file>.TOK`, keyed to
the source's size + mod date); later runs load the cache directly. At
launch `basicWarmCaches` re-tokenizes any enabled BASIC game whose
cache is missing or stale (fresh ones cost a header check,
`basicTokensFresh`), so callers never pay the first-run cost. The
loaded token state also stays in memory between sessions (`progStamp`,
cleared whenever the source mutates): re-running the game the
interpreter already holds skips loading entirely — the log line says
`(resident)`. Editing the `.BAS` invalidates cache and residency
automatically; the `.TOK` can always be deleted safely.

## Plan

Three stages, in development order:

1. **Built-in Clarus games.** Games are Clarus modules
   (`include "games/<name>.cla"`) registered in a table the Games menu
   is drawn from. Pluggable at build time only — a sysop who wants a
   new one rebuilds the app. Needed anyway as the floor for whatever
   ships first, and the model every later stage plugs into (a game is
   a screen-state machine driven by `processInput`, like every other
   screen).
2. **BASIC games via a native Clarus BASIC.** *Shipped 2026-08-28:
   `basic/basic.cla` and `games/basic.cla`, see `docs/basic.md`; the
   Games database replaced the folder listing on 2026-08-30.* A tokenizer plus
   tree-walking interpreter written in Clarus (native 68k, so fast
   enough), with a BBS-flavored I/O layer: `PRINT` → `sendData`,
   `INPUT` → a line-mode prompt (the interpreter parks like any other
   screen; there is no blocking read), plus builtins for the caller's
   name, access level and a per-game save file. Sysops drop `.bas`
   files in a `Games` folder; callers could get a "write your own"
   area later. Estimated ~2k lines. Deliberately **not** a 6502
   emulator running a ROM BASIC: that would be ~10× slower, need an
   I/O trap layer anyway, and give a BASIC with no BBS hooks.
3. **Hermes II externals via a compatibility layer.** Run the period
   Mac BBS game binaries unmodified — the most authentic option there
   is, since the Mac scene had its own corpus. Support several Hermes
   API versions if possible; details and findings below.

## Options considered

- **Data-driven engines** (CYOA/node scripts, trivia, a Z-machine
  interpreter for Infocom/Inform games): a good pluggable story with a
  huge existing library and modern authoring tools, but not
  period-BBS games. Kept in reserve; the Z-machine idea in particular
  is cheap relative to its payoff if wanted later.
- **A separate door application plus a byte pipe** (BBS launches an
  app under MultiFinder and proxies the caller's bytes over ADSP/TCP)
  and **remote door servers** (proxy to `host:port` on a modern box,
  DoorParty-style): both off the table — two apps in a Mac II's RAM
  for little gain, and the Mac's only wire today is the modem port.
- **Porting DOS door games**: the closed-source classics (LORD,
  TW2002, BRE) can't be ported at all; open-source C doors (many were
  written against OpenDoors) could be recompiled with Retro68 as code
  resources against an OpenDoors-subset shim over the same loader
  stage 3 builds, so that door comes along for the ride rather than
  being a separate project. Pascal doors would need FPC's m68k
  classic-Mac target; not counted on.

## Hermes II externals — what the research established

Sources: the Hermes 2.2 source (`hermes/2.2`, THINK Pascal, MIT), the
v1.9 C header in `hermes/2.2/serialnumbers/HermHeaders.h`, and the
three externals collections from hermesbbs.com (v2.2: 60+, v3.1.1: 16,
v3.5: 9 — StuffIt 5/Arsenic, `unar` extracts them). The v3.1 header
pair (`hermes/3.1/HermHeaders.h`, `hermes/Hermheaders.p`) is a
method-13 (LZ+H) `SIT!` archive that `unar` corrupts a few hundred
bytes in; the copy on hermesbbs.com is the same file. **It needs a
real StuffIt Expander** (classic Mac, e.g. in Snow) — until then the
3.1 record layout is known only empirically (below).

### The model — event-driven, like ours

- An external is a file of type `XHRM` in `<shared>:Externals:`.
  Resources: `HRMS 100` = `eInfoRec` (allTime, minSLforMenu,
  restriction letter; 6 bytes in 2.2/3.1, 60 in 3.5), `XHRM 10001`
  (or 63) = the caller-facing code resource, `XHRM 10000` = an
  optional sysop-side Mac-UI external (out of scope), `ICN# 10000`.
  Hermes `OpenResFile`s it, `HLock`s the code and keeps the resource
  file open and `UseResFile`d around each call
  (`SystPref.p:1683-1740`, `InpOut.p:47-62`).
- **One pascal call, one argument**: `UserExternal(theExtRec:
  UserXIPtr)`, entered by pushing the code address then
  `movea.l (a7)+,a0 / jsr (a0)`. `message` says why: `ACTIVEEXT` 1,
  `IDLE` 2 (every idle pass, `allTime` externals only), `CLOSENODE` 3
  (hang-up), `CLOSEEXTERNAL` 4 (quit).
- **No blocking input.** `LettersPrompt`/`NumbersPrompt`/
  `YesNoQuestion` fill `myPrompt`, set `BoardAction := Prompt` and
  return. Hermes's idle loop calls the external again with
  `ACTIVEEXT` only once the answer is in `curPrompt` (`IdleUser` →
  `SetBookmark` when `BoardAction = none`, `HUtils5.p:409-412`,
  `HUtils4.p:1568-1640`). Externals are state machines keeping their
  stage in a `privates` handle Hermes preserves between calls
  (`myPrivs`: per-node stage arrays). Exit is `GoHome()`
  (`BoardSection := MainMenu`). This maps directly onto
  `user.screen`/`processInput`: an `"external"` screen that calls
  `ACTIVEEXT`, parks on a line-mode prompt when a callback sets one,
  writes the answer into the fake `curPrompt`, and re-enters.
- **The API is a callback table plus raw struct access**
  (`UserXInfoRec`, `Initial.p:784-807`): 18 pascal procs —
  `bCR`, `OutLine(s, NLatBegin, color)`, `HangUpAndReset`,
  `PromptUser`, `LettersPrompt`, `NumbersPrompt`, `YesNoQuestion`,
  `GoHome`, `BackSpace`, `ANSIPrompter`, `ReadTextFile`,
  `ReprintPrompt`, `OutChr`, `ANSICode`, `PAUSEPrompt`, `FindUser`,
  `GiveTime`, `LogThis` — each called by pushing its args then the
  ProcPtr and the same `movea.l (a7)+,a0 / jsr (a0)`; **and** pointers
  to every node's `HermUserGlobs` (`n[10]`, `curNode`), the system
  record, message/dir/GFile config and the user list handle
  (`HermUsers`, 64-byte `ULR` entries). Externals read and write
  `thisUser`, `curPrompt`, `activeUserExternal`, `BoardSection`,
  `boardAction` and scratch `crossInt*` straight out of the node
  record, so the shim must present a byte-exact `HermUserGlobs`
  (~20 KB: two 4098-byte driver buffers, `myPrompt`, ~150 fields,
  three 1552-byte `UserRec`s). `OutLine`'s color is a Hermes ANSI
  color 0-7 (-1 = none) → `colorSeq`. `GiveTime`'s `float` argument
  arrives as 4 raw bytes to ignore.

### Layouts, validated against the binaries

Offsets computed from the v1.9 C header (THINK Pascal rules: 2-byte
alignment, Booleans packed, **enums 1 byte** — the binaries prove the
last) and confirmed by disassembling the 2.2 collection (57 externals
with code; capstone, `d16(An)` displacement census):

| field | offset | externals touching it |
|---|---|---|
| `UserXInfoRec.procs[0]` / `[1]` | 354 / 358 | 53 / 53 |
| `curPrompt` (length, first char) | 9906 / 9907 | 53 / 20 |
| `thisUser`, `.UserName` | 14468 / 14470 | 27 / 22 |
| `thisUser.SecLevel` / `.CanANSI` | 14608 / 14656 | 18 / 22 |
| `activeUserExternal` | 19710 | 57 |
| `BoardSection` / `boardAction` / `savedBDaction` | 19713 / 19714 / 19715 | 34 / 40 / 38 |

Callback popularity in 2.2 (the shim's priority order): OutLine and
bCR (all), LettersPrompt 39, OutChr 39, PAUSEPrompt 38, LogThis 34,
YesNoQuestion 32, NumbersPrompt 26, GoHome 21, ANSICode 20,
ReadTextFile 12, ANSIPrompter 5; FindUser, GiveTime and
HangUpAndReset barely used.

### API versions

- **2.2** (Hermes 2.x, 1991-93): the layout above. `procs` at 354.
- **3.1** (Hermes II 3.1/3.2, 1994-95; 17 externals surveyed): same
  slot ordering, but the table is at **100** (the 256-byte reserve
  dropped, so `n[]` starts at 60), and the `HermUserGlobs` accesses
  cluster at 8196 (17/17), 8200/8201, 9256/9257 (15 — the (length,
  char) pair that looks like `curPrompt`, 650 bytes earlier than in
  2.2), 13356/13392/13624 (13 each), 13728, 14260 — nothing lines up
  with the 2.2 record, so `HermUserGlobs` and `UserRec` were
  rearranged, not just extended. Resolving this needs the 3.1 header;
  then run the same calculator and cross-check (`curPrompt` should
  land on 9256, `activeUserExternal` on a 17/17 offset).
- **3.5** (6 externals): another table base (`0x80`, extra slots up
  to `0x274`), 60-byte `HRMS 100`. Out of scope unless its header
  turns up.

Version dispatch can be by the external's own signature: `procs` base
and the `HRMS 100` size differ per generation, and a sysop-side
setting can override.

### What the compatibility layer needs

1. **Compiler (small):** a call-through-pointer primitive — the
   minimum is `callptr(code: ptr, arg: ptr)`, pascal convention, one
   argument, no result (the `= trap` marshalling in `cg68k.cla` is the
   template; the language today deliberately has no indirect call) —
   and a way to store a `callback func`'s glue address into memory
   (today the name only decays as an `external func` `ptr` argument).
   `callback func` parameter/return types (`bool`/`word`/`int`/`ptr`)
   already cover all 18 procs. Host lane: stubs; 68k code can't run
   there anyway.
2. **`vendor/toolbox/resources.cla`:** `OpenResFile`, `UseResFile`,
   `CloseResFile`, `Get1Resource`, `SetResLoad` (trivial traps).
   `file.info` already gives the `XHRM` type check.
3. **`hermes.cla` (~600-900 lines):** offset constants *generated*
   from the headers per API version (never hand-counted); the
   `"external"` screen; a `NewPtr` block for `HermUserGlobs` +
   `UserXInfoRec` + a `HermUsers` list built from the Users database;
   the 18 `callback func`s over `sendData` and the prompt machinery;
   `CLOSENODE` from `disconnected()`, `CLOSEEXTERNAL` at quit;
   the Games menu listing the `Externals` folder.

Risks accepted: no sandbox (a crashing external takes the BBS down,
as in 1993); single node (`totalNodes = 1`); THINK C code resources
set up their own A4 world, so nothing to do there.

### Tools

The survey scripts (AppleDouble/resource-fork reader, capstone
displacement census, C-header layout calculator) are in
`hermes/tools/` (`survey*.py`, `layout.py`; capstone needed for the
census). `hermes/` is untracked.
