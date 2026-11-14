# Sea battles (해전) — MAIN.EXE rules spec

Scope: everything from the moment a sea battle is requested until its aftermath is applied.
Addresses are **load-image offsets** of `original/GAME/MAIN.EXE` (file offset = addr + 0x5400).
`DS:n` = image 0x378B0 + n. Status marks as in `docs/RE_NOTES.md`: ✅ decoded from code and
cross-checked, 🔎 read from code but not exercised, ❓ open.

Related docs: `docs/re/fleets.md` (NPC fleet records, missions, `npc_fight` 0x1A183, reinforcement
selection), `docs/RE_NOTES.md` (records, rand, experience curve).

Conventions used below
- `rand(n)` = 0x4D86 (`((seed = seed*0x41C64E6D+0x3039) >> 16) & 0x7FFF) % n`; `rand(0)` returns 0.
- `min`/`max` = 0x4D42 / 0x4D49, **unsigned 16-bit**. `/` is integer division (truncation).
  "u32" marks the unsigned long helpers 0x383A (div) / 0x373C (mul); results then truncated to 16 bits
  where the code stores a word.
- Stats are person bytes: `LEAD +0x1C, SEA +0x1D, KNOW +0x1E, INT +0x1F, COUR +0x20, SWORD +0x21,
  CHARM +0x22, LUCK +0x23, NAVLV +0x24, BATLV +0x25, NAVEXP +0x26 u16, BATEXP +0x28 u16`.
- "Officer max" (0xD12F / 0xD195): **only for the player's own ship** (captain record == `[0xC67A]`),
  a stat is the maximum over the player, the **부선장** (role 3) and the **수석항해사** (role 5)
  (officer role = person `+0x2E`, found by 0x5BE2 over the companion list DS:0x2D57).
  Role names (DS:0x20F list, 1-based): 1 제독, 2 선장, 3 부선장, 4 경리주임, 5 수석항해사, 6 항해사.
- Skill bits, person `+0x30` (HORIEDIT `babil`): 0x01 교섭, 0x02 회계, **0x04 포술**, 0x08 지도제작,
  0x10 측량. 0xD1EA = "has 포술" (player ship: player or 부선장 or 수석항해사).
- In seg-0 code capstone prints near-call targets > 0xFFFF; subtract 0x10000 (0x14D86 = rand).
  In seg 0xFB8 code capstone sometimes mis-wraps; real target = `0xFB80 + ((ip_next-0xFB80+rel) & 0xFFFF)`.

---------------------------------------------------------------------------------------------

## 1. Call graph ✅

```
0x10D39  player "전투" command (night/same-nation checks)        ┐
0x1FABD  hail ("교섭") → NPC with hostile mission attacks         ├─► 0x10C96 encounter(al=side0, dl=side1)
0x1A183  npc_fight: hunting NPC reaches the player (fleets.md §6.2)┘
0x10C96: [0xD6C]=[0xCE2]=opponent; [0xA509]=0
         0x10B78 reinforcements → sides 2/3
         0xF9E8  battle setup + encounter dialog  (retf 2; al,dl,bl,[sp] = admirals of sides 0..3)
            0x9849, 0x94C6(0x10), 0x15012 …         graphics/music
            0xF53C  build units, map, wind, positions
            0xC2B6/0xC32F/0xBB18                    draw
            scenario hooks 0x32E02/0x32D86/0x32CC1/0x32C30 → may cancel ([0xA509]=8)
            0xF9CA  encounter dialog (0xF661 player attacks / 0xF74A NPC attacks), unless [0xD72]|[0xCE8]
            0xF58D  desertion at battle start
            [0xA538]=100 (duel meter), [0xA53A]=0
         if [0xA509]==0: 0xFB88 → 0xFB26 battle loop
         0x108EE aftermath (exp, 0x10388 result screen, 0x10693 nations, disband NPC fleets)
```

---------------------------------------------------------------------------------------------

## 2. Data structures

### 2.1 Fleet records (no copying into "enemy slots") ✅
The battle works directly on the **fleet records** DS:0x2DB2 + 133·n (accessor 0x5B1C; layout in
`fleets.md` §2.1). Each side's ships are the 10 slots at fleet `+0x2B` (9 B each, `+8 & 0x30 == 0x10`
= in use). Damage to NPC ships is written straight into those slots and persists. The
"index ≥ 10 → DS:0x5666 + 9i" branch of 0x5B4C is **not** used by battle code.

Fleet number of an admiral = person `+0x2C`; `n/10` = nation (6 = pirates), `k = n%10`:
0 hero/rival fleet, 1–4 merchant, 5–9 navy (5–6 galley, 7–9 galleon squadrons). Pirate persons
(`+0x31 & 0xF == 6`) are treated as fleet 60 in the dialogs.

### 2.2 Battle side entries DS:0xA0EE + 8·s, s = 0..3 ✅
| off | meaning |
|---|---|
| +0 | first unit (flagship) pointer |
| +2 | current unit pointer (turn iterator) |
| +4 | fleet record pointer (0 = side unused) |
| +6 | admiral person id (0xFF = unused). `[0xA0F4] [0xA0FC] [0xA104] [0xA10C]` |
| +7 | number of units |

Side 0 = attacker, 1 = defender, 2 = attacker's reinforcement, 3 = defender's reinforcement.
Teams: even sides vs odd sides. "Enemy main entry" of a unit = 0xD329: `0xA0F6 − 8·(side&1)`;
"enemy reinforcement entry" = that + 0x10. "Own main entry" = 0xD33C: `0xA0EE + 8·(side&1)`.
`[0xA61A]` = 1 if the player is side 0 or 2.

### 2.3 Unit record, 24 B, DS:0xA10E + 0xF0·side + 0x18·slot ✅
Built by 0xF0CA for each ship slot in use (slot order), then relinked by 0xEE2C.

| off | size | meaning | set at |
|---|---|---|---|
| +0 | w | captain person pointer | 0xF176 |
| +2 | w | ship slot pointer (fleet `+0x2B + 9·slot`) | 0xF17B |
| +4 | w | map position `y·52 + x` | 0xF35E |
| +6 | w | assigned target unit (valid when flag 0x80) | orders |
| +8 | w | next unit in the side's list (0 = end) | 0xEE2C |
| +0xA | b | heading 0..5 (0 N, 1 NE, 2 SE, 3 S, 4 SW, 5 NW) | 0xF32A |
| +0xB | b | turn accumulator 0..100 (starts 0) | movement |
| +0xC | b | flags (§9.1) | 0xEDB3/0xEE2C |
| +0xD | b | `(side<<4) + owner + listIndex` ; owner 0x80 = player's own fleet, 0xC0 = player's ally, 0x40 = enemy reinforcement, 0 = enemy main | 0xF16B/0xEF2C |
| +0xE | w | shot (포탄) on board | 0xEFC0/0xF036 |
| +0x10..+0x14 | b×5 | gun power at distance 1..5 (§6.1) | 0xF073 |
| +0x15 | b | gun range = DS:0x828[type] | 0xF05E |
| +0x16 | b | melee power | 0xF0C1 |
| +0x17 | b | combat-crew share % | 0xF1D6 |

Captain: player fleet → cargo record `+0x1B` of that slot; NPC fleet → **the admiral for every ship**
(0xF158). Unit alive = 0xD232: `crew ≠ 0 && hull ≠ 0 && !(flags & 0x40)`.

### 2.4 Battle map DS:0x9722, 52 × 48 bytes ✅
Cell = `map[y·52 + x]`, x 0..51 (columns), y 0..47 (rows). In bounds = 0xD3D8.
| bits | meaning |
|---|---|
| 0x80 | blocked: land (0x84..0x8C are coast graphics), or a **derelict** ship (crew killed, 0xE3B0) |
| 0x40 | occupied by an odd-side (defender team) ship |
| 0x20 | occupied by an even-side (attacker team) ship |
| low 5 bits | graphic (0 / 1 = two sea variants) |
A cell is enterable iff `cell & 0xE0 == 0`.

Three far work buffers of 0x9C0 bytes (same indexing) are allocated at 0xED77:
`[0xA0E2]` reach/attack flags, `[0xA0E6]` threat map, `[0xA0EA]` firing-position score (§9).

### 2.5 Globals
`[0xA4CE]` acting side entry, `[0xA4D0]` acting unit, `[0xA4D2]` AI destination, `[0xA4D4]` path
(≤10 dirs, ≥6 ends), `[0xA4FD]/[0xA4FE]` view origin (x,y) of the 13×12 visible window,
`[0xA500]` wind cost table [6], `[0xA506]` wind dir, `[0xA507]` wind strength, `[0xA509]` end code,
`[0xA538]` duel meter, `[0xA53A]` last duel opponent, `[0xA61C]/[0xA61E]` team strengths,
`[0xA618]` chosen target, `[0x571]` world tick (advances during battle).

---------------------------------------------------------------------------------------------

## 3. Tables

### 3.1 Cannons (index = ship slot `+8 & 7`) ✅
Names DS:0x808 (pointers), stats u16 ×8.

| t | name | DS:0x818 weight×10 | DS:0x828 range | DS:0x838 power | DS:0x848 price |
|---|---|---|---|---|---|
| 0 | 미탑재 | 0 | 0 | 0 | 0 |
| 1 | 캐논 | 20 | 3 | 20 | 360 |
| 2 | 데미캐논 | 13 | 2 | 14 | 80 |
| 3 | 캐논페드로 | 10 | 2 | 10 | 40 |
| 4 | 컬버린 | 15 | 5 | 10 | 250 |
| 5 | 데미컬버린 | 11 | 5 | 4 | 40 |
| 6 | 세이커 | 4 | 2 | 4 | 5 |
| 7 | 카로네이드 | 15 | 5 | 20 | 600 |

0x818 is only cargo weight (`guns·w/10`, 0x5CC7) and shipyard display; battle uses 0x828 / 0x838.

### 3.2 Gun power by distance (unit +0x10..+0x14), 0xEF46 ✅
Local 5×5 table (row = range−1, column = distance−1):
```
range 1: 0 0  0 0 0
range 2: 0 10 0 0 0
range 3: 0 10 9 0 0
range 4: 0 10 9 8 0
range 5: 0 10 9 8 7
unit[+0x10 + (d−1)] = (row[range−1][d−1] · power) & 0xFF        (range 0 → row 0)
```
So `gunPower(d) = {2:10, 3:9, 4:8, 5:7}[d] · power` for `2 ≤ d ≤ range`, else 0. Resulting values:

| t | d=2 | d=3 | d=4 | d=5 |
|---|---|---|---|---|
| 캐논 | 200 | 180 | – | – |
| 데미캐논 | 140 | – | – | – |
| 캐논페드로 | 100 | – | – | – |
| 컬버린 | 100 | 90 | 80 | 70 |
| 데미컬버린 | 40 | 36 | 32 | 28 |
| 세이커 | 40 | – | – | – |
| 카로네이드 | 200 | 180 | 160 | 140 |

### 3.3 Hex neighbours DS:0xA514 (static), 6 × {dx, dy if x even, dy if x odd} ✅
| dir | dx | dy (x even) | dy (x odd) |
|---|---|---|---|
| 0 N | 0 | −1 | −1 |
| 1 NE | +1 | −1 | 0 |
| 2 SE | +1 | 0 | +1 |
| 3 S | 0 | +1 | +1 |
| 4 SW | −1 | 0 | +1 |
| 5 NW | −1 | −1 | 0 |
Columns of flat-topped hexes; odd columns are shifted half a hex down.

### 3.4 Ship classes used by battle (DS:0x5E28 ×12 B; base ship records 40+c) 🔎
Class `+1` = durability (max-hull floor, §6.3), `+8` = **max gun ports** (NPC shot stock, §5.2).
Ship record `+0x13 & 0x10` = sail-only (clear = oared galley: 경갤리, 플랜더스/베네치안 갤리,
라 레아르, 철갑선, 안택선, 관선).

| c | name | dur +1 | maxGuns +8 | rec+0x13 |
|---|---|---|---|---|
| 0 | 발사 | 30 | 10 | 0x52 |
| 1 | 한자콕 | 20 | 10 | 0x12 |
| 2 | 다우 | 30 | 15 | 0x52 |
| 3 | 버스 | 70 | 40 | 0x32 |
| 4 | 타렛테 | 20 | 15 | 0x12 |
| 5 | 카라벨 라티나 | 30 | 20 | 0x52 |
| 6 | 카라벨 레돈다 | 30 | 20 | 0x52 |
| 7 | 브리간틴 | 40 | 20 | 0x72 |
| 8 | 나오 | 50 | 40 | 0x72 |
| 9 | 카락 | 50 | 50 | 0x72 |
| 10 | 갤리온 | 80 | 70 | 0x52 |
| 11 | 지벡 | 70 | 40 | 0x52 |
| 12 | 파네스 | 40 | 20 | 0x52 |
| 13 | 슬루프 | 50 | 40 | 0x52 |
| 14 | 프리게이트 | 80 | 70 | 0x52 |
| 15 | 바그 | 90 | 120 | 0x72 |
| 16 | 쉽 | 90 | 150 | 0x72 |
| 17 | 정크 | 80 | 40 | 0x52 |
| 18 | 경갤리 | 40 | 10 | 0x02 |
| 19 | 플랜더스 갤리 | 80 | 30 | 0x02 |
| 20 | 베네치안 갤리 | 90 | 50 | 0x02 |
| 21 | 라 레아르 | 60 | 40 | 0x42 |
| 22 | 철갑선 | 90 | 100 | 0x62 |
| 23 | 안택선 | 60 | 40 | 0x22 |
| 24 | 관선 | 30 | 20 | 0x02 |

---------------------------------------------------------------------------------------------

## 4. Starting a battle

### 4.1 Paths into `encounter` 0x10C96 ✅
1. **Player "전투"** (sea menu 28 item 2; 0x20852 → 0x20464 → 0x10D39)
   - `tick [0x571] < 15 || tick >= 60` → msg **781** "[원작 문장 생략]." (no battle).
     A day is 72 ticks (20 min each): battles may start 05:00–19:40.
   - Candidates 0x12CF9(r=2): fleets with `+0x29 & 1`, not `& 0x10` (in port), admiral ≠ player,
     `|dx| ≤ 2 && |dy| ≤ 2` world tiles (no east–west wrap). None → msg **778**.
   - Pick, show admiral (0xC215), confirm. Target nation (`fleet/10`) == player nationality and the
     player is not a pirate → msg **782** "[원작 문장 생략]？" (no → re-pick).
   - `encounter(side0 = player, side1 = target)`.
2. **Hail** (menu 28 item 1; 0x1FABD): missions 3, 4, 11 or 5–7 hunting the player answer
   msg 155/156/161 and call `encounter(side0 = NPC, side1 = player)` — no night check (if tick ≥ 63
   the battle ends immediately with code 1).
3. **NPC hunter reaches the player** (`npc_fight` 0x1A183 → `call 0x10C96` at 0x1A223): only
   ticks 18–53, see `fleets.md` §6.2 (a fleet without `+0x29 & 0x40` leaves a peerage-0 player alone).

### 4.2 Reinforcements 0x10B78 ✅ (msgs 779, 780)
```
if player nationality (+0x31 & 0xF) == 6: none
A = side-0 admiral, D = side-1 admiral
for c in 0x12CF9(2)   (fleets within 2 tiles of the PLAYER, record order):
    if c in {A, D} or c.fleet%10 < 5: continue            # navy/pirate squadrons only
    if side3 empty and c.fleet/10 == D.fleet/10: side3 = c; msg 779 (수비측 원군)
    elif side2 empty and c.fleet/10 == A.fleet/10: side2 = c; msg 780 (공격측 원군)
```
(The player's "fleet/10" is the hero's original nation.) Reinforcements are AI-only; the player's
ally gets no experience; its flagship's fate does not end the battle.

### 4.3 Encounter dialog 0xF9CA ✅ (skipped when `[0xD72]` or `[0xCE8]` ≠ 0)
Team strengths (0xF279): `[0xA61C]` = Σ fleet `+0x28` of the player's team, `[0xA61E]` = Σ of the
other team, where fleet `+0x28 = (Σ hull of used slots + 4) / 5` (0x17C7D).

**Player attacks** (0xF661, D = defender admiral):
- pirate (`fleet/10 == 6`): msg 810 (scenario event exists for D) or 811, then 813 → battle.
- else msg **812** "멈춰라！", then
  - merchant (k 1–4) and `(3·[0xA61E])/2 < [0xA61C]`: msg **815** "[원작 문장 생략]…"
    + yes/no. **Yes → `[0xA509] = 2`, no battle** (and no goods are transferred: code 2 only
    gives pirate fame, §11). No → msg 816, battle.
  - hero / navy: msg 814, battle.

**NPC attacks** (0xF74A, A = attacker): line 817 (pirate) / 818 (mission 3, arrest) / 819;
advisor 821 if `(3·[0xA61C])/2 ≥ [0xA61E]` else 820; **MENU 54**: 교전 / 도망 / 항복 (Esc = 교전).
- **도망** (flee): `if player.NAVLV + player.LUCK > rand(150)` → msg **822**, `[0xA509] = 3`, no battle;
  else msg **824** "[원작 문장 생략]." → battle. Raw player stats.
- **항복** to a non-pirate: msg **825**, `gold = (2·gold)/3` (signed 32-bit), `mult = 2`.
  (Text says 2/3 is confiscated; the code keeps 2/3.)
- **항복** to pirates: msg **826**, then `gold < 1000` → msg 827, `gold += 1000`;
  `gold < 10000` → msg 828 (unchanged); else msg 829, `gold = 5000`. `mult = 0`.
- After either surrender: every trade-goods slot of every used player ship: `qty = (qty·mult)/3`
  (signed 16), `qty == 0` → good id `+0x16+k = 0xFF`. Water/food/lumber/shot untouched.
  `[0xA509] = 9`, no battle.

### 4.4 Desertion at the start 0xF58D ✅ (msgs 787–790)
Only if `[0xA61C] + 20 ≤ [0xA61E]`: for each player unit after the flagship whose captain's
loyalty (`+0x2B`) < 40: msg `787 + (captain[+0x2F] >> 6)`, then 0xE832: the officer leaves with
his ship (removed from list 0x2D57, ship deleted by 0x5CDF, `+0x2E = 0, +0x2C = 0xFF,
+0x2D = rand(54) + 3`); the unit is unlinked and its map cell `&= 0x1F`.

---------------------------------------------------------------------------------------------

## 5. Battle setup 0xF53C ✅

```
0xF53C(al=A0, dl=A1, bl=A2, stack=A3):
    [0xA0F4],[0xA0FC],[0xA104],[0xA10C] = admirals ; [0xA61A] = player is A0 or A2
    0xF279  units for each side, strengths, returns EH
    0xED77  allocate buffers, build map (0xEAF0), wind (0xED0F)
    0xF443  headings + starting positions
    0xF51B  centre view on the player's flagship (0xF4D2)
```
`EH` (return of 0xF279) = Σ maxHull (`+3`) of every unit on sides whose first unit has no 0x80 owner
bit, i.e. the enemy main fleet + enemy reinforcement. Used for end-of-battle experience (§11.4).

### 5.1 Units 0xF0CA
For slot 0..9 of the side's fleet with `+8 & 0x30 == 0x10`:
- owner bits (0xF0E9): if this side is on the player's team: 0x80 for the player's own fleet else 0xC0;
  otherwise 0x40 for sides 2/3, 0 for sides 0/1.
- `+0x17` combat-crew share:
  - player ship: `100 − cargo[+8] − cargo[+9]` (cargo `+9` = sailing-crew %, used by the speed
    formula; `+8` = a second allotment, default 25 → default share **25%**; the UI that edits `+8` ❓)
  - NPC ship: 25 if sail-only (record `+0x13 & 0x10`), 50 if oared.
- 0xEF46 (below), then flags 0xEDB3 (§9.1).
- 0xEE2C: flagship = player fleet: the slot captained by the player (`[0x1241]`); NPC: first slot
  with the largest maxHull. List = flagship first, then the others in slot order;
  flagship flags `= 0x22`; `+0xD` low nibble renumbered 0..n−1.

### 5.2 0xEF46: shot, guns, melee power
```
if player fleet:  shot = cargo[slot].shot (+6, u16);  m = 3
else:
    g = class[record[+0x12]].maxGuns(+8) / 5
    k = admiral.fleet % 10
    shot = (k == 0 || k >= 5) && record[+0x13] & 0x10 ? g : 0       # hero/navy sail ships
    shot += rand(g)
    m = (first USED slot processed for this side) ? 3 : 2            # [bp-0x22]; note: slot order, not flagship
t      = slot[+8] & 7
range  = DS:0x828[t]                      → +0x15
+0x10..+0x14 = §3.2 table × DS:0x838[t]
+0x16  = ((BATLV·SWORD/100 + SWORD/2) · m) / 3          # captain's raw stats; u16 arithmetic, stored as byte
```

### 5.3 Map 0xEAF0 (+ coast graphics 0xE8C2) ✅
Centred on the **defender's** (side 1) world position (X, Y) (fleet `+0`, `+2`):
```
tile[r][c] = land if worldTile(X−2+c, Y−2+r) >= 0x34 else sea        r,c = 0..5
            (same "≥ 0x34 = blocked" rule as world navigation 0x30ACE; remaster: World land mask)
cell(x, y) for y 0..47, x 2..49:  tile[y/8][(x−2)/8]  → land 0x84 / sea 1
erosion: for each SEA tile (r,c):
    for y in [max(0,8r−4), min(48,8r+12)), x in [max(0,8c−4)+2, min(48,8c+12)+2):
        j = 6·(y>>3) + (x>>3)                       # note: x still includes the +2 offset
        cell = (tile j is land && rand(2) != 0) ? 0 : 1     # both values are sea
cols 0,1 := col 2 ; cols 50,51 := col 49   (per row)
0xE8C2: land cells get coast graphics 0x85..0x8C by their 8 neighbours (cosmetic, keep 0x80)
```
Net effect: a land cell survives only if it lies in a land tile and outside every sea tile's
box extended by 4 cells on each side.

### 5.4 Wind 0xED0F ✅ (independent of the world wind; fixed for the battle)
```
strength [0xA507] = rand(8) + 1                              # 1..8
dir      [0xA506] = rand(8)·5/7                              # 0..5; 0 and 2 twice as likely
W[(dir + k) % 6] = {1, 2, 3, 4, 3, 2}[k]    (DS:0xA500)      # 1 = with the wind, 4 = against
```
`dir` is the direction the wind blows toward (consistent with WINDCUR's convention; the arrow drawn
by 0xC2EB should confirm ❓).

### 5.5 Headings and starting positions 0xF443 / 0xF32A / 0xF35E ✅
```
for each used side s (fleet F, defender fleet D = side 1):
    heading of all its units = (5·F.course(+0x1A)) / 7 % 6       # course 0..7 → 0,0,1,2,2,3,4,5
    ax = clamp(F.x − D.x + 2, 0, 4) ; ay = clamp(F.y − D.y + 2, 0, 4)
    anchor = (10 + 8·ax, 8·(ay + 1))                              # x ∈ {10,18,26,34,42}, y ∈ {8..40}
    flagship: at anchor if in bounds and cell&0xE0 == 0, else retry
              (anchor.x + rand(16) − 8, anchor.y + rand(16) − 8) until valid
    others:   (flag.x + rand(8) − 4, flag.y + rand(8) − 4) until valid
    cell |= 0x20 << (s & 1)
```
The view starts centred on the player's flagship: origin `(clamp(x−6, 0, 39), clamp(y−6, 0, 36))`.

---------------------------------------------------------------------------------------------

## 6. Turn structure ✅

### 6.1 Loop 0xFB26 / 0xFAA6
```
while tick[0x571] < 63:                       # 63 = 21:00. Each pass = one 20-minute tick
    for each side: entry.current = entry.first
    repeat 10 times:                          # unit index
        for side 0..3:
            u = entry.current
            if u:
                if alive(u):
                    if u is the player's flagship (entry.fleet == [0xC6DA] && u == entry.first):
                        r = 0xB6D3 (command menu, §10)
                    else:
                        r = 0xA213 (AI turn, §9)
                    if r == 0: return         # battle over
                entry.current = u.next ; redraw 0xC13B ; delay
            stop if [0x426] (quit) or [0xA509] != 0
    tick += 1                                  # world clock really advances; no daily processing
[0xA509] = 1                                   # sunset
```
Order inside a tick: S0U0, S1U0, S2U0, S3U0, S0U1, S1U1, … Each unit gets **one action per tick**:
move (up to its movement points) and then at most one attack. Dead/left units are skipped.

### 6.2 End check 0xA1B0 (after every unit's action) ✅
```
if [0xA509] != 0: return 0
for s in (0, 1):                                    # main fleets only, side 0 first
    F = entry[s].first
    if !alive(F):
        code = (entry[s].fleet == player fleet) ? 5 : 4
        if F.flags & 0x40: code -= 2               # left the map instead of being lost
        [0xA509] = code; return 0
return 1
```

---------------------------------------------------------------------------------------------

## 7. Movement ✅

### 7.1 Distance 0xD250
`v = 2y + (x & 1)`; `dist = max(|Δx|, (|Δx| + |Δv|) / 2)` (code: `|Δv| < |Δx| ? |Δx| : (|Δv|+|Δx|)/2`).

### 7.2 Movement points per turn 0xD48D (captain's **raw** SEA and NAVLV)
```
s  = (sail(+5) · strength · 8 / 150 + 20) · SEA / 100
mp = max(10, min(25, s + s·NAVLV/15))
```

### 7.3 Turn rate 0xD440
```
r    = rudder(+4) · SEA / 200
rate = min(100, r + r·NAVLV/15)
```

### 7.4 Step cost 0xD3F1(newDir, heading)
```
straight (newDir == heading): cost = sail(+5) · W[newDir] / 100 + 5          # 5..9
turning:  cost = (W[newDir] >= 3) ? 10 − 5·rudder(+4)/100 : 5                 # 5..10
```
(High-sail ships pay more going upwind; ships with destroyed sails pay 5 but have few points.)

### 7.5 Step rules (search 0xDC39 for AI, 0xD813 for the player, execution 0xA129)
From cell P with heading h, points mp and accumulator acc:
```
acc' = min(100, acc + rate)
candidates nd = h−1, h, h+1 (mod 6)        # never sideways/backwards
    turning (nd != h) allowed only if acc' >= 50
    Q = neighbour(P, nd); need inBounds(Q), map[Q] & 0xE0 == 0, cost(nd,h) <= mp
    move: mp −= cost; acc = (nd == h) ? acc' : 0; heading = nd
```
The accumulator persists in unit `+0xB` between turns. Rotation in place:
- player (0xA8EF, msg 769): only h±1, no accumulator test, sets `+0xB = 0`; ends the move.
- AI (0xE142): picks a heading (firing heading if on a firing spot, else the ±1/0 neighbour closest
  to its target); `+0xB = min(100, +0xB + rate)` (not reset).
Moving one hex (0xC341) moves the occupancy bits; max 10 steps per path.

Quirk (AI only): 0xDC39 marks the *source* cell of each expanded step as reachable, so a cell is a
legal AI destination only if a further step from it would also be affordable (the player's 0xD813
marks destinations; the player can use all points). Start cell is always marked.

---------------------------------------------------------------------------------------------

## 8. Combat

### 8.1 Who can attack whom (0xE727, 0xD5E7/0xD629 → 0xD500) ✅
- **Cannon fire** possible iff `shot (+0xE) > 0`, `2 ≤ dist ≤ range(+0x15)` (adjacent ships can't be
  shot), and the target is in a **broadside arc** of the current heading. With
  `ax = |x1−x2|`, `av = |v1−v2|` (v as in §7.1), attacker (x1,v1):
  - heading 0/3 (N/S): `av ≤ ax`
  - heading 1/4 (NE/SW): `av ≥ ax && ((x2 ≤ x1 && v2 ≤ v1) || (x2 ≥ x1 && v2 ≥ v1))`  (target NW or SE)
  - heading 2/5 (SE/NW): `av ≥ ax && ((x2 ≤ x1 && v2 ≥ v1) || (x2 ≥ x1 && v2 ≤ v1))`  (target SW or NE)
- **Boarding** (백병전) possible iff `dist == 1`.
- AI priority (0xE727): unit flag 0x10 (포격중심) → fire if possible else board; otherwise board if
  adjacent else fire. Player chooses a marked target (msg 772): fire if possible, else board.

### 8.2 Cannon damage 0xD6D3 (attacker unit U, distance d) ✅
```
L  = LEAD (officer max)             B = BATLV (officer max)
F  = L·B/100 + L/2
gunners = (U.share(+0x17) · crew) / 100                       # u32
N  = min(guns(+6)/2, gunners/2)                               # one broadside, 2 men per gun
P  = U.gunPower[d] · N / 10                                   # u32
D  = has 포술 ? ceil(P/20) : ceil(P/40)                        # (P+19)/20 or (P+39)/40
D  = D · F / 100
D  = D · (50 + rand(SWORD(officer max)/2)) / 100
D  = max(1, min(D, 50 + rand(captain.BATLV(raw)/2)))
```
There is **no miss roll**: every volley hits. The defender's stats play no role.

### 8.3 Applying a volley 0xE428 / 0xE5BF ✅
```
dmg = D
crit = 0
if dmg >= 10 or rand(5) == 0:
    crit = T1[rand(19)]      T1 = {1,1,1,1, 2,2,2,2, 4,4,4,4, 3,3, 5,5, 6,6, 7}
if dmg >= 20: crit = T2[rand(7)]      T2 = {3,3, 5,5, 6,6, 7}
if dmg >= 40: crit = 7
hull  −= min(hull, dmg) ; hull = min(hull, maxHull)
crew  −= min(crew, rand(3) + dmg/2)
if crit & 1: maxHull = max(class.dur(+1)/4, maxHull − 1)     # permanent
if crit & 2: sail(+5)   −= min(sail,   rand(3) + dmg/2)
if crit & 4: rudder(+4) −= min(rudder, rand(3) + dmg/2)
(0xCAFB: animation only)
if hull == 0:  sink (0xE36E): exp, remove from map (0xC42A), clear targets pointing at it (0xE2A6),
               ship slot +8 = 0 (slot freed; for the player the ship is lost after battle)
elif crew == 0: derelict (0xE3B0): map cell occupancy cleared and set 0x80 (obstacle), exp,
               clear targets; the hulk stays (capturable, §11.6)
else if attacker is in the player's own fleet: exp +10
attacker.shot −= 1                                            # one shot per volley
```
Experience (player's own fleet only, to the acting ship's captain, 0xE30B): sink or derelict
`10 · target.maxHull`, otherwise 10.

### 8.4 Boarding 0xE651 / 0xE612 / 0xD656 ✅
```
melee(U) = clamp(1, 50,
    ( (U.melee(+0x16) · ((crew + rand(10)) · U.share / 100) / 100) · (50 + rand(SWORD(officer max)/2)) & 0xFFFF ) / 100 )
    # inner (crew+rand)·share/100 and ·melee/100 are u32; the last product keeps only the low 16 bits
target.crew   −= min(target.crew,   melee(attacker))
attacker.crew −= min(attacker.crew, melee(target))           # with the target's reduced crew
(0xCEF6: animation)
if target.crew == 0: derelict (0xE3B0), exp 10·maxHull ; else exp +10 (player's own fleet)
```
Hulls are not damaged by boarding. An attacker reduced to 0 crew just becomes dead (cell keeps its
occupancy bit).

**Duel challenge instead of boarding** (both replace the melee exchange and give no melee exp):
- Player (0xAA24): target is the flagship of an enemy entry → msg **770** yes/no; yes and
  `rand(player.LUCK) + ownCrew ≥ targetCrew` → duel (0x128B7, ax=1); else msg **771** and boarding.
- AI (0xE651): acting unit is its side's flagship and the target is the player's flagship (the first
  unit of an opposing entry whose fleet is `[0xC6DA]`): if
  `rand(15) + attacker.SWORD ≥ player.SWORD && attacker.LUCK ≥ rand(targetCrew)` → `[0xA538] = 200 − m`,
  duel 0x128B7 (ax=0, msg **1062**), flip back.

---------------------------------------------------------------------------------------------

## 9. AI ✅ (0xA213 per unit)

```
if !alive(u): return 1
if !0x9902(): u.flags |= 8            # own FLAGSHIP: crew ≤ record.maxCrew(+0x15)·4/10 or hull ≤ maxHull·4/10 or left
0xA0B7: reach := 0x0F, threat := 0, score := 0 ; 0xDEBE: search (§7.5), threat map, firing scores
dest [0xA4D2] = MODE[u.flags & 0xF]()     (far table DS:0x967E)
0xE244: path to dest (fewest heading changes; if dest is a firing spot, last path arriving with the firing heading)
0xA129: execute
0xA0FB: if reach[u.pos] & 0x80: attack (0xE815 → 0xE7A0)
0xA1B0: end check
```

### 9.1 Unit flags +0xC
| bit | on / off (msg in 작전일람) | effect |
|---|---|---|
| 0x01 | 공세 / 수세 (1025, 1026) | display; copied to 0x02 by orders |
| 0x02 | 공격 / 퇴각 (1027, 1028) | mode selection; `flags & 3 == 0` → no firing-spot scoring → never attacks |
| 0x04 | 집결 / 분산 (1023, 1024) | mode selection |
| 0x08 | 이탈 (1022) | flee mode |
| 0x10 | 포격중심 / 돌격중심 (1029/1045, 1030/1046) | scoring weights; fire-first |
| 0x20 | fleet flagship | |
| 0x40 | left the battle | set only by 0xE2F1 |
| 0x80 | has assigned target `+6` (else 위임 1033/1050) | |

Initial flags 0xEDB3 (non-flagships): `(rand(50) ≤ COUR) ? 3 : 2`; `|0x10` if shot > 0 and sail-only;
`|8` if the admiral's fleet is a merchant (`k 1–4`) of nations 0–5. Flagship: exactly 0x22.

### 9.2 Maps built each AI turn (0xDEBE)
- threat (0xDA7F/0xDA0B): for every enemy unit (main + reinforcement, **no alive check**), each
  in-bounds cell within x±5, y±5, `d = dist > 0`: `+= enemy.gunPower[d]` if the enemy could fire at
  it from its current heading (0xD5E7); `+= enemy.melee(+0x16)` if d == 1 (byte, wraps).
- firing score (0xDB16), only if `flags & 3 != 0`: `wGun = flags&0x10 ? 2 : 1`, `wMelee = flags&0x10 ? 1 : 2`;
  for each reachable cell and arrival heading nd, for each enemy E: if U could fire at E from there
  `v = gunPower[dist]·wGun`; if adjacent `v = melee·wMelee` (byte); keep the max ≥ current,
  `reach[cell] = nd | 0x80`.
- friends (0xDE85/0xDD5D): the cell directly ahead of a friendly ship, and the last free neighbour of a
  friend with 5 occupied neighbours, are made non-destinations.

### 9.3 Modes (DS:0x967E, index = flags & 0xF)
| idx | routine | order | destination |
|---|---|---|---|
| 0,1 | 0x9FD4 | 분산·퇴각 | reachable cell with least threat; tie → farthest move |
| 2,3 | 0x9F9B → 0x9D07 | 분산·공격 | approach target T = `+6` if 0x80, else the **enemy main flagship** |
| 4,5 | 0x9E5E | 집결·퇴각 | stay near own flagship, least threat |
| 6,7 | 0x9E3B → 0x9D07 | 집결·공격 | approach own flagship |
| 8..15 | 0x9C21 | 이탈 | run to a map edge and leave |

0x9D07 (scan y 0..47, x 0..51, reachable cells only):
```
dT = max(dist(cell, T), u.range) ; dU = dist(u, cell) ; s = score[cell]
q  = ((((12 − min(dT,10)) · bestS · 10 / 100) & 0xFF) + 9) / 10 · 10 & 0xFF
take if dT < bestDT  or (dT == bestDT && q < s) or (dT == bestDT && q == s && dU > bestDU)
init bestDT = 0xFF, bestS = 0, bestDU = 0
```
0x9E5E: same scan with `dT = dist(cell, own flagship)` (no range clamp), `s = threat`,
`q = ((min(dT,10)·bestS·10/100 & 0xFF) + 9)/10·10 & 0xFF`, take if `dT < bestDT` or tie and `q > s`
or tie, `q == s` and `dU > bestDU`; `bestS` starts 0xFF.

0x9C21 (flee): if the unit is already on an edge sea cell (`x∈{0,51} || y∈{0,47}`, not land; 0x9953)
→ **leave now** (0xE2F1). Else go to the farthest reachable edge sea cell, or if none, to the reachable
cell nearest one of 12 edge points (0,0) (51,0) (0,47) (51,47) (25,0) (26,0) (0,23) (0,24) (51,23)
(51,24) (25,47) (26,47) (original bug: their land test uses swapped x/y).

### 9.4 Target choice (0xE7A0)
Assigned target `+6` if attackable; else the **first** ship, in list order, of the enemy main entry,
then the enemy reinforcement entry, that is alive and attackable from the final cell. No weighting
by weakness or distance.

---------------------------------------------------------------------------------------------

## 10. Player flagship commands (0xB6D3, MENU 50, handlers far table DS:0x9702) ✅

| # | MENU 50 | handler | greyed when | effect / messages |
|---|---|---|---|---|
| 0 | 이동 | 0xAB55 → 0xA6DA | – | step-by-step hex picking (msg **767**), undo by clicking own cell, confirm msg **768**; if no step, rotate 0xA8EF (msg **769**); then attack prompt 0xAAB2; ends turn |
| 1 | 공격 | 0xAB6D → 0xAAB2 | no enemy fireable/adjacent | msg **772** pick target; fire or board (duel offer 770/771); ends turn |
| 2 | 정보 | 0xB089 | – | MENU 51 info screens (table DS:0x96D0); free |
| 3 | 신호 | 0xB140 | no other living own ship | toggles 이탈 (^8), 집결/분산 (^4), 공세/수세 (^1) on the flagship, then every other own ship: `flags = (flags & 0xF0) + (F & 0x0D) + ((F & 1) << 1)`; free |
| 4 | 작전 | 0xB503 | no own ship on screen | msg **773** pick ship; toggles 방침 (`^2`, bit0 = bit1), 방법 (`^0x10`), 대상 (msg **774** pick enemy → `+6`, 0x80; or clear); free |
| 5 | 정선 | 0xB51A | – | msg **775** yes → pass |
| 6 | 아이템 | 0xB543 | no usable item | item menu 0x293F1 ❓; free |
| 7 | 이탈 | 0xB54B | flagship not on an edge sea cell | msg **776** yes → 0xE2F1 (flag 0x40) → end code 3 |

Note: the flagship starts at 0x22 (shown 수세). The first 신호 copies 수세 → 퇴각 to every ship,
which then never attacks until the player signals 공세.

### 10.1 Retreat / escape summary
- Only way to leave: be on an edge sea cell (x 0/51 or y 0/47) — the player via 이탈, an AI ship in
  flee mode at the start of its turn. No dice, speed or distance test.
- AI flee mode: merchant escorts from the start; every ship of a side once its own flagship is at
  ≤ 40% crew or hull or has left.
- The AI never surrenders during a battle; surrender exists only in the encounter dialog (§4.3).

---------------------------------------------------------------------------------------------

## 11. Outcome

### 11.1 End codes `[0xA509]` and result screen 0x10388 (jump table cs:0x084F)
| code | set at | meaning | result |
|---|---|---|---|
| 1 | 0xFB80 | sunset (tick 63) | msg **563**; log "draw" |
| 2 | 0xA1E3 / 0xF722 | enemy main flagship left the map / merchant accepted 815 | msg **565**; pirate fame (s=1); no loot; log "win" |
| 3 | 0xA1E3 / 0xF86B | player's flagship left / successful flee | msg **564**; officers with loyalty < 40 desert (msg 791 path, 0xE832); log "fled" |
| 4 | 0xA1D6 | enemy main flagship lost (crew 0 / hull 0) | msg **833** (name, nation, date `[0x56E]+1501/[0x56F]+1/[0x570]+1`); pirate fame (s=3); loot + capture; log "win" |
| 5 | 0xA1D6 | player's flagship lost | **game over**: msg **1017**, `[0x426] = 0x1A` |
| 6 | duel 0x12960 | player won the duel vs the enemy admiral | as 4; every non-player fleet in the battle is disbanded |
| 7 | duel 0x12960 | player lost the duel | game over as 5 |
| 8 | 0xFA4C | scenario hook cancelled | nothing shown |
| 9 | 0xF9B5 | player surrendered | msg **566**; enemy fleet sent home (0x330CF); desertion as 3; log "fled" |
Log entry 0x1DC0F: msg **837** + MENU **53** suffix (승리했다 / 일몰로 무승부 / 도망칠 수밖에 없었다).

### 11.2 Aftermath 0x108EE (in order)
1. Write back shot: `cargo[slot].shot = unit.shot` for the player's units.
2. Unless code 5/7: each player slot with a captain: slot freed (sunk) → 0x5CDF (captain survives, role 6);
   slot alive and **code even** → `0xE30B(captain, EH/5)`.
3. 0x10388 result + fame (§11.3), loot (§11.5), capture (§11.6).
4. Unless quitting: 0x10693 nation standing (§11.4) — for even codes (and 8).
5. Recompute fleet strengths; for every non-player side disband (0xFC50) if its flagship slot is free,
   crew 0, hull 0, the admiral lacks `+0x31 & 0x20`, or code 6. Disband: fleet `+0x28 = 0`,
   `+0x29 &= ~1`, `+0x2A = 0xFF`, all slots `+8 = 0`; admiral `+0x2E = 0, +0x2C = 0xFF, +0x2D = rand(42)`.
6. Scenario hooks; farewell line for codes 2/4/6 (k = code≠2): pirate 830/834, merchant 832/836,
   navy/hero 831/835.

Morale (cargo `+0x1C`) is not changed by battle code, except captured ships start at 60.

### 11.3 Pirate fame (0x10497) — codes 2, 4, 6
```
s = (code == 2) ? 1 : 3
if player nationality == 6: s *= 3
else switch cat(): 2 → s*=2 ; 3 → s*=3 ; 4 → s*=4
bl = enemy admiral BATLV
pirateFame(family+2) = min(50000, pirateFame + 200 + (min(bl,30)·min(bl,15)·s & 0xFFFF))
```
`cat()` 0xFB8E (P = player nationality, N = enemy fleet/10, natRec = DS:0x1106 + 32n): 0 unless the
player holds item `29+P` (own letter of marque); then 1; 2 if `natRec[P].rel[N] (+0xB+N) ≤ 40`;
3 if `natRec[N][+0x12+P] & 0x10`; 4 if `natRec[P][+2] == N`; 5 if `rel ≥ 60`; 6 if
`natRec[P][+0x12+N] & 0x20` (later tests override). Trade/adventure fame are never touched.

### 11.4 Nation standing 0x10693 (family record `+6..+0xC`, "적대치" in HORIEDIT but used as favour)
```
a = min(rand(5)+3, rel[P][N]); rel[P][N] −= a; rel[N][P] = rel[P][N]
(s, w) by cat(): 2→(2,10) 3→(3,6) 4→(4,3) 5→(−1,90) 6→(−1,60) else (1,30)
if N != 6: st[N] −= min(st[N], (rand(5)+10)·w/30)
if P == 6: stop
if N != P: st[P] = (s >= 0) ? min(200, st[P] + (rand(5)+5)·s) : st[P] − min(st[P], rand(5)+5)
else:  st[P] −= min(st[P], rand(5)+10)
       if st[P] ≤ 40: msg 568 (국적 박탈): rank = 0, nationality = 6, clear [0xCEB],[0xCEA], [0xCEE] &= 0xF8
       elif rank != 0 and st[P] ≤ 70: msg 569 (작위 박탈): rank = 0, same clears
```

### 11.5 Loot 0x10216 — codes 4, 6
`gold += (loser.fleet[+0x24] + 1)·100`; item `fleet[+0x1D]` if the player holds < 20 items.
Msgs **561** (gold + item) or **560**, then **562**.

### 11.6 Capture 0xFE26 (msgs 558, 559, 557)
- Capturable: units of the **losing main fleet** with `hull > 0` (crew may be > 0) that lie inside the
  13×12 view window at the end (origin `[0xA4FD]/[0xA4FE]`, normally centred on the player's
  flagship: x−6..x+6, y−6..y+5 clamped). `nCap` of `nAfloat`.
- Booty (to the loading UI 0x1F6A3 ❓; item codes 0x80 water, 0x81 food, 0x82 lumber, 0x83 shot, then the good):
  ```
  if fleet.good(+0x21) != 0xFF:
      amt = fleet.amount(+0x22 u16) · nCap / nAfloat
  elif rand(2) != 0 and merchant (k 1–4):
      amt = Σ shipRecord.cargo(+0x17) over the capturable ships
      if rand(10) != 0: good = 10 + rand(6)              # foodstuffs
      else:             good = 26 + rand(7); amt /= 4    # gems / precious metals
      amt /= 5
  else: amt = 0
  per = amt / nCap
  for each capturable unit:
      f = shipRecord.cargo(+0x17) − unit.shot − per
      water  += (30 + rand(5)) · f / 100        # 16-bit product
      food   += (30 + rand(5)) · f / 100
      lumber += (2 + rand(2))  · f / 100
      shot   += unit.shot
      good   += per
  ```
- Ships taken: `n = min(10 − ownShips, freeCaptains, nCap)` (free captains = player if not already a
  captain + officers with role > 2). Msg **558**, pick list, msg **559** to finish. Each (0xFCAF):
  new ship record, copy hull/maxHull/rudder/sail/guns/flags, **crew = min(oldCrew/10, record.maxCrew)**,
  cargo cleared, `+8 = 25`, `+9 = 50`, captain role 2, **morale 60**, name (msg **557**).

### 11.7 Battle experience 0xE30B → 0x1B570 ✅
```
exp += amt
while exp >= 30·min(lvl,18)² (signed): if lvl == 100: exp = 0, break ; exp −= need ; lvl++ ; ups++
if ups > 0 (once): LEAD, SEA, KNOW, INT each += min(rand(3), 100 − stat)
repeat ups times: COUR = min(100, COUR + rand(3)) ; SWORD = min(100, SWORD + rand(2))
```
Sources: §8.3/§8.4 per action (player's own fleet only) and `EH/5` at the end (even codes).

---------------------------------------------------------------------------------------------

## 12. Duel (일기토) ✅ — 0x12694, wrapper 0x128B7

State: duellists A `[0xA620]`, B `[0xA622]` (A = challenger; player is A iff he challenged),
`[0xA624] = (enemy challenged)`, history bytes `[0xA626]/[0xA627]` (start 1, `h = h<<2 | move`),
meter `[0xA538]` 0..200 (starts 100; A wins at 200, B at 0; kept between duels against the same
opponent `[0xA53A]` in one battle).

Equipment 0x1218C (struct 7 B at 0xA8FA (A) / 0xA901 (B): weapon id, armour id, weapon type, atk u16, def u16):
- Player: inventory DS:0x2D93 ×20, items with `item[+0x19] & 0x10` (equipped): category
  `+0x19 & 0xF` < 4 → weapon (last one wins), 6 → armour (`def +=`). Item table 0x8144 + 26·id,
  `+0x18` value. Raw stats; officers don't help.
- NPC: `b = min(BATLV,24)`, `n = min(NAVLV,24)`;
  weapon = `[0x0F,0x07,0x0D,0x0C,0x0E,0x0B][b == 24 ? 3 + NAVLV%3 : b>>3]`,
  armour = `[0x11,0x12,0x13,0x13][n>>3]` (def 20/30/40/40).

| type | weapons (id value) |
|---|---|
| 0 검 | 00 단도 5, 01 숏소드 10, 02 롱소드 20, 0D 바스터드소드 25, 4A 룬블레이드 40 |
| 1 스트레이트 | 03 레이피어 15, 04 에페 10, 05 에스톡 20, 0C 프람베르그 25, 4C 성기사의검 40 |
| 2 커브 | 06 숏사브르 10, 07 시미타 20, 08 일본도 25, 0F 사브르 15, 49 요도촌정 40, 4D 시바신의마검 30 |
| 3 헤비 | 09 커트라스 10, 0A 브로드소드 20, 0B 청룡언월도 30, 0E 클레이모어 25, 1A 백호반월도 25 |
| 6 갑옷 | 10 하드레더 10, 11 체인메일 20, 12 하프플레이트 30, 13 플레이트메일 40, 4B 성기사의갑옷 70, 4E 에롤즈플레이트 55 |

Turns: `for i in 0..19`: even i → A attacks, odd → B. Moves: attack 0 찌른다 / 1 벤다 / 2 친다
(msgs 1053–1055, menu title 1056 "턴 %2d : 공격"), defence 0 걷어낸다 / 1 맞받는다 / 2 비킨다
(1057–1059, 1060). After 20 attacks without a decision: no result, meter kept.

AI choice 0x10FCE: `r = rand(10)`, `move = r < lo ? 0 : r > hi ? 2 : 1`; attacking by weapon type
1 → (6,7), 2 → (2,7), 3 → (2,3), else (3,6); defending by its def: ≥60 → (6,7), ≥20 → (2,7), else (2,3).

Resolution 0x12029:
```
m = att move, pa = att previous move (history bits 2-3), d = def move, pd = def previous move
power = att.BATLV·att.SWORD/50 + att.SWORD/2                            (0x11189)
mult  = (wAtk ≥ 1 ? 50 : 0) + 25·m + (wType == m+1 ? wAtk : 0)
atk   = (((wAtk + power)·(4 − pa)) & 0xFFFF) >> 2
atk   = ((atk·mult) & 0xFFFF) / 100
ev    = 5·(2 − d) + defDef + min(def.BATLV, 20)
base  = min_u((100 − ev)·atk/100, 50)            # signed calc, unsigned min → negative becomes 50
dmg   = base + rand(att.BATLV >> 1)
X     = ((2d + 5)·(4 − pd)·2 − (defDef >> 1)) & 0xFFFF
if X >= rand(100): dmg = 0                        # dodge
meter: A attacked → min(meter + dmg, 200) ; B attacked → meter − min(dmg, meter)
```
Outcome: player challenged → target in enemy main fleet: code 6 (won) / 7 (lost); target is the
reinforcement flagship → that ship's crew = 0 whatever the result (bug). Enemy challenged → 6 / 7
from the player's view. Exp 0x1278F: win msg **1061**, `10·E.BATLV`, else `3·E.BATLV` (0x1B570);
if level-up or `E.SWORD ≥ player.SWORD`: player SWORD and COUR `+= rand(3)` (max 100).

---------------------------------------------------------------------------------------------

## 13. Related rules

### 13.1 Port guards (on entering a port building; 0x1B1CB → 0x1AF95) — not a sea battle
Not for building types 3, 5, 7, 10 or pirate ports. n = port nation (`+0x13 & 7`):
`st[n] < 80 && rand(3) == 0 && rand(100) > st[n] + 20` → msgs 839/840; escape if
`SWORD + BATLV·SWORD/100 ≥ rand(150)` (msgs 842/843); caught → 841, 845, `gold −= 3·gold/4`,
`st[n] += 20`. Else (st < 80) only msg 838.

### 13.2 Fleet "전투력" display (fleet info, msgs 922–924; 0x1CD39..0x1CF2D) 🔎
Per ship: `gunners = min(300, (100 − c[+9] − c[+8])·crew/100)` (NPC: c8 = 25, c9 = 50),
`g = min(guns, gunners)`, `power += 2·hull + g·(2·range + pow)/10 + gunners`. Display only.

---------------------------------------------------------------------------------------------

## 14. Message / menu index

| step | numbers |
|---|---|
| start | 778 none in range, 779/780 reinforcements, 781 night, 782 same nation |
| hail replies | 152–161 |
| encounter | 810–813, 814, 815/816 merchant offer, 817–819 NPC opening, 820/821 advisor, MENU 54, 822/824 flee, 825 surrender (navy), 826–829 surrender (pirates) |
| desertion | 787–790 (start), 791 |
| player move | MENU 50, 767, 768, 769 |
| attack / duel | 772, 770, 771, 1062 |
| orders | 773, 774, 1022–1050 (labels), MENU 51 info |
| pass / leave | 775, 776 |
| duel | 1053–1061 |
| result | 563, 564, 565, 566, 833, 1017 (game over), 837 + MENU 53 (log) |
| farewell | 830–832, 834–836 |
| loot / capture | 560–562, 558, 559, 557 |
| nation | 568, 569 |
| port guards | 838–845 |
| fleet info | 922–924 |

---------------------------------------------------------------------------------------------

## 15. Open questions ❓

1. **Cargo `+8`** (default 25): which UI edits it and what it is called. Combat share = `100 − c8 − c9`.
2. Wind arrow semantics (0xC2EB): the code only needs `W[]`; confirm whether `[0xA506]` is drawn as
   "blowing toward".
3. Item command in battle (0x293F1) and `0x12E5C` usable-item test not decoded.
4. Booty units (water/food booty vs cargo ×10 storage) and the loading UI 0x1F6A3 / 0x1DFB4.
5. Scenario hooks 0x32CC1/0x32C30/0x32E02/0x32D86 (event 0xA1) and 0x32D65/0x32EB6 (0xA2);
   flags `[0xD72]`, `[0xCE8]` that suppress dialogs.
6. Person `+0x31 & 0x20` (keeps an NPC fleet alive after battle) and `+0x1B & 0xC0`.
7. Bugs to decide on for the remaster (all reproduced exactly above):
   AI reachability marks source cells (§7.5); flee edge points use swapped coordinates (§9.3);
   threat/score maps ignore dead/departed enemies; merchant "surrender" (815) gives no goods;
   navy surrender keeps 2/3 of gold while the text says 2/3 is confiscated; duel vs a reinforcement
   flagship always zeroes its crew; code 6 also disbands allied reinforcements; capture depends on the
   view window; `m` multiplier goes to the first used NPC slot, not the flagship; byte wrap of
   `gunPower`/`melee` products (none overflow with stock tables).
8. Units of `+0x17` vs NPC crews: NPC crews come from fleet generation (`fleets.md`), not checked here.
