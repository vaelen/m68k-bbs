# vDB v2: Clarus Implementation Spec

The Clarus implementation of Vaelen's Database (vDB), targeting 68k
Mac (System 6/7) first and the Clarus host lane for testing. The
*design* — files, pages, indexes, journal, operations — is the same as
the C implementation (`~/repos/libvdb`, described in `docs/vdb.md`);
this spec defines the **v2 on-disk format**, which diverges from v1
deliberately. Where this spec is silent, `docs/vdb.md` governs
(operation sequences, transaction protocol, helper semantics).

## Differences from v1 (libvdb)

| # | Change | Why |
|---|--------|-----|
| 1 | All multi-byte integers are **big-endian** | Native order for the 68k: plain `intAt`/`wordAt`/`setIntAt`/`setWordAt` everywhere. No `LE` suffixes to forget — a missed suffix is a silent corruption bug. |
| 2 | `version` = **2** (both .DAT and B-tree headers) | Self-describing: v1 LE on disk is `01 00`, v2 BE is `00 02` — unambiguous in either byte order. |
| 3 | Strings on disk are **Pascal strings** (length byte + chars) | What Clarus produces natively; no NUL scanning. Same byte budgets as v1. |
| 4 | `last_compacted` is **Mac-epoch seconds** (what `now()` returns) | Display-only metadata; avoids epoch conversion. |
| 5 | Leaf-page capacity is a **byte budget**, not a key count | The v1 doc's 60-keys × 60-values caps cannot fit a 512-byte page; v1's packed writer can overrun. v2 makes "it must fit the page" the rule. |
| 6 | DBIndexInfo records the field's **byte offset** (name shrinks to 28 bytes) | Without it, no code can extract index keys from record bytes — the reason libvdb's secondary-index maintenance was never implemented. |

A v2 reader MUST reject any file whose version is not 2 (or whose
signature doesn't match) with `lastError` set. No v1 compatibility —
there are no v1 files to migrate; add conversion only when one exists.

## Conventions

- **Pages**: 512 bytes, numbered from 0. All reads/writes are whole
  pages at offset `page_num * 512` via `filehandle.readAt`/`writeAt`.
- **Integers**: big-endian two's complement. `i32` ↔ `t.intAt`/
  `t.setIntAt`; `u16` ↔ `t.wordAt`/`t.setWordAt`. `u8` is one byte.
  Never use the `LE` accessor family in vDB code.
- **bool**: one byte, 0 = false, 1 = true.
- **Strings**: Pascal — one length byte, then that many bytes of
  MacRoman text, remainder of the field zero-filled. A field of size N
  holds at most N-1 chars.
- **CRC16**: CRC-16/KERMIT — exactly the `t.crc16(pos, n)` builtin
  (and libvdb's `CRC16()`), so keys and checksums match the C library.
- **Durability**: `f.flush()` is the write barrier the journal
  protocol requires (see `docs/vdb.md`, Transaction Protocol).
- **Mac file types** (via `file.create(path, type, creator)`):
  data `"VDBd"`, index `"VDBi"`, journal `"VDBj"`; creator is the
  application's (the BBS uses `"68BB"`). Ignored on the host lane.
- **Naming**: `NAME.DAT`, `NAME.IDX`, `NAME.I00`…`NAME.I14`,
  `NAME.JNL` — same as v1. HFS caps filenames at 31 chars, so the
  base name must be ≤ 27 chars.

## .DAT file

### Page 0 — header + index list

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 4 | signature | `"VDB\0"` (0x56 0x44 0x42 0x00) |
| 4 | 2 | version | u16, = 2 |
| 6 | 2 | page_size | u16, = 512 |
| 8 | 2 | record_size | u16, 1–65535; all records same size |
| 10 | 4 | record_count | i32, active records |
| 14 | 4 | next_record_id | i32, never decreases |
| 18 | 4 | last_compacted | i32, Mac-epoch seconds, 0 = never |
| 22 | 1 | journal_pending | bool |
| 23 | 1 | index_count | u8, 0–15 |
| 24 | 8 | reserved | zero |
| 32 | 480 | indexes | 15 × 32-byte DBIndexInfo; first `index_count` valid |

**DBIndexInfo** (32 bytes):

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 28 | field_name | Pascal string, ≤ 27 chars |
| 28 | 2 | field_offset | u16, byte offset of the field in the record |
| 30 | 1 | index_type | 0 = IT_ID (i32 field), 1 = IT_STRING |
| 31 | 1 | index_number | 0–14, names the `.I??` file |

`field_offset` is a v2 addition (v1 spent all 30 leading bytes on the
name): recording where the field lives is what lets the db module
extract keys from record bytes itself — so add/update/delete keep
every secondary index current automatically, the piece libvdb never
implemented because its metadata couldn't support it. Index updates
are NOT journaled; crash recovery rebuilds every index from the data
file, per the design.

### Page 1 — free list

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 2 | free_page_count | u16, total free pages in file |
| 2 | 2 | free_page_list_len | u16, valid entries below, 0–127 |
| 4 | 508 | free_pages | i32[127], stack of free page numbers, each listed individually (v2: v1 listed only a run's first page, but its allocator needed every page as an entry to find a run, so freed runs were never reused until a rescan) |

Semantics (identical to v1): the array is a cache of up to 127 known
free pages; `free_page_count` is the true total. Count > 0 with an
empty array triggers a rescan (`UpdateFreePages`).

### Pages 2+ — data pages

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 4 | id | i32 record ID |
| 4 | 1 | status | 0 = PS_EMPTY, 1 = PS_ACTIVE, 2 = PS_CONTINUATION |
| 5 | 1 | reserved | zero |
| 6 | 506 | data | record bytes |

`pages_per_record = ceil(record_size / 506)`. Multi-page records
occupy consecutive pages, all carrying the same `id`; only the first
is PS_ACTIVE. Record *content* layout is application-defined, except:
a field named by an IT_STRING index must be a Pascal string field of
64 bytes (≤ 63 chars) at a fixed offset; a field named by an IT_ID
index must be an i32 (big-endian, like everything else).

## Index files (.IDX and .I??) — B-tree v2

Same page-0-header + node-pages shape as libvdb's btree module.
`.IDX` maps record ID → first page number; `.I??` map field keys →
record IDs. Keys and values are i32.

### Page 0 — header

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 4 | magic | `"BTRE"` |
| 4 | 2 | version | u16, = 2 |
| 6 | 2 | order | u16, informational |
| 8 | 4 | root_page | i32 |
| 12 | 4 | next_free_page | i32, 0 = none |
| 16 | 4 | page_count | i32, total pages incl. header |
| 20 | 492 | reserved | zero |

### Node pages

Common prefix: byte 0 is `page_type` — 2 = internal (reserved),
3 = leaf, 4 = overflow.

**Leaf** (type 3):

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 1 | page_type | = 3 |
| 1 | 2 | key_count | u16 |
| 3 | 4 | next_leaf | i32, 0 = none (range scans) |
| 7 | … | entries | `key_count` packed entries, ascending key order |

Packed leaf entry (variable length, `10 + 4*value_count` bytes):

| Size | Field | Notes |
|-----:|-------|-------|
| 4 | key | i32 |
| 2 | value_count | u16, values stored in this node |
| 4 × n | values | i32 each |
| 4 | overflow_page | i32, 0 = none |

**Capacity rule (v2)**: the serialized entries MUST fit in
512 − 7 = 505 bytes. A leaf whose entries would overflow the budget
splits near its byte midpoint (each side keeps at least one entry),
the right half moving to a new page whose first key is promoted to
the parent as a separator; `next_leaf` keeps the leaves a sorted
chain. One *entry* larger than the budget (a key with ~124+ values)
cannot split and the insert fails — that is what overflow pages are
reserved for.

**Internal** (type 3 = leaf's sibling, type 2):

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 1 | page_type | = 2 |
| 1 | 2 | key_count | u16, n = 1–63 |
| 3 + 8i | 4 | child i | i32 page number, i = 0…n |
| 7 + 8i | 4 | key i | i32, i = 0…n−1 |

Child i routes keys below key i; the last child routes the rest.
Max 63 keys (3 + 8·63 + 4 = 511 bytes). An internal node past 63
keys splits with its median key *promoted* (not copied down); when
the root splits, a new one-key root is allocated and the header's
`root_page` repointed — so the tree grows at the top and every leaf
sits at the same depth. New pages come from the header's
`page_count`; `next_free_page` stays 0 (unused).

**Deletion is lazy**: entries are removed from their leaf, but nodes
are never merged and an emptied leaf stays in place (separator keys
in internal nodes need not exist as live keys). The space comes back
when the tree is rebuilt — which vDB does on crash recovery, and
compaction will do wholesale.

**Overflow** (type 4) pages hold a key's values past the first
`btMaxInline` (32): page_type(1), u16 value_count at 1, i32 next at 3,
then packed i32 values (126 per page). A leaf entry's trailing i32 is
the chain head (0 = none). A whole-key delete leaks the chain until the
tree is rebuilt (the same lazy model as emptied leaves).

### Key generation

- IT_ID: the field's i32 value is the key.
- IT_STRING (`StringKey`): lowercase the string's bytes (ASCII
  `A`–`Z` only; high MacRoman bytes pass through), then
  `key = crc16` of the lowercased bytes (length byte excluded),
  zero-extended to i32. Case-insensitive; collisions possible
  (1 in 65536), so callers verify the field after lookup — see
  `docs/vdb.md`.

## .JNL file — journal

A sequence of fixed 518-byte entries, appended in order, truncated to
0 on commit. Protocol and replay rules: `docs/vdb.md`.

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 1 | operation | 0 = none, 1 = update, 2 = delete, 3 = add |
| 1 | 4 | page_num | i32, −1 for add |
| 5 | 4 | record_id | i32 |
| 9 | 507 | data | page data (506), then the page's status byte (v2: was reserved in v1 — recording the status lets replay restore continuation pages correctly, which v1 could not) |
| 516 | 2 | checksum | u16 |

**Checksum**: `crc16` of the entry's first 516 bytes exactly as laid
out on disk (so no separate serialization pass — compute over the
assembled entry buffer, then store at offset 516). Entries with bad
checksums are skipped during replay.

## Clarus module plan

Mirrors the C split: the B-tree is a standalone, reusable module with
no knowledge of vDB, exactly as `btree.c` is in libvdb.

- `btree.cla` — self-contained B-tree over a `filehandle`: `btCreate`,
  `btOpen`, `btClose`, `btInsert`, `btFind`, `btDelete`,
  `btDeleteValue`, plus `StringKey` (which lives here, as in C). Owns
  its own node serialization. Includes nothing from vdb; reusable by
  any program needing an int- or hashed-string-keyed index.
- `vdb.cla` — the db module: open/create/close, add/find/update/
  delete record, index management, journal protocol, compaction,
  `UpdateFreePages` — the helper set from `docs/vdb.md` with Clarus
  conventions (`bool` return, details in `lastError`). Owns the
  header/free-list/data-page/journal serialization; talks to the
  B-tree only through `btree.cla`'s public functions.
- `tests/btree-test.cla`, `tests/vdb-test.cla` — host-lane suites.
  `filehandle` works on the host lane, so the tests create real files
  in a scratch directory and exercise the modules end to end,
  crash-recovery replay included. (No pure/IO file split as with
  `terminal.cla`/`termio.cla` — that existed only because the host
  lane couldn't compile connection calls, which doesn't apply to
  file I/O.)

Records and arrays can hold `filehandle` values, so a `Database`
record owns its open files, mirroring the C struct.

**TODO — iteration API.** vDB has no way to walk records except
`dbNextRecordId(db)` + probing `dbFind` over 1 .. next−1 (IDs are
dense and never reused, so this works but does one index lookup per
probe, misses included). Add a real cursor — e.g. `dbFirstId`/
`dbNextId(afterId)` walking the primary index's leaf chain (which is
already maintained in sorted order for exactly this) — when boards
get big enough for probing to hurt.
