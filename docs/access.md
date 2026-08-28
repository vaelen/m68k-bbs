# Access flags

A user's `access` field (`user.cla`, stored as an i32 at offset 132 of
the Users record) is a bit set. `enum Access` names the bits; a
member's value is its bit number, so `int(f)` is the shift.

| bit | flag | grants |
|---|---|---|
| 0 | Login | logging in at all — without it a correct password gets "This account is disabled." and a hang-up |
| 1 | SendMail | `N)` New Message and `R)` Reply in mail |
| 2 | PostBoards | `N)` New Post and `R)` Reply on the boards |
| 3 | UploadFiles | `U)` Upload in a file area |
| 4 | ApproveUploads | seeing pending files, `A)` Approve, the "awaiting approval" login banner; the holder's own uploads skip the pending flag |
| 5 | PostWall | the "Sign the wall?" question |
| 6 | Games | `G)` Games on the main menu |
| 7 | Sysop | `S)` Sysop Menu, deleting posts/files, editing file descriptions, sysop-only areas, writing into the shared games folder |
| 8 | BasicRepl | `B)` BASIC prompt on the Games menu (and its per-user folder) |

Bits 9-31 are free. Each gate checks exactly its own bit — Sysop does
not imply the rest. The first account created gets `accessAllFlags`
(bits 0-8); every later signup gets `accessDefault` (Login, SendMail,
PostBoards, UploadFiles, PostWall, Games).

Menu items the caller lacks are not drawn and the key does nothing
(the same convention the sysop menu item always had).

## API (`user.cla`)

- `getBit(v, n)`, `setBit(v, n)`, `clearBit(v, n)` — plain int helpers.
- `hasPermission(f)`, `setPermission(f, grant)` — on the session `user`.
- `accessHas(v, f)` — the same test on any int (the sysop list/card
  read records without loading them).
- `accessLabel(f)` — the name shown in the table; `accessFlagCount`.

## Sysop UI

Sysop > Users > Edit > `A` opens the `useraccess` screen:

```
+----+----------------------+---------+
| N  | Access Level         | Granted |
+----+----------------------+---------+
| 0  | Login                | Yes     |
| 1  | Send Mail            | Yes     |
...
+----+----------------------+---------+
Flag to toggle (Enter = done):
```

A number flips that bit in the buffered `editAccess` and redraws;
Enter returns to the edit card, where `S` saves. A sysop cannot open
the table for their own account.

`ENVIRON$("ACCESS")` in BASIC returns the bits as a decimal number.
