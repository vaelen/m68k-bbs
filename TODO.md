# TODO

Deferred work, with enough detail to pick up cold. Nothing here is
blocked on a language feature unless it says so.

## Multi-file downloads (tag-and-download)

Batch download: the caller tags several files on the list and downloads
them in one ZMODEM (or YMODEM) session. Deferred — the single-file
download in the file view covers the common case, and this is mostly UI.

**Engine (`zmodem.cla`, `xmodem.cla`)** — the smaller half:
- A download queue the engine walks: after the `ZRINIT` that
  acknowledges a file's `ZEOF`, send the next `ZFILE` instead of `ZFIN`.
  Either a `list of string` of paths/names in the engine, or a
  `xferNextFile()` callback that `files.cla` answers with the next
  (path, name) or empty.
- A per-file completion callback — `xferSent(name)` after each `ZEOF`
  is acknowledged — so each entry's download count is bumped and saved.
  Today `xferDone` bumps one `fileRec`; a batch can't.
- `ZSKIP` on one file advances to the next, not end-of-batch.
- YMODEM batching (`xmodem.cla`) is the same loop: block 0 per file,
  empty block 0 to end. Could share the queue. XMODEM/1K can't batch.

**UI (`files.cla`)** — the larger half:
- Tagging on the file list. Digits already open the number prompt, so
  tag is `T` then a number (or `T` toggles a tag mode). Tagged entries
  marked `*` in the `#` column; a tag count in the footer.
- Session state: `list of int` of tagged file IDs, reset on connect.
- `D) Download Tagged` on the *list* → protocol menu restricted to
  `Y`/`Z` (XMODEM can't batch) → a queue builder that resolves IDs to
  `filePath`, skipping offline/pending entries with a message.
- The `*` marker has to fit both the 79- and 39-column layouts.

~80-100 lines in `files.cla`, ~40 in the engines. No language gap.

## ZRINIT ESCCTL for non-BINARY telnet links

Telnet transfers rely on BINARY (RFC 856) being agreed both ways
(`telnet.cla`, `telnetBinaryRequest`); a client that refuses it stays
in NVT mode, which appends LF to every lone CR it sends and drops a
NUL after a CR it receives. For ZMODEM there is a belt-and-braces
option: set ESCCTL in our `ZRINIT` flags so the sender ZDLE-escapes
every control byte (CR included) and the NVT rewriting never sees a
bare CR in the data. Only helps uploads (our receiver's `ZRINIT`), and
only ZMODEM — XMODEM/YMODEM have no escaping, so a client that can't
do BINARY still can't transfer those. Not needed by SyncTERM, which
negotiates BINARY at connect; add if some other client turns up that
won't. `zmodem.cla` receiver's `ZRINIT` builder, plus a unit case in
`tests/zmodem-test.cla` (the parser side already handles ESCCTL).
