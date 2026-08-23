# vDB v2: Changes Over the C Implementation

What the Clarus implementation (`btree.cla`, `vdb.cla`, format spec in
`docs/vdb-clarus.md`) does differently from libvdb (`~/repos/libvdb`),
written down so the improvements can be folded back into the C
library. Sections are ordered by how much they matter to C: outright
bugs first, then design gaps the C library never closed, then format
and platform choices that are Clarus-specific and probably should NOT
be copied.

## 1. Bugs in the C implementation (fix these regardless)

### 1.1 Journal replay corrupts multi-page records

`ReplayJournal` (db.c) replays every `JO_UPDATE`/`JO_ADD` entry with
`page.status = PS_ACTIVE` — including entries for continuation pages,
which must be `PS_CONTINUATION`. After a replay of a multi-page
record, every page of it reads as the first page of a record;
`ReadRecord`'s status checks then reject the record, and the index
rebuild (which trusts `PS_ACTIVE`) indexes each continuation page as
its own record with garbage content.

**v2 fix:** the journal entry's data field is 507 bytes but a page
only holds 506 — v2 uses that last byte (entry offset 515) to record
the page's status. The journal writer sets it (`PS_ACTIVE` for the
first page of a record, `PS_CONTINUATION` for the rest) and replay
restores it verbatim. One byte that was already there, zero format
growth. (C: set `entry.data[506]` when journaling, use it in the
replay `switch`.)

### 1.2 Freed multi-page runs are never reused

`FreePages` (db.c) adds only the run's *first* page number to
`free_pages` ("subsequent pages can be calculated"), but
`FindConsecutiveFreePages` searches for runs as **adjacent array
entries with consecutive page numbers**. Nothing ever calculates the
subsequent pages, so for any `pages_per_record > 1` the free list can
never satisfy an allocation: every add appends to the file and the
data file grows forever, until `UpdateFreePages` happens to rescan
(which lists every page individually — the representation the finder
actually needs). Caught live by a test: delete a 2-page record, add
another, file grew.

**v2 fix:** `FreePages` pushes **every** freed page number onto the
array (up to the 127 cap), matching what `UpdateFreePages` produces.
The run-finder is unchanged. (C: one-line loop in `FreePages`.)

### 1.3 The B-tree's in-memory structs cannot fit their own page

btree.h declares `BT_MAX_KEYS 60` and `BT_MAX_VALUES 60`, but a leaf
serialized with 60 keys × 1 value is already 847 bytes, and
`writeLeafNode` writes packed entries into a fixed 512-byte buffer
with **no bounds check** — enough keys/values and it overruns the
stack buffer before `fwrite`. The documented capacity is unreachable
and the undocumented one is a buffer overflow.

**v2 fix:** capacity is defined as what it physically is — a byte
budget (512 − 7 = 505 bytes of packed entries per leaf). An insert
that would exceed it splits the leaf (see §2.2); the writer refuses
to emit an oversized page. (C: at minimum, bound the serialization;
properly, adopt §2.2.)

### 1.4 Replay leaves the free list stale

`ReplayJournal` rebuilds indexes but never refreshes the free list,
so after recovery `free_page_count`/`free_pages` reflect pre-crash
state, not the replayed reality (e.g. a replayed delete's pages are
marked empty on disk but absent from the list, and the count is off).
Mostly self-corrects later via `UpdateFreePages`, but the counters
are wrong until then.

**v2 fix:** recovery ends with the free-list rescan (`UpdateFreePages`)
right after the index rebuild — it is already a full-file scan sitting
next to another full-file scan, so it is nearly free.

### 1.5 B-tree header only written at close

The C `BTree` caches its header in memory and writes it in
`CloseBTree`. Any header mutation (root page, page count — latent
today because the tree never allocates, live the moment splitting
exists) is lost on crash.

**v2 fix:** stateless design — the header page is read at the start
of each operation and written back immediately when it changes
(allocation, root growth). See §3.1 for the general pattern.

### 1.6 Compaction leaves duplicate records behind on a crash

`CompactDatabase` moves each record to its new location but never
clears the old pages — during the sweep, every moved record is active
in two places at once. That is fine if compaction completes (the
truncate and index rebuild sort it out), but a crash mid-sweep leaves
duplicates that `RebuildAllIndexes` then indexes **twice** (both
copies inserted under the same record ID). From there updates and
deletes hit one copy while lookups can return the other — stale-data
resurrection.

**v2 fix**, two halves: (a) the sweep clears each moved record's old
page run immediately after writing the new copy (skipping any pages
the two runs share); (b) the recovery-time primary rebuild checks for
an already-indexed record ID and, on a duplicate, keeps the first
(lower-page, i.e. moved-to) copy and marks the later copy's pages
empty — so even the crash-between-write-and-clear window heals.

### 1.7 `last_compacted` is set to zero

`CompactDatabase` finishes with `db->header.last_compacted = 0;` —
the field the operation exists to stamp is reset instead. v2 stamps
the current time, and also recounts `record_count` during the sweep
(free accuracy — the sweep visits every active record anyway).

## 2. Design gaps closed (the C library wants these)

### 2.1 Secondary indexes actually work: `DBIndexInfo` gains a field offset

The root cause of `FindRecordByString` being a stub and
`AddRecord`/`UpdateRecord`/`DeleteRecord` never touching the `.I??`
files: `DBIndexInfo` stores only a field *name*, so no library code
can extract an index key from a record's raw bytes. The metadata
cannot support the feature.

**v2 layout** (still exactly 32 bytes):

| Offset | Size | v1 | v2 |
|-------:|-----:|----|----|
| 0 | 28 | field_name (part) | field_name (≤ 27 chars) |
| 28 | 2 | field_name (last 2) | **field_offset** (u16, byte offset of the field in the record) |
| 30 | 1 | index_type | index_type |
| 31 | 1 | index_number | index_number |

With the offset recorded, the db module extracts keys itself
(`IT_ID`: the i32 at that offset; `IT_STRING`: the string field at
that offset, hashed with the same case-folded CRC16 as `StringKey`)
and the whole feature follows:

- **`AddIndex(db, field_name, index_type, field_offset)`** — validate
  the field fits inside `record_size` (4 bytes for IT_ID, the full
  64-byte string field for IT_STRING), reject duplicates and a 16th
  index, **build the index file by scanning existing records first,
  and only then write the header entry** — a crash mid-build leaves
  an orphaned `.I??` file, never a half-true header.
- **AddRecord** — after the primary-index insert, insert
  `extracted_key → record_id` into every secondary.
- **UpdateRecord** — read the old record *before* overwriting,
  extract old and new keys per index, and re-key **only the indexes
  whose key changed** (delete old entry, insert new).
- **DeleteRecord** — read the old record before freeing its pages,
  then remove its key from every secondary. Treat a missing entry as
  success: deletion's goal is absence, and recovery's rebuild
  self-heals a drifted index.
- **FindRecordByString** — secondary lookup → candidate record IDs →
  primary lookup → read record → **verify the actual field matches**
  (case-insensitively) before returning. CRC16 collides at 1 in
  65536; verification makes collisions invisible to callers instead
  of returning the wrong record. An IT_ID sibling
  (`FindRecordByInt`) verifies the same way.
- **Recovery** — index updates are never journaled (unchanged from
  the design); `ReplayJournal`'s rebuild must now recreate the
  secondaries alongside the primary, from the same data-file scan.
- Extraction is defensive: a malformed string length byte (over 63,
  or running past the record) yields the empty string / key 0 rather
  than reading out of bounds — record bytes are caller data.

### 2.2 A real B-tree: splitting, internal nodes, root growth

The C tree is a single root leaf; at capacity, inserts fail
(`btree.md` "Current Limitations"). With ~36 single-value keys per
leaf that caps a database at ~36 records. v2 implements the growth
path the format always reserved:

- **Leaf split:** entries are variable-size, so the split point is
  the entry boundary nearest the byte midpoint (each side keeps at
  least one entry). Right half moves to a new page; the new page's
  first key is promoted to the parent as a separator; the
  `next_leaf` chain is restitched (left → new → left's old next).
- **Internal nodes** (page type 2, finally concrete): key_count u16
  at offset 1, then child i (i32) at 3+8i interleaved with key i at
  7+8i; n keys, n+1 children, max 63 keys (3 + 8·63 + 4 = 511).
  Child i routes keys below key i; the last child routes the rest.
- **Internal split:** at 64 keys, split at the median, which is
  *promoted* (moved up), not copied down.
- **Root growth:** a root split allocates a new one-key root and
  repoints the header's `root_page` — the tree only ever grows at
  the top, so every leaf sits at the same depth by construction.
- **Page allocation** comes from the header's `page_count`
  (incremented and written immediately); `next_free_page` stays 0.
- **Deletion is lazy:** entries are removed, nodes never merge,
  emptied leaves stay in place (internal separator keys need not
  exist as live keys). Space returns when the tree is rebuilt —
  which recovery already does, and compaction will. This deletes
  the hardest third of a textbook B-tree at zero cost to a system
  that already rebuilds indexes wholesale.
- Insert now fails only when a *single entry* outgrows a page
  (~124 values on one key) — the case overflow pages (type 4, still
  reserved) exist for.
- Worth porting from the Clarus tests: a leaf-chain walk asserting
  every key strictly ascends across the whole tree and the total
  matches — it validates split stitching and global order in one
  cheap pass, and caught nothing only because it was there.

### 2.3 Journal checksum defined over the on-disk bytes

C builds a separate 516-byte buffer to checksum
(`CalculateJournalChecksum`). v2 defines the checksum as CRC16 over
the entry's first 516 bytes *exactly as laid out on disk*, then
stores it at offset 516 — the writer checksums the buffer it is
about to write and replay checksums the buffer it just read. Same
strength, one serialization pass, no risk of the checksum buffer's
layout drifting from the real one.

## 3. Structural choices worth considering

### 3.1 Stateless handles: all mutable state lives on disk

The Clarus modules keep no in-memory copies of the header or free
list; every operation reads the (512-byte) metadata pages it needs
and writes them back immediately. The "handle" is just the open
files. Costs one extra page read per operation; buys: no
write-back-at-close to forget (§1.5), no cached-state/disk drift
after a crash, and any number of independently opened trees/databases
with no shared-state coordination. On a machine where a page read is
a memcpy from the OS cache this is close to free; even on a real
Mac Plus it is one 512-byte read against an operation that already
does several.

### 3.2 Failure ordering in AddIndex

Build first, publish (header write) second — generalizable: every
multi-file mutation in v2 orders its writes so that a crash at any
point leaves either the old state or orphaned-but-unreferenced data,
with recovery's rebuild covering the middle.

## 4. Clarus/68k-specific choices — do NOT port

- **Big-endian integers, format version 2.** Native for the 68k and
  it lets the plain (unsuffixed) accessors be the only ones used.
  The C library should stay little-endian; if it ever needs to read
  v2 files, the version field distinguishes unambiguously — v1 LE is
  bytes `01 00`, v2 BE is `00 02`, whichever order you read them in.
- **Pascal strings on disk** (index field names, indexed string
  fields: length byte + bytes). Natural for Clarus, noise for C.
  Note `GenerateIndexKey` already expects a length-prefixed string
  for IT_STRING, so C is half-Pascal here anyway.
- **`last_compacted` in Mac-epoch seconds** (1904, local time).
  Platform clock choice, nothing more.

If the C library adopts the v1-compatible fixes (§1, §2) without the
byte-order change, bump its version to distinguish "v1 with a status
byte in journal entries and an offset in DBIndexInfo" from old v1
files — the DBIndexInfo reinterpretation in particular silently
misreads old headers (the last two name bytes become the offset).

## 5. Test scenarios worth porting to the C suite

All from `tests/btree-test.cla` / `tests/vdb-test.cla` (each caught
or guards a real behavior above):

1. Delete a multi-page record, add another, assert the file did NOT
   grow (§1.2).
2. Hand-craft a pending journal (flag byte + entries written raw),
   reopen, assert: valid entry applied, checksum-corrupted entry
   skipped, journal truncated, and — for a multi-page record — every
   page's status correct after replay (§1.1).
3. Journal an update that changes an indexed field, "crash", reopen:
   lookups by the NEW value succeed and by the old value fail —
   proving recovery rebuilds secondaries rather than trusting them
   (§2.1).
4. 500 keys inserted in scrambled order, then 2000 sequentially:
   every key findable, root provably internal (and its first child
   internal), leaf chain globally sorted and complete (§2.2).
5. Index lookups: case-insensitivity both directions, verification
   path (collision or not, the returned record's field must match),
   type mismatch rejected, field-past-record-end rejected (§2.1).
