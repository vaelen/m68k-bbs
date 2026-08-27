# Banned Usernames

A sysop-editable list of usernames nobody may sign up with, and that
hang up the line when typed at the login prompt — the names bots and
scanners try first (`root`, `admin`, `sysop`, `guest`, …). Storage is
one text file (`banned.cla`).

## Behavior

- **Signup** (`NEW` at the login prompt): a banned name is refused
  with `That username is not allowed.` and the name prompt repeats.
- **Login prompt**: typing a banned name hangs up straight away — no
  message, no password prompt, no login-log record — via the same
  paced `+++` / `ATH` sequence as a normal logoff (`hangupPhase`).
  The Mac-side log gets `Banned name at login (<name>); hanging up.`
- Matching is case-insensitive (`isBanned`), on the whole name.

## Editing (Sysop menu `X`)

`Sysop Menu > X) Banned Names` shows the list flowed across the
terminal width with its count, then:

- `A) Add Name` — `Name to ban (Enter = cancel): `; names are trimmed,
  limited to 31 characters, and refused if already listed
  (`Already banned.`). Saved at once (`Banned: <name>`).
- `D) Delete Name` — `Name to remove (Enter = cancel): `; any case
  matches (`Removed: <name>`, or `Not on the list.`).
- `Q` back to the Sysop menu.

## The file

`Banned.txt` next to the app (TEXT/ttxt), one name per line, CR line
ends. It is loaded once at launch (`bannedLoad`, logged as
`Banned names loaded (N).`); when it is missing, the 31 built-in
defaults are written out so there is something to edit. The file can
also be edited by hand on the Mac or on the host (LF and CRLF line
ends are accepted, blank lines skipped, an unterminated last line
read); hand edits take effect at the next launch, Sysop-menu edits at
once.

Defaults: admin, administrator, "admin, admin1, client, contact,
daemon, default, enable, fraud, guest, help, hostmaster,
mailer-daemon, moderator, moderators, nobody, notme, postmaster, root,
"root, security, server, support, sventek, sysop, system, test, ubnt,
unknown, webmaster.

`tests/banned-test.cla` covers the defaults, case-insensitive matching,
add/remove persistence, and a hand-edited file.
