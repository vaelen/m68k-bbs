# vDB scan cursors, header cache, and list-screen conversion

Design spec, 2026-09-01. Status: approved in brainstorming, not yet
planned.

## Goal

Listing screens are slow on the SE because every record enumeration is
an ID-probe loop: for each candidate ID, `dbFind` re-reads the vDB
header from disk, descends the B-tree from the root, and reads the
record page — 3–4 File Manager calls per ID, misses included. The
worst case is `drawPostList`, which draws page N by probing every ID
from the newest down (page 5 of a 500-post board is 200+ full
`dbFind`s, redone on every page turn). Three fixes, together:

1. A **scan cursor** over the primary index: seek once, then walk
   leaf-sequentially, ~50 entries per 512-byte page read.
2. A **header cache**, so `dbFind`/`dbNextRecordId`/`dbRecordCount`
   stop re-reading the header page on every call.
3. A **network-name memo** in the board picker, collapsing N identical
   `loadNetwork` lookups per draw to one per network.

Every ID-probe enumeration converts to the cursor (caller screens,
sysop lists, toss/maintenance machinery). Screen behavior, prompts,
and list numbering are unchanged — this is a read-path swap only.

Out of scope: mail-inbox enumeration (secondary-index path via
`dbFindAllByInt`; it gets the header cache only), raising the 9600
serial rate (a wide table still costs ~1 s of line time), on-disk
format changes of any kind.

## Decisions

- **Transient cursors, persistent positions.** A cursor lives only
  inside one screen draw or one toss/maintenance slice; it never
  spans an input event. What persists between keystrokes is what
  persists today: a page number or boundary ID (`listFromId`,
  `postPage`). Each draw re-seeks against current reality, so cursor
  invalidation (toss inserted posts, sysop deleted one, compact
  rewrote the file) cannot arise. Re-seeking costs ~1 leaf read per
  50 entries skipped.
- **No `prev_leaf`, no format change.** Leaves are forward-linked
  only; descending walks (post lists are newest-first) step backward
  using the descent `path` btDescend already returns: re-read the
  parent, take the previous child; at a first child, go up a level
  and descend the rightmost spine. Same read cost as a back-link,
  no version bump, no migration, no split-code burden.
- **Cursor is an opaque `text` blob owned by the caller.** Clarus
  records pass by value with immutable parameters, so a
  `cur = next(cur)` API is off the table; `text` passes by reference
  and callee-fills-the-text is the language's out-param idiom. Blob
  layout is private to btree.cla. Caller-owned (not a vdb global)
  because `boardsBackfillLastPost` genuinely nests two live scans
  (Boards ascending × per-board posts descending).
- **No writes to a tree while a scan on it is live.** Handlers are
  single-threaded, so this only constrains a single call chain:
  mutators (expiry, deletes) collect IDs from a scan first, close it,
  then act. Documented on the API.
- **Header cache is a module map, not a `Database` field.** Records
  copy by value; a non-empty `text` field aliases across copies, but
  whether an *empty* one does before its buffer is materialized is
  unverified. A `map of string to text` keyed by `db.name` is
  unambiguous and changes no record shape.

## 1. B-tree scan primitives (btree.cla)

New functions; btree.cla stays standalone and vDB-agnostic.

- `btScanStart(f: filehandle, cur: text, fromKey: int,
  descending: bool): bool` — one `btDescend` for `fromKey`, then
  position at the smallest entry ≥ fromKey (ascending) or the largest
  ≤ fromKey (descending). Landing on an empty leaf, or past the last
  qualifying entry, steps immediately. False = nothing to scan or I/O
  error.
- `btScanNext(f: filehandle, cur: text): bool` — advance one entry;
  false when exhausted (sticky: further calls stay false).
- `btScanKey(cur: text): int` / `btScanValue(cur: text): int` — read
  the current entry's key and first value out of the blob (one return
  value per function; accessors instead of out-params). The primary
  index holds one value per key (the record's first page), so only
  the first value is exposed; overflow chains are not walked.

Cursor blob (private layout): direction byte, done flag, current leaf
page number, current entry index, the descent path page numbers
(≤ `btMaxDepth`), and a 512-byte snapshot of the current leaf.

Stepping:

- **Ascending**: next entry in the snapshot; at leaf end follow
  `next_leaf` (1 read); empty leaves skipped in a loop; `next_leaf`
  0 = done.
- **Descending**: previous entry in the snapshot. Entries are
  variable-size, so stepping back rescans offsets from the leaf head —
  ≤ ~50 tiny in-memory iterations per step (O(n²) per leaf; noted
  ceiling, cache the offsets if it ever shows on the SE). At the
  leaf's first entry, the predecessor walk: re-read the parent page
  from the path, take the child pointer before this one; at a
  parent's first child, go up a level; then descend the rightmost
  spine of the sibling subtree, updating the path. At the root's
  first child = done. ~1–3 reads per ~50 entries.
- Re-reading path pages is safe because scans are transient and
  handlers are single-threaded — no split can happen mid-scan.

## 2. vDB scan API (vdb.cla)

- `dbScanStart(db: Database, cur: text, fromId: int,
  descending: bool): bool`
- `dbScanNext(db: Database, cur: text, rec: text): int` — advance,
  read the record's pages via the entry's value (first page), fill
  `rec`, return the ID; 0 when exhausted. A record that fails to read
  is logged and skipped, not fatal.
- `dbScanSkip(db: Database, cur: text, n: int): int` — skip n live
  index entries without touching record pages; returns the number
  actually skipped. This is the page-positioning tool: "page 7" =
  seek newest + skip 6×rows (~1 read per 50) + read one screenful of
  records.

Conventions: ascending from 1 = full scan oldest-first; descending
from `dbNextRecordId(db) − 1` = newest-first. "Page X of Y" totals
come from `dbRecordCount` (header field, cached). Callers that filter
rows while positioning (the file list hides `pending` from
non-sysops) cannot use `dbScanSkip`; they skip via `dbScanNext` and
pay one record read per skipped entry — still ~4× cheaper than
today's `dbFind` probe.

## 3. Header cache (vdb.cla)

Module-level `map of string to text` keyed by `db.name`.

- `dbReadHeader` returns a **copy** of the cached bytes on a hit
  (assignment would alias and callers mutate their `hdr` before
  committing); fills the cache on a miss.
- Refresh: `dbCommit` and `dbSetPending` store the bytes they just
  wrote. Clear: `dbRollback`, `dbClose`, compaction, journal
  recovery; `dbOpen` clears then seeds.
- Implementation is one store helper and one clear helper called from
  every site that writes the header page; the work includes an audit
  of vdb.cla for any direct `writeAt(0, …)` that would bypass them.

## 4. Network-name memo (boards.cla)

Local to `drawBoardPicker`: parallel `list of int` / `list of string`
(netId → name), cleared per draw, consulted before `loadNetwork`.
Nothing else needs it.

## 5. Conversions

| Caller | Today | After |
|---|---|---|
| `drawPostList` | probe every ID newest-down per draw | seek newest desc, `dbScanSkip((page−1)×rows)`, emit a screenful |
| `drawBoardPicker`, area picker, games menu | probe 1..nextId | ascending scan |
| File list | probe descending | descending scan, manual skip via `dbScanNext` (pending filter) |
| Wall `recentWallIds` | probe descending | descending scan, n entries |
| Sysop paged lists (`listFromId`) | probe ascending from cursor | ascending scan from `listFromId`; `nextLiveId` deleted |
| Toss `scanBoard`, `expirePosts`, maintenance | probe from mark, one unit per tick | transient scan per tick/slice; mutators collect IDs first, then delete |
| `boardsBackfillLastPost` | probe boards × probe posts down | ascending Boards scan × one-step descending posts scan (two live cursors) |

Mail inbox keeps `dbFindAllByInt` + per-ID `dbFind` (header cache
applies).

## 6. Testing

- **btree scan suite**: ascending/descending full scans; seeds
  mid-range and on deleted keys; holes from deletion; a
  fully-emptied leaf mid-chain; multi-level trees (enough inserts to
  split twice); descending across leaf and parent boundaries;
  `dbScanSkip` counts; scan on an empty tree; scan-after-exhaustion
  stays done.
- **Header cache**: read-after-commit sees committed bytes,
  read-after-rollback sees pre-transaction bytes, reopen invalidates.
- **Existing suites** (`scripts/test.sh`) pass untouched — the
  conversions change no observable output.
- **On the SE**: before/after `TickCount` log lines around
  `drawPostList` and `drawBoardPicker` for one release, so the win is
  measured rather than assumed. Baseline, measured on production
  2026-09-01 (~15 boards, 1 network, ANSI 80×24): board picker 396
  ticks (~6.6 s), post list page 347 ticks (~5.8 s). The 9600-baud
  line time for one such table is ~90 ticks, so ~¾ of the wait is
  DB reads; target ~120–150 ticks per draw.
