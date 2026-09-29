# Daily Word

A Wordle-style daily puzzle with leaderboards, and the first **built-in
Clarus game** (stage 1 of `docs/games.md`). Every caller gets the same
five-letter word each day and has six guesses. Results feed a
per-player stats record and two leaderboards. Status: implemented
2026-09-29 (host-lane tested; not yet played in Snow).

Why this game: it's turn-based, so it works over any line speed and on
every terminal type (ANSI, VT100, ASCII, PETSCII, 40 or 80 columns).
It needs no cursor addressing, gives callers a reason to call once a
day, and the leaderboard lets them compete across calls on a
single-line BBS.

## Pieces

| file                     | what                                                                                     |
|--------------------------|------------------------------------------------------------------------------------------|
| `games/wordslib.cla`     | the pure parts: scoring, day number, word files, stats record, ranking, letter rendering |
| `games/words.cla`        | the screens: guess prompt, board, personal stats, leaderboard tables                     |
| `tests/words-test.cla`   | host-lane tests for `wordslib.cla`                                                       |
| `scripts/wordlist.py`    | generator: `~/repos/cinquel/words.c` → `Words/Words.txt` + `Words/Answers.txt` (committed) |
| `usersdb.cla`            | `userNameById`: a leaderboard name without `loadUser` overwriting the session user        |
| `gamesdb.cla`            | new `GameType` member `Builtin` (byte 7, appended)                                       |
| `games/basic.cla`        | `gameNumberInput` gets a `Builtin` case that dispatches on `game.filename`               |
| `sysop.cla`              | the New Game wizard / edit card type prompt accepts `I` (Built-in) as well as `B`        |
| `config.cla`             | new key `wordsDayOne` (default `2026-10-01`), the date of puzzle #1                      |

### Registering built-in games

A built-in game is a Games-database row of type `Builtin` whose
`filename` names the module, e.g. `words`. `gameNumberInput` switches on
it:

```
case Builtin {
    switch game.filename {
    case "words" { wordsStart(game.id) }
    else        { sendLine("No such built-in game."); gotoScreen("games") }
    }
}
```

The sysop adds it through the usual wizard (name "Daily Word", type
`I`, file `words`), so it can be renamed, reordered or disabled like any
other game. `Native` stays reserved for `:Externals:` code resources
as `docs/games.md` plans. Any later built-in game adds one `case` here.

## Word lists

No list is ever loaded into RAM. Both are TEXT files in a `:Words:`
folder next to the app, with fixed **6-byte lines** (five lowercase
letters + CR). They stay hand-editable in any Mac text editor, and
record *n* sits at byte `6 * n`.

| file          | contents                                           | size    |
|---------------|----------------------------------------------------|---------|
| `Words.txt`   | every accepted guess, **sorted**                   | ~34 KB  |
| `Answers.txt` | the answer sequence, **shuffled once**, one per day | ~12 KB  |

- **Source:** cinquel's `words.c`, i.e. the Stanford GraphBase list
  (5,757 words, ordered by how common each word is).
- **Answers:** the first ~2,000 of that order, minus plurals and
  third-person `-s` forms (heuristic: drop words ending in `s` unless
  they end in `ss`, `us` or `is`; review the output by hand). They're
  shuffled with a fixed seed and written out. The generator also
  merges every answer into `Words.txt`, so an answer is always a valid
  guess.
- **Guess check:** binary search `Words.txt` with `filehandle.readAt`:
  about 13 six-byte reads, roughly 80 ms on the SE.
- **Today's answer:** one `readAt` at `6 * ((day - 1) mod count)`.
  2,000 answers last about 5½ years before the cycle repeats.
- **Sanity check at game start:** each file's size must be a nonzero
  multiple of 6. If not, log it and say "Daily Word is not set up."

`wordlist.py` writes both files; they're copied onto the image with
`hcopy` like any other data file (see `docs/snow-hdd-howto.md`). They
aren't generated at build time: the sysop owns them once installed.

## Day number

Puzzle #1's date lives in `Config.txt` as `wordsDayOne=2026-10-01`
(`config.wordsDayOne: string`, default `"2026-10-01"`; set it by
editing `Config.txt`, since the Sysop Config menu doesn't expose it). A
test instance can move it back to get a running game today.

The day number never goes through Mac-epoch seconds. Both dates become
a plain day count with a pure days-from-civil function (the standard
era/day-of-era formula, all small positive ints), and the difference
is the puzzle number:

```
func civilDays(y: int, m: int, d: int): int      // days since 1970-01-01
func wordsDay(): int                             // today - dayOne + 1
```

"Today" comes from `dateTimeStr(now())` (`mm-dd-yy`, local time, so
it rolls over at local midnight; the year is `2000 + yy`). The config
value is parsed as `yyyy-mm-dd`. It works the same on both lanes, needs
no Toolbox date calls and sidesteps `now()` being negative. A value
`wordsIsoDays` can't parse (or missing/mangled word files) logs a
line and the game says "Daily Word is not set up." `Config.txt` only
checks the `dddd-dd-dd` shape when it loads.

- `wordsDay() < 1` → "Daily Word starts on 2026-10-01." and back to
  the menu.
- The number doubles as the puzzle number ("Daily Word #29"). 0 is
  free as the "never played" value in the stats record.
- Moving `wordsDayOne` after launch renumbers every puzzle and the
  stats records' `day`s no longer match. That's harmless (at worst a
  streak breaks), but it's documented as "set it once".

A caller who starts before midnight keeps playing that day's word; the
day is fixed in the record when the game starts.

## Scoring a guess

`wordScore(guess, answer: string): string` is pure and returns five
marks: `G` right spot, `Y` in the word elsewhere, `.` not in the word.
It handles duplicates the standard way, in two passes:

1. Mark every exact match `G` and remove that letter from a per-letter
   count of the answer's unmatched letters.
2. Left to right over the rest: `Y` if the letter's remaining count is
   above 0 (then decrement it), else `.`.

So with answer `ABBEY`, guess `BABES` → `YYGG.` and guess `BBBBB`
→ `.GG..`. These cases go into `tests/words-test.cla`.

## Screens

All are ordinary `user.screen` states driven by `processInput`, like
every other screen.

1. **`wordsStart(gameId)`** loads the caller's stats record (below):
   - finished today → redraw the board, show their result, then the
     leaderboards;
   - in progress today → redraw the guesses so far, then continue;
   - otherwise → start a fresh game for today and save it right away.

   Then it draws `sendTitleBox("Daily Word #" + intStr(day))` and, on
   a first game, a three-line legend.
2. **`wordguess`** (line mode): prompt `Guess 3/6: `. Input is
   trimmed and case-folded.
   - Empty Enter → leave; progress is kept.
   - Not five letters → "Five letters, please."
   - Not in `Words.txt` → "Not in the word list."

   Neither error uses up a guess. A valid guess is scored, **written to
   the stats record before anything is drawn**, then drawn. Hanging up
   mid-game can't reset a puzzle, since the record is on disk and the
   next call resumes.
3. **End** (a win, or the sixth miss, which reveals the word): update
   the stats, show the caller's own line and distribution, `showPause`,
   then the leaderboards, `showPause`, then back to the `games` menu.

### Drawing a guess row

Letters are spaced (`C R A N E`), and each row is followed by an
alphabet line (`A B C . E ...`) with ruled-out letters shown as `.`:

| terminal                  | right spot                            | elsewhere                              | not in word          |
|---------------------------|---------------------------------------|----------------------------------------|----------------------|
| ANSI/VT100 color          | `bg(Green)` + `fg(Black)`, bold        | `bg(Yellow)` + `fg(Black)`             | `bg(BrightBlack)`     |
| PETSCII color             | `reverseVideo(true)` + `fg(Green)`     | `reverseVideo(true)` + `fg(Yellow)`     | `fg(BrightBlack)`     |
| everything without color  | marker row under the guess: `^`       | `?`                                    | `.`                  |

A monochrome row looks like this:

```
  C R A N E
  ^ ? . . ^
```

Every color path also works with `terminal.color` off, because the
helpers return `""`; the marker row is sent exactly when
`not terminal.color`. That covers mono ANSI, VT100 mono, ASCII and
VT52 with one branch. Everything fits in 40 columns: a guess row is
11 characters and the alphabet line 51, which wraps as two 13-letter
lines on narrow terminals (`terminal.columns < minimumWideTerminalWidth`).

### Personal stats after a game

```
Played 23  Win% 87  Streak 4  Best 9
1 |                     0
2 | ##                  2
3 | ########            8
4 | ######              6   <- today
5 | ###                 3
6 | #                   1
```

Bars are scaled to fit the terminal width, and the `today` marker is
dropped on narrow terminals.

## Stats file

One shared file, `_stats`, resolved through `gameDataPath(gameId, 0,
"_stats", ...)` in `:GameData:<gameId>:`, so it follows the sandbox
rules and survives a game rename. It's **sparse**: a retro BBS has
many accounts and few players, so only players get a record. Records
are 64 bytes, each starting with its owner's user ID, in the order
people first played. 100 players = 6.4 KB.

- **Find:** at game start, one linear scan in 4 KB `readAt` chunks,
  matching on `userId`. The record's byte offset is kept for the
  session (`wordsRecAt`), so every later update is a single
  `writeAt` with no rescan.
- **New player:** nothing found → the record is appended at
  `f.size()` when they make their first guess, not when they open the
  game. Someone who only looks at the leaderboard never gets one.
- **Never removed.** A deleted user's record stays, and the
  leaderboards skip IDs `loadUser` can't find. vDB IDs are never
  reused, so a new account can't inherit it. If it ever matters, a
  compaction pass could drop dead records; not planned.

Big-endian, written with the same `text` accessors the vDB records use:

| offset | size  | field                                                                  |
|--------|-------|------------------------------------------------------------------------|
| 0      | i32   | `userId`                                                               |
| 4      | i16   | `day` — the puzzle this record's game is for (0 = none yet)            |
| 6      | byte  | `state` — 0 none, 1 playing, 2 won, 3 lost                             |
| 7      | byte  | `used` — guesses made                                                  |
| 8      | 30    | guesses, 6 × 5 letters                                                 |
| 38     | i32   | `finishedAt` — `now()` when won/lost; today's tie-break                |
| 42     | i16   | `played`                                                               |
| 44     | i16   | `wins`                                                                 |
| 46     | i16   | `streak` — stored; see "live streak"                                   |
| 48     | i16   | `best`                                                                 |
| 50     | i16   | `lastWinDay` (0 = never)                                               |
| 52     | 6×i16 | distribution: wins in 1..6 guesses                                     |

Day numbers fit an i16 for 89 years. `finishedAt` is only ever
compared between two same-day values, which the language reference
says orders correctly.

On a win on day `d`: `streak = streak + 1` if `lastWinDay == d - 1`,
else `1`; `best = max(best, streak)`; `lastWinDay = d`. A loss sets
`streak = 0`. **Live streak**, used everywhere it's displayed:
`streak` if `lastWinDay >= today - 1`, else 0. A skipped day breaks
the streak without anyone having to write the record.

## Leaderboards

Built by one pass over `_stats` in 4 KB `readAt` chunks, keeping the
top 10 of each board by insertion (O(players), with RAM bounded by the
chunk). Names come from `loadUser(id)` for the ≤20 winners only. Both
are drawn with the existing table senders (`sendTableHeader`/
`rowLine`/`sendTableFooter`, `docs/tables.md`).

| board                 | who                                      | ranked by                         | wide columns                        | narrow columns   |
|-----------------------|------------------------------------------|-----------------------------------|-------------------------------------|------------------|
| **Today #N**          | winners of today's puzzle                | guesses, then `finishedAt`        | # · Name · Guesses                  | Name · Guesses   |
| **Streaks**           | anyone with a live streak or a `best`    | live streak, then best, then wins | # · Name · Streak · Best · Played · Win% | Name · Streak |

The caller's own row is highlighted with `bold(true)` / `reverseVideo`
when it appears. If it doesn't, one extra line underneath gives their
rank (`You: #14, streak 2`). The Today board only lists winners, and
the answer is never shown to someone who hasn't finished today.

Picking the game again after finishing today goes straight to the
finished board and the leaderboards; that is the only way to see them.

## Edge cases

- **Two sessions at once:** single line, so there's no concurrent
  writer. The file isn't journaled; a crash mid-write loses at most
  one caller's record, and records never move once written. A torn
  append is handled by sizing everything as `size / 64` whole records:
  the scan ignores a partial tail and the next append overwrites it.
- **Word files edited mid-cycle:** changing `Answers.txt` changes
  today's word for anyone who hasn't finished. Guesses are replayed
  from the record against the new answer when drawn. Documented for
  the sysop, not guarded.
- **Disconnect mid-game:** nothing to do; `disconnected()` needs no
  hook, since every guess is already on disk.
- **Idle hang-up** works as on any screen.
- **Capitals-only / XMODEM text rules** don't apply; the game runs
  after terminal selection and never precedes a transfer.

## Out of scope (add if asked)

- Hard mode (revealed hints must be reused).
- A main-menu teaser line ("Today's word: 4 solvers so far").
- Posting the day's results to the wall or a board.
- Letting callers view past puzzles.
- Answer lists in other languages (the files would just need
  different contents).

## Build order

1. `scripts/wordlist.py` → both files; eyeball `Answers.txt`.
2. `wordScore`, `civilDays`/`wordsIsoDays`/`wordsStampDays`,
   `wordsFind` (binary search) + `tests/words-test.cla`.
3. The sparse stats file (scan, append, update in place), then
   leaderboard ranking and letter rendering, all in `wordslib.cla`.
4. `GameType.Builtin`, the dispatch case, the wizard's `I`,
   `userNameById`.
5. The screens (`games/words.cla`). `bbs.cla` can't be built on the
   host lane, so they're checked by the 68k build.
6. Deploy to Snow, clean databases per CLAUDE.md, set `wordsDayOne`
   to a past date, and play a few days by moving the Mac clock
   forward (the streak and day rollover are the parts worth watching).
