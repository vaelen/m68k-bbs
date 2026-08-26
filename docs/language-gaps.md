# Clarus Language Gaps for File Areas (from the 68kBBS project)

Language/runtime features the **file-area** feature set still needs from
Clarus. The storage layer (`areasdb.cla`/`filesdb.cla`), the sysop area
menu (`sysop.cla`), the caller-facing browser (`files.cla`), and
XMODEM/XMODEM-1K/YMODEM/ZMODEM transfers in both directions
(`xmodem.cla`, `zmodem.cla`) are all built and working on today's toolchain; what follows is what
the *remaining* file-area work — sysop import, area-folder management,
deletion cleanup, and faithful Mac-file preservation — needs
that the language does not yet provide.

Normative API details, once shipped, live in
`docs/clarus-language-reference.md`. The earlier record of already-shipped
gaps (positioned file I/O, CRC16, LE accessors, `string(n)`, etc.) is in
git history; every one of those landed and is in the pinned toolchain.

## Already possible — no new feature required

Worth stating so these aren't re-filed:

- **Data-fork upload and download over the modem.** Shipped: XMODEM,
  XMODEM-1K, YMODEM and ZMODEM run in both directions on today's
  toolchain (`xmodem.cla`, `zmodem.cla`, `docs/file-transfers.md`) — protocol framing is a
  *library*, not a language feature, and `every N ticks` timers cover
  the ACK/NAK timeouts.
- **Transfer CRCs.** `text.crc16x` (CRC-16/XMODEM) and `text.crc32`
  (ZMODEM's) shipped 2026-08-25 (§8 below records the as-shipped
  contract and the measured speed); `xmodem.cla` uses `crc16x`.
- **Capturing a data-fork file's size at import.** `file.open` then
  `size()` works today (it just leaves a handle open briefly).

**Spike answered** (2026-08-26, Clarus filesystem-api phase Task 1):
both path forms open natively with no code changes. A nested
partial path (`:ProbeA:B:x.dat`, multiple levels deep, not just one)
round-tripped create/write/close/open/size; a full path built from
`PBGetVolSync`'s own volume name (`vol + ":ProbeA:B:x.dat"`) also
opened successfully. Verified only on Mini vMac/System 6, against the
probe's own boot volume — a second, non-boot mounted volume and System
7 (Snow) were never exercised, so treat the full-path answer as
"confirmed on the boot volume, System 6" rather than exhaustively
proven. If a second-volume or System-7 difference ever turns up, areas
can still fall back to staying flat next to the app. `docs/fidonet.md`'s
own spike list (nested partial paths, host-lane
`ReadDateTime`/`SecondsToDate`/`DateToSeconds` glue) is satisfied by
the same phase — see that doc's own updated note.

## Needed features, roughly by value

### 1. Directory listing / folder enumeration — SHIPPED

Enumerate the files in a folder — names at minimum, ideally with size and
Finder type. No such call exists (`file.*` can only open a path it is
already given).

- **Unlocks:** the sysop import flow *browsing* a folder instead of
  typing exact filenames; pointing an area at an existing folder or a
  whole CD-ROM of shareware and having its files appear; detecting files
  a sysop dropped into an area's folder in the Finder.
- **Shape:** an iterator or a `list of` over a directory path, e.g.
  `file.list(path, entries): bool`.
- **Toolbox:** `PBGetCatInfo` with `ioFDirIndex` stepping.
- Highest-value gap: without it the "point an area at a folder of files"
  use case in `docs/files.md` can't be realized; everything must be
  registered by hand.
- **Shipped** (2026-08-26) — as shipped: `file.list(path, names: list of
  string): bool`. Names only, catalog order, both files and folders,
  `""` for the program's own folder; a non-folder `path` is a failure.
  Names-only (no size/type in the same call) — pair with item 2's
  `file.info(path)` per entry for size/type/dates.

### 2. File metadata query without a full open — SHIPPED

Read a file's attributes by path: data- and resource-fork sizes, Finder
type/creator, and created/modified dates. Today only the data-fork size
is reachable, and only by opening the file.

- **Unlocks:** import capturing an accurate size *and* the real
  type/creator; the MacBinary header fields (below); a listing that can
  show the size of an on-disk file not yet in the database.
- **Shape:** `file.info(path, info): bool` filling a record
  (dataSize, rsrcSize, type, creator, created, modified).
- **Toolbox:** `PBGetFInfo`/`PBGetCatInfo` — `PBGetFInfoSync` is already
  vendored in `vendor/toolbox/files.cla`, so the groundwork is laid.
- **Shipped** (2026-08-26) — as shipped: `file.info(path): FileInfo`.
  Note the shape changed from the request above: it RETURNS the
  predeclared `FileInfo` record directly (`size`, `rsrcSize`, `type`,
  `creator`, `created`, `modified`, `isDir`) rather than filling an
  out-param and returning `bool`; on failure it returns a zeroed record
  and sets `lastError`. `file.exists(path): bool` shipped alongside it
  (never sets `lastError` — `false` just means "doesn't exist").

### 3. Delete a file — SHIPPED

Remove a file by path. There is no delete in the `file` namespace at all.

- **Unlocks:** removing the physical file when a sysop deletes a file
  entry; removing an area's `ARE<nn>` database files (and its folder) on
  area deletion; discarding a rejected pending upload. Today every delete
  path leaves the on-disk file (and, for areas, the whole `ARE<nn>` set)
  orphaned — noted as a `ponytail:` in `sysop.cla`/`files.cla`.
- **Shape:** `file.delete(path): bool`.
- **Toolbox:** `PBDelete`/`FSDelete`.
- **Shipped** (2026-08-26) — as shipped: `file.delete(path): bool`,
  matching the shape above exactly. Removes a file or an *empty*
  folder; a non-empty folder is a failure, and on the Macintosh an open
  file is too (`fBsyErr`). Area-folder deletion (`ARE<nn>` + the
  folder itself) still needs the folder emptied first, one call each.

### 4. Arbitrary-file resource-fork access as bytes

Read a *named file's* entire resource fork into a `text`, and write a
`text` as a file's resource fork alongside an existing data fork. The
current pair is narrower: `writeRes` writes a fork but leaves the data
fork empty (whole-file), and `readResource` reads a *named resource from
the current resource chain*, not an arbitrary file's fork as a blob.

- **Unlocks:** MacBinary encode on download / decode on upload — i.e.
  transferring *real* Mac files (applications, documents with icons and
  preferences) faithfully. Without it, file areas can only carry
  flat/data-fork content, which rules out most period Mac software.
- **Shape:** `file.readResFork(path, out): bool` /
  `file.writeResFork(path, fork): bool` (data fork preserved), the
  fork-level counterparts to `readText`/`writeText`.
- **Toolbox:** open the resource fork via `PBHOpenRF`, then `readAt`-style
  positioned reads.

### 5. Set an existing file's Finder type/creator (and dates) — SHIPPED

`file.create` stamps type/creator only at creation; there is no way to
change them on an already-written file.

- **Unlocks:** a MacBinary-decoded upload getting its real
  type/creator/dates so it launches or opens correctly in the Finder;
  correcting a file's Finder identity from the sysop menu.
- **Shape:** `file.setInfo(path, type, creator, created, modified): bool`.
- **Toolbox:** `PBSetFInfo` — `PBSetFInfoSync` is already vendored in
  `vendor/toolbox/files.cla`.
- **Shipped** (2026-08-26) — as shipped: `file.setInfo(path, type,
  creator, created, modified): bool`, matching the shape above exactly.
  A `0` date argument means "leave that date unchanged"; `type`/
  `creator` follow the same 4-character literal rule as `writeText`.
  Host-lane caveat: `created` is accepted and ignored there (POSIX
  birth time is not settable) — only `modified` actually restamps a
  host-built file.

### 6. Create a directory — SHIPPED

Make a folder by path. No mkdir exists.

- **Unlocks:** the New Area wizard creating the area's folder itself,
  instead of requiring the sysop to make it in the Finder first — and
  auto-creating a per-area *pending uploads* subfolder.
- **Shape:** `file.makeDir(path): bool`.
- **Toolbox:** `PBDirCreate`.
- **Shipped** (2026-08-26) — as shipped: `file.makeDir(path): bool`,
  matching the shape above exactly. Creates exactly one level — the
  parent must already exist — so a New Area wizard creating
  `:Files:NewArea` still needs `:Files` to exist first; no recursive
  `mkdir -p` form (filed as a follow-up in Clarus's own `docs/TODO.md`).

### 7. Rename / move a file — SHIPPED

Rename in place, and move between folders. No such call exists.

- **Unlocks:** the upload-to-temp-then-commit pattern; moving an approved
  upload out of a pending holding folder into the live area; renaming a
  file from the sysop menu.
- **Shape:** `file.rename(oldPath, newPath): bool` (same-volume move via
  a differing parent path).
- **Toolbox:** `PBRename` / `PBCatMove`.
- Nice-to-have: uploads can write straight to the final path, so this is
  a convenience rather than a blocker.
- **Shipped** (2026-08-26) — as shipped, split into TWO calls rather
  than the combined single call sketched above: `file.rename(path,
  newName): bool` (leaf name only, not a path — renames in place) and
  `file.move(path, dirPath): bool` (moves into folder `dirPath`,
  keeping its existing name; same volume only, `badMovErr` otherwise).
  A caller wanting both (move to a new folder AND rename) issues both
  calls; there is no atomic combined form (filed as a follow-up in
  Clarus's own `docs/TODO.md`).

### 8. Optimized transfer CRCs: `text.crc16x` and `text.crc32` — SHIPPED

**Shipped** in the pinned toolchain (2026-08-25); `xmodem.cla` uses
`text.crc16x`. Kept for the record:

`text.crc16(h, pos, n)` implements exactly one algorithm, CRC-16/KERMIT
(reflected `0x8408`). XMODEM and YMODEM use the *other* common CRC-16 —
poly `0x1021` forward (non-reflected), init 0, no final XOR, check value
`0x31C3` over `"123456789"` — and ZMODEM's default framing uses CRC-32
(reflected `0xEDB88320`, init and final XOR `0xFFFFFFFF`, check value
`0xCBF43926`).

- **Shape (as shipped):** `t.crc16x(h, pos, n): int` and
  `t.crc32(h, pos, n): int` — same signature, chunking, and strict
  range rule as `crc16`. `crc32` returns the raw register: the caller
  seeds `0xFFFFFFFF` and applies the final XOR once at the end of a
  chunked run (`t.crc32(0xFFFFFFFF, 0, 9) ^ 0xFFFFFFFF == 0xCBF43926`),
  so all three compose the same way. The result is an ordinary signed
  `int` — `0xCBF43926` is negative as an `int`, and hex literals above
  `0x7FFFFFFF` wrap the same way, so comparisons against published check
  values work as written.
- **What the request got wrong, for the record:** the Clarus runtime is
  itself Clarus (`runtime/clarus/text.cla`, compiled by the same
  backends as user code), not "C/68k" — a builtin's edge over a library
  loop is the unchecked `peekb` on the dereferenced master pointer per
  byte, not a different language. And the `crc32` table is not a
  build-time constant: Clarus has no array-literal initializer (filed in
  the compiler's `docs/TODO.md`), so it is a 1 KB heap block built on
  the first `crc32` call and kept for the process; `crc16x` stayed a
  bitwise loop by design (128-byte XMODEM blocks are cheap either way).
- **Measured** (Snow, Mac II, 16 MHz 68020, one 64 KB buffer, single
  run): `crc16` 277 ticks, `crc16x` 287, `crc32` 120 — the table is
  ≈2.3× faster per byte (≈30 µs vs ≈70 µs), so a 1 KB ZMODEM subpacket
  costs ≈31 ms of the ≈180 ms it takes to arrive at 57600 bps (≈72 ms
  with a bitwise loop). Less than a table's theoretical win — per-byte
  loop overhead dominates on a 68020 — but comfortably inside the
  event-loop budget.
- **Former workaround:** `crcXmodem` in `xmodem.cla` (bitwise, 128×8
  iterations per block) — replaced by `t.crc16x(0, 0, n)`.

## Summary

| # | Feature | Blocks which file-area feature | Toolbox |
|--:|---------|-------------------------------|---------|
| 1 | Directory listing — shipped | Import-by-browse; folder/CD-ROM areas | PBGetCatInfo |
| 2 | File metadata query — shipped | Accurate import; MacBinary headers | PBGetFInfo |
| 3 | Delete a file — shipped | Physical delete on file/area removal | PBDelete |
| 4 | Resource-fork bytes | MacBinary — real Mac files, not just data forks | PBHOpenRF |
| 5 | Set type/creator/dates — shipped | Correct Finder identity after decode | PBSetFInfo |
| 6 | Create a directory — shipped | Wizard-created area folders | PBDirCreate |
| 7 | Rename / move — shipped (two calls) | Pending→approved holding-area workflow | PBRename |
| 8 | `text.crc16x` / `text.crc32` — shipped | Fast XMODEM CRC; ZMODEM | — (pure runtime) |

Data-fork transfers (1‑to‑1 with the modem) need **none** of these.
Items 1, 2, 3, 5, 6, 7 shipped in the Clarus filesystem-api phase
(2026-08-26, `runtime/clarus/prelude.cla`'s `FileInfo` record + the
`file.*` directory/catalog family, both lanes); item 8 (the CRCs)
shipped 2026-08-25; the HFS full-path spike (above) is answered. Item 4
(resource-fork bytes / MacBinary) is the only feature on this list
still unshipped — it is what makes file areas able to carry genuine
Macintosh software rather than flat files.
