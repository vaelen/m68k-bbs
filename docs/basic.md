# BASIC — developer page

68kBBS carries a GW-BASIC-flavored BASIC interpreter written in Clarus.
Callers pick `.BAS` programs from the Games menu; sysops also get the
classic `Ok` prompt. The interpreter is a self-contained module with
no knowledge of the BBS: it talks to whatever includes it through four
hook functions and an API, so the same file runs on the host lane over
TCP (`scripts/basic-host.sh`) and could be embedded in another Clarus
app with a page of wrapper code. The caller-facing language reference
is `basic/langref.md`; this page is the developer's view. Design
history: `docs/superpowers/specs/2026-08-28-basic-interpreter-design.md`.

## Files

| file | responsibility |
|---|---|
| `basic/num.cla` | `Num`, the software float: arithmetic, compare, parse, GW-BASIC print formatting, SQR/EXP/LOG/SIN/COS/TAN/ATN/power. Pure. |
| `basic/basic.cla` | source store, tokenizer, evaluator, statements, wait states, immediate mode, sequential files. Includes `num.cla` only. |
| `basic/basic-host.cla` | host-lane CLI wrapper over the TCP-mapped serial port |
| `games/basic.cla` | BBS wrapper: hooks over `sendData`/`terminal`, the Games list, the sysop prompt, the `basic`/`basicline` screens |
| `basic/langref.md` | the language as a caller sees it |
| `tests/num-test.cla`, `tests/basic-test.cla` | host-lane suites (`scripts/test.sh`); `tests/fixtures/sst.bas` is Super Star Trek, the acceptance program |
| `basic/QBasic-SST0.BAS` | the same program, for the `BASIC` folder |

## Why a software float, and why no AST

Clarus has `int` and 16.16 `fixed` (±32767) and nothing else; SANE is
a Mac-only trap and the host lane cannot execute traps. Star Trek's
efficiency rating alone (`1000*(K7/(T-T0))^2`) reaches 1.6 million, so
`num.cla` implements numbers as `m * 2^e` with a 32-bit signed mantissa
normalized to `[2^30, 2^31)`: about nine significant digits, better
than MS BASIC single precision (24 bits), with `PRINT` rounding to seven
so program output matches GW-BASIC. Multiply is done in 16-bit halves
with round-to-nearest at the normalized precision; divide is a 31-step
restoring division plus a rounding bit; add halves both mantissas
(one bit of rounding loss). Range is ~±2.7e39, flush-to-zero below
~1e-39; `Overflow` and `Division by zero` are `abort`s.

Clarus has no recursive records, and MS BASIC itself never built a
tree: it crunched lines to tokens and interpreted by scanning them.
So does this interpreter. The program counter is an index into one
flat token list; `GOTO` is a map lookup; `FOR`/`GOSUB`/`WHILE` are
stacks of token positions.

## The hook contract

The including program defines these four functions:

| hook | purpose |
|---|---|
| `basicOut(s: string)` | every byte of program output; `\n` (CR) ends a line — the wrapper translates to its own line ending |
| `basicScreen(op: char, a: int, b: int)` | `'C'` CLS; `'L'` LOCATE row `a`, col `b` (0 = unchanged); `'K'` COLOR fg `a`, bg `b` (−1 = unchanged, QBasic color numbers); `'B'` BEEP. The wrapper decides what, if anything, to emit |
| `basicPath(name: string, write: bool): string` | maps a bare BASIC file name to a real path inside the wrapper's sandbox; `""` refuses; `name == ""` asks for the folder itself (`FILES`) |
| `basicEnv(name: string): string` | `ENVIRON$`; `""` when unknown |

The interpreter never references a connection, a terminal, or anything
in `bbs.cla`; `tests/basic-test.cla` shows the minimum wrapper (the
hooks append to a `text`).

## The API

| call | effect |
|---|---|
| `basicNew()` | clear program, variables, stacks, files; state `BIdle` |
| `basicLoad(src: text): bool` | replace the program from source (CR, LF or CRLF line ends; unnumbered lines get previous + 1, 10 for the first); prints `Duplicate line number n` and returns false on a collision |
| `basicRun()` | tokenize and start at the first line; errors end in `BDone` |
| `basicPrompt()` | print `Ok`, state `BPrompt`; from here `RUN`'s errors return to the prompt |
| `basicStep(budget: int): bool` | execute up to `budget` statements, stopping early at a wait, the end, an error, or after ~1 KB of output (so a serial line keeps draining). Returns true while the host should keep calling: `BRunning`, `BSleeping`, `BWaitKey` |
| `basicLine(s: string)` | a completed input line: the answer to `INPUT`/`LINE INPUT` (`BWaitLine`) or a line typed at the prompt (`BPrompt`) |
| `basicKey(c: char)` | a raw key for `INKEY$`; wakes `SLEEP` and a stalled `INKEY$` poll |
| `basicBreak()` | keyboard interrupt: `STOP` at the current line from any running or waiting state (`CONT` resumes at the prompt); no-op when idle or at the prompt |
| `basicStop()` | abort, close files; state `BDone` |
| `basicState` | `BIdle`, `BRunning`, `BWaitLine`, `BWaitKey`, `BSleeping`, `BPrompt`, `BDone` |
| `basicWidth` | line width for `PRINT` wrapping and comma zones (default 80; `WIDTH n` changes it) |
| `basicSleepInstant`, `basicFixedSeed` | test flags: timed `SLEEP` returns at once; `RANDOMIZE` uses a fixed seed |

The wrapper picks its input mode from the state — line mode for
`BWaitLine` and `BPrompt`, single keys otherwise — and echo is the
wrapper's business (the BBS already echoes in line mode; the host
wrapper relies on the terminal's local echo).

### Waits

Nothing blocks. `INPUT` prints its prompt, records where the variable
list starts, skips to the end of the statement and returns with
`BWaitLine`; `basicLine` splits the answer on commas (quotes honored),
checks the count and the numeric items, prints `?Redo from start` and
re-prompts on a mismatch, else assigns and resumes. `INKEY$` shifts a
key queue or returns `""`; after 200 consecutive empty polls the
interpreter parks in `BWaitKey`, since a program spinning on `INKEY$`
has nothing else to do until a key arrives. `SLEEP n` sets a deadline
(`BSleeping`); bare `SLEEP` waits for a key; either wakes on a key.

### Errors

Every runtime and syntax error is `abort("<message>")`; `basicStep`
wraps execution in one `attempt`. The handler prints `Syntax error in
2140` (GW-BASIC wording, no `?` prefix; immediate-mode errors omit the
line), closes files, and drops to the prompt (if the run started
there) or `BDone`. `STOP` prints `Break in n` and `CONT` resumes.

## Inside basic.cla

Sections in file order:

- **Source store** — `srcLines: intmap of text` by line number plus
  the sorted `srcNumbers`. Immediate-mode line entry, `DELETE`, `LOAD`
  and `NEW` edit this; `LIST` prints it.
- **Tokenizer** — `RUN` retokenizes everything into `prog: list of
  Tok` (`kind`, `ival`, `aux`, `num`; 20 bytes). A `TLine` token
  carries each line's number; `lineIndex` maps number → index; labels
  (`name:` at line start) go in `labels`; names are interned uppercase
  with their type suffix; string literals and the raw text after each
  `DATA` are pooled. Keywords must be delimited — `TOTAL` and `SCORE`
  are variables — except the crunched forms `1TO9`, `GOTO10`, `THEN20`
  (a glue keyword directly followed by digits).
- **Values** — `Val { isStr, n: Num, s: string }`. Scalars live in
  `nums`/`strs` keyed by name-with-suffix (`A`, `A%`, `A$` are three
  variables; `DEFINT` etc. supply the implied suffix); a store into `%`
  rounds half-to-even and checks ±32767. Arrays: `ArrayInfo` per name
  over two heaps (`anums`, `astrs`), up to three dimensions, auto-DIM
  to 10.
- **Evaluator** — recursive descent, one function per precedence
  level (`IMP EQV XOR OR AND NOT relational + - MOD \ * / unary- ^`).
  Logical operators work on the operands rounded to ints.
- **Output** — `outStr` tracks `cursorCol`/`cursorRow` for `POS`,
  `CSRLIN`, `TAB` and the 14-column comma zones, wraps an item that
  would cross `basicWidth`, and ends the line when an item exactly
  fills it (GW-BASIC's own quirk). `PRINT #n` redirects through
  `printFile`. `PRINT USING` (`stmtPrintUsing`) evaluates the items,
  then walks the format: `usingField` parses one field spec into the
  `u*` globals (kind, width, decimals, comma/sign/fill/dollar/exponent
  flags) and `usingNumber` renders a value into it — body first
  (digits, commas, point), then sign and `$`, then `%` if it won't
  fit, else left-padded with spaces or `*`.
- **ON ERROR** — `execStatement` notes each statement's start in
  `stmtStartPc`; when an abort reaches `handleAbort` with a handler
  armed (`onErrorLine`) and not already inside it, it sets `ERR`/`ERL`
  (`errorCode` maps message → GW-BASIC number; `ERROR n` pre-sets
  `pendingErrCode`), remembers `errStmtPc`, and jumps to the handler
  instead of reporting. `RESUME` returns to `errStmtPc`, `RESUME NEXT`
  to the statement after it, `RESUME line` elsewhere; an error inside
  the handler is reported as usual.
- **Statements** — `execStatement` switches on the keyword; `stmt*`
  functions consume their own tokens. Control flow is the `forStack`
  (`key`, limit, step, pc), `gosubStack` and `whileStack`.
- **Files** — `files: BasFile[4]`: each open file is a whole `text`,
  read on `OPEN` for `INPUT`/`APPEND`, written on `CLOSE`, `END`, an
  error, `basicStop`. (`ponytail:` stream it if someone writes a log.)

Things kept deliberately simple, and when to revisit: three array
dimensions (raise `ArrayInfo` when a program needs more); `numAdd`'s
one-bit rounding loss (add a guard bit if a numeric program shows
drift); keys typed while a game is in character mode are not echoed by
the BBS at all (a per-program `ECHO` setting if someone wants it).

## The BBS wrapper

`games/basic.cla`, included by `bbs.cla` after `motd.cla`:

- The Games menu lists `*.BAS` in the `BASIC` folder next to the app
  (`file.list`, sorted), numbered; `V` or a digit opens the `Game
  number:` prompt (`gamenum`) and the pick runs. Callers with the
  BasicRepl access flag also see `B) BASIC prompt`.
- Screens: `basic` (character mode — keys go to `basicKey`, and
  `echoActive()` is off so `INKEY$` games control what shows) and
  `basicline` (line mode — `INPUT` answers and prompt lines go to
  `basicLine`). `syncBasicScreen` picks one from `basicState` after
  every pump; `displayPrompt` prints nothing for either (the program
  owns the prompt).
- `basicPump()` runs `basicStep(300)` then re-syncs; `bbs.cla`'s
  `every 2 ticks` block pumps while `basicActive` and the state is
  `BRunning`/`BSleeping`, so a compute loop can't freeze the Mac and
  output trickles out at the serial line's pace.
- `^C` on either screen (caught in `inputChar` before line assembly,
  `basicBreakKey`) is `basicBreak()`: "Break in n", then the `Ok`
  prompt for a sysop or the Games menu for a game.
- Hooks: `basicOut` turns CR into `terminal.eol` and goes through
  `sendData` (column tracking, telnet IAC escaping). `basicScreen` emits
  ANSI only when `terminal.ansi` (CLS = clear + home, LOCATE = CUP,
  COLOR = the QBasic 0–15 palette mapped to `Color` via `setColor`/
  `setBackground`), else CLS is `terminal.rows` blank lines and the
  rest is ignored; BEEP is a BEL always. `basicPath` refuses any `:`,
  maps to `:BASIC:name` while a game runs (writes below sysop refused)
  and `:BASIC:<username>:name` at the prompt (folder created on first
  write). `basicEnv` answers `USER`, `ACCESS` (the flag bits as a decimal
  int — `docs/access.md`), `COLUMNS`, `ROWS`.
- `basicWidth = terminal.columns` (the physical width minus one, as
  everywhere in the BBS, so the last column is never written).
- `disconnected()` calls `basicStop()`; `BDone` (program end,
  `SYSTEM`, an error in run-only mode) returns to the Games menu.

To stock the Games folder on the Snow image (Snow stopped):
`hmkdir :BASIC && hcopy -t basic/QBasic-SST0.BAS :BASIC:QBasic-SST0.BAS`.

## The host wrapper

`scripts/basic-host.sh [file.bas]` builds `basic/basic-host.cla` on the
host lane and listens on `$PORT` (default 2345):

```
scripts/basic-host.sh basic/QBasic-SST0.BAS    # run a program
scripts/basic-host.sh                          # the Ok prompt
nc localhost 2345
```

The host lane can't build a program with an `every` block (timers make
it a UI program), so the wrapper pumps to completion inside each
receive and a timed `SLEEP` busy-waits. It doesn't echo (nc/telnet
line mode echo locally), sends CRLF, emits ANSI directly, and maps
file names to the current directory. `INKEY$` only sees keys after
Enter under `nc`.

## Testing

`tests/num-test.cla` pins arithmetic identities, the exact GW-BASIC
`PRINT` strings (` .3333333`, ` 1E+07`, ` 1.234568E+08`, ` 1E-05`…),
parse round trips, and the transcendental functions to 1e-5.
`tests/basic-test.cla` has a `runProgram(src, inputs)` harness (hooks
capture output; `INPUT` answers come from a `|`-separated script; key
waits get `Y`), a `session(lines)` harness for the prompt, and a
seeded scripted game of Super Star Trek asserting it runs to the end
without an error. Manual checks: the host wrapper over `nc`, and Snow
via `scripts/deploy.sh` (2026-08-28: signup → Games → play → prompt →
`SAVE`/`FILES` → `SYSTEM` all verified on the 68k build).

## Not in v1

`CHAIN`/`COMMON`; random-access files (`FIELD`/`GET`/`PUT`);
`PEEK`/`POKE`/`INP`/`OUT`/`CALL`; graphics and sound (all recognized and refused with `Not
supported` so a program fails loudly); the QBasic structured forms.
The tokenizer already accepts unnumbered lines and labels, so block
`IF`, `DO/LOOP`, `SELECT CASE` and `SUB/FUNCTION` are additive when
wanted. `ECHO` control for character-mode games, and a tag-and-run
multi-program library, likewise.
