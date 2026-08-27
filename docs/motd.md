# Message of the Day

A block of text the sysop writes that every caller sees after the
wall at login, and that main-menu `D) Message of the Day` shows
again. Storage is one text file (`motd.cla`); editing reuses the line
editor (`editor.cla`).

## What the caller sees

In the login chain, after the wall's `Sign the wall?` question:

```
Welcome to the 68kBBS test board.
Be excellent to each other.

Press any key to continue...
```

then the new-message / pending-file counts and the main menu. When the
message is empty the MOTD and its pause are skipped entirely. Main-menu
`D` prints the message (or `No message of the day.`) followed by the
same pause, then redraws the menu.

The text is word-wrapped to the caller's terminal width with
`wrapText` — CRs in the file are paragraph breaks (blank lines kept),
LFs are ignored — so one file serves 80- and 40-column callers. It is
not paged: keep it short. (If a long MOTD is ever wanted, the
wall's line-counting pager is the thing to reuse.)

## Editing (Sysop menu `M`)

`Sysop Menu > M) Message of the Day` opens the line editor over the
current text (`startMotdEditor` in `sysop.cla`): the existing lines
are listed, numbered, and the usual editor commands apply — `/L`
list, `/D n` delete, `/E n` edit, `/I n` insert, `/R n` replace text,
`/?` help. `/S` writes the file (`Message of the day saved.`); `/A`
discards the edit (`Edit aborted.`). Both return to the Sysop menu.
This is `editTarget = 'D'` in `editor.cla`; the body is the rows
joined end to end, each hard row carrying its own CR.

## The file

`MOTD.txt` next to the app (TEXT/ttxt, so it opens in TeachText /
SimpleText), CR line ends. It is read once at launch (`motdLoad`,
logged as `Message of the day loaded (N bytes).`) into the global
`motdText`; a missing file is an empty message and is not created.
`motdSave(body)` creates/truncates the file, writes and flushes it,
and updates `motdText` only on success. Editing the file on the Mac by
hand takes effect at the next launch — from the Sysop menu it takes
effect at once.

`tests/motd-test.cla` covers the missing-file case, a save/load
round-trip, and saving an empty message.
