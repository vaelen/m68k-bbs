# Guestbook

Short, timestamped shoutouts from callers — "hi everyone", "thanks for
the ZMODEM tip" — shown to every caller right after login and on demand
from the main menu. Storage is `guestbookdb.cla` (a vDB database,
`docs/vdb-clarus.md` for the engine); the screens are `guestbook.cla`;
the login-flow glue is in `bbs.cla`. Pre-v1: no backward compatibility
is promised for the record format.

## What the caller sees

After the terminal type is chosen, the login chain runs once:

```
Welcome back, andrew!            (a new account: "Welcome, andrew!")
Last on: 08-27-26 16:16:02
Press any key to continue...

+---------------------------------------------------------------------------+
|                                 Guestbook                                 |
+-------------------+------------------+------------------------------------+
| Date              | Name             | Message                            |
+-------------------+------------------+------------------------------------+
| 08-27-26 17:40:11 | andrew           | Hello from the e2e run, shoutout   |
|                   |                  | to Alice                           |
+-------------------+------------------+------------------------------------+
| 08-27-26 17:12:03 | bob              | first!                             |
+-------------------+------------------+------------------------------------+
Add a guestbook entry? (Y/[N])
Your entry (120 chars max): _
```

then the Message of the Day (`docs/motd.md`), the new-message and
pending-file counts, and the main menu. Main-menu `G) Guestbook` shows
the same table and question and returns to the menu.

- The newest **20** entries (`gbRecent`), newest first.
- The message cell wraps inside the column and the row grows to fit;
  a joint rule separates entries.
- Wide terminals (79 columns): Date · Name · Message, content widths
  17 · 16 · 34. Narrow (39): Who · Message, 12 · 20, with the name on
  the first row of the first cell and the date (`mm-dd-yy`, no time)
  on the second.
- Paging: the drawer counts the lines it has sent; when the count
  reaches `terminal.rows - 2` it stops and asks `Display More?
  (Y/[N])`. `Y` continues from the next row of the same entry; any
  other key closes the table (bottom rule) and asks about a new entry.
- `Add a guestbook entry? (Y/[N])`: `Y` opens a single-line prompt.
  Empty input cancels ("No entry added."); more than 120 characters
  is refused with `Entries are limited to 120 characters.` and the
  prompt repeats; otherwise the entry is stored under the caller's
  username and stamped `now()`.

Anyone logged in may add an entry; there is no per-login limit and no
delete UI yet (the sysop can delete records with a host-lane vDB
program, or remove the `Guestbook.*` files to start over).

## Storage

One database, `Guestbook.DAT` / `Guestbook.IDX` / `Guestbook.JNL`,
160-byte records, no secondary indexes. The vDB record ID is the entry
ID.

| Offset | Size | Field |
| ------ | ---- | ----- |
| 0   | 32  | name — Pascal string (length byte + ≤31 chars) |
| 32  | 4   | created — Mac-epoch seconds, big-endian (`now()`) |
| 36  | 121 | message — Pascal string (length byte + ≤120 chars, `gbMessageMax`) |
| 157 | 3   | slack |

Record IDs are assigned in increasing order and never reused, so
"newest first" is a walk from `dbNextRecordId - 1` downward, skipping
deleted IDs (`recentGuestbookIds(n, ids)`), the same walk the post
list uses — no timestamp index needed. The message is read with
`text.stringAt` rather than `dbExtractString`, which only handles the
≤63-byte fields used as index keys.

## API (`guestbookdb.cla`)

- `guestbookOpen(): bool` / `guestbookClose()` — opened at `App.launch`
  with the other databases, closed at quit.
- `guestbookCount(): int`
- `addGuestbookEntry(name, msg): int` — new ID or -1 (`lastError`);
  name and message are truncated to their fields.
- `loadGuestbookEntry(id): bool` — fills `gbName`, `gbCreated`,
  `gbMessage`.
- `recentGuestbookIds(n, ids)` — the newest `n` IDs, newest first.

`tests/guestbookdb-test.cla` covers add/load, the 120-char cap, and
newest-first order across a deleted record.

## Screens (`guestbook.cla`, dispatched by `bbs.cla`)

| Screen | Mode | Prompt | Keys |
| ------ | ---- | ------ | ---- |
| `gbmore` | hotkey | `Display More? (Y/[N]) ` | `Y` continue, else close |
| `gbask` | hotkey | `Add a guestbook entry? (Y/[N]) ` | `Y` prompt, else move on |
| `gbentry` | line | `Your entry (120 chars max): ` | text; empty cancels |

`startGuestbook()` draws the header and starts `drawGuestbook()`, which
keeps its resume point in `gbIndex` (entry) and `gbRow` (row within
it) and the line count in `gbLines`. `guestbookDone()` goes back to
the main menu when `gbFromMenu` is set (main-menu `G`), otherwise on
to `postLoginMotd()` in bbs.cla.
