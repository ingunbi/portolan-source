# Tavern (rest), inn person list, palace 밀회 (대항해시대 II, Korean DOS)

Companion to [tavern_jobs.md](tavern_jobs.md) (same conventions: load-image addresses, `DS:n` =
image 0x378B0 + n, "msg N" = MESSAGE.DAT line N, "menu N" = MENU.DAT entry N with all `\0` items).
Everything here was read from code unless marked **(inferred)**. Native RNG `rand(n)` 0x4D86 (0..n−1).

Extra helpers seen in this part:

| call | effect |
|---|---|
| 0x8EE3 / 0x8EBE | open the window of an officer (role priority 3,4,5,2,6 / 4,3,5,2,6: first mate first / accountant first) |
| 0x7D45(ax = portrait, bx = name) | girl window: portrait + `§name§` (msg 1134) |
| 0x7E95 | clear the girl's window and print msg N (tavern_jobs §0) |
| 0x153BF(ax = layout, dx = count) | list picker over the word list DS:0x574, returns index or −1 |
| 0x1AE42 / 0x13CA3 (bl = item count) | menu; returns item or 0xFF (Esc). `[0xA9BA]` = disabled-item mask (bit i = item i) |
| 0x32FE8(ax = n) | load MENU.DAT entry n into string pointers |
| 0x24EBB(ax) | pay ax gold if possible (returns 0 if short), redraw status |
| 0x24EE1(ax) | add ax gold, cap 600,000,000, redraw status |
| 0x58EA(dx:ax = min, stack = max) | number input; loops until min ≤ v ≤ max |
| 0x373C / 0x36A2 / 0x376E | 32-bit mul / div / mod |

## 0. State

| what | where | notes |
|---|---|---|
| per-day flags | `[0xC3C]` | **cleared at every day rollover** 0x190F9. bit 0x01 = sailors hired today (선원고용 greyed), bit 0x40 = barmaid affection bonus already taken today (자기자랑 / 업무정보 relic), bit 0x80 = slept at the inn (0x285D7), bit 0x02 used by building 0x2B3A0/0x2C326 (not this doc) |
| tavern mood | `[0xB5E0]` | = charm / 3 on entry |
| heroine here | `[0xB5E4]` | girl ptr from 0x26F15 (greeting only) |
| barmaid here | `[0xB5E6]` | girl ptr from 0x26F55; 0 = none (여급과대화 greyed) |
| pirate patron | `[0xB5E8]` | 1 if the patron is admiral of fleet 60–69 (tavern greeting) |
| selected person | `[0xBECE]` index, `[0xB5E2]` ptr | tavern/inn; **also overwritten by the 조사의뢰 report** (admiral ptr) |
| inn person | `[0xB6B8]` index, `[0xC13C]` ptr | |
| person `+0x2B` | friendship / loyalty | 0..100 |
| person `+0x2F` | bits | low 2 bits = type (fleets.md: 0/1 national, 2 pirate), 0x08 informal speech, **0x10 tavern (clear = inn)**, **0x40 doubles the treat gain**; generated persons: `rand(16) << 4 | type` |
| person `+0x2E` | role | 0 none, 1 admiral, 2 captain, 3 first mate, 4 accountant, 5 chief navigator, 6 navigator; names DS:0x858 (`'' 제독 선장 부선장 경리주임 수석항해사 항해사`) |
| person `+0x1C..+0x22` | abilities | 통솔 항해 지식 직감 용기 검술 매력; names DS:0x87E |
| hero `+0x31` bit 0x10 | "female hero" | selects feminine lines (survey 0x2929E: 758/760 vs 759/761), excluded as admiral (0x18263). **No writer in MAIN.EXE or any SNR script, and clear for all persons in the new-game data**, so every "female" branch below is dead in practice (see §9) |
| girl record | DS:0x2B56 + 17·i, i < 30 (0x5B0C) | see §5.1 |
| officer slots | DS:0x2D57 person × 30 (0xFF free), DS:0x2D75 wage/10 × 30 | |
| ship slots | 0x5B4C(i): 9 B at `[0xC6DA]`+…, `+0` crew u16, `+7` ship record, `+8 & 0x30 == 0x10` in use | |
| cargo record | DS:0x5210 + 30·i (0x5B2C) | `+0x1C` morale |

## 1. Tavern entry 0x26FF5

```
mood = hero.charm / 3                                  # [0xB5E0]
[0xB5E4] = 0x26F15()      # heroine: hero not female; first girl with +0xC == port, +0x10 & 0x08, +0x10 & 0x40
[0xB5E6] = 0x26F55()      # barmaid: first girl with +0xC == port, +0x10 & 0x08, !(+0x10 & 0x40);
                          #   if hero female: return 0 unless (OLD [0xB5E6]).+0x10 & 1   ← stale pointer, original bug
if v63 == 0 ([0xD72] == 0 and [0xCE8] == 0):            # no script spoke
    if [0xB5E4]: girl window 0x7D45(portrait 0x61, girl[0].name)       # always girl 0 (카를로타)
                 girl says 17 (hero.given, drinkName[market.+0x24]); wait; close
    else:        keeper says 18 (drinkName)
    if [0xB5E6]: 0x26FA2()     # female hero only: girl window, 307 if her request is ready
                               #   (+0xE != 0xFF and +0xF == 0) else 308; wait; close
loop: menu 15 (6 items), dispatch DS:0xB632, until Esc
    [0xA9BA] |= 0x01 if [0xC3C] & 1             # already hired today
    [0xA9BA] |= 0x10 if [0xB5E6] == 0           # no barmaid
    [0xA9BA] |= 0x03 if ship count (0x12986) == 0
```
Dispatch DS:0xB632: 선원고용 0x252A7, **선원해고 0x25356**, 한턱내기 0x2589E, 항해자와대화 0x26293,
**여급과대화 0x26CCB**, **도박 0x26E14**. Hiring (0x252A7) sets `[0xC3C] |= 1` at the end, so
선원고용 works **once per day**.

## 2. 선원해고 0x25356

```
0x2515E(n = 0)                                 # shared with hiring (n = sailors bought)
for each of the 10 ship slots in use: if slot.crew == 0: cargo[i].+0x1C (morale) = 0
```
0x2515E with n = 0:
```
loop:
    i = ship picker 0x153BF(0x87, ship count) over the ships in use (0x12986 list)
    if Esc: return                             # nothing is paid or refunded
    ship = ship record (slot.+7, DS:0x57CE + 25·k)
    officer window (0x8EE3); say 857 (ship.name, slot.crew)
    v = numinput(0 .. min(slot.crew, ship.+0x15 max crew))
    if v == slot.crew: close; continue
    lower window: say 858 (slot.crew − v); if !yes_no(): close; continue
    close; slot.crew = v
```
- Any number from 0 to the current crew, ship by ship; **no cost, no refund, no morale change**
  except that a ship left with **0 crew gets morale 0**. No minimum crew is enforced here.
- Dismissed sailors simply vanish.

(Hiring for reference: after paying all n up front, the same loop distributes them; on Esc with
sailors left msg 35 + yes/no, then refunds `min(n, left) × wage` via 0x24EE1; new sailors arrive
with morale 60: `morale = ((new − old)·60 + morale·old) / new` for each ship that grew.)

## 3. 항해자와대화 (tavern) and the patron menu

### 3.1 List 0x26224 → pick 0x26268 → 0x261C0
Port list 0x12B5D (tavern_jobs §1.1): persons 0..119, not the hero, `+0x31 & 0x20`, and
`+0x2D == port` **or same fleet as the hero (your officers)** or admiral of a docked fleet < 70 at
the port's x,y. Tavern list 0x12BEB keeps entries with `+0x2F & 0x10`; inn list 0x12C4B the others.
Both return the filtered count, or `[0x574] = 0xFF` and the unfiltered count when nothing passed.
- Tavern, empty: mood ≥ 50 → random face, msg 38 ("not here, but I saw one at the inn" — said
  **without checking the inn**); else officer window, msg 39.
- Pick (layout 0x86) → `[0xB5E2]`, portrait 0x7D9F, `[0xBECE]` → 0x261C0 → close → re-list.

0x261C0: greeting 0x25988; if it returns 0 stop; else menu 12 with **3 items** (결투 hidden), dispatch
DS:0xB5EA (한턱내기 0x25CCC, 항해자정보 0x25E34, 고용 0x261B8), **loop** until Esc or a handler
returns 0.

### 3.2 Greeting 0x25988 (tavern)
```
[0xB5E8] = 0
if p.fleet == hero.fleet: say 134 + rand(3); wait; return 0          # own officer, no menu
if 60 <= p.fleet < 70:  say 859 + rand(2); wait; [0xB5E8] = 1; return 1   # pirate admiral
say 41; wait
if p.fleet == 0xFF: lower: say 43
else:
    nat = fleet / 10 (DS:0x866 names, 6 = 해적);  kind = fleet%10 == 0 ? 0 : (fleet%10)/5 + 1  (menu 11: 함대/상선대/전함대)
    lower: say 42; p.role == 1 ? say 137 (nat, kind, p.given) : say 138 (nat, kind, roleName[p.role], p.given)
wait; return 1
```

### 3.3 한턱내기 for one person 0x25CCC
```
price = drinkPrice[market([0xC3A]).+0x24]         # DS:0x7FA bytes, table §8.1
if price > gold: lower: say 76; wait; return 1
pay(price)
job hooks (tavern_jobs §1.5: commission 11 informant → map sale; job 5 debtor → 0x25BD7)
lower window:
if ((hero.+0x2F ^ p.+0x2F) & 3) == 0: say (B5E8 ? 861 : 44); k = 3      # same type: "마음이 맞을 것 같군"
else:                                 say (B5E8 ? 861 : 45); k = 1
wait
p.+0x2B = min(100, p.+0x2B + 6·k·(p.+0x2F & 0x40 ? 2 : 1))     # +18/+36 or +6/+12
best = first index of the max of the FIVE abilities +0x1C..+0x20 (통솔..용기)
if p.+0x2B > 30 and ability[best] > 75: lower: say 46; say 139 (abilityName[best]); wait
return 1
```
Pirate admirals (861) still gain friendship. No limit per day; each treat costs one drink.

### 3.4 항해자정보 0x25E34 — a rumour, not an info screen
After the job hooks (commission 11 → map sale; job 5 → debtor):
```
t = min(99, [0xC3A] + rand(8));  port = t − min(rand(4), t)        # port index cur−3 .. cur+7, clamped
q = first person 0..119 with +0x2D == port and +0x31 & 0x20 (any person, tavern or inn)
lower window:
if port == [0xC3A]: say 47 (drinkName of this port)                 # small talk
elif q found:       say 570 (port.name, q.family)                    # "%s[원작 문장 생략]…"
else:               say 571 (port.name)
wait; return 1
```
Free, writes nothing. It does not show the patron's own stats.

### 3.5 고용 0x2609F (already ported; summary)
ax = 1 tavern / 0 inn. Hooks; hero window msg 48; 0x25F54: role ≠ 0 → 49; no free officer slot → 140;
**tavern only:** friendship ≤ 30 → 141. Then k = person's best of 7 abilities, `pv = (navLv+batLv)·A[k]`,
`hv = (hero navLv+batLv)·hero.A[k]`, accept if `rand(20) + pv < hv + hv·rank/10` (rank = family `+0xD`)
→ 0x25FBF: wage `min(20, pv/400 + rand(3) + 1)·10`, msg 142, yes → 144, `+0x2D = 0xFF`, fleet = hero's,
role 6, `+0x2B += 10` (cap 100), slot = index, wage/10; no → 143. Refused → 145.
**Inn hiring skips the friendship test.**

## 4. 항해자와대화 at the inn (building 4, menu 4 item 0 → 0x28592)

```
loop 0x283A4: n = inn list 0x12C4B
   n == 0              → officer window, msg 67; stop
   [0x574] == 0xFF     → face 0x7CCE(port nation), msg 68 ("a navigator is drinking in the tavern"); stop
   pick (layout 0x86, 0x153BF); Esc → stop
   portrait 0x7D9F(person); 0x28409(person); close
0x28409:
   [0xB6B8] = index; [0xC13C] = ptr
   own officer (same fleet): say 69/70/71 (rand 3); wait; return
   fleet 60–69: say 859 + rand(2); wait; return              # no menu, [0xB5E8] untouched
   say 72; wait; lower:
      fleet == 0xFF → 75;  role == 1 → 73 (nat, kind, given);  else 74 (nat, kind, roleName, given)
   menu 3 with 2 items (항해자정보, 고용; 결투 hidden), dispatch DS:0xB6BA, ONE choice:
      항해자정보 0x283F7 → 0x27112: [0xBECE]=[0xB6B8], [0xB5E2]=ptr, 0x25E34 (§3.4)
      고용       0x28400 → 0x27122: same, 0x2609F(ax = 0)
```
No 한턱내기 at the inn (so no friendship gain there), and the menu closes after one action.

## 5. Tavern girls (여급)

### 5.1 Record DS:0x2B56 + 17·i (30 records, 0x5B0C)
| off | meaning |
|---|---|
| +0x0 | name[11] |
| +0xB | **age** (msg 404); +1 every new year (0x15A79, together with person `+0x2A`) |
| +0xC | port |
| +0xD | **affection** 0..100 |
| +0xE | investigation request: `nation | category << 4`, 0xFF none |
| +0xF | days until the request is done (0xFF none); daily −1 while ≠ 0/0xFF (0x190D1 from 0x190F9) |
| +0x10 | flags: 0x01 "easy-going" (조사의뢰 needs 40 not 80; gift refusal 330 vs 331; female hero needs it), 0x02/0x04 never tested natively, **0x08 present**, **0x30 taste** (>>4), **0x40 heroine** (not a barmaid; greets at entry) |

Portrait = KAO index `0x61 + i`. New-game data (affection 0, no request in all):

| i | name | age | port | flags | taste | bit0 | present | heroine |
|---|---|---|---|---|---|---|---|---|
| 0 | 카를로타 | 38 | 0 리스본 | 0x6F | 2 | 1 | 1 | **1** |
| 1 | 루치아 | 16 | 0 리스본 | 0x3F | 3 | 1 | 1 | 0 |
| 2 | 라디아 | 19 | 2 이스탄불 | 0x3D | 3 | 1 | 1 | 0 |
| 3 | 프로라 | 20 | 3 바르셀로나 | 0x1F | 1 | 1 | 1 | 0 |
| 4 | 테레사 | 17 | 7 마르세이유 | 0x0E | 0 | 0 | 1 | 0 |
| 5 | 마틸다 | 22 | 8 제노바 | 0x1F | 1 | 1 | 1 | 0 |
| 6 | 지아나 | 17 | 13 베네치아 | 0x0E | 0 | 0 | 1 | 0 |
| 7 | 뮤리네 | 21 | 16 아테네 | 0x2D | 2 | 1 | 1 | 0 |
| 8 | 넬리 | 19 | 18 알렉산드리아 | 0x39 | 3 | 1 | 1 | 0 |
| 9 | 안나 | 20 | 26 세우타 | 0x1E | 1 | 0 | 1 | 0 |
| 10 | 엘레느 | 23 | 27 보르도 | 0x1C | 1 | 0 | 1 | 0 |
| 11 | 리리안 | 22 | 29 런던 | 0x1F | 1 | 1 | 1 | 0 |
| 12 | 완다 | 21 | 32 엔트워프 | 0x2A | 2 | 0 | 1 | 0 |
| 13 | 릴 | 20 | 33 암스테르담 | 0x3F | 3 | 1 | 1 | 0 |
| 14 | 크라우디아 | 19 | 35 함부르크 | 0x2D | 2 | 1 | 1 | 0 |
| 15 | 안나 | 20 | 37 스톡홀름 | 0x3D | 3 | 1 | 1 | 0 |
| 16 | 나타리 | 21 | 40 리가 | 0x0D | 0 | 1 | 1 | 0 |
| 17 | 이사벨 | 24 | 44 아바나 | 0x1E | 1 | 0 | 1 | 0 |
| 18 | 아메리아 | 18 | 45 마르가리타 | 0x3F | 3 | 1 | 1 | 0 |
| 19 | 실비아 | 18 | 53 리우데자네이로 | 0x1D | 1 | 1 | 1 | 0 |
| 20 | 베리사 | 19 | 59 산조지 | 0x3C | 3 | 0 | 1 | 0 |
| 21 | 예루마 | 21 | 62 아르긴섬 | 0x1B | 1 | 1 | 1 | 0 |
| 22 | 하토라 | 20 | 66 소팔라 | 0x3D | 3 | 1 | 1 | 0 |
| 23 | 하디 | 22 | 75 카이로 | 0x25 | 2 | 1 | **0** | 0 |
| 24 | 사라이 | 20 | 77 메카 | 0x0C | 0 | 0 | 1 | 0 |
| 25 | 쿤티 | 19 | 85 고아 | 0x2D | 2 | 1 | 1 | 0 |
| 26 | 루키아 | 21 | 86 말라카 | 0x1E | 1 | 0 | 1 | 0 |
| 27 | 티티스 | 18 | 88 반다 | 0x0E | 0 | 0 | 1 | 0 |
| 28 | 미화 | 19 | 97 장안 | 0x3F | 3 | 1 | 1 | 0 |
| 29 | 오나쓰 | 17 | 99 나가사키 | 0x2D | 2 | 1 | 1 | 0 |

(port names as in the port table.) At most one barmaid per tavern = the first present non-heroine
girl of the port. Taste: 0 clothes/accessories (405), 1 jewels (406), 2 "your sincerity" (407),
3 "talking with you" (408).

### 5.2 여급과대화 0x26CCB
```
items = hero female ? [조사의뢰, 정보수집] : [자기자랑, 선물, 조사의뢰, 정보수집]     # menu 14
keeper says 146 (girl.name); wait
if gold < 10: officer window (0x8EBE), say 147; wait; close; return
gold -= 10                                      # no status redraw here
loop menu (dispatch DS:0xB606: 0x262D5, 0x263F8, 0x26862, 0x26C59) until Esc:
    if item != 선물: girl window 0x7D45(0x61 + i, name)
    handler; if item != 선물: close windows
```
One 10-gold fee covers any number of actions in the session.

### 5.3 자기자랑 0x262D5 (boast of a discovery)
```
taste = (g.+0x10 >> 4) & 3
list = sites s in 0..99 with !(site.+6 & 0x80) and (site.+6 & 0x20)   # found — or treasure map bought
if empty: girl says 312; wait; return
s = picker (layout 0x92); Esc → return
show discovery 0x34043(s)
gain = site.+5 / 10 + 1                       # site value 10..100 → 2..11
girl says 313
if taste >= 2: gain *= 2; say boast[site.+6 & 7]; [0xC3C] &= ~0x40
wait
if [0xC3C] & 0x40: return                      # already earned today
g.+0xD = min(100, g.+0xD + gain); [0xC3C] |= 0x40
```
boast[category] (category names DS:0x8DA): 0 보물 314, 1 원주민 315, 2 희귀한 동물 316, 3 식물 317,
4 유적 318, 5 괴물 319, 6 자연 320, 7 원주민 315.
So: taste 0/1 → one boast per day (shared flag), taste 2/3 → doubled and **unlimited** (the flag is
cleared first).

### 5.4 선물 0x263F8 (gift)
```
taste = (g.+0x10 >> 4) & 3
list = inventory items with type (+0x19 & 0xF) 10 (장신구) or 11 (보물)    # 0x12E82
if empty: girl window; say (g.+0x10 & 1 ? 330 : 331); wait; return
loop: it = picker (layout 0x8D); Esc → return
      item info 0x28CD2(it); if !yes_no(): continue
      break
girl window; type = item.+0x19 & 0xF; girl says 321
gain = min(10, item.+0x18)
liked = taste 0 and type 10 → say 322 | taste 1 and type 11 → say 323 | taste 3 → say 324 | (taste 2: never)
if liked: gain *= 2; if g.+0xD >= 80: wait; girl says 325 (kiss)
wait
g.+0xD = min(100, g.+0xD + gain)
remove the first inventory slot holding it (0xFF); close
```
No daily limit. Gift items (value `+0x18`, list price `+0x16`×100):

| id | item | type | value | gain (liked) |
|---|---|---|---|---|
| 44 | 왕관 | 10 | 1 | 1 (2) |
| 50 | 비단 숄 | 10 | 3 | 3 (6) |
| 51 | 차이나드레스 | 10 | 8 | 8 (16) |
| 52 | 은제 머리장식 | 10 | 5 | 5 (10) |
| 53 | 백금 머리빗 | 10 | 10 | 10 (20) |
| 54 | 담비털 가운 | 10 | 12 | 10 (20) |
| 55 | 서클렛 | 10 | 4 | 4 (8) |
| 56 | 공작깃털 부채 | 10 | 3 | 3 (6) |
| 57 | 비단 리본 | 10 | 2 | 2 (4) |
| 58 | 벨벳 가운 | 10 | 5 | 5 (10) |
| 59 | 다이아몬드 왕관 | 11 | 100 | 10 (20) |
| 60 | 진주 팔찌 | 11 | 10 | 10 (20) |
| 61 | 루비 지팡이 | 11 | 50 | 10 (20) |
| 62 | 은 촛대 | 11 | 3 | 3 (6) |
| 63 | 비취 보석상자 | 11 | 20 | 10 (20) |
| 64 | 보관 | 11 | 60 | 10 (20) |
| 65 | 금 팔찌 | 11 | 15 | 10 (20) |
| 66 | 사파이어 반지 | 11 | 20 | 10 (20) |
| 67 | 공작석 상자 | 11 | 10 | 10 (20) |
| 68 | 백금 브로치 | 11 | 20 | 10 (20) |
| 69 | 루비 반지 | 11 | 25 | 10 (20) |

### 5.5 조사의뢰 0x26862 (fleet investigation)
```
if g.+0xE != 0xFF:
    if g.+0xF != 0: girl says 537; wait; return          # not done yet
    report 0x26648(); return
if hero not female and g.+0xD < 80 / ((g.+0x10 & 1) + 1): girl says 533; wait; return   # need 80 (40)
new request 0x26570()
```
**New request 0x26570** (free):
```
girl says 534; nat = menu of DS:0x866 names, 7 items (포르투갈..해적); Esc → return
g.+0xE = nat; girl says 535
cat = menu 45 if nat == 6 else menu 44, 3 items; Esc → g.+0xE = 0xFF; return
g.+0xE |= cat << 4
g.+0xF = rand(3) + (110 − g.+0xD) / (5 · ((hero.+0x31 & 0x10) + 1))     # male: aff 80 → 6–8 days, 100 → 2–4
girl says 536 (g.+0xF); wait
```
Categories → fleet numbers `nat·10 + k`, k from DS:0xB5F6 = `1,5,7,10`:

| cat | menu 44 (nations) | menu 45 (nat 6) | k |
|---|---|---|---|
| 0 | 상선대 | 카리브해적 | 1–4 |
| 1 | 경비함대 | 코르세르 | 5–6 |
| 2 | 외양함대 | 사략선대 | 7–9 |

**Report 0x26648** (live data at the time of the report, not of the request):
```
girl says 538; wait
nat != 6: girl says 539 (nationName); say 540 (catName)   else: girl says 540 (catName)
wait
for k in range(cat):
    f = fleet[nat·10 + k] (0x5B1C)
    if !(f.+0x29 & 1): say 556 (k − first + 1)        # "[원작 문장 생략]."
    else:
        [0xB5E2] = admiral; girl says 541 (admiral.family)
        mission f.+0x1B: 0,1,2 → 542 (port[+0x1C]) | 3 → 550 (port) | 4 → 551 | 5,6,7 → 543 (person[+0x1C].family)
                         8 → 549 (person.family) | 9 → 548 (port) | ≥10 → nothing
        wait
        if f.+0x21 != 0xFF: girl says 544 (goodsName[f.+0x21]); wait
        girl says 553; latlon(f.x, f.y) (0x24D58); say 554
    wait
g.+0xE = 0xFF; g.+0xF = 0xFF
```
Also reached from 업무정보 with job 4 (해적퇴치) or commission 12, **bypassing the affection test
and overwriting a pending request** (tavern_jobs §6).

### 5.6 정보수집 0x26C59 (menu 13, dispatch DS:0xB5FA)
girl says 398; loop menu (3 items; `[0xA9BA] = 1` greys 업무정보 unless `[0xCEA] != 0 && [0xCEB] != 0`):
- **업무정보 0x268C3**: job hints, tavern_jobs §6 (job-11 relic owned → affection +10 once per day).
- **그녀의취향 0x26BB8**:
  ```
  taste = (g.+0x10 >> 4) & 3
  if rand(50) < g.+0xD: girl says 405 + taste; g.+0xD = min(100, g.+0xD + (taste < 2 ? 2 : 4))
  else: girl says 403
  ```
  **No daily limit** — once affection ≥ 50 every ask succeeds (+2/+4 each, free inside one session).
- **그녀의연령 0x26C2D**: `g.+0xD > 80` → 404 (age `+0xB`), else 403. Writes nothing.

### 5.7 Who else touches girls
- Fortune teller 연애운 0x2CC63 (town.md §9.3): first present non-heroine girl of the port:
  affection ≥ 80 → 326 (names her), ≥ 50 → 327, else 328; none → 329.
- Scripts: opcode **FC b d** (`woman[b].affection += d`, cap 100, 0x31EA8) exists but **no shipped
  SNR uses it**. Scripts write the table directly: SNR1 sets 카를로타/루치아 affection := 100 (Lisbon,
  night visit) and clears 루치아 `+0x10 & 0x08` (kidnapped → no barmaid in Lisbon); SNR6 sets
  라디아 affection := 50, later 100. No script or native code **reads** affection for story logic.

## 6. 도박 0x26E14

```
if gold == 0: random face, say 1010; wait; close; return
load DATA1.LZW entry 9 (cards/dice graphics) into a 0x15C0 buffer ([0xC6F2])
loop: menu (2 items, strings DS:0xB616 "Black Jack", DS:0xB621 "Dice"), dispatch DS:0xB626:
      0x2E263 (2DA1:0853), 0x2F620 (2DA1:1C10); until Esc
redraw the tavern
```
Common: both games return silently if gold < 10. **Bet = 10 .. min(gold, 500)** (0x2DA11), taken from
gold when placed. Gold is shown as 금괴 `gold / 10000` (msg 960) + 금화 `gold % 10000` (959); bet
prompt 995/996, 962. Winnings are added without the 600,000,000 cap. Native RNG only; no stat,
fame or time effect, no daily limit.

### 6.1 Black Jack 0x2E263
```
face = rand(0x3FFF) | 0xC000 (random dealer); start = gold
say 979; if !yes_no(): return
repeat: round 0x2E09B
        if gold >= 10: say 981; again if yes   else: say 980; wait; break
if gold == 0: return
if gold > start + 500: say 982; wait
if gold + 500 < start: say 983; wait
```
**Round 0x2E09B.** Cards 0..51: rank `c % 13` (0 A, 1–8 = 2–9, 9 = 10, 10 J, 11 Q, 12 K), suit `c / 13`;
value `min(10, rank + 1)`, hand total adds 10 once if it holds an ace and the sum ≤ 11 (0x2DBB2).
Shoe 0x2DA2A: fresh 52-card deck, 208 swaps `deck[k % 52] ↔ deck[rand(52)]`, first 24 cards used.
```
cards[0] = player's first card (shown), cards[1] = dealer's hole card (face down)
bet = 0x2DBEE: show gold, numinput(10 .. min(gold,500)); remark 963 if bet < 20, 964 if > 200, else 965
gold -= bet
player: next = 2; loop                      # player cards = cards[0], cards[2..]
    deal cards[next++]; total; show 978
    if total > 21: P = 0 (bust); break
    menu ＨＩＴ/ＳＴＡＮＤ: STAND → P = total; break      # Esc counts as HIT
    if next == 8: P = total; break           # max 7 cards
dealer: hand = hole + cards[next..]; draw until total >= 17 (soft 17 stands) or 6 cards
    if total >= 17: reveal hole, show 978; D = total > 21 ? 0 : total    else D = total (hole never shown)
settle 0x2DD9D(P, player count pc, D, bet, cards, last dealer index)
```
**Settle** (ties and double busts go to the dealer):
```
if D < P:                                           # player wins, mult pm
    P == 21 and pc == 2: {cards 0 and 10 (A + J of suit 0)} → 6 (966) | either card J/Q/K → 3 (967) | A + 10 → 2 (968)
    P == 21 and pc == 3: sort the 3 cards by id; same rank (7-7-7) → 4 (969);
                         ids consecutive (same-suit run, also Q-K-A across a suit boundary) → 4 (970); else 2 (968)
    otherwise: pc >= 5 → 4 (971) else 2 (968)
    gold += pm · bet                                # net +(pm−1)·bet
else:                                               # dealer wins, extra penalty dm
    dc = dealer card count
    D == 21 and dc == 2: {hole, 2nd} = {0, 10} → 4 (972) | a J/Q/K → 1 (973) | else 0 (974)
    D == 21 and dc == 3: 777 → 2 (975); same-suit run → 2 (976); else 0 (974)
    dc >= 5 and D != 0: 2 (977)       (also for D == 21 with ≥ 5 cards)
    else 0 (974)
    if dm·bet > gold: gold = 0 else gold −= dm·bet  # net −(dm+1)·bet, never below 0
wait
```
Net results: natural A+J of suit 0 +5×, other A+face +2×, 777/run/5-card +3×, plain win +1×;
dealer specials cost 5×/2×/3× the bet in total.

### 6.2 Dice 0x2F620 (poker dice vs two players)
```
start = gold; set up two random-faced opponents; order = 0
opp A says 1001; if !yes_no(): return; opp B says 1002
repeat: round 0x2F233(&order); wait
        if gold >= 10: say 1005; again if yes (and gold >= 10)
        else: A says 1003, B says 1004; wait
if gold == 0: return
if gold > start + 500: A 1006, B 1007        if gold + 500 < start: A 1008, B 1009
```
**Round 0x2F233:**
```
show gold; max = min(gold, 500); asker = rand(2) says 962
bet = numinput(10 .. max); bet = negotiate 0x2F048(asker); gold -= bet
roll order: order 0 → A,B,you; 1 → B,you,A; 2 → you,A,B
each roller: 0x2EE2A (5 dice, up to 3 rolls), faces 0 → 6, show hand name (0x2F1F7)
r = compare 0x2E8DD(you, A, B)
r 0: say 997; gold += 3·bet; order = 2                 # you win the pot (net +2·bet)
r 1: say 998; order = 0      r 2: say 998; order = 1   r 3 (A,B tie above you): say 998; if order == 2: order = 0
r 4 (three-way tie): say 999; gold += bet
r 5 (you = A on top): if order == 1: order = 2;  r 6 (you = B): if order == 0: order = 1
r 5/6 (and any r > 6): say 1000; gold += 3·bet / 2        # net +bet/2
```
**Rolling 0x2EE2A:** unheld dice get `rand(6)` (0 means six), then the 5 dice are insertion-sorted
ascending on the raw value (so sixes come first) with their hold flags. Opponents: after each of the
first two rolls hold every die that matches another die (0x2E68C) and re-roll the rest — always 3
rolls. You: after roll 1 and 2, msg 984 "이 눈으로 승부를？" yes → stop; no → toggle holds (menu
0x13E63, 5 entries, "hold" marks); toggled dice become permanently held; all five held → stop.
**Hand rank 0x2E70A** = number of equal pairs among the 5 dice: 10 파이브 다이스 > 6 포 다이스 >
4 풀 하우스 > 3 쓰리 다이스 > 2 투 페어 > 1 원 페어 > 0 (blank). No straights; names DS:0xB9F6.
**Tie-break keys** (higher face wins; kickers ignored): five → d[0]; four/three → d[2] (middle die
of the raw-sorted hand); full house → d[2] then the pair; two pair → first pair in raw-sorted order
(0x2E745: sixes if any, else the **lower** pair) then the other pair; one pair → the pair; blank → tie.
**Compare 0x2E8DD:** you strictly best → 0; someone above you → 1/2 (A/B; equal → 3, A vs B keys);
exactly one opponent tied with you on top → 0/1/2 or 5/6 by the keys; all three equal rank → keys,
best wins, two on top → 3/5/6, three → 4. Original-code defects in the all-equal-rank path:
- one pair, all three pair values equal → returns **2** (B wins) instead of 4;
- four/three of a kind with you = B on top (A lower) → returns an **uninitialised** local;
- two pair with you = B on first pair: B's better second pair returns 1 instead of 2 (same gold);
- all three blank → returns an **uninitialised** local.

**Bet negotiation 0x2F048(asker):**
```
if bet >= 200 or rand(4) == 0: asker says 993, other says 994
else:
    prop = bet + bet·(rand(bet < 100 ? 10 : 5) + 1)/10      # +10..100 % (or +10..50 %)
    other says 985 (prop); yes_no:
      yes → bet = prop; asker 986; other 987
      no  → rand(3) == 0: asker 991 (bet kept); other 992
            else bet = rand(2) ? prop : (prop + bet)/2:  == prop → asker 988, other 987; else asker 989, other 990
bet = min(bet, max)
```

## 7. 밀회 (palace menu 16, item 4)

Not implemented in this build. The palace (0x2A424) loads menu 16 and shows it with **bl = 4**
(알현, 망명, 자금원조, 선박원조); dispatch DS:0xB742 holds exactly four far pointers (0x29EDD,
0x29FB0, 0x2A0CD, 0x2A155) followed by unrelated data; menu 16 is loaded nowhere else, and
MESSAGE.DAT and the SNR texts contain no tryst lines. The remaster should omit it. (Same for the
hidden 결투 of menus 3/12.)

## 8. Tables

### 8.1 Drinks (market `+0x24`; names DS:0x7DE, prices DS:0x7FA)
럼주 3, 와인 4, 위스키 5, 브랜디 6, 진 3, 맥주 3, 보드카 2, 테킬라 2, 야자주 1, 유주 1, 민트차 3,
소주 2, 라오주 3, 탁주 2.

### 8.2 Name tables
nation DS:0x866: 포르투갈, 에스파니아, 오스만제국, 영국, 이탈리아, 네덜란드, 해적, (측량).
role DS:0x858 and ability DS:0x87E: see §0. Dispatch: DS:0xB632 (menu 15), DS:0xB5EA (menu 12),
DS:0xB5FA (menu 13), DS:0xB606 (menu 14), DS:0xB6BA (inn menu 3), DS:0xB626 (gambling), DS:0xB742
(palace). Black Jack strings DS:0xB90C (A..K), DS:0xB94A ＨＩＴ, DS:0xB951 ＳＴＡＮＤ.

### 8.3 Messages
| msg | text |
|---|---|
| 17 | `어머！ %s씨.\n%s(는) 좀 어떠세요？` (heroine) |
| 18 | `[원작 문장 생략].` |
| 35 | `[원작 문장 생략]？` |
| 38 / 39 | `[원작 문장 생략].` |
| 41 / 42 / 43 | `[원작 문장 생략]？` / `저는 ` / `[원작 문장 생략].` |
| 44 / 45 | `[원작 문장 생략].` / `고마워！` |
| 46 / 139 | `나는 이래봬도 ` + `%s에는 자신 있지.` |
| 47 | `[원작 문장 생략]？` |
| 67 / 68 | `[원작 문장 생략].` |
| 69–71 | `[원작 문장 생략].` / `…출항일은 언제입니까？` |
| 72 | `[원작 문장 생략]？` |
| 73 / 74 / 75 | `나는 %s %s의 %s제독이다.` / `나는 %s %s의 %s, %s(이다).` / `[원작 문장 생략]！` |
| 76 | `[원작 문장 생략].` |
| 134–136 | `[원작 문장 생략].` / `…술은 적당히 합시다.` / `…[원작 문장 생략]？` |
| 137 / 138 | `%s %s의 %s(다).` / `%s %s의 %s, %s(다).` |
| 146 / 147 | `%s([원작 문장 생략].` |
| 307 / 308 | `[원작 문장 생략].` / `어머나, 어서 오셔요.` |
| 312 / 313 | `[원작 문장 생략].` / `와！ 신기해라！\n` |
| 314–320 | `너무나 예뻐요！` `어떤 옷을 입었던가요？` `물리지 않았나요？` `어떤 꽃이 필까？` `[원작 문장 생략]……` `무섭지 않았어요？` `[원작 문장 생략]！` |
| 321–325 | `아！ 좋아라！ ` `저…… 어울려요？` `[원작 문장 생략].` `고마워요.` `[원작 문장 생략]！ ` |
| 330 / 331 | `[원작 문장 생략].` |
| 398 / 403 / 404 | `무엇을 듣고 싶은가요？` / `[원작 문장 생략].` |
| 405–408 | `[원작 문장 생략]？` |
| 533–544 | `안돼요. 바쁜걸요.` `[원작 문장 생략]？` `어떤 함대인가요？` `[원작 문장 생략].` `%s의 ` `%s에 관한 정보였었죠？` `%s제독의 함대는 ` `%s(를) 향하고 있어요.` `%s[원작 문장 생략].` |
| 548–551 | `%s항을 경호하고 있어요.` `%s[원작 문장 생략].` |
| 553 / 554 / 556 | `[원작 문장 생략] ` / `근처가 아닐까？` / `[원작 문장 생략].` |
| 570 / 571 | `%s[원작 문장 생략].` |
| 857 / 858 | `%s[원작 문장 생략]？` |
| 859 / 860 / 861 | `[원작 문장 생략].` |
| 959 / 960 | `소지금 금화 %4ld` / `금괴 %4ld` |
| 962–978 | `도박금은 얼마요？` `[원작 문장 생략].` `정말로 좋겠소？` `그럼 카드를 돌리겠다.` `[원작 문장 생략]！` `네가 이겼다.` `[원작 문장 생략]…` `시퀀스냐！ …３배…` `５장이냐！ …３배…` `[원작 문장 생략]！` `스리세븐이다！\n…３배를 내줘.` `시퀀스다！…` `５장이다！…` `합계 %2d` |
| 979–983 | `[원작 문장 생략].` `한판 더 안 하겠소？` `[원작 문장 생략]！` |
| 984–996 | `이 눈으로 승부를？` `[원작 문장 생략].` `그래, 그렇게 나와야지.` `[원작 문장 생략].` `좋소.` `[원작 문장 생략]！` `할 수 없군.` `그걸로 좋소.` `나도.` `도박금 (10-%3ld)` `도박금 (10-%3ld)%3ld` |
| 997–1010 | `쳇, 제법인데！` `[원작 문장 생략].` `멋진 승부인데！` `당신네들 정말 세군！` `[원작 문장 생략]？` `헛, 봉이 또 오는군！` `[원작 문장 생략].` `돈이 생기면 또 오게！` `또 한판하지 않겠소？` `[원작 문장 생략]？` `흐흐, 역시 봉이였어！` `[원작 문장 생략].` |

Unused: 309–311 (`와 주셔서 너무 기뻐요.` `이쪽으로 오세요.` `오늘밤, 시간 있어요？` — no loader found),
961 `--- not use ---`.

## 9. Open questions / quirks to decide
1. **Female-hero flag** (hero `+0x31 & 0x10`): no writer found in MAIN.EXE or SNR scripts and clear in
   the new-game data; OPEN.EXE (hero selection) was not checked. If it is never set, the female branches
   (no 자기자랑/선물, free 조사의뢰, faster reports, entry greeting 307/308, barmaid presence test) are
   dead. If Catalina is meant to have it, 0x26F55 tests the **stale** `[0xB5E6]` instead of the found girl.
2. Heroine greeting always shows girl 0 (카를로타) even if another girl had bit 0x40.
3. 그녀의취향 and taste-2/3 자기자랑 have no daily limit; reproduce or cap?
4. 자기자랑 lists sites with flag 0x20, which is also set when only the treasure map was bought.
5. Dice compare defects (§6.2) — the remaster should pick sane values (4 / 6 / 2 / 4).
6. Blackjack "sequence" accepts Q-K-A crossing suits (raw ids 11,12,13 etc.); 21 needs that or 6-7-8.
7. 여급과대화 subtracts 10 gold without redrawing the status bar.
8. 조사의뢰 report writes the admiral into `[0xB5E2]` (harmless; reset on the next pick).
9. Girl `+0x10` bits 0x02/0x04: not tested natively (maybe meant for scripts).

## Sources
Tavern entry 0x26FF5, 0x26F15, 0x26F55, 0x26FA2; dismiss 0x25356 + 0x2515E (hire 0x252A7, 0x24E2B,
0x25070); talk 0x26293/0x26224/0x26268/0x261C0, greeting 0x25988, treat 0x25CCC, info 0x25E34, hire
0x2609F/0x25F54/0x25FBF; lists 0x12B5D/0x12BEB/0x12C4B; inn 0x28592/0x283A4/0x28409/0x283F7/0x28400,
0x27112/0x27122; girls 0x26CCB, 0x262D5, 0x263F8, 0x12E82, 0x26862, 0x26570, 0x26648, 0x26C59,
0x26BB8, 0x26C2D, daily 0x190F9/0x190D1, yearly 0x15A79; gambling 0x26E14, Black Jack 0x2E263,
0x2E09B, 0x2DD9D, 0x2DBEE, 0x2DA2A, 0x2DBB2, 0x2DD8A, 0x2DA11; Dice 0x2F620, 0x2F233, 0x2EE2A,
0x2EDAB, 0x2E68C, 0x2E70A, 0x2E745, 0x2E772, 0x2E7A5, 0x2E8DD, 0x2F048, 0x2F1F7 (segment 0x2DA1,
near targets wrap in 0x2DA10..); palace 0x2A424 + DS:0xB742; SNR1/SNR6 woman writes (`tools/snr.py`).
