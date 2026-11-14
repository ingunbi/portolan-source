# Fleet organisation and sea commands (편성 · 지휘 · 항해 · 항구) — MAIN.EXE spec

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N, "menu N" = MENU.DAT entry N (all NUL-separated items listed).
Near calls in segments 0xFB8 / 0x1F74 / 0x2DA1 were re-resolved inside their 64 KB segment
(e.g. 항해→아이템 is 0x293F1, not capstone's 0x193F1). Everything below was read from code unless
marked **(inferred)**. Scratch disassembler used: a copy of `tools/re.py dis` that fixes near-call
wrap and annotates message numbers.

The town command table (DS:0xAE88 entries 12..15) and the sea command bar (far table DS:0xB170)
point at the **same four routines**: 정보 0x20559, 편성 0x20703, 지휘 0x207CF, 항해 0x208C7. "At sea"
versus "in port" is decided inside each routine by `[0xC3A]` (current port, 0xFF at sea).

---------------------------------------------------------------------------------------------

## 0. Shared state and helpers

### 0.1 Ship slots, dock slots, cargo records
| what | where | notes |
|---|---|---|
| ship slot s (9 B) | `0x5B4C(s)`: s < 10 → player fleet `[0xC6DA] + 0x2B + 9s`; s ≥ 10 → `DS:0x5666 + 9s` | **slots 10..39 = 30 dock slots** at DS:0x56C0..0x57CD (`0x5B3C(i)` = DS:0x56C0 + 9i) |
| slot fields | +0 crew u16, +2 hull, +3 maxHull, +4 rudder, +5 sail, +6 guns, +7 ship record #, +8 state | state `&0x30`: 0x10 in use, 0x20 under construction; `&7` cannon type |
| cargo record s (30 B) | `0x5B2C(s)` = DS:0x5210 + 30s, **s = 0..39** (40 records, last ends at 0x56C0) | one per slot, fleet and dock |

Cargo record layout (complete for this spec):

| off | type | meaning |
|---|---|---|
| +0 / +2 | u16 | water / food, in 1/10 barrel |
| +4 / +6 | u16 | lumber (자재) / shot (탄약), barrels |
| **+8** | u8 | **파수 (watch) share %** — new ship 25 |
| **+9** | u8 | **운항 (sailing) share %** — new ship 50. **갑판 (deck/combat) share = 100 − c8 − c9** |
| +0xA | u16 | load cache (0x5CA5 / 0x5C7F result) |
| +0xC / +0x16 | u16×5 / u8×5 | trade goods qty / id (0xFF empty) |
| +0x1B | u8 | **captain person id**; 0xFF none (also "deleted" marker); `port | 0x80` = docked or being built at that port |
| +0x1C | u8 | morale 0..100 |
| +0x1D | u8 | figurehead |

The three share names come from msgs 1163–1165 and 1121 (`운항/파수/갑판`), 1113 (departure table).

**Flagship (기함)** = the ship whose cargo `+0x1B == [0x1241]` (the hero), not slot 0 — see 1.1, 1.5,
battle.md 0xEE2C. Slot order is changed only by 대열변경 and by compaction 0x1FDFC.

### 0.2 Voyage flag byte `[0xF91]`
| bit | meaning | set | cleared |
|---|---|---|---|
| 0x80 | auto-sail (항구이동) active | 0x309EA / 0x30A95 | 정박 0x208B7, steering 0x20989, arrival 0x30E2A/0x30E64, landing 0x344C4/0x345CE |
| 0x40 | second auto mode ❓ (tested with 0x80 by 0x30DFA) | — | steering 0x20989 |
| 0x20 | **stopped** (정박, in port, waiting ashore) | 정박 0x208B2, port arrival 0x1B704, 기항 0x1BA46, 0x308E6, 대기 | 출항 (sea 0x208A1, landing 0x33873, harbour 0x273AF), steering 0x20989, auto-sail 0x309E5 |
| 0x08 | party ashore on ordinary land | landing 대기 0x345E3 | landing menu entry 0x3447B/0x3458B |
| 0x10 | party ashore on land chip 0x59 | same | same |
| 0x18 | party ashore at a village | village 대기 0x344C9 (sets 0x38) | same |

Effects of `0x20`: the per-tick heading routine 0x30DF9 returns 8 (no move) — the fleet stays put
while time, consumption, weather and incidents keep running. Effects of `0x18` (any landed bit):
food/water use is `crew·ration/200 + 1` instead of `/100` (0x18A6F, 0x18B21); **storm damage is
skipped entirely** (0x195B4); direction clicks are ignored (0x20A00); 항해 disables 항구이동/정박/기항.

### 0.3 Other globals
- `[0xC3F]` incidents: low nibble weather event (1 storm, 2 calm, 3 fog), **0x10 rats** (msg 473 —
  this is what RE_NOTES calls 전염병, 0x18D3C), **0x20 scurvy**, 0x80 "day not finished".
- `[0xC158]` rebuilt by the status-panel routine 0x7F00 (0x83E5): **0x80 = carries 망원경 (item 24)**,
  **0x40 = carries 고양이 (item 25)**.
- `[0xC176]` **sight range**, rebuilt by 0x7F00 (0x817B):
  `range = min(12, max over ships(crew · c8) / 100) × (telescope ? 2 : 1)`
  (the best single ship's number of lookouts, /100). Used by sighting 0x3070D as `max(range, 2)`
  (Chebyshev, no x wrap, not in fog, inside the 24×24 view, then `rand(200) < max 직감`). 0x7F00 runs
  after most commands and once a day (0x19135), so the range follows crew changes.
- `[0x1032]` storm immunity days (holy oil), −1 per day in the daily routine (0x19124); a storm can
  start only when it is 0 (0x1940A).
- `[0xA9BA]` disabled-item bitmask for the next menu (bit i = item i).

### 0.4 Helpers
| addr | does |
|---|---|
| 0x12986 | list in-use fleet slots (state 0x10) into DS:0x574, return count |
| 0x129C5 | same, minus the hero's ship |
| 0x12A10 | free slots: dock slots 10..39 first (state not 0x10/0x20), then fleet slots |
| 0x12A8E | hero + all companions (DS:0x2D57) |
| 0x12ABD | companions only |
| 0x12AE5 | hero (only if he captains no ship) + companions with status > 2 (not captains) |
| 0x12E5C | inventory items (DS:0x2D93 ×20), count |
| 0x12CF9 / 0x12D59 | other fleets within 2 tiles / on a given view cell (active, not in port, not the player) |
| 0x13E63 | pick one of the on-screen buttons laid out in DS:0xC178 (8 B each); 0xFF = cancel |
| 0x153BF | `choose(menuHeader, n)` from the DS:0x574 list; −1 = cancel |
| 0x58EA | number input `(min u32 in dx:ax, max u32 on stack)` |
| 0x13FDB | yes/no |
| 0x8EE3 / 0x8EBE | "reporter": first companion holding status 3,4,5,2,6 (resp. 4,3,5,2,6); shows the portrait |
| 0x1FD7D(a, b) | swap ship slot a ↔ b (9 B) **and** cargo record a ↔ b (30 B) |
| 0x1FDFC | compact: fleet slots 0..8 pull the next in-use slot up; dock slots 10..38 likewise, never moving state-0x20 slots |
| 0x5CDF(s) | delete ship s (see 1.5) |
| 0x1DFB4 | redraw the fleet table window |

---------------------------------------------------------------------------------------------

## 1. 편성 — menu 27, 0x20703

Menu 27: `선장변경|인사변경|승무원편성|승무원비율|함선처분|적하편성`. Jump table cs:0x1021 (0x20761).

```
loop:
  disabled = 0
  if listShips() == 0:      disabled |= 0x3D   # all but 인사변경
  if listCompanions() == 0: disabled |= 0x02   # 인사변경
  k = menu(27); if k == −1: return
  0 → 0x1E3C6   1 → 0x1E6BD   2 → 0x1E8E7   3 → 0x1ECE2
  4 → 0x1EE54, then 0x20D3 (clear sprite cache) + 0x1F7C (redraw map)
  5 → 0x1F5EF
  0x1DFB4 (redraw fleet table)
```
Works identically in port and at sea; nothing here advances time.

### 1.1 선장변경 (change captain) 0x1E3C6 → 0x1E2AE
```
loop:
  s = pick ship (0x1E242 lays out listShips(), 0x13E63)
  if cancel:
      if some in-use slot has captain == hero (0x1E363): return
      msg 226 "[원작 문장 생략]." ; continue      # cannot leave without a flagship
  p = choose(0x89, hero + companions)      ; cancel → loop
  change_captain(s, p)  0x1E2AE:
      c = cargo(s); old = person(c.1B); new = person(p)
      other = none
      if new.2E in {1 admiral, 2 captain}:
          other = cargo of the in-use slot whose .1B == p
      if other: other.1B = c.1B                 # the two ships swap captains; statuses unchanged
      else:
          if old.2E != 1: old.2E = 6            # old captain → 항해사
          if new.2E != 1: new.2E = 2            # new captain
      c.1B = p
```
- Moving the hero to another ship makes **that** ship the flagship.
- A post holder (status 3/4/5) picked here simply becomes status 2 and so loses the post. The table
  `DS:0xB050..0xB052` is only read by 인사변경, which rebuilds it from statuses on entry (0x1E12C);
  everything else finds post holders by status (0x5BE2, 0x8E58).

### 1.2 인사변경 (posts) 0x1E6BD → 0x1E5BB
Already implemented (`Officers.appoint`). Details:
```
0x1E12C: rebuild B050/B051/B052 (부선장/경리주임/수석항해사) from companions' status 3/4/5
no companions → msg 229 "동료가 없습니다."
loop: k = pick post 0..2 (0x13E63); cancel → return
  p = choose(0x89, companions)
  if p.2E == 2: msg 227 "%s([원작 문장 생략]."; return
  if p.2E in 3..5: vacate that post (B050+ (p.2E−3) = 0xFF)
  if old holder of k < 120: old.2E = 6
  p.2E = k + 3; B050+k = p
  msg 228 "%s(를) %s(로) 임명했습니다."            # post names DS:0x858: 부선장, 경리주임, 수석항해사
```

### 1.3 승무원편성 (move sailors) 0x1E8E7 → 0x1E789
A shared pool: `[0xB060]` sailors (u16), `[0xB062]` their morale. Pool starts empty.
```
pool = 0; poolMorale = 0
loop:
  show "남은 승무원" (1158) + "%5d명" (1159) pool
  s = pick ship; on cancel:
      if pool != 0: msg 231 "[원작 문장 생략]？" yes/no; no → continue
      return                                    # leftover sailors are simply lost (dismissed)
  set_crew(s)  0x1E789:
      old = slot.crew; om = cargo.1C; rec = shiprec(slot.7)
      max = umin(old + pool, rec.+0x15)          # record max crew
      msg 230 "%s[원작 문장 생략]？(0-%d)"; n = input(0..max)
      slot.crew = n; pool' = pool − n + old
      cargo.1C = n == 0 ? 0 : (old < n ? (om·old + poolMorale·(n−old)) / n : om)
      poolMorale' = pool' == 0 ? 0 : (old < n ? poolMorale
                                              : (poolMorale·pool + om·(old−n)) / pool')
```
Integer division throughout (u32 dividends). Crew may be set to 0; the harbour 출항 then refuses (4.2).

### 1.4 승무원비율 (crew roles) 0x1ECE2 → 0x1EBFF → 0x1EBCC
Per ship: three rows 운항 (c9), 파수 (c8), 갑판 (100 − c8 − c9), each shown as
`%4d명:%3d%%` (msgs 1160–1162: `crew·c9/100`, `crew·c8/100`, and the remainder `crew − both`)
with a bar; two buttons per row (layout 0x1E948: index = 2·row + col). Even index = −1 %, odd = +1 %.
```
row 0 (운항): t = (c9, c8, deck)    row 1 (파수): t = (c8, deck, c9)    row 2 (갑판): t = (deck, c9, c8)
+1: if t0 < 100: t0++; if t1 > 0: t1−− else t2−−
−1: if t0 > 0:   t0−−; t1++
write back c8, c9 (deck is implicit)
```
So 운항 trades first with 파수, 파수 with 갑판, 갑판 with 운항. Range 0..100 each, sum 100, step 1;
no cost, no confirmation, effective immediately.

What the shares do (all readers found):
- **c9 운항** — speed: `min(100, c9·crew/minCrew)` factor (0x30C2F; RE_NOTES 선속); the harbour 출항
  refuses if any ship has `crew·c9/100 == 0` (msg 57).
- **c8 파수** — sight range `[0xC176]` (0.3). Nothing else reads it.
- **갑판 = 100 − c8 − c9** — gunners and boarders in battle (battle.md unit +0x17, 0xF1D6).
- Defaults 25 / 50 come from the ship order (F9, 0x31C64) and captured ships (battle.md 11.6).

### 1.5 함선처분 (scuttle/abandon a ship) 0x1EE54 → 0x1EDE3 → 0x5CDF
```
if listShips() == 1: msg 217 "[원작 문장 생략]."; return
loop:
  list = in-use ships with !(cargo.1B & 0x80)       # 0x1ED2F: hides ships already marked
  s = pick; cancel → break
  if cargo(s).1B == hero: msg 233 "[원작 문장 생략]."; continue
  msg 234 "%s([원작 문장 생략]？" yes → 0x1EDC6: delete_ship(s); slot(s).8 = 0x10
for s in 0..9: if slot in use and cargo(s).1B == 0xFF: slot(s).8 = 0     # really free them now
```
`delete_ship(s)` 0x5CDF: ship record `+0x12 = 0xFF, +0x13 = 0, +0x14 = 0, +0x15 = 0, +0x17 = 0`;
slot `+2..+6 = 0xFF`, crew 0, `+8 = 0`; cargo water/food/lumber/shot 0, goods cleared, `+0xA = 0`;
if the captain is not the hero: captain `.2E = 6`; `.1B = 0xFF`, `.1C = 0`, `.1D = 0`;
then `+8 = 25` immediately overwritten by `+8 = 50` (source bug; `+9` was meant).
**Crew, cargo, guns and figurehead are lost; no money.** Works in port too (unlike 매각).

### 1.6 적하편성 (move cargo) 0x1F5EF → 0x1F519 → 0x1F2EB / 0x1F1FF
A pool "미적재 적하" (msg 1170) of up to 9 entries `{id, qty}`; ids 0x80 물, 0x81 식량, 0x82 자재,
0x83 탄약 (names DS:0xB084 → msgs/strings 물, 식량, 자재, 탄약), else a trade-good id (< 46).
```
pool = empty
loop:
  s = pick ship; on cancel:
      total = Σ pool qty
      msg (total == 0 ? 219 "좋습니까？" : 211 "[원작 문장 생략]？") yes/no
      yes → return  (pool contents are discarded)      no → continue
  ship view 0x1EFF8 ("%s호", msg 1171): rows = water/10, food/10, lumber, shot, then each goods slot;
            one extra empty row while rows < 9
  loop: r = pick row (0x13E63); cancel → back to ship list
     transfer 0x1F2EB(s, r):
        used = Σ ship rows; id = row id
        if row empty: pick a pool entry k (0x13E63); id = pool.id[k]; merge into the ship row with
                      the same id if one exists
        j = pool entry with the same id, else first empty pool entry; none → return (silently)
        avail = shipQty + pool.qty[j]
        max = umin(shipQty + rec.+0x17 − used, avail)     # rec.+0x17 = cargo capacity
        n = input(0..max); shipQty = n; pool.id[j] = id; pool.qty[j] = avail − n
        a goods row that reaches 0 becomes empty; a pool entry that reaches 0 becomes empty
     write back 0x1F1FF: water = 10·qty, food = 10·qty, lumber, shot, goods re-packed into
        the five holds (ids ≥ 46 dropped); cargo.+0xA = 0x5CA5(s)
```
- Units are barrels for water/food; **the write-back drops the 1/10-barrel remainder** of water and
  food on every ship where a row transfer was made.
- Moves are free and instantaneous; any ship pair, in port or at sea.
- 0x1F6A3 is the same UI started with a pre-filled pool; used by the shipyard trade-in/sale
  (0x2B1AD, 0x2B43C: cargo of the sold ship) and by the village 식량약탈 (0x342F5: pool = plundered
  food, id 0x81). Leftovers are lost there too.

---------------------------------------------------------------------------------------------

## 2. 지휘 — menu 28, 0x207CF

Menu 28: `감시|교섭|전투|대열변경|식량할당|급여설정`. Jump table cs:0x10EA (0x2082A).
```
disabled: in port → 0x07 (감시, 교섭, 전투); listShips()==0 → 0x18; no companions → 0x20
0 감시 0x1F84F (loop)        1 교섭 0x20403 → 0x1FABD (menu closes when it returns 0)
2 전투 0x20464 → 0x10D39 (menu closes)    3 대열변경 0x1FF1B    4 식량할당 0x20245
5 급여설정 0x20474 → loop{ p = choose(0x89, companions); 0x202C9(p) }
```
교섭 and 전투 are specified in fleets.md §6.3 and battle.md §4.1.

### 2.1 감시 (inspect a fleet) 0x1F84F
Pure information; no time passes.
```
loop:
  target = 0x1F748:  click a cell of the 24×24 view (0x15768); cancel → return
     if a known port (port.+0x13 & 0x10) sits on that cell: msg 1139 "제독님, 저건 %s항인데요." ; continue
     fleets on the cell (0x12D59): 0 → msg 215 "[원작 문장 생략]." ; continue
                                    1 → it; several → choose(0x8C)
  p = admiral, f = fleet(p.2C)
  flag = p.31 & 0xF; if flag == 6 (pirate): flag = p mod 6        # pirates show a fake flag
  kind = (f % 10 == 0) ? 0 : (f % 10)/5 + 1                       # menu 39: 함대 / 상선대 / 전함대
  window: "%s %s" (1140, admiral name); "<nation DS:0x866[flag]> <kind>";
          "속도:%dknot" (1141) = trunc(0x1A69E(f, wind [0xC3D], current [0xC3E]) / 2);
          "침로:%s" (1142, menu 40 heading f.1A); then every in-use ship's name, two per line
  if f / 10 == 6 and f != 60:                                     # pirate fleets 61..69
      K = max 지식 (+0x1E) of the companions (hero excluded; 0 if none)
      if rand(90) < K: msg 766 "[원작 문장 생략]."
```
The click is not filtered by fog/visibility (any fleet standing on that cell answers).

### 2.2 대열변경 (formation = slot order) 0x1FF1B
```
cur[0..9] = listShips() (rest 0xFF); n = count
n == 0 → return; n == 1 → msg 217 "[원작 문장 생략]."; return
new[] = all 0xFF; left = n
while left > 0:
   msg 218 "%d[원작 문장 생략]？" (n − left + 1); pick among ships not yet placed
   cancel: if left < n: undo the last placement (left++); else stop asking
   else new[n − left] = pick; left−−
msg 219 "좋습니까？" no → start over; yes → if new[0] != 0xFF: apply 0x1FEAF
apply: for i in 0..9 with new[i] valid and != cur[i]:
          swap_slots(cur[i], new[i]) (0x1FD7D, slot + cargo record); fix up new[] references
       compact 0x1FDFC
```
Only the order of slots changes; captains travel with their ships, so the flagship (hero's ship) is
unchanged. Order matters for: battle unit order after the flagship, which ship's stores are drawn
first when one runs dry (daily consumption), lumber use order in 응급수리, list order in all menus.

### 2.3 식량할당 (rations) 0x20245
Water `[0x2D55]`, food `[0x2D56]`, each 0..100 %, buttons 2×2 (index 0 water −1, 1 water +1,
2 food −1, 3 food +1), display `%3d%%` (DS:0xB0D8/0xB0DE) with bars. Disabled with no ships.
Effects are the known daily rules: use per ship `crew·ration/100 + 1` (÷200 ashore), morale
`v = 100 − 통솔/5 − ration` (RE_NOTES 하루 정산).

### 2.4 급여설정 (officer pay) 0x202C9(p)
```
k = index of p in DS:0x2D57
if p.loyalty (+0x2B) >= 80: portrait; msg 220 "[원작 문장 생략]."; return
cur = 10 · DS:0x2D75[k]                              # gold per month
speaker = 0x8EBE (경리주임 first, then 3,5,2,6)
msg (speaker == p ? 221 "[원작 문장 생략]？")
show "（%d～2000）" (DS:0xB0EB) with cur
loop: v = input(0..2000)
      if v < cur: msg 224 "[원작 문장 생략]."; retry       # pay can only go up
msg 223 "감사합니다."
p.loyalty = umin(100, p.loyalty + (v − cur) / 5)
DS:0x2D75[k] = v / 10
```
- Pay range: current .. 2000 gold (byte 0..200). Loyalty gain is computed from the untruncated v:
  raising by 5–9 gold gives +1–1 loyalty while the stored byte does not change (free loyalty up to 80).
- Pay matters elsewhere: monthly `loyalty += 2·pay/10 − max ability + admiral 통솔` (0x18864) and the
  harbour desertion check (4.1: pay < 190 gold, loyalty < 30).

---------------------------------------------------------------------------------------------

## 3. 항해 — menu 29 / 46, 0x208C7

Menu 29 `항구이동|정박|기항|상륙|아이템|기능`; while stopped (`[0xF91] & 0x20`) menu 46
`항구이동|출항|기항|상륙|아이템|기능` is loaded instead (same handlers). Jump table cs:0x11F8.
```
disabled: landed (&0x18) → 0x07; in port → 0x0F; no items → 0x10
0 항구이동 0x309F7   1 정박/출항 0x2087A   2 기항 0x1B951   3 상륙 0x34651     → menu closes
4 아이템 0x293F1 → menu stays open      5 기능 0x20F8E → closes only after a successful 로드
loop also ends when [0x426] != 0 (scene change / game over)
```

### 3.1 항구이동 (auto-sail) 0x309F7
Needs a 부선장 with 측량술 (`0x5BE2(3)` → person `+0x30 & 0x10`); else msg 855/856 (by speaker's
speech flag). Pick a known port (0x12DCE list, menu 0x85), then `[0xF91] = ([0xF91] & ~0x20) | 0x80`.
Arrival calls 기항 0x1B951 automatically (0x30E20). Implemented in the remaster.

### 3.2 정박 / 출항 (stop / resume) 0x2087A
```
if [0xF91] & 0x20: msg 1149 "이동하겠습니다."; [0xF91] &= ~0x20              # 출항 (menu 46)
else:              msg 1150 "정선하겠습니다."; [0xF91] |= 0x20; [0xF91] &= ~0x80   # 정박
```
No other state. While stopped the heading routine returns 8: no movement. Everything else (ticks,
daily consumption, morale, weather, incidents, NPC fleets, encounters) continues — the only readers
of bit 0x20 are this toggle (0x20890) and the heading routine (0x30E01). A direction click
(0x20985) also clears 0x20 and 0x80 and sets the heading.

### 3.3 기항 (call at port) 0x1B951
Ports are land; you must stop next to one and call.
```
build the window origin as for the local 96×96 map (block of the fleet, clamped 0..27 / 0..42)
for (dx, dy) in DS:0xAF38 = (−1,−2) (0,−2) (1,−2) (−2,−1) (−2,0) (−2,1) (2,−1) (2,0) (2,1) (−1,2) (0,2) (1,2):
   cell = localmap[fleet + (dx,dy)]                    # the ring just outside the fleet's 2×2 footprint
   if cell == 0x74 or 0x78:                            # port / supply-port corner chip
       [0xC3A] = port whose (x,y) == fleet + (dx,dy)   (0x1B51E)
       msg 365 "%s[원작 문장 생략]？"  no → [0xC3A] = 0xFF; return
       [0xF91] |= 0x20; log 0x1DC0F(port, days [0x2D54]); arrival 0x1B6EE (exp, etc.); town 0x8AB2
```
Nothing found → silently nothing. (The loop keeps scanning the remaining offsets after returning
from town ❓.)

### 3.4 상륙 (landing) 0x34651 → 0x344DE
```
if [0xF91] & 0x18: goto landed_menu            # already ashore: no prompt, no direction
buttons for the 8 tiles bordering the fleet's 2×2 footprint: dx (DS:0xBCC4) 0,1,2,2,1,0,−1,−1;
   dy (DS:0xBCD4) −1,−1,0,1,2,2,1,0 — a side is offered only if it stays inside the 24×24 view
pick one (0x1338A); cancel → return
[0x8142] = discovery site covering that tile (0x343DD) or 0xFF
chip = localmap[tile]
  0x41, 0x49, 0x51 (latitude land chips) → [0xBC84] = 1, landed_menu
  0x59                                    → [0xBC84] = 0, landed_menu
  0x74..0x7B (port corners)               → 기항 0x1B951
  0x7C..0x7F (site / village chips)       → landed_menu ([0xBC84] keeps 1)
  ≥ 0x80                                  → nothing
  other (< 0x74)                          → msg 441 "[원작 문장 생략]."
landed_menu 0x344DE:
  if not already ashore: msg (site active ? 439 "부락에 " : "") + 440 "[원작 문장 생략]？"
                         no → [0x8142] = 0xFF; return
  [0xBC86] = (hero luck · [0xBC84] > rand(100))       # water roll, re-rolled on every entry
  if site and site active (!(+6 & 0x80)): village menu 35 (0x34456; town.md §10.1)
  else: [0xF91] &= ~0x18; menu 36 loop (cannot be cancelled):
```
Menu 36 `출항|응급수리|탐색|대기`:

**출항 0x33858** — msg 417 "[원작 문장 생략]？"; yes → `[0xF91] &= ~0x20`, menu closes.

**응급수리 (emergency repair) 0x33CD7 → 0x33B47**
```
loop: s = choose(0x8A, ships); cancel → fleet_recompute 0x17C7D; return
  if hull == maxHull and rudder == class.rudder and sail == class.sail:
      msg 418 "[원작 문장 생략]."; continue
  window: 내구 hull/maxHull, 선회 rudder/class, 추진 sail/class (bars)
  loop: part = pick 0..2; cancel → back
     L = Σ lumber (cargo +4) over all in-use ships;  L == 0 → msg 419 "자재가 없습니다."
     need = [maxHull − hull, class.rudder − rudder, class.sail − sail][part]
     need == 0 → msg 420 "[원작 문장 생략]."
     n = input(0 .. umin(L, (need + 4) / 5))  msg 421 "[원작 문장 생략]？\n(0-%d)"
     take n lumber from ships in slot order (0x33AEE)
     part 0: hull = umin(maxHull, hull + 5n); 1: rudder = umin(class.rudder, rudder + 5n);
     part 2: sail = umin(class.sail, sail + 5n)
```
**1 lumber = 5 points**; maxHull itself is never raised (storms lower it; the shipyard repair also
only refills hull up to maxHull). No time passes.

**탐색 (search) 0x33ED0**
```
if [0x8142] != 0xFF and (site.+6 & 0xF0) == 0xA0:        # inactive relic site whose map you hold, not taken
    msg 431 "%s(를) 발견했습니다." (item site.+4)
    inventory slot holding item (site.+4 − 10) (the treasure map) := site.+4 (the relic)
    site.+6 |= 0x10
else water 0x33E08:
    if [0xBC84] == 0: msg 424 "[원작 문장 생략]？" no → return
    if [0xBC86] == 0: msg 425 "[원작 문장 생략]."; return
    msg 426 "[원작 문장 생략]."
    loop 0x33D4E: s = choose(0x8B, ships); cancel → return
       free = rec.+0x17 − cargoLoad(s); free == 0 → msg 422 "[원작 문장 생략]."
       n = input(0..free) msg 423 "%s[원작 문장 생략]？(0-%d)"
       water = (water/10 + n) · 10                         # free; rounds the old stock down to barrels
```
Water chance = hero luck % on ordinary land, 0 on chip-0x59 land (after the warning). The roll is
made once per landing-menu entry, so 대기 → 상륙 re-rolls it. The relic needs the landing tile to be
on the site's 2×2 cells; if the map is not in the inventory the relic is lost but the site is marked.

**대기 (stay ashore)** — `[0xF91] &= ~0x80; [0xF91] |= 0x20 | ([0xBC84] ? 0x08 : 0x10)`; menu
closes. The fleet waits with the party ashore (0.2 effects). 항해→상륙 returns straight to menu 36.

### 3.5 아이템 0x293F1
Loop: pick an item (choose 0x8D, inventory), info box 0x28E37, menu 33 `장비|사용`:
장비 → 0x28E75 (town.md §9.1), 사용 → 0x2939A by type (item `+0x19 & 0xF`). Also reachable from the
battle menu (0xB543).

| type | items | 사용 |
|---|---|---|
| 0–6 | weapons, shields, armour | "무기는,/방패는,/방어 무기는,/갑옷은," + msg 1098 "[원작 문장 생략]." |
| 7 | 20 사분의, 21 육분의, 22 경위의 | position fix 0x29244 (below) |
| 8 | 23 회중시계 | msg 1099 "%d시" (`tick/3`) + msg 1100 "%d0분" (`(tick%3)·2`, only if non-zero) |
| 8 | 24 망원경 | msg 1101 "먼 곳이 보인다." only; **its effect is passive** (×2 sight range, 0.3) |
| 8 | 25 고양이 | msg 1102 "야옹∼" only; **passive: rats cannot start** while carried (0x18D55) |
| 8 | 26–28, 29–40 licences | msg 1097 "이 아이템은, " + 1098 |
| 9 | 41 쥐약 | if rats (`[0xC3F] & 0x10`): clear, msg 1103; else 1104. **Consumed either way** |
| 9 | 42 성스런 향유 | if storm (`[0xC3F] & 0xF == 1`): low nibble = 0, weather redraw 0x19150, msg 1106 (tick 12..59) / 1105; else 1107. Then `[0x1032] = rand(6) + 10` (**10–15 days without storms**). Consumed |
| 9 | 43 라임 주스 | if scurvy (`& 0x20`): clear, msg 1108; else 1109 "맛있다." Consumed |
| 12 | 80–89 treasure maps | 0x1D6EF: shows the chart region around site `item.+0x18` |
| other | gifts, jewellery, relics | 1097 + 1098 |

**Position fix 0x29244** (instrument power p = item `+0x18`: 사분의 5, 육분의 2, 경위의 1):
```
in port → msg 756 "[원작 문장 생략]."
err = 0
if hero lacks 측량술 (+0x30 & 0x10):
    msg 757 "[원작 문장 생략]."
    loop choose(0x89, companions): lacks skill → msg 755 "[원작 문장 생략]."
    cancelled → the hero guesses: msg 758+760 (hero +0x31 & 0x10) or 759+761; err = rand(100) + 1
lat = 640 − y;      latDeg = (|lat|·8 / (57p)) · p        → msg 126 "북위 %d도, " / 127 "남위" (lat < 0)
lon = (x + 1981) mod 2160; west = lon > 1080; if west: lon = 2160 − lon
lonDeg = (lon / (6p)) · p                                 → msg 128 "동경 %d도" / 129 "서경"
printed values: latDeg + err, lonDeg + err
```
(The "기능" item of this menu is **not** a skill command; see 3.6. Surveying is done with the
instruments above; 0x24D58 is the rumour formatter used by taverns/NPCs.)

### 3.6 기능 = system menu (menu 20) 0x20F8E
`환경|저장|로드|중단`: 환경 0x20E97 (options; music restart if `[0xC30]` bit 0x80 flipped),
저장 0x1680C(0) (in port first `[0xC3B] = 0x82`), 로드 0x1680C(1) (on success sets date bytes
`[0x56F..0x571] = 0xF0` and closes 항해), 중단 0x20F50.

---------------------------------------------------------------------------------------------

## 4. 항구 (harbour office, building 3) 0x280A3

Supply ports (`100 ≤ [0xC3A] < 130`) go to 0x2802C (4.4). Market ports:

### 4.1 On entering
1. Port guards / blockade setup when the hour is ≤ 18 or ≥ 54 ticks, `rand(3)==0`, port nation < 6
   and the nation's flag byte `+0x12+group & 0x10` (war.md; not repeated here).
2. **Desertion check** — for each person q in 0x12AE5 (non-captain companions, status 3–6):
   ```
   if q.loyalty < 30 and rand(4 − (q.2F & 3)) == 0 and pay(q) < 19 (i.e. < 190 gold):
       q: msg 798 "[원작 문장 생략]."
       reporter == q ? msg 800 "[원작 문장 생략]？"
       yes → msg 801 "[원작 문장 생략]." ((pay+1)·10)
             yes → pay += 1 (10 gold), loyalty = 30
       any no → dismiss 0x27F0B: companion slot = 0xFF, pay 0, q.2E = 0, q.2C = 0xFF, q.2D = this port
   ```
3. Bounty rumour once (`[0xCEE] & 3`, not `& 4`, `[0xCEA] == 0`, port nation == hero nation):
   msgs 409 + (410 + nation) + 416; `[0xCEE] |= 2`.
4. Greeting msg 56 "[원작 문장 생략]？" (skipped during scripted states `[0xD72]`, `[0xCE8]`).

### 4.2 Menu 9 `출항|보급|도크`, far table DS:0xB6AC
Disabled: no ships → 출항, 보급; **도크 only in the six capitals** (0x1ADEC: port == nation record
`+0xA` for nations 0..5: 리스본, 세빌리아, 이스탄불, 런던, 제노바, 암스테르담).

**출항 0x273DA → 0x27176** (departure check):
```
table (1113/1114): per ship  name, 운항 crew·c9/100, 파수 crew·c8/100, 갑판 rest,
                   load % = 100·cargoLoad / rec.+0x17, water/10, food/10
if any ship has 운항 crew == 0: msg 57 "[원작 문장 생략]."; stay
days = umin(Σwater, Σfood) / max(1, Σcrew)          # record units, i.e. days at full ration
days == 0 → msg 59 "[원작 문장 생략]."; stay
10 ≤ days ≤ 180 → msg 61 "[원작 문장 생략]？"
days > 180 → msg 58 "６[원작 문장 생략]？";  1..9 → msg 60
yes: log 0x1DC0F; [0x2D54] = 0; heading = 8 (none, until the player steers); 0x4FA5;
     [0xF91] &= ~0x20; 0x18BCC, 0x18C85, 0x837D (not decoded); [0xC3B] = 0xFF
no: harbour picture redrawn (0x8D04(3)); no time passes
```
**보급 0x277AA**: grid ship × {물, 식량, 자재, 포탄} plus a load/unload toggle button.
Load = 0x273FA (RE_NOTES 보급). **Unload 0x2758D**: msg 1115 "[원작 문장 생략]？(0-%ld)",
max = current barrels (water/10, food/10, lumber, shot); subtracts `10n` / `n`; no refund.

### 4.3 도크 (dock) 0x27E2A — menu 8 `보관|배비|교환`, far table DS:0xB694
State refresh 0x27954 (before every command):
```
[0xB686] = ships in fleet; [0xB688] = umin(1 + companions, 10)        # possible captains
stored list = dock slots 10..39 with state 0x10 and cargo.1B == port | 0x80   → [0xB68A] = count
capacity [0xB68C] = stored + free dock slots (state not 0x10/0x20), counted up to 5
```
Header "도크보관 선박" (1118) with the stored ships (`%s호`), then msg 276 "[원작 문장 생략]
있소." / 277 "[원작 문장 생략]." (capacity).
**Per capital at most 5 ships; the 30 dock slots are shared by all capitals and by ships on order
(0x12A10 hands out dock slots first).** No fees anywhere in the dock.

**보관 (store) 0x27A4D**
```
no ships → return; candidates = ships except the hero's (0x129C5); none → msg 279 "기함밖에 없습니다."
stored == capacity → msg 288 "[원작 문장 생략]."
loop: msg 280 "어느 것을 맡길까요？"; s = choose; cancel → return; show ship (0x2A8C4, 0x2AAAD)
      crew > 0 ? msg 281 "[원작 문장 생략]？" : msg 201 "이 배로 하겠소？"; no → loop
      d = free dock slot list[stored]; swap_slots(s, d)
      both records: morale 0, crew 0                 # the crew is dismissed
      captain.2E = 6 (back to 항해사); cargo(d).1B = port | 0x80; cargo(s).1B = 0xFF
      msg 282 "그럼, 맡아 두겠습니다."
```
Cargo, guns, hull state and figurehead stay with the stored ship.

**배비 (bring out) 0x27B8C**
```
stored == 0 → msg 283 "[원작 문장 생략]."
ships == [0xB688] → msg 285 "[원작 문장 생략]."        # also blocks a 10-ship fleet
loop: msg 284 "[원작 문장 생략]？"; d = pick stored; show; msg 201 yes/no
      k = first free fleet slot; swap_slots(k, d)
      morale 0, crew 0 on both records                 # the ship comes out empty
      captain = first of 0x12AE5 (a non-captain companion, or the hero if he has no ship); .2E = 2
      msg 286 "[원작 문장 생략]."                 # "we'll tow it out"
```
**교환 (exchange) 0x27CCE**
```
no ships → return; stored == 0 → msg 283
loop: msg 280; f = choose fleet ship (any, flagship included); show
      msg 284; d = pick stored ship; show
      m = shiprec(d).+0x15 (max crew)
      crew(f) > m ? msg 281 with crew(f) − m : msg 201; no → loop
      swap_slots(f, d)
      fleet record: morale = old ship's morale, crew = umin(old crew, m), captain = old captain
      dock record: morale 0, crew 0, .1B = port | 0x80
      msg 287 "[원작 문장 생략]."
```
Each ship keeps its own cargo (cargo does not move across). After every dock command: 0x1AF54 and
compaction 0x1FDFC; on leaving the dock: 0x19150, harbour picture 0x8D04(3), msg 56.

### 4.4 Supply-port harbour 0x2802C — menu 57 `출항|보급|명명`, far table DS:0xB6A0
출항 0x273DA and 보급 0x277AA as above (no dock, no desertion check). **명명 (name the port)
0x27F59**: msg 926 "[원작 문장 생략]！", text input of up
to 7 characters (0x2FE73, al = 7) into the port record name (+4); cancelled → old name restored;
same name as any other of the 130 ports → restored + msg 927 "[원작 문장 생략]
이름을 붙여 주시오."; else msg 928 "%s！\n[원작 문장 생략]."

---------------------------------------------------------------------------------------------

## 5. Message index
| msgs | where |
|---|---|
| 56–61 | harbour greeting, departure estimate |
| 201, 276–288 | dock |
| 211, 219, 1170, 1171 | 적하편성 |
| 215, 766, 1139–1142 | 감시 |
| 217, 233, 234 | 함선처분 / 대열변경 |
| 218, 219 | 대열변경 |
| 220–224 | 급여설정 |
| 225 | 교섭 (none in range) |
| 226 | 선장변경 |
| 227–229 | 인사변경 |
| 230, 231, 1158, 1159 | 승무원편성 |
| 365 | 기항 |
| 409, 410+n, 416 | harbour bounty rumour |
| 417–426, 431, 439–441 | landing (출항, 응급수리, 탐색, prompt, refusal) |
| 755–761, 126–129 | instruments |
| 798–801 | harbour desertion |
| 855, 856 | 항구이동 refusal |
| 926–928 | 명명 |
| 1093–1109 | item use |
| 1113–1116 | departure table, unload |
| 1118–1124 | dock list and ship info box (`운항/파수/갑판`, `운항요원`) |
| 1149, 1150 | 정박 / 출항 |
| 1160–1165 | 승무원비율 |

## 6. Remaster gaps seen in Sources/PortolanCore (for planning)
- `Ship` has `sailorShare` (c9) but no watch share (c8); `Discovery.lookAround` sights with a fixed
  2-tile box (its second clause repeats `dx <= 2 && dy <= 2`) instead of `max([0xC176], 2)` with the
  lookout/telescope formula of 0.3.
- Captains are implicit (officer `i−1` commands ship `i`, flagship = ship 0); the original stores a
  captain per ship (+0x1B) and lets the hero command any ship (1.1).
- `epidemic` in `Voyage` is the original's rats incident (`[0xC3F] & 0x10`, msg 473): a carried cat
  prevents it, 쥐약 ends it. Scurvy ends with 라임 주스; 성스런 향유 stops a storm and blocks new ones.
- Missing: crew pool moves, share editing, scuttling, cargo pool moves, 감시, 대열변경, pay raises and
  harbour desertion, 정박 state, explicit 기항, non-village landing (repair, water, relics, waiting
  ashore with halved consumption and no storm damage), item use at sea, instruments, dock,
  harbour unload, supply-port naming.

## 7. Open questions ❓
1. `[0xF91]` bit 0x40 (tested together with 0x80 by 0x30DFA): a second auto-sail mode, writer not traced.
2. Land chip 0x59 (sets `[0xBC84] = 0`: no water, warning 424): which terrain (desert/ice?) the
   local-map builder (0x22897, 0x229C3) assigns it to.
3. 0x58EA on cancel: what 급여설정's "v < cur → retry" loop does when the input is cancelled.
4. 기항 keeps scanning the remaining ring offsets after the town routine 0x8AB2 returns.
5. 0x1D6EF (treasure-map view) layout was not decoded beyond reading the site from item `+0x18`.
6. Ships on order may sit in dock slots (state 0x20, `.1B = port|0x80`) and reduce a capital's dock
   capacity; confirm with the shipyard order path (0x2B0FF, 0x2B740, 0x2B781).
7. 0x5CDF writes cargo `+8` twice (25, then 50); probably `+9 = 50` was intended. Harmless, since a
   new ship re-initialises both.
