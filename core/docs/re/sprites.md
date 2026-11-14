# Sprites, icons and small pictures (ships, UI, figureheads, gambling, sea battle, duel)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
Screen coordinates are in the 640×400 game area (the VGA puts add 40 lines for the 480-line mode).
Status: ✅ read from code and checked by rendering · 🔎 read, some details skipped · ❓ not decoded.

```
build/venv/bin/python -I tools/sprites.py [OUT] [GROUP ...]   # default assets/sprites, groups:
    ships  ui  figureheads  gambling  battle  duel             # OUT/<group>/*.png (RGBA) + index.json
```
Every `index.json` has a `files` list (name, size, what it is, source file + offset, format, palette) and the
group's geometry/palette notes. The walking town (CHAR.LZW, PORTCHIP, PORTMAP) is not covered here.

---------------------------------------------------------------------------------------------

## 0. Files, formats, blitters ✅

| file | size | content | loaded by | § |
|---|---|---|---|---|
| `GRAPH.DAT` 28..52 | | 25 ship class pictures 128×96 | 0x7EE9 → 0x5A51 | 1 |
| `DATA1.LZW` 11, 0x4000.. | (32 KB entry) | 32 world-map fleet sprites 32×32 (the first 0x4000 B are the 128 world chips) | 0x833C → `[0x42A]` | 2 |
| `DATA1.LZW` 14 | 16032 | UI sheet → `[0xC0E]:0` (init 0x16E02) | 0x16E02 | 3 |
| `DATA1.LZW` 7 / 6 | 9216 / 3840 | sea ship's-wheel / port compass pieces → `[0xC0E]:0x3EA0` | 0x8427 / 0x8B52 | 3.2 |
| `TRANSIT.DAT` | 19200 | 8 menu tabs 24×80 (0..0x1E00), figureheads 1..10 48×48 (0x1980 + 0x480·k) | 0x91DE, 0x1BB79 | 3.3, 4 |
| `DATA1.LZW` 9 | 5568 | 5 cards 32×48, 6 dice 24×24 → DS buffer `[0xC6F2]` | 0x26E14 | 5 |
| `HDAT.PUT` | 31624 | sea-battle chips, ships, markers, effects → `[0x42A]:0` | 0xBC39 | 6 |
| `GRAPH.DAT` 26, 53..56 | | battle side panel, result pictures | 0xC2B6, 0x10388 | 6 |
| `IAP1..6.LZW`, `IAE1.LZW` | 45–52 KB / 38616 | duellist animations (hero `[0x1241]+1` / every opponent) | 0x1265B / 0x12670 | 7 |
| `DATA1.LZW` 0..3, `GRAPH.DAT` 23, 24 | | duel backdrops, rigging overlays, duel screen | 0x124B1, 0x1230E | 7 |
| `MONSTER.DAT` | 200 | not graphics: 30 sea-event points | 0x3078D | 8 |

Pixel layouts (names used in the index files; one group per 8-px column, MSB = left pixel):

| name | bytes | blitter |
|---|---|---|
| i4 | p0 p1 p2 p3 | screen put 0x2A7 (via 0x3D2 far source, 0x3CA DS source): `[bp+6]` x byte column, `+8` y, `+0xA` width bytes, `+0xC` rows, `+0xE` mode (0 copy, 1 xor, 2 and, 3 or, 4 skip colour 0; bit 15 doubles rows), `+0x10` offset, `+0x12` segment. Work-page copy 0x2431 |
| m3 | p0 p1 p2 mask (1 = keep) | work-page masked put 0x22C9; plane 3 := mask & no colour → colour 8 is the key of the page |
| w3 | per 16 px: mask, p0, p1, p2 as words (left byte first) | 0x248C (world fleet); plane 3 cleared → colours 0..7 |
| mask1 + i4 | 1-bit mask (1 = keep) then i4 | 0x63E mode 0x20F (AND) then 0x3D2 mode 3 (OR) |
| 1-bit | one bit per pixel | 0x63E: mode high byte 4 = stamp the 1 bits in colour = low byte, 2 = AND mask; DATA1[14] 0..0x280 (all 0xFF) is the source of solid fills |

Palettes (B,R,G tables): main 0x40ECE; town/sea daylight DS:0xAD82 and time of day DS:0xAD22 + 0x30·phase
(colours 0..7 identical in all of them); info screens DS:0xAF80; battle and duel DS:0xA584. AF80 and A584 differ
from the main table in colours 3 (`f4c` vs `d6a`) and 6 (`fa0` vs `fa6`) already. **`assets/images/graph_23..56`
were exported with the main table; the game shows 23/24/26/53..56 with DS:0xA584 and 28..52 with DS:0xAF80**
(the sea around the ships is colours 8..15 and comes out wrong in the main table). The sprite groups re-render them
correctly.

---------------------------------------------------------------------------------------------

## 1. Ship class pictures and the info screens ✅ — `ships/`

`0x7EE9(ax = x byte, bx = class, dx = y)` draws **GRAPH.DAT 28 + class** (0x5A51: seek the BE u32 offset table
of GRAPH.DAT, decode 0xFC4 format to the screen; opaque, the picture carries its own sea). 25 classes, 128×96,
palette DS:0xAF80 (`class_00..24.png`).

- 자함대정보 0x1CAB2: 40×20 tiles of the 16×16 sea tile DATA1[14] 0x2BA0 (i4, `fleet_sea_tile.png`) from (0,0),
  then the ship of fleet slot i at DS:0xAFF0 + 2i = (x byte, y/16): (256,160), (384,64), (128,64), (256,16),
  (128,208), (384,208), (0,16), (0,160), (512,16), (512,160) (`index.json` `fleetScreen.shipSlots`).
- 함선정보 0x1BB79(slot, col): window 0x71FA at column col (15 from the info menu), class picture at
  (8·(col+2), 48), figurehead (§4) at (8·(col+19), 48) if cargo `+0x1D` ≠ 0, the four cargo icons DATA1[14]
  `0x20D0 + 0x100·(2i+j)` (16×32 i4: 식수, 식량, 자재, 포탄; `cargo_0..3.png`) at (8·(col+26+7j), 48+40i).
- Other 0x7EE9 callers: 0x1C0DE, 0x250D1, 0x2A9F1 (shipyard) 🔎; the battle 자함대/타함대 info reuses 0x1CAB2 / 0x1BB79
  (0xABA3, 0xAC5D).

## 2. World-map fleet sprites ✅ — `ships/world_*`

DATA1[11] is read to `[0x42A]:0` at sea (0x833C). Its first 0x4000 bytes are the 128 world chips; **0x4000..0x7FFF
are 32 fleet sprites**, 32×32 w3, 0x200 each (RE_NOTES' "256 tiles" counts them as chips; the cell table DATA1[18]
points above 127 only for cells 33–55 (254/255), 99 and 105, apparently unused cells 🔎).

```
offset = 0x4000 + 0x1000·(ship record +0x13 & 0x10 ? 1 : 0)    # sail-only class vs oared
                + 0x2000·(fleet != player)                        # other fleets: second colour set
                + 0x400·DS:0x9526[heading & 7]                    # 0 0 1 1 1 2 3 3 -> N, E, S, W
                + 0x200·((tick [0x571] + k) & 1)                  # two-frame bob, k = fleet's order in the row
```
- Player (0x6D89): the ship captained by the hero (cargo `+0x1B == [0x1241]`) decides oared/sail. Others
  (0x6ECB loop, rows 0..22 of the view): the fleet's flagship (`fleet +0x32` ship record).
- Position (0x248C): `(96 + 16·dx, 8 + 16·dy)`, dx, dy = fleet tile − view origin `[0xF92]/[0xF94]` (0..22); the
  sea view is the 384×384 window at (96,8) of the frame picture.
- During a storm or fog (`[0xC3F] & 0xF` = 1 or 3) only the player is drawn (0x6D89 path).
- Colours 0..7 only (plane 3 cleared), so every time-of-day palette gives the same ship; exported in 0x40ECE.
  Player sails are white/blue, other fleets cream/orange.

## 3. Frame-screen UI ✅ — `ui/`

### 3.1 DATA1[14] sheet (`[0xC0E]:0..0x3EA0`)

| offset | content | format | drawn by |
|---|---|---|---|
| 0x0000 | 0xFF × 0x280: solid source for 0x63E colour fills (menu highlight bars 0x52D0, list boxes 0x12FBE) | 1-bit | — |
| 0x0280 | AA55 dither 8×16 (`stamp_dither`) | 1-bit | 0x6920 |
| 0x0290, 0x0310 | scroll buttons up / down 16×16 (blue) | i4 | 🔎 not traced |
| 0x0390, 0x0410 | gauge buttons − / + 16×16 (red triangles) | i4 | environment screen 0x20BD4, 0x1EB60, 0x200EE |
| 0x0490 + 0x320·k | wind dial 40×40, needle toward k = N, NE, E … NW (k 0..7), k = 8 calm (0x1D90) | i4 | sea panel 0x8DAF at (568, y); battle 0xC2B6 (§6) |
| 0x20B0 | ▼ 16×16 (`stamp_more`), colour 2 | 1-bit | 0x14148 |
| 0x20D0 | cargo icons 16×32 ×4 (§1) | i4 | 0x1BD45 |
| 0x24D0 + 16·d | digit glyphs 8×16 for '0'..'9' (offset `(0x21D + char)·16`) | 1-bit | text renderer 0x4850 |
| 0x2570 + 0x90·k | 11 mouse cursors 24×24: image 0x48 B + mask 0x48 B (0 = cursor) | 1-bit pair | 0x5012 → 0x2EE9 |
| 0x2BA0 | fleet-screen sea tile 16×16 (§1) | i4 | 0x1CAEB |
| 0x2C20 | window corners TL, TR, BL, BR 8×8 | i4 | 0x71FA |
| 0x2CA0 + 0x80·s | window edges, style s = 0..2: top, left, right, bottom 8×8 (tiled by 0x8A6), interior colour 7 | i4 | 0x71FA |
| 0x2E20 | boarding sabres 4 × 32×32 (§6) | i4 + mask1 | 0xCEF6 |
| 0x3820, 0x38A0, 0x3920 | battle cell markers 32×32 (§6); 0x3820 also the map pick marker 0x155AB | 1-bit | 0xBB5D |
| 0x39A0 + 0x20·k | 16 list-window frame pieces 8×8 | i4 | 0x148CE..0x14C95 🔎 |
| 0x3BA0, 0x3C20 | list scroll buttons up / down 16×16 | i4 | 0x14C4D, 0x14C7C |
| 0x3CA0 | 64×64 ship silhouette on a dither (`stamp_ship`) | 1-bit | 0x8C59 (port arrival), 0x1AE79 ❓ |

Cursors (`[0x712]` = current): 0x2570 arrow; then a numeric-keypad set 1..9 = SW, S, SE, W, wheel, E, NW, N, NE
(chosen around the fleet by 0x1B412; the wheel 0x2840 sets `[0x9498]` = 0x10); 0x2B10 outlined arrow (sea view
0x6FF5). Exported with the image bits white and mask-only bits black 🔎 (the software cursor's colours are not
traced).

### 3.2 Ship's wheel and port compass ✅
- Sea: DATA1[7] at `[0xC0E]:0x3EA0`, 18 × 32×32 i4: index h = piece for heading h (0 N … 7 NW), 8 = centre;
  9 + h = the same piece with a lit arrow, 17 = lit centre. 0x938C(base) puts piece `[0x9605] + base` (0 to
  restore, 9 lit) at x 496 (h 5..7) / 536 (0, 4) / 576 (1..3), y 272 (0, 1, 7) / 312 (2, 6) / 352 (3..5) — the
  wheel in the frame picture GRAPH.DAT 2 / 4. Lit only with display effects on (`[0xC30] & 1`, 0x9447).
- Port: DATA1[6], 8 × 40×24 i4: N, E, S, W, then lit N..W (0x92A8, base 4) at (528,304), (552,336), (528,368),
  (504,336) of GRAPH.DAT 3 / 5.

### 3.3 Menu tabs ✅ (TRANSIT.DAT 0..0x1E00)
Eight 24×80 i4 pictures, `0x3C0·k`: k 0..3 INFORMATION, MANAGEMENT, INSTRUCTION, NAVIGATION (layout TYPE 1,
`[0xC30] & 0x80` set), k 4..7 정보, 경영, 명령, 항해 (TYPE 2, offset + 0xF00). 0x91DE(t) saves the screen under tab t
(0x28F9) and puts the highlighted tab at **(616, 72 + 80t)** while its menu is open; 0x91C7(t) restores (0x2967).
Without display effects (`[0xC30] & 1` clear) it draws a plain 0x63E fill (mode 0x107, solid source) instead 🔎.
These are the "TRANSIT.DAT wipes" of newgame.md §7.1.

## 4. Figureheads ✅ — `figureheads/`

TRANSIT.DAT `0x1980 + 0x480·k`, k = cargo `+0x1D` = 1..10 (k = 0: none, never read): 48×48 i4, opaque copy
(0x3D2 mode 0) at (8·(col+19), 48) on the ship screen (0x1BCA2), palette DS:0xAF80. Order = names DS:0x323:
바다표범, 제독, 유니콘, 사자, 독수리, 위인, 포세이돈, 용, 천사, 여신 (golden busts on a dark blue dither).
The shipyard figurehead shop (0x2AAC2) opens the same file 🔎.

## 5. Gambling ✅ — `gambling/`

DATA1[9] is read into the DS buffer `[0xC6F2]` (0x26E14); both puts are 0x3CA (DS source), opaque (mode 0).
- Cards 0x2DB08(x, y, card): picture `suit = card / 13` at `0x300·suit` (32×48): 0 ♠, 1 ♥, 2 ♣, 3 ♦, 4 back
  (`card_*.png`). Unless the back is shown, the rank `DS:0xB90C` (A 2 … 10 J Q K) is printed over the corner with
  `ESC C0 ESC B7` (`%s`, DS:0xB927) at the same text position. Callers 0x2DBFF, 0x2DC0E, 0x2E0F1, 0x2E18D, 0x2E1CB.
- Dice 0x2E5ED(x, y, v): picture `0xF00 + 0x120·v` (24×24), **v = raw value 0..5 shows 1..6 pips** (one red pip for
  0). Five dice at x + 40·i (0x2EE2A), each re-rolled die is redrawn after a 20-tick wait. tavern_more.md §6.2 says
  "0 means six"; the picture for 0 is the ace ❓ (see open questions).
- Palette: the tavern's (taken as 0x40ECE; cards use colours 0, 1, 2, 4, 7, dice 0..7) 🔎.

---------------------------------------------------------------------------------------------

## 6. Sea battle ✅ — `battle/`

Effects save/restore the background with 0x5086 / 0xC474 (stack in `[0xC10]`). Delays `0x5958(n)` = n ticks of
FMDRV timer 1 (60.3 Hz).

### 6.1 HDAT.PUT
Read whole (0x7B88 B) into `[0x42A]:0` by **0xBC39**, before every battle (0x10CB5) and again after a duel
(0x12968), because the duel loads DATA1[0..3] into the same buffer.

| offset | count | size | format | content | drawn by |
|---|---|---|---|---|---|
| 0x0000 | 13 | 32×32 | i4, 0x200 | terrain chips | 0xBF65 |
| 0x1A00 | 24 | 32×32 | mask1 0x80 + i4 0x200 | ships, index `6·set + heading` | 0xBD2F |
| 0x5600 | 6 | 40×40 | i4, 0x320 | heading arrows N..NW | not referenced 🔎 |
| 0x68C0 | 11 | 32×32 | 1-bit, 0x80 | dither, thin square, square frame, crosshair, X (unused 🔎), path arrows 0..5 at 0x6B40 | 0xBB5D |
| 0x6E40 | 4 | 32×32 | mask1 + i4, 0x280 | volley burst (spark → fireball → ring) | 0xCAFB |
| 0x7840 | 4 | 16×20 | mask1 0x28 + i4 0xA0 | water spout | 0xCAFB |
| 0x7B60 | 1 | 8×8 | mask1 8 + i4 0x20 | cannonball | 0xC583 |

Chips (map cell `& 0x1F`): 0, 1 the two sea variants; 2 rocks and 3 white caps are never generated 🔎; 4 land
(0x84); 5..12 coast 0x85..0x8C. **0xE8C2** picks the coast chip from the 8 square neighbours (bit set = not land:
0x80 NW, 0x40 N, 0x20 NE, 0x10 W, 0x08 E, 0x04 SW, 0x02 S, 0x01 SE; clamped at the edge); masks not listed keep
0x84 (`index.json` `coast`):

| cell | chip | sea masks |
|---|---|---|
| 0x85 | 5 | D0 D4 F0 F4 (sea NW) |
| 0x86 | 6 | 40 60 C0 E0 (N) |
| 0x87 | 7 | 68 69 E8 E9 (NE) |
| 0x88 | 8 | 10 14 80 90 94 (W) |
| 0x89 | 9 | 08 09 20 28 29 (E) |
| 0x8A | 10 | 16 17 96 97 (SW) |
| 0x8B | 11 | 01 02 03 04 06 07 (S) |
| 0x8C | 12 | 0B 0F 2B 2F (SE) |

Ship sets (0xBD2F): `set = (unit +0xD & 0x80 ? 0 : 1) + (ship record +0x13 & 0x10 ? 0 : 2)`: 0 player side (own
and ally, white sails), 1 enemy (beige sails), 2 / 3 the same for oared ships. Heading 0..5 = N, NE, SE, S, SW, NW
(unit +0xA). A derelict is drawn normally; hull 0 or flag 0x40 is not drawn.

### 6.2 Palette
**DS:0xA584**, faded in by **0xBB18** (0x9825). If `[0x426]` and `[0xC6DC]` are 0 it also starts a **water cycle**:
`0x16BE(DS:0xA57C, 4, 0x10)` hooks INT 1Ch; every 17 ticks (18.2 Hz, ≈ 0.93 s) ISR 0x3F34 loads colours 8..15 from
the next of the four 16-byte entries DS:0xA53C + 16k (word = `G<<8 | R<<4 | B`). Only colours 9, 11, 14, 15
change. 0xBB44 unhooks and fades to black at the end (0x10679). Chips with those colours are exported with
`_p1.._p3` copies.

### 6.3 Screen layout
- Map view 13×12 cells at (0,0), origin `[0xA4FD]/[0xA4FE]`. **Terrain is a square 32-px grid** (chip of cell
  (x, y) at (32·vx, 32·vy) for both column parities, plus a half row at y = 384). **Ships and markers of odd
  columns sit 16 px lower** — the hex stagger exists only for them. Redrawing an odd-column cell (0xBF65) draws the
  lower half of its chip at 32·vy + 16 and the upper half of chip (x, y+1) below it.
- Ship number (0xBD2F, unless crew = 0): `+0xD & 0xF` printed `%1d` on the sprite, colour 7 for a side's flagship,
  1 for the others (DS:0xA5B4 / 0xA5BB); sides 2/3 print it 24 px to the right.
- Side panel 0xC2B6: GRAPH.DAT **26** (224×400) at (416,0) (`panel.png`, labels Wind/Time/Hull/Crew/Rudder/Sails/
  Cannon Ball in the picture), then
  - minimap: fill (424,8) 208×192 colour 5 (0x906); land (0xBEFD) and ships (0xBCD0 → 0xBC62) as 4×4 dots
    (DS:0xA50C `.XX. XXXX XXXX .XX.`) at (424 + 4x, 8 + 4y): own 7, ally 6, enemy 2, enemy reinforcement 3, land 0;
  - wind dial at (440,230): DATA1[14] `0x490 + 0x320·k`, `k = (15·dir − dir/3)/10` → dial frames 0, 1, 3, 4, 5, 7.
    **The needle points toward `[0xA506]`** (answers battle.md open question 2: "blowing toward");
  - texts 0xC13B for the player's flagship: `%s호` (496,216), hour `%2d` = tick/3 (448,296), `%02d` = 20·(tick%3)
    (472,296), hull, crew/max crew, rudder/class, sails/class `%3d/%3d` at x 560, y 232/248/264/280, shot `%3d`
    (600,296);
  - message box 0xC102: fill (424,328) 192×56 colour 0, text from (432,336).
- Result 0x10388: GRAPH.DAT picture at (120,32) (0x10319), window below (0x10366): **53** codes 4/6/8,
  **54** codes 2, 3, 9, **55** code 1 (sunset), **56** codes 5/7.

### 6.4 Animations 🔎
| routine | what |
|---|---|
| 0xC341 | one move step: redraw old cell, erase dot, move, ship + dot, wait 8 |
| 0xC42A | sink / remove: redraws the cell and erases the dot — **no sinking animation** |
| 0xC583 | cannonball: sound 0x24, 8×8 ball along a parabola from attacker to target cell centre (+8,+8), 1 tick per step, only inside the view |
| 0xCAFB(target) | ball, then at the target cell frames of burst k (32×32) and/or spout k (16×20 at x + 0 or 16 (rand 2), y + 12), wait 8: burst+spout ×4; spout only ×4 if attacker range ≥ 4 and distance = range, else burst only ×4; burst+spout ×4 |
| 0xCEF6(target) | boarding: sound 0x30; 3 passes (target, attacker, target) of 8 frames `0,1,2,3,1,3,0,2` of DATA1[14] `0x2E20 + 0x280·f` (32×32, **i4 first, mask after**), 2 ticks each |

### 6.5 Cell markers 0xBB5D(x, y, bl) 🔎
| bl | stamp | colour | use |
|---|---|---|---|
| 1, 2 | DATA1[14] 0x3820 brackets | caller's (4) | own ships to pick (0xA385), reachable cells (0xA5A0) |
| 3 | DATA1[14] 0x38A0 sight ring | 6 | enemy within gun range |
| 4 | DATA1[14] 0x3920 sword | 3 | enemy adjacent (boarding) |
| 0x80 + d | HDAT 0x6B40 + 0x80·d arrow | 4 | path steps (DS:0xA4F2) |
| 0 | HDAT 0x68C0 dither | 4 | default, never passed |

---------------------------------------------------------------------------------------------

## 7. Duel (일기토) ✅ — `duel/`

Rules: battle.md §12. Entry 0x12846(A, B, playerChallenged) (battle 0x128B7, script 0x31AA4): fade to black,
meter 100, 0x12694, fade, reload the world chips (0x833C) or the port (0x8747). Palette **DS:0xA584**: 0x119CB →
0xBB18 fades to it and starts the water cycle, which 0x119CB stops at once (0x1713); every duel graphic uses
colours 0..7, so the duel is static.

### 7.1 Files
| file | content | format |
|---|---|---|
| GRAPH.DAT 23 | 640×400 duel screen at (0,0) (0x1230E) | rle4 |
| GRAPH.DAT 24 | 480×176 port scenery at (80,168) when `[0xC3A] ≠ 0xFF` | rle4 |
| DATA1 0 / 1 | 384×120 backdrop of the fighting box, sea / port | i4 |
| DATA1 2 / 3 | 72×120 foreground rigging (sailors on the shrouds), sea only | m3 |
| IAP{hero+1}.LZW | the hero's duellist (`[0x1241]` 0..5) | below |
| IAE1.LZW | one opponent figure for every NPC | below |

**IA\*.LZW**: 35 LS11 entries = 7 groups g × 5: entry `5g` = body, `5g+1+t` = weapon overlay for weapon type t
(duel struct +2: 0 검, 1 스트레이트, 2 커브, 3 헤비; no weapon = type 0; the overlay includes the sword arm). An
entry starts with a frame table, 8 B per frame: x (byte column), y, w (bytes), h, BE u32 offset of the m3 pixels;
the table ends where the first offset points. x, y place the frame in the 192×120 fighting box (hero at x ≈
104–168 facing left, opponent at x ≈ 16–80 facing right).

| g | action | frames |
|---|---|---|
| 0 | stance: 0, 1 ready (alternate), 2 hit, 3 down, 4, 5 victory (alternate) | 6 |
| 1 / 2 / 3 | attack 찌른다 / 벤다 / 친다 | 3 / 4 / 3 |
| 4 / 5 / 6 | defence 걷어낸다 / 맞받는다 / 비킨다 | 3 each |

Loader 0x114C9(side, g) → `[0x42A]`: hero body 0, weapon 0x2C90, opponent body 0x4780, weapon 0x70B0 (LS11
directories at DS:0xA63A / 0xA73A, reader 0x34D3B). Group 0 is pre-rendered by 0x11305 into 72×88 slots of the work
pages `[0xA90A..0xA90E]` (rects DS:0xA83A + 8·slot) and drawn by 0x11671; other groups by 0x11387 / 0x11425.

### 7.2 Composition and positions
- Work page 0 `[0xA908]` (720×120): colour 8, backdrop at x 0..383 (0x2431), overlays at x 576..719 (0x22C9).
  0x234C copies to `[0xC12]` keeping the destination where plane 3 is set: **colour 8 is the key colour**.
- Frame 0x1175A(heroFrame, oppFrame): `[0xC12]` (192×120) := backdrop x `8·(7+k)` … +191; bodies + weapons at box
  `(8·(x + [0xA62C]), y + [0xA62E])` (opponent `[0xA630]/[0xA632]`); overlays at sea (0x11559) at backdrop x 0 and
  312, over the fighters; then the box is put at **screen (8·(23+k), 176)** — screen x = backdrop x + 128.
- Camera `k = [0xA628]` (0x11208): `(200 − meter)/20` if the hero challenged, else `meter/20` (5 at the start);
  the finishing knock-back runs it to −7 / 17. Rest offsets: hero −8 px, opponent +8 px.
- Intro 0x119CB / 0x1185B: two 96-px half boxes slide together one byte per 4 ticks, feet alternating frames 0/1.

### 7.3 Animation (ticks of 60.3 Hz)
- Exchange 0x11E80: six steps (four on a hit), 2 ticks each (`f ≥ 6` = frame f−6 of the move group, else stance
  frame; back = 8-px steps away from the opponent). On a hit the defender shows stance frame 2 raised 8 px from
  step 3. Sound DS:0xB5E (hit) / DS:0xB48 (miss) at step 3.

  | move | steps (f / back) |
  |---|---|
  | 찌른다 | 6/0, 1/0, 7/0, 8/0, 0/0, 1/0 |
  | 벤다 | 6/0, 7/0, 8/0, 9/0, 0/0, 1/0 |
  | 친다 | 6/0, 7/0, 8/0, 8/0, 0/0, 1/0 |
  | 걷어낸다, 맞받는다 | 1/0, 6/1, 7/1, 7/1, 8/1, 1/1 |
  | 비킨다 | 6/0, 7/1, 7/2, 8/2, 8/2, 1/2 |
- Damage 0x11CB9: camera moves a byte per 4 ticks to the new k; damaged side frame 2 bobbing y 0/−8, then frame 3;
  "-%d" blinks 4 × 4 ticks in colour 2 at (208,360) (opponent) / (432,360) (hero).
- Decision 0x11B79: 7 steps of 4 ticks, loser frame 2 hopping 0, −8, −16, −24, −16, −8, 0; then 16 steps of
  victory frames 4/5 against frame 3.
- Text on GRAPH 23: names (96,24) / (336,24); portraits (96,56) / (480,56); weapon and armour names (200,56),
  (200,80) / (328,56), (328,80); message box (208,112) 224×48; points `%3d` (184,360) / (408,360) — **there is no
  meter bar**, the meter is these two numbers (sum 200) and the box position. Move menu 0x13D50 at column 0x44,
  y 240 🔎.

---------------------------------------------------------------------------------------------

## 8. MONSTER.DAT 🔎 (not graphics)

30 records of 5 bytes (x u16, y u16, type 0..9; the rest of the 200 bytes is 0), world tile coordinates. 0x30731
keeps 10 active points at DS:0xF9E + 4i (x, y) / DS:0xFC6 + i (type); when the player fleet stands on one, the
slot is cleared, the event runs via the far table DS:0xBB58[type] (0x30343..0x305C2; 0x305DE plays effects and
prints msg 1176 "[원작 문장 생략]."), and the next record (`[0xFD0]` · 5) is read into the slot.
The events themselves (sea monsters?) are not decoded ❓; no picture file is involved.

---------------------------------------------------------------------------------------------

## For the remaster

- Info screens: `ships/class_NN.png` (128×96, opaque) at `fleetScreen.shipSlots` over `fleet_sea_tile.png` tiled
  40×20; ship screen: class picture, `figureheads/figurehead_NN.png`, `ships/cargo_0..3.png` at the §1 positions.
- World map: `ships/world_<row>_<dir>_<frame>.png` (row 0/1 player oared/sail, 2/3 other fleets; dir N/E/S/W from
  the 8-way heading by DS:0x9526; frame alternates each tick, offset by the fleet's order).
- Frame UI: `ui/helm_*` / `ui/compass_*` lit pieces while steering, `ui/tab_type1|2_N` for the open menu tab,
  `ui/wind_dial_*` in the sea panel, `ui/frame_*` 8×8 window pieces (interior colour 7), list pieces and buttons,
  `ui/cursor_*` (direction cursors around the fleet), `ui/digit_*`.
- Gambling: `gambling/card_<suit>.png` + rank text in the corner, `card_back.png` for the hole card;
  `gambling/die_<v>.png` with v = raw die value (0 = one pip).
- Battle: `battle/chip_NN` on a square grid (two sea variants, coast table), `ship_<set>_<heading>` with odd columns
  16 px lower and the number label; burst/spout/ball/sabre sequences of §6.4; markers of §6.5; `panel.png`,
  `wind_<dir>.png`, minimap dots, `result_53..56.png`; animate colours 9/11/14/15 with the 4-phase cycle (or swap the
  `_pN` files). There is no sinking animation in the original.
- Duel: `duel/screen.png`, the 192×120 box at (184 + 8k, 176) clipped from `backdrop_sea|port.png` at x = 56 + 8k,
  `heroN_gG_body.png` + `…_weaponT.png` / `enemy_…` strips (frame n at x = 192·n, already at its box position),
  `overlay_left/right.png` on top, exchange table in `index.json`.
- Re-export or stop using `assets/images/graph_23..56` for these screens: they are in the wrong palette.

## Open questions ❓

1. Dice: the picture for raw value 0 is the red ace, but tavern_more.md §6.2 reads raw 0 as "six" (sorted first,
   higher in ties). One of the two readings is wrong; check 0x2E70A / 0x2E745 / 0x2E8DD before using the art.
2. Palette of the tavern and gambling screens (cards and dice exported with 0x40ECE); the time-of-day palettes only
   change colours 8..15, which these pictures do not use, so this matters only if the tavern sets its own table.
3. DATA1[14] 0x290 / 0x310 scroll buttons and 0x3CA0 ship silhouette (0x8C59, 0x1AE79): callers' purpose not traced.
4. Software cursor colours (image bits white?) and hotspots (`[0x9498]` = 0x10 for the wheel cursor).
5. Weather at sea: no extra graphics found; storm / fog only hide other fleets (0x6D89) and play the storm sound
   (0x95BE(0xBE2)); flashes or palette effects during a storm were not looked for.
6. Battle: exact cannonball parabola (0xC583 constants 0xE100, 0x7080, 0x258; branch 0xC89C); colour of bl = 1
   markers from 0xA5A0; whether `[0xC6DC]` (disables the water cycle) is a user option; users of HDAT 0x5600 arrows
   and the four spare stamps (none found).
7. Duel: placement arguments of the move menu 0x13D50; sound records DS:0xB48 / 0xB5E.
8. MONSTER.DAT events (§8) and the cells 33–55, 99, 105 of DATA1[18] that point at chips above 127.
9. GRAPH.DAT pictures not covered here (0, 1, 6..22, 27, 57..59, 63, 64): already exported by tools/extract.py in
   the main palette; their screens and palettes were not checked.
