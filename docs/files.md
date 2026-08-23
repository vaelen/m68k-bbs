# File Area Databases

How 68kBBS stores file areas and their file entries, as implemented
by `areasdb.cla` and `filesdb.cla` on top of vDB
(`docs/vdb-clarus.md` for the engine's on-disk format; `docs/boards.md`
for the message-board databases this mirrors). Pre-v1: no backward
compatibility is promised — data structures may change freely, always
starting from a clean database.

The sysop area management (`sysop.cla`) and the caller-facing browser
(`files.cla`) are built on top of the API below; upload/download
transfers are a later step. This document covers the storage layer;
the two UIs are summarized under "The UIs" at the end.

## Shape

File areas are message boards whose "bodies" are real files:

- **One `Areas` database** defines the areas. Its vDB record ID is
  the area ID. Like `Boards`, plus the **folder** where the area's
  physical files live and an access byte.
- **One file-entry database per area** (`ARE<nn>.*`), plus a per-area
  long-description heap (`ARE<nn>.MSG`). Each area owns its files, so
  entries never need an area-ID field or index.
- **The physical file** lives at `<area folder>:<filename>` under its
  own name. The database holds only metadata. The folder is an
  ordinary Finder folder (or a whole volume — a CD-ROM of shareware
  makes a fine area): the sysop can drop files into it and import
  them, and can remove files the same way.

Per-area databases keep each one small, let an area be archived or
removed by deleting its `ARE<nn>` files, and are the layout the
boards UI already knows.

### What Clarus can and cannot do with files

The Clarus file API is `file.open` / `file.create` / `readText` /
`writeText` and positioned `filehandle` I/O. There is **no** delete,
rename, create-directory, directory listing, or exists-without-open.
Consequences that shape this design:

- Entries are never discovered by scanning a folder; the sysop imports
  a file by naming it, and the import opens it to confirm it exists
  and read its size.
- Deleting an entry never deletes the physical file, and deleting an
  area leaves its folder and `ARE<nn>` files behind.
- Folders are created by the sysop in the Finder, not by the BBS.

Filing these as Clarus gaps (delete, listing) would improve the sysop
experience; nothing in the format depends on them.

## The Areas database

Files: `Areas.DAT` / `Areas.IDX` / `Areas.JNL`. Fixed 256-byte
records (one 512-byte page either way), no secondary indexes (area
lists are tiny; lookups scan).

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 64 | name | Pascal string, ≤ 63 chars |
| 64 | 64 | description | Pascal string, ≤ 63 chars — the area-list one-liner |
| 128 | 64 | folder | Pascal string, ≤ 63 chars; HFS path of the area's folder (`BBS HD:Files:Utilities`), no trailing colon. Empty = the app's own directory. |
| 192 | 1 | access | char: `0` = every caller; `'S'` = sysops only. The user record's access encoding, so richer levels later need no format change. |
| 193 | 63 | reserved | zero |

- **Area ID** = the vDB record ID: dense, starting at 1, never
  reused. Enumerate areas by probing `loadArea` over
  `1 .. areasNextId()-1`.
- Area deletion is a plain `dbDelete` on the Areas database.

API (`areasdb.cla`): `areasOpen` / `areasClose`,
`createArea(name, description, folder, access): int`, `loadArea(id)`
into the global `area`, `saveArea()` writing the global `area` back,
`areaCount`, `areasNextId`.

## An area's file entries

Files per area, named from the area ID (`filesName`: `ARE` + two
decimal digits, so area IDs are 1–99 — `filesOpen` enforces it):

- `ARE<nn>.DAT` / `.IDX` / `.JNL` — file header records in vDB
- `ARE<nn>.I00` — secondary index on the filename field
  (case-insensitive, like the `Users` username index)
- `ARE<nn>.MSG` — the long-description heap (a plain file, not a vDB
  database)

### File header record (256 bytes, vDB record ID = file ID)

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 64 | filename | Pascal string, ≤ 63 chars (Mac names are ≤ 31; 64 is the width `itString` indexes). **Indexed case-insensitively**: one entry per name per area, and `findFile(name)` for imports and downloads. |
| 64 | 64 | uploader | Pascal string, ≤ 63 chars — a **name**, not a user ID, so sysop imports and future networked files need no local account |
| 128 | 64 | description | Pascal string, ≤ 63 chars — the listing one-liner |
| 192 | 4 | created | i32, Mac-epoch seconds (upload/import time) |
| 196 | 4 | size | i32 bytes, captured at upload/import so listings never open the file |
| 200 | 4 | downloads | i32 counter |
| 204 | 4 | flags | i32 bit set: bit 0 **pending** (uploaded, awaiting sysop approval — hidden from non-sysops), bit 1 **offline** (sysop marked the physical file missing — listed but not downloadable). Bits 2–31 reserved (e.g. MacBinary-wrapped). |
| 208 | 4 | long-desc offset | i32, byte offset into `ARE<nn>.MSG` |
| 212 | 4 | long-desc length | i32; 0 = none (offset then meaningless) |
| 216 | 40 | reserved | zero |

Filename uniqueness is enforced by the storage layer: `addFile`
returns −1 when `findFile(name)` already hits, and `saveFile` refuses
a rename onto another entry's name. Names are stored as given; the
transfer/import layer rejects names the Mac File Manager cannot take
(colons, > 31 chars, empty — the storage layer rejects only empty).

### The long-description heap (`ARE<nn>.MSG`)

Byte-for-byte the posts rule: raw bytes, no framing; the header's
offset/length pair is the only map. **Write ordering:** `addFile`
appends the description and calls `flush()` **before** the journaled
header add, so a crash leaves either a complete entry or orphaned heap
bytes, never a header pointing at missing text. Deleting an entry
orphans its bytes; there is no compactor (the same deferred shape as
posts). Long descriptions are CR-joined lines, re-wrapped per reader
like post bodies, and immutable once written.

### The physical file

`filePath(id)` = `area.folder + ":" + filename` when the loaded
`area`'s folder is non-empty, else the bare filename (relative to the
app directory, like every database file). `filesdb.cla` never opens
the physical file; only the import/upload/download code does. Files
are stored and served as **data forks**; preserving Mac resource forks
is a transfer-layer (MacBinary) concern the reserved flag bits leave
room for.

### Enumeration

File IDs are dense and never reused: list an area by probing
`loadFile` over `1 .. filesNextId()-1` (deleted IDs miss), newest
first by walking backward, as posts do. Listings skip **pending**
entries unless the caller is a sysop.

## API summary (`filesdb.cla`)

One area open at a time; `filesOpen(areaId)` closes any previous
area, creating the database, name index, and heap on first use.
`filePath` reads the global `area`, so callers `loadArea` first.

- `filesOpen(areaId): bool`, `filesClose()`
- `addFile(name, uploader, description, size, flags, longDesc): int`
  — new file ID, or −1 (including empty or duplicate name)
- `loadFile(id): bool` — header into the global `fileRec`
  (`FileEntry`: id, name, uploader, description, created, size,
  downloads, flags; named `fileRec` because `file` is the Clarus
  namespace)
- `findFile(name): int` — case-insensitive; −1 if none
- `fileLongDesc(id): text` — from the heap; empty if none
- `saveFile(): bool` — write `fileRec` back (downloads, flags,
  description, uploader, name); long description carried over
- `filePath(id): string` — empty if the entry doesn't exist
- `fileCount()`, `filesNextId()`
- Flag consts: `fileFlagPending` (1), `fileFlagOffline` (2)

## Capacity notes

- Areas: 99 (two-digit file names; lift by widening `filesName`).
- File headers: one 512-byte page each.
- Folder path ≤ 63 chars; names, uploaders, descriptions ≤ 63 chars.
- Long descriptions: no format cap (i32 offset/length); the line
  editor sets the practical limit.

## The UIs

Both mirror the message-board screens (`docs/boards.md`), reusing the
same table senders and paging helpers.

- **Sysop** (`sysop.cla`, Sysop menu `F`): a paged area list, a detail
  card, a lettered-field edit card buffered in the global `area`
  (`N`ame / `D`escription / `F`older / `A`ccess; `S` saves via
  `saveArea`, `Q` discards; in edit, `-` clears the folder back to the
  app directory), a Y/N delete over the detail card, and a New Area
  wizard (name → description → folder → access, empty name cancels).
  Deleting an area leaves its `ARE<nn>` files and folder behind.

- **Caller** (`files.cla`, main menu `F`): area picker → paged file
  list → framed file view. Two visibility rules enforced here (the
  storage layer stores everything; the reader filters):
  - **sysop-only areas** (`access == 'S'`) are hidden from, and
    un-enterable by, non-sysop callers;
  - **pending files** (`fileFlagPending`) are hidden from non-sysop
    callers, and excluded from the page count.
  The view shows the metadata card (Name title, From / Date,
  Size / Downloads, then the short description word-wrapped to the
  frame width as the last header line) and the paged long description
  below it. Sysops additionally get
  `D`elete (a `dbDelete` of the header; the physical file and heap
  bytes stay behind, like post deletion). There is no download yet.

## Later steps (what this layout already supports)

- **Import** (sysop types a name): `file.open(filePath)` to verify,
  `size()`, then `addFile`.
- **Upload**: write the received bytes to `filePath`, then `addFile`
  with `fileFlagPending` for sysop review.
- **Download**: `loadFile`, open `filePath`, stream it; then
  `fileRec.downloads + 1` and `saveFile`.
- **Path check**: the first deploy with a non-empty folder should
  confirm on Snow that `file.open` accepts an HFS full path
  (`BBS HD:Files:x`); if not, areas stay flat next to the app (empty
  folder) with no format change.
