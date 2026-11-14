# Information screens, records and item use (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N, "MENU N[i]" = item i of MENU.DAT entry N (0-based, NUL-separated items).
Status: ✅ read in full from code · 🔎 read, some drawing details skipped · ❓ not decoded.

Helpers used below: `say(msg, ...)` 0x32F2C (printf of a message), `loadmenu` 0x32FE8, `listmenu(code, n)`
0x153BF (scrolling list over the word list DS:0x574, see §0), `popup` 0x204A2, `waitkey` 0x140EA,
`rand(n)` 0x4D86, `umin` 0x4D42, `abs` 0x4D3C, `sign` 0x4DA0. Records: person DS:0x1242 × 50 (0x5AEC),
family DS:0x11E6 × 14 (0x5ADC), fleet DS:0x2DB2 × 133 (0x5B1C), ship slot fleet+0x2B × 9 (0x5B4C),
cargo DS:0x5210 × 30 (0x5B2C), ship DS:0x57CE × 25 (0x5B6E), class DS:0x5E28 × 12 (0x5B7E), port
DS:0x5F54 × 20 (0x5B8E), market DS:0x697C × 37 (0x5B9E), trade zone DS:0x77F0 × 128 (0x5BAE), site
DS:0x7E88 × 7 (0x5BC2), item DS:0x8144 × 26 (0x5BD2).

---------------------------------------------------------------------------------------------

## 0. Shared pieces ✅

**List menu 0x153BF(code, n).** `code & 0x3F` selects a column header (MENU 47 item) and a row printer
(far table DS:0xAA3A); rows are the n words at DS:0x574. Returns the chosen row index or −1.
Codes used here: 0 선박명 (ship list), 1 상품명/총중량 (0x142F0: goods name padded to 11 + `%5d` of
DS:0x5D8[g]), 6 인물명, 8 시세·물가 (0x1458E: category name DS:0x7CA[c]), 9 인물명/직업, 0xD 아이템명,
0x12 발견물명 (0x14630: COLONY.DAT name).

**List builders**: 0x12986 = ship slots in use (`slot+8 & 0x30 == 0x10`), returns the count;
0x12A8E = hero first, then the 30 companions DS:0x2D57; 0x12E5C = every inventory item (DS:0x2D93 × 20,
0xFF = empty).

**Menu greying**: `[0xA9BA]` (and `[0xA9BB]` for items 8+) is a bit mask, bit k = item k disabled.

**Palettes** (B,R,G nibbles ×48 B). `0x9754(p)` copies p into the current palette DS:0x961E,
`0x983F` fades to the current palette, `0x9825(p)` fades straight to p.

| palette | used by |
|---|---|
| DS:0x961E (initially = 0x40ECE) | current palette |
| DS:0xAD22 + 0x30·phase (5 entries) | time of day, town and sea (0x1ABE0, phase from 0x1913C); only colours 8–15 differ |
| DS:0xAD82 (phase 2) | daylight; forced by the 항구지도 screen (0x1DB3C). Same as 0x40ECE except colour 15 (`fed` vs `62c`) |
| DS:0xAF80 | fleet / ship info screens (0x1CF97, 0x1D037, battle 0xAC4C), also 0x250A8, 0x27E35, 0x2C31C |
| DS:0xAF50 | world chart and treasure map (0x1D43C …): a parchment palette — sea 9 = `fca`, land 8 = `a86`, fog 13 = `da8`, fleet marker 11 = `b98` (R,G,B digits) |

(`assets/images/graph_25.png` was decoded with the main table; the game shows that picture with DS:0xAF50.)

---------------------------------------------------------------------------------------------

## 1. 정보 command (MENU 26) — 0x20559 ✅

The same routine serves the town and the sea: it is entry 12 of the building table DS:0xAE88 and entry
4 of the sea command table DS:0xB160. MENU 26 = 자함대정보, 함선정보, 인물정보, 주인공정보, 적하정보,
적하일람, 발견물정보, 항해도, 항해일지, 항구지도 (items 0..9). Jump table cs:0xEEF (0x2062F):

| # | item | handler | greyed when |
|---|---|---|---|
| 0 | 자함대정보 | 0x1D003 → 0x1CAB2(hero fleet) | no ship (0x12986 = 0) |
| 1 | 함선정보 | 0x1D02D: pick ship (list code 0) → 0x1BB79(slot, 15) | no ship |
| 2 | 인물정보 | 0x1D064: pick person (code 6) → 0x1C215(p, 15, own=1) | — |
| 3 | 주인공정보 | 0x1C5E5 | — |
| 4 | 적하정보 | 0x1D08D: pick ship → 0x1C742(slot) | no ship, or no trade goods in any ship (0x20500) |
| 5 | 적하일람 | 0x1C8CC | same as 4 |
| 6 | 발견물정보 | 0x1CA4E | no site with `+6 & 0xE0 == 0x60` (active, sighted, found) |
| 7 | 항해도 | 0x1D447 | `[0xF9A]` (explored cells) = 0 |
| 8 | 항해일지 | 0x1DCA8 | first log word = 0xFFFF (empty) |
| 9 | 항구지도 | 0x1D930 | at sea (`[0xC3A]` = 0xFF) |

The menu loops until cancelled; each screen ends with a key press. Nothing here costs time.

### 1.1 자함대정보 — fleet screen 0x1CAB2(fleet) ✅ (also battle 자함대/타함대 via 0xAB72)

Draws a sea background of 40×20 tiles (`[0xC0E]` +0x2BA0), the fleet's ship sprites (0x7EE9 by class)
at the 10 positions DS:0xAFF0 (x byte, y/16 pairs), then:
- no ship: msg 918 and return;
- admiral portrait (0x7BD2), msg 919 `%s제독` (admiral surname), msg 920 항해 레벨 (+0x24),
  msg 921 전투 레벨 (+0x25);
- then the per-ship loop below and msgs 922–924. Palette DS:0xAF80.

```
own = (player person +0x2C == fleet)
for every slot in use:
    cls = ship(+7).+0x12; C = class(cls)
    if own: c8 = cargo+8 (파수 %), c9 = cargo+9 (운항 %), load = cargo+0xA, capt = cargo+0x1B
    else:   c8 = 25, c9 = 50, load = C.capacity(+6) / 2,   capt = admiral (fleet+0x2A)
    crewTotal += crew;  gunsTotal += guns(+6)
    gunners = min(300, (100 − c9 − c8) * crew / 100)                     # "갑판" crew
    power  += 2*hull(+2) + min(guns, gunners) * (2*range[t] + pow[t]) / 10 + gunners
              # t = slot+8 & 7, range DS:0x828, pow DS:0x838 (unsigned 16-bit)
    # speed only picks the "slowest" ship; it is never printed
    d = |windDir − heading|   windDir = ([0xC3D] & 0x38) >> 3, heading = PLAYER fleet +0x1A
    a = T[d][cls] * sail(+5)                     # T = DS:0x714 8×8, indexed by CLASS NUMBER (see note)
    a = (min(100, c9*crew / C.minCrew(+5)) * a / 100) * min(150, 180 − min(180, 100*load/C.capacity)) / 100
    s = min(40, min(30, a + a*capt.navLevel/10) * capt.SEA / 75)
    if s < best: best = s; slowest = slot         # strict <, first slot wins ties
    minHull = min(minHull, hull)                  # starts at 100
msg 922: 함대선회력 = slowest.rudder(+4), 선원 총수 = crewTotal
msg 923: 함대추진력 = slowest.sail(+5),   총포문수 = gunsTotal
msg 924: 함대내구력 = minHull (≤ 100),    전투력 = power
```
This confirms battle.md §13.2. Note: the real speed (0x30C2F) indexes T by the class's sail type
(class +9) and multiplies by wind force / 150; both info screens (here and 0x1BA80) index T by the class
number and ignore wind force. For the remaster: 함대선회력/추진력 are the rudder/sail of the slowest ship.

### 1.2 함선정보 — ship screen 0x1BB79(slot, x) 🔎

Window with the class picture (0x7EE9), the figurehead picture if cargo `+0x1D` ≠ 0 (TRANSIT.DAT,
0x480-byte bitmaps at file offset 0x1980 + 0x480·figurehead), a 2×2 block with 식수/10, 식량/10, 자재,
포탄 (icons from `[0xC0E]`), then
- msg 1146 `%s급` (class name), msg 884 `%s호` (ship name), msg 885 선장 (captain = cargo +0x1B),
- msg 887 무장 cannon name DS:0x808[t]; if t ≠ 0, msg 888 `guns/capacity(ship +0x14)(guns × DS:0x818[t])`
  (DS:0x818 = cannon weight × 10),
- msg 889/890 운항/파수/갑판 = `c9·crew/100`, `c8·crew/100`, the rest — so cargo **+9 = 운항 %, +8 = 파수 %**
  (answers battle.md open question 1 for the labels),
- msg 891 운항요원 = class +5 (minimum sailing crew),
- msg 892/893 적재율 = `100 · totalLoad(0x5C7F) / class capacity` %, colour 2 above 79, colour 4 above 30,
- msg 894 속도 = `(0x1BA80(slot) + 1) / 2` KT, where 0x1BA80 is the speed formula with d = 0, wind force
  4, `a = sail · T[0][cls] · 4 / 150`, crew and load factors as in §1.1 (load = cargo +0xA), captain = cargo +0x1B,
- seven bars, MENU 41 labels, msg 895 `%-9s%4d/%3d` + bar 0x8F08 of `100·cur/max`:
  HULL hull/maxHull, RUDDER rudder/class rudder, SAILS sail/class sail, CREW crew/ship max crew (+0x15),
  CONDITION morale (cargo +0x1C)/100, CARGO cargo load (0x5C2A)/ship cargo space (+0x17),
  CAPACITY total load (0x5C7F)/class capacity.

### 1.3 인물정보 — person screen 0x1C215(person, x, own) ✅

Portrait; if `own`: the ship the person captains (`cargo +0x1B == person`; a non-captain is shown with
the hero's ship) as msg 925 `%s호`, and the role name DS:0x858[+0x2E] (제독…항해사). Then msg 897
`성 이름`, msg 898 연령 (+0x2A); seven stat bars DS:0x87E names 통솔력…매력 with values +0x1C..+0x22
(**운 is not shown**). If `own`: for the hero msg 899 작위 + title (or msg 900 없음); for a companion
msg 901 급료 = `10 × DS:0x2D75[k]`. Then msg 902/903 항해 레벨 + 경험 (+0x24, +0x26), msg 904/905 전투 레벨
+ 경험 (+0x25, +0x28), msg 906 국적 = DS:0x866[+0x31 & 0xF] (0..5 nations, **6 = "해적"**), msg 907 기능
and the five skill names DS:0x874 (측량, 지도제작, 포술, 회계, 교섭) — skill i is highlighted (colour 1,
msg 909) when `+0x30 & (0x10 >> i)`, else colour 6 (msg 908).

### 1.4 주인공정보 — hero screen 0x1C5E5 ✅

```
msg 910 header "소지금 공헌도"
msg 911 금화:%5d   gold % 10000         msg 912 금괴:%5u   gold / 10000
msg 913 명성, then 3 × msg 914 "%4s:%5u": MENU 42 (교역, 해적, 모험), family +0/+2/+4
for n in 0..5: msg 915 "%-12s:" nation name DS:0x866[n];
               if family.standing[n] (+6+n) < 100: colour 2 (msg 916)
               "%3d" |standing[n] − 100|          # 공헌도; nation 6 standing (+0xC) is not shown
```
Rank and nationality are on the 인물정보 screen, not here.

**Title tables** (loaded at game start, 0x15FFF): DATA1.LZW entry **16** (European: 기사, 준훈작, 훈작,
준남작, 남작, 자작, 백작, 후작, 공작) — or entry **17** (사족, 감찰관, 군수, 지사, 영주, 대영주, 군후, 재상,
대재상) when `[0x1241] == 5` — 81 bytes (9 × 9) to DS:0xC685; title of rank r = DS:0xC67C + 9r (r ≥ 1).
So the Ottoman titles (HORIEDIT.H `Ipeer`) belong to **hero 5 (the Istanbul hero)**, chosen by hero, not by
current nationality; a defecting hero keeps his table. (town.md §5 says this build has no Turkish table —
that is wrong.)

### 1.5 적하정보 — cargo of one ship 0x1C742(slot) ✅
Returns silently if the ship's five goods slots (cargo +0x16) are all 0xFF. Else window, msg 884 ship
name, and one msg 917 `%-10s%5d` line per occupied slot: goods name DS:0x764[g], amount cargo +0xC (u16).

### 1.6 적하일람 — goods totals and the best market 0x1C8CC ✅
```
total[g] (DS:0x5D8 + 2g) = Σ over ships in use of amounts of goods g; list = goods in first-seen order
pick g from listmenu(code 1)            # rows "name ... total"
best = 0x1C818(g):
    best = port 0, bestPrice = 0
    for p in 0..99:  m = market(p)
        price = (m+0x1A == g) ? (m.idx[cat(g)] + 50) * m.specialtyPrice(+0x18) / 200
                              : zone(m+0x21).buy[g] * (m.idx[cat(g)] + 50) / 100
        if price > bestPrice and port(p).+0x13 & 0x40 (visited): best = p, bestPrice = price
if hero has 회계 (+0x30 & 2): hero says msg 848 (goods, port name)
else for each companion with role 4 (경리주임): msg 849 if he has 회계, else msg 850 (no port)
```
Without either the screen shows nothing after the pick. No price is printed, only the port; port 0
(리스본) is named when no visited port pays anything.

### 1.7 발견물정보 — discoveries 0x1CA4E → 0x34043 → 0x33F3C ✅
List (code 0x12) of sites 0..99 with `+6 & 0x80 == 0`, `& 0x40`, `& 0x20` (active, sighted, found —
reporting to a patron does not remove them). Picking one draws (palette unchanged):
- the 48×48 picture KAO entry `0x80 + COLONY[+0x12]` at (x byte 0x11, y 0x30) by 0x7BE5,
- the name (COLONY +0, 18 B), msg 1079 `（%s）` category DS:0x8DA[+6 & 7] (보물, 원주민, 희귀한 동물, 식물,
  유적, 괴물, 자연, 원주민),
- msg 1080 `중요도%s` with MENU 34[value / 25] (value = site +5): 0–24 D, 25–49 C, 50–74 B, 75–99 A, 100 ☆,
- the description (COLONY +0x13, word-wrapped 40 columns).

Pictures: KAO.LZW entries 128..255 = pictures 0..127, 48×48, three planes byte-interleaved
(6 B × 3 per row), colours 0..7. Discoveries use 0..84 (COLONY byte +0x12; 12 is unused); item n uses
picture `0x55 + item[+0x15]` = 85..127 (0x28D5F). `tools/portmaps.py` writes them to
`assets/pictures/NNN.png`.

### 1.8 항해도 — world chart 0x1D447 ✅ (drawing 🔎)

**Explored bitmap** DS:0xD74, 45 rows × 12 bytes: cell (col, row) = 24×24 world tiles, col = x/24
(0..89), row = y/24 (0..44); bit `0x80 >> (col & 7)` of byte `12·row + col/8`. Counters `[0xF9A]` total,
`[0xF9C]` since the last 지리보고 (u16).
- New game 0x160DF: clears 540 bytes, marks rows 8..17 × cols 4..16 (130 cells, `[0xF9A]` = 130,
  `[0xF9C]` stays 0, so the home seas are never paid for).
- At sea 0x6BA2 (and 0x6A40): whenever the view-window block index `[0x704]` changes (it is
  `30·clamp((y/24)%45 − 1, 0, 42) + clamp((x/24)%30 − 1, 0, 27)`, so normally whenever the fleet enters
  another 24-tile cell, except across the clamped edges of a 720-tile map file), the 3×3 cells around the fleet's cell are marked: cols `(x/24 − 1 … +1) mod 90`,
  rows `y/24 − 1 … +1` clipped to 0..44; each newly set bit increments both counters.
- 지리보고 with `[0xF9A] ≥ 3300` (0xCE4): msg 507, GRAPH.DAT picture 63, and every bit is set
  (11 × 0xFF + 0xC0 per row) (0x2D3C1).

**Overview** 0x1D340 (palette DS:0xAF50): GRAPH.DAT picture **25** (640×400; the map area is 540×270
at (50,50)). The chart is rotated by `[0x711]` = 30 cells (constant): display column `dc` shows world
column `(dc + 60) mod 90`, i.e. `dc = (col + 30) mod 90`. Every unexplored cell is filled as a 6×6 box of
colour 13 at `(50 + 6·dc, 50 + 6·row)` (0x219DD). The fleet is a 6×6 box of colour 11 at
`(50 + ((x + 720) mod 2160 − 12)/4, 50 + (y − 12)/4)` (division truncates toward 0).
World x 0 is therefore chart pixel 50 + 180; 리스본 (x 120) is at ≈ 260.

**Zoom**: a cell picker 0x15768 over the 90×45 grid (6-px cells, 2×2 cursor, starts at the fleet's cell).
On a pick (dc, row): `col = (dc − 30) mod 90`; if any of cells (col..col+1, row..row+1) is explored
(no wrap in this test), the screen shows those four cells at (96,8), (288,8), (96,200), (288,200):
24×24 world tiles each, 8×8 px per tile (192 px per cell); unexplored cells are plain colour 9. Tiles are
the world tiles halved by 0x1D251 (top-left pixel of each 2×2, table DS:0xB004). Any key returns to the
overview; cancel leaves. In port the town graphics are unloaded on entry and reloaded (0x8747) on exit.

### 1.9 항해일지 — logbook 0x1DCA8 ✅

**Storage**: a far buffer `[0xC16]` of 0x300 bytes = **48 entries × 16 B**; a first word 0xFFFF marks the end.
New game fills it with 0xFF (0x162B2). Saved after the data segment image: slot offset
`0x97 + slot·33340`, DS:0xC30..0x8B6B (32572 B), then the 0x300 log bytes (0x1652C / 0x167DB).

**Writer** `log(type = ax, a = dx, b = bx, c, d)` 0x1DC0F (two stack words, c pushed first): first free
entry; if all 48 are used, entries 1..47 move down one and the new one is entry 47. Entry (0x1DB89):

| off | u16 |
|---|---|
| +0 | date `(12·[0x56E] + [0x56F])·31 + [0x570]` (year since 1501, month 0..11, day 0..30) |
| +2 | type |
| +4 | a |
| +6 | b |
| +8 | c |
| +0xA | d |
| +0xC | unused |

**Entry types** (only these five are written or printed; msgs 368–383 are "－－－없음－－－" fillers):

| type | written at | a / b / c / d | printed |
|---|---|---|---|
| 0 arrival | 0x1BA5D, after "기항하겠습니까" (msg 365) is answered yes; also sets `[0xF91] |= 0x20` | days at sea `[0x2D54]` / port | msg 366 `[원작 문장 생략].` |
| 1 departure | 0x27392 (출항 confirmed) | days of supplies = `min(Σ water, Σ food) / max(1, Σ crew)` (cargo +0/+2 in tenths of a barrel) / port | msg 367 `…%d[원작 문장 생략].` |
| 2 battle | 0x103F3 (end codes 0/2/4/6 → result 0), 0x10531 (code 1 → 1), 0x10588 (codes 3/9 → 2); none for 5/7/8 | enemy admiral's fleet number / result | msg 837 `우리 함대는, %s %s대와 전투%s`: nation DS:0x866[fleet/10]; kind MENU 52: fleet ≥ 60 or `fleet%10 == 0` → 함대, 1–4 → 상선, 5–9 → 전함; MENU 53[result] (`, 승리했다` / `[원작 문장 생략]`) |
| 9 port sighted | 0x30870 (port sighting, both the ≤2-tile and the intuition path) | port / 0 | msg 381 `%s항을 발견했다.` (villages are not logged) |
| 12 purchase | 0x23F99 (교역소 buy) | goods / 0 / total price (16-bit) / quantity | msg 384 `%s([원작 문장 생략].` (b is the high word, always 0) |

Port names are port record +4. Sales, discoveries on land, royal events etc. are **not** logged.

**Display**: window; date as `%4d/%2d/%2d ` = `d/31/12 + 1501`, `(d/31)%12 + 1`, `d%31 + 1`, then the text.
Six entries per page (rows 0x30 px apart); it opens on the last page `(n − sign(n)) / 6`; page buttons
msg 1147 앞 / 1148 뒷 appear when there is an earlier / later page.

### 1.10 항구지도 — town map 0x1D930 ✅ (+ `tools/portmaps.py`)

**Town data** (loader 0x8747, on entering a port):

| file | content |
|---|---|
| CHIP_NO.DAT | 100 B: chip set s of market port p (0: Iberia/Mediterranean, 1: northern Europe 27–41, 2: Islamic, 3: Americas/Africa/Asia default, 4: 94–97, 5: 98–99, 6: 81–83, 85, 92). Supply ports (≥ 100) use set **3** |
| PORTCHIP.LZW | entry 2s = 240 tiles of 16×16, four sequential planes of big-endian u16 rows (128 B) → `[0x428]:[0x42A]`; entry 2s+1 = 4 bytes `(0, a, b, c)` → DS:0xC128 |
| PORTMAP.LZW | entry p (p < 100) or **100** (every supply port): 96×96 tile bytes, row-major → `[0x432]:0` (row stride 0x60) |
| ZA_DAT.DAT | 101 × 24 B: twelve (x, y) door tiles in MENU 58 order (record 100 for supply ports; only 항구 is set there). (255,255) or (0,0) = no such building — e.g. 리스본 has no 점술가 |
| CHAR.LZW | entry hero → `[0x70A]:0`, entry 6 → `[0x70A]:0x1400` (walking sprites) |

Walkability (0x5F6A / 0x5FF4) for the 2-tile-wide walker with left tile L and right tile R:
passable iff `L < b` and (`R < a` or `b ≤ R < c`). Thresholds per set: 0:(29,34,40) 1:(21,26,31)
2:(20,25,30) 3:(22,26,31) 4:(37,42,48) 5:(32,37,46) 6:(21,22,27).

**Screen**: fade to black, build 256 halved 8×8 chips from the town tiles (0x1D251), then show 2×2 of the
4×4 blocks of 24×24 tiles (a 48×48-tile window, 384×384 px at (96, 8), mode 2 of 0x1D0B5, no fog).
Window block: `bx = (px)/24`, `by = (py)/24` of the walker's tile (`[0xC44]+[0xC40]`, `[0xC46]+[0xC42]`);
`bx −= 1` if `bx == 3` or (`px % 24 < 12` and `bx ≠ 0`); same for y. Labels: MENU 58 names for buildings
0..11 except 7 (NPC): tile (c, r) of the window is drawn at screen (96 + 8c, 8 + 8r); a label (16 px tall,
8 px per byte) starts at column `13 + c − len/2` (centred on the boundary of door tiles c, c+1, i.e. on the
2-tile door) and at y = `8·(r − 1)`, so it sits right above the door tile; c = doorX − 24·bx, r = doorY − 24·by.
It is boxed (0x216FC) and skipped if it would leave the window. Palette DS:0xAD82 (day). Any key returns.

**Export** — `build/venv/bin/python -I tools/portmaps.py` writes `assets/portmaps/000..100.png` (1536×1536,
8-bit indexed, day palette DS:0xAD82; supply ports all use 100.png), `assets/portmaps/portmaps.json`
(per port 0..129: map entry, chip set, named door tiles; walk thresholds per set) and
`assets/pictures/000..127.png` (48×48). The remaster can show a port's map by cropping the 48×48-tile
window above (or the whole 96×96 map) and placing labels from `doors`.

---------------------------------------------------------------------------------------------

## 2. 시세·물가 (교역소 MENU 6[3]) — 0x24C72 ✅

The 교역소 dispatch DS:0xB5D0: 구입 0x24578, 매각 0x24762, 투자 0x24A58, 시세·물가 0x24C72. Free, no time.
```
list (code 8) of the 10 categories; pick c:
   keeper: msg 151 "%s의 물가는 %d％입니다." (category name DS:0x7CA[c], market.idx[c] + 50)
   window, header msg 1112 "상품명   매각  매입" (two columns of goods)
   for g in goods of category c (DS:0x7BF[c] (0 for c=0) .. DS:0x7C0[c]−1):
       col 1 = zone sells g (zone +0x6E list)? buyPrice(slot) (0x23E11)
             : g == market.specialty (+0x1A)? 0x23E11(g)          # see note
             : " ----"
       col 2 = sellPrice(g) (0x24628)
```
`buyPrice` = `base × (idx+50)/100`, then ×12/10 unless the port nation's 면세증 is held — the exact price of
구입; `sellPrice` = the price 매각 would pay (specialty: `price × (idx+50)/200`). The zone list is shown
whatever the economy (구입 hides goods needing more economy). **Bug**: the specialty branch passes the goods
number g as a zone *slot* to 0x23E11, so when g < 9 and zone slot g is filled the column shows the price of
that slot's goods instead of the specialty price. With the new-game data this happens at ports 73, 74, 83,
84, 85, 86, 87, 88, 89 and 92 (specialty goods 0–5); ports 42 and 44 (slot empty) show the right price.

---------------------------------------------------------------------------------------------

## 3. 지도확인 (map maker, MENU 25[3]) — 0x2D4E3 ✅

Map maker menu (0x2D626, dispatch DS:0xB8E2: 계약 0x2D22D, 기능습득 0x2D2B0, 지리보고 0x2D3A0, 지도확인
0x2D4E3). Greying: 지리보고 when not contracted (NPC +0x13 & 0x10 clear) or already used this visit; 계약 when
contracted; 기능습득 when the hero has 지도제작 (+0x30 & 8); **지도확인 when no item 80..89 is held**.
```
item = first inventory item in 80..89 (보물지도); site = item.+0x18 (set at new game)
lonRaw = (site.x + 1981) mod 2160; E = lonRaw ≤ 1080 ? msg 128 동경 : (msg 129 서경, lonRaw = 2160 − lonRaw)
latRaw = 640 − site.y;            N = latRaw ≥ 0 ? msg 126 북위 : msg 127 남위
lat = (|latRaw|·8/57 / 5 + rand(2)) · 5        # degrees, rounded down to 5°, then +5° half the time
lon = (lonRaw/6 / 5 + rand(2)) · 5
msg 785 (금괴 2개, yes/no); no → leave
if gold <= 20000: msg 239 ("손님, 돈이 모자랍니다.")       # needs MORE than 20,000
else gold −= 20000; msg 786; msg 783 + "북위 %d도, " + "동경 %d도" + msg 784
```
The rand rolls happen before the question, once per use. Nothing is stored; the map item stays.
The site's coordinate convention (lat `(640 − y)·8/57`, lon `(x + 1981) mod 2160 / 6`) is the same as the
instruments (§5) and the patron's 모험이야기.

---------------------------------------------------------------------------------------------

## 4. Battle 정보 (MENU 51) and 아이템 ✅

**정보** 0xB089 (free; loops until cancelled), MENU 51 via 0x13ECB, handlers far table DS:0x96D0:

| # | item | handler | shows | greyed |
|---|---|---|---|---|
| 0 | 자함대 | 0xABD4 → 0xAB72(hero) → 0x1CAB2 | fleet screen §1.1 | — |
| 1 | 자함대인물 | 0xABDC | person list (code 6) → 0x1C215(p, 6, own=1) | — |
| 2 | 자함대선박 | 0xAC11 | list of own units alive and not departed (code 0) → 0x1BB79 ship screen | — |
| 3 | 타함대 | 0xAC8E | admirals of the other used sides (one → direct, else list) → fleet screen with NPC values (§1.1) | — |
| 4 | 타함대인물 | 0xACF5 | same list → 0x1C215(admiral, 6, own=0): no ship/role, salary or rank | — |
| 5 | 타함대선박 | 0xAD6D | pick an enemy unit on the map (0xBA55) → 0x1C02E: class picture, msg 886 `%s 함대`, "기함"/"N호선" (DS:0x8A4), armament + guns (msg 887/888), four bars HULL, RUDDER, SAILS, CREW | no other-side unit alive, present and inside the view (0xBC9F) |
| 6 | 작전일람 | 0xAEF7 | every own living unit: msg-free line `%2d: %s` (list index + 1, ship name) then "기함" (msg 1034) for the flagship, else 방침 (0xAE39: 이탈 1022 if flag 8, else 집결 1023 / 분산 1024 by flag 4; 공세 1025 / 수세 1026 by flag 1) and 방법 (0xAE79: 공격 1027 / 퇴각 1028 by flag 2, 포격 1029 / 돌격 1030 by flag 0x10, target "원군" 1031 or "적" 1032 + DS:0x8A4 name when flag 0x80, else 위임 1033) | the flagship is the only own unit alive |

**아이템** 0xB543 = the ordinary item menu 0x293F1 (§5), returns 0 (does not end the turn). It is greyed
only when the inventory is empty (0x12E5C is "list every item", not a usability test). There is **no
battle-specific item effect**: using an item in battle does exactly what it does at sea (the instruments
work because `[0xC3A]` = 0xFF); equipping/unequipping changes the weapon/armour used by the duel.

---------------------------------------------------------------------------------------------

## 5. Item menu: 장비 / 사용 (MENU 33) — 0x293F1 ✅

Reached from the sea/port 항해 command (MENU 46/29 item 4, 0x20964; greyed with no items), the
아이템 building's own menu, and battle. Loop: list (code 0xD) → detail window 0x28C9A(item) → popup MENU
33: 장비 → 0x28E75 (toggle, town.md §9.1; type ≥ 7 → msg 1090), 사용 → 0x2939A.

**Detail window**: ITEM.MES text (`0x7C` bytes per item at `item·0x7C`), name + type `%s（%s）` (type names
DS:0x8EA: 검, 스트레이트 소드, 커브 소드, 헤비 소드, 방패, 방어무기, 갑옷, 측량기, 항해용품, 소모품, 장신구,
보물, 지도, 국보급 보물), picture `0x55 + icon`, msg 1087 장비 if equipped, weapon grade msg 1088
공격력 MENU 34[`pow ≥ 35 ? 4 : (pow − 5)/6`], armour grade msg 1089 방어력 MENU 34[`pow > 40 ? 4 : (pow − 10)/10`].

**사용** 0x2939A by type (item +0x19 & 0xF):

| type | items | handler | effect |
|---|---|---|---|
| 7 측량기 | 20 사분의 (p = 5), 21 육분의 (p = 2), 22 경위의 (p = 1) (p = item +0x18) | 0x29244 | in port: msg 756, nothing. At sea: if the hero lacks 측량 (+0x30 & 0x10): msg 757, pick a companion (code 9, 0x291F1; one without 측량 → msg 755, pick again); cancel → the hero guesses (msg 758+760, or 759+761 when hero +0x31 & 0x10) with error `e = rand(100) + 1`, else e = 0. Prints `북/남위 e + (|640−y|·8 / (57p))·p 도, 동/서경 e + ((x+1981) mod 2160 / (6p))·p 도` (fleet position, msgs 126–129). Not consumed |
| 8 항해용품 | 23 회중시계 | 0x29030 | msg 1099 `%d시` = tick/3, msg 1100 `%d0분` = 2·(tick%3) when ≠ 0 |
| 8 | 24 망원경, 27 망원경, 28 공백 | 0x2907C | msg 1101 "먼 곳이 보인다." only |
| 8 | 25 고양이 | 0x29095 | msg 1102 "야옹∼" only |
| 8 | 29–40 licences | 0x28FCB | msg 1097 + 1098 "…[원작 문장 생략]." |
| 9 소모품 | 41 쥐약 | 0x290F2 | if `[0xC3F] & 0x10` (rat plague): clear it, msg 1103; else msg 1104 |
| 9 | 42 성스런 향유 | 0x2911E | if the weather event is a storm (`[0xC3F] & 0xF == 1`): end it, msg 1106 (day, ticks 12–59) / 1105 (night); else msg 1107. In both cases `[0x1032] = rand(6) + 10` |
| 9 | 43 라임 주스 | 0x2917B | if `[0xC3F] & 0x20` (scurvy): clear it, msg 1108; else msg 1109 "맛있다." |
| 9 | 45 성스런 향유 (2nd), 46 속죄상, 47 면죄부, 48, 49 | 0x28FCB | "cannot be used here" — **but still consumed** |
| 12 지도 | 80–89 | 0x29392 → 0x1D6EF | treasure map view below |
| others | weapons, armour, gifts, jewellery, relics | 0x28FCB | msg 1094/1095/1093+1094/1096/1097 + 1098 |

Every type-9 use removes the first inventory copy of the item (0x291D4), whatever happened.

**Passive item effects** (0x83EB, recomputed with the status panel): holding **24 망원경** sets
`[0xC158] |= 0x80`, which doubles the sighting range `[0xC176] = min(12, …/100) × (telescope ? 2 : 1)` used
by port/village sighting (0x3070D) and shown on the status panel (0x81D8); holding **25 고양이** sets `[0xC158] |= 0x40`, which
prevents the rat plague (0x18D55). (Item 27, the second 망원경, has no passive effect.) Holy oil's
`[0x1032]` is a day counter (−1 per day at 0x19124) during which no storm can start (0x1940A).

**Rat plague** (RE_NOTES calls it 전염병, 0x18D3C): with no cat, `[0xC3F] & 0x10` clear and more than 30 days
at sea, `rand(navLevel/5 + 2) == 0` and `rand(105) > luck` → msg 473 ("쥐 떼가 발생…"), bit 0x10 set;
what it does afterwards is in RE_NOTES (crew losses each day); entering a port also clears it (0x1B709).

**Treasure map** 0x1D6EF(item): site = item +0x18; `col = x/24` (−1 mod 90 if `x%24 < 12`),
`row = y/24` (−1 if `y%24 < 12` and row ≠ 0). Draws cells (col..col+1, row..row+1) like the chart zoom but
in mode 1 (0x228E1: **no fog**, explored or not), palette DS:0xAF50. Before drawing it builds four marker
chips from chip 65 with the diagonal masks DS:0xB014 (an X drawn in colour 2) 🔎 — the remaster can mark
the site with an X. No coordinates are given (that is 지도확인's job). In port the town is reloaded after.

---------------------------------------------------------------------------------------------

## 6. What the remaster lacks (Sources/Portolan/FleetInfoView.swift)

FleetInfoView has ship rows, person rows, per-ship cargo and rations. Missing relative to the original:
- 자함대정보: fleet screen with 함대선회력/추진력 (slowest ship), 선원 총수, 총포문수, 함대내구력, 전투력 (§1.1).
- 함선정보: 운항/파수/갑판 split, 운항요원, 적재율 %, 속도 KT, figurehead picture (§1.2).
- 인물정보: age, experience, nationality, skills, 작위 (hero), 급료 (companions); 운 is hidden in the original.
- 주인공정보: 금괴/금화, three fames, 공헌도 per nation (§1.4), title table by hero (§1.4).
- 적하일람 (totals + 경리주임 advice), 발견물정보 (+ pictures), 항해도 (fog chart), 항해일지 (needs the five
  log writers in §1.9 and a 48-entry ring), 항구지도 (assets now exported).
- 시세·물가, 지도확인, battle 정보 screens, item 사용 effects and the telescope/cat passives.

## 7. Corrections to other notes
- town.md §5: the Ottoman title table exists (DATA1 entry 17, used by hero 5).
- RE_NOTES "전염병 (0x18D3C)" is the rat plague (msg 473); cat prevents it, 쥐약 cures it.
- battle.md §15 q1: cargo +8 = 파수 %, +9 = 운항 % (labels from the ship screen); q3 answered in §4–5.
- RE_NOTES "PORTCHIP 뒤따르는 4바이트" = walkability thresholds (§1.10); town tiles look right only with
  the day palette DS:0xAD82.

## 8. Open questions
1. Exact drawing of the treasure-map X (which cell value 0x228E1 swaps for chips 124–127) and the
   difference between 0x228E1 and 0x22734 beyond fog. 🔎
2. List-menu page logic of the logbook (button hit-tests) was not traced line by line; the page rule
   above is from the counters.
3. Whether the remaster should reproduce the 시세·물가 specialty-price bug (§2).
4. The 항해도 cell picker 0x15768 (cursor size, keyboard steps) was read only from its arguments.
5. Sighting range input `…/100` in 0x8126..0x8160 (some per-ship maximum) not identified; only the
   telescope doubling is certain.
6. Which UI edits cargo +8/+9 (승무원비율, MENU 27[3]) and its limits — not traced here.
7. Message 882 "발견물이 없습니다." has no reader in the 정보 path (the item is greyed instead).
