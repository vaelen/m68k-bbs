# CP437 / PETSCII Comparison Table

A byte-for-byte comparison of IBM Code Page 437 and Commodore PETSCII, for
reference when writing translation layers between ANSI BBSes and Commodore
terminal software.

## Reading this table

- **CP437** — the IBM PC / MS-DOS character set used by ANSI BBSes. Note that
  CP437 assigns printable glyphs to `$00`–`$1F`, but those code points still
  act as control codes in transit; the glyphs appear only when a byte is
  written directly to video memory or passed with the "display controls" bit
  set.
- **PETSCII** — the unshifted (uppercase/graphics) set. This is what a C64
  displays at power-on.
- **Shifted** — the shifted (lowercase/uppercase) set, selected by printing
  `CHR$(14)`. `CHR$(142)` switches back. The byte values never change; only
  the glyph drawn by the character ROM does.

Unicode glyphs for the PETSCII graphics are approximations. Several PETSCII
block-graphics have no Unicode equivalent and are shown as the closest
matching shape.

Sources: c64-wiki PETSCII code chart; masswerk "PETSCII Revealed" (Norbert
Landsteiner, 2020) for the graphics glyph mapping.

---

## $00–$1F — control codes

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 0 | $00 | (blank) | — | — |
| 1 | $01 | ☺ | — | — |
| 2 | $02 | ☻ | — | — |
| 3 | $03 | ♥ | STOP | STOP |
| 4 | $04 | ♦ | — | — |
| 5 | $05 | ♣ | WHITE | WHITE |
| 6 | $06 | ♠ | — | — |
| 7 | $07 | • | — | — |
| 8 | $08 | ◘ | disable SHIFT+C= | same |
| 9 | $09 | ○ | enable SHIFT+C= | same |
| 10 | $0A | ◙ | — | — |
| 11 | $0B | ♂ | — | — |
| 12 | $0C | ♀ | — | — |
| 13 | $0D | ♪ | RETURN | RETURN |
| 14 | $0E | ♫ | switch to lowercase set | same |
| 15 | $0F | ☼ | — | — |
| 16 | $10 | ► | — | — |
| 17 | $11 | ◄ | CRSR DOWN | CRSR DOWN |
| 18 | $12 | ↕ | RVS ON | RVS ON |
| 19 | $13 | ‼ | HOME | HOME |
| 20 | $14 | ¶ | DELETE | DELETE |
| 21 | $15 | § | — | — |
| 22 | $16 | ▬ | — | — |
| 23 | $17 | ↨ | — | — |
| 24 | $18 | ↑ | — | — |
| 25 | $19 | ↓ | — | — |
| 26 | $1A | → | — | — |
| 27 | $1B | ← | — | — |
| 28 | $1C | ∟ | RED | RED |
| 29 | $1D | ↔ | CRSR RIGHT | CRSR RIGHT |
| 30 | $1E | ▲ | GREEN | GREEN |
| 31 | $1F | ▼ | BLUE | BLUE |

PETSCII has no ESC at `$1B` — which is exactly why ANSI escape sequences never
worked natively on Commodore hardware.

CP437 carries the four card suits at `$03`–`$06`; PETSCII has them at `$D1`,
`$D3`, `$D8`, `$DA`. Same designer instinct, incompatible placement.

---

## $20–$3F — identical in both

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 32 | $20 | space | space | space |
| 33 | $21 | ! | ! | ! |
| 34 | $22 | " | " | " |
| 35 | $23 | # | # | # |
| 36 | $24 | $ | $ | $ |
| 37 | $25 | % | % | % |
| 38 | $26 | & | & | & |
| 39 | $27 | ' | ' | ' |
| 40 | $28 | ( | ( | ( |
| 41 | $29 | ) | ) | ) |
| 42 | $2A | * | * | * |
| 43 | $2B | + | + | + |
| 44 | $2C | , | , | , |
| 45 | $2D | - | - | - |
| 46 | $2E | . | . | . |
| 47 | $2F | / | / | / |
| 48 | $30 | 0 | 0 | 0 |
| 49 | $31 | 1 | 1 | 1 |
| 50 | $32 | 2 | 2 | 2 |
| 51 | $33 | 3 | 3 | 3 |
| 52 | $34 | 4 | 4 | 4 |
| 53 | $35 | 5 | 5 | 5 |
| 54 | $36 | 6 | 6 | 6 |
| 55 | $37 | 7 | 7 | 7 |
| 56 | $38 | 8 | 8 | 8 |
| 57 | $39 | 9 | 9 | 9 |
| 58 | $3A | : | : | : |
| 59 | $3B | ; | ; | ; |
| 60 | $3C | < | < | < |
| 61 | $3D | = | = | = |
| 62 | $3E | > | > | > |
| 63 | $3F | ? | ? | ? |

---

## $40–$5F — the case group

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 64 | $40 | @ | @ | @ |
| 65 | $41 | A | A | a |
| 66 | $42 | B | B | b |
| 67 | $43 | C | C | c |
| 68 | $44 | D | D | d |
| 69 | $45 | E | E | e |
| 70 | $46 | F | F | f |
| 71 | $47 | G | G | g |
| 72 | $48 | H | H | h |
| 73 | $49 | I | I | i |
| 74 | $4A | J | J | j |
| 75 | $4B | K | K | k |
| 76 | $4C | L | L | l |
| 77 | $4D | M | M | m |
| 78 | $4E | N | N | n |
| 79 | $4F | O | O | o |
| 80 | $50 | P | P | p |
| 81 | $51 | Q | Q | q |
| 82 | $52 | R | R | r |
| 83 | $53 | S | S | s |
| 84 | $54 | T | T | t |
| 85 | $55 | U | U | u |
| 86 | $56 | V | V | v |
| 87 | $57 | W | W | w |
| 88 | $58 | X | X | x |
| 89 | $59 | Y | Y | y |
| 90 | $5A | Z | Z | z |
| 91 | $5B | [ | [ | [ |
| 92 | $5C | \ | £ | £ |
| 93 | $5D | ] | ] | ] |
| 94 | $5E | ^ | ↑ | ↑ |
| 95 | $5F | _ | ← | ← |

CP437 follows ASCII-1967 (caret, underscore); PETSCII follows ASCII-1963
(up-arrow, left-arrow). `$5C` was backslash on the PET and became `£` on the
C64. These three positions are the only divergences in this block.

---

## $60–$7F — where ASCII lowercase would be

PETSCII puts graphics here. Every code in this range duplicates `$C0`–`$DF`
(add `$60`).

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 96 | $60 | ` | ─ | ─ |
| 97 | $61 | a | ♠ | A |
| 98 | $62 | b | │ | B |
| 99 | $63 | c | ─ | C |
| 100 | $64 | d | ─ | D |
| 101 | $65 | e | ▔ | E |
| 102 | $66 | f | ─ | F |
| 103 | $67 | g | │ | G |
| 104 | $68 | h | │ | H |
| 105 | $69 | i | ╮ | I |
| 106 | $6A | j | ╰ | J |
| 107 | $6B | k | ╯ | K |
| 108 | $6C | l | ▙ | L |
| 109 | $6D | m | ╲ | M |
| 110 | $6E | n | ╱ | N |
| 111 | $6F | o | ▛ | O |
| 112 | $70 | p | ▜ | P |
| 113 | $71 | q | ● | Q |
| 114 | $72 | r | ▁ | R |
| 115 | $73 | s | ♥ | S |
| 116 | $74 | t | ▏ | T |
| 117 | $75 | u | ╭ | U |
| 118 | $76 | v | ╳ | V |
| 119 | $77 | w | ○ | W |
| 120 | $78 | x | ♣ | X |
| 121 | $79 | y | ▕ | Y |
| 122 | $7A | z | ♦ | Z |
| 123 | $7B | { | ┼ | ┼ |
| 124 | $7C | \| | ▌ | ▌ |
| 125 | $7D | } | │ | │ |
| 126 | $7E | ~ | π | ░ |
| 127 | $7F | ⌂ | ◥ | ▧ |

---

## $80–$9F — second control block

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 128 | $80 | Ç | — | — |
| 129 | $81 | ü | ORANGE | ORANGE |
| 130 | $82 | é | — | — |
| 131 | $83 | â | — | — |
| 132 | $84 | ä | — | — |
| 133 | $85 | à | F1 | F1 |
| 134 | $86 | å | F3 | F3 |
| 135 | $87 | ç | F5 | F5 |
| 136 | $88 | ê | F7 | F7 |
| 137 | $89 | ë | F2 | F2 |
| 138 | $8A | è | F4 | F4 |
| 139 | $8B | ï | F6 | F6 |
| 140 | $8C | î | F8 | F8 |
| 141 | $8D | ì | SHIFT+RETURN | SHIFT+RETURN |
| 142 | $8E | Ä | switch to uppercase set | same |
| 143 | $8F | Å | — | — |
| 144 | $90 | É | BLACK | BLACK |
| 145 | $91 | æ | CRSR UP | CRSR UP |
| 146 | $92 | Æ | RVS OFF | RVS OFF |
| 147 | $93 | ô | CLEAR | CLEAR |
| 148 | $94 | ö | INSERT | INSERT |
| 149 | $95 | ò | BROWN | BROWN |
| 150 | $96 | û | LT. RED | LT. RED |
| 151 | $97 | ù | GREY 1 | GREY 1 |
| 152 | $98 | ÿ | GREY 2 | GREY 2 |
| 153 | $99 | Ö | LT. GREEN | LT. GREEN |
| 154 | $9A | Ü | LT. BLUE | LT. BLUE |
| 155 | $9B | ¢ | GREY 3 | GREY 3 |
| 156 | $9C | £ | PURPLE | PURPLE |
| 157 | $9D | ¥ | CRSR LEFT | CRSR LEFT |
| 158 | $9E | ₧ | YELLOW | YELLOW |
| 159 | $9F | ƒ | CYAN | CYAN |

The worst block for interoperability. CP437 puts accented Latin here; PETSCII
puts its entire color and cursor control set here. Any 8-bit-clean path
carrying CP437 text through a PETSCII terminal will trigger color changes and
screen clears from ordinary European text.

---

## $A0–$BF — graphics common to both charsets

This block survives a charset switch, which is why serious PETSCII artists
lean on it.

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 160 | $A0 | á | shifted space | shifted space |
| 161 | $A1 | í | ▌ | ▌ |
| 162 | $A2 | ó | ▄ | ▄ |
| 163 | $A3 | ú | ▔ | ▔ |
| 164 | $A4 | ñ | ▁ | ▁ |
| 165 | $A5 | Ñ | ▏ | ▏ |
| 166 | $A6 | ª | ▒ | ▒ |
| 167 | $A7 | º | ▕ | ▕ |
| 168 | $A8 | ¿ | ▄ | ▄ |
| 169 | $A9 | ⌐ | ◤ | ▨ |
| 170 | $AA | ¬ | ▄ | ▄ |
| 171 | $AB | ½ | ├ | ├ |
| 172 | $AC | ¼ | ▗ | ▗ |
| 173 | $AD | ¡ | └ | └ |
| 174 | $AE | « | ┐ | ┐ |
| 175 | $AF | » | ▂ | ▂ |
| 176 | $B0 | ░ | ┌ | ┌ |
| 177 | $B1 | ▒ | ┴ | ┴ |
| 178 | $B2 | ▓ | ┬ | ┬ |
| 179 | $B3 | │ | ┤ | ┤ |
| 180 | $B4 | ┤ | ▎ | ▎ |
| 181 | $B5 | ╡ | ▍ | ▍ |
| 182 | $B6 | ╢ | ▐ | ▐ |
| 183 | $B7 | ╖ | ▔ | ▔ |
| 184 | $B8 | ╕ | ▀ | ▀ |
| 185 | $B9 | ╣ | ▃ | ▃ |
| 186 | $BA | ║ | ▟ | ✓ |
| 187 | $BB | ╗ | ▖ | ▖ |
| 188 | $BC | ╝ | ▝ | ▝ |
| 189 | $BD | ╜ | ┘ | ┘ |
| 190 | $BE | ╛ | ▘ | ▘ |
| 191 | $BF | ┐ | ▚ | ▚ |

---

## $C0–$DF — graphics vs. uppercase

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 192 | $C0 | └ | ─ | ─ |
| 193 | $C1 | ┴ | ♠ | A |
| 194 | $C2 | ┬ | │ | B |
| 195 | $C3 | ├ | ─ | C |
| 196 | $C4 | ─ | ─ | D |
| 197 | $C5 | ┼ | ▔ | E |
| 198 | $C6 | ╞ | ─ | F |
| 199 | $C7 | ╟ | │ | G |
| 200 | $C8 | ╚ | │ | H |
| 201 | $C9 | ╔ | ╮ | I |
| 202 | $CA | ╩ | ╰ | J |
| 203 | $CB | ╦ | ╯ | K |
| 204 | $CC | ╠ | ▙ | L |
| 205 | $CD | ═ | ╲ | M |
| 206 | $CE | ╬ | ╱ | N |
| 207 | $CF | ╧ | ▛ | O |
| 208 | $D0 | ╨ | ▜ | P |
| 209 | $D1 | ╤ | ● | Q |
| 210 | $D2 | ╥ | ▁ | R |
| 211 | $D3 | ╙ | ♥ | S |
| 212 | $D4 | ╘ | ▏ | T |
| 213 | $D5 | ╒ | ╭ | U |
| 214 | $D6 | ╓ | ╳ | V |
| 215 | $D7 | ╫ | ○ | W |
| 216 | $D8 | ╪ | ♣ | X |
| 217 | $D9 | ┘ | ▕ | Y |
| 218 | $DA | ┌ | ♦ | Z |
| 219 | $DB | █ | ┼ | ┼ |
| 220 | $DC | ▄ | ▌ | ▌ |
| 221 | $DD | ▌ | │ | │ |
| 222 | $DE | ▐ | π | ░ |
| 223 | $DF | ▀ | ◥ | ▧ |

---

## $E0–$FF — duplicate range

PETSCII `$E0`–`$FE` duplicate `$A0`–`$BE`. `$FF` is a second copy of `$DE`
(π), placed at the top of the range by Microsoft BASIC so the π constant
wouldn't collide with keyword tokens.

| Dec | Hex | CP437 | PETSCII | Shifted |
|---|---|---|---|---|
| 224 | $E0 | α | (dup $A0) | (dup $A0) |
| 225 | $E1 | ß | ▌ | ▌ |
| 226 | $E2 | Γ | ▄ | ▄ |
| 227 | $E3 | π | ▔ | ▔ |
| 228 | $E4 | Σ | ▁ | ▁ |
| 229 | $E5 | σ | ▏ | ▏ |
| 230 | $E6 | µ | ▒ | ▒ |
| 231 | $E7 | τ | ▕ | ▕ |
| 232 | $E8 | Φ | ▄ | ▄ |
| 233 | $E9 | Θ | ◤ | ▨ |
| 234 | $EA | Ω | ▄ | ▄ |
| 235 | $EB | δ | ├ | ├ |
| 236 | $EC | ∞ | ▗ | ▗ |
| 237 | $ED | φ | └ | └ |
| 238 | $EE | ε | ┐ | ┐ |
| 239 | $EF | ∩ | ▂ | ▂ |
| 240 | $F0 | ≡ | ┌ | ┌ |
| 241 | $F1 | ± | ┴ | ┴ |
| 242 | $F2 | ≥ | ┬ | ┬ |
| 243 | $F3 | ≤ | ┤ | ┤ |
| 244 | $F4 | ⌠ | ▎ | ▎ |
| 245 | $F5 | ⌡ | ▍ | ▍ |
| 246 | $F6 | ÷ | ▐ | ▐ |
| 247 | $F7 | ≈ | ▔ | ▔ |
| 248 | $F8 | ° | ▀ | ▀ |
| 249 | $F9 | ∙ | ▃ | ▃ |
| 250 | $FA | · | ▟ | ✓ |
| 251 | $FB | √ | ▖ | ▖ |
| 252 | $FC | ⁿ | ▝ | ▝ |
| 253 | $FD | ² | ┘ | ┘ |
| 254 | $FE | ■ | ▘ | ▘ |
| 255 | $FF | (nbsp) | π | π |

Quirk: the π character reads back as 255 from a string literal but 222 from
`GET`.

---

## Notes on translation

**PETSCII to ASCII** is nearly trivial. Four operations cover it:

1. Swap the case of `$41`–`$5A`.
2. Remap `$C1`–`$DA` down to `$41`–`$5A`.
3. Translate `$0D` (RETURN) and `$14` (DELETE) to CR and BS.
4. Drop or map the color and cursor controls in `$00`–`$1F` and `$80`–`$9F`.

That is the whole conversion, and it is why the translate tables in Novaterm
and CCGMS are so small.

**CP437 to PETSCII** is not tractable as a byte mapping. Three separate
problems:

- CP437 concentrates its box-drawing in `$B3`–`$DA`, which is exactly where
  PETSCII has its C= graphics and its uppercase letters.
- CP437's double-line forms (`═ ║ ╔ ╬`) have no PETSCII equivalent at all.
- Even the single-line forms differ in where the stroke sits within the 8×8
  cell. PETSCII's variants at `$C3`–`$C8` are deliberately offset for bar
  charts and have no CP437 counterpart.

This is why CCGMS Ultimate and Novaterm don't attempt a smart mapping. They
run either a PETSCII mode or a CP437/ANSI mode, and switching means loading a
different character set into VIC bank RAM rather than translating bytes.
