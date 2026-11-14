# Other fleets on the world map (NPC fleets, encounters, monthly world)

Addresses are MAIN.EXE load-image offsets; `DS:n` = image `0x378B0+n`. Pseudocode uses
`rand(n)` = 0x4D86 (0 if n = 0), `min`/`max` = 0x4D42/0x4D49, integer division truncates.
Extractor: `build/venv/bin/python -I tools/extract_fleets.py [--nations] [--tables] [--graph]`.

> Tool caveat: `re.py dis`/`calls` print near-call targets without 16-bit wrap. In segment 0xFB8,
> `push cs; call X` with X ≥ 0x1F740 really goes to `X − 0x10000` (e.g. the "0x20C96" call at
> 0x1A223 is 0x10C96). Callers below were found with a wrap-aware search.

Status marks: ✅ read in full · 🔎 read, some details skipped · ❓ not decoded.

---------------------------------------------------------------------------------------------

## 1. Overview and timing ✅

| when | routine | what |
|---|---|---|
| every tick at sea | 0x1A9BD (from 0x1AC59) | all 70 fleets: in-port handler at tick 0; fleets inside the 72×72 local window move tile by tile |
| once per day per fleet | 0x1A5F8 (from day loop 0x1AC8F) | fleet *k* is processed when the tick counter passes *k* (tick = 72/day, fleets 0–69) |
| end of day | 0x190F9 | `[0xC39]=0` (24 if `[0xC3C]&0x80`), daily upkeep; then fleets `0..[0xC39]-1` (those the next day will skip) |
| end of month | 0x189DA | 0x1728C, 0x1730D, 0x173CC, **0x184C1** (nations + fleets), **0x189C9** (persons) |

Day loop 0x1AC8F (pseudocode):
```
t = [0xC39]                          ; start tick (24 on a new game, 0 normally)
while !quit:
    [0x571] = t ; if t >= 72: break
    if [0xC39] != 0 or t % 12 == 0: weather 0x199EC
    0x1ABA7()                        ; at sea: one tick (0x1A9BD + player move, [0x571]+=1)
                                     ; in port: a port action, [0x571] += its time
    for k in t .. [0x571]-1: if k < 70: [0xC6F0]=k; fleet_daily(fleet k)    ; 0x1A5F8
    if at sea: 0x6BA2 (draw fleets), 0x3070D
    t = [0x571]
daily 0x190F9; for k in 0..[0xC39]-1: if k<70: fleet_daily(fleet k)
```
So off-screen fleets act **once a day**, at sea fleet *k* sees `[0x571] = k+1`; in port `[0x571]`
jumps by the action time. `[0xC6F0]` = index of the fleet being processed (used by many helpers).

The **local window** is the 72×72-tile area kept decoded around the player:
`wx = 720·[0x706] + [0xC156]`, `wy = [0xC15A]` (also `wx = ((B%30)+30·[0x706])·24`,
`wy = (B/30)·24`, `B=[0x704]`). `on_local(p)` (0x22B30) = `0 ≤ p.x−wx < 72 && 0 ≤ p.y−wy < 72`.
Passability `blocked(x,y)` (0x30AA0) = any of the 2×2 tiles (x..x+1, y..y+1) in the 96-wide local
buffer `[0x430]` has chip ≥ 0x34.

---------------------------------------------------------------------------------------------

## 2. Data layouts

### 2.1 Fleet record — 70 × 133 B at DS:0x2DB2 (accessor 0x5B1C) ✅

Fleet index layout: **group g = index / 10 = nation record index** (0 Portugal, 1 Spain, 2 Turkey,
3 England, 4 Italy, 5 Netherlands, 6 pirates). Within a group, k = index % 10:
k 0 = hero (Joan 0, Catalina 10, Al 20, Otto 30, Pietro 40, Ernst 50; fleet 60 is a special
pirate-group fleet, inactive at start), k 1–4 = merchant fleets, k 5–6 = "galley" navy
squadrons, k 7–9 = "galleon" navy squadrons. Fleets 61–69 are pirates (same k roles for rebuild).
The player's fleet is `[0xC6DA] = fleet(person([0x1241]).+0x2C)`; `[0xC67A]` = player person.

| off | type | meaning |
|---|---|---|
| +0x00 | u16 | x (tile, 0..2159, wraps) |
| +0x02 | u16 | y (tile, 0..1079) |
| +0x04 | u16×2 | destination point (port coordinates, or a chased fleet's position) |
| +0x08 | u16×2 | local intermediate target (used while `+0xD & 0x80`) set by the window pathfinder 0x2343F |
| +0x0C | u8 | route state: bits 0–2 = current waypoint slot (0–3); bits 4–7 = slot-valid mask (slot 0 = 0x80, 1 = 0x40, 2 = 0x20, 3 = 0x10; table DS:0xB574) |
| +0x0D | u8 | route flags: 0x02 new segment (reset line error) · 0x08 last buffered waypoint is the goal node · 0x20 head straight for +4/+6 · 0x40 needs a new route · 0x80 use local target +8/+0xA. Bit 0x01 is set in the new-game data, no reader found ❓ |
| +0x0E | i16 | Bresenham error term for per-tick steering (0x30AF5) |
| +0x10 | u16×4 | waypoint node ids (route graph, §2.4) |
| +0x18/+0x19 | u8 | x/y movement accumulators (1/60 tile) |
| +0x1A | u8 | heading 0–7 (0 = north, clockwise) |
| +0x1B | u8 | **mission** (§4.3) |
| +0x1C | u8 | mission target: **port** for missions 0,1,2,9 · **person id** for 4–8,10 |
| +0x1D..+0x20 | u8×4 | treasure carried: item ids (50–69 = gifts/jewellery in the item table, §2.6), 0xFF none. Item +0x1D is the one handed to a player who defeats the fleet |
| +0x21 | u8 | cargo good id (0xFF none) |
| +0x22 | u16 | cargo quantity (≤ 1000) |
| +0x24 | u16 | funds, in units of 100 gold (spoils to the player = `(funds+1)×100`, 0x10260) |
| +0x26 | u8 | home port (fallback destination; = nation capital after a respawn) |
| +0x27 | u8 | days left in port (hero fleets 0; start data 1–9) |
| +0x28 | u8 | strength = `(Σ hull of active ships + 4) / 5` (0x17C7D) |
| +0x29 | u8 | state: 0x01 active (exists) · 0x10 in port (hidden, not encounterable) · 0x20 stopped (in port / reached dest) · 0x40 script-controlled (never auto-returns home, no sibling quota; only set by scenario scripts through the record accessor 0x3162E) |
| +0x2A | u8 | admiral person id (0xFF none) |
| +0x2B | 9 B×10 | ship slots: crew u16, hull, maxHull, rudder, sail, guns, ship record #, flags (`&0x30==0x10` in use, `&7` cannon type) |

`fleet_recompute` 0x17C7D: `f.28 = (Σhull+4)/5`; if Σhull == 0 → `f.29 &= ~1`.

### 2.2 Person fields used here (50 B at DS:0x1242, 120 persons) ✅/🔎
+0x1A u16 portrait (`|0xC000` for generated persons) · +0x1C..+0x23 eight abilities (+0x1D
seamanship is the escape roll) · +0x24 nav level · +0x25 battle level · +0x2C fleet (0xFF none,
0xFE story persons 69–78) · +0x2D port where the person waits (0xFF at sea) · +0x2E 1 = serving
as admiral · +0x2F: low 2 bits type (0/1 national, 2 pirate), 0x04 "grows" (gets monthly ship
upgrades, 0x186DF), 0x20/0x80 personality bits used as give-up / aggression modifiers (§4.3) ·
+0x31: low nibble nation (6 = pirate), 0x10 ❓ (excluded from admiral selection, tested in
tavern-girl scenes), 0x20 slot in use / available as admiral, 0x40 does not wander between
ports (heroes and some admirals), 0x80 unpaid.

### 2.3 Nation record — 7 × 32 B at DS:0x1106 (accessor 0x5AD2) ✅ (index 6 = pirates)

| off | meaning | new game |
|---|---|---|
| +0 | u16 power (recomputed monthly from ports, 0x17464) | 0 for all |
| +2 | enemy nation (0–6; 7 = the player's nation) | P→2, S→6, T→4, E→1, I→2, N→0, pir→1 |
| +3 | policy 0–8 (drives missions, §4.3) | 0,1,2,5,0,5,8 |
| +4 | target port for invest/trade missions | 17,3,61,52,27,59,— |
| +5..+8 | player-standing values (0x183DA) | 0 |
| +9 | aggressiveness | 60,70,80,90,50,85,100 |
| +0xA | capital port | 0,1,2,29,8,33,4 (Algiers) |
| +0xB..+0x11 | relation toward nation 0–6 (100 = self) | symmetric matrix, e.g. P: 100,85,30,50,70,50,40 |
| +0x12..+0x18 | war-state per nation: low nibble state (1 friendly, 4 war, …), high nibble flags 0x10/0x20 | 🔎 |
| +0x19..+0x1F | last port taken by nation n | 0xFF |

### 2.4 Route graph — DATA1.LZW[4] (12288 B) + count DATA1.LZW[5] (u16 = 622) ✅
Loaded into far handle `[0xC1E]` (0x15F79). 16-byte nodes:
`x u16 (bit15 = node lies in a block the player has charted, rebuilt from bitmap DS:0xFD2/0xD74),
y u16, next[4] u16 (0xFFFF none), cost[4] u8`. 1430 directed edges, all two-way inside 0..621;
median edge 25 tiles (Chebyshev), cost ≈ 4.2 × Euclidean length capped at 255. The nearest-node
scan runs over indices **0..622 inclusive** (off by one: node 622 = (799,621) with a one-way
link to 214; node 623 is unused).

### 2.5 Other tables (MAIN.EXE data) ✅
- DS:0xBB80 heading from (sx,sy) ∈ {-1,0,1}²: rows sy=-1,0,1: `7 0 1 / 6 8 2 / 5 4 3` (8 = stay).
- DS:0xBC42 u16×9 mission nibbles by policy (§4.3); DS:0xBC54 far ptrs: in-port handlers by mission.
- DS:0xAC98 / 0xACC2 / 0xACEC: monthly rebuild class tables (7 nations × 3 tiers × 3 classes) for
  merchants / galleys / galleons; DS:0xAD16 rival upgrade classes; DS:0xAC50 region weights
  `4,3,3,2,3,1,1,1`; DS:0xAC58 far ptrs to target-port predicates. `--tables` prints them decoded.

### 2.6 The three "unknown" record types
- **0x5BD2: item table, 26 B at DS:0x8144** ✅ — name[21] (단도, 숏 소드, … 50–69 비단 숄 …
  루비 반지), +0x15 icon/kind, +0x16 u16 price, +0x18 value, +0x19 category (9 empty, 0x0A
  clothes/accessory, 0x0B jewel, 0x0D …). Fleet treasure (+0x1D) and battle spoils index it.
- **0x5B0C: tavern girls, 30 × 17 B at DS:0x2B56** 🔎 — name[11] (카를로타, 루치아, …),
  +0xB (0x10–0x26, likely mood/portrait), +0xC port, +0xD 0, +0xE request/item (0xFF none),
  +0xF day counter (daily 0x190D1: `if v != 0xFF && v != 0: v--`), +0x10 flags (0x08 present,
  0x40, 0x01, low bits hero mask). Portrait = 0x61 + index; messages 307/308.
- **0x5AFC: special characters, 20 × 21 B at DS:0x29B2** 🔎 — name[16], +0x10 group (0 Joan's
  story cast, 1 Catalina's, 2/3 scholars, 0xFF rulers), +0x11 portrait, +0x13 flags (0x10 =
  current patron), +0x14 residence port. Records 10–17 are the rulers met in a palace:
  `record 10 + port nation` (0x2A43B): 마누엘1세, 카를로스1세, 슐레이만 대제, 헨리8세, 페토루스
  총독, 네이블 총독, 파우라, 사파. 18/19 = 줄리아노 교수 (Napoli), 월프 박사 (Hamburg).

---------------------------------------------------------------------------------------------

## 3. New-game fleets (DATA1[15]) ✅

All NPC fleets: mission 0, `+0xC = 0x4100` (fleets 1–58) or `0x4000` (59–69) = needs route,
state 0x01, +0x1C = +0x26 = home port,
`+0x27 = k` (1–9), strength 0 (recomputed when first damaged/rebuilt), treasure 0xFF, cargo none.
Quirk: the destination +4/+6 of fleet *i* is the coordinates of **port i mod 42**, not of
+0x1C; on the first arrival 0x19B48 then relocates the fleet into its home port +0x1C.
Hero fleets 10–50 are inactive with no ships; fleet 60 is inactive with 10 ships.

| # | role | x,y | dest | home | admiral | funds | ships (crew total; guns; cannon types) |
|---|---|---|---|---|---|---|---|
| 0 | player | 118,358 | – | Lisbon | 0 조안 페레로 | – | none (state 0) |
| 1 | merch | 2006,353 | 142,372 | Lisbon | 6 시몬 세게이라 | 55 | Nao 4, Brigantine 1, Carrack 2 (565; 15–30; 4–6) |
| 2 | merch | 951,668 | 352,344 | Lisbon | 7 루이 코스타 | 50 | Nao 4, Brig 2, Carrack 1 (510) |
| 3 | merch | 650,572 | 194,342 | Lisbon | 8 로렌소 핀트 | 45 | Nao 4, Brig 1, Carrack 1 (465) |
| 4 | merch | 487,592 | 200,376 | Lisbon | 9 로포 페레이라 | 50 | Nao 3, Brig 1, Carrack 2 (485) |
| 5 | galley | 109,351 | 242,372 | Lisbon | 10 라파엘 셀란 | 40 | Flanders Galley 5, Light Galley 2 (960; 10–30; 2–4) |
| 6 | galley | 148,299 | 178,356 | Lisbon | 11 디에고 소사 | 45 | Flanders 4, Light 2 (780) |
| 7 | galleon | 196,190 | 212,326 | Lisbon | 12 알퐁소 안드레드 | 50 | Galleon 5, Carrack 2 (1100; 30–70; 2–4) |
| 8 | galleon | 308,873 | 230,320 | Lisbon | 13 가르시아 알바레스 | 55 | Galleon 4, Carrack 2 (920) |
| 9 | galleon | 1885,1022 | 240,328 | Lisbon | 14 곤사로 실베이라 | 60 | Galleon 5, Carrack 1 (1000) |
| 10 | hero | 142,374 | 260,348 | Seville | 1 카탈리나 | 0 | none, inactive |
| 11–14 | merch | 159,640 · 280,871 · 578,479 · 2008,317 | ports 11–14 | Seville | 15–18 | 35,45,50,55 | as 1–4 |
| 15–16 | galley | 187,354 · 192,347 | ports 15–16 | Seville | 19, 20 | 45, 35 | as 5–6 |
| 17–19 | galleon | 1980,909 · 952,687 · 467,626 | ports 17–19 | Seville | 21–23 | 45,55,40 | as 7–9 |
| 20 | hero | 352,342 | 392,402 | Istanbul | 5 알 베자스 | 0 | none, inactive |
| 21–24 | merch | 438,697 · 97,592 · 4,174 · 259,829 | ports 21–24 | Istanbul | 24–27 | 45,55,45,50 | Nao 4–6 + Carrack 1–2 (500–600; 30) |
| 25–26 | galley | 364,327 · 396,326 | ports 25–26 | Istanbul | 28, 29 | 45, 35 | Flanders 4–5 + Venetian Galley 2 (1540/1360; 30–50) |
| 27–29 | galleon | 884,690 · 57,539 · 251,396 | ports 27–29 | Istanbul | 30–32 | 60,55,45 | Xebec 4–5 + Carrack 1–2 (680–800; 30) |
| 30 | hero | 180,264 | 160,264 | London | 2 옷토 | 0 | none, inactive |
| 31–34 | merch | 2011,859 · 248,221 · 243,202 · 322,355 | ports 31–34 | London | 33–36 | 55,45,35,45 | Nao 3–4, Carrack 1–2, Caravela Redonda 1–2 (450–550) |
| 35–36 | galley | 193,262 · 174,275 | ports 35–36 | London | 37, 38 | 40, 35 | Carrack 4–5, Galleon 2 (860/760) |
| 37–39 | galleon | 361,853 · 610,532 · 670,542 | ports 37–39 | London | 39–41 | 45,50,60 | Galleon 4–5, Carrack 1–2 (920–1100) |
| 40 | hero | 230,322 | 322,218 | Genoa | 4 피에트로 | 0 | none, inactive |
| 41–44 | merch | 608,508 · 2068,808 · 443,715 · 239,756 | ports 41,0,1,2 | Genoa | 42–45 | 50,35,40,35 | Buss 4–6, Tarette 1–2 (630–915) |
| 45–46 | galley | 256,357 · 240,339 | ports 3,4 | Genoa | 46, 47 | 40, 45 | Flanders 4–5, Venetian 2 (1540/1360) |
| 47–49 | galleon | 283,410 · 60,497 · 89,89 | ports 5–7 | Genoa | 48–50 (49 안드레아 도리아) | 30,40,30 | Buss 3–4, Carrack 1–2, Nao 1–2 (710–880) |
| 50 | hero | 218,248 | 230,320 | Amsterdam | 3 에르네스트 | 0 | none, inactive |
| 51–54 | merch | 617,555 · 692,514 · 2109,745 · 845,692 | ports 9–12 | Amsterdam | 51–54 | 30,40,30,45 | Nao 3–4, Carrack 1–2, Caravela Latina 1–2 |
| 55–56 | galley | 220,237 · 205,247 | ports 13,14 | Amsterdam | 55, 56 | 50, 60 | Carrack 4–5, Galleon 2 |
| 57–59 | galleon | 277,336 · 323,400 · 65,447 | ports 15–17 | Amsterdam | 57–59 | 50,45,25 | Galleon 4–5, Carrack 1–2 |
| 60 | special | 1985,434 | 358,416 | Caracas | 60 안토니오 칸 | 35 | Carrack 4, Galleon 5, Nao 1 — **inactive** |
| 61 | pirate | 1985,434 | 358,416 | Caracas | 114 프란차 로로노아 | 35 | Carrack 4, Galleon 2, Nao 1 (840) |
| 62 | pirate | 1909,529 | 390,410 | Cartagena | 61 피에르 루글란 | 40 | Carrack 4, Galleon 1, Nao 2 |
| 63 | pirate | 717,487 | 392,402 | Havana | 62 루이스 스콧트 | 50 | Carrack 3, Galleon 2, Nao 1 |
| 64 | pirate | 626,572 | 378,386 | Margarita | 63 존 데이비스 | 45 | Carrack 4, Galleon 1, Nao 1 |
| 65 | pirate | 381,412 | 258,406 | Algiers | 64 하이레딘 레이스 | 35 | Venetian Galley 5, Flanders 2 (1960) |
| 66 | pirate | 351,413 | 386,316 | Algiers | 65 아이딘 레이스 | 45 | Venetian 5, Flanders 1 (1780) |
| 67 | pirate | 772,674 | 410,302 | Tunis | 66 마호메드 샤룩 | 30 | Galleon 5, Nao 2 (1060) |
| 68 | pirate | 2042,670 | 418,344 | Tunis | 67 울구 아리 | 40 | Galleon 5, Nao 1 |
| 69 | pirate | 1961,578 | 144,384 | Tunis | 68 잭 라캄 | 45 | Galleon 4, Nao 2 |

Ship slots hold full crew and hull of the class default record (ship record 40+class).
Full per-slot data: `tools/extract_fleets.py`.

---------------------------------------------------------------------------------------------

## 4. Daily fleet update

### 4.1 fleet_daily 0x1A5F8 ✅
```
fleet_daily(f):
    if !(f.29 & 1): return
    if at_sea and on_local(f): f.0D |= 0x80; return       ; per-tick code drives visible fleets
    if f == player fleet: return
    refresh_chase(f)            ; 0x1A0B3
    choose_mission(f)           ; 0x19E80
    p = encounter_daily(f)      ; 0x1A454
    if p != 0xFF:
        if !on_local(fleet(person(p).2C)): npc_fight(f, p)   ; 0x1A183
        return
    if f.29 & 0x10:                         ; in port
        port_handler(f)                     ; 0x33818
        if f.29 & 0x10: return
    if route_update(f):                     ; 0x23B68
        pt = route_target(f)                ; 0x19AA5
        hop(f, pt)                          ; 0x19BBB
```

### 4.2 Route following ✅
`nearest_node(p)` 0x22B79: minimum squared distance with x wrap (|dx| > 1080 → ±2160), scanning
node 622 down to 0, strict `<` (ties keep the higher index). Returns `idx | 0x8000` when the
distance is 0.

`pathfind(f)` 0x22C58 (returns 1):
```
S = nearest(f.xy); G = nearest(f.dest)
if exact(S) and S == G: f.0D |= 0x28; return
BFS from G (FIFO queue of {mask, node, cost}); order[] = -1; queue[0] = {0, G, 0}
while queue not exhausted and front.node != S and !found:
    e = pop front
    for k in 0..3 (bit = 8>>k):
        if e.mask & bit or e.node.next[k] == none: continue
        nb = e.node.next[k]; c = e.node.cost[k] + e.cost
        (player fleet only: skip nb unless nodes[nb].x & 0x8000)
        e.mask |= bit; back = 8>>j where nodes[nb].next[j] == e.node
        if order[nb] < 0: append {back, nb, c}; if nb == S: found
        else: q = queue[order[nb]]; q.mask |= back; q.cost = min(q.cost, c)   ; no re-propagation
path = exact(S) ? [] : [S]; cur = S
while cur != G and len(path) < 4:
    e = queue[order[cur]]
    take the first k with (e.mask & 8>>k) and cost[k] + queue[order[next[k]]].cost == e.cost
    cur = next[k]; path.append(cur)            ; (no k found → reads next[4], original bug)
slot = f.0C & 7; while f.0C & mask[slot]: slot = (slot+1) & 3
for n in path:
    if (f.0C & 0xF0) == 0xF0: break
    f.0C |= mask[slot]; f.10[slot] = n
    if n == G: f.0D |= 8; break
    slot = (slot+1) & 3
f.0D &= ~0x40
```
So a fleet buffers at most 4 nodes and re-plans from its current node when the buffer empties.

`route_update(f)` 0x23B68:
```
i = f.0C & 7
if f.xy == node(f.10[i]).xy:
    f.0C &= ~mask[i]; f.0C = (f.0C & ~7) | ((i+1)&3); f.0D |= 2
    if (f.0C & 0xF0) == 0: f.0D |= 0x40
if on_local(f): return local_steer(f)        ; 0x23A4D, window BFS 0x2343F ❓ details
f.0D &= ~0x80
if !(f.0D & 0x40): return 1
if f.0D & 8: f.0D |= 0x20; return 1          ; last node reached → go straight to dest
return pathfind(f)
```
`route_target(f)` 0x19AA5: if `0x40` and `f.xy == dest` and `route_update` = 0 →
(unless script fleet) `send_to_port(f, 0, f.26)` and stay; else `+8/+0xA` if 0x80, `dest` if 0x20,
else the current waypoint node.

`hop(f, pt)` 0x19BBB (off-screen movement):
```
if !on_local(pt): f.xy = pt (mod 2160 / 1080)          ; jump: one waypoint per day
elif f is outside the window: place f where the line f→pt enters the window
     (interpolated edge point; if blocked, scan along the edge for a free tile); else no move
if f.xy == f.dest:
    if f.1B == 4: if rand(10) == 0: send_to_port(f, 0, f.26)
    elif f.1B in 5..8 or 10: f.dest = fleet(person(f.1C).2C).xy
                             f.0C = on_local(f) ? 0x6000 : 0x4000 ; f.29 &= ~0x30
    else: arrive(f)                                      ; 0x19B48
if on_local(f): route_update(f)
```
`arrive(f)` 0x19B48: `f.29 |= 0x30`; by mission: 0,1,2,9 → `f.xy = port(f.1C).xy`; 3 → clear 0x10
(waits at sea); 4 → nothing; 5–8,10 → `f.xy = fleet(person(f.1C).2C).xy`. Then
`f.27 = rand(8) + 8` and `port_handler(f)`.

Effective off-screen speed: one route node (median 25 tiles) per day, independent of ships/wind.
While the player is **in port** every fleet goes through `fleet_daily` (no `on_local` early exit)
and the per-tick mover does not run, so fleets inside the (last) local window whose next point is
also inside it stand still until the player sails out.

### 4.3 Missions ✅

| +0x1B | meaning | target +0x1C | hail reply |
|---|---|---|---|
| 0 | return home / go to port | port | 152 "본국으로 돌아가는 길" |
| 1 | invest in a port | port | 153 |
| 2 | trade with a port | port | 154 |
| 3 | lie in wait (script) | – | 155 → battle |
| 4 | pirate prowl (go to where the player was) | player person | 156 → battle |
| 5, 6 | hunt the fleet of a person (5 galley type, 6 galleon type) | person | 157 (161 + battle if the target is the player) |
| 7 | relentless hunt (never goes home after a fight) | person | as 5 |
| 8 | escort an own merchant fleet | person | 158 |
| 9 | guard home port vs pirates (in-port handler is a no-op) | port | 159 |
| 10 | follow / business with a person (script) | person | 160 |
| 0xFF | (hail with no mission) | – | 216 "나는 %s의 %s" |

`send_to_port(f, m, port)` 0x330CF (m = 0xFF keeps the mission):
```
if m == 0: f.dest = port.xy
if !(f.29 & 0x40) and sibling_quota() and m != 0: f.1B=0; f.1C=f.26; f.27=5; return
if f.29 & 0x10 and on_local(f):          ; leaving a visible port
    put f on the first free tile of 12 offsets around it (0x23721); none → as quota case
if m != 0xFF: f.1B = m
f.1C = port; f.dest = port.xy; f.0C = 0x4000; f.29 &= ~0x30
```
`send_after_fleet(f, m, idx)` 0x33197: same quota/port-exit checks; if `fleet(idx)` inactive →
`send_to_port(f,0,f.26)`; else `f.1C = fleet(idx).2A; f.dest = fleet(idx).xy; f.0C = 0x4000;
f.29 &= ~0x30`.

`sibling_quota()` 0x32FFC (uses `[0xC6F0]`, k = idx%10): k 1–4 → 1 if **≥ 2** of the four merchant
fleets of the group are not in port; k 5–6 or 0 → 1 if any of fleets 5–6 is not in port; k 7–9 → 1
if any of 7–9 is not in port. (Net effect: per nation at most 2 merchant, 1 galley and 1 galleon
fleet are out on a non-home mission.)

**In port** `port_handler(f)` 0x33818: `[0xC164] = [0xC6F0]/10`; missions 0,1,2 call
DS:0xBC54[m] (9 → no-op, 3–8 not called). All start with `if f.27: f.27--; if f.27 != 0: return`.
- Mission 0, 0x3345D: if cargo: for each of the 10 price indices of `market(f.1C)`:
  `idx -= min(idx, rand(3) + (class(cargo)==i ? 2 : 0))` (selling). Repair all ships
  (hull = maxHull). Treasure: `for s in 0..3: if rand(2(s+1)) != 0 break; if t[s]==0xFF:
  t[s] = rand(20)+50`. Recompute strength. `funds = rand(3) + power/10 + 1`; cargo cleared.
  `f.1B = next_mission()`; `depart()`.
- Mission 1 (invest), 0x33568: skip if funds < 2 or port is the capital. Invest `(funds/2)×100`
  into whichever of economy/industry is lower (`m.2`/`m.6`, cap 50000; if one is capped use the
  other); `funds -= funds/2`; `inc = min(100 − support[nat], 6·funds/10)`; `support[nat] += inc`;
  take `min(inc, Σ others)` back one point at a time round-robin from the other nations' support.
  Then mission 0 home.
- Mission 2 (trade), 0x336E4: unless at the capital: good `r = rand(16)+10`,
  `price = zone(m.21).buy[r] × (m.idx[class(r)]+50) / 100`; if `100·funds ≥ price`:
  `n = min(1000, 100·funds/price)`, `idx[class] += min(100−idx, rand(3)+3)`,
  `funds −= n·price/100`, cargo = (r, n). Then mission 0 home.

`next_mission()` 0x333D6: 0 unless `f.1C == capital`; else nibble of DS:0xBC42[policy]:
merchants (k 1–4) `>>8`, k 5–6 `>>4`, k 0,7–9 `>>0`:

| policy | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| merchants | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 6 | 6 |
| galleys | 9 | 9 | 9 | 6 | 5 | 5 | 5 | 9 | 4 |
| galleons | 8 | 8 | 8 | 6 | 6 | 6 | 6 | 6 | 6 |

`depart()` 0x332B9 (`zone` = nation.2, or the player's nation if it is 7):
mission 0,9 → home; 1,2 → `nation.4`; 3,7 → stay; 4 → after the player's fleet (mission kept);
5,6 by policy: 3,7 → after the player's fleet; 4,8 → fleet `10·zone + (peerage>2 ? rand(5) :
rand(4)+1)`; 5 → `10·zone + 5 + rand(2)`; 6 → pirate fleet `61 + rand(9)`; 8 → own merchant
`10·nat + 1 + rand(4)`.

**Mission changes at sea** `choose_mission(f)` 0x19E80 (skipped for script fleets), only for
pirates (idx > 60) and navies (k ≥ 5); `adm = person(f.2A)`:
- missions 4–6, k ≤ 6: if the hunted fleet has `+0x27 != 0` → home; else with chance
  `1/(adm.2F&0x20 ? 30 : 15)` → home. k ≥ 7: same with `1/(… ? 60 : 30)`.
- missions 8–9, only when `[0x571] % 12 == 0` (at sea that means fleets 11, 23, 35, 47, 59):
  for every active fleet i ≠ f with mission 5–7 whose victim belongs to f's group: with
  chance `1/(adm.2F&0x80 ? 2 : 1)` → `send_after_fleet(f, k>6 ? 6 : 5, i)` (each match retargets).
- then (all of the above fall through to here) pirates (idx > 60) with mission 4 that are on the
  local window: with chance `1/(adm.2F&0x80 ? 3 : 2)` pick a random victim among active fleets
  0–59 that are merchants (k 1–4) or the player's fleet — the player only if his peerage > 0 —
  and `send_after_fleet(f, 5, victim)`.

`refresh_chase(f)` 0x1A0B3 (missions 5–8,10): if the target person is not 0x20-active or has no
fleet → home; else if `on_local(f)` or `rand(4)==0`: `dest = target fleet xy`,
`f.0C = on_local(f) ? 0x6000 : 0x4000`.

---------------------------------------------------------------------------------------------

## 5. Per-tick movement of visible fleets — 0x1A9BD ✅

Called every tick at sea (wind = `[0xC3D]` bits 3–5 dir / 0–2 strength, current = `[0xC3E]`):
```
for each fleet f (index → [0xC6F0]):
    if f == player or !(f.29&1): continue
    if f.29 & 0x10:                                  ; any fleet in port, visible or not
        if [0x571] == 0: port_handler(f)             ; (so at sea in-port timers run twice a day)
        if still in port: continue
    if blocked(f.xy): continue
    if !on_local(f): f.0D &= ~0x80; continue
    p = encounter_local(f); if p != 0xFF: npc_fight(f, p); continue      ; 0x1A565
    if f.xy == f.dest and f.1B != 4: (same arrival/chase update as hop())
    d = steer(f)                                     ; 0x30AF5
    if d == 8: f.29 |= 0x20; continue
    f.1A = d; s = npc_speed(f, wind, current)        ; 0x1A69E
    if move(f,d,s) and move(f,(d+1)&7,s) and move(f,(d−1)&7,s): local_repath(f)  ; 0x23C0E→0x2343F
```
`steer(f)` 0x30AF5: 8 if at dest; route_update (−1 if it fails); target = +8/+0xA, dest, or the
waypoint node; Bresenham on `adx=|fx−tx|, ady=|fy−ty|` with error `f.0E` (reset to `−adx/2` when
`f.0D&2`): major axis always steps, minor axis steps when the error crosses 0; heading from
DS:0xBB80.

`npc_speed` 0x1A69E (= the info-screen speed; no crew/load terms): per active ship
`a = sail[|wdir−heading|][class.sailType] × ship.sail × wstr / 150` (DS:0x714),
`s = min(40, min(30, a + a·navLv/10) × seamanship/75)`, `×rudder/100` if the wind angle is 3–5;
fleet `s = max(2, min_i s)`; current: angle 0,1,7 → `s += min(40−s, cstr)`, 3–5 →
`s −= min(s−1, cstr)`; 0 if `wstr == 0` and every ship is sail-only (`rec.13 & 0x10`).

`move(f,d,s)` 0x1A834: accumulators `acc += vec[d]·s` (no separate current term), a step when ≥ 60
(±60 kept), x within the third (`x % 720`). Leaving the window → step without a land test.
Target 2×2 blocked: if the single step `(x,y)+vec[d]` is free, keep the accumulators (clamped to
59/0 on the stepped axes) and return 0; else return 1 (blocked). Wrap x mod 2160, y mod 1080.

---------------------------------------------------------------------------------------------

## 6. Encounters

### 6.1 Detection ✅
- `encounter_local(f)` 0x1A565 (per tick, visible fleets, missions 4–7 only):
  mission 4 → if `f.xy == player.xy`: `f.1B = 5`, return the player's admiral.
  missions 5–7 → hunted fleet inactive → home; hunted fleet in port/script (`&0x50`) → none;
  **same tile** → return `f.1C`.
- `encounter_daily(f)` 0x1A454 (off-screen, missions 4–7): "same block" = `x/24 + 90·(y/24)`.
  Mission 4: first fleet 0–59 that is active, not `&0x50`, in the same block and **weaker**
  (`g.28 < f.28`) → `f.1B = 5`, return `g.2A` (the `i%10 in 1..4` test is written as `||`
  and always passes). Missions 5–7: as above with "same block" instead of "same tile".

### 6.2 NPC fight resolution `npc_fight(f, p)` 0x1A183 ✅
```
if tick < 18 or tick >= 54: return               ; only 6:00–17:59
T = fleet(person(p).2C); atk = f.28/10; def = T.28/10   (before any damage)
if on_local(f):
    if p == player hero:
        if !(f.29&0x40) and peerage(player) == 0: send_to_port(f,0,f.26); return
        encounter(f.2A, p)                        ; 0x10C96 → battle, see 6.4
        if f destroyed or f.29&0x40 or f.1B==7: return
        if rand(3) == 0: send_to_port(f,0,f.26)
        return
else:
    if p == player hero: return                   ; off-screen fleets never fight the player
    if rand(150) < person(p).1D:                  ; victim's seamanship → escape
        if f.1B != 7: send_to_port(f,0,f.26)
        return
; automatic battle
if f.1B != 7: send_to_port(f,0,f.26)
if T.29 & 0x40 or !(T.29&1) or T.29 & 0x10: return
pool = atk; for slot 9..0 of T (used):              ; damage from the last ship forward
    if hull <= pool: pool −= hull; sink it;
        q = T.22/5; T.22 −= q; f.22 += min(1000−f.22, q); f.21 = T.21
        q = T.24/5; T.24 −= q; f.24 += min(60000−f.24, q)
    else: hull −= pool; break
recompute(T); if T dead: fleet_destroyed(T); send_to_port(f,0,f.26)
pool = def; same on f's ships (no loot); recompute(f); if f dead: fleet_destroyed(f)
; relations ([0xC164] = nation of the last fleet that ran port_handler — probably meant
;  "attacker's nation"; stale-global quirk):
A = [0xC164]; B = person(p).2C / 10
if A < 6: nat[A].rel[B] −= min(rel, rand(2)+2)
if B < 6: nat[B].rel[A] = (A < 6) ? nat[A].rel[B] : nat[B].rel[A] − min(…, rand(2)+2)
```
`fleet_destroyed(T)` 0x1A135: `T.29 &= ~1`; admiral: `.2E=0, .2C=0xFF`; if portrait high bits
(`+0x1B & 0xC0`) are clear and `rand(10) != 0` → `.2D = rand(42)` (moves to a tavern of ports
0–41) else `.2D = 0xFF, .31 &= ~0x20` (removed); `T.2A = 0xFF`.

### 6.3 Player-initiated ✅
- Candidate list 0x12CF9(r=2): active fleets not in port, not the player's own, with
  **|dx| ≤ 2 and |dy| ≤ 2** from the player (0x12CAB, no x wrap); ids into DS:0x574.
- **Attack** (0x20464 → 0x10D39): only ticks 15–59, else msg 781 "[원작 문장 생략]
  없습니다." None → 778. Pick from a menu, show the admiral (0xC215), confirm. If the target's
  group equals the player's nation (and the player is not pirate) → msg 782 yes/no. Then
  `encounter(player, target)`.
- **Hail/negotiate** (0x20403 → 0x1FABD, menu 0x8C; none → 225): reply by mission (table in §4.3,
  table at 0x1FB75); missions 3, 4 and "hunting the player" (5–7 with target = player) answer and
  then `encounter(npc, player)`.

### 6.4 Entering a battle ✅
`encounter(a, d)` 0x10C96 (al = attacker person, dl = defender person):
`[0xD6C] = [0xCE2] =` the non-player side; `reinforce(a, d, &aAlly, &dAlly)` 0x10B78; then
**`battle 0xF9E8(al = attacker, dl = defender, bl = attacker ally, stack = defender ally)`**
(allies 0xFF when none); result code in `[0xA509]`; aftermath 0x108EE.
`reinforce`: none if the player's nation is 6; for each other admiral within distance 2 whose
fleet is a navy/pirate squadron (`fleet%10 ≥ 5`): if the defender slot is free and its group =
defender's group → defender ally (msg 779); else if the attacker slot is free and group =
attacker's group → attacker ally (msg 780).
Spoils on victory (0x10242, f = the opposing fleet of the battle side table DS:0xA0EE):
`(f.24+1)×100` gold, plus item `f.1D` if it is not 0xFF, the item count 0x12E5C() < 20 and the
side record's `+0xD & 0x80` is clear (msgs 560–562). Defeat lines 830–836.

---------------------------------------------------------------------------------------------

## 7. Monthly world routines

Order in 0x189DA: 0x1728C seasons, 0x1730D bank, 0x173CC markets, **0x184C1**, **0x189C9**,
`[0xC38] = 0`.

### 7.1 0x184C1 = 0x17464, 0x179A0, 0x17BD1, 0x184AC
**Power 0x17464** ✅: for ports 0–99, n = `port.13 & 7`, r = `market.1C` (region 0–7):
`IND[n][r] += market.industry`, `ECO[n][r] += market.economy × (port.13&8 ? 2 : 1)`. For n 0–5:
```
p = ECO[n][0] / w[0]                                ; w = DS:0xAC50 = 4,3,3,2,3,1,1,1
for r in 4..7: if IND[n][r] >= 300: p += ECO[n][r]/w[r] else break
for r in 1..2: if IND[n][r] >= 300: p += ECO[n][r]/w[r]
if (IND[n][2] >= 300 or IND[n][4] >= 300) and IND[n][3] >= 300: p += ECO[n][3]/w[3]
nat[n].power = p
nat[6].power = Σ / 6
```
**Diplomacy 0x179A0** = 0x175FD, 0x17766, 0x178BF ✅/🔎:
- enemy (0x175FD): nation n picks the other nation m (0–6) minimising `rel[n][m] × power[m] / 100`;
  if `rand(180 − nat.9) + 100 < |200 − standing|` (standing = player's family byte +6+n) the enemy
  is 7 (the player). Pirates pick n maximising `(100 − rel) × power`, player if
  `rand(50)+100 < |200 − family+0xC|`.
- policy (0x17766): `r = rand(power[enemy] >= power ? 120 : 90)`; if `nat.9 > r` → 0x1771E:
  `policy = power[enemy] > power ? 4 : 5` (the code first writes 3 for enemy 7 and 6 for enemy 6,
  then always overwrites); else `policy = rand(3)`. Pirates: `policy = enemy==7 ? 7 : 8`.
- target port (0x178BF): scans ports 0–99 with a predicate chosen by policy (DS:0xAC58:
  unowned port / own non-capital / ports 75–92 / player-nation non-capital / enemy non-capital),
  each match taken with 1/5 chance; falls back to another predicate if none matches → `nat.4`.
**Relations/war 0x17BD1** 🔎: for each pair: 0x179AD sets the war-state nibble from the power
ratio, relation and flags via table DS:0xAC74 (results 7–10 are randomised); 0x17B46: state 1 →
`rel[b][a] += rand(5)+3` (copied to `rel[a][b]`, no cap); state 4 (war) →
`chance = power[b] ? min(50, 10·power[a]/power[b]) : 50`, if `rand(50) < chance` nation a takes the
highest-numbered non-capital port of b (0x17AB4: `port.13` nation := a,
`support[a] = rand(10)+80`, `nat[b].19+a = port`).
**Fleets 0x184AC** ✅ = rebuild 0x17CC3, 0x17DB7, 0x17EAC, relaunch 0x18362, standing 0x183DA.
- Rebuild, for each group n 0–6, tier `q = min(power/500, 2)`; a new ship = class from the table,
  hull = maxHull = class hull, rudder/sail = class, guns = `rec.14`, crew = `rec.15`,
  cannon type `4 + rand(3) − 3·heavy` (0x17C1C). **Only inactive fleets are refilled** (an active
  fleet stops after looking at slot 0):
  merchants 10n+1..4 share `power/50 + 5` ships, light guns, classes DS:0xAC98;
  galleys 10n+5..6 share `power/75 + 5`, heavy guns, DS:0xACC2;
  galleons 10n+7..9 get all 10 slots, heavy guns, DS:0xACEC.
- Relaunch 0x18362: for every non-hero fleet (idx%10 ≠ 0) that is inactive and has
  `≥ rand(2)+4` ships → 0x18208: idx < 60: 50 % first idle person 6–119 of that nation with
  `.31&0x20`, `!(.31&0x10)`, no fleet; 50 % generate a new person (0x17F8B, type rand(2)) in the
  first free slot. Pirates: 50 % first idle person with `(.2F&3) ≥ 2`; 50 % generate one with a
  random nationality, type 2. Then 0x18156: person `.2C=idx, .2D=0xFF, .2E=1`; fleet at the
  **capital** of group n (pirates → Algiers), `send_to_port(f,0,capital)`, funds
  `rand(3)+power/10+1`, cargo/treasure cleared, `home = capital`, `f.27 = rand(10)+5`,
  `f.29 = 0x31` (active, in port).
- Generated person 0x17F8B: random first/last name from NAME.TBL (16 per nationality, unique),
  `+0x2A = rand(16)+20`, abilities `rand(35)+60`, nav/battle level
  `min(100, max(rand(5)+8, old+rand(4)+2))`, exps 0, `+0x2F = rand(16)<<4 | type`,
  `+0x30 = rand(16)`, `+0x31 = nation | 0x20`, portrait `rand(0x3FFF) | 0xC000`.
- Standing 0x183DA: for nation n: if the player's family byte `+6+n ≥ 130`:
  `v = peerage × power`, `nat.5 += v/3000`, `nat.6 += v/1000` (cap 100), `nat.7 = min(7, v/4000)`,
  `nat.8 += min(10, v/4000)`; if `< 70`: `nat.5 = nat.6 = nat.8 = 0, nat.7 = 0xFF`.

### 7.2 0x189C9 = 0x184D2, 0x1863C, 0x186DF, 0x18864 ✅
- **0x184D2 persons**: for persons 6–119: in use, not story-bound, no fleet, waiting in a port →
  with 1/3: `port = clamp(port + rand(5) − 2, 0, 96)` (tavern hopping by index). Free slot →
  with 1/3 generate a person (nationality rand(6), type rand(3)) waiting in port `rand(42)`.
- **0x1863C rival levels**: for heroes 0–5 except the player, then "60" (the loop reads person 6's
  record but passes id 60 — original bug): if the player's nav level is higher,
  `d = player − rival + rand(2) + 1`, rival += d and `d` stat rolls (0x1857B: leadership
  `+rand(3)`, seamanship/knowledge/intuition `+rand(5)`, cap 100); battle level likewise with
  `d = (player − rival)/2 + rand(2) + 1` (rolls courage/swordplay). Rivals stay just ahead.
- **0x186DF rival ships**: for heroes (not the player) and admirals with `.2F&4`, `.31&0x20`,
  `.2E==1` commanding a navy (k ≥ 5) or pirate fleet: if `fleet.28 < player.28` or `rand(3)==0`:
  fill the first empty slot, else replace the slot with the lowest ship record, with class
  `9 + nibble(DS:0xAD16[type] >> 4·(peerage/5))` (type: Joan 0, Catalina 1, Otto 2, Ernst/Pietro 0,
  Al 3; NPC galley 1, galleon 2), heavy guns. Inactive hero fleets also grow this way.
- 0x18864: officer wages (already in RE_NOTES).

---------------------------------------------------------------------------------------------

## 8. Message numbers
152–161 hail replies, 216 "나는 %s의 %s", 225 no fleet to negotiate, 560–562 spoils,
778 no fleet to attack, 779/780 reinforcements, 781 no war at night, 782 same nation,
830–836 enemy lines on defeat, 307/308 tavern girl.

## 9. Open questions
1. Local steering inside the window: 0x23A4D, the window BFS 0x2343F/0x23225/0x237BF/0x239AE/
   0x2389D (uses far buffer `[0xC10]`), and when 0x23A4D returns 0 (steer then yields −1 and
   0x1A9BD stores heading 0xFF).
2. `+0xD` bit 0x01 in the new-game data; meaning of the hero fleets' and fleet 60's activation
   (expected from SNR scripts writing +0x29 through 0x3162E).
3. War-state table DS:0xAC74 / 0x179AD exact states and the high-nibble flags of nation +0x12.
4. Stale `[0xC164]` in the relation update after NPC fights (attacker nation intended?).
5. Player use of the route graph (`fleet == [0xC6DA]` branch restricted to charted nodes).
6. Person +0x2F bits beyond 0x04/0x20/0x80 and +0x30; tavern girl +0xB/+0xE/+0x10; special
   character +0x12/+0x13.
7. Battle internals (0xF9E8) and the full aftermath 0x108EE (other agent).
