# Walking town (항구 시가지): walker, townsfolk, doors (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N. Near calls in segments 0xFB8 / 0x1F74 were re-resolved inside their
64 KB segment. Status: ✅ read in full from code · 🔎 read, some details skipped · ❓ not decoded.
Already documented elsewhere and only referenced here: town data loader 0x8747, walkability rule
and 항구지도 (info.md §1.10), building list / hours / arrests (town.md §1), blockade guards
(war.md §4.1), building scripts (scenario.md §3.2), harbour office / 출항 (commands.md §4).

Assets: `tools/portmaps.py` → `assets/portmaps/` (maps, doors, thresholds);
`tools/townchars.py` → `assets/townchars/` (sprites, compass arrows, `townchars.json`).

---------------------------------------------------------------------------------------------

## 0. State ✅

| what | where | notes |
|---|---|---|
| camera (window origin, tiles) | `[0xC40]` x, `[0xC42]` y (u16) | 0..72; window = 24×24 tiles of the 96×96 map |
| walker in the window | `[0xC44]` x, `[0xC46]` y (u16) | absolute tile = `C40+C44`, `C42+C46` = **top-left tile of the 2×2 sprite** |
| previous camera | `[0xC170]`, `[0xC174]` | saved at each step; only read by dead code in 0x6147 |
| map offset of camera | `[0xC166]` = `C42·96 + C40` | argument of the window painter 0x1F7C |
| townsfolk | DS:0xC48 + 3i, i = 0..7: `x, y, k` (bytes) | i 0..3 walkers (k = facing), i 4..7 standing (k = kind), x = 0xFF unused |
| doors of this port | DS:0x88C, 12 × `(x, y)` | ZA_DAT record `min(port, 100)`, loaded by 0x8705 |
| walk thresholds | DS:0xC129..0xC12B = `a, b, c` | PORTCHIP entry 2s+1 bytes 1..3 (0x8747) |
| last loaded port | `[0xC3B]` | 0xFF after 출항 (0x273C3); 0x82 when saved in port (0x170C7, 0x21002) |
| talk cooldown | `[0x950E]` (byte) | set 10 on arrival from sea (0x8B4D); not saved |
| hero step toggle | `[0x9510]` | 0 / 0x280, xor'ed on every hero draw (0x5FBE) |
| sprite buffer | `[0x70A]`:0 | CHAR.LZW entry hero → +0, entry 6 → +0x1400 (0x8747) |
| tile map / chips | `[0x430]:[0x432]` / `[0x42A]`:0 | PORTMAP 96×96 bytes / 240 PORTCHIP tiles × 128 B |

DS:0xC40..0xC5F lies inside the saved block (DS:0xC30..), so camera, walker and townsfolk positions
are saved; `[0x950E]` and `[0x9510]` are not.

---------------------------------------------------------------------------------------------

## 1. CHAR.LZW sprites ✅ (`tools/townchars.py`)

7 LS11 entries: 0..5 = the six heroes (5120 B = 8 frames), 6 = townsfolk (15360 B = 24 frames).
Entry `[0x1241]` (hero index) → `[0x70A]`:0, entry 6 → `[0x70A]`:0x1400; game frame n is at
`[0x70A]`:`n·0x280`.

**Frame** = 640 B = 32×32 px = four 16×16 quarters TL, TR, BL, BR at +0, +0xA0, +0x140, +0x1E0
(0x5E5E). **Quarter** = 160 B: four planes of 16 big-endian u16 rows (32 B each, bit 15 = leftmost
pixel, plane p = colour bit p — the PORTCHIP tile layout), then a 32 B **mask** in the same layout.
0x1795 composes each quarter onto a copy of the map tile under it (0x173C): per plane word
`tile = (tile AND mask) OR plane`. Mask bit 1 = transparent (plane bits are always 0 there — checked
over all 72 frames); mask 0 = opaque, including the black (colour 0) drop shadow. The composed tile
is blitted by 0x2111 and marked dirty (0x20E9) so the next window paint restores it.

**Order**: 8 frames per character = `dir·2 + step`, dir 0 up (back view), 1 right, 2 down (front),
3 left.

| game frames | entry | who |
|---|---|---|
| 0..7 | hero h | 조안 페레로, 카탈리나 에란초, 옷토 스피노라, 에르네스트 로페스, 피에트로 콘티, 알 베자스 (h = 0..5) |
| 8..15 | 6, frames 0..7 | walker A: woman in a white headscarf (slots 0, 2) |
| 16..23 | 6, frames 8..15 | walker B: bearded man (slots 1, 3) |
| 24, 25 | 6, frames 16, 17 | standing kind 0: man with a hat (slot 4, by the 교역소) |
| 26, 27 | 6, frames 18, 19 | standing kind 1: dog (slot 5, by the 주점) |
| 28, 29 | 6, frames 20, 21 | standing kind 2: guard with a halberd (blockade) |
| 30, 31 | 6, frames 22, 23 | standing kind 3: old merchant in a blue robe (slot 7, by the 여관) |

**Palette**: sprites use colours 0..7 only; those are identical in the main table 0x40ECE and in all
five time-of-day palettes DS:0xAD22 + 0x30·phase (only colours 8..15 differ). So sprites never tint
with the time of day; only the map tiles do.

**Export**: `build/venv/bin/python -I tools/townchars.py [--out DIR]` writes 72 RGBA 32×32 PNGs
(`hero{h}_{dir}_{step}.png`, `walker_{a,b}_{dir}_{step}.png`, `stand_{man,dog,guard,merchant}_{0,1}.png`),
the 8 compass arrows (§5) and `townchars.json` (frame size, directions, frame order, slots, talk).

---------------------------------------------------------------------------------------------

## 2. Screen ✅

Port frame = GRAPH.DAT picture 3 (layout TYPE 1, `[0xC30] & 0x80`) or 5 (TYPE 2), drawn by 0x5A51 in
0x8AB2 (`assets/images/graph_03.png` / `graph_05.png`). Game area 640×400 (VGA y + 40).

- **Map window**: 24×24 tiles of 16 px at (96, 8) → 384×384. Window tile (c, r) = map tile
  `(C40 + c, C42 + r)` at screen `(96 + 16c, 8 + 16r)`. Painted by 0x1F7C (only tiles that differ
  from a per-page cache at cs:0x1AFC; 0x20D3 invalidates it). No sub-tile scrolling: every move
  is a whole 16 px tile.
- A sprite at map (x, y) covers tiles (x..x+1, y..y+1) and is drawn at screen
  `(96 + 16(x − C40), 8 + 16(y − C42))`. Draw order: map, hero, standing figures, walkers.
- Right side: market status panel (0x86F2 → 0x84FD), **compass rose** (direction pad) and four
  vertical **command tabs**. Hit rectangles DS:0xAE14, 12 × 9 B `(x1, y1, x2, y2, key)`, game coords:

| # | rect | key | action |
|---|---|---|---|
| 0 | 528..576 × 304..344 | `8` | up |
| 1 | 552..600 × 336..376 | `6` | right |
| 2 | 528..576 × 368..408 | `2` | down |
| 3 | 504..552 × 336..376 | `4` | left |
| 4..7 | same rects as 0..3 | 0x1E, 0x1C, 0x1F, 0x1D (cursor up, right, down, left) | same |
| 8 | 618..639 × 72..152 | `/` | 정보 (DS:0xAE88[12] → 0x20559) |
| 9 | 618..639 × 152..232 | `*` | 편성 (0x20703) |
| 10 | 618..639 × 232..312 | `+` | 지휘 (0x207CF) |
| 11 | 618..639 × 312..392 | `=` | 항해 (0x208C7) |

---------------------------------------------------------------------------------------------

## 3. Main loop ✅

Call chain: day loop 0x1AC8F → per tick 0x1ABA7 → (in port) **0x1B4DA** town session →
**0x1B337** walk loop → 0x6568 step / 0x1B08E door.

```
0x1ABA7 tick body, in port ([0xC3A] != 0xFF):
    if [0xC6DC] == 0: palette = DS:0xAD22 + 0x30·phase(tick)      ; 0x1913C, 0x9754
    fade in (0x983F)
    cost = town_session()                                         ; 0x1B4DA
    [0x571] += cost                                               ; time passes only here
    if date bytes >= 0xF0 (0x1AD6E, a load happened): return
    if still in port: redraw window + hero facing down (0x1AB78)
    if [0xC3C] & 0x80 (slept at the inn): [0x571] = 72           ; ends the day
    elif [0xC6DC] == 0: palette = tick < 72 ? AD22 + 0x30·phase : AD22
    [0xAD20] = 1
0x1B4DA town_session:
    0x86F2 (status panel)
    while [0x426] == 0 and [0xC3A] != 0xFF and !0x1AD6E():
        wait until no key/button (0x12EFD); r = walk_loop(); wait again
        if r != 0: return r
    return 0
```

`phase(tick)` = DS:0xAD1A[tick / 12] = `0,1,2,2,3,0`: 0 night (00–04, 20–24 h), 1 dawn (04–08),
2 day (08–16), 3 dusk (16–20). Palette 4 (DS:0xADE2) is the sea fog palette, never used in town.
`[0xC6DC]` (force day palette DS:0xAD82) is only ever cleared (0x15BF3).

```
0x1B337 walk_loop:            ; cursors = [0x2570 none, 0x29F0 up, 0x28D0 right, 0x2690 down, 0x27B0 left]
    aim = 0 (0 none, 1 up, 2 right, 3 down, 4 left); face = 2 (down)
    reset mouse motion counters (0x4FA5)
    loop:
        if [0x426] != 0: return
        key = 0x20A8A()                         ; 0 none, 0xFF left button, else translated key
        (mx, my) = mickeys since last poll (0x4FA5, INT 33h/0Bh)
        if |mx| > 8 or |my| > 8:                ; mouse aims, the cursor turns into an arrow
            aim = |my| < |mx| ? (mx >= 0 ? 2 : 4) : (my >= 0 ? 3 : 1)
        r = 0x1B29C(key)                        ; rects, below
        if r != 0xFF: aim = r
        if [0xC3A] == 0xFF or 0x1AD6E(): return
        set mouse cursor cursors[aim] if changed (0x5012)
        timer_start(([0xC30] & 1) ? 8 : 4)      ; 0x1678, INT 66h F101h
        if key != 0 and aim != 0:
            face = aim − 1
            step(face)                          ; 0x6568
            r = door_check()                    ; 0x1B08E
            if r != 0: return r                 ; entered an open building: ticks to add
        else:                                   ; idle frame
            paint window; draw hero (frame unchanged: toggled twice); npc_tick(−1) (0x6147)
        while timer running (0x1685): wait
```

`0x1B29C(key)`: for rect i = 0..11, first match of `rect.key == key` **or** mouse position inside
the rect (0x4EBC, INT 33h/03h). No match → 0xFF. Match with `key == 0` (mouse just hovering) → 0
(aim cleared). Match i < 8 → direction `i%4 + 1`. Match i ≥ 8 → tab i−8 pulled out (0x91DE),
command DS:0xAE88[4 + i] called, tab restored (0x91C6), returns 0xFF.

**Input** (0x20A8A over 0x4044/0x3FB5): left button → 0xFF; right button → 0. Extended keys: cursor
keys → 0x1E/0x1C/0x1F/0x1D, F1 → `/`, F2 → `*`, F3 → `+`, F4 → `=` (via 0x16, 0x14, 0x02, 0x19),
PgUp → `?`, PgDn → `>`, Del → 0x7F, other F-keys/Home/End/Ins/keypad 5 → 0xFF; space → Enter (0x0D).
Then `-` → `+` and `+` → `=`. So keypad `/ * - +` = 정보 편성 지휘 항해, keypad (NumLock) `8 6 2 4`
and cursor keys walk. **Any other key, or the left button outside every rect, walks in the aimed
direction** (the last mouse motion); holding the button walks continuously, a held key walks at the
keyboard repeat rate (the key buffer is flushed after each paint, 0x3F9E).

**Speed**: one tile per loop pass, a pass lasts at least 8 timer units with 표시효과 on
(`[0xC30] & 1`, default) or 4 with it off. Timer unit: FMDRV programs the PIT to 291.3 Hz
(divisor 0x1000, FMDRV.COM 0x131C) and decrements the F0/F1 countdowns when an accumulator
`+= 0x35` overflows (FMDRV 0x1FC/0x20E) → **60.3 Hz**. So ≥ 133 ms (≈ 7.5 tiles/s) per step, or
≥ 66 ms with effects off, plus paint time. Hero step frame toggles every step; NPCs update once per
pass whether the hero moves or not.

---------------------------------------------------------------------------------------------

## 4. One step: 0x6568(dir) ✅

dir 0 up, 1 right, 2 down, 3 left → (dx, dy). "free(p)" = feet row walkable (0x5F6A, rule below)
**and** no townsfolk collision (0x6050(−1, p)). Map position p = (C40+C44, C42+C46).

```
if C44+dx not in 0..22 or C46+dy not in 0..22: goto paint (turn only; map edge)
save camera to [0xC170]/[0xC174]
r = collide(−1, p + (dx,dy))                       ; 0x6050
if r != 0 and [0x950E] >= 10: talk(r) (0x63A1); [0x950E] = 0; return 0   ; no move, no repaint
if [0x950E] < 10: [0x950E]++
p += (dx, dy)
if !free(p):                                        ; slide around the obstacle
    for side s in (+1, −1):                         ; side vector = s·(dy, dx)
        k[s] = 20
        for k in 1..19:
            q = p0 + s·k·(dy, dx)                    ; p0 = position before the step
            if q outside 0..94 or !free(q): break
            q2 = q + (dx, dy); if q2 outside 0..94: break
            if free(q2): k[s] = k; break
    if k[+1] == k[−1] == 20: p = p0                 ; blocked, keep facing dir
    else: (dx, dy) = s·(dy, dx) with s = +1 if k[−1] > k[+1] else −1 (ties: −1)
          p = p0 + (dx, dy)                          ; ONE tile sideways toward the nearer gap
camera: if dx == −1 and C44 < 4 and C40 > 0, or dx == +1 and C44 > 18 and C40 < 72:
            C44 −= dx; C40 += dx                    ; same for y with C46/C42
face = dy < 0 ? 0 : dy > 0 ? 2 : dx < 0 ? 3 : 1    ; the slide direction if it slid
paint: [0xC166] = C42·96 + C40; compass highlight 0x934F(face); paint window (0x1F7C);
       hero 0x5FBE (frame face·2 + toggle); npc_tick(face) (0x6147); return 1
```

- **Walkability** 0x5F6A (hero) / 0x5FF4 (NPCs): feet tiles `L = map[y+1][x]`, `R = map[y+1][x+1]`;
  passable iff `L < b` and (`R < a` or `b ≤ R < c`) — info.md §1.10. The head row y is never tested.
- The camera keeps the hero in window columns/rows 4..18 (4 free tiles each side) except at the map
  edges (camera 0..72). Hero absolute range 0..94.
- Doors: the hero "enters" when his top-left tile equals a door tile (§6); checked by the caller
  after every step attempt, moved or not.

---------------------------------------------------------------------------------------------

## 5. Compass highlight ✅ (`compass_*.png`)

DATA1.LZW entry 6 (3840 B, loaded on town entry 0x8B52 → `[0xC0E]`:0x3EA0): 8 images 40×24, 480 B
each, 4 planes interleaved per byte column (`(y·5 + x/8)·4 + plane`). Image d = arrow d normal,
4 + d = lit. 0x934F(dir): if dir != `[0x9605]`, redraw the old arrow normal (0x92A8(0)); if
표시효과 is on, `[0x9605] = dir` and draw it lit (0x92A8(4)), else `[0x9605] = 0xFF`. Positions:
up (528, 304), right (552, 336), down (528, 368), left (504, 336) — verified by overlaying on
graph_03 (normal images match the frame pixel for pixel).

---------------------------------------------------------------------------------------------

## 6. Doors and buildings ✅

`0x5F1F`: first k in 0..11 with DS:0x88C[k] == (hero x, hero y) → building k (MENU 58 order), else −1.
All 100 market ports have doors 0..4; every door's entering position is reachable from the arrival
spot under the walk rule (checked with a flood fill over all 101 maps).

```
0x1B08E door_check:
    k = 0x5F1F(); if k < 0: return 0
    mouse cursor = default
    if closed by the hour table (town.md §1.1):
        msg 765 "문이 잠겨 있습니다." (0x1AF61), key wait; return 0     ; no time; hero stays ON the door
    cost = rand(3) + 2                                                   ; 2..4 ticks
    building picture 0x8D04(k) (GRAPH picture k+6 at (104,16); church 20 when 0x2C515())
    BGM: 주점 0x13, 왕궁 0x12 (0x94C6)
    [0xC46]++                                                            ; hero now at (door.x, door.y+1)
    scripts SNR0 (0x32CC1/0x32C30) and hero (0x32E02/0x32D86) for (port, k)
    if a script returned 0 and k != 4: skip the building
    else: standing / arrest check (town.md §1.2), then DS:0xAE88[k]()
    if still in port: port BGM (0x1AD8A), repaint window + hero facing down (0x1AB78)
    return cost
```

The returned cost is added to the tick (§3). After any building the walk loop is re-entered, so the
hero's facing resets to down. A closed door repeats msg 765 on every further step attempt until the
hero steps off.

**Arrival** (town entry 0x8AB2, from 기항 0x1BA64, the new game / load 0x16B56, info redraw 0x20656):
```
if [0xC3B] != [0xC3A]:
    load doors 0x8705
    if [0xC3B] == 0xFF:                       ; came from sea (or new game)
        C40 = clamp(door3.x − 12, 0, 72); C42 = clamp(door3.y − 13, 0, 72)
        C44 = door3.x − C40;  C46 = door3.y + 1 − C42     ; hero at (door3.x, door3.y+1), facing down
        townsfolk_init 0x8993
    [0xC3B] = [0xC3A]; [0x950E] = 10
DATA1[6] compass; 0x8747 town data; frame picture 3/5; paint; status panel; 0x19150 palette; BGM
```
A save made in port stores `[0xC3B] = 0x82`, so loading it reloads the doors but keeps the saved
camera, walker and townsfolk.

**Leaving**: only through the harbour office (building 3, 0x280A3; supply ports 0x2802C): 출항 →
0x27176 checks → 0x837D sea screen sets `[0xC3A] = 0xFF` (0x840E), `[0xC3B] = 0xFF` (0x273C3); the
walk loop sees `[0xC3A] == 0xFF` and returns. The 항해 tab in port only offers 아이템 and 기능
(items 0..3 disabled, commands.md §3).

---------------------------------------------------------------------------------------------

## 7. Townsfolk ✅

**Init 0x8993** (b = 0, 1, 2, 4 for i = 0..3; door = DS:0x88C[b]):
```
slot i     = (door.x − 2, door.y + 1, facing 2)      ; walker left of the door
slot 4 + i = (door.x + 2, door.y + 1, kind i)        ; standing figure right of the door
i == 2: slot 2 = (door.x, door.y) (on the 조선소 door), slot 6 = (0xFF, 0xFF)   ; kind 2 = guard only
guards (day, port nation n < 6, nation[n].+0x12+hero nationality & 0x10, hero at (door3.x, door3.y+1)):
    slots 4, 5, 6 = (door3.x − 2, door3.y + 2), (door3.x, door3.y + 2), (door3.x + 2, door3.y + 3), kind 2
```
So a market port has 4 walkers and 3 standing figures (man, dog, merchant). Supply ports (record
100 has only the harbour; other doors (0,0)) get junk positions in the map corner that are never
on screen: effectively no townsfolk. In chip-set 3 towns 99 of the walker homes are not walkable;
the walkers simply step off (no walker is boxed in).

**npc_tick 0x6147(dir)**, once per loop pass:
```
if night (0x603B: tick < 12 or >= 60): townsfolk_init(); return       ; nobody drawn at night
for slot 4..7: if visible: draw frame 24 + 2·kind + rand(2)            ; flicker between 2 frames
for slot i 0..3 (x, y, d):
    d' = rand(10) == 0 ? rand(4) : d
    if rand(3) == 0: (x', y') = (x, y) + step(d') else (x', y') = (x, y)
    if collide(i, x', y') == 0 and x' < 94 and y' < 94 and feet walkable (0x5FF4):
        draw at (x', y') frame 8·(1 + (i&1)) + 2d' + ((x'+y') even); store x', y', d'
    else: draw at (x, y) with the same frame rule (facing d'); d = (d' + rand(3) − 1) & 3
visible (0x611F): C40 ≤ x ≤ C40+22 and C42 ≤ y ≤ C42+22
```
Collision 0x6050(self, x, y) (always 0 at night): any other slot with `|Δx| ≤ 1` and `|Δy| ≤ 1` →
`slot+1`, or 7 for a slot ≥ 4 of kind 2; for an NPC also the hero (→ 1). 2×2 sprites therefore never
overlap. NPCs ignore doors and the window.

**Talking** 0x63A1(r) — bump into a figure with the cooldown ≥ 10; message window 0x76EB, key wait.
Pure flavour, no state changes:

| r | figure | message |
|---|---|---|
| 1 | walker 0 (A) | msg 642 + port (642..741: one line per market port, e.g. 리스본 "[원작 문장 생략].") |
| 2 | walker 1 (B) | msg 630 + day % 10 (tips) |
| 3 | walker 2 (A) | used ships DS:0x7E70 slot 0 (most recent yard): msg 640 with class name (ship record 40 + class), none → 641 |
| 4 | walker 3 (B) | msg 623 + port nation (greeting in Portuguese, Spanish, Turkish, English, Italian, German for the Dutch, 6 → 안녕하세요) |
| 5 | slot 4, kind 0 (man) | supply port → 578; capital (0x1ADEC) → 579 (nation, port); nation < 6 → 580 (nation, 식민지 if `+0x13 & 0x80` else 동맹항, port); else 581 |
| 6 | slot 5, kind 1 (dog) | msg 619 + port % 3 (멍멍！ / Ｂｏｗｗｏｗ！ / 캉캉！) |
| 7 | slot 6 or any guard | msg 622 with the hero's nationality name (blockade) |
| 8 | slot 7, kind 3 (merchant) | msg 616, then 617 with the specialty name DS:0x764[market +0x1A], or 618 if none |

**Guards** (war.md §4.1): three standing kind-2 sprites below the harbour door; with the hero at
the arrival spot they leave only the way back into the harbour office (every other move collides →
msg 622, then the slide search finds no gap). They disappear at night (npc_tick re-inits without
guards) or when the harbour office drops them (0x28123: hour ≤ 18 or ≥ 54, rand(3) == 0); nothing
re-adds them until the next arrival. No arrest or fine while walking — arrests only happen at
building doors (town.md §1.2–1.3).

---------------------------------------------------------------------------------------------

## 8. Time ✅

- Walking, bumping, talking and the four command tabs cost **no ticks**; the clock is frozen while
  the walk loop runs. Each open building costs `rand(3) + 2` ticks (40–80 minutes), added after the
  building returns; a closed door costs nothing. Building code may change the tick itself (inn).
- The town palette is set from the phase only when the walk session (re)starts (§3), i.e. after a
  building; it never changes while walking. Only colours 8..15 change (map tiles), sprites do not.
- Night (tick < 12 or ≥ 60): townsfolk and guards vanish, no collisions.
- When a building pushes the tick to 72 the day loop ends: daily settlement 0x190F9, NPC fleets for
  the skipped ticks (0x1A5F8 per tick index) — not walking-specific (fleets.md).

---------------------------------------------------------------------------------------------

## 9. For the remaster

The Swift side needs (data: `assets/portmaps/portmaps.json` + PNGs, `assets/townchars/townchars.json`):

1. Town state per visit: camera, hero tile (top-left of 2×2), facing, step toggle, talk cooldown,
   8 townsfolk slots `(x, y, k)`; save them with the game (the original does).
2. Arrival at `(door3.x, door3.y+1)` facing down with the camera rule of §6; townsfolk init §7 incl.
   blockade guards (replace the current "buildings closed during blockade" substitute).
3. Input: arrows / numpad 8 6 2 4 / compass clicks / held mouse button = one tile per pass; tabs
   정보 편성 지휘 항해 (F1–F4, keypad / * - +). The mouse "aim" quirk can be replaced by
   click-direction-from-hero if wanted.
4. Step rule §4: feet-row walkability, ±1 collision, sideways slide (one tile toward the nearer gap,
   search ≤ 19), camera margin 4, map edges. Tween the 16 px move for smoothness but keep the logic
   tile-based at ≈ 7.5 steps/s.
5. Door check after every step attempt (§6): hours (town.md), msg 765 when closed, cost 2–4 ticks,
   scripts (port, building), arrest check, building UI, exit one tile below facing down.
6. Townsfolk tick each pass (§7): walker AI, standing 2-frame flicker, night hide/reset, talk table.
7. Time frozen while walking; palette by phase on returning from a building; leaving only via the
   harbour office 출항.

---------------------------------------------------------------------------------------------

## 10. Open questions / quirks

1. Real step rate on period hardware: the timer gives ≥ 133 / 66 ms per pass; paint time and DOS
   keyboard repeat (typematic) are not modelled. 🔎
2. Every key except the mapped ones (Esc, Enter, letters, unmapped F-keys = 0xFF) walks in the
   mouse-aimed direction, and a key with the cursor over a rect triggers that rect — faithful but
   odd; the remaster may drop it.
3. Leaving port from a tab (기능 → 로드 of a sea save) makes the walk loop return 0xFF, added to the
   tick; harmless because the load also sets the date bytes to 0xF0 (0x1AD6E). Not traced further. 🔎
4. Walker 2's used-ship line reads yard memory slot 0 (the last shipyard visited), which may be
   another port's stock.
5. Per-port lines 642 + port would be wrong for supply ports (742..), but no townsfolk are reachable
   there.
6. Message window geometry of 0x76EB and the status panel 0x84FD were not decoded. 🔎
7. 0x6147 computes `dir / 2` when the camera moved and discards it (dead code); `[0xC170]/[0xC174]`
   have no other reader.
