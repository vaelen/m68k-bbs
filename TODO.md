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

## FidoNet follow-ups (docs/fidonet.md, "Scope")

Deferred from v0.2, none blocked on a language feature:

- **Charset tables.** Inbound and outbound text is ASCII-only (bytes
  above 0x7F become `?`, outbound carries `^ACHRS: ASCII 1`). Add
  CP437/LATIN-1/UTF-8 <-> MacRoman tables in `ftnpkt.cla` keyed on the
  stored `CHRS` kludge, so old messages re-render once the table lands.
- **ARCmail bundles.** The uplink link must send uncompressed `.pkt`s
  (no packer). Either an `inflate` in Clarus (~300 lines, ZIP stored
  blocks outbound) or unpacking in the bridge.
- **Bridge as caller.** Crash mail needs the Mac's EMSI *answer* side
  and a `RING` from the modem emulator; today the Mac only polls.
- **Outbound netmail queue screen.** Unsent netmail is only visible as
  a count on the network card; a list with delete would help debugging.
- **Per-user netmail gate.** Any authenticated user may send netmail.
- **FTSC product code.** Packets and EMSI carry product code `00`;
  register one (FSC-0090) and put it in `ftnpkt.cla`/`emsi.cla`.
- **System name.** The Origin line and EMSI IDENT use the constant
  `ftnSystemName` ("68kBBS"); make it a sysop setting.
- **Deleted networks.** Boards keep a dangling `networkId`; the sysop
  board card shows `#n (missing)`. Clear or block on delete.
- **Bridge (libftn).** `fnemsi` + modem-emulator `ATDT`/`exec:` targets
  per docs/fidonet.md "Bridge contract"; `scripts/ftn-e2e.sh` then
  swaps its Python peer for the real bridge. libftn does not currently
  build on this machine (`ftn.c`, 6 errors).
