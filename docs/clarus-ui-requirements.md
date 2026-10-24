# Clarus UI requirements from 68kBBS (2026-10-24)

Requests from the 68kBBS project for the Clarus widget system. The aim
is to let Clarus build classic Mac utility windows (status panes,
tables, logs) out of real widgets, rather than hand-drawing everything
on a canvas. The syntax below is a proposal: the Clarus side owns the
final shape, but the behavior described is what 68kBBS needs.

This supersedes the `docs/TODO.md` item "Language: canvas text font"
(2026-09-28), which is folded into section 2.

## Why: the window 68kBBS wants

68kBBS's single window today is one buffered canvas tailing a log. The
new layout is three panes:

```
+------------------+-------------------------------------+
| Status: Connected| User        Connected   Terminal  Time|
| User:   andrew   | andrew      10/24 20:41 ANSI   0:17:32|
| Screen: Boards   | pixelpusher 10/24 19:58 C64 40 0:24:11|
|                  | ...                                 ^v|
+------------------+-------------------------------------+
| 20:40:58 Ring 1.                                        |
| 20:40:59 Caller connected.                              |
| ... (log, newest at the bottom)                         |
+---------------------------------------------------------+
```

- Top left: three label pairs (Status / User / Screen), updated from a
  timer.
- Top right: a scrolling table of the last 50 callers, newest first.
- Bottom half: the log.

The panes split the window proportionally and follow the grow and zoom
boxes. It has to work on a Mac SE (8 MHz 68000, 512x342, about 900 KB
free heap), System 6 and 7.

Clarus can't build this from widgets today. A widget is placed only
by `at:`, `width:` and `fill:`. There is no height, and nothing can be
moved or resized at runtime. Tables always fill the window's width.
There is no font control anywhere, and nothing suits a fast log. The
Toolbox has none of these limits (`MoveControl`/`SizeControl`, `LNew`
with any rView plus `LSize`, any TextEdit rect, `TextFont`/`TextSize`),
so these are gaps in Clarus's widget layer only.

## Decisions already made

- **Layout is done by the program's code.** The program lays widgets out
  itself, from the window's `opened` and `resized` events. No
  declarative split or percentage layout in this batch.
- **Table columns can show a formatted value** (section 5), so the
  callers record can keep timestamps and durations as `int`s.
- **LogPanel supports selecting and copying text now** (section 4).
- **The extras are in**: menu checkmarks, submenus and canvas
  text measurement (sections 7-8).

## Priorities

| #  | Item                          | For 68kBBS's window |
|----|-------------------------------|---------------------|
| 1  | Widget geometry               | required            |
| 2  | Fonts                         | required            |
| 3  | Label improvements            | required            |
| 4  | LogPanel widget               | required            |
| 5  | Table improvements            | required            |
| 6  | Divider widget                | required            |
| 7  | Menu checkmarks and submenus  | extra               |
| 8  | Canvas text measurement       | extra               |
| 9  | Menu caption metacharacters   | bug fix             |

---

## 1. Widget geometry

### 1.1 Height when declaring

Every widget accepts `height: N` alongside the existing `width: N`.
Some controls have a natural height (field, button, check, popup).
For those, `height:` may be ignored or clamped, but say so in the
reference.

### 1.2 Runtime bounds

Every widget gets read-only `x`, `y`, `width` and `height` properties
(`int`, pixels, in window content coordinates). It also gets one method
that sets all four:

```
w.Callers.setBounds(161, 0, 319, 150)
```

- One call, not four property writes, so a move plus resize costs one
  invalidate/redraw.
- Mac: controls use `MoveControl`/`SizeControl`. Tables use the list
  rView plus `LSize`, with the scrollbar kept inside the bounds.
  TextEdit gets a new viewRect and destRect plus a recalc. A buffered
  canvas reallocates its offscreen bitmap.
- The old and new rects are invalidated. Calling `setBounds` on every
  widget from `resized` must not flicker, and the window must redraw
  once, not once per widget.
- A widget whose bounds were set by code is **placed by code** from
  then on. The runtime's automatic resize relayout (edge pinning,
  `fill`) leaves it alone, because the program's `resized` handler owns
  it. Widgets never touched by `setBounds` keep today's behavior, so
  existing programs are unaffected.
- Negative or zero sizes clamp to 0 and hide nothing silently. A widget
  of size 0 simply draws nothing.

### 1.3 Window content size

Window references get read-only `contentWidth` and `contentHeight`
(the area below the title bar, the same area widgets live in). Today
`title` is the only window property.

### 1.4 Tables no longer forced to full width

A table honors a declared `width:`/`height:` or bounds set by code.
`width: fill`/`fill: both` keep working as now.

### 1.5 Usage in 68kBBS (target)

```rust
extend Main {
    on opened { layoutMain(window) }
    on resized { layoutMain(window) }
}

func layoutMain(m: Main) {
    var w: int = m.contentWidth
    var h: int = m.contentHeight
    var top: int = h / 2
    m.Callers.setBounds(161, 0, w - 161, top)
    m.TopRule.setBounds(0, top, w, 3)
    m.SideRule.setBounds(160, 0, 1, top)
    m.Log.setBounds(0, top + 3, w, h - top - 3)
}
```

## 2. Fonts

### 2.1 When declaring

```
label StatusV { font: "Geneva", 9; style: bold }
logpanel Log  { font: "Monaco", 9 }
```

- `font: "Name", size` resolves the name with `GetFNum`. An unknown
  name falls back to the application font (Geneva). This is not an
  error, because fonts vary between Macs.
- `style:` takes `bold`, `italic` or `underline`, combinable
  (`style: bold, italic`). Plain is the default.

### 2.2 At runtime

```
w.StatusV.setFont("Geneva", 9)
w.StatusV.setStyle(bold)
```

The method names are a suggestion. The change redraws the widget and,
for table and LogPanel, recomputes the row height from `GetFontInfo`.

### 2.3 Which widgets

`label`, `field`, `textview`, `table` (rows and header), `canvas` and
`logpanel`. Buttons, checks and popups keep the system font, per Mac
convention. They may refuse the attribute at check time.

### 2.4 Canvas specifics

This is the old TODO item. The font is stored per canvas and
reapplied whenever the offscreen GrafPort is recreated (each resize).
`drawText` and `textWidth` (section 8) use it.

## 3. Label improvements

`label` already has `text`, `at`, `width` and runtime `text`. Add:

- `font:`/`style:` (section 2) and `height:`/`setBounds` (section 1).
- `align: left | center | right` (default `left`).
- Single line, clipped to its bounds, no wrapping.
- Assigning the same text it already shows does **not** redraw.
  68kBBS refreshes the status labels from a timer every second or so,
  and an unchanged label must cost nothing and never flicker.

## 4. LogPanel (new widget)

A read-only, scrolling, append-only list of text lines: the Mac
equivalent of a terminal's scrollback. It replaces 68kBBS's
hand-drawn log canvas and its `list of string` ring.

### 4.1 Declaration

```
logpanel Log { maxLines: 100; font: "Monaco", 9; scrollbar: both; fill: both }
```

- `maxLines:` caps the history. When a new line arrives past the cap,
  the oldest line is dropped. The default is your choice (around 200).
- `scrollbar: vertical | both`. Lines never wrap. `both` adds a
  horizontal scrollbar sized to the widest line held.
- `at`, `width`, `height`, `fill`, `font`, `style` as for other
  widgets.

### 4.2 Methods and properties

| Member              | Meaning |
|---------------------|---------|
| `appendLine(s)`     | Add one line (`string`). A CR or LF inside `s` splits it into several lines. Empty lines are kept. |
| `clear()`           | Drop every line. |
| `lineCount`         | Lines currently held (`int`, read-only). |
| `line(i)`           | Line `i` as a `string`, 0 = oldest. Out of range = runtime error, as for lists. |
| `scrollToEnd()`     | As `textview.scrollToEnd()`. |

`line(i)` lets the program use the panel as its only copy of the log.
68kBBS's sysop menu pages the log remotely, and today keeps a second
copy for that.

### 4.3 Storage

Lines are stored compactly (for example one handle holding
length-prefixed lines in a ring, plus an offset table). Each line costs
its own bytes, not 256. 68kBBS's current `list of string` ring costs
about 32 KB for 100 lines because every line occupies a full 256-byte
`string`. That is the waste this widget should remove. Out of memory on
append drops the oldest lines rather than failing.

### 4.4 Drawing and speed

This is the reason the widget exists. 68kBBS left TextEdit because
every append re-wrapped the whole buffer, about 1 s per line on the SE.

- Only visible lines are drawn. It does not use TextEdit, so there is
  no 32,000-byte limit.
- Appends are batched: any number of `appendLine` calls within one
  handler or timer cause one screen update when control returns to the
  event loop (like a buffered canvas). 68kBBS can log several lines per
  event.
- When following the end, one appended line should scroll with
  `ScrollRect` and draw just the new line, not repaint the panel.

### 4.5 Follow mode

- If the view is showing the last line, it stays at the end as lines
  arrive.
- If the user has scrolled up, appends do not move the view, so
  they can read history while the BBS keeps logging. The scrollbar thumb
  still updates. When old lines drop off the top, the view stays on the
  same text: the scroll position moves with the dropped lines, so the
  view doesn't jump.
- Scrolling back to the bottom resumes following.

### 4.6 Selection and copy

- Selection is by whole line, which is enough for a log and much simpler
  than character selection. Click selects a line. Drag or shift-click
  extends. Selected lines draw inverted.
- `standard edit`'s Copy enables while a LogPanel has a selection. It
  puts the selected lines, joined with CR, on the clipboard as `TEXT`
  (`ZeroScrap`/`PutScrap`). Select All selects every line. Cut, Paste
  and Clear stay dimmed: the panel is read-only.
- The selection stays put as lines are appended. Lines dropping off the
  top shrink it, and if they all drop off it is cleared.
- Clicking the panel makes it the focus for Copy, the way a `textview`
  takes the caret.

### 4.7 Host lane

Accepted and recorded in the scripted-UI trace like other widgets.
`line(i)`/`lineCount` work so the host tests can check contents.

## 5. Table improvements

### 5.1 Formatted columns

A column may show any expression over the row, not just a field:

```
table Callers {
    rows: recentCallers
    font: "Geneva", 9
    column "User"      shows name                     width 90
    column "Connected" shows shortDateTime(connected) width 80
    column "Terminal"  shows term                     width 64
    column "Time"      shows durationStr(secs)        width fill align right
}
```

- Row fields are in scope bare, as `shows field` resolves today. The
  expression's type follows the existing column type rules (a `string`
  result is shown as-is).
- It is evaluated at draw time, for visible rows only, so it must be a
  plain function call. A runtime error inside one should not take down
  the redraw. Choose a policy and document it, e.g. show an empty cell
  and log the error once.
- Why: the callers record stays at 52 bytes (`string(31)` name, `int`
  time, `int` seconds, `string(10)` terminal). Storing display strings
  instead would add about 12 bytes per entry.

### 5.2 Column alignment

`align left | center | right` per column, default left. The header
text follows its column's alignment.

### 5.3 Every list mutation refreshes the table

The reference promises live updates for `add`, `remove` and element
writeback. 68kBBS's callers list uses `unshift` (newest at the top)
and `pop` (drop the oldest past 50). Make sure `unshift`, `shift`,
`pop`, `push`, `clear`, `release`, `reserve` and `l[i] = v` all keep
the bound table correct. For these small tables, invalidating
everything is fine. `selected` stays on the same row (or goes to -1
if that row is removed).

### 5.4 Scrolling and selection from code

- `scrollTo(i)` makes row `i` visible (`LScroll`). `scrollTo(0)` is
  "top".
- `selected` becomes writable: assigning `-1` clears it and assigning
  `i` selects that row. Assignment never fires `select`, like other
  programmatic widget writes.

## 6. Divider widget

A 1-pixel line (or a 3-pixel double rule) to separate panes. A
`divider` draws a horizontal line when its bounds are wider than tall,
and vertical otherwise:

```
divider TopRule  { style: double }
divider SideRule { }
```

`style: single | double`, default single. It has no events. It is
positioned with `at`/`width`/`height`/`setBounds` like everything else.
Without it a program has to drop a canvas in just to draw a line.

## 7. Menu checkmarks and submenus

68kBBS's Modem menu lists port speeds (300...57600) and ports (modem or
printer) as one flat menu. It marks the active choice by **dimming** it,
because Clarus has neither.

### 7.1 Checkmarks

- Each menu item gets a runtime `checked` property:
  `Modem.Speed9600.checked = true` (`CheckItem`).
- When declaring: `item Speed9600 "9600" checked`.

### 7.2 Submenus

A hierarchical menu item (System 6 and 7 both support them):

```
menu Speed {
    item S9600  "9600"
    item S19200 "19200"
}
menu Modem {
    item Init "Initialize Modem"
    item PortSpeed "Port Speed" submenu Speed
}
```

- The submenu is an ordinary declared `menu`, so its items' `select`
  handlers work as usual. It is inserted with `InsertMenu(m, -1)` and
  never appears in the menu bar itself.
- Hierarchical MENU IDs must be in 1..235, which affects ID allocation.
- A submenu counts toward the 31-menu limit.

## 8. Canvas text measurement

- `c.textWidth(s: string): int`: the width of `s` in pixels, in the
  canvas's current font (`StringWidth`).
- `c.lineHeight`, `c.ascent`: read-only `int`s from `GetFontInfo`, so
  rows of text can be laid out without guessing (68kBBS hard-codes 12).

## 9. Bug: menu caption metacharacters

Today a caption containing `(` is shown **dimmed**. 68kBBS's
CLAUDE.md carries the rule "menu captions must not contain `(`".
`AppendMenu` reads `( / ^ ! < ;` as Menu Manager metacharacters.
Captions should be literal: append a placeholder, then set the real
text with `SetItem`, which does not parse metacharacters.

---

## General requirements

- **Targets:** System 6 and System 7, 68000 (Mac Plus/SE) up.
  Nothing here should need Color QuickDraw.
- **Compatibility:** existing programs compile and behave as before.
  All new attributes are optional.
- **Host lane:** every new property and method exists on the host. UI
  calls are recorded in the scripted-UI trace or accepted and ignored,
  like canvas drawing today, so 68kBBS's host-lane tests still build.
- **Docs:** language reference (Chapters 8-11) and changelog entries
  for each item. Mac notes where behavior differs between lanes.
- **Tests:** the usual fixtures. For LogPanel in particular: the
  `maxLines` drop, follow mode against a scrolled-up view, selection
  surviving appends, and Copy's clipboard contents.

## How 68kBBS will use it

Once these land and the pin is refreshed:

- The `Main` window becomes labels + `divider`s + the `Callers` table +
  a `LogPanel`, laid out from `opened`/`resized` by code.
- `on App.log` calls `Log.appendLine(...)`. The `logLines` ring,
  `logRedraw` and the 2-tick redraw go away, and the sysop log viewer
  reads `Log.line(i)`.
- The Modem menu switches to Speed/Port submenus with checkmarks.
