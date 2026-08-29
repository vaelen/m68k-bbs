# Daily database maintenance

Once a day, in a configured window, the BBS deletes expired posts and
compacts every database — headers, indexes and the append-only body
heaps. Inbound echomail already past a board's expiry is never stored.
Modules: `maint.cla` (the run) and `heap.cla` (the heap compactor);
design: `docs/superpowers/specs/2026-08-29-maintenance-design.md`.

## Expiry

Each board has `keepDays` (sysop board card, `E) Expire after`; 0 =
never, the default). A post is expired when `created < now() -
keepDays * 86400` — the post's own date, so for echomail the date it
was written, not when it arrived. Seed a backlog with expiry 0.
`expirePosts` (`postsdb.cla`) walks the board's dense ID range and
`dbDelete`s expired headers; the toss (`ftntoss.cla`) counts an
inbound message past the cutoff as *expired* and drops it before the
dupe check. Threads are ignored: a reply outlives its starter.

## The window

`Config.txt` `maintenanceHour` (default 4; sysop Configuration menu
`H`). Window start = today's `hour:00:00` Mac local time, or
yesterday's if not yet reached. The run is due when the **Users**
database's `last_compacted` stamp (`dbLastCompacted`) is older than
that (0 = never). The once-a-minute branch of the 30-tick timer starts
it when nothing else is on the line (no caller, no poll); a Mac that
was off at the hour runs at its first idle minute after launch.

## The run

One unit per timer firing: expire one board; compact one board
(`postsCompact`: `dbCompact` then `heapCompact`); compact one file
area (`filesCompact`); then `Mail` (`mailCompact`), `Wall`, `Areas`,
`Networks`, `Boards`, `Users` — Users last, so its stamp means
"finished". A scheduled run skips a database already stamped since the
window opened, so an interrupted run resumes where it stopped;
`Maintenance > Run Database Maintenance` forces every database (it
still needs the line idle to start). Each unit logs one line with
before/after sizes; a failing unit is logged and the run continues.

While a run is in progress the BBS is **closed**: `connected()` sends
`THE BBS IS CLOSED FOR MAINTENANCE. PLEASE CALL BACK LATER.` and hangs
up (no login-log record). `Maintenance > Toggle Closed to Callers`
sets the same flag by hand — it never disconnects a caller already
online, and the log reports `Closed to callers.` / `Open to callers.`
(Clarus menu items carry no checkmark, and a `(` in a caption would
dim the item -- it is the Menu Manager's disabled-item metacharacter).
The manual setting survives a
run: the run saves it, closes, and restores it. FidoNet polls wait for
the run (`ftnSchedule`/`ftnNext` check `maintaining`).

## Heap compaction and recovery

`heap.cla` rewrites a heap into `<name>.NEW` in record-ID order (a
body's new offset is the running total of the live bodies before it),
renames `.MSG` → `.OLD` and `.NEW` → `.MSG`, rewrites the headers'
offsets (journaled `dbUpdate`), deletes `.OLD`. A clean heap (live
bytes == file size) is skipped without a copy. The rewrite needs the
heap's size in free disk while it runs; a write failure deletes `.NEW`
and leaves the old heap untouched. On every open, `heapRecover`
finishes whatever a crash interrupted:

| on disk | crashed | action |
|---|---|---|
| `.NEW` only | mid-rewrite | delete `.NEW` |
| `.OLD` + `.NEW`, no `.MSG` | between the renames | `.NEW` → `.MSG`, then fix offsets, delete `.OLD` |
| `.OLD` + `.MSG` | fixing offsets | fix offsets, delete `.OLD` |

Both actions are idempotent: the offsets are a pure function of header
order and lengths. `tests/heap-test.cla` stages each state;
`tests/maint-test.cla` steps a whole run by hand on the host.
