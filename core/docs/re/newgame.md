# Start-up, title menu, hero selection, new game, environment

Status: decoded from MAIN.EXE. Every address below is a load-image offset (`DS:n` = image
`0x378B0 + n`). OPEN.EXE (opening animation, reads only `OPGRAPH.LZW`) and END.EXE (ending,
`ENDGRP.DAT`/`END_PUT.DAT`/`EVENT*.DAT`) play no part in starting a game. MAIN.EXE gets nothing
from them; it only *hands off* to END.EXE through `int 65h` (§8.4). **The hero select screen,
name entry, environment screen and save/load windows are all in MAIN.EXE.**

Main corrections to earlier notes:

- **0x16588 is not the new-game routine.** It is the tail of the *load* routine 0x16469 (the
  story-bit fix-up after a save is read, §8.2). The new-game routine is **0x1626B**, called from
  the title's *Start New Game* handler 0x168C0.
- There is **no new-game option screen**. `[0xC30]` starts at 0xFF (DATA1[15] byte 0, and
  0x15A44 also writes 0xFF at boot). The story bits 0x02/0x40 are only cleared by the endings
  (§7.2). MENU 30, 49, 59 and 60 are never loaded (§9).
- Every hero starts with **no ship, no gold, no officers and no items**, in their home port, on
  the same date. What differs is their person/fleet records and their prologue script (§5).

---------------------------------------------------------------------------------------------

## 1. Program flow

```
main 0x15AF7:
  if 0x354EE() (EMS check) fails: error text, exit(0)
  0x15A44 init:
      [0xC30] = 0xFF                       ; all option bits on
      0x1626 hook int 23h/24h, 0x7F7 / 0x2AAC video, 0x974E, 0x983F
      0x159B6: [0x412] = 1; drive letter = getdisk()+'A' patched into every "C:..." name
               (pointer list DS:0xAFA), [0x710] = [0xA24] = letter
      0x159ED: open KAO.LZW [0x416], MESSAGE.DAT [0x418], MENU.DAT [0x41A]
      0x352C1
  0x16F20 title:
      0x16F06: 0x16B82 allocate the EMS pages ([0xC0E]..[0xC2C], fonts, DATA2/IKKI ...),
               mouse range 0..639 x 0..399, [0x8B7D] = 1
      0x16ACC(1)                            ; §2
      0x3483E; 0x15A0F open GRAPH.DAT [0x414]
      0x16B49: [0xC3A] == 0xFF ? 0x837D (sea screen) : 0x8AB2 (port screen)
      if !([0xC30] & 4): 0x9568(0x14) (music fade)
  loop while [0x426] == 0:                  ; calendar loop 0x15B30..0x15BB4
      months from [0xC37], days from [0xC38] (0x1598F month length), day = 0x1AC8F
      a load sets [0x56F]=[0x570]=[0x571]=0xF0; 0x1AD6E sees >= 0xF0 and the loop restarts
      from the loaded date DS:0xC36..0xC39 (0x15AC6)
      month end 0x189DA; year end 0x15A79 (ages +1; year > 52 -> [0x426] = 0x10)
  [0x426] != 0: 0x4EA9, 0x9849, 0x17032([0x426]) (§8.4), then 0x16F57:
      close GRAPH.DAT, 0x3483E, 0x974E, [0x413] = 0,
      0x16ACC(0)  -> reloads DATA1[15] over DS:0xC30 (all game state AND options back to the
                     new-game values), title menu again
      reopen GRAPH.DAT, 0x16B49, music check; back to the calendar loop
```

`0x16ACC(first)`: `0x983F`, BGM 3 (`0x94C6(3)`, title music); `first != 0` → 0x15BF3
(`[0xC6DC] = 0`, `0x91BE(2,1)`), else DATA1.LZW entry 15 → DS:0xC30 (0x7F3D bytes). Then open
GRAPH2.DAT as `[0x414]` (title/hero-select pictures), and since `[0x412]` is always 1:
`0x16A06(first)` → if `first` and `KOUKAI2.DAT` does not exist, create it (§8.1) → **title menu
0x16994**. At boot the DS image of MAIN.EXE already equals DATA1[15] byte for byte (checked), so
both paths start from the same state.

## 2. Title menu (0x16994, MENU 56)

MENU.DAT entry 0x38 is loaded (0x32FE8) and shown as a 4-row menu at (0x19, 0x30) by 0x13DF8;
it cannot be cancelled. The choice indexes the far-pointer table **DS:0xABCA**:

| # | item | handler | does |
|---|---|---|---|
| 0 | Ｌｏａｄ Ｄａｔａ | 0x16892 | open KOUKAI2.DAT read-only; 0 if missing; else load window 0x16469 (§8.2). Returns its result |
| 1 | Ｓｔａｒｔ Ｎｅｗ Ｇａｍｅ | 0x168C0 | §3 |
| 2 | Ｅｎｖｉｒｏｎｍｅｎｔ | 0x1691C | `[0x9524] = 1`, environment screen 0x20E97 (§7), `[0x9524] = 0`, returns 0 |
| 3 | Ｑｕｉｔ Ｇａｍｅ | 0x1692E | window titled with item 3, msg 958 " 게임을 끝내겠습니다." + yes/no (0x13FDB); yes → 0x17032(0x80) (quit to DOS, §8.4); no → 0 |

The loop repeats while the handler returns 0. Item 4 "Ｓａｖｅ Ｄａｔａ" is not a title choice;
it is the title of the save window (0x16328 prints item `dx`: 0 for load, 4 for save).
`[0x9524]` is the display-page toggle used when windows are drawn (flipped by the sea-view
redraw 0x6D08 and others); setting it for the title environment screen draws it on page 1.

Environment settings chosen here carry into the new game (0x1626B does not touch
DS:0xC30..0xC35). Loading a save replaces them with the saved ones (they are part of the save).

## 3. Start New Game (0x168C0)

```
0x168C0:
  if [0x412]:                       ; always 1 in this build (set by 0x159B6)
      if 0x15E5F(0) == -1: return 0 ; hero select cancelled -> title
  0x1626B()                         ; new-game setup, §3.4
  if ![0x412]:                      ; dead branch (no hero select)
      read person[hero]+0 (13 B) and +0xD (13 B) from C:USERNAME.DAT
  return 1                          ; leaves the title loop
```

### 3.1 Hero select (0x15E5F)

```
0x9849; draw image 1 of [0x414] (GRAPH2.DAT) at 0,0 (0x5A51)
0x15E2D: portraits 0..5 (KAO.LZW index = hero id) at DS:0xAB6E (x,y) pairs:
         0 (56,184)  1 (104,280)  2 (184,56)  3 (280,80)  4 (328,256)  5 (512,168)
palette DS:0xAADE (0x9825); if [0xC6DC] == 0: fade in (0x16BE(0xAB5E,8,8))
loop:
  hotspots i = 0..5: x..x+0x40, y..y+0x50 (DS:0xC178 + 8i)
  sel = 0x13E63(6 items, 6, flags 0x81)     ; 0x81 = cancellable (arg 0)
  if sel == 0xFF: restore screen, return -1
  [0x1241] = sel; 0x15BDA (pointers [0xC67A] person, [0xC6DA] fleet)
  0x15C71 info window (§3.2)
  ok = 0x15C05(0)                           ; msg 947 "좋습니까？", yes/no
  if ok:
      0x15DD7 back up both names (far buffer [0x708])
      0x15DAE name entry (§3.3)
      0x15C71 redraw info
      ok = 0x15C05(1)                       ; msg 1071 "모두 " + 947 -> "모두 좋습니까？"
      if !ok: 0x15E01 restore the names
  if ok: return sel                         ; else back to the portraits
```

### 3.2 Hero info window (0x15C71)

Window (0x2E,0x20)-(…), portrait `[0x1241]` at (0x20,0x30), then:

- msg 934 `"%s %s"` with person `+0` (given) and `+0xD` (family name)
- labels msgs 935–938 (연령, 통솔력, 항해술／지식, 직감, 기술, 용기, 검술, 매력); age `+0x2A` with
  msg 939 `"%3d세"`; the seven abilities `+0x1C..+0x22` in a 2-column grid (format DS:0xAB96
  `%3d`). **Luck `+0x23` is not shown** — it is re-rolled by 0x1626B.
- skill name `DS:0x874[ DS:0xABA0[h] ]`: table 0x874 = 측량, 지도제작, 포술, 회계, 교섭, …;
  `DS:0xABA0` = `4,2,2,1,0,3` → 조안 교섭, 카탈리나 포술, 옷토 포술, 에르네스트 지도제작,
  피에트로 측량, 알 회계. This matches the skill bits `+0x30`: **0x01 교섭, 0x02 회계, 0x04 포술,
  0x08 지도제작, 0x10 측량** (table index = 4 − bit number). DS:0xABA0 is a fixed per-hero
  table, not derived from `+0x30`: Ernst (0x18) is shown as 지도제작, Al (0x03) as 회계.
- blurb = MESSAGE.DAT line `DS:0xAB9A[h]` = 50 + h (msgs 50–55).

### 3.3 Name entry (0x15DAE → 0x301F5)

Window with msg 940 "[원작 문장 생략].", then
0x301F5: prompt 0x30157(0, 6) and text input 0x2FE73(max 6, dest = person `+0`), then
0x30157(1, 6) and 0x2FE73(6, person `+0xD`). Result 2 from the input (중단) stops and keeps what
was typed so far; the "모두 좋습니까?" No restores both names. The input uses MENU 31
(중단/영문/＜＜/결정/기호/＞＞) and MENU 32 (the jamo grid), loaded at 0x2F79B / 0x2F822. The
names are 13-byte EUC-KR fields (6 two-byte characters + NUL); `$n`/`$s` in scripts read them.

### 3.4 New-game setup (0x1626B)

```
0x1626B:
  0x15BDA: p = person([0x1241]); [0xC67A] = p; [0xC6DA] = f = fleet(p.+0x2C)
  f.+0x29 |= 0x01                        ; the hero's fleet becomes active (hero fleets are 0)
  p.+0x23 = rand(101)                    ; luck 0..100 (data value 50 is discarded)
  [0xC3A] = f.+0x26                      ; start in the fleet's home port
  port([0xC3A]).+0x13 |= 0x50            ; discovered (0x10) + visited (0x40); already set
                                         ; in the data for the six home ports
  0x16177 discoveries (§3.6)
  0x1620D sea-view origin (§3.6)
  0x1613D shared start-up (§3.5)
  0x160DF charted cells (§3.6)
  EMS page [0xC16], 0x300 bytes := 0xFF ; voyage log (항해일지, written by 0x1DB89) emptied
```

`rand` is 0x4D86 (`(seed*0x41C64E6D+0x3039)>>16 & 0x7FFF) % n`, 0x4D54). The seed `[0xC138]`
is BSS (0 at boot, never seeded) but every input-polling loop calls `rand(100)` while it waits
(0x1313E, 0x13AA4), so the luck roll depends on how long the player sat in the menus. A
remaster should use any random 0..100.

Nothing else is touched: no gold, ships, officers, items, fame, date. **The other five heroes'
persons and fleets stay as in the data** (inactive fleets with no ships); they are the rivals
handled by the monthly code (fleets.md §7.2, 0x1863C/0x186DF skip `[0x1241]`).

### 3.5 Shared start-up (0x1613D; also run after every load)

```
0x1613D:
  [0x56E..0x571] = DS:0xC36..0xC39        ; year, month, day, tick
  0x3217E scenario files: close [0x55C],[0x55E],[0x566],[0x568] if open;
          digit '1'+[0x1241] into "C:SNR*.DAT" (DS:0xA45) and "C:SNR*.MES" (DS:0xAA1),
          open -> [0x55C] DAT, [0x55E] MES; digit '0' -> SNR0 -> [0x566], [0x568]
  0x15F79 static tables from DATA1.LZW (not saved):
          [5] -> DS:0xC12E (route node count), [4] -> EMS [0xC1E] (route graph),
          [10] -> [0x436], [12] -> [0x70E], [0x12] -> [0x43A],
          **[0x10], or [0x11] when [0x1241] == 5 -> DS:0xC685 (0x51 bytes)** = peerage titles,
            9 x 9 bytes: [16] 기사 준훈작 훈작 준남작 남작 자작 백작 후작 공작,
                         [17] (Al) 사족 감찰관 군수 지사 영주 대영주 군후 재상 대재상
          WINDCUR.DAT: summer table if 3 <= month < 9 else winter -> [0x43C]; current -> [0x440]
          DS:0xC0B6[0..45] = DS:0x764[0..45] (goods-name pointers; scenario table 19 "tbl19")
  0x4FE4(mouse sensitivity, §7.1)
  DS:0xA11 = '1'+[0x1241]                 ; "C:EVENT*.DAT" -> EVENT{h+1}.DAT (script pictures)
```

### 3.6 World seeding

**0x16177 discoveries** (98 sites, DS:0x7E88 × 7; records 98/99 are dummies at (0,0)/(1,0)):

```
for i in 0..97: site[i].+6 |= 0x80                 ; hide all
n = 0; while n < 50: r = rand(98); if site[r].+6 & 0x80: clear it; n++     ; 50 come alive
k = 0; while k < 10:
    r = rand(98)
    if site[r].+6 & 0x80 and site[r].+4 < 0x5A:     ; a still-hidden site
        site[r].+4 = 0x5A + k                       ; relic k
        item_def[0x50 + k].+0x18 = r                ; the treasure map points at it
        k++
```
(items 0x50..0x59: 가면, 제단, 조각상, 석판, 수정구슬, 불뿜는 항아리, 보검, 메달, 성자의 지팡이의
지도, 낡은 지도.)

**0x1620D sea-view origin** (24×24-tile window, fleet drawn at offset 11):
`R = (x / 720) * 720`; `[0xF92] = clamp(x − 11, R, R + 0x2B8)`; `[0xF94] = clamp(y − 11, 0, 0x420)`.

**0x160DF charted cells**: clear the 90×45 bitmap DS:0xD74 (0x21C bytes), then mark cells
`cx = 4..16, cy = 8..17` (tiles x 96..407, y 192..431: Europe, the Mediterranean and NW Africa)
and add 1 to `[0xF9A]` for each (130); then 0x22A79 rebuilds the charted route nodes (DS:0xFD2).
Same area for every hero.

---------------------------------------------------------------------------------------------

## 4. Per-hero starting state (new-game data DS:0xC30.., plus 0x1626B)

Common to all heroes (values in DATA1[15]):

| what | address | value |
|---|---|---|
| options | `[0xC30]` | 0xFF (§7) |
| text speed, sea speed, ?, mouse, scroll margin | DS:0xC31..0xC35 | 5, 5, 0, 2, 6 |
| date | DS:0xC36..0xC39 | 21, 4, 16, 24 → **1522-05-17 08:00** (year +1501, month/day 0-based, 72 ticks/day) |
| `[0xC3A]` port | | 0xFF in the data, set to the home port |
| `[0xF91]` | | 0x20 (docked) |
| gold / bank | DS:0x123A u32 / DS:0x123E s16 (×100) + 0x1240 | 0 / 0 |
| hero id | DS:0x1241 | 0 in the data, set by the select screen |
| family record h | DS:0x11E6 + 14h | fame (trade, battle, adventure) 0/0/0; standing with nations 0–5 (`+6..+0xB`) 100 each; `+0xC` 100; peerage `+0xD` 0 |
| days at sea, water/food ration | DS:0x2D54..0x2D56 | 0, 100, 100 |
| officers / wages | DS:0x2D57 ×30 / DS:0x2D75 ×30 | all 0xFF / all 2 |
| items | DS:0x2D93 ×20 | all 0xFF |
| hero fleet ship slots | fleet `+0x2B` ×10 | all empty: filler bytes `FF 00 FF FF FF FF FF FF`, flags `+8` = 0 |
| cargo records 0..9 | DS:0x5210 ×30 | record 0: water 200, food 200, `+6` 5, `+8` 25, `+9` 50, `+0xA` 0x51; others zero with `+8`=`+9`=20. Irrelevant: `order_ship` clears the record it uses |
| person `+0x2E` role | | 0 for every hero (becomes 1 = admiral when the first ship is delivered with the hero as captain, 0x31DAC) |
| person `+0x2D` port | | 0xFF; person `+0x2B` loyalty 100 |

Per hero (person record DS:0x1242 + 50h, fleet record DS:0x2DB2 + 133·fleet):

| h | person | portrait | age | 통 항 지 직 용 검 매 (+0x1C..0x22) | luck | nav/battle lv | exp nav/battle | +0x2F | skill +0x30 | +0x31 (nation) | fleet | fleet x,y | home port `+0x26` | fleet `+0xD` / dest |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 조안 페레로 | 0 | 18 | 78 75 73 85 82 82 89 | rand(101) | 1/1 | 0/0 | 0x50 | 0x01 교섭 | 0x60 (0 Portugal) | 0 | 118,358 | 0 리스본 | 0x00 / – |
| 1 | 카탈리나 에란초 | 1 | 18 | 80 79 65 52 86 92 95 | rand(101) | 8/10 | 190/170 | 0xE1 | 0x04 포술 | 0x61 (1 Spain) | 10 | 142,374 | 1 세빌리아 | 0x41 / 260,348 |
| 2 | 옷토 스피노라 | 2 | 25 | 92 72 61 43 88 86 82 | rand(101) | 10/12 | 140/210 | 0xD1 | 0x04 포술 | 0x63 (3 England) | 30 | 180,264 | 29 런던 | 0x41 / 160,264 |
| 3 | 에르네스트 로페스 | 3 | 23 | 78 92 86 82 62 53 90 | rand(101) | 11/1 | 120/0 | 0xE0 | 0x18 지도제작+측량 | 0x65 (5 Netherlands) | 50 | 218,248 | 33 암스테르담 | 0x41 / 230,320 |
| 4 | 피에트로 콘티 | 4 | 33 | 84 80 75 87 53 61 81 | rand(101) | 4/1 | 110/0 | 0x51 | 0x10 측량 | 0x64 (4 Italy) | 40 | 230,322 | 8 제노바 | 0x41 / 322,218 |
| 5 | 알 베자스 | 5 | 19 | 80 86 84 65 53 42 80 | rand(101) | 1/1 | 0/0 | 0xC1 | 0x03 교섭+회계 | 0x62 (2 Turkey) | 20 | 352,342 | 2 이스탄불 | 0x41 / 392,402 |

All six fleets: state `+0x29` 0 in the data (→ 0x01 for the player's), admiral `+0x2A` = h,
mission 0, `+0x1C` = home port, funds 0, no treasure/cargo, no ships. Fleet x,y is the berth
two tiles off the port record coordinates (e.g. Lisbon port 120,358). Fleet 0 is the only one
with `+0xD = 0` and no destination; the others keep the AI route fields of the inactive rival
fleet (harmless for the player's fleet, see open questions).

Hero-dependent files and tables: `SNR{h+1}.DAT/.MES` (0x3217E), `EVENT{h+1}.DAT` (DS:0xA11),
`IAP{h+1}.LZW` (duel graphics, digit DS:0xA87 at 0x12653), peerage titles DATA1[16] or [17]
(Al), sea BGM `4 + h` (0x846E, music.md), ending code h (`F4 h`), rival ship type in 0x186DF
(Joan 0, Catalina 1, Otto 2, Ernst/Pietro 0, Al 3).

---------------------------------------------------------------------------------------------

## 5. Prologues (chapter 0 of SNR{h+1}) — where ships, money and officers come from

Nothing in MAIN.EXE gives a hero a ship. Every prologue does it with `order_ship`/`deliver_ship`
(F9/FA). `order_ship t` (0x31C64): first player slot whose flags `& 0x30` is neither 0x10 nor
0x20; first ship record 0..39 with `+0x12 == 0xFF`; hull = maxHull = `9 × class hull / 10`,
rudder/sail = class, crew 0, guns 0, record #, flags 0x20 (building); cargo record of that slot
zeroed (water, food, materials, shot, goods), `+8` = 25, `+9` = 50 (crew ratio), `+0x1B` =
`[0xC3A] | 0x80`; ship record capacities from template 40+t (0x31D86); market `+0x23` = 0.
`deliver_ship` (0x31DAC): flags → 0x10, captain `+0x1B` = `[0x574]` (the hero for a first
ship → hero `+0x2E` = 1), market `+0x23` = 0xFF, name = MES line, `fleet_recompute`.
Classes: 5 카라벨 라티나 (hull 27/30 after the 9/10 rule, rudder 90, sail 75; berths 30, cargo
80, 10 gun ports), 10 갤리온 (hull 72, rudder 60, sail 65; 180 berths, 550 cargo, 70 ports).
Water/food in cargo records are tenths of a barrel. Cannon type 4 = 컬버린.

| h | file / ch.0 | where | steps (in order) | ship | crew / supplies | gold | officers | items | other state |
|---|---|---|---|---|---|---|---|---|---|
| 0 조안 | SNR1 (scenario.md §6) | Lisbon | residence (father) → tavern (Carlotta) → residence after 22:00 (mother) → church (Enrico) → shipyard → harbor (Rocco's lecture) → day 1 at sea `next_block` → day 3 Domingo → ch.1 | class 5 ordered at the residence, delivered at the shipyard: 『헤르메스Ⅱ세』 (#132) | 0 / none | +1000 (Carlotta, required); church: +1000 or luck := 100 (optional); ch.1 monthly +1000 | 69 로코 (→ role 3), 70 엔리코 (→ role 4), 71 도밍고 (day 3) | item 0x34 은제 머리장식, 3 레이피어 | women 0,1 affection 100; ports 98/99 `+0x13 |= 0x20` |
| 1 카탈리나 | SNR2 0x3C–0x7A6 | Seville | block 0: residence (commander: news, f0) → [2nd residence visit before the tavern: item 15] → tavern (rumour, f4) → residence (petition refused) `next_block`; block 1: tavern (decision, f5) → harbor: steals the gold transport | class 10 갤리온 『리베리온』 (#152), delivered at once | **120 crew, 50 guns (type 4)**; water 1000, food 1000, shot 50, **10 units of good 31 금** in slot 0 | 0 | 72 프랑코 사누드 (role 3) | 15 사브르 (optional, item slot 0) | **person 1 `+0x31` nation := 6 (pirate)**; block 2 at sea day 1: family[1] `+7` (standing with Spain) := 0, `next_chapter` |
| 2 옷토 | SNR3 0x36–0x908 | London, then Seville | block 0: palace (Henry VIII, f0) → shipyard (f1) → harbor (Mash, f2) → tavern duel → `next_block`; block 1 at sea day 1: Seville `+0x13 |= 0x10`, `next_block`; block 2 Seville: market/shipyard launch scenes, tavern (Mash's crew), **harbor before tick 60**: steal the new galleon | first class 5 『심플튼』 (#75); at Seville the caravel is dropped (slot flags `&= ~0x10`, ship record 0 freed) and class 10 『바카스』 (#151) is made with **hull/maxHull 100, 150 crew, 70 guns (type 4)** | caravel: 20 crew, water 200, food 200; galleon: water 2000, food 2000, shot 50 | +300 (Gilbert); block 3 day 1 at sea: **+10000** | 75 마슈 로이 (role 3, after a duel) | 1 숏 소드, 16 하드 레더, 32 사략허가서(E); item defs 1 and 16 `+0x19 |= 0x10` (equipped) | family[2] peerage +1 (→ 1 기사); block 3: nation 1 (Spain) `+0x15 |= 0x10`, nation 3 (England) `+0x13 |= 0x10` (war flags), family[2] battle fame +300, standing with Spain := 20, `next_chapter`. If the player visits another port's harbor twice first (v9 = 1), block 3 skips all of this and just goes to ch.1 |
| 3 에르네스트 | SNR4 0x2E–0x26E | Amsterdam | residence (Mercator) → `next_block`; block 1: harbor → `next_chapter` | class 5 『메르카토르』 (#34) | 0 / none | **gold := 5000** (assignment) | 77 로이드 스탓텐 (role 3) | – | npc 9 메르카토르 `+0x13 |= 0x10`; ports 97 장안, 98 사카이, 99 나가사키 `+0x13 |= 0x20` |
| 4 피에트로 | SNR5 0x2A–0x44B | Genoa, then Lisbon | block 0: harbor first (debt: **bank `[0x123E]` := −10 = −1000 gold**, f0) → tavern (Camilo) → `next_block`; block 1 Lisbon: residence (Duchess) → harbor → `next_chapter` | class 5 『파르콘』 (#17) | 10 crew; water 100, food 100 | at the Lisbon residence: **gold := 5000**, bank := 0 | 76 카미로 스테파노 (role 3) | 21 육분의, 24 망원경 (slots 0, 1) | Lisbon `+0x13 |= 0x10`; npc 0 집사 마르코 `+0x13 |= 0x10` |
| 5 알 | SNR6 0x34–0x65E | Istanbul | block 0: shipyard (Jahan) → order only, `next_block`; block 1 (any order): tavern +1000, harbor +1000, bank +1000 +1000 → when all three done `next_block`; inn (optional): +500 or item 25; block 2: shipyard → delivered; at sea day 1 → `next_chapter` | class 5 『사바니』 (#142), **ordered in block 0, delivered in block 2** | 0 / none | 4000 required, +500 optional | 78 자한 사림 (role 3) | 25 고양이 (if the inn money is refused) | woman 2 라디아 affection := 50 |

So Joan's "no ship until the script" is the rule for everyone; Catalina and Otto are the only
heroes whose script also crews, arms and provisions the ship. Every prologue companion is made
first mate by writing person `+0x2E = 3` (Joan's Enrico later 4 = accountant); the scripts do
not write the post holders DS:0xB050..0xB052 (whether those are rebuilt from `+0x2E` is open).

---------------------------------------------------------------------------------------------

## 6. Other hero-dependent code

- 0x2CD8D: at the fortune teller (MENU 17), Catalina (h = 1) has item 2 연애운 disabled
  (`[0xA9BA] |= 4`).
- 0x15FFF: Al's peerage names (§3.5).
- 0x32E20: the hero script context only runs with `[0xC30] & 0x40` (scenario.md §3.1).
- Everything else reads `[0x1241]` / `[0xC67A]` / `[0xC6DA]` generically (≈120 sites); nothing
  assumes hero 0. Nation-based rules use the hero's `+0x31 & 0xF`, so Catalina after her
  prologue is a pirate (6) and Al is Turkish (2).

---------------------------------------------------------------------------------------------

## 7. `[0xC30]` options and the environment screen

### 7.1 Option bytes

| byte / bit | meaning | default | UI | readers |
|---|---|---|---|---|
| C30 bit 0x01 | 표시효과 (display effects): TRANSIT.DAT wipes 0x91F3, palette fades 0x9368/0x9460, scroll animations 0x7871/0xC4D1, 0x73C7, 0x1B42B, 0x27186… | on | env row 0 ON/OFF | |
| C30 bit 0x02 | story not yet ended (rank-9 ending 15 allowed: palace 0x2A5DF, town.md) | on | none | §8.2, §8.4 |
| C30 bit 0x04 | BGM | on | env row 1 ON/OFF | 0x94D4 play, 0x16F3E/0x165E6 fade |
| C30 bit 0x08 | sound effects through the FM driver (0x94A0, 0x9668, 0x969B) | on | **none** (no way to change it) | |
| C30 bits 0x10, 0x20 | unused | on | – | – |
| C30 bit 0x40 | hero scenario enabled (SNR{h+1} runs) | on | none | 0x32E20 |
| C30 bit 0x80 | 레이아웃: frame picture TYPE 1 (set: GRAPH.DAT 2 at sea, 3 in port) / TYPE 2 (clear: 4 / 5) | TYPE 1 | env row 2 | 0x8480, 0x8BA4, 0x1D544…, 0x26EEB, 0x31AA9 |
| C31 | text/message speed: waits `12 × [C31] × n` timer units (0x5981, 0x59ED abortable) | 5 | **none** | |
| C32 | 해상속도: after each sea-view redraw wait `[C32]` timer units, any key skips (0x6D32). 0 = no delay | 5 (0..10) | env gauge 3 | |
| C33 | unused | 0 | – | – |
| C34 | 마우스감도: INT 33h fn 0Fh, CX = DX = `(v+2)·2` mickeys per 8 pixels (4..12; larger = slower), only if a mouse is present (`[0x9496]`) — 0x4FE4, applied at start/load and on change | 2 (0..4) | env gauge 4 | |
| C35 | 해상이동치: dead zone of the sea view. The view scrolls one tile when the fleet is more than `[C35]` tiles from the centre offset 11 (`dx < 11 − v` or `dx > 11 + v`, same for y; 0x312AD) | 6 (0..10) | env gauge 5 | |

Timer units are those of the KOEI driver's countdown (`int 66h`, AX=F101h set / F100h read,
0x1678/0x1685).

### 7.2 Environment screen (0x20E97)

Reached from the title (§2) and from the system menu (§8). Window (0x18,0x20) 0xE0 wide; six
labels (format `%-s`, DS:0xB1D4) from DS:0xB19C: 표시효과, ＢＧＭ, 레이아웃, 마우스감도,
해상이동치, 해상속도 — rows at y = 0x30 + 32i. 0x20BD4 builds 12 hotspots: rows 0–2 two
identical hotspots each at x 0x130..0x160 (index 0–5); gauge rows 3–5 a "−" at x 0x130 and a
"+" at x 0x188 (index 6–11). 0x20CDE draws the values: ON/OFF (DS:0xB180 "Ｏ  Ｎ", 0xB187
"ＯＦＦ"), TYPE 1/TYPE 2 (DS:0xB18E/0xB195), gauges 0x913F (0..100 %) = `25·C34`, `10·C35`,
`10·C32`.

```
loop:
  sel = 0x13E63(12 hotspots, 2, flags 3)        ; cancellable
  if sel == 0xFF: break
  if sel/2 in 0..2: 0x20D83(sel):
      0: [C30] ^= 0x01
      1: if [0x9606] != 0xFF and [0x420] (FM driver): [C30] ^= 0x04;
           on:  if [0xC3F] & 0xF == 1 (storm): restart the storm effect (0x95BE(0xBE2), 0x965A(0x30));
                play [0x9606]
           off: stop (0x96DE), fade 0x9568(5), wait 0x958F
      2: [C30] ^= 0x80
  else 0x20DFA(sel − 6) = i:  max = (i >= 2 ? 10 : 4)
      target = i < 4 ? [C34 + i/2] : [C32]       ; i 0,1 mouse; 2,3 scroll margin; 4,5 sea speed
      odd i: target += min(1, max − target); even i: target −= min(1, target)
      0x4FE4 mouse ratio from [C34]
```
After the screen, the system menu redraws the whole sea/port screen when bit 0x80 changed
(0x91C6(3), 0x16B49, 0x91DE(3)).

---------------------------------------------------------------------------------------------

## 8. System menu, save/load, quit, endings (brief)

### 8.1 KOUKAI2.DAT (333,551 bytes)

```
0x0000            1 byte  (whatever [0x1241] was when the file was created; unused)
0x0001 + 15·s     slot header s = 0..9:
                  +0..+0xB date text "dd/Mon/15yy" (day tens digit or ' ', month DS:0x94F6
                           pointers Jan..Dec, "/15" DS:0xABC5, year+1 two digits), NUL
                  +0xC     port [0xC3A] (0xFF -> msg 1072 "해상")
                  +0xD     save type: 0 normal, 2 story ended, 3 rank ending only (shown with
                           a red '*' DS:0xABA6)
                  header byte 0 == 0 -> empty ("      KOEI Game %02d", DS:0xABAE)
0x0097 + 33340·s  DS:0xC30..0x8B6B (0x7F3C bytes) + 0x300 bytes voyage log (EMS [0xC16])
```
Created by 0x16A06 at the first boot (empty headers, slots = copies of DS:0xC30). The file
offset of `DS:n` inside slot 0 is `n − 0xB99` (as in RE_NOTES).

### 8.2 Load (0x16469) and the post-load fix-up (0x16588)

Slot window (0x16328, title "Ｌｏａｄ Ｄａｔａ"), msg 951 "[원작 문장 생략].", 10 rows,
cancellable; empty → msg 953 and wait; else msg 952 "[원작 문장 생략]？". Reads the slot
into DS:0xC30 and the log, then:

```
if !([C30] & 0x42):  [0xC60] = 0xFF, [0xC61] = 0      ; story over: hero script disabled
elif !([C30] & 0x02): [C30] = ([C30] | 0x40) & ~0x02; [0xCEA] = [0xCEB] = 0   ; reset SNR0
else:                 [C30] |= 0x42
0x15BDA; 0x1613D (§3.5); 0x780F; stop music; storm effect if [0xC3F]&0xF == 1;
if BGM off: fade; [0xA24] = drive letter; return 1
```

### 8.3 System menu (0x20F8E, MENU 20) and save (0x1661A)

Reached only through item 5 "기능" of the voyage command menu 0x208C7 (MENU 29 at sea, MENU 46
when `[0xF91] & 0x20`; in port items 0–3 are disabled). Choices: 환경 → 0x20E97; 저장 → if in
port `[0xC3B] = 0x82`, 0x1680C(0); 로드 → 0x1680C(1), on success date bytes := 0xF0 (calendar
restart, §1) and return 1; 중단 → 0x20F50: "[원작 문장 생략]?" (DS:0xB1D8), yes →
`[0x426] = 0x88` (back to the title).

0x1680C(mode): opens KOUKAI2.DAT (read/write for modes 0, 2, 3); 0 = save, 1 = load, 2/3 =
ending saves. Save: slot window titled "Ｓａｖｅ Ｄａｔａ", msg 954 "[원작 문장 생략]？"
(no empty-slot check), header type = mode, but 2 if `!(C30 & 0x40)`, 3 if `C30 & 0x40` and
`!(C30 & 2)`; writes the headers, copies the current date into DS:0xC36..0xC39, writes the slot.

### 8.4 Endings and quitting (0x17032(code))

| code | meaning |
|---|---|
| 0..5 | story ending of hero h (`F4 h`): msg 746 "[원작 문장 생략]…", `[0xC3B] = 0x82` in port, `[C30] &= ~0x42`, ending save (mode 2), then END.EXE |
| 0x0F | rank-9 ending (palace, needs `C30 & 2`): `[C30] &= ~0x02` only, ending save (mode 3), END.EXE with code `0x100 | h` and the hero's nation |
| 0x10 | year counter `[0x56E]` > 52 at New Year, i.e. on reaching 1554: msg 1016 (retirement) |
| 0x18 / 0x19 / 0x1A | flagship sunk in a storm 1014 / no crew left 1015 / lost a battle 1013 |
| 0x80 | Quit Game from the title: KOEI end screen (GRAPH.DAT 0x3C, 0x3E), free EMS, restore vectors, exit(0) |
| 0x88 | 중단: straight back to the title |

END.EXE hand-off (0x17151): name string "given + DS:0xAC4D + family" at DS:0xBEAA,
`int 65h` AH=1 (CX:BX = name), AX=0x300 BX=code, AX=0x400 BX=nation, AX=0x500
BX=`((code << 7) | nation) ^ 0x1565`, then exit(1). Game-over codes show the message with
year/month/day and the hero's name, then return to the title.

---------------------------------------------------------------------------------------------

## 9. Leftovers in the data (not used by this build)

- MENU 30 (ＢＧＭ, 표시속도, 이동속도, Blue, Red, Green), MENU 49 (Ｅｎｖｉｒｏｎｍｅｎｔ),
  MENU 59 (아날로그디스플레이 / ８계조액정디스플레이) and MENU 60 (표시효과, ＢＧＭ, 레이아웃,
  저장, 마우스감도, 해상이동치) are never loaded: every MENU.DAT load (0x32FE8 / 0x32F3E, 55
  call sites) was checked. They look like the PC-98 environment screens; this build hard-codes
  its labels at DS:0xB19C. 표시속도 would be C31 and 이동속도 C32/C33; the palette sliders do
  not exist.
- Messages 941–945, 948–950, 955 (user disk / floppy prompts; 955 is printed by the unreferenced
  0x16AA2), 946 (display choice), 956 "--- not use ---".
- `[0x412] == 0` paths: no hero select, names from `C:USERNAME.DAT`, endless loop after the end
  screen (0x1701D) — a demo/kiosk configuration.

---------------------------------------------------------------------------------------------

## 10. Remaster notes (vs `Voyage.newGame(in:)` / `seedDiscoveries`)

`Voyage.newGame(in:)` is hard-wired to `heroes[0]`. A faithful `newGame(hero h)`:

1. Take a pristine copy of `assets/ds.bin` (= DATA1[15] image; it keeps the options unless the
   title environment changed them).
2. `[0x1241] = h`; person h `+0x23 = rand(101)`; fleet `f = person[h].+0x2C` (0/10/30/50/40/20),
   `f.+0x29 |= 1`; port `[0xC3A] = f.+0x26` (0, 1, 29, 33, 8, 2) and its `+0x13 |= 0x50`.
3. Discoveries: **98** sites (`rand(98)`), not 100 — records 98/99 are dummies at (0,0)/(1,0)
   and must stay hidden; condition `+4 < 0x5A` (all are 0 at start, so equivalent).
4. Charted cells x 4..16 × y 8..17 (130 cells, `[0xF9A] = 130`) and rebuild the charted route
   nodes — currently not done, so 항구이동 starts with nothing charted.
5. Load `SNR{h+1}`, `EVENT{h+1}`, `IAP{h+1}`, peerage names DATA1[16] / [17] for Al, sea BGM 4+h.
6. Date 1522-05-17 08:00, gold 0, no ships/officers/items for everyone. Start in the port screen
   and let the prologue script run (§5); `joanAfterPrologue` has no equivalent for the others.
   The captain model must follow person h (abilities, levels, skills `+0x30`, nation `+0x31`).
7. Hero select screen: six portraits, info window (§3.2, luck hidden), "좋습니까?", name entry,
   "모두 좋습니까?". Title: Load / Start / Environment / Quit.

---------------------------------------------------------------------------------------------

## 11. Open questions

1. Timer unit of the `int 66h` countdown (text speed C31, sea speed C32).
2. `[0x574]` (captain chosen by 0x12AE5 before `deliver_ship`): confirm it is always the hero for
   a first ship in every prologue.
3. The non-zero AI fields of the hero fleets 10–50 (`+0xD = 0x41`, destination) once the player
   owns one: does the player's 항구이동 or any daily code read them before they are overwritten?
4. `[0xC3B] = 0x82` on saving in port / before the ending save: which port view is restored.
5. Family `+0xC` (100 at start) and the person `+0x2F` bits of the heroes (0x50, 0xE1, 0xD1,
   0xE0, 0x51, 0xC1).
6. Bit 0x08 (sound effects) has no UI; whether the FM driver honours it for all effects.
7. Al's ship sits ordered (flags 0x20, market `+0x23 = 0` = "finished") between blocks 0 and 2;
   what the native shipyard does if the player enters it in block 1 (the script triggers first
   and leaves, so probably nothing).
