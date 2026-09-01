# vDB Scan Cursors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-ID `dbFind` probe loops with leaf-sequential B-tree scan cursors, cache the vDB header page, and memoize network names in the board picker — cutting SE list-screen draws from ~6 s toward the ~1.5 s serial floor.

**Architecture:** btree.cla gains a transient scan cursor (opaque caller-owned `text` blob: direction, path, current leaf snapshot) supporting ascending and descending walks with no on-disk format change (descending steps use the descent path, not a prev pointer). vdb.cla wraps it (`dbScanStart`/`dbScanNext`/`dbScanSkip`) and caches header pages in a module map. Every enumerating caller converts; single-record lookups stay on `dbFind`.

**Tech Stack:** Clarus (pinned toolchain `bin/clarusc`, `--rtdir vendor/runtime/clarus/`), host-lane CLI tests via `scripts/test.sh`, 68k build via `scripts/build.sh`.

**Spec:** `docs/superpowers/specs/2026-09-01-vdb-scan-cursor-design.md`

## Global Constraints

- Clarus: statements end at newline; no `+=`/`++`; `var` only at top of a body; records pass **by value** with immutable params; `text` passes by reference; `text` assignment **aliases** — copy with `.append()`. No `break` — exit loops with flag/index tricks.
- Source is MacRoman; keep program text ASCII.
- 68k backend: never `return m.get(...)` or map-index directly — assign to a local first; no fixed arrays by value.
- Always compile/check with `bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla`; 68k build must stay green (`scripts/build.sh`).
- Commit messages: one sentence, never mention Claude/AI, no trailers.
- API rule (document, enforce by convention): a scan cursor is transient — created, drained, and dropped inside one event handler; **never write to a database while one of its scans is live** — collect IDs first, then mutate.
- Screen output, prompts, and list numbering must be byte-identical to today (behavior-preserving conversions).

---

### Task 1: B-tree scan primitives

**Files:**
- Modify: `btree.cla` (new section after `btFind`, ~line 537)
- Test: `tests/btree-test.cla` (append to existing `App.startCLI`)

**Interfaces:**
- Consumes: `btDescend(f, key, path, page)`, `btPageSize`, `btLeafHeaderSize`, `btMaxDepth`, `btPtLeaf`, `btPtInternal` (all existing).
- Produces (used by Task 2):
  - `btScanStart(f: filehandle, cur: text, fromKey: int, descending: bool): bool`
  - `btScanNext(f: filehandle, cur: text): bool`
  - `btScanKey(cur: text): int`
  - `btScanValue(cur: text): int`

Cursor blob layout (private to btree.cla, all big-endian):
byte 0 state (0 fresh, 1 running, 2 done), byte 1 direction (0 asc, 1 desc), word 2 entry index, int 4 current leaf page, int 8 current key, int 12 current value (first value of the entry), word 16 path depth, ints 18..145 path page numbers (`btMaxDepth` slots), bytes 146.. the 512-byte leaf snapshot. "Fresh" means positioned on an entry not yet consumed: the first `btScanNext` returns it without advancing, so every loop is uniform `while btScanNext(...)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/btree-test.cla` inside `on App.startCLI`, just before the final `if failures ...` exit block (reuse the existing `expect` helper; `f`, `v`, `i`, `ordered` are already declared — add new vars to the existing `var` block at the top of the handler: `var cur: text`, `var f2: filehandle`, `var hit: bool`):

```
    // --- scan cursor -------------------------------------------------
    f2 = btCreate("BTS.IDX", "VDBi", "68BB")
    expect(f2 != nil, "scan tree created")
    // 2500 keys (value = key * 7): ~70 leaves, two internal levels
    i = 1
    while i <= 2500 {
        if not btInsert(f2, i, i * 7) {
            expect(false, "scan insert " + string(i))
            i = 2501
        }
        i = i + 1
    }

    expect(btScanStart(f2, cur, 1, false), "ascending scan starts")
    i = 0
    ordered = true
    while btScanNext(f2, cur) {
        i = i + 1
        if btScanKey(cur) != i or btScanValue(cur) != i * 7 { ordered = false }
    }
    expect(i == 2500 and ordered, "ascending scan: all keys, in order")
    expect(not btScanNext(f2, cur), "exhausted scan stays done")

    expect(btScanStart(f2, cur, 2500, true), "descending scan starts")
    i = 2500
    ordered = true
    while btScanNext(f2, cur) {
        if btScanKey(cur) != i or btScanValue(cur) != i * 7 { ordered = false }
        i = i - 1
    }
    expect(i == 0 and ordered, "descending scan: all keys, in order")

    // seeded mid-range
    expect(btScanStart(f2, cur, 1200, false) and btScanNext(f2, cur), "asc seek 1200")
    expect(btScanKey(cur) == 1200, "asc seek lands on 1200")
    expect(btScanStart(f2, cur, 1200, true) and btScanNext(f2, cur), "desc seek 1200")
    expect(btScanKey(cur) == 1200, "desc seek lands on 1200")

    // holes: delete 900..1100 (empties ~5 consecutive leaves)
    i = 900
    while i <= 1100 {
        btDeleteValue(f2, i, i * 7)
        i = i + 1
    }
    expect(btScanStart(f2, cur, 1000, false) and btScanNext(f2, cur), "asc seek into hole")
    expect(btScanKey(cur) == 1101, "asc scan skips the hole forward")
    expect(btScanStart(f2, cur, 1000, true) and btScanNext(f2, cur), "desc seek into hole")
    expect(btScanKey(cur) == 899, "desc scan skips the hole backward")
    // crossing the emptied leaves mid-run
    btScanStart(f2, cur, 890, false)
    i = 0
    hit = true
    while i < 15 and btScanNext(f2, cur) {
        i = i + 1
        if i <= 10 {
            if btScanKey(cur) != 889 + i { hit = false }
        } else {
            if btScanKey(cur) != 1090 + i { hit = false }
        }
    }
    expect(i == 15 and hit, "ascending run crosses emptied leaves")
    btScanStart(f2, cur, 1110, true)
    i = 0
    hit = true
    while i < 15 and btScanNext(f2, cur) {
        i = i + 1
        if i <= 10 {
            if btScanKey(cur) != 1111 - i { hit = false }
        } else {
            if btScanKey(cur) != 910 - i { hit = false }
        }
    }
    expect(i == 15 and hit, "descending run crosses emptied leaves")

    // ends of the range
    expect(btScanStart(f2, cur, 3000, true) and btScanNext(f2, cur) and btScanKey(cur) == 2500, "desc from past the top lands on max")
    expect(not (btScanStart(f2, cur, 3000, false) and btScanNext(f2, cur)), "asc from past the top is empty")
    expect(not (btScanStart(f2, cur, 0, true) and btScanNext(f2, cur)), "desc from below the bottom is empty")
    f2.close()

    // empty tree
    f2 = btCreate("BTE.IDX", "VDBi", "68BB")
    expect(not (btScanStart(f2, cur, 1, false) and btScanNext(f2, cur)), "empty tree asc scan is empty")
    expect(not (btScanStart(f2, cur, 1, true) and btScanNext(f2, cur)), "empty tree desc scan is empty")
    f2.close()
```

Arithmetic check (keys 900..1100 deleted): ascending from 890 yields 890..899 (`889 + i`, i=1..10) then 1101..1105 (`1090 + i`, i=11..15); descending from 1110 yields 1110..1101 (`1111 - i`, i=1..10) then 899..895 (`910 - i`, i=11..15).

- [ ] **Step 2: Run the suite to verify it fails**

```sh
D=$(mktemp -d) && cp tests/fixtures/* "$D"/ && bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$D/main.c" tests/btree-test.cla && cc -O1 -I vendor/runtime/host -o "$D/prog" "$D/main.c" vendor/runtime/host/rt.c && (cd "$D" && ./prog); rm -rf "$D"
```
Expected: compile error — `btScanStart` undefined.

- [ ] **Step 3: Implement the primitives**

Add to `btree.cla` after `btFind` (before `btRemove`):

```
// --- Scan cursors -----------------------------------------------------
// A transient, caller-owned cursor over the tree in key order, either
// direction. The blob layout is private: state(1) dir(1) entry_index(2)
// leaf_page(4) key(4) value(4) depth(2) path page numbers
// (btMaxDepth * 4), then a snapshot of the current leaf page.
// Descending walks re-read path pages to find the previous leaf (the
// leaf chain is forward-only), so the tree MUST NOT be written while a
// scan is live -- create, drain and drop the cursor inside one event
// handler; mutators collect keys first, then act.

const btScanHdrSize: int = 146     // 18 + btMaxDepth * 4
const btScanFresh: int = 0
const btScanRun: int = 1
const btScanDone: int = 2

func btScanKey(cur: text): int {
    return cur.intAt(8)
}

func btScanValue(cur: text): int {
    return cur.intAt(12)
}

// Byte offset (within the blob) of leaf entry `idx`.
func btScanEntryOff(cur: text, idx: int): int {
    var off: int = btScanHdrSize + btLeafHeaderSize
    var i: int = 0
    while i < idx {
        off = off + 10 + cur.wordAt(off + 4) * 4
        i = i + 1
    }
    return off
}

// Make entry `idx` of the snapshot current.
func btScanLoad(cur: text, idx: int) {
    var off: int = btScanEntryOff(cur, idx)
    cur.setWordAt(2, idx)
    cur.setIntAt(8, cur.intAt(off))
    cur.setIntAt(12, cur.intAt(off + 6))
}

// Replace the leaf snapshot (page `pageNum`, content `page`).
func btScanSetLeaf(cur: text, pageNum: int, page: text) {
    var head: text
    head.append(cur.textAt(0, btScanHdrSize))
    cur.clear()
    cur.append(head)
    cur.append(page)
    cur.setIntAt(4, pageNum)
}

// Ascending: follow the next_leaf chain to the next non-empty leaf.
// (The path is not maintained -- ascending never reads it.)
func btScanNextLeaf(f: filehandle, cur: text): bool {
    var page: text
    var next: int = cur.intAt(btScanHdrSize + 3)
    while next != 0 {
        if not f.readAt(next * btPageSize, btPageSize, page) { return false }
        if page.length != btPageSize { return false }
        btScanSetLeaf(cur, next, page)
        if cur.wordAt(btScanHdrSize + 1) > 0 { return true }
        next = cur.intAt(btScanHdrSize + 3)
    }
    return false
}

// Descending: the previous leaf in tree order, via the path -- find
// this child in its parent, take the one before it (recursing up at a
// first child), then ride the rightmost spine back down to a leaf.
// May land on an empty leaf; the caller loops.
func btScanPrevLeaf(f: filehandle, cur: text): bool {
    var page: text
    var level: int = cur.wordAt(16) - 2
    var child: int
    var idx: int
    var n: int
    var i: int
    while level >= 0 {
        if not f.readAt(cur.intAt(18 + level * 4) * btPageSize, btPageSize, page) { return false }
        if page.length != btPageSize { return false }
        child = cur.intAt(18 + (level + 1) * 4)
        n = page.wordAt(1)
        idx = 0 - 1
        i = 0
        while i <= n {
            if page.intAt(3 + 8 * i) == child { idx = i; i = n + 1 }
            i = i + 1
        }
        if idx > 0 {
            child = page.intAt(3 + 8 * (idx - 1))
            level = level + 1
            while level < btMaxDepth {
                if not f.readAt(child * btPageSize, btPageSize, page) { return false }
                if page.length != btPageSize { return false }
                cur.setIntAt(18 + level * 4, child)
                if int(page[0]) == btPtLeaf {
                    cur.setWordAt(16, level + 1)
                    btScanSetLeaf(cur, child, page)
                    return true
                }
                if int(page[0]) != btPtInternal { return false }
                child = page.intAt(3 + 8 * page.wordAt(1))
                level = level + 1
            }
            return false
        }
        level = level - 1
    }
    return false
}

// Move to the adjacent leaf in scan direction and make its first
// (asc) or last (desc) entry current. Marks the cursor done at the end.
func btScanStep(f: filehandle, cur: text): bool {
    var ok: bool
    if int(cur[1]) == 1 {
        ok = btScanPrevLeaf(f, cur)
        while ok and cur.wordAt(btScanHdrSize + 1) == 0 {
            ok = btScanPrevLeaf(f, cur)
        }
        if ok { btScanLoad(cur, cur.wordAt(btScanHdrSize + 1) - 1) }
    } else {
        ok = btScanNextLeaf(f, cur)
        if ok { btScanLoad(cur, 0) }
    }
    if not ok { cur[0] = char(btScanDone) }
    return ok
}

// Seed a scan at fromKey: the smallest key >= fromKey (ascending) or
// the largest <= fromKey (descending). True when an entry is current.
func btScanStart(f: filehandle, cur: text, fromKey: int, descending: bool): bool {
    var path: list of int
    var page: text
    var n: int
    var i: int
    var off: int
    var k: int
    var found: int = 0 - 1
    cur.clear()
    while cur.length < btScanHdrSize { cur.append(char(0)) }
    cur[0] = char(btScanDone)
    if not btDescend(f, fromKey, path, page) { return false }
    if descending { cur[1] = char(1) }
    cur.setWordAt(16, path.count)
    i = 0
    while i < path.count {
        cur.setIntAt(18 + i * 4, path[i])
        i = i + 1
    }
    cur.append(page)
    cur.setIntAt(4, path[path.count - 1])
    n = cur.wordAt(btScanHdrSize + 1)
    off = btScanHdrSize + btLeafHeaderSize
    i = 0
    while i < n {
        k = cur.intAt(off)
        if descending {
            if k <= fromKey { found = i }
        } else {
            if found < 0 and k >= fromKey { found = i }
        }
        off = off + 10 + cur.wordAt(off + 4) * 4
        i = i + 1
    }
    if found >= 0 {
        btScanLoad(cur, found)
        cur[0] = char(btScanFresh)
        return true
    }
    if not btScanStep(f, cur) { return false }
    cur[0] = char(btScanFresh)
    return true
}

// Advance one entry; the first call after btScanStart returns the
// seeded entry itself. False (sticky) when the scan is exhausted.
func btScanNext(f: filehandle, cur: text): bool {
    var idx: int
    if cur.length < btScanHdrSize or int(cur[0]) == btScanDone { return false }
    if int(cur[0]) == btScanFresh {
        cur[0] = char(btScanRun)
        return true
    }
    idx = cur.wordAt(2)
    if int(cur[1]) == 1 {
        if idx > 0 {
            btScanLoad(cur, idx - 1)
            return true
        }
    } else {
        if idx + 1 < cur.wordAt(btScanHdrSize + 1) {
            btScanLoad(cur, idx + 1)
            return true
        }
    }
    return btScanStep(f, cur)
}
```

State note: `btScanStep` leaves the state byte untouched on success — still `btScanRun` when reached from `btScanNext`, and `btScanStart` sets `btScanFresh` itself after its call — and sets `btScanDone` on failure.

- [ ] **Step 4: Run the suite to verify it passes**

Same command as Step 2. Expected: all `PASS` lines including the 18 new scan assertions, exit 0.

- [ ] **Step 5: Verify no regression, commit**

```sh
scripts/test.sh && bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla
git add btree.cla tests/btree-test.cla
git commit -m "B-tree scan cursors: transient caller-owned text-blob cursor, ascending and descending, no format change."
```

---

### Task 2: vDB scan API

**Files:**
- Modify: `vdb.cla` (new section after `dbNextRecordId`, ~line 817)
- Test: `tests/vdb-test.cla` (append)

**Interfaces:**
- Consumes: Task 1's `btScanStart`/`btScanNext`/`btScanKey`/`btScanValue`; existing `dbIsOpen`, `dbReadHeader`, `dbReadRecordAt`.
- Produces (used by Tasks 4–8):
  - `dbScanStart(db: Database, cur: text, fromId: int, descending: bool): bool`
  - `dbScanNext(db: Database, cur: text, rec: text): int` — fills `rec`, returns ID, 0 when exhausted
  - `dbScanSkip(db: Database, cur: text, n: int): int` — skips n live index entries (no record reads), returns count skipped

- [ ] **Step 1: Write the failing tests**

Append to `tests/vdb-test.cla` before the exit block (declare `var cur: text`, `var sdb: Database`, `var sid: int`, `var srec: text`, `var got: int` in the handler's var block; reuse `expect`):

```
    // --- scan cursors ------------------------------------------------
    sdb = dbCreate("SCAN", 32, "68BB")
    expect(dbIsOpen(sdb), "scan db created")
    sid = 1
    while sid <= 40 {
        dbAdd(sdb, "rec" + string(sid))
        sid = sid + 1
    }
    dbDelete(sdb, 7)
    dbDelete(sdb, 8)
    dbDelete(sdb, 40)

    expect(dbScanStart(sdb, cur, 1, false), "asc scan starts")
    got = 0
    sid = dbScanNext(sdb, cur, srec)
    while sid != 0 {
        got = got + 1
        sid = dbScanNext(sdb, cur, srec)
    }
    expect(got == 37, "asc scan visits the 37 live records")

    expect(dbScanStart(sdb, cur, 1, false) and dbScanNext(sdb, cur, srec) == 1, "asc scan yields ID 1 first")
    expect(srec.length == 32 and srec[0, 4] == "rec1", "scan fills the record bytes")

    expect(dbScanStart(sdb, cur, 6, false), "asc scan from 6")
    expect(dbScanNext(sdb, cur, srec) == 6 and dbScanNext(sdb, cur, srec) == 9, "asc scan skips deleted 7-8")

    expect(dbScanStart(sdb, cur, dbNextRecordId(sdb) - 1, true), "desc scan from newest")
    expect(dbScanNext(sdb, cur, srec) == 39, "desc scan starts at newest live (40 deleted)")
    expect(dbScanNext(sdb, cur, srec) == 38, "desc scan walks downward")

    expect(dbScanStart(sdb, cur, dbNextRecordId(sdb) - 1, true), "desc scan restarts")
    expect(dbScanSkip(sdb, cur, 10) == 10, "skip 10 live entries")
    expect(dbScanNext(sdb, cur, srec) == 29, "skip positions correctly (39..30 consumed)")
    dbClose(sdb)
```

- [ ] **Step 2: Run to verify it fails**

```sh
D=$(mktemp -d) && cp tests/fixtures/* "$D"/ && bin/clarusc emit --rtdir vendor/runtime/clarus/ -o "$D/main.c" tests/vdb-test.cla && cc -O1 -I vendor/runtime/host -o "$D/prog" "$D/main.c" vendor/runtime/host/rt.c && (cd "$D" && ./prog); rm -rf "$D"
```
Expected: compile error — `dbScanStart` undefined.

- [ ] **Step 3: Implement**

Add to `vdb.cla` after `dbNextRecordId`, and change that function's `// TODO: replace with a real iteration/cursor API` comment to `// Prefer dbScanStart/dbScanNext for enumeration; probing stays valid.`:

```
// --- Scan cursors -----------------------------------------------------
// Transient, caller-owned (see btree.cla): seed with dbScanStart,
// drain with dbScanNext/dbScanSkip inside ONE event handler, drop it.
// Never write to the database while one of its scans is live --
// collect IDs first, then mutate.

func dbScanStart(db: Database, cur: text, fromId: int, descending: bool): bool {
    if not dbIsOpen(db) { return false }
    return btScanStart(db.index, cur, fromId, descending)
}

// Advance to the next live record: fills rec with its bytes and
// returns its ID; 0 when the scan is exhausted. An entry whose record
// pages fail to read is logged and skipped.
func dbScanNext(db: Database, cur: text, rec: text): int {
    var hdr: text
    var out: text
    var id: int
    rec.clear()
    if not dbIsOpen(db) { return 0 }
    if not dbReadHeader(db, hdr) { return 0 }
    while btScanNext(db.index, cur) {
        id = btScanKey(cur)
        out = dbReadRecordAt(db, btScanValue(cur), id, hdr.wordAt(8))
        if out.length == hdr.wordAt(8) {
            rec.append(out)
            return id
        }
        log("dbScan: unreadable record " + string(id) + " in " + db.name)
    }
    return 0
}

// Skip n index entries (live records) without reading record pages;
// returns the number actually skipped.
func dbScanSkip(db: Database, cur: text, n: int): int {
    var done: int = 0
    while done < n and btScanNext(db.index, cur) {
        done = done + 1
    }
    return done
}
```

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: all PASS, exit 0.

- [ ] **Step 5: Full suite, commit**

```sh
scripts/test.sh && bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla
git add vdb.cla tests/vdb-test.cla
git commit -m "vDB scan API over the B-tree cursor: dbScanStart/dbScanNext/dbScanSkip."
```

---

### Task 3: Header cache

**Files:**
- Modify: `vdb.cla` (`dbReadHeader` ~line 67, `dbWriteHeader` ~line 77, `dbOpen` ~line 615, `dbClose` ~line 652, `dbCompact` ~line 855)
- Test: `tests/vdb-test.cla` (append)

**Interfaces:**
- Produces: no new public API — `dbReadHeader` transparently serves cached bytes. Internal: `var dbHdrCache: map of text`, `func dbHdrCacheDrop(name: string)`.

- [ ] **Step 1: Write the tests**

The cache is transparent, so the strongest test is the entire existing suite passing (every add/find/update/delete/compact/recover path reads headers). Add two explicit assertions after the scan tests in `tests/vdb-test.cla` (declare `var cdb: Database` if no reusable Database var is free):

```
    // --- header cache coherence --------------------------------------
    cdb = dbCreate("HDRC", 32, "68BB")
    dbAdd(cdb, "one")
    expect(dbNextRecordId(cdb) == 2, "cached header tracks adds")
    dbAdd(cdb, "two")
    dbDelete(cdb, 1)
    expect(dbRecordCount(cdb) == 1 and dbNextRecordId(cdb) == 3, "cached header tracks delete + add")
    dbClose(cdb)
    cdb = dbOpen("HDRC", "68BB")
    expect(dbIsOpen(cdb) and dbRecordCount(cdb) == 1, "reopen reseeds the cache from disk")
    dbClose(cdb)
```

- [ ] **Step 2: Run to verify current behavior passes (baseline)**

Same single-suite command as Task 2 Step 2. Expected: PASS (these assertions hold pre-change too — they guard the cache against regressions).

- [ ] **Step 3: Implement the cache**

At the top of vdb.cla's header section:

```
// Cached header pages by database name. Every header write goes
// through dbWriteHeader, which refreshes the entry, so commits,
// rollbacks and recovery keep the cache current; open/close drop it.
var dbHdrCache: map of text

func dbHdrCacheDrop(name: string) {
    if dbHdrCache.has(name) { dbHdrCache.remove(name) }
}
```

Rewrite `dbReadHeader` (serve a **copy** — callers mutate their `hdr`; assignment would alias):

```
func dbReadHeader(db: Database, hdr: text): bool {
    var f: filehandle = db.data
    var c: text
    if dbHdrCache.has(db.name) {
        c = dbHdrCache[db.name]
        hdr.clear()
        hdr.append(c)
        return true
    }
    if not f.readAt(0, dbPageSize, hdr) { return false }
    if hdr.length != dbPageSize { return false }
    if hdr[0] != 'V' or hdr[1] != 'D' or hdr[2] != 'B' or int(hdr[3]) != 0 { return false }
    if hdr.wordAt(4) != 2 { return false }
    c.append(hdr)
    dbHdrCache[db.name] = c
    return true
}
```

Rewrite `dbWriteHeader` (store a fresh copy — never alias the caller's buffer):

```
func dbWriteHeader(db: Database, hdr: text): bool {
    var f: filehandle = db.data
    var c: text
    if not f.writeAt(0, hdr) { return false }
    c.append(hdr)
    dbHdrCache[db.name] = c
    return true
}
```

In `dbOpen`: add `dbHdrCacheDrop(name)` as the first statement. In `dbClose`: add `dbHdrCacheDrop(db.name)` before closing handles. In `dbCompact` and `dbCompactFail`: read both functions; add `dbHdrCacheDrop(db.name)` at their entry unless every path already routes through `dbOpen`/`dbClose` (verify by reading — if compaction reopens via `dbOpen`, the drop there suffices, but the entry-drop is one harmless line; prefer adding it).

Audit: `grep -n "writeAt(0" vdb.cla` must show only `dbWriteHeader`'s line. `grep -n "readAt(0" vdb.cla` hits besides `dbReadHeader` (e.g. in recovery) must be checked: a raw read of page 0 that bypasses the cache is fine (reads disk truth); a raw **write** is not — route it through `dbWriteHeader` or drop the cache entry beside it.

- [ ] **Step 4: Run to verify it passes**

Single-suite command, then `scripts/test.sh` (postsdb/maildb/filesdb/heap/maint suites all hammer header paths). Expected: all suites pass.

- [ ] **Step 5: Commit**

```sh
git add vdb.cla tests/vdb-test.cla
git commit -m "Cache vDB header pages in memory; every dbWriteHeader refreshes the entry, open/close drop it."
```

---

### Task 4: boards.cla — picker, post list, backfill, network memo

**Files:**
- Modify: `boards.cla` (`drawBoardPicker` ~line 101, `boardPickerCells` ~line 75, `boardsBackfillLastPost` ~line 52, `drawPostList` ~line 190)

**Interfaces:**
- Consumes: `dbScanStart`/`dbScanNext`/`dbScanSkip` (Task 2); existing `boardsDb`, `postsDb`, `postsOpen`, `postsNextId`, `boardTouch`, `loadNetwork`, `network` global, `bOffLastPost`, `pOffCreated`, `pOffSubject`, `pOffSender`, `boardRecordSize` (checks subsumed by dbScanNext).
- Produces: `networkNameFor(netId: int): string` plus module vars `netMemoIds: list of int`, `netMemoNames: list of string` (private to boards.cla).

- [ ] **Step 1: Add the network memo**

Above `boardPickerCells`:

```
// Network names looked up once per draw: the picker shows the same
// network on most rows.
var netMemoIds: list of int
var netMemoNames: list of string

func networkNameFor(netId: int): string {
    var i: int = 0
    var name: string
    while i < netMemoIds.count {
        if netMemoIds[i] == netId { return netMemoNames[i] }
        i = i + 1
    }
    name = intStr(netId)
    if loadNetwork(netId) { name = network.name }
    netMemoIds.add(netId)
    netMemoNames.add(name)
    return name
}
```

In `boardPickerCells`, replace the network branch:

```
    netId = rec.intAt(bOffNetwork)
    if netId == 0 {
        cells.add("local")
    } else {
        cells.add(networkNameFor(netId))
    }
```

- [ ] **Step 2: Convert drawBoardPicker**

Replace the probe loop (keep header/footer/timing lines as they are; add `var cur: text`, delete `var nextId`, keep `var id`, `var rec`):

```
    netMemoIds.clear()
    netMemoNames.clear()
    sendTableHeader("Bulletin Boards", cells, w)
    if dbScanStart(boardsDb, cur, 1, false) {
        id = dbScanNext(boardsDb, cur, rec)
        while id != 0 {
            boardPickerCells(id, rec, cells)
            sendLine(rowLine(cells, w))
            id = dbScanNext(boardsDb, cur, rec)
        }
    }
```

- [ ] **Step 3: Convert drawPostList**

Replace the probe loop (add `var cur: text`; the `skip` var stays; delete `var id: int = postsNextId() - 1` initializer — plain `var id: int`):

```
    postIds.clear()
    postListWidths(w)
    cells.add("#")
    cells.add("Subject")
    if terminal.columns >= minimumWideTerminalWidth {
        cells.add("From")
        cells.add("Date")
    }
    sendTableHeader(board.name, cells, w)
    if dbScanStart(postsDb, cur, postsNextId() - 1, true) {
        dbScanSkip(postsDb, cur, skip)
        id = dbScanNext(postsDb, cur, rec)
        while id != 0 and postIds.count < pageRows {
            postIds.add(id)
            cells.clear()
            cells.add(intStr(postIds.count))
            cells.add(dbExtractString(rec, pOffSubject))
            if terminal.columns >= minimumWideTerminalWidth {
                cells.add(dbExtractString(rec, pOffSender))
                cells.add(dateTimeStr(rec.intAt(pOffCreated)))
            }
            sendLine(rowLine(cells, w))
            if postIds.count < pageRows {
                id = dbScanNext(postsDb, cur, rec)
            } else {
                id = 0
            }
        }
    }
```

- [ ] **Step 4: Convert boardsBackfillLastPost (collect-then-mutate)**

Replace the whole function:

```
// Fill in lastPost for boards that predate the field (0): the newest
// surviving post's date. Run once at launch; a board that really has
// no posts is rescanned each launch, cheaply. Board IDs are collected
// first -- boardTouch writes the Boards database, and a scan must not
// see writes.
func boardsBackfillLastPost() {
    var cur: text
    var rec: text
    var todo: list of int
    var i: int = 0
    var id: int
    if dbScanStart(boardsDb, cur, 1, false) {
        id = dbScanNext(boardsDb, cur, rec)
        while id != 0 {
            if rec.intAt(bOffLastPost) == 0 { todo.add(id) }
            id = dbScanNext(boardsDb, cur, rec)
        }
    }
    while i < todo.count {
        if postsOpen(todo[i]) and dbScanStart(postsDb, cur, postsNextId() - 1, true) {
            id = dbScanNext(postsDb, cur, rec)
            if id != 0 { boardTouch(todo[i], rec.intAt(pOffCreated)) }
        }
        i = i + 1
    }
    postsClose()
}
```

- [ ] **Step 5: Compile, full tests, commit**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla && scripts/build.sh && scripts/test.sh
git add boards.cla
git commit -m "Board picker, post list and lastPost backfill enumerate via scan cursors; network names memoized per draw."
```

---

### Task 5: files.cla + filesdb.cla — area picker, file list, counts

**Files:**
- Modify: `files.cla` (`drawAreaPicker` ~line 56, `visibleFileCount` ~line 142, `drawFileList` ~line 174)
- Modify: `filesdb.cla` (`pendingFileCount` ~line 223)

**Interfaces:**
- Consumes: Task 2's scan API; existing `areasDb`, `filesDb`, `filesNextId`, `areaVisible(rec)`, `fileVisible(rec)`, `fOffFlags`, `fileFlagPending`, `filesName`, `areasNextId`.

- [ ] **Step 1: Convert drawAreaPicker**

Replace the probe loop (add `var cur: text`, delete `var nextId`):

```
    sendTableHeader("File Areas", cells, w)
    if dbScanStart(areasDb, cur, 1, false) {
        id = dbScanNext(areasDb, cur, rec)
        while id != 0 {
            if areaVisible(rec) {
                cells.clear()
                cells.add(intStr(id))
                cells.add(dbExtractString(rec, aOffName))
                if terminal.columns >= minimumWideTerminalWidth {
                    cells.add(dbExtractString(rec, aOffDescription))
                }
                sendLine(rowLine(cells, w))
            }
            id = dbScanNext(areasDb, cur, rec)
        }
    }
```

- [ ] **Step 2: Convert visibleFileCount**

```
// Files visible to the current caller (pending hidden from non-sysops).
func visibleFileCount(): int {
    var cur: text
    var rec: text
    var n: int = 0
    var id: int
    if not dbScanStart(filesDb, cur, 1, false) { return 0 }
    id = dbScanNext(filesDb, cur, rec)
    while id != 0 {
        if fileVisible(rec) { n = n + 1 }
        id = dbScanNext(filesDb, cur, rec)
    }
    return n
}
```

- [ ] **Step 3: Convert drawFileList (manual skip — the pending filter)**

Replace the probe loop (add `var cur: text`; keep `skip`; `var id: int` plain):

```
    fileNumIds.clear()
    fileListWidths(w)
    cells.add("#")
    cells.add("Name")
    if terminal.columns >= minimumWideTerminalWidth {
        cells.add("Size")
        cells.add("Description")
    }
    sendTableHeader(area.name, cells, w)
    if dbScanStart(filesDb, cur, filesNextId() - 1, true) {
        id = dbScanNext(filesDb, cur, rec)
        while id != 0 and fileNumIds.count < pageRows {
            if fileVisible(rec) {
                if skip > 0 {
                    skip = skip - 1
                } else {
                    fileNumIds.add(id)
                    cells.clear()
                    cells.add(intStr(fileNumIds.count))
                    cells.add(dbExtractString(rec, fOffName))
                    if terminal.columns >= minimumWideTerminalWidth {
                        cells.add(sizeStr(rec.intAt(fOffSize)))
                        cells.add(dbExtractString(rec, fOffDescription))
                    }
                    sendLine(rowLine(cells, w))
                }
            }
            if fileNumIds.count < pageRows {
                id = dbScanNext(filesDb, cur, rec)
            } else {
                id = 0
            }
        }
    }
```

- [ ] **Step 4: Convert pendingFileCount's inner loop (filesdb.cla)**

Keep the outer `aid` loop (it enumerates area *files on disk*, not DB records); replace the inner probe (add `var cur: text` to the var block, drop `id`'s initializer usage accordingly):

```
        if dbIsOpen(db) {
            if dbScanStart(db, cur, 1, false) {
                id = dbScanNext(db, cur, rec)
                while id != 0 {
                    if (rec.intAt(fOffFlags) & fileFlagPending) != 0 { n = n + 1 }
                    id = dbScanNext(db, cur, rec)
                }
            }
            dbClose(db)
        }
```

- [ ] **Step 5: Compile, tests, commit**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla && scripts/build.sh && scripts/test.sh
git add files.cla filesdb.cla
git commit -m "File-area picker, file list and pending counts enumerate via scan cursors."
```

---

### Task 6: sysop.cla — the five paged lists

**Files:**
- Modify: `sysop.cla` (`nextLiveId` ~line 364 deleted, `finishListPage` ~line 377, `drawUserListPage` ~line 416, `drawBoardListPage` ~line 490, area list page ~line 1225, game list page ~line 1620, network list page ~line 2019)

**Interfaces:**
- Consumes: Task 2's scan API.
- Produces: `finishListPage(db: Database, menuScreen: string, w: list of int)` — **signature change**: the `nextId`/`size` parameters go away; all five call sites updated in this task.

- [ ] **Step 1: Replace nextLiveId + finishListPage**

Delete `nextLiveId` entirely. Replace `finishListPage`:

```
// Close a page: bottom rule, then the more-prompt (staying on the list
// screen) or, when no live records remain, back to `menuScreen`.
func finishListPage(db: Database, menuScreen: string, w: list of int) {
    var cur: text
    sendRule(BottomLeft, BottomCenter, BottomRight, w)
    if dbScanStart(db, cur, listFromId, false) and dbScanSkip(db, cur, 1) == 1 {
        sendData("[Enter] More  [Q] Menu > ")
    } else {
        user.screen = menuScreen
        displayPrompt()
    }
}
```

- [ ] **Step 2: Convert the five draw*ListPage loops**

Each follows the same mechanical rewrite; apply it to all five, then compile. For `drawUserListPage` (add `var cur: text`, delete `var nextId`):

```
    sendTableHeader("Users", cells, w)
    if dbScanStart(usersDb, cur, listFromId, false) {
        id = dbScanNext(usersDb, cur, rec)
        while id != 0 and shown < pageRows {
            cells.clear()
            cells.add(intStr(id))
            cells.add(dbExtractString(rec, uOffName))
            cells.add(accessName(rec.intAt(uOffAccess)))
            if terminal.columns >= minimumWideTerminalWidth {
                if rec.intAt(uOffLastSeen) != 0 {
                    cells.add(dateTimeStr(rec.intAt(uOffLastSeen)))
                } else {
                    cells.add("Never")
                }
                cells.add(dbExtractString(rec, uOffEmail))
            }
            sendLine(rowLine(cells, w))
            shown = shown + 1
            listFromId = id + 1
            if shown < pageRows {
                id = dbScanNext(usersDb, cur, rec)
            } else {
                id = 0
            }
        }
    }
    finishListPage(usersDb, "sysopusers", w)
```

For `drawBoardListPage`: same shape; row body is `boardRowCells(id, rec, cells)` + `sendLine(rowLine(cells, w))`; footer `finishListPage(boardsDb, "sysopboards", w)`.

For the area list page (~1225): row body is the existing cells block over `aOffName`/`aOffDescription`/`areaAccessName(rec[aOffAccess])`; footer `finishListPage(areasDb, "sysopareas", w)`.

For the network list page (~2019): row body is the existing cells block over `nOffName`/`addressAt(rec, nOffAddr)`/`addressAt(rec, nOffUplink)`/`pollResultName(int(rec[nOffLastResult]))`; footer `finishListPage(networksDb, "sysopnets", w)`.

For the game list page (~1620): the rows go through `loadGame(id)` (the `game` global), not `rec` — keep `loadGame(id)` in the row body, driven by the scanned `id` (`if loadGame(id) { ...cells from game.*... }`; the extra dbFind per row is fine for a sysop-only screen of a handful of games); footer `finishListPage(gamesDb, "sysopgames", w)`. The scan still needs a `var rec: text` for `dbScanNext`.

The `listFromId = id + 1` line replaces the old post-loop `listFromId = id`; every converted list sets it per emitted row exactly as shown for users.

- [ ] **Step 3: Compile, tests, commit**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla && scripts/build.sh && scripts/test.sh
git add sysop.cla
git commit -m "Sysop paged lists enumerate via scan cursors; nextLiveId probing removed."
```

---

### Task 7: walldb.cla + games/basic.cla

**Files:**
- Modify: `walldb.cla` (`recentWallIds` ~line 79)
- Modify: `games/basic.cla` (`loadGameIds` ~line 123)

**Interfaces:**
- Consumes: Task 2's scan API; existing `wallDb`, `gamesDb`, `loadGame`, `game` global.

- [ ] **Step 1: Convert recentWallIds**

```
// The newest n entry IDs, newest first.
func recentWallIds(n: int, ids: list of int) {
    var cur: text
    var rec: text
    var id: int
    ids.clear()
    if not dbScanStart(wallDb, cur, dbNextRecordId(wallDb) - 1, true) { return }
    id = dbScanNext(wallDb, cur, rec)
    while id != 0 and ids.count < n {
        ids.add(id)
        if ids.count < n {
            id = dbScanNext(wallDb, cur, rec)
        } else {
            id = 0
        }
    }
}
```

- [ ] **Step 2: Convert loadGameIds**

```
func loadGameIds() {
    var cur: text
    var rec: text
    var id: int
    gameIds.clear()
    if not dbScanStart(gamesDb, cur, 1, false) { return }
    id = dbScanNext(gamesDb, cur, rec)
    while id != 0 {
        if loadGame(id) and game.enabled { gameIds.add(id) }
        id = dbScanNext(gamesDb, cur, rec)
    }
}
```

- [ ] **Step 3: Compile, tests (walldb-test + gamesdb-test cover these), commit**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla && scripts/build.sh && scripts/test.sh
git add walldb.cla games/basic.cla
git commit -m "Wall recents and the games menu enumerate via scan cursors."
```

---

### Task 8: postsdb.cla expirePosts + ftntoss.cla scanBoard

**Files:**
- Modify: `postsdb.cla` (`expirePosts` ~line 231)
- Modify: `ftntoss.cla` (`scanBoard` ~line 341)

**Interfaces:**
- Consumes: Task 2's scan API; existing `postsDb`, `postsOpen`, `loadPost`, `post` global, `pOffCreated`, `postFlagInbound`, `scanClamp`, `scanEchoBody`, `pktAddMsg`, `saveBoard`, `scanBoards`/`scanHigh`/`scanCount`.

- [ ] **Step 1: Convert expirePosts (collect-then-delete)**

```
// Delete every post created before `cutoff` (Mac-epoch seconds; the
// caller computes now() - keepDays * 86400). Scans the headers once,
// collecting doomed IDs first (a scan must not see deletes; 4 bytes
// per ID is fine into the tens of thousands); each delete is
// journaled. Bodies stay in the heap until heapCompact (heap.cla)
// reclaims them. Returns the count, or -1 if the board can't be
// opened; leaves the board open.
func expirePosts(boardId: int, cutoff: int): int {
    var cur: text
    var rec: text
    var doomed: list of int
    var id: int
    var i: int = 0
    var n: int = 0
    if not postsOpen(boardId) { return -1 }
    if dbScanStart(postsDb, cur, 1, false) {
        id = dbScanNext(postsDb, cur, rec)
        while id != 0 {
            if rec.intAt(pOffCreated) < cutoff { doomed.add(id) }
            id = dbScanNext(postsDb, cur, rec)
        }
    }
    while i < doomed.count {
        if dbDelete(postsDb, doomed[i]) { n = n + 1 }
        i = i + 1
    }
    return n
}
```

- [ ] **Step 2: Convert scanBoard's walk**

The loop keeps `loadPost(pid)` for the local-post branch (scanEchoBody and the kludge builders read the `post` global), but the walk itself becomes a scan — deleted IDs are skipped for free and the inbound-prefix `safe` mark advances on live inbound posts exactly as before (a deleted tail below the first local post no longer advances `safe`; immaterial, since the next scan skips deleted entries at no cost). Replace the middle of `scanBoard` (keep the open/log preamble and the `safe > board.lastExported` tail exactly as they are; `var pid`/`var last`/`var safe`/`var localSeen`/`var m` stay, add `var cur: text` and `var rec: text`):

```
    last = postsNextId()
    safe = board.lastExported
    if dbScanStart(postsDb, cur, board.lastExported + 1, false) {
        pid = dbScanNext(postsDb, cur, rec)
        while pid != 0 {
            if loadPost(pid) and (post.flags & postFlagInbound) == 0 {
                localSeen = true
                m = new PktMsg
                m.fromName = scanClamp(post.sender, 35)
                m.toName = "All"
                m.subject = scanClamp(post.subject, 71)
                m.orig = network.addr
                m.dest = network.uplink
                m.attr = 0
                m.date = ftnDateStr(post.created)
                m.area = board.tag
                if pktAddMsg(m, scanEchoBody(pid)) { scanCount = scanCount + 1 }
            } else {
                if not localSeen { safe = pid }
            }
            pid = dbScanNext(postsDb, cur, rec)
        }
    }
```

Note `safe` initialization changes from `pid - 1` to `board.lastExported` (same value, expressed without the pre-loop `pid`).

- [ ] **Step 3: Compile, run the covering suites and the FTN e2e**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla && scripts/build.sh && scripts/test.sh
scripts/ftn-e2e.sh
```
Expected: all suites pass (postsdb-test, maint-test, ftntoss-test cover expiry and scan); ftn-e2e completes a full poll.

- [ ] **Step 4: Commit**

```sh
git add postsdb.cla ftntoss.cla
git commit -m "Post expiry and the FTN board scan enumerate via scan cursors (expiry collects IDs first)."
```

---

### Task 9: Sweep audit, docs, final verification

**Files:**
- Modify: `CLAUDE.md` (btree/vdb bullet, boards bullet), `docs/vdb-clarus.md` (scan API + header cache section)
- Verify: whole tree

- [ ] **Step 1: Sweep for leftover probe loops**

```sh
grep -n "NextRecordId\|NextId()" *.cla games/*.cla | grep -v test
```
For each hit, confirm it is either (a) converted, (b) a single-record path, (c) `heap.cla`/compaction — which **stays on ID probing deliberately**: `heapFixOffsets` updates records while iterating, and the no-writes-during-scan rule forbids that; it runs only during maintenance with callers rejected. Add a one-line comment there saying so. Anything else that still probes: convert it in the Task-4 style or record why not.

- [ ] **Step 2: Update docs**

- `docs/vdb-clarus.md`: add a "Scan cursors" section (API signatures, transient/caller-owned/no-writes rule, blob is opaque) and a "Header cache" note (map by name, dbWriteHeader refreshes, open/close drop).
- `CLAUDE.md`: in the `btree.cla`/`vdb.cla` bullet add the scan cursor API + header cache; in the boards bullet note the picker/post list scan + network memo; drop any text claiming enumeration probes IDs.

- [ ] **Step 3: Full verification**

```sh
bin/clarusc --rtdir vendor/runtime/clarus/ bbs.cla
scripts/build.sh
scripts/test.sh
scripts/xmodem-e2e.sh
scripts/ftn-e2e.sh
```
Expected: everything green.

- [ ] **Step 4: Commit**

```sh
git add CLAUDE.md docs/vdb-clarus.md heap.cla
git commit -m "Document the vDB scan cursor API and header cache; note heap compaction deliberately stays on ID probing."
```

- [ ] **Step 5: Measure on the SE**

Deploy to production on request (image swap per the deploy procedure; Andrew launches). Compare the new `Board picker drawn (N ticks).` / `Post list page drawn (N ticks).` lines against the recorded baseline (396 / 347 ticks); target ≤ 150. If the numbers disappoint, the next suspects in order: serial line time (fixed floor ~90 ticks), `dateTimeStr` per row, rowLine string work.
