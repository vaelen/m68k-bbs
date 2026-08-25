# Clarus Language Gaps for File Areas (from the 68kBBS project)

Language/runtime features the **file-area** feature set still needs from
Clarus. The storage layer (`areasdb.cla`/`filesdb.cla`), the sysop area
menu (`sysop.cla`), the caller-facing browser (`files.cla`), and
XMODEM/XMODEM-1K/YMODEM transfers in both directions (`xmodem.cla`)
are all built and working on today's toolchain; what follows is what
the *remaining* file-area work — sysop import, area-folder management,
deletion cleanup, ZMODEM, and faithful Mac-file preservation — needs
that the language does not yet provide.

Normative API details, once shipped, live in
`docs/clarus-language-reference.md`. The earlier record of already-shipped
gaps (positioned file I/O, CRC16, LE accessors, `string(n)`, etc.) is in
git history; every one of those landed and is in the pinned toolchain.

## Already possible — no new feature required

Worth stating so these aren't re-filed:

- **Data-fork upload and download over the modem.** Shipped: XMODEM,
  XMODEM-1K and YMODEM run in both directions on today's toolchain
  (`xmodem.cla`, `docs/file-transfers.md`) — protocol framing is a
  *library*, not a language feature, and `every N ticks` timers cover
  the ACK/NAK timeouts. ZMODEM waits only on `crc32` (§8 below).
- **XMODEM's CRC.** `text.crc16` is CRC-16/KERMIT, not XMODEM's; a
  ten-line bitwise loop in `xmodem.cla` covers it for now. The
  optimized builtin is §8 below — a speed-up, not a blocker.
- **Capturing a data-fork file's size at import.** `file.open` then
  `size()` works today (it just leaves a handle open briefly).

One open question here is not a language gap but a **spike**: confirm on
Snow that `file.open` accepts an HFS full path (`BBS HD:Files:x`). The
partial-path form (a leading colon: an area folder of `:files`) is in
live use and works; the full-path form is still unconfirmed. If it
does not work, such areas stay flat next to the app with no format
change.

## Needed features, roughly by value

### 1. Directory listing / folder enumeration

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

### 2. File metadata query without a full open

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

### 3. Delete a file

Remove a file by path. There is no delete in the `file` namespace at all.

- **Unlocks:** removing the physical file when a sysop deletes a file
  entry; removing an area's `ARE<nn>` database files (and its folder) on
  area deletion; discarding a rejected pending upload. Today every delete
  path leaves the on-disk file (and, for areas, the whole `ARE<nn>` set)
  orphaned — noted as a `ponytail:` in `sysop.cla`/`files.cla`.
- **Shape:** `file.delete(path): bool`.
- **Toolbox:** `PBDelete`/`FSDelete`.

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

### 5. Set an existing file's Finder type/creator (and dates)

`file.create` stamps type/creator only at creation; there is no way to
change them on an already-written file.

- **Unlocks:** a MacBinary-decoded upload getting its real
  type/creator/dates so it launches or opens correctly in the Finder;
  correcting a file's Finder identity from the sysop menu.
- **Shape:** `file.setInfo(path, type, creator, created, modified): bool`.
- **Toolbox:** `PBSetFInfo` — `PBSetFInfoSync` is already vendored in
  `vendor/toolbox/files.cla`.

### 6. Create a directory

Make a folder by path. No mkdir exists.

- **Unlocks:** the New Area wizard creating the area's folder itself,
  instead of requiring the sysop to make it in the Finder first — and
  auto-creating a per-area *pending uploads* subfolder.
- **Shape:** `file.makeDir(path): bool`.
- **Toolbox:** `PBDirCreate`.

### 7. Rename / move a file

Rename in place, and move between folders. No such call exists.

- **Unlocks:** the upload-to-temp-then-commit pattern; moving an approved
  upload out of a pending holding folder into the live area; renaming a
  file from the sysop menu.
- **Shape:** `file.rename(oldPath, newPath): bool` (same-volume move via
  a differing parent path).
- **Toolbox:** `PBRename` / `PBCatMove`.
- Nice-to-have: uploads can write straight to the final path, so this is
  a convenience rather than a blocker.

### 8. Optimized transfer CRCs: `text.crc16x` and `text.crc32`

`text.crc16(h, pos, n)` implements exactly one algorithm, CRC-16/KERMIT
(reflected `0x8408`). XMODEM and YMODEM use the *other* common CRC-16 —
poly `0x1021` forward (non-reflected), init 0, no final XOR, check value
`0x31C3` over `"123456789"` — and ZMODEM's default framing uses CRC-32
(reflected `0xEDB88320`, init and final XOR `0xFFFFFFFF`, check value
`0xCBF43926`).

- **Unlocks:** table-driven CRCs in the runtime's C/68k instead of a
  Clarus bit loop per byte. XMODEM's 128-byte blocks are cheap either
  way; ZMODEM streaming at 57600 bps (1 KB subpackets, back to back)
  is where a per-bit Clarus loop starts eating the time budget between
  event-loop passes on a 68020.
- **Shape:** `t.crc16x(h, pos, n): int` and `t.crc32(h, pos, n): int`,
  same signature, chunking, and strict range rule as `crc16`; `crc32`
  returns the raw register (the caller applies the `0xFFFFFFFF`
  init/final XOR, as it does for `crc16`'s seed), so all three compose
  the same way.
- **Current workaround:** `crcXmodem` in `xmodem.cla` (bitwise,
  128×8 iterations per block), to be replaced with `t.crc16x(0, 0, n)`
  when the builtin lands. ZMODEM has no workaround worth writing —
  it waits for `crc32`.

## Summary

| # | Feature | Blocks which file-area feature | Toolbox |
|--:|---------|-------------------------------|---------|
| 1 | Directory listing | Import-by-browse; folder/CD-ROM areas | PBGetCatInfo |
| 2 | File metadata query | Accurate import; MacBinary headers | PBGetFInfo |
| 3 | Delete a file | Physical delete on file/area removal | PBDelete |
| 4 | Resource-fork bytes | MacBinary — real Mac files, not just data forks | PBHOpenRF |
| 5 | Set type/creator/dates | Correct Finder identity after decode | PBSetFInfo |
| 6 | Create a directory | Wizard-created area folders | PBDirCreate |
| 7 | Rename / move | Pending→approved holding-area workflow | PBRename |
| 8 | `text.crc16x` / `text.crc32` | Fast XMODEM CRC (workaround exists); ZMODEM (no workaround) | — (pure runtime) |

Data-fork transfers (1‑to‑1 with the modem) need **none** of these — only
the HFS-path spike; item 8 is a speed-up for XMODEM and a prerequisite
only for ZMODEM. Items 1–3 make the sysop and import experience real;
items 4–5 are what make file areas able to carry genuine Macintosh
software rather than flat files.
