# Sea view: world chips, coast autotile, palettes (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n. Code segment
0x1F74 starts at 0x1F740 (near calls wrap at 64 KB). Status: ✅ read in full and reproduced by `tools/seamap.py` ·
🔎 read, details skipped · ❓ not decoded.

```
build/venv/bin/python -I tools/seamap.py [OUT] [--check-all]          # default OUT = assets/seamap
  atlas_p0..4.png, p0..4/chip_XX.png   128 chips 16×16 in palette phases 0..4 (night, dawn, day, dusk, fog)
  chips_indexed.bin                    128 × 256 colour indices (palette-free atlas)
  chips.bin                            2160×1080 chip index per tile (y·2160 + x), ports/villages hidden
  index.json                           palettes, phase table, chip classes, markers, windowOverrides, histogram
  view_lisbon.png, view_lisbon_phases.png, world.png   check renders
```

---------------------------------------------------------------------------------------------

## 1. Pipeline ✅

```
fleet enters another 24-tile block  ([0x704] changes, 0x69DA / 0x6BA2)
  └─ 0x22734(block = 30·wr + wc)                          build the 72×72 local map [0x430] (row stride 96)
       ├─ 0x224E1  decode the 3×3 WORLDMAP blocks → 36×36 cells (stack), then pre-chips into [0x430] (§3)
       ├─ 0x219F8(wr)  coast autotile, in place (§4)
       └─ overlay of cells ≥ 0x10 (§5)
every redraw (0x6D03, also 0x6B59, 0x199AB, 0x3028C …)
  └─ 0x1F7C(seg [0x432], off [0xC166], chips [0x42A])     24×24 chips at (96, 8), only cells that changed (§7)
```
The same [0x430] buffer is the collision map (`blocked` 0x30AA0: any of the fleet's 2×2 tiles ≥ 0x34) and is
read by 기항 / 상륙 (port chips 0x74 / 0x78, land chips, commands.md §3.3–3.4).

## 2. Data ✅

| what | where | loaded by |
|---|---|---|
| WORLDMAP.LZW entry `[0x706]` (third of the world, 720×1080 tiles) | `[0x70A]:[0x708]` | 0x82F8 (`[0x706]` = fleet x / 720, 0x3122E) |
| DATA1[11] 0..0x3FFF: 128 chips 16×16, 4 sequential 32-byte planes, rows BE u16, MSB left | `[0x42A]:0` | 0x833C at sea |
| DATA1[10] (512 B): autotile table, index `mask8 + 0x100·(centre is sea)` | `[0x434]` (seg `[0x436]`) | 0x15F79 (static) |
| DATA1[12] (512 B): coordinate hash, 0..0xFF ports, 0x100..0x1FF sites | `[0x70C]` (seg `[0x70E]`) | 0x15F79 |
| DATA1[18] (1024 B): cell → 4 chips NW, NE, SW, SE | `[0x438]` (seg `[0x43A]`) | 0x15F79 |
| port records DS:0x5F54 × 20 (`+0/+2` x,y of the 2×2, `+0x13 & 0x10` known) | data segment (DATA1[15]) | new game / save |
| site records DS:0x7E88 × 7 (`+0/+2` x,y, `+6 & 0x40` village sighted, `0x80` inactive) | data segment | new game / save |

Cells (tools/worldmap.py): one cell = 2×2 tiles, block = 12×12 cells = 24×24 tiles. Values on the map:
`0x00..0x0F` quadrant land bits (8 NW, 4 NE, 2 SW, 1 SE; 578 795 cells), `0x10` market port (100), `0x11` site
(98), `0x12` supply port (30), `0x13..0xB7` hand-drawn 2×2 pieces from DATA1[18] (mountains 0x20 ×1264, hills 0xAF
×1056, desert frames 0x65..0x76, river/shore pieces 0x80..0xAB …). DATA1[18] entries pointing at chips ≥ 0x80
(0x21, 0x22, 0x25 …, 0x63, 0x69) and cells 0x16, 0x1F, 0x50..0x53, 0x58..0x5B, 0x7D..0x7F, 0xE5, 0xE6 never occur.

**Bands.** `block row = y // 24`; offset `0x10` for rows 0 and 44, `0` for rows 14..30 (y 336..743), `8` otherwise.
Land chip = `0x41 + offset` → 0x41 / 0x49 / 0x51 (snow); 0x59 is desert. 리스본 (y 358) is in the 0x41 band.

## 3. Pre-chips (0x224E1, tail 0x22628) ✅

0x224E1(ax = first block) decodes blocks `b, b+1, b+2` of three rows (`b += 30`), 3×3 = 36×36 cells, then fills
[0x430] (72×72, stride 96; columns 72..95 and rows ≥ 72 untouched):
- cell < 0x10 → each quadrant `0x41` if its bit is set, else `0`
- cell ≥ 0x10 → DATA1[18][4·cell + q], stored as `0` when `< 0x34`

The pre-chips are only the input of §4; cells ≥ 0x10 are overwritten again in §5.

## 4. Coast autotile 0x219F8(ax = window block row) ✅

In place over the 72×72 tiles, raster order. Exact rule (`tools/seamap.py World.autotile`):
```
land(x,y) = prechip(x,y) >= 0x29                     # flags taken from the pre-chips (3 rolling rows of 72)
for y in 0..71: off = band offset of block row (ax + y/24)      # recomputed every 24 rows
  for x in 0..71:
    c = buf[x,y]; if c >= 0x59: continue             # ports, villages, desert, chips >= 0x59 stay
    m = N·1 | NE·2 | E·4 | SE·8 | S·0x10 | SW·0x20 | W·0x40 | NW·0x80     # land flags of the 8 neighbours,
                                                      # coordinates clamped to the window (0..71)
    t = DATA1[10][m + (land(x,y) ? 0 : 0x100)]
    if t == 0: buf = 0
    elif buf[x,y-1] == 0x59 or buf[x-1,y] == 0x59 or buf[x+1,y] == 0x59 or buf[x,y+1] == 0x59:
         buf = t + 0x18                               # neighbours outside the window are skipped;
    else: buf = t + off                               # up/left are already rewritten, right/down are not
```
DATA1[10] for a land centre is always 0x41 (→ land chip of the band, or 0x59 next to desert). For a sea centre
only N, E, S, W matter (diagonals ignored):

| land at | none | N | E | N E | S | N S | E S | N E S | W | N W | E W | N E W | S W | N S W | E S W | all |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| table | 0 | 2 | 5 | 3 | 7 | 0x42 | 8 | 0x45 | 4 | 1 | 0x43 | 0x46 | 6 | 0x44 | 0x47 | 0 |

So shore chips 1..8 (+band, +0x18 desert) and one-tile channels / dead ends 0x42..0x47 (+band). A sea tile
enclosed on four sides and a sea tile touching land only diagonally both draw as open sea (chip 0).

**Desert fill.** Because the 0x59 test reads up/left from the rewritten buffer, 0x59 floods right and down through
land: the map draws a desert as a frame of DATA1[18] cells holding 0x59 and edge chips 0x69..0x72 around plain
quadrant land (cells 0x0F), and the autotile fills the inside. Shores touching 0x59 become 0x19..0x20 (+0x18).
This answers commands.md §7 Q2: chip 0x59 (no water ashore) is that desert.

## 5. Overlay of cells ≥ 0x10 (0x22734 tail, 0x227CF..0x228DA) ✅

Raster order over the 36×36 cells; the land chip uses the cell's block row (`row % 12 == 0` steps it):

| cell | drawn |
|---|---|
| < 0x10 | the autotile result |
| 0x10 market port, 0x12 supply port | port = hash lookup of the cell's top-left tile (0x2242D); `+0x13 & 0x10` (known) → keep the pre-chips 0x74..0x77 / 0x78..0x7B, else all four = band land chip (never 0x59) |
| 0x11 site | site = lookup 0x22486; `+6 & 0x40` (village sighted) → keep 0x7C..0x7F, else all four = 0x59 if the tile left of the cell (final buffer, `[si-1]`) is 0x59, else band land chip |
| other | DATA1[18] chips verbatim (also chips < 0x34 such as hand-drawn rivers 0x09..0x10) |

Lookup (0x22417): `h = (x + y) % 255`; probe `DATA1[12][h]` (ports) or `[0x100 + h]` (sites), 0xFF = none, else
compare the record's x,y, next `h = (h + 19) % 255`. All 228 marker cells resolve. Sighting a port or village
(0x3070D → `+0x13 |= 0x10` / `+6 |= 0x40`) calls 0x30260, which rebuilds the current window and redraws, so the
chips appear at once. An unknown port is plain land with no 0x74/0x78 for 기항 to find, but sighting at ≤ 2 tiles
always marks it known first.
Quirk: 메카 (port 77, 416,488) sits in the Arabian desert and shows as a 0x41 green square until known.

## 6. Window dependence ✅

[0x430] only ever holds one window: block col `wc = clamp((x/24) % 30 − 1, 0, 27)`, row `wr = clamp(y/24 − 1,
0, 42)` of the fleet, inside its 720-tile third (`[0xC156] = 24·wc`, `[0xC15A] = 24·wr`, 0x69DA / 0x6BA2).
The view origin `[0xF92]/[0xF94]` starts at fleet − 11 (0x1620D), clamped to `[720·third, 720·third + 696]` ×
`[0, 1056]`, and scrolls one tile when the fleet leaves the dead zone `11 ± [C35]` (0x312AD, C35 ≤ 10), so it
shows window columns/rows 3..69 only (0..69 / 3..71 when the window is clamped at an edge). Consequences:
- The clamped neighbours of §4 are visible only at the map's top/bottom rows and the third borders x % 720 ∈ {0,
  719}; chips.bin computes each third as one 720×1080 image with the same clamping, so it matches there. The
  land/sea class agrees across all three borders, so no seam shows.
- The desert fill restarts at each window's top/left edge: a desert cut by a window edge keeps green interior
  tiles. `seamap.py` re-runs the game's window build for all 3612 windows (`--check-all`): 14 windows, 462 visible
  tiles differ from chips.bin, all inside deserts (tiles 179..182,531..533 · 272,819 · 339..350,435..436 ·
  483..490,448..472 · 795..799,359..364). They are listed in `index.json` → `windowOverrides`
  (`third, blockCol, blockRow, tiles [x, y, chip]`).

## 7. Drawing 0x1F7C ✅

- Destination VGA offset 0xF0C = (96, 48) in the 480-line mode = (96, 8) in the game area; 24 rows × 24 chips,
  row stride in [0x430] 96 (`bx += 0x48` after 24 chips); offset `[0xC166] = (vy − wy)·96 + (vx % 720 − wx)`.
- Each chip is copied plane by plane (0x81E selects the plane; write mode set by 0x118), 16 words, no mask.
  Chips ≥ 0x80 would read the fleet sprites; none occur.
- A 576-byte cache in the code segment (cs:0x1AFC) holds the chip last drawn per cell; equal chips are skipped.
  0x20D3 clears it (and a second one at cs:0x1D3C; full redraw); 0x20E9(24·dy + dx) invalidates the 2×2 cells
  under a 32×32 fleet sprite (0x6E2E, 0x6FDA), so the next frame repaints the water there. No animation: the
  chips never change between window builds.
- Frame (0x6D03): `[0x9524] ^= 1`; wait `[C32]` timer units (key skips); hide mouse; 0x1F7C; fleets (sprites.md
  §2: all fleets unless weather is storm or fog, then only the player); panel updates outside the view (0x7053,
  0x706C, 0x7096, 0x8E07 🔎); mouse cursor (below); show mouse.

## 8. Palettes, time of day, weather ✅ (weather end 🔎)

- Five tables DS:0xAD22 + 0x30·k, B,R,G 0..15 (`×17` in index.json): 0 night, 1 dawn, 2 day (= DS:0xAD82), 3 dusk,
  4 fog. Colours 0..7 are identical in all five; 8..15 differ:

| k | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 (RGB 0..f) |
|---|---|---|---|---|---|---|---|---|
| 0 night | 444 | 047 | 640 | 553 | 056 | 034 | 044 | 667 |
| 1 dawn | 89a | 04a | a70 | 982 | 06a | 034 | 098 | def |
| 2 day | 779 | 04c | a60 | eb5 | 08f | 076 | 0b6 | fed |
| 3 dusk | 863 | 459 | 930 | c97 | 679 | 044 | 986 | fda |
| 4 fog | 666 | 467 | 764 | 665 | 467 | 456 | 466 | 777 |

- Terrain chips use colours 0 and 8..15 (open sea = 0, 9, 12), so the whole map shades; port chips 0x74..0x7B use
  mostly 0..7 and stay bright at night; fleet sprites use 0..7 only.
- `phase(tick)` = DS:0xAD1A[tick / 12] = `0 1 2 2 3 0` (72 ticks a day). Per tick (0x1ABA7, state `[0xAD20]`):
  state 0 and no weather → 0x19196 sets a new target only at ticks 12 / 24 / 48 / 60 (AD52 / AD82 / ADB2 / AD22);
  state 1 → 0x981C moves the DAC copy one step (1/15 per channel) toward the target, back to state 0 when equal.
  So each change fades over up to 15 ticks.
- Weather (`[0xC3F] & 0xF`, sea_events / RE_NOTES): while active 0x19A7B sets the target with 0x19150 — storm (1)
  → DS:0xAD22 (night), fog (3) → DS:0xADE2, calm (2) → time of day — and `[0xAD20] = 1` (fades per tick). When the
  weather ends 0x199E4 sets the time-of-day target without restarting the fade; it is reached at the next full fade
  0x983F (menus, port) 🔎. `[0xC6DC]` (force day palette) is never set.
- No colour cycling at sea: the INT 1Ch cycler 0x16BE is started only by the title (0x15E95) and the sea battle.

## 9. Other things drawn over the view ✅

- Fleets: sprites.md §2 (DATA1[11] 0x4000.., `(96 + 16·dx, 8 + 16·dy)`, two-frame bob).
- Mouse cursor (0x6E64..0x700E): inside the view, cell `(mx − 96) >> 7`, `(my − 8) >> 7` of a 3×3 grid of 128 px
  picks cursor DATA1[14] `0x2960 + 0x90·(col − 3·row)` = NW N NE / W wheel E / SW S SE; outside → 0x2B10.
- Storm start (0x19942): cache cleared, GRAPH.DAT picture 58 (240×160, sailors in a storm) at (160, 16) over the
  view while the officer speaks, then the view is redrawn (0x199AB). Calm and fog have no picture. Sea-event
  pictures: sea_events.md.
- No port names, flags or markers besides the 2×2 port / village chips; no fog of war in the view (the explored
  bitmap DS:0xD74 is only for the 항해도, info.md §1.8).

## 10. Variant 0x228E1 🔎

Used by the chart cell renderer 0x1D0B5 when its mode ≠ 0 (callers 0x1D86x, 0x1D9xx; mode 0 at 0x1D5xx = 항해도
zoom uses 0x22734). Differences: cells 0x10 and 0x12 are always land (0x59 if the left tile is 0x59, else band
land), cell 0x11 always keeps its village chips, and the band steps every 24 cell rows instead of 12 (bug: the
third block row of the window gets the second row's band). The chart halves the chips to 8×8 (0x1D251).

## For the remaster

1. Replace the mask shader by chips: draw `chips.bin` tiles with `atlas_p{phase}.png`, or `chips_indexed.bin` plus
   the five palettes in the shader so the 15-tick fades (§8) are a palette lerp per channel step.
2. Overlay `index.json` `markers` (`chips` NW, NE, SW, SE at `x..x+1, y..y+1`) when the port record is known
   (`+0x13 & 0x10`) or the village sighted (`+6 & 0x40`); otherwise the `hidden` chip (already in chips.bin).
3. For exact original glitches apply `windowOverrides` while the fleet's window (§6) is the listed one.
4. Passability of the original = chip ≥ 0x34 on the fleet's 2×2 footprint (narrow waters 0x42..0x53 count as
   blocked but can never fit a 2×2 fleet anyway). This is exact, unlike `world_mask.bin`'s colour heuristic,
   which differs on 3573 tiles (all one-tile channels or hand-drawn shore pieces such as 0x1B).
5. Keep fleets in colours 0..7, ports bright at night, no water animation, storm picture 58 at (160,16).

## Open questions ❓

1. Weather end: confirm in a running game that the palette stays storm/fog until the next full fade (§8).
2. Exact screens of 0x1D0B5 modes 1 and 2 (treasure-map views) using 0x228E1.
3. Chips 0x21..0x32 (forest/cliff shores, rocks, iceberg, whirlpool) and 0x61..0x63 are drawn but placed by no
   map cell; DATA1[18] cells referring to them (and to chips ≥ 0x80) are unused — leftovers of another version?
4. A hidden site at window column 0 reads `[si-1]` before the row (garbage); no site lies on x % 720 = 0, so unseen.
5. Nothing here was compared with a capture of the original running; the renders only look right
   (리스본 harbour, Tagus, coasts, deserts, snow rows).
