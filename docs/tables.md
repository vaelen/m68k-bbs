# Drawing tables

How the BBS renders boxed tables (like the sysop user list) on ASCII,
ANSI, and VT100 terminals. The primitives live in `terminal.cla` (pure,
host-testable — exact-byte assertions in `tests/terminal-test.cla`),
the connection-facing sender in `termio.cla`, and a full worked example
in `bbs.cla` (`drawUserListPage`).

**Single-byte encodings only. Never emit Unicode.** Source files are
MacRoman; high bytes are written as `\xHH` escapes.

## Character sets

`boxChar(p: BoxPiece): char` returns the drawing character for the
session's `terminal.type`:

| BoxPiece     | ASCII | ANSI (cp437) | VT100 (DEC Special Graphics) |
| ------------ | ----- | ------------ | ---------------------------- |
| TopLeft      | `+`   | 0xDA         | `l`                          |
| TopCenter    | `+`   | 0xC2         | `w`                          |
| TopRight     | `+`   | 0xBF         | `k`                          |
| CenterLeft   | `+`   | 0xC3         | `t`                          |
| Center       | `+`   | 0xC5         | `n`                          |
| CenterRight  | `+`   | 0xB4         | `u`                          |
| BottomLeft   | `+`   | 0xC0         | `m`                          |
| BottomCenter | `+`   | 0xC1         | `v`                          |
| BottomRight  | `+`   | 0xD9         | `j`                          |
| Horizontal   | `-`   | 0xC4         | `q`                          |
| Vertical     | `\|`  | 0xB3         | `x`                          |

VT100 has no high-byte drawing set: it remaps codepoints 0x60–0x7E to
line graphics while a shift to the G1 character set is active. So:

- `vt100SetupSeq` (`ESC ) 0`) designates G1 = DEC Special Graphics.
  Sent **once**, when the caller picks VT100 at the terminal-type menu
  (`applyTerminal` in bbs.cla). G0 stays ASCII, so normal text is
  unaffected.
- `startDrawing()` / `stopDrawing()` return SO (0x0E) / SI (0x0F) on
  VT100 and `""` on the other types. Drawing characters render as
  lines only between them.

## Building blocks (terminal.cla)

- `pad(s, width)` — left-align in `width` spaces, truncate if longer.
- `center(s, width)` — center (odd leftover space goes right),
  truncate if longer.
- `hbar(width)` — `width` × Horizontal, **bare** (no SO/SI).
- `vbar()` — one Vertical, **self-contained** (carries its own SO/SI
  on VT100), for use between runs of normal text.
- `ruleLine(l, m, r, widths)` — a full horizontal rule: piece `l`,
  a joint `m` between columns, piece `r`. Bare.
- `rowLine(cells, widths)` — a data row: `vbar() + " " + pad(cell, w)
  + " "` per column, closing `vbar()`. Self-contained.

`widths` is a `list of int` of **content** widths; both `ruleLine` and
`rowLine` add the two padding spaces per column themselves, so one
widths list drives rules and rows alike. Total rendered width is
`sum(widths) + 3*count + 1`.

`sendDrawing(conn, s)` in termio.cla sends `startDrawing() + s +
stopDrawing()` — a whole rule line costs one SO/SI pair. Rows from
`rowLine` are sent as-is (their bars are self-contained). Lines end
with `terminal.eol` (a `Terminal` field, default CRLF).

## Assembling a table

For a title bar spanning the table, use a one-element widths list of
`sum(widths) + 3*(count-1)` — that renders the same total width.

```
+-----------------------+      ruleLine(TopLeft, TopCenter, TopRight, span)
|      Table Title      |      rowLine([center(title, span[0])], span)
+--------+--------------+      ruleLine(CenterLeft, TopCenter, CenterRight, w)
| Name   | Description  |      rowLine(headers, w)
+--------+--------------+      ruleLine(CenterLeft, Center, CenterRight, w)
| Foo    | Bar          |      rowLine(cells, w)   (per row)
+--------+--------------+      ruleLine(BottomLeft, BottomCenter, BottomRight, w)
```

## Widths, 40 vs 80 columns

Pick the layout with `if terminal.columns < 80` (never `==` — wider
terminals may be added later). Current convention: a narrow variant
that fits 40 columns and a wide one that fits 80. The user list
(`userListWidths`) uses content widths 4/21/5 (= 40 total) narrow,
plus 17/17 (= 80 total) wide.

## Paging

Page size is derived from the terminal: `terminal.rows - 8` data rows
(frame is 5 lines + title, plus the more-prompt and the echoed input
line). The pattern (see `drawUserListPage` / `userListInput`):

- a global cursor (`listFromId`) holds the next record id to show;
- each page redraws the full frame, renders up to a page of live
  records, then scans ahead — if more remain it prompts
  `[Enter] More  [Q] Menu` and stays on the list screen; otherwise it
  returns to the parent menu;
- on input, `Q` leaves, anything else draws the next page.
