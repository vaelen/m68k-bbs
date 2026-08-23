# Private Mail Database

How 68kBBS stores private mail, as implemented by `maildb.cla` on top
of vDB (`docs/vdb-clarus.md` for the engine's on-disk format;
`docs/boards.md` for the message-board databases this mirrors).
Pre-v1: no backward compatibility is promised — data structures may
change freely, always starting from a clean database.

The UI over this storage (main-menu `M - Mail`: inbox list, message
view, composer reusing `editor.cla`) is described in CLAUDE.md's
architecture notes once it exists.

## Shape

**One `Mail` database for everyone**, indexed by recipient, plus one
body heap:

- `Mail.DAT` / `Mail.IDX` / `Mail.JNL` — message header records in vDB
- `Mail.I00` — secondary index on the recipient user-ID field
- `Mail.MSG` — the body heap (a plain file, not a vDB database)

A user's inbox is one index lookup (`dbFindAllByInt` on the recipient
field). This was chosen over per-user mailbox files because user IDs
aren't bounded the way board IDs are (two-digit file names), one open
database at launch is simpler than per-caller file juggling, and it
matches Fidonet, where netmail is one area (`NETMAIL.*`) rather than
one per addressee — so a future tosser imports into this same database
through the same `sendMail` path.

The header/heap split is the same as boards': fixed records give cheap
indexed lookups, the heap gives exact-fit variable-length bodies.

## Message header record (256 bytes, vDB record ID = message ID)

| Offset | Size | Field | Notes |
|-------:|-----:|-------|-------|
| 0 | 64 | fromName | Pascal string, ≤ 63 chars — a display **name**, not a user ID |
| 64 | 64 | toName | Pascal string, ≤ 63 chars |
| 128 | 64 | subject | Pascal string, ≤ 63 chars (same cap as posts) |
| 192 | 4 | fromUserId | i32; 0 = not a local user (future: inbound netmail) |
| 196 | 4 | toUserId | i32, **indexed** (IT_ID, `.I00`); 0 = not a local user (future: outbound netmail) |
| 200 | 4 | created | i32, Mac-epoch seconds |
| 204 | 4 | body offset | i32, byte offset into `Mail.MSG` |
| 208 | 4 | body length | i32; 0 = no body (offset then meaningless) |
| 212 | 2 | flags | u16; bit 0 = read. Bits 1–15 reserved |
| 214 | 42 | reserved | zero |

- Names are stored **alongside** the resolved user IDs, not instead of
  them: the IDs drive lookups, the names drive display. A renamed or
  deleted user's old mail still shows who it was from, and imported
  netmail needs no local account (same rule as a post's `sender`).
- **Message IDs** are dense and never reused (vDB record IDs).
- **Recipient-only storage**: one record is one inbox item. The sender
  keeps no copy, so there is no sender-side delete state and no index
  on `fromUserId`. `fromUserId` is stored anyway so a Sent list can be
  added later by adding an index — no format change.

### Reserved bytes — intended Fidonet use

Nothing writes these today; this records the plan so the tosser can
be added without a redesign:

- `flags` bits 1–15: Fido attributes as needed (Private, Crash, Sent,
  Received, Kill/Sent, Local, Hold, …).
- Reserved 214–229: origin and destination addresses as two 8-byte
  groups of u16 `zone, net, node, point`; all-zero = local. Binary
  rather than a `"z:n/n.p"` string so routing code compares integers.
- Reserved 230–255: spare (e.g. a MSGID hash for dupe checking).

Subjects are capped at 63 chars (FTS-0001 allows 72); widen the field
if real netmail ever trips on it.

## The body heap (`Mail.MSG`)

Identical to a board's `BRD<nn>.MSG`: an append-only file of raw body
bytes with no framing; the header's offset/length pair is the only map
into it. Bodies are CR-joined lines from the line editor, re-wrapped
per reader.

**Write ordering:** `sendMail` appends the body and `flush()`es
**before** the journaled header add. Bodies are never journaled; a
crash leaves either a complete message or orphaned heap bytes nothing
references — never a header pointing at text that didn't reach disk.

**Deletion:** `deleteMessage` is a `dbDelete` of the header; the body
bytes are orphaned, not reclaimed. No heap compactor — same reasoning
and same compactor shape as `docs/boards.md` if it ever matters.

## API (`maildb.cla`)

`Message` record (id, fromName, toName, subject, fromUserId,
toUserId, created, flags) + global `message` (last loaded header).

- `mailOpen(): bool` / `mailClose()` — opened once at launch alongside
  Users and Boards; creates the files (with the recipient index) on
  first run
- `sendMail(fromName, fromUserId, toName, toUserId, subject, body): int`
  — new message ID or −1
- `loadMessage(id): bool` — header into the global `message`
- `messageBody(id): text` — body from the heap; empty if none
- `inboxIds(userId, ids)` — all message IDs addressed to `userId`,
  oldest first (index values accumulate in insertion order); the UI
  lists newest first
- `markRead(id): bool` — sets flag bit 0 via `dbUpdate`
- `deleteMessage(id): bool`
- `unreadCount(userId): int` — for the login banner and main menu
- `mailCount()`, `mailNextId()`

**Recipient validation is not the db layer's job.** The composer
resolves the `To:` name with `findUserId` (case-insensitive) and
rejects input that matches no local user; `maildb` just takes IDs.
Richer address formats (netmail) extend that resolver later, storing
`toUserId = 0` plus the reserved address bytes.

## Tests

`tests/maildb-test.cla` (host lane): send/load/body round trip, two
users' inboxes stay separate and ordered, read flag, delete, and a
body-less message.
