# Frame screens: sea and port layout, status panels, message / menu / list windows (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N, "MENU N" = MENU.DAT entry N. Screen coordinates are the 640×400 game area
(VGA y + 40). Text positions are given in pixels; the code uses 8-px columns (`col·8`) and pixel rows.
Status: ✅ read from code (and checked by `tools/frame.py` renders) · 🔎 read, details skipped · ❓ not decoded.

```
build/venv/bin/python -I tools/frame.py [OUT]          # default OUT = assets/frame
  frame_sea_type1.png  frame_sea_type2.png             GRAPH.DAT 2 / 4 (640×400, opaque)
  frame_port_type1.png frame_port_type2.png            GRAPH.DAT 3 / 5
  font_ascii.png, font_digits.png, font_hangul.png     HANKAKU.FNT, DATA1[14] digits, ALL_FONT.16P (white atlases)
  check_sea.png, check_port.png                        composed check screens, layout type 1 (sample values)
  check_sea_type2.png, check_port_type2.png            the same on the type-2 frames
  sample_faces.png, sample_message.png, sample_popup.png, sample_list.png   windows drawn by the §4 rules
  index.json                                           regions, fields, gauges, dials, text engine, fonts,
                                                       window rules, list layouts, check-render state
```
Already documented and only referenced: frame UI sprites (sprites.md §3: wheel, compass, tabs, wind dial,
window pieces, digits), sea view (seamap.md), walking town (town_walk.md), portraits (faces.md).

---------------------------------------------------------------------------------------------

## 1. Frame pictures ✅

| picture | screen | layout | drawn by |
|---|---|---|---|
| GRAPH.DAT 2 | sea | TYPE 1 (`[0xC30] & 0x80` set, **default**): English labels, tabs INFORMATION… | 0x837D (0x8480, drawn twice), 0x1D562 (after the chart / info) |
| GRAPH.DAT 4 | sea | TYPE 2 (bit clear): Korean labels, tabs 정보 경영 명령 항해 | same |
| GRAPH.DAT 3 | port | TYPE 1 | 0x8AB2 (0x8BA4), 0x1D544, 0x1D64A (chart / info), 0x26EEB, 0x31AA9 (after a duel, twice with `[0x9524] ^= 1`) |
| GRAPH.DAT 5 | port | TYPE 2 | same |

`bx = ([0xC30] & 0x80) ? 2 : 4` (sea) / `? 3 : 5` (port), `0x5A51(bx, x 0, y 0)`, 640×400, opaque.
Option: 환경 row 2 레이아웃 (newgame.md §7.1); toggling it from the 기능 menu rebuilds the screen
(0x20FE4 → 0x16B49). Several sites draw the frame twice with `[0x9524] ^= 1` in between (0x31AC0): the
frame goes to both video pages 🔎; 0x86F2 / 0x7F00 likewise draw their fields twice.

**Palette.** The four frames use **colours 0..7 only** (histograms: 0, 1, 2, (3), 4, 5, 6, 7). Colours 0..7
are identical in the main table 0x40ECE and in all five time-of-day / weather tables DS:0xAD22 + 0x30·k,
so the frame never tints with time of day or weather, and `assets/images/graph_02..05.png` (main table)
were already correct. The only other palette shown with the frame is the 항해도 parchment DS:0xAF50
(0x1D5F4, the chart is drawn inside the map window): there colour 3 = `f4c` (vs `d6a`) and colour 6 =
`fa0` (vs `fa6`), a barely visible tint of the frame during the chart.

### 1.1 Regions (both screens) ✅

| region | rect (x, y, w, h) | notes |
|---|---|---|
| map window | (96, 8, 384, 384) | sea view 24×24 chips (seamap.md §7) / town map (town_walk.md §2); black in the picture |
| menu tabs | (616, 72 + 80t, 24, 80), t = 0..3 정보/편성(경영)/지휘(명령)/항해 | in the picture; TRANSIT.DAT highlight while open (sprites.md §3.3); hit rects x 618..639 |
| date scroll | sea (488, 8, 144, 32); port (8, 8, 80, 48) | "A.D." printed in the picture |

### 1.2 Sea frame (GRAPH.DAT 2 / 4) ✅
Panel rects below are measured from the picture (decoration, approximate); the code-relevant positions are
the fields of §2 / §3, the wheel, compass and tabs.

| region | rect | content |
|---|---|---|
| State panel | (8, 16, 80, 208) | header "State"; 7 labels (TYPE 1 / TYPE 2): Rudder 선회력, Sails 추진력, Hull 내구도, Draft 흘수, Range 감시범위, Crew 승무원, Con. 컨디션; a dark gauge slot under each |
| Cargos panel | (8, 232, 80, 160) | header "Cargos"; icons water, food, lumber, shot at y ≈ 258, 290, 320, 350 |
| date scroll | (488, 8, 144, 32) | "A.D." + year month day (§2.1) |
| navigation panel | (488, 56, 128, 208) | labels Wind 풍향, Current 조류, Direction 침로, Speed … knot 속도 … 노트, Day 일수 |
| ship's wheel | (496, 272, 120, 120) | 9 pieces 32×32 at x 496/536/576, y 272/312/352 (sprites.md §3.2) |

### 1.3 Port frame (GRAPH.DAT 3 / 5) ✅

| region | rect | content |
|---|---|---|
| date scroll | (8, 8, 80, 48) | "A.D." + year, "Mon.dd" |
| mermaid picture | (0, 56, 96, 168) | decoration; white clock box (8, 142, 72, 16) |
| User Data panel | (8, 224, 80, 168) | Fame 명성, Funds 소지금 ···, Gold Coin 금화, Gold Ingot 금괴 |
| port name scroll | (488, 8, 144, 40) | region + port name (§3) |
| market panel | (488, 64, 128, 232) | TYPE 1: Economic growth rate / investments / Technological progress / investments / Price index; TYPE 2: 상업가치, 상업투자액, 공업가치, 공업투자액, 평균물가; "%" printed in the picture at (592, 228) |
| compass | (504, 304, 96, 96) | arrows 40×24 at (528,304) N, (552,336) E, (528,368) S, (504,336) W (town_walk.md §5) |

---------------------------------------------------------------------------------------------

## 2. Sea status panel ✅

Everything is printed with `ESC C0 ESC B7` (colour 0 on colour 7, opaque cells), right margin col 79.
Digits '0'..'9' come from the DATA1[14] glyphs 0x24D0 (`[0xC2E]` = 1 after start-up, 0x16DEB); other
ASCII from HANKAKU.FNT (8×16), Hangul from ALL_FONT.16P (16×14) — §5.

### 2.1 Every sea frame (0x6D03 → 0x6E32, after the fleets are drawn) ✅

| field | pos | format | value | routine |
|---|---|---|---|---|
| year | (536, 16) | `%2d` | 1501 + `[0x56E]` | 0x7053 → 0x7026 (sets right margin 79) |
| month | (576, 16) | `%s` | DS:0x94F6[`[0x56F]`] → "Jan".."Dec" (English in both layouts) | 0x706C |
| day | (608, 16) | `%2d` | `[0x570]` + 1 | 0x7096 → 0x7026 |
| wind dial | (568, 64) 40×40 | DATA1[14] i4 put mode 0 | `0x490 + 0x320·dir`, dir = `([0xC3D] >> 3) & 7`; **force 0 → calm dial 0x1D90** | 0x8E07 → 0x8D97(y, dir, force) |
| wind force | (536, 88) | `%d` | `[0xC3D] & 7` (0 is printed too) | 0x8D97 |
| current dial | (568, 112) | same | `[0xC3E]` same bits | 0x8D97 |
| current force | (536, 136) | `%d` | `[0xC3E] & 7` | 0x8D97 |
| heading dial | (568, 160) | same | player fleet `+0x1A` (0..7; 8 = no heading → calm dial); no number (force arg −1) | 0x8D97 |
| speed | (552, 208) | `%2d` | `([0xC15C] + 1) / 2` knots; `[0xC15C]` = 0x30C2F fleet speed set by the move step 0x310F8 (kept unchanged while stopped) | 0x6E42 |

The needle points the way the wind/current **blows toward** (as in battle, sprites.md §6.3). Only the
date is shown at sea, no clock (time of day is only the palette, seamap.md §8).

### 2.2 0x7F00 — State bars, cargo, days ✅

Runs only at sea (`[0xC3A] = 0xFF`); in port it returns at once (so the sight range is not rebuilt in
port). Per in-use slot s (0..9) of the player fleet: crew `+0`, ship max crew `ship +0x15`, cargo, morale,
the speed `a` of info.md §1.1 (T = DS:0x714 indexed by `|windDir − heading|` and the ship's *class*,
captain's navigation level and SEA) — the **slowest** ship (strict `<`, first wins) gives rudder, sail
and draft. Then `[0xC176]` sight range (commands.md §0.3), then twice (both pages 🔎):

| bar | gauge y | value 0..100 (clamped, `/2` → 0..50 px) |
|---|---|---|
| Rudder 선회력 | 72 | slowest ship slot `+4` rudder (raw value, not relative to the class) |
| Sails 추진력 | 96 | slowest ship slot `+5` sail (raw) |
| Hull 내구도 | 120 | min over ships of slot `+2` hull (start 100) |
| Draft 흘수 | 144 | `100 · cargo(slowest)+0xA load / class(+6) capacity` |
| Range 감시범위 | 168 | `100 · [0xC176] / 24` |
| Crew 승무원 | 192 | `100 · Σ crew / Σ ship max crew (+0x15)` (divisor 0 → 1) |
| Con. 컨디션 | 216 | `Σ(crew · morale cargo+0x1C) / Σ crew` (crew-weighted morale; 0 → 1) |

**Gauge 0x913F(col, y, v)**: `v = clamp(v, 0, 100) / 2`; fill (16+10 .. 16+9+v, y+2 .. y+5) in colour
`[0xBE90]`, then (26+v .. 75, y+2 .. y+5) in `[0xBE92]` (0x219DD inclusive rect fill). Both colours are
set by 0x91BE(2, 1) everywhere (0x15BFE …): **filled = colour 2 (red), empty = colour 1 (blue)**, a
50×4 px bar at x 26..75. Same gauge is used by the ship / person info screens and the environment screen.

| cargo / days | pos | format | value |
|---|---|---|---|
| water | (48, 264) | `%5d` | Σ cargo `+0` / 10 (barrels) |
| food | (48, 296) | `%5d` | Σ cargo `+2` / 10 |
| lumber 자재 | (48, 328) | `%5d` | Σ cargo `+4` |
| shot 포탄 | (48, 360) | `%5d` | Σ cargo `+6` |
| days at sea 일수 | (552, 240) | `%3d` | `[0x2D54]` (byte) |

Not shown anywhere at sea: weather (only palette, storm picture 58 and sound), gold, fleet / hero name.

### 2.3 When the sea screen is (re)drawn ✅

- Sea entry 0x837D (출항 via 0x27176, loading a sea save 🔎): `[0xC3A] = 0xFF`, DATA1[11]
  chips, DATA1[7] wheel → `[0xC0E]:0x3EA0`, BGM, frame 2/4, date (0x7053/0x706C/0x7096), chip cache
  cleared (0x20D3), window build 0x69DA, palette 0x19150, 0x7F00, `[0x9605] = 0xFF` (no lit wheel
  piece), storm sound if weather 1, fade in 0x983F.
- Every sea frame 0x6D03: §2.1 fields (date, dials, speed).
- 0x7F00: sea entry, window rebuild after a block change (0x6B9A), daily (0x19135), after an incident
  report (0x19854), after every sea command (0x20A6E), after the chart (0x1D587), sea events (0x306AC),
  landing (0x33C70, 0x33DF1, 0x3428E, 0x343D6).
- After the 항해도 / info screens: frame + date + 0x7F00 + 0x8E07 (0x1D562..0x1D58C).

---------------------------------------------------------------------------------------------

## 3. Port status panel 0x86F2 → 0x84FD ✅

0x86F2 hides the mouse and calls 0x84FD twice (both pages 🔎). 0x84FD prints `ESC C0 ESC B7` and then:

| field | pos | format | value |
|---|---|---|---|
| year | (48, 16) | `15%2d` | `[0x56E] + 1` → "1522"; **quirk: 1501..1509 print "15 1".."15 9"** |
| month.day | (24, 40) | `%s.%2d` | month name DS:0x94F6[`[0x56F]`], `[0x570] + 1` → "Jan. 1" |
| clock | (8, 144) | `%2d:%02d %c.M` | h = `(tick/3 + 11) % 12 + 1`, m = `20·(tick % 3)`, 'A' if tick < 36 else 'P' (tick `[0x571]`, 72/day) |
| fame 명성 | (48, 248) | `%5u` | `max(+0, +2, +4)` of family record `[0x1241]` (0x5ADC: 교역, 해적, 모험 fame) |
| gold coins 금화 | (40, 320) | `%5d` | gold DS:0x123A (u32) `% 10000` |
| gold ingots 금괴 | (40, 360) | `%5u` | gold `/ 10000` (printed after `\n`: left margin col 5, line pitch 40) |
| region | (488, 8) | msg 385 + market `+0x21`, then msg 1135 "지방 " | market ports (< 100) only; e.g. "이베리아지방 " |
| supply port | (488, 8) | msg 1136 "보급항" | ports ≥ 100 |
| port name | (488, 24) | msg 1137 `\n%s항` | port record `+4`; the line (488, 24, 144, 16) is first filled with colour 7 (0x906) |
| 상업가치 economy | (560, 96) | `%5d` | market `+0` |
| 상업투자액 | (560, 128) | `%5u` | market `+2` (this month's economy investment) |
| 공업가치 industry | (560, 160) | `%5d` | market `+4` |
| 공업투자액 | (560, 192) | `%5u` | market `+6` |
| 평균물가 price index | (560, 224) | `%4d` | `Σ market[+0xE + c] (c = 0..9) / 10 + 50` (0x1AE1E), "%" in the picture |

Market fields are printed with left margin col 70 and line pitch 32 (`%5d\n%5u\n%5d\n%5u\n%4d`), only for
market ports; `[0xC6E2]` keeps the market pointer. Afterwards the line pitch is reset to 24.

**When**: port entry 0x8AB2 (frame 3/5, map paint 0x1AB78, 0x86F2, palette 0x19150, `[0x9605] = 0xFF`,
BGM 0x1AD8A, fade in); the start of every walk session 0x1B4E0 (i.e. after each building); after the
info / chart screens (0x1D55B, 0x1D661); after a duel in port (0x31AE1) and other script screens
(0x319F9..0x31A85); 0x1AE42 (panel, then a popup menu 0x13CA3 — building menus); and from the shops / bank / shipyard after money
changes (0x24059 … 0x2D999, 25 sites). The panel is not redrawn while walking (the clock stands still
while walking, town_walk.md §8).

### 3.1 Checks (`check_*.png`) ✅
- Sea: the seven gauges fall exactly into the dark slots under the labels, the dials into the round
  sockets at x 568, the digits next to Wind / Current / Speed / Day and in the Cargos box.
- Port, TYPE 2: every market value sits under its label (상업가치 y 80 → value y 96 …). **TYPE 1**: the
  English labels take three lines per block, so "rate:" and "progress:" get the 경제/공업 values but the two
  investment values print one line *below* "investments:" — the original looks like that.
- With the new-game data segment as is (`[0x56E]` = 0) the port year prints "15 1" (the quirk above); the
  check render uses 1522.

---------------------------------------------------------------------------------------------

## 4. Windows ✅

### 4.1 Frame window 0x71FA(ax = col x, dx = y, bx = cols w, push style s, push h) ✅
Box (8x, y, 8w, h), DATA1[14] pieces 8×8 i4 (sprites.md §3.1):
- corners TL 0x2C20 at (x, y), TR 0x2C40 at (x+w−1, y), BL 0x2C60 at (x, y+h−8), BR 0x2C80 at (x+w−1, y+h−8);
- edges of style s at `0x2CA0 + 0x80·s`: top `+0` over cols x+1..x+w−2 at y, left `+0x20` and right
  `+0x40` over rows y+8..y+h−9, bottom `+0x60` at y+h−8; tiled by 0x8A6 (pattern row = screen y & 7);
- interior (x+1 .. x+w−2 cols, y+8 .. y+h−9) filled with **colour 7** (0x906);
- text: left margin col x+1, right margin col x+w−2, cursor (x+1, y+8), `ESC C0 ESC B7`.
Style 0 = gold/red rope (most windows), 1 and 2 = darker variants (all three in `sample_popup.png`); styles 1/2 are
used by a few callers (0x1E437, 0x1E72C, 0x1E756, 0x1E7ED, 0x1ED29, 0x1F8E8, 0x2088B, 0x20F61, 0x2FE97).

### 4.2 Message window 0x76EB(ax = col x, dx = y, bx = cols w, push style, push h) ✅
```
0x5086(x, y, w+1 cols, h+4 rows)        save the background (incl. shadow) on the window stack [0xC10]
0x761B: 0x71FA(x, y, w, style, h)
        text margins col x+2 .. x+w−3, cursor (x+2, y+16)      (one more column and 8 px more than 0x71FA)
        drop shadow, AND (put mode 2) with 2-row dither patterns, i.e. black 50 % checkerboard:
          right:  col x+w, rows y+4 .. y+h+3, pattern DS:0x9560 (AF/5F: left 4 px)
          bottom: rows y+h .. y+h+3, col x pattern DS:0x9550 (FA/F5: right 4 px), cols x+1..x+w−1 DS:0x9558 (AA/55)
```
So the shadow is offset 4 px right / 4 px down and 4 px thick. Closed (background restored) by 0x780F,
which pops the newest saved block (record: x col, y, w cols, h before the pixels): with display effects on
and h > 16 it restores 8-row strips from the top and the bottom edge toward the middle, one tick per step
(h/16 + 1 steps), else at once. 0x7399 (title / new-game screens 0x15C3F…0x1723A, cargo windows 0x1C79D /
0x1CBAD, 0x1E942, 0x2008A, environment 0x20ECC, 0x28E4C, 0x2B761, 0x2D3D9, 0x33F82) saves w × h (no
shadow), and with `[0xC30] & 1` opens the frame from the centre column outward, one column per side per
tick; then 0x71FA, margins x+2..x+w−3, cursor (x+2, y+16).

Common geometries (callers' constants, x/y/w in px):

| use | x, y, w, h | style |
|---|---|---|
| sea event / sighting report 0x3024A, townsfolk talk 0x63BF | 128, 160, 288, 128 | 0 |
| reports 0x1ED29 / 0x2088B | 128, 160, 288, 128 / 72 | 1 |
| battle and many reports (0x1027F, 0x1F7D8, 0x20042 …) | 160, 128, 240, 96 | 0 |
| fleet-organisation prompts (0x1FF81, 0x20009) | 160, 64, 240, 72 | 0 |
| voyage log 0x1DCC1 | 120, 32, 336, 320 | 0 |
| popup menu 0x13CA3 | §4.4 | 0 |

Text: line pitch `[0x8B72]` = 24 by default (16 or 40 in a few places), word wrap at the right margin
(0x490E), key-wait marker 0x140EA: ▼ (DATA1[14] 0x20B0, 16×16 1-bit stamped in **colour 2**) at the middle
column of the margins, on the current line if the cursor is at the left margin, else 24 px lower
(clamped to col 78, y 384), blinking 4 ticks on / 4 off until a key.

### 4.3 Face (speech) windows 0x7C45(al = col x, dl = y) ✅
0x5086 save + 0x71FA(x, y, 39 cols, style 0, 144): a 312×144 window, **no shadow**; portrait 64×80 at
(8(x+2), y+16); text margins col x+11 .. x+36, cursor (8(x+11), y+16).

| routine | window | portrait | text area | who |
|---|---|---|---|---|
| 0x7D71(person) / 0x7C8E (stranger, person ≥ 120) | (104, 16, 312, 144) | (120, 32) | x 192..399, from y 32 | upper = the hero / own side |
| 0x7D9F(person) / 0x7CAE / 0x7CCE(set, face) / 0x7D45(kao, name) | (160, 192, 312, 144) | (176, 208) | x 248..455, from y 208 | lower = the person spoken to |
| 0x7CF9(kao, name) | 0x71FA(96, 288, 376, 104) | (112, 300) | x 184..455, from y 296 | bottom box, msg 1134 name |
| 0x8D4B(msg …) | 0x71FA(240, 8, 240, 128) | — (building picture GRAPH k+6 at (104, 16)) | x 256..455, from y 16 | building keeper |

Clear-and-select helpers: 0x7DCD upper (fill (192, 32, 216, 112) colour 7, cursor (192, 32)), 0x7E07
lower (fill (248, 208, 216, 112), cursor (248, 208)), 0x7E95 tavern girl (fill (248, 232, 216, 88)),
0x7E41 bottom box (fill (176, 320, 288, 64)). **Speaker name**: not drawn by the window code; it is the
first line of the text itself, `§name§` + newline (scenario lines "§집사 마르코§\n…", msgs 787–790; msg
1134 `§%s§` for 0x7CF9 / 0x7D45), in the same colour 0 on 7 — '§' is the ALL_FONT glyph 0xA1D7.
Portraits use colours 0..7 only; the window interior is colour 7 (plane 3 = 0), which settles faces.md
open question 1 (indices 0..7).

### 4.4 Popup menu 0x13CA3(ax = col x, dx = y, bl = n, push cancellable, push items) ✅
`mw` = widest item in columns (0x13560 / 0x4D16). Window 0x76EB(x, y, mw + 4, style 0, 24·(n+1)) with
shadow. Item i is centred: col `x + 2 + (mw − width_i)/2`, y `y + 16 + 24i`; hot rect (8(x+1), y+16+24i)
– (8(x+mw+3), +16). **Selection = XOR colour 7 over the hot rect** (0x12F92, 0x63E mode 0x107 on the
solid source): cream ↔ black. **Disabled** item (bit i of `[0xA9BA]`/`[0xA9BB]`): 0x6911 stamps the AA55
dither (DATA1[14] 0x280) in colour 7 over the item → greyed. The command menus (정보 0x20559 etc.) call
0x204A2(y, n, items), which right-aligns the window at col `0x4A − mw` (ends at x 624 + shadow, next to
the tabs). Variant 0x13D50 uses 0x761B (frame without background save). The four command menus call
0x204A2 with y = 48 (정보, 10 items), 136 (편성), 224 (지휘, 항해; 6 items each). Variant **0x13ECB** opens the
menu at the mouse pointer (from 0x4EBC): left edge = pointer x − 4·(mw + 4) when that fits, top = pointer y − 24
when y > 24; the battle flagship menu MENU 50 (0xB6D3) uses it every turn. The yes/no prompt 0x13FDB
(script E9 …) draws a picture box (resource `[0xC0E]`, type 2 of DS:0xA9C6) at pointer − (40, 32), or with
the pointer parked at (639, 399) at x = 4·(left + right − 10), y = cursor y (+24 unless at the left margin).

### 4.5 List window 0x153BF(code, n) → 0x147E0 ✅ (thumb 🔎)
Layout table DS:0x1034 + 10·code: `x col, y, w cols, rows r, scroll top` (21 codes = the 21 MENU 47
headers; `index.json` → `listLayouts`). Window = (8x, y, 8(w+4), 16r + 40), filled colour 7, pieces
DATA1[14] `0x39A0 + 0x20·k` (8×8):

| piece k | at | role |
|---|---|---|
| 0 / 1 / 2 | (x, y) / cols x+1..x+w+2 at y / (x+w+3, y) | top-left, top, top-right |
| 3 | col x, rows y+8 .. y+h−9 (every 8) | left edge |
| 4 | (x+w+3, y+8) | right edge |
| 5 / 6 / 7 | (x, y+16) / cols x+1..x+w+2 / (x+w+3, y+16) | header underline (rows y+20..23) |
| 8 / 9 / 10 | (x, y+24) / cols x+1..x+w / (x+w+1, y+24) | top of the list box |
| 11 | col x+w+1, rows y+32 .. y+h−9 | list / scroll-bar divider |
| 12 / 6 / 13 | (x, y+h−8) / cols x+1..x+w / (x+w+1, y+h−8) | bottom |
| 14 / 15 | cols x+w+2 / x+w+3, rows y+40 .. y+h−17 | scroll track (black inside) |
| 0x3BA0 / 0x3C20 (16×16) | (x+w+2, y+24) / (x+w+2, y+h−16) | scroll buttons up / down |

Header: MENU 47 item `code` (from MENU 0x2F), centred over w+2 columns at y+4, `ESC C0 ESC B7`. Rows: r
visible rows of 16 px at (8(x+1), y+32+16i), width 8w, printed by the far table DS:0xAA3A row printer;
highlight like §4.4 (XOR 7 on the row rect). Scroll thumb geometry `[0xC13E]` = 8(x+w+2), `[0xC140]` =
y+41, track length h−58, thumb `r·track/n` (≥ 1) 🔎 — drawing of the thumb not traced.

---------------------------------------------------------------------------------------------

## 5. Text engine (for exact placement) ✅

| var | meaning | default |
|---|---|---|
| `[0x8B6E]` / `[0x8B70]` | cursor col (0..78) / y px (0..400); 0x4655(ax col, dx y) sets both (−1 keeps) | |
| `[0x8B74]` / `[0x8B76]` | left / right margin col (wrap at right, newline returns to left) | 0 / 79 |
| `[0x8B72]` | line pitch px | 24 |
| `[0x8B7B]` / `[0x8B7C]` | foreground / background colour (bg 0 = transparent cells) | 7 / 0 |

Escapes (0x4970): `ESC = y x` locate (`y = (c−0x20)·8`, `x = c−0x20`), `ESC C n` fg, `ESC B n` bg,
`ESC R n` left margin `n−0x20`, `ESC M n` alternative bg `[0x8B7A]` (used when bg = 0), `ESC F n` font
flags `[0x8B7D]` (4/5 = black drop shadow at +1,+1 under a transparent glyph), `ESC W` wait; CR = left
margin, LF = newline (**no-op when the cursor is already at the left margin**, so `\n\n` gives no empty
line), BS = back. A glyph may start at any col ≤ right margin (and ≤ 77/78); after it, col > right →
newline. Cells: ASCII 8×16 (HANKAKU.FNT 0x20..0x7F, 16 B each); EUC-KR 16×14 (ALL_FONT.16P: 3478
records of 30 B = code u16 stored **trail byte first** + 14 rows × 2 B, in glyph-index order; index
`(hi − (hi ≥ 0xB0 ? 0xA4 : 0xA1))·94 + lo − 0xA1`, records 0..1999 in buffer `[0xC2A]`, the rest in
`[0xC2C]`); digits '0'..'9' from DATA1[14] 0x24D0 + 16·d (8×16) once `[0xC2E]` is set (0x16DEB, always
after start-up). With bg ≠ 0 the whole cell (8×16 or 16×14) is painted (opaque).

---------------------------------------------------------------------------------------------

## For the remaster ("original screen layout" mode)

1. Draw `assets/frame/frame_{sea|port}_type{1|2}.png` at (0,0) of a 640×400 canvas (type 1 by default,
   option 레이아웃); never tint it (colours 0..7). Map window (96, 8, 384×384) on top, then sprites.
2. Sea panel: §2.1 fields every frame, §2.2 bars/cargo/days on the 0x7F00 events (or simply every frame —
   same pixels); gauge = 50×4 px red/blue at x 26, y+2; wind/current/heading dials 40×40 at x 568
   (`assets/sprites/ui/wind_dial_*`, calm when force 0 / heading 8), force digits at (536, y+24).
3. Port panel: §3 fields; region/port name only via the messages listed; economy block only for market
   ports; year quirk "15 n" for 1501..1509 if exactness matters.
4. Text: colour 0 on colour 7 opaque cells; DATA1 digits (`font_digits.png`), HANKAKU ASCII
   (`font_ascii.png`), ALL_FONT Hangul (`font_hangul.png`, row = lead byte A1..AC/B0..C8, col = trail − 0xA1); right-align
   by the printf widths (`%5d` = 5 cells of 8 px).
5. Windows: 0x71FA pieces (style 0..2, interior colour 7), 0x76EB = 0x71FA + 4-px checker shadow + saved
   background; face windows at (104,16) / (160,192) 312×144 with portrait at +16,+16 and text at +88,+16;
   speaker name is the `§name§` first line; ▼ key-wait in colour 2, blinking 4/4 ticks; menus centred
   items, XOR-7 highlight, dither-greyed disabled items, right-aligned at col 74 for the tab menus;
   lists per `listLayouts`.
6. `index.json` has every rect and field (`fields[]`: screen, id, x, y, format, colours, source, redraw).

## Open questions ❓

1. Double drawing (frame, 0x84FD, 0x7F00 loop): both video pages through `[0x9524]`? Only the page flip of
   0x5A51 was seen; the text routines' page handling was not traced 🔎.
2. List scroll thumb drawing (0x14CEE fills colour 15? and the thumb routine) and the list row highlight
   (0x154C2 uses rect outlines 0x2174C when the cell width < 8) 🔎.
3. Speed `[0xC15C]` while stopped keeps the last value (heading 8 skips 0x30C2F) — confirm in a running game.
4. Rudder / Sails bars show the raw slot values (class maxima 50..90 / 60..95, class +2 / +3), not the ratio
   to the class maximum, so a new ship never fills its bar — faithful, but worth confirming on screen.
5. 0x7399 / 0x780F opening / closing animations: step timing only roughly read.
6. Supply ports (≥ 100) leave the market block empty; whether a later market-port panel after a supply port
   could leave stale values is moot because the frame is redrawn on every port entry.
