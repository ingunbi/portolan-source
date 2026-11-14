# Sea events — MONSTER.DAT (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image
0x378B0 + n; "msg N" = MESSAGE.DAT line N (`assets/text.json["message"]`). Helpers: `umin`/`umax`
0x4D42/0x4D49 (unsigned 16-bit), `rand` 0x4D86 (**not used anywhere below**), `say(msg, …)`
0x32F2C, wait key 0x140EA, close windows 0x780F, person `p(i)` = DS:0x1242 + 50i (0x5AEC),
ship slot `slot(s)` = `[0xC6DA]` + 0x2B + 9s (0x5B4C, s < 10), cargo `cargo(s)` = DS:0x5210 + 30s
(0x5B2C). `[0xC6DA]` = player fleet, `[0xC67A]` = player person, `[0x1241]` = hero person index.
Marks: ✅ read in full · 🔎 read, some details skipped · ❓ not decoded.

**Headline.** There are 10 invisible one-tile "monster" points active at a time. Every tick at
sea, after the player's fleet has moved, the game compares the fleet's tile with the 10 points;
on an exact match the point is consumed, one of 10 fixed effects is applied **without any random
roll or condition**, an alarm plays and three text boxes are shown, and the next record of
MONSTER.DAT takes the empty slot. The 10 starting points live in the new-game data segment
(DATA1[15]); MONSTER.DAT adds 30 more, so **a game has at most 40 sea events**, in a fixed order.
No picture, palette effect, portrait, log entry or battle is involved. Type 7 is never placed.

---------------------------------------------------------------------------------------------

## 1. When it runs ✅

Day loop 0x1AC8F (fleets.md §1), one iteration per tick at sea:
```
0x1ABA7: at sea → 0x1AC59: commands 0x20AEA, NPC fleets per tick 0x1A9BD,
                            player move 0x310AD (one step), [0x571] += 1
fleet_daily for fleets k in t .. [0x571]-1
if [0x426] == 0 (no quit/ending) and [0xC3A] == 0xFF (at sea):      ; 0x1AD17
    0x6BA2 (draw fleets); 0x3070D                                    ; call at 0x1AD2A
```
0x3070D (the 0x30731 named in sprites.md §8 is its slot loop):
```
if [0xC3A] != 0xFF: return
range = umax([0xC176], 2)                       ; only for the sighting part
for i in 0..9:                                  ; 0x30731
    if fleet.x == X[i] and fleet.y == Y[i]:     ; fleet = [0xC6DA], words +0 / +2
        event(i); return                        ; §3 — sighting is skipped this tick
sighting of ports / villages                    ; 0x307E7.., commands.md §0.3, town.md §10
```
- **Once per tick at sea, after the player's one-step move.** Nothing else calls 0x3070D.
- **No other gate**: not weather (storm / calm / fog), not time of day, not sails furled or
  anchored, not landing, not sight range, telescope, skills, items, hero or story flags. Fog and
  `range` only affect the port/village sighting in the second half of the routine.
- Only the player fleet is tested; NPC fleets never trigger or consume points.

## 2. State ✅

| DS | type | meaning |
|---|---|---|
| 0xF9E + 4i | u16 | point i x (world tile 0..2159, same units as fleet `+0`) |
| 0xFA0 + 4i | u16 | point i y (0..1079, fleet `+2`) |
| 0xFC6 + i | u8 | point i type 0..9 |
| 0xFD0 | u8 | next MONSTER.DAT record to load |

- **New game**: DS:0xC30.. is overwritten with DATA1[15] (newgame.md), which holds the 10 points
  of §6.1 and `[0xFD0] = 0`. Nothing else initialises them: the only code references to
  0xF9E/0xFA0/0xFC6/0xFD0 are inside 0x3070D, and the scenario VM reaches DS only through its
  record tables (scenario.md §4.5), none of which covers this range. Same for all six heroes.
- **Saved**: the range lies inside the saved block DS:0xC30..0x8B6B, i.e. KOUKAI2.DAT slot offsets
  0x405..0x437 (`n − 0xB99`). The remaster's `assets/ds.bin` already contains the initial bytes.
- The points are **never drawn** (no reader besides 0x3070D) and have no sighting distance.

## 3. Trigger and refill — 0x30731..0x307E4 ✅

```
event(i):
    X[i] = Y[i] = 0                                  ; 0x3076A
    present(T[i])                                    ; 0x305DE, §4 (effect + messages)
    fd = open("C:MONSTER.DAT")                       ; DS:0xA32, 0x15908 (missing → "File Not %s", quit)
    lseek(fd, 5·[0xFD0], 0)                          ; 0xAA
    read(fd, &X[i]/&Y[i], 4); read(fd, &T[i], 1)     ; 0x44, x u16le, y u16le, type
    close(fd); [0xFD0] += 1                          ; 0x30, 0x307E0
```
- **"Stands on"** = exact equality of the fleet record's x and y words (the top-left tile of the
  fleet's 2×2 footprint, the same coordinate `blocked(x,y)` 0x30AA0 tests) with the point. The
  mover 0x30E6E changes each axis by at most ±1 per tick, so every tile on the track is visited
  once; a point is hit only if the track crosses that exact tile (no radius, no x wrap needed).
- Only the first matching slot fires; a new point is read **after** the event's windows close,
  into the slot just used. Record k therefore becomes active after the (k+1)-th event.
- MONSTER.DAT is 200 bytes = 40 records; records 30..39 are all zero. Loading one gives a dead
  slot (0,0) — tile (0,0) is land, never reachable. Hence exactly **40 possible events per game**
  (10 built-in + 30), `[0xFD0]` ≤ 40, never reads past EOF, never wraps.
- The event uses no game time (the day loop continues with the next tick).

## 4. Presentation — 0x305DE(al = type) ✅

```
hide cursor (0x4EA9)
r = far call DS:0xBB58[type]()           ; handler applies the effect FIRST (§5)
if r == 0: show cursor; return           ; consumed silently: no sound, no text
save text cursor [0x8B74],[0x8B76]
repeat 2:                                ; alarm, ≈ 0.50 s on / 0.33 s off / 0.50 s on
    0x95BE(DS:0xBCC)  effect voice  (driver AH 5)
    0x965A(0x30)      effect note 0x30 (AH 6; only if [0x420] driver and option [0xC30] & 8)
    0x5958(30)        30 timer ticks (60.3 Hz)
    0x96DE            mute effect channel
    (first pass only) 0x5958(20)
window 0x3024A; say(1176); wait key; close        ; "[원작 문장 생략]."
for k in 0, 1:
    window 0x3024A; say(510 + 2·type + k); wait key; close
restore text cursor; 0x7F00 (status panel + sight range); 0x96DE; show cursor
```
- Handler table DS:0xBB58, 10 far pointers into segment 0x2DA1 (§5); no bounds check (types in
  the data are 0..9).
- 0x3024A = `0x76EB(ax=0x10, dx=0xA0, bx=0x24, 0, 0x80)`, a plain text window with no portrait;
  its only other user is the port/village sighting report 0x30260. Exact geometry 🔎.
- Effect voice DS:0xBCC (22 bytes, format music.md §5.2):
  `00 00 00 00 00 08 00 F0 F0 00 04 F5 10 27 02 9C 0F 81 00 00 02 01` — sine FM pair (mult 0,
  modulator TL 8, carrier TL 0, AR 15, sustain), transpose −11, LFO on: triangle, speed 0x2710,
  pitch depth −100/127 over range index 15, amplitude depth −127, delay 2 — a warbling alarm.
  Used only here (the storm uses DS:0xBE2, the village search DS:0xBA0). Rendered as
  `assets/sfx/sea_event.wav` (sfx.md).
- No picture, no palette change, no screen shake, no voyage-log entry, no battle.

## 5. The ten events ✅

| t | handler | msgs | text (short) | effect | silent when |
|---|---|---|---|---|---|
| 0 | 0x30343 | 510 / 511 | 세이렌: 노랫소리 → 많은 선원이 바다에 빠짐 | every ship: crew −25 % | never |
| 1 | 0x30350 | 512 / 513 | 거대한 눈과 촉수 → 피해는 없으나 공포 | hero + every companion: 용기 −10 | never |
| 2 | 0x303A3 | 514 / 515 | 짙은 안개, 삭구 소리 → 요함 1척이 사라짐 | last non-hero ship vanishes | only the hero's ship |
| 3 | 0x30407 | 516 / 517 | 가오리 요괴 → 선원이 돛대를 물려 쫓아냄 | nothing | never |
| 4 | 0x3040B | 518 / 519 | 돛대 끝의 청백색 인광 → 힘을 얻음 | every ship: morale +10 | never |
| 5 | 0x30463 | 520 / 521 | 불을 뿜는 새 → 맨 뒤 배의 돛대가 탐 | last non-hero ship: 추진 halved | only the hero's ship |
| 6 | 0x304B4 | 522 / 523 | 거대한 용, 폭풍 → 모든 적하를 버림 | every ship: all trade goods lost | never |
| 7 | 0x30518 | 524 / 525 | 용이 선미를 가로지름 → 선원들이 불행을 저주 | every ship: morale −10 | never (**not placed**) |
| 8 | 0x30568 | 526 / 527 | 거대한 고래떼 → 맨 뒤 배에 부딪힘 | last non-hero ship: 내구 halved | only the hero's ship |
| 9 | 0x305C2 | 528 / 529 | 유령선, 한맺힌 흐느낌 | hero 운 −30 | never |

Full message texts (msg 1176 comes first in every case):

| msg | text |
|---|---|
| 510 | [원작 문장 생략]. |
| 511 | [원작 문장 생략]. |
| 512 | [원작 문장 생략]. |
| 513 | [원작 문장 생략]. |
| 514 | [원작 문장 생략]. |
| 515 | [원작 문장 생략]. |
| 516 | [원작 문장 생략]. |
| 517 | [원작 문장 생략]. |
| 518 | [원작 문장 생략]. |
| 519 | [원작 문장 생략]. |
| 520 | [원작 문장 생략]. |
| 521 | [원작 문장 생략]. |
| 522 | [원작 문장 생략]. |
| 523 | [원작 문장 생략]. |
| 524 | [원작 문장 생략]. |
| 525 | [원작 문장 생략]. |
| 526 | [원작 문장 생략]！ |
| 527 | [원작 문장 생략]. |
| 528 | [원작 문장 생략].  |
| 529 | [원작 문장 생략]. |

### 5.1 Handlers (pseudocode) ✅

"in use" = `slot(s).+8 & 0x30 == 0x10` (ships under construction, 0x20, and dock slots are never
touched). All arithmetic on bytes; `−= umin(v, n)` floors at 0.

```
0  0x30343: crew_loss(pct = 25, report = 0)          ; 0x34096
       for s in 0..9 in use: lost = (pct·crew) / 100 (16-bit signed, truncating); crew −= lost
       (with report ≠ 0 it would print msg 427 "[원작 문장 생략]." — type 0 passes 0)
       return 1
1  0x30350: for p in list 0x12A8E (hero [0x1241], then companions DS:0x2D57 ≠ 0xFF):
                p.+0x20 (용기) −= umin(p.+0x20, 10)
       return 1
2  0x303A3: s = last_other()                          ; see below
       if none: return 0
       slot(s).+8 &= ~0x10                            ; slot is free; crew, guns, cargo bytes left as they were
       p(cargo(s).+0x1B).+0x2E = 6                    ; captain stays a companion, now plain 항해사
       cargo(s).+0x1B = 0xFF
       return 1
3  0x30407: return 1
4  0x3040B: for s in list 0x12986 (in-use slots): cargo(s).+0x1C (morale) += umin(10, 100 − morale)
       return 1
5  0x30463: s = last_other(); if none: return 0
       slot(s).+5 (추진) >>= 1; return 1
6  0x304B4: for s in 0..9 in use: for k in 0..4: cargo(s).+0x16+k = 0xFF, cargo(s).+0xC+2k = 0
                0x1957C (recompute load 0x5C7F for every in-use ship)
       water, food, lumber, shot and cannons are kept; return 1 (also with an empty hold)
7  0x30518: for s in 0..9 in use: cargo(s).+0x1C −= umin(morale, 10); return 1
8  0x30568: s = last_other(); if none: return 0
       slot(s).+2 (내구) >>= 1; 0x17C7D(fleet)  (strength +0x28 = (Σ hull + 4)/5); return 1
9  0x305C2: p([0xC67A]).+0x23 (운) −= umin(운, 30); return 1

last_other(): for s = 9 down to 0: if in use and cargo(s).+0x1B != [0x1241]: return s
              return none                      ; = the hindmost ship not commanded by the hero
```
- **No `rand`, no conditions**: no check of hero, nation, items (holy oil, cat, …), skills,
  abilities, weather, or ship type. Every visit to a point has the same outcome.
- Silent cases: types 2, 5, 8 when the hero's ship is the only ship in use. The point is still
  consumed and replaced (§3).
- Ability use elsewhere: 용기 (+0x20) appears in the treat-a-drink praise check
  (tavern_more.md) and the 포술 school requirement 용기 ≥ 80 (town.md); 운 (+0x23) drives flight,
  boarding/duel, storms, rats/scurvy, tavern rolls (battle.md, RE_NOTES, tavern_jobs.md).
  Morale feeds desertion (RE_NOTES 바다의 사건). 추진 and 내구 are restored by shipyard repair.

### 5.2 Source quirks 🔎

1. Type 2 only clears the in-use bit. Unlike `delete_ship` 0x5CDF (commands.md §1.5) it does not
   free the ship record (`+0x12` stays ≠ 0xFF; 0x31C64 allocates records by `+0x12 == 0xFF`), so
   one of the 40 ship records leaks per type-2 event. Crew and cargo bytes stay in the free slot
   (the next ship order re-initialises them). No compaction (a free slot can sit below the hero's
   slot), no strength recompute 0x17C7D, and a generic (단역) captain is demoted, not removed.
2. Type 2 assumes the ship has a captain; with `.1B = 0xFF` it would write `p(255).+0x2E`
   (inside the fleet records). Cannot happen through normal play.
3. Type 8 can leave a ship at 내구 0 (from 1). It is not sunk here; what happens to a 0-hull ship
   outside a storm or battle was not traced ❓.
4. Type 0 multiplies in 16 bits: correct for crews up to 1310 per ship.
5. Messages 524/525 and handler 7 are never reached in the original data (§6).

## 6. The points ✅

Types: 0 세이렌, 1 거대한 눈, 2 안개(배 실종), 3 가오리, 4 성 엘모의 불, 5 불새, 6 용(적하 상실),
7 용(지나감), 8 고래떼, 9 유령선. "Nearest port" = Chebyshev tile distance with x wrap (ids from
`assets/ports.json`). Every point is open water for the whole 2×2 footprint and reachable by sea
from Europe (flood fill over `world_mask.bin`). Areas are read off the world mask.

### 6.1 Built-in, active from the new game (DATA1[15] → DS:0xF9E / 0xFC6)

| slot | x, y | type | nearest port (dist) | area |
|---|---|---|---|---|
| 0 | 241, 148 | 9 유령선 | 나르비크 #101 (37) | Norwegian Sea off Norway |
| 1 | 300, 178 | 0 세이렌 | 스톡홀름 #37 (18) | Gulf of Bothnia |
| 2 | 99, 267 | 4 성 엘모의 불 | 더블린 #31 (37) | Atlantic W of Ireland |
| 3 | 324, 325 | 0 세이렌 | 사로니카 #17 (19) | Danube river, upstream of the Black Sea |
| 4 | 173, 528 | 5 불새 | 톰북투 #64 (19) | Niger river, E of Timbuktu |
| 5 | 176, 601 | 3 가오리 | 산조지 #59 (14) | Gulf of Guinea |
| 6 | 260, 809 | 4 성 엘모의 불 | 케이프타운 #102 (51) | Atlantic off SW Africa |
| 7 | 436, 738 | 2 안개 | 모잠비크 #70 (16) | Mozambique Channel |
| 8 | 425, 513 | 5 불새 | 맛사와 #74 (15) | Red Sea, S end |
| 9 | 614, 526 | 1 거대한 눈 | 고아 #85 (10) | Arabian Sea off Goa |

### 6.2 MONSTER.DAT records 0..29 (record k enters after the (k+1)-th event)

| rec | x, y | type | nearest port (dist) | area |
|---|---|---|---|---|
| 0 | 1771, 513 | 6 용(적하) | 베라크루즈 #49 (35) | Gulf of Mexico, N of Yucatán |
| 1 | 1905, 538 | 9 유령선 | 산토도밍고 #48 (11) | Caribbean, S of Hispaniola |
| 2 | 1953, 684 | 5 불새 | 카옌 #56 (43) | Amazon river |
| 3 | 714, 484 | 6 용(적하) | 코친 #82 (82) | Bay of Bengal, N end |
| 4 | 1897, 1011 | 4 성 엘모의 불 | 몬테비데오 #128 (105) | off Cape Horn / Drake Passage |
| 5 | 881, 647 | 2 안개 | 암보이나 #84 (53) | Flores Sea |
| 6 | 1843, 759 | 2 안개 | 모옌도 #126 (27) | Pacific off Peru |
| 7 | 1088, 808 | 3 가오리 | 지롱 #111 (76) | Coral/Tasman Sea off E Australia |
| 8 | 1235, 891 | 8 고래떼 | 완가누이 #115 (25) | off E New Zealand (North Island) |
| 9 | 993, 627 | 1 거대한 눈 | 반다 #88 (45) | Pacific N of New Guinea |
| 10 | 780, 21 | 4 성 엘모의 불 | 딕손 #105 (114) | Arctic Ocean N of Siberia |
| 11 | 1358, 205 | 8 고래떼 | 놈 #117 (49) | Bering Sea |
| 12 | 1395, 492 | 4 성 엘모의 불 | 나레후 #118 (6) | Hawaii |
| 13 | 1042, 537 | 6 용(적하) | 괌 #112 (4) | Guam |
| 14 | 950, 440 | 3 가오리 | 나가사키 #99 (38) | East China Sea S of Kyushu |
| 15 | 1647, 81 | 4 성 엘모의 불 | 바이아 #121 (55) | Arctic, Canadian archipelago |
| 16 | 1971, 92 | 1 거대한 눈 | 페어웰 #129 (129) | Baffin Bay |
| 17 | 1955, 316 | 0 세이렌 | 코드 #127 (56) | Gulf of St. Lawrence |
| 18 | 1744, 1060 | 9 유령선 | 발파라이소 #125 (168) | Southern Ocean, bottom map edge |
| 19 | 666, 666 | 8 고래떼 | 실론 #83 (90) | Indian Ocean S of Ceylon |
| 20 | 563, 463 | 5 불새 | 디우 #81 (13) | Gulf of Khambhat by Diu |
| 21 | 488, 568 | 4 성 엘모의 불 | 아덴 #72 (30) | Arabian Sea off the Horn of Africa |
| 22 | 1221, 95 | 8 고래떼 | 코르프 #114 (105) | East Siberian Sea |
| 23 | 1183, 1067 | 8 고래떼 | 완가누이 #115 (167) | Southern Ocean S of New Zealand |
| 24 | 1838, 481 | 6 용(적하) | 아바나 #44 (22) | Florida Straits E of Havana |
| 25 | 1844, 597 | 3 가오리 | 카르타헤나 #43 (8) | Caribbean off Cartagena |
| 26 | 1064, 324 | 2 안개 | 에조 #110 (44) | Pacific E of Ezo |
| 27 | 1327, 142 | 1 거대한 눈 | 놈 #117 (15) | Bering Strait |
| 28 | 1634, 484 | 0 세이렌 | 산타바르바라 #122 (36) | Pacific off W Mexico |
| 29 | 1502, 620 | 9 유령선 | 타히티 #119 (112) | central Pacific near the equator |
| 30–39 | 0, 0 | 0 | — | zero padding → dead slot |

Count over all 40 points by type 0..9: **4, 4, 4, 4, 7, 4, 4, 0, 5, 4**.

---------------------------------------------------------------------------------------------

## 7. For the remaster

- [ ] Ship MONSTER.DAT with the assets (e.g. `assets/scenario/MONSTER.DAT`, or embed the 30
      records). The 10 starting points and the counter are already in `ds.bin` at 0xF9E..0xFD0.
- [ ] Keep the state in the DS image (`memory[0xF9E…0xFD0]`) so saves and old saves carry it;
      no Swift-side copy needed.
- [ ] In `Voyage.gameTick`, after the player's move (where `lookAround` runs) and only at sea and
      when not game over: compare the fleet tile with the 10 slots; on a match run the event and
      **skip the port/village sighting for that tick**. Anchored / stopped ticks still test.
- [ ] Use the original coordinate convention: the fleet tile is the top-left of its 2×2
      footprint, exact equality, x in 0..2159. Check that `(Int(x), Int(y))` in the remaster is
      that tile, and that a tick moving more than one tile per axis tests every tile it crosses
      (the original never moves more than one).
- [ ] Event order: zero the slot → apply effect → if the handler returned 0 stop (no sound or
      text) → alarm → msg 1176 → msg 510+2t → msg 511+2t (three boxes, key wait each, no
      portrait) → status panel refresh → load record `[0xFD0]` into the slot, `[0xFD0] += 1`.
      Records ≥ 30 give a dead (0,0) slot.
- [ ] Effects on the Swift models (player ships, companions and hero live in Swift):
      t0 crew −`25·crew/100` per ship; t1 용기 −min(v,10) for hero + companions; t2 remove the
      hindmost ship not captained by the hero (captain → status 6, stays a companion; crew,
      cargo, guns lost); t3 none; t4 morale +min(10, 100−m); t5 that ship's 추진 /2; t6 clear
      all trade goods, recompute load; t7 morale −min(m,10); t8 that ship's 내구 /2, recompute
      fleet strength; t9 hero 운 −min(v,30). "Ship" = in-use slots only.
- [ ] Type 2: recommend deleting the ship properly (free the ship record) rather than copying
      the record leak of §5.2; the player-visible result is the same.
- [ ] Alarm: play `assets/sfx/sea_event.wav` (voice DS:0xBCC, note 0x30, 0.50 s on / 0.33 s off /
      0.50 s on; sfx.md), only if sound effects are enabled.
- [ ] Tests: the 40 points load in order; a point fires once and is replaced by the next record;
      types 2/5/8 with a single (hero) ship consume silently; type 6 keeps water/food/lumber/shot;
      handler 7 works although unused; after 40 events nothing fires; state survives save/load.

## 8. Open questions

1. The exact sound of voice DS:0xBCC: now modelled (sfx.md), not compared with real hardware.
2. Geometry of the text window 0x76EB(0x10, 0xA0, 0x24, 0, 0x80) (shared with 0x30260).
3. What, if anything, sinks a 0-hull ship left by type 8 outside storms and battles.
4. Area names in §6 are read off the world mask, not from any game table (the game has none).
