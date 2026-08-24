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
- `padLeft(s, width)` — right-align (footer text like `Page X of Y`).
- `center(s, width)` — center (odd leftover space goes right),
  truncate if longer.
- `wrapText(body, width, lines)` — word-wrap a `text` into a
  `list of string`: breaks on spaces, hard-breaks over-long words,
  keeps CR line breaks (blank lines included), drops LFs. Used by the
  post viewer to re-wrap stored bodies to each reader's width.
- `spanWidth(widths)` — the one-column content width that renders the
  same total width as the given columns (`sum + 3*(n-1)`), for title
  and footer bars.
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

bbs.cla layers the connection-facing senders over these, shared by
the sysop screens and the board reader:

- `sendRule(l, m, r, w)` — one rule line via `sendDrawing` + eol
- `sendTableTitle(title, w)` — blank spacer, top rule, centered
  title bar, joint rule
- `sendTableHeader(title, headers, w)` — title plus a header row and
  its rule
- `sendTableFooter(msg, w)` — joint rule, right-aligned footer bar
  spanning the table, bottom rule

## Assembling a table

Title and footer bars span the table via a one-element widths list of
`spanWidth(w)` — that renders the same total width. The full anatomy
(`sendTableHeader` draws the top five lines, `sendTableFooter` the
bottom three):

```
+-----------------------+      ruleLine(TopLeft, TopCenter, TopRight, span)
|      Table Title      |      rowLine([center(title, span[0])], span)
+--------+--------------+      ruleLine(CenterLeft, TopCenter, CenterRight, w)
| Name   | Description  |      rowLine(headers, w)
+--------+--------------+      ruleLine(CenterLeft, Center, CenterRight, w)
| Foo    | Bar          |      rowLine(cells, w)   (per row)
+--------+--------------+      ruleLine(CenterLeft, BottomCenter, CenterRight, w)
|            Page 1 of 2 |     rowLine([padLeft(msg, span[0])], span)
+------------------------+     ruleLine(BottomLeft, BottomCenter, BottomRight, span)
```

Detail cards (`sendTableTitle` + label/value rows + a bottom rule)
and the post view (title bar, meta rows, wrapped body rows, footer)
are the same pieces with a single-span or two-column widths list —
see `drawUserDetails` and `drawPostView`.

## Widths, 40 vs 80 columns

`terminal.columns` holds the physical width **minus one** (set only
through `setColumns`; 79 for an 80-column screen). SyncTERM and DOS
ANSI.SYS wrap on their own when the last column is written, so a
newline after a full-width line shows as a blank line there, while
Unix terminals and anything wider than 80 need that newline. Never
writing the last column keeps every line short of it, and every line
carries its own newline. A table's total width is
`sum(content widths) + 3 × columns + 1`, so the layouts fit **79**
wide and **39** narrow.

Pick the layout with `if terminal.columns < minimumWideTerminalWidth`
(never `==` — wider terminals may be added later). The user list
(`userListWidths`) uses content widths 4/20/5 (= 39 total) narrow,
plus 17/17 (= 79 total) wide.

## Paging

Page size = `terminal.rows` minus the frame lines, counted **from the
top rule down** — everything above the table (the previous echoed
command, the blank spacer) is expected to scroll off. Count one line
each for: top rule, title, its joint, the header row and its joint
(or each meta row), the footer joint, footer, bottom rule, and the
prompt. So the footer'd post list gets `rows - 9` data rows, the
post view `rows - 8 - metaRows`, and the older footerless sysop
lists `rows - 8`.

Two paging styles coexist:

- **Forward-only** (sysop user/board lists — `drawUserListPage` /
  `userListInput`): a global cursor (`listFromId`) holds the next
  record id; after a full page with live records remaining it prompts
  `[Enter] More  [Q] Menu`, otherwise it returns to the parent menu.
- **Bidirectional** (post list and post view — `drawPostList` /
  `drawPostView`): a page number against a computed page count,
  shown right-aligned in the footer (`Page X of Y`). `+` or Enter
  pages forward, `-` back, `L` redraws the current page; at either
  end the input quietly re-prompts. List numbering restarts at 1 on
  every page.
