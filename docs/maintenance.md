# Daily database maintenance

Once a day, in a configured window, the BBS deletes expired posts and
compacts the append-only body heaps (`BRD<nn>.MSG`, `ARE<nn>.MSG`,
`Mail.MSG`), which never reuse deleted space. The vDB database files
themselves reuse deleted records' pages, so they are compacted only
by hand (`Maintenance > Compact Databases`, below). Inbound echomail
already past a board's expiry is never stored. Modules: `maint.cla`
(both runs) and `heap.cla` (the heap compactor); design:
`docs/superpowers/specs/2026-08-29-maintenance-design.md`, revised by
`docs/superpowers/specs/2026-09-28-maintenance-heaps-only.md`.

## Expiry

Each board has `keepDays` (sysop board card, `E) Expire after`; 0 =
never, the default). A post is expired when `created < now() -
keepDays * 86400` — the post's own date, so for echomail the date it
was written, not when it arrived. Seed a backlog with expiry 0.
`expirePosts` (`postsdb.cla`) walks the board's **Created index**
ascending and stops at the first date past the cutoff — O(expired),
not O(board); a full header scan at the 68k's ~100 ms/record took a
quarter hour on a big echomail board — then `dbDelete`s the collected
IDs. The toss (`ftntoss.cla`) counts an inbound message past the
cutoff as *expired* and drops it before the dupe check, and clamps a
garbage (non-negative) parsed date to receipt time so it can't sort
past every real date and become unexpirable. Threads are ignored: a
reply outlives its starter.

## The window

`Config.txt` `maintenanceHour` (default 4; sysop Configuration menu
`H`). Window start = today's `hour:00:00` Mac local time, or
yesterday's if not yet reached. The run is due when the **Users**
database's `last_compacted` stamp (`dbLastCompacted`) is older than
that (0 = never). The once-a-minute branch of the 30-tick timer starts
it when nothing else is on the line (no caller, no poll); a Mac that
was off at the hour runs at its first idle minute after launch.

## The run

The run is a state machine of one-record units. `bbs.cla`'s 2-tick
timer calls `maintTick`, which runs units until 5 ticks have passed
(`maintTickBudget`) or a unit logs — every `Maint:` line ends the
slice so it paints before more work starts — then returns to the
event loop, so menus and the log window stay live.

It works one item at a time — each board, each file area, then Mail:

```
Maint: Board 2 (Name): Starting
Maint: Board 2 (Name): Deleting - 40% (3/sec)     once a minute
Maint: Board 2 (Name): Checking - 70% (25/sec)    once a minute
Maint: Board 2 (Name): Packing - 62% (9/sec)      once a minute
Maint: Board 2 (Name): Done - 1234 expired
```

1. **Collect** (boards with `keepDays > 0`) — one Created-index key per
   unit, its post IDs read from the scan cursor's leaf copy
   (`btScanValues`, no per-key search), stopping at the first date past
   the cutoff. Its progress line has no percentage (the total isn't
   known until the cutoff is reached): `Collecting - 5513 found, through
   03-14-25` — the date the walk has reached.
2. **Delete** — `maintDeleteBatch` (10) posts per unit in one
   transaction (`dbDeleteMany`: about one disk write per post -- no
   journal entries, index leaves and the free list written once
   per batch). A crash mid-batch leaves the board pending; its next
   open rebuilds the indexes and recounts, and the rest of the batch is
   deleted next run. A failed batch closes the board (logged) and skips
   its packing.
3. **Check** — the heap job's first pass (`heap.cla`, one record per
   unit) sums the live lengths. Less than a quarter orphaned: done.
4. **Pack** (only when the check says so; no line of its own, just the
   minute progress) — copy the live bodies to `.NEW`, swap, fix the offsets
   (progress: copy is 0-50%, fix 50-100%).
5. **Done** — `Done - N expired` for a board (always printed, even when
   nothing was deleted or packed), `Done` for an area and Mail.

After Mail, the Users stamp (`dbStampCompacted`) — the "run finished"
marker the schedule reads. Progress lines give the percentage through
the current step and the records/sec since the last line, to one
decimal place. `Maintenance > Run Database
Maintenance` starts the same run outside the window (the line must be
idle). Failures are logged and the run moves on.

## Manual compaction

`Maintenance > Compact Databases` (line idle, no run in progress)
`dbCompact`s every database file, one per tick: each board's and file
area's headers (`postsCompact`/`filesCompact` — a board first has any
legacy thread starters' threadId 0 rewritten to their own ID,
`postsThreadFix`, so its Thread index stops collecting every starter
under key 0, the overflow chain that made expiry deletes slow), then `Mail`
(`mailCompact`), `Wall`, `Areas`, `Networks`, `Boards`, `Users`. It
reclaims B-tree slack and truncates the `.DAT` files; it never touches
the heaps. The BBS is closed to callers while it runs. `dbCompact`
works in place, so a crash leaves the database pending and its next
open replays the journal and rebuilds the indexes — slow but
recoverable, and the reason it isn't a nightly job. Compacting Users
stamps it, which counts as that day's scheduled run.

While a run is in progress the BBS is **closed**: `connected()` sends
`THE BBS IS CLOSED FOR MAINTENANCE. PLEASE CALL BACK LATER.` and hangs
up (no login-log record). `Maintenance > Toggle Closed to Callers`
sets the same flag by hand — it never disconnects a caller already
online, and the log reports `Closed to callers.` / `Open to callers.`
(Clarus menu items carry no checkmark, and a `(` in a caption would
dim the item -- it is the Menu Manager's disabled-item metacharacter).
`Maintenance > Hang Up` (Cmd-H) drops the line by hand via the paced
`+++`/`ATH` sequence; `Maintenance > Initialize Modem` does the same
hang-up and then sends `Config.txt`'s `modemInit` string — the sequence
that also runs at startup (`modemReset`, called from `modem.opened`).
Every modem command is logged as it goes out (`Hanging Up: ATH`,
`Resetting Modem: <string>`).
`Maintenance > Toggle Log Auto-Scroll` (on by default) is the log
window's follow-newest-line behaviour; turn it off to scroll back
through the log while lines keep arriving. The manual setting survives a
run: the run saves it, closes, and restores it. FidoNet polls wait for
the run (`ftnSchedule`/`ftnNext` check `maintaining`).

## Compacting a board on the host

A big board's compaction freezes the Mac for hours, so it can be done
on the host instead: the vDB and heap formats are the same on both
lanes. With the BBS **not running**, copy the board's files
(`BRDnn.DAT`, `.IDX`, `.JNL`, `.I00`-`.I02`, `.MSG`) into a `Boards`
folder inside an empty directory DIR, then

    scripts/boardtool.sh DIR BOARD [KEEPDAYS]

It expires posts older than KEEPDAYS (if given), runs `postsCompact`
(legacy thread starters rewritten, headers compacted, indexes
rebuilt), packs the heap whatever its waste (`heapForce`), and logs
sizes as it goes. Copy the files back over the originals (type and
creator don't matter; the app opens them by name). From a disk image,
with hfsutils: `hcopy -r ":Boards:BRD13.DAT" DIR/Boards/` out and
`hcopy -r DIR/Boards/BRD13.DAT :Boards:` back, image unmounted from the
emulator.

## Heap compaction and recovery

`heap.cla` rewrites a heap into `<name>.NEW` in record-ID order (a
body's new offset is the running total of the live bodies before it),
renames `.MSG` → `.OLD` and `.NEW` → `.MSG`, rewrites the headers'
offsets, deletes `.OLD`. The offset fix walks the primary index and
writes each changed offset in place (`dbSetFieldIntAt`: no journal, no
index work — the offset fields are unindexed); `.OLD` is the "fix
incomplete" marker, deleted only after the data file is flushed, so a
crash anywhere in the fix is redone in full at the next open. The job
is stepped (`heapBegin`/`heapUnit`, one record per unit) with a
single global primary-index cursor across units — safe only because
nothing writes the index while maintenance holds the databases. A
heap under the waste threshold is skipped without a copy. The rewrite needs the
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

## Note: the index rebuild and B-tree overflow

Compaction rebuilds every secondary index strictly (one `btInsert` per
record). A board's Thread index keys on `threadId`, and `0` marks every
thread-starter, so that one key can hold hundreds of values. Before
B-tree overflow pages existed a key was capped at ~123 values and the
rebuild failed once a board passed that many starters (leaving it
`pending`); overflow pages (`btree.cla`, `docs/vdb-clarus.md`) removed
the cap. A board left `pending` by an old build recovers on next open --
`dbOpen` replays and rebuilds the indexes, now successfully.

## Measured

Before the 2026-09-28 split (these runs included `dbCompact`).
Mac II (Snow), 2026-08-29, the seeded test image: board 1 (20 posts,
6K heap, nothing to reclaim) 15 s; board 2 (10 live posts after 30
expired and 5 deleted, heap 11K -> 2K) 9 s; the small fixed databases
about 1 s each. The time is `dbCompact`'s index rebuilds (one
`btInsert` per record per index) plus any journal replay left by an
earlier interrupted run, not the heap copy. Heap use is flat across a
run (1115K -> 1113K free). A 1,000-post board will take minutes;
bulk-loading the rebuilt B-trees is the optimization if that ever
matters.
