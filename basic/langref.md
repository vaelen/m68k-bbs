# 68kBBS BASIC — language reference

The BASIC on 68kBBS is a Microsoft-style, line-numbered BASIC in the
GW-BASIC / BASICA family, the dialect the classic "101 BASIC Games"
programs were written in. Programs written for GW-BASIC generally run
unchanged; QBasic programs run if they stick to the line-numbered core
(no `SUB`s, `DO/LOOP`, `SELECT CASE`, or graphics). This page lists
what is here. See "Differences" at the end for what isn't.

## Programs and lines

A program is a sequence of numbered lines, 1–65529:

```
10 PRINT "HELLO"
20 GOTO 10
```

Several statements fit on a line separated by `:`. A line without a
number (in a loaded file) is numbered one past the previous line, and
a `label:` at the start of a line can stand in for a line number in
`GOTO`/`GOSUB`. `REM` or `'` starts a comment to the end of the line.
Keywords and names are case-insensitive; strings keep their case.

Keywords must be separated from names (`TOTAL` and `SCORE` are
variables), except that a keyword may run straight into a line number:
`GOTO10`, `IF X THEN20`, `FOR I=1TO9`.

## Data

**Numbers** are single precision: about nine significant digits,
printed to seven, range about ±3×10³⁸. Literals: `10`, `-3.5`, `.5`,
`1.5E3`, `2D-2`, `&HFF` (hex), `&O17` (octal). There is one numeric
type internally; the suffixes `%` `!` `#` `&` are accepted and make
distinct variables (`A`, `A%` and `A$` are three variables). A value
stored into an `%` variable is rounded to an integer (ties to even) and
must fit in ±32767.

**Strings** hold 0–255 characters. Literals are in double quotes.

**Variables** are letters and digits starting with a letter, up to 40
characters, plus an optional type suffix. `DEFINT A-C`, `DEFSNG`,
`DEFDBL`, `DEFSTR` set the implied type for names starting with those
letters. Unset variables are `0` / `""`.

**Arrays** — `DIM A(8,8)`, `DIM N$(20)`, up to three subscripts, each
from `0` (or `1` after `OPTION BASE 1`) to the given bound. Using an
undimensioned array dimensions it to 10 per subscript. Redimensioning
is a `Duplicate definition` error.

## Operators

Highest first:

| operators | meaning |
|---|---|
| `^` | power |
| `-` (unary) | negation (so `-2^2` is `-4`) |
| `*` `/` | multiply, divide |
| `\` | integer divide |
| `MOD` | remainder |
| `+` `-` | add, subtract (`+` also joins strings) |
| `=` `<>` `<` `>` `<=` `>=` | compare, giving `-1` (true) or `0`; strings compare byte-wise |
| `NOT` | bitwise not |
| `AND` | bitwise and |
| `OR` | bitwise or |
| `XOR` `EQV` `IMP` | bitwise xor, equivalence, implication |

The logical operators round their operands to integers first, so `IF
A AND B` works on truth values and `X AND 7` masks bits.

## Statements

Square brackets mark optional parts.

**Assignment and data**

- `[LET] var = expr` — assign; `LET` is optional.
- `DIM name(bounds)[, ...]` — declare arrays. `OPTION BASE 0|1`.
- `SWAP a, b` — exchange two variables of the same type.
- `DATA item, "item", ...` / `READ var[, var...]` / `RESTORE [line]` —
  constant data read in order; unquoted items are trimmed; `RESTORE`
  goes back to the first `DATA` (or the first at or after `line`).
  Running out is `Out of DATA`.
- `DEF FNname[(param)] = expr` — a one-line function, e.g. `DEF
  FNR(R)=INT(RND*8+1)`; string functions end in `$` (`DEF
  FNA$(S$)=S$+"!"`).
- `DEFINT|DEFSNG|DEFDBL|DEFSTR letter[-letter][, ...]`.
- `MID$(s$, n[, m]) = e$` — replace part of a string in place.
- `CLEAR` — clear all variables and close files.
- `RANDOMIZE [seed]` — reseed `RND`; `RANDOMIZE TIMER` for a fresh
  game each run. Without a seed the clock is used.

**Output**

- `PRINT [items]` (or `?`) — items separated by `;` (no space) or `,`
  (next 14-column zone). Numbers print with a leading space (or `-`)
  and a trailing space; a trailing `;` or `,` suppresses the newline.
  `TAB(n)` moves to column n (1-based; a new line if already past it),
  `SPC(n)` prints n spaces. Output wraps at the screen width.
- `PRINT [#n,] USING fmt$; items[;]` — formatted output. The format
  string is printed literally except for its fields, each of which
  consumes the next item (the format is reused from the start when
  items remain, on the same line):
  - numeric: `#` a digit position, `.` the point, `,` thousands
    separators, a leading `+` prints the sign, a trailing `+` or `-`
    prints it after the number, `**` fills the left with asterisks,
    `$$` puts a `$` before the number, `**$` both, `^^^^` after the
    digits prints in exponent form. A number that doesn't fit is
    printed anyway with a `%` in front. `PRINT USING "$$#,###.##";
    1234.5` prints ` $1,234.50`.
  - string: `!` the first character, `\ \` (a pair of backslashes,
    with spaces between) a fixed-width field of that many characters,
    `&` the whole string.
  - `_` prints the next character literally.
- `WRITE [items]` — comma-separated, strings quoted.
- `CLS` — clear the screen. `LOCATE [row][, col]` — move the cursor.
  `COLOR [fg][, bg]` — set colors (QBasic numbers: 0 black, 1 blue, 2
  green, 3 cyan, 4 red, 5 magenta, 6 brown, 7 white, 8–15 the bright
  versions). These three need an ANSI-capable terminal; on plain ASCII
  `CLS` scrolls the screen clear and the others do nothing.
- `BEEP` — ring the bell. `WIDTH n` — set the line width (20–255).

**Input**

- `INPUT [;] ["prompt" ; | ,] var[, var...]` — read values from the
  caller. The prompt is followed by `? ` (with `;`) or nothing (with
  `,`); with no prompt just `? `. Several variables take comma-separated
  answers; quoted strings may contain commas. A wrong count or a
  non-number for a numeric variable prints `?Redo from start` and asks
  again. An empty answer gives `0` / `""`.
- `LINE INPUT [;] ["prompt";] var$` — the whole line, commas and all.
- `INKEY$` (a function) — the next key typed, or `""` if none. A
  program waiting in a loop on `INKEY$` pauses until a key arrives.
- `SLEEP [seconds]` — wait for a key, or for the seconds to pass or a
  key, whichever first.

**Control**

- `GOTO line` / `GOSUB line` … `RETURN`.
- `IF cond THEN stmts [ELSE stmts]` — everything to the end of the
  line; a bare line number after `THEN`/`ELSE` is a `GOTO`; `IF cond
  GOTO line` also works. `IF`s nest on one line.
- `FOR var = start TO limit [STEP step]` … `NEXT [var[, var...]]` —
  the body runs zero times if `start` is already past `limit`; `NEXT
  I, J` closes two loops.
- `WHILE cond` … `WEND`.
- `ON expr GOTO|GOSUB line, line, ...` — the n-th target; out of range
  falls through.
- `END` — stop and close files. `STOP` — stop with `Break in n`; at the
  prompt `CONT` resumes. `SYSTEM` — leave BASIC. Ctrl-C at the keyboard
  is a `STOP` wherever the program is (running, sleeping, or waiting
  for a key or `INPUT`).

**Error handling**

- `ON ERROR GOTO line` — from then on, an error jumps to `line`
  instead of stopping; `ON ERROR GOTO 0` turns it off again. In the
  handler `ERR` is the error number and `ERL` the line it happened on.
- `RESUME` — run the failing statement again; `RESUME NEXT` — continue
  with the statement after it; `RESUME line` — go to `line`. An error
  inside the handler, or `RESUME` with no error pending, stops the
  program.
- `ERROR n` — raise error `n` (a program's own errors use numbers
  above 76).

**Files** — three sequential files, numbered 1–3, in the folder the
BBS gives you (no paths; `:` is refused). A name without a `.` gets
`.BAS`.

- `OPEN "name" FOR INPUT|OUTPUT|APPEND AS #n`, or the older `OPEN
  "I"|"O"|"A", #n, "name"`.
- `PRINT #n, items` / `WRITE #n, items` — write a line.
- `INPUT #n, var[, ...]` — read comma- or line-delimited items; `LINE
  INPUT #n, var$` — a whole line; `EOF(n)` — true at the end.
- `CLOSE [#n[, #m]]` — close (all, with no list). Output files are
  written when closed, and when the program ends.

**At the `Ok` prompt** (sysops): type a numbered line to add or replace
it (a bare number deletes it), or any statement to run it now.
`LIST [a][-[b]]`, `DELETE a[-b]`, `NEW`, `RUN [line | "file"]`, `CONT`,
`LOAD "file"`, `SAVE "file"`, `FILES`, `SYSTEM`.

## Functions

| function | result |
|---|---|
| `ABS(x)` `SGN(x)` `INT(x)` `FIX(x)` | absolute value, sign, floor, truncate |
| `CINT(x)` `CSNG(x)` `CDBL(x)` | round to integer (±32767); the other two return x |
| `SQR(x)` `EXP(x)` `LOG(x)` | square root, e^x, natural log |
| `SIN(x)` `COS(x)` `TAN(x)` `ATN(x)` | trigonometry in radians |
| `RND[(x)]` | a number in [0, 1): `RND` or `RND(1)` the next, `RND(0)` the last again, `RND(-n)` reseeds |
| `TIMER` | seconds since midnight |
| `LEN(s$)` `ASC(s$)` `CHR$(n)` `VAL(s$)` `STR$(x)` | length, first character's code, character from code, string to number (leading number, else 0), number to string (with the leading space) |
| `LEFT$(s$,n)` `RIGHT$(s$,n)` `MID$(s$,n[,m])` | substrings (positions from 1) |
| `INSTR([n,]s$,t$)` | position of t$ in s$ from n, 0 if absent |
| `SPACE$(n)` `STRING$(n, c$|code)` | n spaces; n copies of a character |
| `UCASE$(s$)` `LCASE$(s$)` `LTRIM$(s$)` `RTRIM$(s$)` | case and trimming |
| `HEX$(n)` `OCT$(n)` | hex and octal digits |
| `INKEY$` | see Input |
| `POS(0)` `CSRLIN` | cursor column and row (from 1) |
| `ENVIRON$("name")` | on the BBS: `USER` (your name), `ACCESS` (your access flags as a number), `COLUMNS`, `ROWS` |
| `EOF(n)` `FRE(x)` | end of file; free memory (a constant) |
| `ERR` `ERL` | the last error's number and line (see Error handling) |

## Errors

`Syntax error`, `Type mismatch`, `Illegal function call`, `Overflow`,
`Division by zero`, `Undefined line number`, `NEXT without FOR`,
`RETURN without GOSUB`, `WEND without WHILE`, `FOR without NEXT`,
`WHILE without WEND`, `Out of DATA`, `Subscript out of range`,
`Duplicate definition`, `String too long`, `Undefined user function`,
`Not supported`, `File not found`, `Bad file number`, `Bad file mode`,
`Bad file name`, `File already open`, `Input past end`, `Path not
found`, `Device I/O error`, `Can't continue`, `RESUME without error`.
Each is reported as `<error> in <line>`; the program stops (back to
`Ok` if it was started from the prompt) unless an `ON ERROR` handler
is armed. Error numbers follow GW-BASIC: 1 NEXT without FOR, 2 Syntax
error, 3 RETURN without GOSUB, 4 Out of DATA, 5 Illegal function call,
6 Overflow, 8 Undefined line number, 9 Subscript out of range, 10
Duplicate definition, 11 Division by zero, 13 Type mismatch, 15 String
too long, 17 Can't continue, 18 Undefined user function, 20 RESUME
without error, 26 FOR without NEXT, 29 WHILE without WEND, 30 WEND
without WHILE, 52 Bad file number, 53 File not found, 54 Bad file
mode, 55 File already open, 57 Device I/O error, 62 Input past end, 64
Bad file name, 73 Not supported, 76 Path not found.

## Differences from GW-BASIC and QBasic

- One numeric type (single precision at nine digits, printed to
  seven); `%`/`!`/`#`/`&` only name distinct variables. Numbers print
  in E notation at 10⁷ and below 10⁻⁴.
- Arrays have at most three dimensions.
- Keywords must be delimited (see Programs and lines).
- `PRINT USING` with `^^^^` always prints one digit before the point.
- Not implemented: `CHAIN`/`COMMON`, random-access files (`FIELD`,
  `GET`, `PUT`),
  `PEEK`/`POKE`/`INP`/`OUT`/`CALL`/`USR`/`DEF SEG`, `LPRINT`/`LLIST`,
  `DATE$`/`TIME$`, and everything graphical or musical (`SCREEN`,
  `PSET`, `LINE (…)`, `CIRCLE`, `PAINT`, `DRAW`, `PLAY`, `SOUND`, …).
  These stop the program with `Not supported`.
- No QBasic structured forms: block `IF … END IF`, `DO … LOOP`,
  `SELECT CASE`, `SUB`/`FUNCTION`, `CONST`, `TYPE`.
- `CLS`/`LOCATE`/`COLOR` depend on the caller's terminal type.
- On the BBS, keys typed while a program is waiting on `INKEY$` are
  not echoed; the program prints what it wants shown.
