# Message Board Databases

How 68kBBS stores message boards and posts, as implemented by
`boardsdb.cla` and `postsdb.cla` on top of vDB
(`docs/vdb-clarus.md` for the engine's on-disk format; `docs/vdb.md`
for its design). Pre-v1: no backward compatibility is promised —
data structures may change freely, always starting from a clean
database.

## Shape

Two record kinds, deliberately in separate databases:

- **One `Boards` database** defines the boards. Its vDB record ID is
  the board ID.
- **One posts database per board** (`BRD<nn>.*`), plus a per-board
  body heap (`BRD<nn>.MSG`). Because each board owns its files, posts
  never need a board-ID field or index — the board is the file.

The per-board split also keeps each database small (fast index
rebuilds on a 68k), lets a board be archived or deleted by removing
its files, and maps one-to-one onto the future echomail model, where
a board is a Fidonet-style echo.

## The Boards database

Files: `Boards.DAT` / `Boards.IDX` / `Boards.JNL`. Fixed 160-byte
records, no secondary indexes (board lists are tiny; lookups scan).

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 64 | name | Pascal string, ≤ 63 chars |
| 64 | 64 | description | Pascal string, ≤ 63 chars — the board-list one-liner |
| 128 | 16 | network | Pascal string, ≤ 15 chars; `"local"` for now |
| 144 | 16 | reserved | zero |

- **Board ID** = the vDB record ID: dense, starting at 1, never
  reused. Enumerate boards by probing `loadBoard` over
  `1 .. boardsNextId()-1`.
- **network** exists so Fidonet-style echomail can be added later
  without a format change: a networked board will carry its network's
  name here, and the tosser can find its boards by scanning. Until
  then every board is `"local"`.

API (`boardsdb.cla`): `boardsOpen` / `boardsClose`,
`createBoard(name, description, network): int`, `loadBoard(id)` into
the global `board`, `boardCount`, `boardsNextId`.

## A board's posts

Files per board, named from the board ID (`postsName`: `BRD` + two
decimal digits, so board IDs are 1–99 — a guard `postsOpen` enforces):

- `BRD<nn>.DAT` / `.IDX` / `.JNL` — post header records in vDB
- `BRD<nn>.I00` — secondary index on the thread-ID field
- `BRD<nn>.MSG` — the body heap (a plain file, not a vDB database)

This is the classic message-base split (Hudson, Squish, and JAM all
separate fixed headers from packed message text): fixed-size records
give cheap indexed lookups, the heap gives exact-fit variable-length
bodies with no per-post slack.

### Post header record (160 bytes, vDB record ID = post ID)

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 64 | sender | Pascal string, ≤ 63 chars — a **name**, not a user ID, so echomail senders need not be local users |
| 64 | 4 | created | i32, Mac-epoch seconds |
| 68 | 4 | thread ID | i32, indexed (IT_ID, `.I00`): 0 = thread starter; otherwise the starter's post ID |
| 72 | 64 | subject | Pascal string, ≤ 63 chars |
| 136 | 4 | body offset | i32, byte offset into `BRD<nn>.MSG` |
| 140 | 4 | body length | i32; 0 = no body (offset then meaningless) |
| 144 | 16 | reserved | zero |

### Threads

A thread starter posts with thread ID 0; every reply carries the
starter's post ID. Reading a thread is therefore: the starter itself
(`dbFind(root)`) plus an index lookup (`dbFindAllByInt` on the
thread field), which returns replies in posting order because a
B-tree key's values accumulate in insertion order. `threadPosts`
packages that as starter-first-then-replies. There is no reply
nesting — threads are flat, like the era's message bases.

### The body heap (`BRD<nn>.MSG`)

An append-only file of raw body bytes, nothing else — no framing, no
lengths, no checksums; the header record's offset/length pair is the
only map into it. Reading a body is one positioned read.

**Write ordering (the one rule that matters):** `addPost` appends the
body and calls `flush()` **before** the journaled header add. Bodies
are never journaled; the ordering means a crash at any point leaves
either a complete post or some orphaned heap bytes that nothing
references — never a header pointing at text that didn't make it to
disk.

**Deletion & compaction:** deleting a post (deleting its header
record) orphans its body bytes in the heap; they are not reclaimed.
There is deliberately no heap compactor yet — post deletion is rare,
and compacting the heap means rewriting every surviving header's
offset. If heap growth ever matters, the compactor's shape is:
`dbCompact` the headers, then sweep posts in ID order appending each
body to a fresh heap while rewriting offsets via `dbUpdate`, then
swap the files.

### Enumeration

Post IDs are dense and never reused, so "list this board's posts" is
a probe loop over `1 .. postsNextId()-1` (deleted IDs simply miss),
and "newest N" walks backward from `postsNextId()-1`. This leans on
vDB's `dbNextRecordId`; a real cursor API is a tracked TODO in
`docs/vdb-clarus.md`.

## API summary (`postsdb.cla`)

One board open at a time; `postsOpen(boardId)` closes any previous
board, creating the files (with the thread index) on first use.

- `addPost(sender, threadId, subject, body): int` — new post ID or −1
- `loadPost(id): bool` — header into the global `post`
- `postBody(id): text` — body from the heap; empty if none
- `threadPosts(root, ids)` — starter + replies, posting order
- `postCount()`, `postsNextId()`, `postsClose()`

## Capacity notes

- Boards: 99 (two-digit file names; lift by widening `postsName`).
- Post headers: one 512-byte page each (160-byte record), so a board
  with 1,000 posts spends ~500 KB on headers, plus exact body bytes.
- Bodies: no length cap in the format (i32 offset/length); the BBS
  compose flow will set the practical limit.
- Subjects, senders, board names: ≤ 63 chars (64-byte Pascal fields).

## Echomail later (why this design accommodates it)

- `network` on the board record names the echo's network; local
  boards stay `"local"`.
- `sender` is a display name, not a user-ID reference, so imported
  posts need no local account.
- Reserved header bytes (144–159) have room for an origin address /
  MSGID hash when tossing arrives.
- Per-board files mean a tosser imports into exactly one database and
  one heap, using the same `addPost` path (and its crash-ordering
  rule) as local posting.
