# Clarus Language Gaps (from the 68kBBS project)

Features 68kBBS needs (or would benefit from) that Clarus does not have
yet. The driving use case is implementing the vDB database engine
(`~/repos/libvdb/db.md`) in pure Clarus: fixed 512-byte pages, a
write-ahead journal, and B-tree index files. Everything else about vDB
is expressible in Clarus today; the items below are what's missing,
roughly in priority order.

## Required: positioned (random-access) file I/O

The built-in `file` namespace is whole-file only (`readText`,
`writeText`, `save`, `load`). A page-oriented database needs an open
file handle with positioned reads and writes. Doing this with raw
File Manager traps (`PBOpenSync`/`PBReadSync`/`PBWriteSync`/... via
`extern record` param blocks) is possible — the Clarus runtime's own
native file layer works exactly that way — but it puts unsafe-lane
`ptr`/`poke` code at the bottom of the one component where corruption
matters most, and it is Mac-only, so the database engine could never be
tested on the host lane the way `tests/*.cla` run today.

Proposed: a small handle API in the runtime, Mac File Manager traps on
the native lane and stdio on the host lane, following the existing
`file` conventions (`bool` return, details in `lastError`):

```
var f: filehandle                      // new resource type, nil until opened

file.open(path: string, f: filehandle): bool       // existing file, r/w
file.create(path: string, type: string, creator: string, f: filehandle): bool
f.readAt(pos: int, count: int, out: text): bool    // positioned read
f.writeAt(pos: int, data: text): bool              // positioned write
f.append(data: text): bool
f.size(): int                                      // -1 on error
f.setSize(n: int): bool                            // grow or truncate (journal reset)
f.flush(): bool                                    // durability barrier (journal protocol)
f.close()
```

Notes:

- `readAt`/`writeAt` map naturally onto `_Read`/`_Write` with
  `ioPosMode = fsFromStart` + `ioPosOffset` — the Mac File Manager does
  positioned I/O in the param block, so no separate seek is needed.
- `flush` is required for the journal's write-ahead ordering (journal
  entry must be on disk before the data write). `_FlushVol` (or
  `_FlushFile` + `_FlushVol`) on the Mac; `fflush` on the host.
- `setSize` (`_SetEOF`) covers both truncating the journal after commit
  and pre-allocating pages. Runtime note: the Clarus runtime has a
  comment trail about `PBGetEOFSync` misbehaving under a busy heap —
  worth revisiting while implementing `size()`.
- Like `connection`, a `filehandle` should be storable in records and
  arrays so a database handle record can own its open files.

## Nice-to-haves

**CRC16.** vDB uses CRC16 for journal-entry checksums and string index
keys. Easily written in Clarus (bitwise ops exist), but a
`crc16(t: text): int` builtin (or a `t.crc16(pos, n)` sibling of the
existing `t.hashStep`) would be faster on a 68000 and shared by every
program that talks to a binary format.

**Little-endian accessors on `text`.** `t.intAt(pos)` is big-endian
only. vDB files are little-endian, so a pure-Clarus implementation must
assemble every multi-byte field from single bytes. LE siblings —
`t.intAtLE(pos)`, plus 16-bit variants (`t.wordAt`/`t.wordAtLE`) —
would cover binary formats from the LE world (DOS, most modern ones).

**In-place binary patching on `text`.** There are readers (`intAt`,
`stringAt`, `textAt`) but no writers: building a 512-byte page image
currently means byte-by-byte `t[i] = c` assignment. `t.setIntAt(pos,
v)`, `t.setWordAt(pos, v)` (+ LE variants) would make page serialization
symmetric with parsing.

**Int-to-string conversion.** There is no built-in way to render an
`int` as decimal text; every program writes the same `intStr` loop
(this project, `examples/serialecho.cla`, the test kit's
`tkIntToStr`). A builtin (or stdlib function) would remove the most
commonly re-implemented helper in the ecosystem.

**Toolbox include resolution.** `include "toolbox/osutils.cla"` fails
unless the program sits inside the compiler repo; user programs must
spell a relative path to it (this project uses a `clarus-src` symlink).
Since `clarusc` already knows its runtime directory (`--rtdir`), a
fallback that resolves `toolbox/...` includes against the rtdir's
sibling `toolbox/` directory would let programs use the catalog without
knowing where the compiler lives.

**Method calls on connection-typed parameters.** `c.send(...)` where
`c` is a parameter or local fails to build on both backends
("method call on receiver kind 13 not yet implemented"); only globals
work. This forced `termio.cla`'s color functions to hardcode the global
`modem` instead of taking a `connection` argument, and it will bite any
library code that wants to work over "whichever connection you hand
me". (Presumably the same applies to a future `filehandle`.)

**68k backend: string temps per statement.** A longer string
concatenation chain fails `emit68k` with "too many str/rec temps needed
in one statement -- bump cgBigTmpSlots". Check-clean code should not
fail at emit; either raise the cap or spill temps automatically.
