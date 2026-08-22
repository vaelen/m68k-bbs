# Clarus Language Gaps (from the 68kBBS project)

**All resolved.** Every gap this project filed against Clarus has shipped
in the compiler/runtime (pinned here as of 2026-08-23, clarus 671b297).
Kept as a record of what was asked for and what landed; the normative
details are in `docs/clarus-language-reference.md`. The driving use case
was the vDB database engine (`~/repos/libvdb/db.md`).

- [x] **Positioned (random-access) file I/O.** Shipped as the
  `filehandle` resource type: `file.open(path)` / `file.create(path,
  type, creator)` plus `readAt`, `writeAt`, `append`, `size`, `setSize`,
  `flush`, `close`. Mac File Manager traps on the native lane, stdio on
  the host lane, so vDB can be tested host-side. See the reference's
  Files section.
- [x] **CRC16.** `t.crc16(pos, n)` — CRC-16/KERMIT (reflected poly
  0x8408, seed 0, check value 0x2189), rolling-hash shape like
  `hashStep`.
- [x] **Little-endian accessors on `text`.** `t.intAtLE(pos)`,
  `t.wordAt(pos)`, `t.wordAtLE(pos)`.
- [x] **In-place binary patching on `text`.** The four writers
  `setIntAt` / `setIntAtLE` / `setWordAt` / `setWordAtLE`, symmetric
  with the readers and sharing their bounds rule.
- [x] **Int-to-string conversion.** `string(n)` joined the
  `int()`/`fixed()`/`char()`/`ptr()` conversion family. The hand-rolled
  `intStr` helpers can go as code gets touched.
- [x] **Toolbox include resolution.** `include "toolbox/..."` now falls
  back to the compiler's toolbox via rtdir (honored in every mode,
  including check-only). This project passes
  `--rtdir vendor/runtime/clarus/`, which resolves to `vendor/toolbox/`.
- [x] **Method calls on connection-typed parameters.** Connections now
  copy into records/arrays/locals and pass to functions ("receiver kind
  13" is gone). `termio.cla`'s `(conn: connection, ...)` signatures are
  restored. Handlers still bind to globals; the 4-connection cap stands.
- [x] **68k string temps per statement.** Long `+` chains no longer fail
  `emit68k` with "bump cgBigTmpSlots" (verified with a 20-term chain).
