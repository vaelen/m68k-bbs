# Games — plan and research notes

How 68kBBS will offer games to callers, and how a sysop adds their own.
Main-menu `G` opens the (still empty) `games` menu in `bbs.cla`. This
page records the options weighed on 2026-08-27, the plan, and what the
Hermes externals research established so far.

## Plan

Three stages, in development order:

1. **Built-in Clarus games.** Games are Clarus modules
   (`include "games/<name>.cla"`) registered in a table the Games menu
   is drawn from. Pluggable at build time only — a sysop who wants a
   new one rebuilds the app. Needed anyway as the floor for whatever
   ships first, and the model every later stage plugs into (a game is
   a screen-state machine driven by `processInput`, like every other
   screen).
2. **BASIC games via a native Clarus BASIC.** A tokenizer plus
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
