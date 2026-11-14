# Tavern debtor, tavern job hints, commission-11 treasure hint (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N, "menu N" = MENU.DAT entry N (all items, `\0`-separated; the
`assets/text.json["menu"]` list only keeps the first item), `S0#n` = SNR0.MES line n.
Helpers: `rand(n)` 0x4D86 (native RNG, `rand(0) = 0`; *not* the script RNG), umin 0x4D42,
umax 0x4D49, yes/no 0x13FDB (`lcall 0xfb8:0x445b`), wait-for-key 0x140EA, number input 0x58EA.
Status: everything was read from code unless marked **(inferred)**.

Text output helpers (all printf-style, `%s`/`%d` arguments pushed after the message number):

| call | effect |
|---|---|
| 0x551C (→ 0x32F2C) | print msg N into the **current** speech window (appends) |
| 0x8D4B | clear the building keeper's window (top) and print msg N there |
| 0x7E95 | clear the tavern girl's window and print msg N there |
| 0x7D71(p) | open the upper window with person p's portrait (used for the hero) |
| 0x7D9F(p) | open the lower window with person p's portrait (the person you talk to) |
| 0x7CAE | lower window with a random generated face (an anonymous patron) |
| 0x7E07 / 0x7DCD | select + clear the lower (other speaker) / upper (hero) window |
| 0x780F | close the speech windows |
| 0x86F2 | redraw the status bar (gold) |

## 0. State

| what | where | notes |
|---|---|---|
| SNR0 chapter / block | `[0xCEA]` / `[0xCEB]` | chapter ≠ 0 ⇔ a job or royal commission is under way. **Every native job test first checks `[0xCEA] != 0`**, because v6 keeps its value after the job ends |
| v6 = job code | `[0xD00]` u16 | = the SNR0 chapter: 1 상품수송, 2 상품구입, 3 편지배달, 4 해적퇴치, **5 빚독촉**, 6–12 royal commissions (**11 = treasure**) |
| v16 | `[0xD14]` u16 | job 5: 13 (Venice, the bank). Commission 11: guild port that has the lead (255 = not yet chosen) |
| v17 | `[0xD16]` u16 | job 5: **debtor** person index. Commission 11: **informant** person index (255 = not yet chosen). Native code compares only the low byte with the selected person |
| v18 | `[0xD18]` u16 | job 5: **255 = still owed, 0 = collected**. Commission 11: relic item 90–96 (its map is item v18 − 10, 80–86) |
| v19 | `[0xD1A]` u16 | job 5: debt units (1 at tier 0, 2 at tier ≥ 1); one unit = 5 gold bars = 50,000 gold |
| v23 | `[0xD22]` u16 | rank tier `min(rank, 6) / 3` (0, 1, 2), written by SNR0 chapter 0 block 0 at the guild/palace |
| f16 / f17 / f18 | `[0xCEE]` bits 0 / 1 / 2 | promotion due / summoned / commission accepted (town.md §5) |
| selected person | `[0xBECE]` (index), `[0xB5E2]` (record ptr) | set by the tavern's 항해자와대화 (0x262AC/0x262BA) and by the inn stubs 0x27112/0x27122 |
| inn's selected person | `[0xB6B8]` | copied into `[0xBECE]`/`[0xB5E2]` by 0x27112/0x27122 |
| tavern girl | `[0xB5E6]` → record DS:0x2B56 + 17·i | `+0xD` affection |
| "pirate patron" | `[0xB5E8]` | 1 if the patron is admiral of a fleet 60–69 (set by the greeting 0x25988) |
| tavern mood | `[0xB5E0]` | |
| hero person | `[0xC67A]` → person record | `+0x23` 운 (luck), `+0x22` 매력 (charm) |
| current port | `[0xC3A]` | |
| gold | DS:0x123A u32 | |
| inventory | DS:0x2D93 × 20 bytes | 0xFF = empty |
| person record | DS:0x1242 + 50·i (0x5AEC), 120 persons | `+0` given name, `+0xD` family name, `+0x2C` fleet (0xFF none), `+0x2D` port where he waits (0xFF at sea), `+0x2F` bit 0x10 = drinks in the **tavern** (clear = stays at the **inn**), `+0x31` bit 0x20 = slot in use |
| port record | DS:0x5F54 + 20·p (0x5B8E) | `+0` x u16, `+2` y u16, `+4` name |
| site record | DS:0x7E88 + 7·s (0x5BC2) | `+6` flags (0x80 inactive, 0x20 found / map bought, 0x10 reported); snr.py calls this table `supply_pt` |
| item record | DS:0x8144 + 26·i (0x5BD2) | `+0` name; map items `+0x18` = site index |

Both jobs take their person from the pool **79–119** (`rand(41) + 79`), the wandering
navigators. Whether such a person is in the tavern or the inn is decided by person `+0x2F`
bit 0x10 (random at generation, `rand(16) << 4`), so a debtor or informant may be at the **inn**.

## 1. Where the player meets the person (callers)

### 1.1 Port person list 0x12B5D
Persons 0..119 except the hero with `+0x31 & 0x20`, and either `+0x2D == [0xC3A]`, or the same
fleet as the hero (your officers), or admiral of a fleet < 70 that is in port (`fleet+0x29 & 0x10`)
at this port's coordinates. The list goes to DS:0x574.
- tavern list 0x12BEB: the entries with person `+0x2F & 0x10`;
- inn list 0x12C4B: the entries without it.
(If no entry passes the filter, `[0x574] = 0xFF` and the caller reports "nobody".)

### 1.2 Tavern (building 1, 0x26FF5)
Main menu = menu 15, dispatch DS:0xB632:

| item | text | handler | relevant here |
|---|---|---|---|
| 0 | 선원고용 | 0x252A7 | |
| 1 | 선원해고 | 0x25356 | |
| 2 | 한턱내기 (round for the house) | 0x2589E → 0x25721 | **job hint 0x25589** (§3) |
| 3 | 항해자와대화 | 0x26293 | **debtor 0x25BD7** (§2), **map seller 0x25AE0** (§5) |
| 4 | 여급과대화 | 0x26CCB | barmaid 업무정보 0x268C3 (§6) |
| 5 | 도박 | 0x26E14 | |

**항해자와대화 0x26293** loops: 0x26224 (empty list → msg 38 if mood ≥ 50 else 39) → pick a
person from the list (0x26268) → `[0xB5E2] = person`, portrait 0x7D9F(person),
`[0xBECE] = index` → **0x261C0**:
1. greeting 0x25988: your own officer → msg 134/135/136 and no menu; admiral of fleet 60–69 →
   msg 859/860, `[0xB5E8] = 1`; otherwise msg 41 + description (42 + 137/138, or 43).
2. menu 12 shown with **3 items** (`bl = 3` = item count for 0x13CA3), dispatch DS:0xB5EA:
   한턱내기 0x25CCC, 항해자정보 0x25E34, 고용 0x261B8 (= 0x2609F with ax = 1).
   Menu 12's 4th item **결투 is never shown** (the 4th table word is garbage).
3. a handler returning 0 ends this person's menu (the debtor ran away).

### 1.3 Inn (building 4, 0x286A5)
Menu 4 item 0 항해자와대화 (DS:0xB6D2 → 0x28592): inn list 0x12C4B (empty → msg 67/68), pick, portrait
0x7D9F, greeting 0x28409 (`[0xB6B8] = index`), then menu 3 with **2 items** (`bl = 2`; 결투
hidden), dispatch DS:0xB6BA:
- 항해자정보 0x283F7 → 0x27112: `[0xBECE] = [0xB6B8]`, `[0xB5E2] = record`, → **0x25E34**
- 고용 0x28400 → 0x27122: same, → **0x2609F with ax = 0**

### 1.4 At sea
Hail (교섭, 0x20403 → 0x1FABD): if `[0xCEA] != 0 && v6 == 11 && (u8)v17 == admiral` →
0x7D9F(admiral), **0x25AE0**, 0x780F, return 1 (no battle). Only commission 11 has this hook.

### 1.5 The job hooks in the person handlers

All tests are skipped when `[0xCEA] == 0`. `sel` = `[0xBECE]`.

| handler | before the test | commission 11 test → action | job 5 test → action |
|---|---|---|---|
| 0x25CCC 한턱내기 (one person) | drink price `p = DS:0x7FA[market.+0x24]`; `p > gold` → msg 76, return 1; else pay p (0x24EBB) | `v6 == 11 && sel == (u8)v17 && v18 != 0` → 0x7D9F(sel), 0x25AE0, 0x780F, return 1 | `v6 == 5 && sel == (u8)v17 && v18 != 0` → **return 0x25BD7()** |
| 0x25E34 항해자정보 | — | `v6 == 11 && sel == (u8)v17` → same as above | `v6 == 5 && sel == (u8)v17 && v18 != 0` → return 0x25BD7() |
| 0x2609F 고용 | — | same as 0x25E34 | same as 0x25E34 |
| 0x1FABD hail at sea | — | `v6 == 11 && admiral == (u8)v17` | — |

If no hook fires, the handler does its normal job (treat: msgs 44/45/861 and friendship
`+0x2B`; info: msg 570/571/47; hire: msgs 48, 140–145).
So the scene is triggered by **any** of the three choices once you have picked the right
person; only 한턱내기 costs a drink first.

## 2. Debt collection (빚독촉): debtor encounter 0x25BD7

### 2.1 The job around it (SNR0)
- Briefing (chapter 0 block 5, guild): S0#8 "$r32[원작 문장 생략]
  있는데. 떠맡겠나？" with v16 = 13; accept → v6 = 5 → SNR0 chapter 5, block 0.
  **The briefing also writes v17 = 13 + rand(20) + {1, 16, 31}[tier]** (a port offset that is
  not used by this job) and does not touch v18/v19.
- **Chapter 5 block 0** (Venice 13, bank 8), first visit:
  `repeat v17 = rand(41) + 79 until person[v17].+0x2D != 0xFF and (tier 0 ? port < 42 : port > 41)`;
  tier 0: v19 = 1, v20 = 1 month, v21 = 5000, v22 = 150; tier ≥ 1: v19 = 2, v20 = 3, v21 = 20000,
  v22 = 500; S0#45–47 ("$r33 $r34씨가 빌린 돈을…", "$d20개월 이내에…금화 $d21닢…", "해주시겠습니까？").
  No → S0#48, job ends. Yes → deadline v24, **v18 = 255**, block 1.
- **Chapter 5 block 1** (Venice bank): `v18 == 255` → not collected yet (S0#54/55 days left /
  cancel ×0.9 fame, or S0#56/57 late ×0.8 fame). Otherwise needs `gold / 10000 >= 5·v19`: takes
  `5 × 10000·v19` (= what the debtor paid), pays v21 and trade + pirate fame +v22 (late: v21/2,
  no fame; S0#49–51); short of money → S0#52/53, trade fame ×0.5. All end the job.

So the native encounter only has to **pay the gold and set v18 = 0**.

### 2.2 When it runs
Tavern 항해자와대화 or inn 항해자와대화, the person chosen is the debtor (`[0xBECE] == (u8)v17`),
`[0xCEA] != 0`, `v6 == 5`, `v18 != 0`, then any patron-menu choice (§1.5).

### 2.3 Logic (0x25BD7, far proc, returns 1 = still here, 0 = gone)
```
0x25BD7  open upper window with the hero's portrait (0x7D71([0x1241]))
         say 608 (given, family of the debtor)              ; hero: "%s %s[원작 문장 생략]…"
         wait
0x25BFB  if rand(100) <= hero.luck: goto PAY                 ; byte compare, +0x23
         if rand(3) != 0:            goto PAY
FLEE (0x25C18):
         lower window: say 610; wait                         ; debtor refuses and runs
         upper window: say 613; wait                         ; hero: "놓치고 말았군."
         close windows (0x780F)
         p = debtor.+0x2D
         debtor.+0x2D = (p >= 42) ? rand(58) + 42 : rand(42)  ; may be the same port again
         return 0                                            ; patron menu closes
PAY (0x25C6D):
         lower window: say 609 (5·v19); wait                 ; "…옛소！ 금괴 %d개."
         upper window: say 614; wait
         close windows
         gold += 50000 · v19          (32-bit, 0x373C; **no 600,000,000 cap here**)
         v18 = 0                      (word)
         redraw status (0x86F2)
         return 1
```
Flee chance = `(1 − min(luck + 1, 100)/100) / 3`; e.g. luck 60 → 13 %, luck 99+ → 0.
Native RNG, so a new try (after finding him again) is an independent roll. Nothing else is written
(no v63, no flags, no fame).

### 2.4 Messages
| msg | speaker | text |
|---|---|---|
| 608 | hero | `%s %s[원작 문장 생략].` (given, family) |
| 609 | debtor | `[원작 문장 생략].` (5·v19) |
| 614 | hero | `[원작 문장 생략].` |
| 610 | debtor | `[원작 문장 생략]！` |
| 613 | hero | `제기랄！\n놓치고 말았군.` |
| 76 | — | `[원작 문장 생략].` (한턱내기 only, cannot pay the drink) |

**Unused in this build:** 611 `[원작 문장 생략]！`, 612 `져, 졌다！\n빚을 갚을 테니
[원작 문장 생략]…` — no
instruction loads 0x263, 0x264 or 0x267 (full immediate scan), and the 결투 item of menus 3/12 is
hidden. There is **no duel** in the debt job; a fleeing debtor is simply lost until found again.

### 2.5 Quirks to decide on
1. **Before the first Venice bank visit** (chapter 5 block 0 not run yet) v17 still holds the
   briefing's port offset (14–33 / 29–48 / 44–63 by tier) and v18/v19 are left over from the
   previous job (a goods id, 6, 255, …; 0 only in a fresh game). If v18 ≠ 0 and the player talks
   to the person with that index, he is treated as the debtor and pays `50000 · v19` (stale v19).
   The tavern hint (§3) also points at that person. Faithful port = reproduce; a clean port would
   add `[0xCEB] >= 1` to the job-5 tests.
2. After payment v18 = 0, so the debtor scene no longer fires, but the house-round hint of §3
   keeps naming him until the job ends (it does not test v18).
3. If the debtor was found as admiral of a docked fleet (`+0x2D = 0xFF`), fleeing writes a port
   42–99 into `+0x2D` while he keeps the fleet.

## 3. Tavern job hints: house round 0x25589

### 3.1 When it runs
Tavern menu 15 item 2 **한턱내기** (0x2589E): msg 19 (drink, price), number input up to
`min(50, gold'/price)` (gold' = `gold % 10000 + 10000` when gold ≥ 10000); n = 0 → nothing.
Otherwise mood update, pay `n · price`, then **0x25721**:
```
fame line: M = max(trade, pirate, adventure fame): M < 1000 → 36; < 5000 → 132; else 133
           (in a random-face window 0x7CAE); wait
if [0xCEA] != 0:
    if 0x25589() != 0: close windows; return          # the hint replaces the rumour
    goto RUMOUR
if (f16 or f17) and not f18: king rumour 0x256DE (409, 410+nat, 416); f17 = 1; return
RUMOUR (0x257FC): pirate rumour if luck > rand(200) (msgs 37, 40) else 0x25421 / 0x2552C
```
So with a job active, the royal-summons rumour never appears, and for jobs other than 5 / 11
(and for job 11 before an informant exists) the ordinary rumour is told.

### 3.2 Logic (0x25589, returns 1 if a hint was given)
```
if v6 == 11 and v17 != 0xFF:
    for i in 0..19:
        if inv[i] == (u8)(v18 − 10) or inv[i] == (u8)v18: return 0   # map or relic already owned
if not ((v6 == 11 and v17 != 0xFF) or v6 == 5): return 0
if (s16)v17 % 3 != [0xC3A] % 3: return 0              # only a third of the ports know
p = person[(u8)v17]
if p.+0x2D != 0xFF:                                   # waiting in a port
    port = port[p.+0x2D]
    lower window: say 599 (p.given, p.family, port.name); wait
    lower window: say 600 (port.name); latlon(port.x, port.y) (0x24D58); say 601; wait
else:                                                 # at sea
    f = p.+0x2C
    kind = (f % 10 == 0) ? 0 : (f % 10) / 5 + 1        # menu 11: 0 함대, 1 상선대, 2 전함대
    lower window: say 602 (p.given, p.family, nationName[f / 10], menu11[kind]); wait
    lower window: say 603; wait
return 1
```
`nationName` = DS:0x866 word pointers: 포르투갈, 에스파니아, 오스만제국, 영국, 이탈리아, 네덜란드, 해적
(fleets 60–69 → index 6). A person at sea with no fleet (`+0x2C = 0xFF`) would index entry 25
(garbage); not expected for these persons.

**latlon 0x24D58(x, y)** (far, `retf 4`), shared by every "near N° E°" hint:
```
d = 0x280 − y;  lat = |d| · 8 / 57;  say (d >= 0 ? 126 "북위 %d도, " : 127 "남위 %d도, ") lat
s = (x + 0x7BD) mod 0x870
if s > 0x438: say 129 "서경 %d도" (0x870 − s) / 6   else: say 128 "동경 %d도" s / 6
```
(Check: 리스본 (120, 358) → 북위 39도, 서경 9도; 베네치아 → 북위 45도, 동경 13도.)

### 3.3 Messages
| msg | text |
|---|---|
| 599 | `%s %s(는) %s항에 있지.` |
| 600 | `%s항은 ` |
| 126–129 | `북위 %d도, ` / `남위 %d도, ` / `동경 %d도` / `서경 %d도` |
| 601 | `근처야.` |
| 602 | `%s %s？\n[원작 문장 생략].` |
| 603 | `[원작 문장 생략].` |

Reads only; writes nothing.

## 4. Royal commission 11: guild hint 0x2C636

### 4.1 The commission (SNR0 chapter 11)
Audience (block 1): picks the first site with `(+6 & 0xF0) == 0x80` and relic `+4` in 90–96
(v18 = that relic), S0#154–157, accept → S0#159/160, **v16 = 255, v17 = 255**, block 2.
Block 2 (audience): if the relic is in the inventory → S0#161, slot := 0xFF, gold += 100,000,
v40 += 1, rank += 1, site `+6 |= 0x10`, job ends; else S0#162 and an offer to give up
(S0#163, all three fames halved).
Relic item names: 90 순금 가면, 91 비취옥 제단, 92 고대신의 조각상, 93 흑요석의 석판, 94 암흑신의
수정구슬, 95 불뿜는 항아리, 96 파괴신의 보검; maps 80–86 = "<relic>의 지도" (가면의 지도 …).
Map item `+0x18` = the site (set at new game, town.md §10.1).

The hint chain is entirely native:
**guild (any) → guild of port v16 → tavern rumour (§3) → informant v17 (§5, buy the map)
→ land at the site and 보물탐색 (town.md §10.1, `(+6 & 0xF0) == 0xA0` gives the relic) → king.**

### 4.2 When it runs
Guild (building 6, 0x2CB18), menu 1 item 0 **업무알선** (DS:0xB8A0 → 0x2C77F):
```
if [0xCEA] != 0:
    if v6 >= 6: 0x2C636(); return                      # any royal commission
    if [0xC3A] == (u8)v16: keeper says 931 else keeper says 338 (port[v16].name); wait; return
...
```
The remaster's `guildDesk()` currently returns msg 595 for every royal commission; for
commission 11 it should run the logic below.

### 4.3 Logic (0x2C636; the linear listing shows it at 0x2C635 because of a padding byte)
```
none = 1
if v6 == 11:
    for i in 0..19: if inv[i] == (u8)(v18 − 10) or inv[i] == (u8)v18: none = 0; break
if !none or v6 != 11: keeper says 595; wait; return

if v16 == 0xFF: v16 = rand(42)                         # word write: port 0..41
if [0xC3A] == (u8)v16:                                 # this is the guild with the lead
    if v17 == 0xFF:
        if rand(v23 + 1) == 0:                         # tier 0: always; tier 1: 1/2; tier 2: 1/3
            repeat v17 = rand(41) + 79 until person[v17].+0x2D != 0xFF and < 42
        else:
            repeat v17 = rand(41) + 79 until person[v17].+0x2D != 0xFF and >= 42
    p = person[(u8)v17]
    keeper says 596 (item[v18].name, p.given, p.family); wait
    keeper says 597; wait
else:
    port = port[(u8)v16]
    keeper says 598 (item[v18].name, port.name); wait
    keeper says 600 (port.name); latlon(port.x, port.y); say 601; wait
```
The v17 search loops have no exit: if no person 79–119 waits in a port of the wanted range it
hangs (practically never). v16/v17 are chosen **once** and kept; v17 is not re-chosen when the
informant later moves or goes to sea (the tavern hint and the at-sea hail follow him).

### 4.4 Messages
| msg | text |
|---|---|
| 595 | `[원작 문장 생략]？` (other commissions, or the map/relic is already owned) |
| 596 | `%s(는) %s %s(가) 알고 있을걸？` (relic, informant given, family) |
| 597 | `[원작 문장 생략].` |
| 598 | `%s？\n%s[원작 문장 생략].` (relic, port v16) |
| 600 + latlon + 601 | `%s항은 ` `북위 …도, 서경 …도` `근처야.` |
| 931 / 338 | guild jobs 1–5: `[원작 문장 생략]？` |

Writes: v16 (`[0xD14]`), v17 (`[0xD16]`).

## 5. Commission 11 informant: map sale 0x25AE0

### 5.1 When it runs
Any hook of §1.5 with `v6 == 11` and the chosen person = v17: tavern 한턱내기 (after paying the
drink, and only if v18 ≠ 0, always true here), 항해자정보, 고용, inn 항해자정보/고용, and the hail
at sea. The caller opens the informant's portrait first (0x7D9F) and closes after (0x780F); the
handler then returns 1.

### 5.2 Logic
```
for i in 0..19: if inv[i] == (u8)(v18 − 10): say 879; wait; return   # map already bought
say 604 (item[v18].name); wait                     # "…[원작 문장 생략]…포기했네."
lower window: say 605                             # "[원작 문장 생략]？"
if !yes_no(): return                              # no message
if gold < 1000: lower window: say 607; wait; return
lower window: say 606; wait                       # "자, 지도를 받게." (printed before the slot test)
slot = first i with inv[i] == 0xFF
if none: lower window: say 880; wait; return       # no map, no charge
inv[slot] = v18 − 10
site[item[v18 − 10].+0x18].+6 |= 0x20              # site becomes searchable for the relic
gold -= 1000; redraw status
```
Only the **map** is tested here, not the relic: after the relic has replaced the map in the
inventory, the informant offers (and sells) the map again. The guild (§4) and tavern (§3) hints
test both.

### 5.3 Messages
| msg | text |
|---|---|
| 604 | `%s？\n[원작 문장 생략].` |
| 605 | `[원작 문장 생략]？` |
| 606 | `[원작 문장 생략].` |
| 607 | `[원작 문장 생략].` |
| 879 | `[원작 문장 생략]！` |
| 880 | `[원작 문장 생략].` |

## 6. Related: barmaid 업무정보 0x268C3 (also job-aware, also missing)

Tavern menu 15 item 4 여급과대화 (0x26CCB): msg 146, costs **10 gold** (msg 147 if short), menu 14
(자기자랑 0x262D5 (only if hero `+0x31 & 0x10` is clear), 선물 0x263F8, 조사의뢰 0x26862,
정보수집 0x26C59). **정보수집**: msg 398, menu 13 (업무정보 0x268C3, 그녀의취향 0x26BB8, 그녀의연령
0x26C2D; dispatch DS:0xB5FA). **업무정보 is greyed out** (`[0xA9BA] = 1`, the menu's disabled-item
mask **(inferred)**) unless `[0xCEA] != 0 && [0xCEB] != 0`. All lines go to the girl's window (0x7E95).

| v6 | answer |
|---|---|
| 4, 12 | goes straight to the fleet search 0x26570 (조사의뢰: 534–536) |
| 9 / 10 | 586 / 587 |
| 11 | own map (v18−10) → 1018 (map name); own relic → 1019 (relic name) and affection +10 (cap 100) once per visit (`[0xC3C]` bit 0x40); neither → 588 if v17 == 0xFF else 589 |
| 5 | 589 `[원작 문장 생략].` |
| 3 | 590 printed **without its port argument** (the `%s` reads a stale stack word, an original bug), then latlon(port v17), 594 |
| 7, 8 | here = port v17 → 585; else 591 (v18 < 4, 왕궁) / 592 (총독부) with nationName[v18], 593 (port v17), latlon, 594 |
| 1 | here = port v17 → 585; else if `charm + affection <= rand(150)` and hero `+0x31 & 0x10` clear → 399; else 401 (port v17) + msg 385 + market[v17].+0x21 (region) + 402 |
| 2, 6 | same charm test → 399; else first port 0..39 whose specialty (market `+0x1A`) is goods v18 and `10·[+0x1B] <= economy` → 400 (goods, port); else highest trade zone 12..0 selling v18 (`+0x6E` × 9) → 202 (goods) + 385+zone + 203; else 399 |

Chapters 3 and 4 only have block 0 in SNR0, so their rows are unreachable through this gated menu.

## 7. Open questions
1. Do we reproduce the stale-v17/v18 debtor bug of §2.5.1 (job 5 before the first Venice bank
   visit)? It is reachable whenever the previous job left v18 ≠ 0.
2. `[0xA9BA]` as the menu's disabled-item mask is inferred from its uses (tavern bits 0x01, 0x03,
   0x10; barmaid 0x01); 0x13CA3 was not traced to the drawing code.
3. The debtor's flight can pick the current port again (no exclusion); intended or not, it means
   the player may find him in the same tavern on the next 항해자와대화.
4. Barmaid row v6 = 3 (msg 590 without argument) is dead code under the block gate; nothing to
   port unless the gate is changed.
5. Commission 11 v17 search can spin forever if no person 79–119 waits in a port of the wanted
   range (§4.3); the remaster should bound it.

## Sources
Debtor 0x25BD7; patron handlers 0x25CCC, 0x25E34, 0x2609F/0x261B8, greeting 0x25988, menu loop
0x261C0, 항해자와대화 0x26293/0x26224/0x26268, inn 0x28592/0x283A4/0x28409/0x283F7/0x28400, stubs
0x27112/0x27122, person lists 0x12B5D/0x12BEB/0x12C4B; house round 0x2589E → 0x25721 → hint 0x25589,
latlon 0x24D58; guild 0x2C77F → 0x2C636; map sale 0x25AE0, hail 0x1FABD; barmaid 0x26CCB, 0x26C59,
0x268C3, 0x26570. Dispatch tables DS:0xB632 (tavern), DS:0xB5EA (patron), DS:0xB5FA (정보수집),
DS:0xB606 (barmaid), DS:0xB6D2 (inn), DS:0xB6BA (inn talk), DS:0xB8A0 (guild). SNR0 chapter 0
block 5, chapter 5 blocks 0–1, chapter 11 blocks 0–2 (`build/venv/bin/python tools/snr.py 0`).
