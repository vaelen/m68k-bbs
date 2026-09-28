# TODO

Deferred work, with enough detail to pick up cold. Nothing here is
blocked on a language feature unless it says so.

## Serial handshaking setting

`modemNoHandshake()` (bbs.cla, `on modem.opened`) forces all flow
control off: the Clarus runtime never calls SerHShake, and on a real SE
the driver's leftover setting held the first `PBWriteSync` forever
(0 bytes out). Make it a setting instead of a hardcoded choice:

- `Config.txt`: `modemHandshake=none|cts|xonxoff` (default `none`) —
  a field on `Config`, a case in `configApply`, a line in `configSave`.
- Modem menu: three flat items with the active one dimmed, like the
  speed/port items (`modemMenuSync`); a change saves and reapplies
  SerHShake on the open port (no reopen needed).
- 68kBBS Config (`bbsconfig.cla`): a `Handshake` popup (enum) on the
  form.
- `modemNoHandshake` becomes `modemApplyHandshake`, setting `fCTS` or
  `fXOn` (xOn `\x11`, xOff `\x13`) on the output driver.

Caveat: synchronous writes (runtime `rtConnDevWrite` → `PBWriteSync`)
still block the whole app while the modem holds CTS or has sent XOFF,
so `cts`/`xonxoff` are only safe once the runtime's writes time out or
go async. The proper home for the default-off SerHShake is the runtime's
`rtConnDevOpen` (then re-pin and drop the bbs.cla workaround).

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

## Faster post adds (tossing)

`dbAdd` of a post costs ~1.55 s on the SE (68kBBS Bench, 2026-09-28),
and a tossed echomail message pays more on top of it. Deletes had the
same problem and went from ~2.2 s to ~0.32 s each by cutting disk
writes (see `dbDeleteMany`/`btRemoveMany`, commit 96d5680). The
constraint is the same: on the SE a 512-byte `writeAt` costs ~73 ms
(and about that per sector whatever the size), a `readAt` ~6 ms, a
flush ~25 ms more, a text op ~4-7 ms, a one-byte `append` ~0.3 ms.

Where an add's writes go today (`dbAdd`, vdb.cla): pending-flag header
write; free-list read/write or file growth (`dbAllocatePages`); a
518-byte journal entry built, appended and flushed
(`dbJournalRecord`); the record page; a primary `btInsert` leaf write;
three secondary `btInsert`s, each opening/closing its index file and
writing a leaf (`dbIndexInsertAll`); the commit (header write +
journal truncate). Per tossed post, `addPostFtn` (postsdb.cla) adds a
body-heap append + flush and `boardTouch` -- a full journaled
`dbUpdate` of the Boards record, just to stamp `lastPost`.

In order:

1. **Measure first.** Per-phase `dbTiming` for `dbAdd` like `dbDelete`
   has (`dt*` phases, `dbTimes`), plus an "add a post the way the toss
   does" run in `bench.cla` (body append + `boardTouch` + MsgId dupe
   check) so the whole per-message cost is visible.
2. **`boardTouch` once per batch, not per post** -- probably the
   cheapest big win: remember the newest `created` per board during a
   toss unit and stamp it once at the end (local posts can keep the
   per-post touch).
3. **`dbAddMany(db, recs)` for the toss:** one pending flag, one
   free-list update, record pages written, each index file opened once
   and updated by a `btInsertMany` (keys sorted, each leaf read once,
   the batch's entries inserted in memory, written once; a leaf that
   overflows its budget falls back to the existing one-at-a-time split
   path for that leaf), one commit. Body-heap appends batched with a
   single flush before the header adds (keep the body-before-header
   ordering, postsdb.cla file comment). The tosser (`ftntoss.cla`)
   would collect a packet's messages per board -- dupe-checking against
   the batch as well as the board -- and add them together; that
   changes its one-message-per-tick unit, so size batches to the
   ~5-tick slice budget.
4. **Drop the journal entry for single-page records**, as
   `dbDeleteMany` did: a pending database's next open rebuilds every
   index from the data pages, so a crash mid-add either has the record
   page (kept) or not (gone). Required first: replay must recompute
   `next_record_id` as max ID + 1 (and it already recounts records via
   `dbCountPrimary`), or a crash between the page write and the header
   update would hand the same ID out twice. Multi-page records keep the
   journal (a torn run of pages).

Adds matter less than deletes did for maintenance, but they set the
toss rate: a big inbound packet on the SE currently tosses at well
under one message a second.

## Maintenance follow-ups (docs/maintenance.md)

- **Bulk-load the index rebuild.** `dbCompact` re-inserts one record at
  a time per index (~15 s for a 20-post board on the Mac II; minutes
  for a 1,000-post board). Building each B-tree's leaves in sorted
  order in one pass would cut it to seconds. Measured numbers in
  docs/maintenance.md "Measured".
- **Overflow chains leak on whole-key delete.** `btDelete` drops the
  leaf entry but leaves its type-4 chain pages allocated until the
  tree is rebuilt (compaction). Harmless at current scale; a free list
  for overflow pages if it ever matters.

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
