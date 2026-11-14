# Nation relations, war states, alliance and blockade (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image
0x378B0 + n. `nat[n]` = nation record DS:0x1106 + 32n (accessor 0x5AD2), `rel[a][b]` = byte
`nat[a].+0xB+b`, `ws[a][b]` = byte `nat[a].+0x12+b`, `power[n]` = u16 `nat[n].+0`.
`port(p)` = DS:0x5F54 + 20p (0x5B8E), `market(p)` = DS:0x697C + 37p (0x5B9E),
`support[p][n]` = byte `market(p).+8+n`. `rand(n)` = 0x4D86, `umin` = 0x4D42, long div 0x36A2.
Status: everything below was read from code unless marked **(inferred)**.

**Headline**: the monthly routine computes a war-state for every ordered nation pair, but the
code that acts on it compares the **whole byte** (flags + state) with 1 and 4. State 4 ("war",
port capture) is only ever produced for pairs that carry the blockade flag 0x10, so the byte is
0x14 and **no nation ever captures a port in the original game**. Only state 1 (relations
improve) has an effect, and only for pairs with no flag bits. States 0, 2, 3, 5, 6 have no
reader. The flags 0x20 (동맹, alliance) and 0x10 (봉쇄, blockade) are static apart from Otto's
prologue script, and are read by the guild's 나라정보, the town's harbour guards and the battle
fame/standing code.

---------------------------------------------------------------------------------------------

## 1. Where it runs

Monthly 0x189DA → 0x184C1:
```
0x17464 power        ; nat[n].+0 (fleets.md §7.1)
0x179A0 diplomacy    ; enemy +2, policy +3, target +4
0x17BD1 relations    ; this file
0x184AC fleets       ; rebuild / relaunch / standing
```
Remaster: call `relationsMonth()` in `Voyage.worldMonth` after the `choosePolicy` loop and
before `rebuildFleets` (Sources/PortolanCore/WorldMonth.swift). Power must already be the
recomputed value from `nationPower()`.

## 2. Pseudocode

### 2.1 0x17BD1 relations_month ✅
```
for a in 0..5:                        ; pirates (6) never take part, ws[*][6] never changes
    for b in 0..5:
        if a == b: ws[a][a] = 0; continue
        decide_state(a, b)            ; 0x179AD
        apply_state(a, b)             ; 0x17B46
```
Pairs are processed strictly in this order (a outer, b inner) and `apply_state` runs right
after `decide_state` for the same pair, so a relation bump for (a,b) is already visible when
(b,a) is decided later. Power is not recomputed in between. RNG order per pair: at most one
`rand` in 0x179AD (only for table values 7–10), then one in 0x17B46 (`rand(5)` for state 1,
`rand(50)` for state 4, plus `rand(10)` in 0x17AB4 when a port is taken).

### 2.2 0x179AD decide_state(a = ax, b = dx) ✅
```
pa = power[a]; pb = power[b]           ; signed 16-bit compares (jle/jg); /2 truncates
if   pa/2 >  pb: pc = 0               ; a more than twice as strong
elif pb/2 >  pa: pc = 1               ; b more than twice as strong
elif pb  <  pa:  pc = 2               ; a stronger
else:            pc = 3               ; b at least as strong
f = ws[a][b]
fc = (f & 0x20) ? 0 : (f & 0x10) ? 1 : 2   ; alliance / blockade / none (0x20 wins)
r = rel[a][b]                          ; byte 0..255
rc = (r + 9) / 40                      ; 0: 0–30, 1: 31–70, 2: 71–110, 3: 111–150
v = byte DS:0xAC74[12*rc + 3*pc + fc]
switch v:
    7:  v = (rand(100) >= r) ? 0 : 3
    8:  v = (rand(100) <= r) ? 0 : 2
    9:  v = (rand(20) + 30 <= r) ? 0 : 2
    10: v = (rand(10) + 30 >  r) ? 2 : 0
ws[a][b] = (ws[a][b] & 0xF0) | v       ; v is OR-ed whole: values > 15 also set flag bits
```

### 2.3 0x17B46 apply_state(a = ax, b = dx) ✅
```
switch ws[a][b]:                       ; the WHOLE byte, flags included (original bug)
    1:                                  ; rapprochement
        rel[b][a] += rand(5) + 3        ; byte add, no cap (max reachable 117, §3.3)
        rel[a][b] = rel[b][a]
    4:                                  ; war — unreachable, see §3.2
        chance = power[b] != 0 ? umin(10*power[a] / power[b], 50) : 50
                                        ; 10*power[a] is a signed 16x16→32 product, long div
        if rand(50) < chance: take_port(a, b)
    else: nothing
```

### 2.4 0x17AB4 take_port(a = ax, b = dx) ✅ (never executed, §3.2)
```
for p in 99 down to 0:
    if (port(p).13 & 7) != b: continue
    if nat[b].+0xA == p: continue                    ; never the capital
    port(p).13 = (port(p).13 & 0xF8) | a             ; flags 0x08/0x10/0x20/0x40/0x80 kept
    support[p][a] = rand(10) + 80                    ; others' support untouched
    nat[a].+0x19+a = p                               ; a's OWN slot (not nat[b].+0x19+a)
    return                                           ; one port per call
```
No message, no standing/fame change, no check for the player's nation (the player's own
nation could lose ports), no check of the story-closed bit 0x20. Highest-numbered non-capital
port per owner at new game: POR 85 고아, ESP 54 마라카이보, TUR 80 무스카트, ENG 31 더블린,
ITA 14 라구사, NED 41 베르겐.

Interaction with the daily owner rule 0x1902A (per port, `for n in 0..5` ascending: if
`support[n] >= 75 and owner != n` → owner := n (0x18FB9, also sets 0x08 if economy < 150 and
p > 41); elif `support[n] < 75 and owner == n` → owner := 6, clear 0x08 (0x18FE4)): the old
owner b normally still has `support[b] >= 75`, so the next day the port goes to whichever of
a, b has the **higher nation index**. A capture by a lower-numbered nation would revert at
once. Moot in the original, relevant if the remaster enables the intended behaviour (§7).

`nat[n].+0x19..+0x1F` ("last port taken") is 0xFF in the new game, written only here and read
nowhere.

## 3. The table DS:0xAC74 and the state values

### 3.1 Dump (48 bytes reachable: 36 designed + 12 overrun into DS:0xAC98)

`idx = 12·rc + 3·pc + fc`. Rows = rc (relation band), columns grouped by pc, each group
`fc0 (0x20 alliance) · fc1 (0x10 blockade) · fc2 (no flag)`:

| rc \ pc | 0: a > 2b | 1: b > 2a | 2: a > b | 3: b ≥ a |
|---|---|---|---|---|
| 0 (rel 0–30)    | 0 · 3 · 0  | 1 · 3 · 5  | 0 · 3 · 1  | 1 · 3 · 5  |
| 1 (rel 31–70)   | 6 · 4 · 9  | 1 · 3 · 10 | 6 · 7 · 9  | 0 · 3 · 10 |
| 2 (rel 71–110)  | 6 · 4 · 2  | 6 · 3 · 1  | 6 · 7 · 8  | 6 · 7 · 8  |
| 3 (rel 111–150) overrun = DS:0xAC98 rebuild table | 0x78 · 0x05 · 0x89 | 0x07 · 0x99 · 0x08 | 0x78 · 0x07 · 0x89 | 0x07 · 0x99 · 0x09 |

Raw: `00 03 00 01 03 05 00 03 01 01 03 05 | 06 04 09 01 03 0a 06 07 09 00 03 0a |
06 04 02 06 03 01 06 07 08 06 07 08 | 78 05 89 07 99 08 78 07 89 07 99 09`.

Randomised values (§2.2): 7 → 3 with probability `r/100` else 0; 8 → 2 with probability
`(99−r)/100` else 0; 9 → 2 when `rand(20)+30 > r` (always for r ≤ 30, never for r ≥ 50);
10 → 2 when `rand(10)+30 > r` (never for r ≥ 40). So 8/9/10 lean to 2 for lower relations,
7 leans to 3 for higher relations.

### 3.2 What each value does

| value (whole byte) | effect | reachable as a whole byte? |
|---|---|---|
| 1 | `rel` both ways `+= rand(5)+3` | only from fc2 cells: idx 8 (rel ≤ 30, a stronger but ≤ 2×) and idx 29 (rel 71–110, b > 2a); the fc0 cells 3, 9, 15 give 0x21 → inert |
| 4 | war: chance to take b's top non-capital port | **never**: 4 only sits in fc1 cells (idx 13, 25), so the byte is 0x14 (or 0x94…) |
| 0, 2, 3, 5, 6, 9 | none — no reader anywhere | |
| 0x78 / 0x99 / 0x05 (rc 3) | would add flag bits 0x10/0x20/0x40/0x80 | **no**: rc 3 needs rel ≥ 111, which only flag-free pairs reach (§3.3) |
| 0x89 (rc 3, fc2, pc 0/2) | sets bit 0x80 (read nowhere) + nibble 9; the byte can never be 1 again, so that direction's bump is off for good | yes |

Intended meanings **(inferred, nothing reads them)**: 0 neutral / truce; 1 rapprochement;
2 tension (comes from 8/9/10 at low relation); 3 standoff under blockade; 4 war (only with
blockade, a ≥ 2× b, rel ≥ 31); 5 likely "impose blockade" (weak nation with low relation and
no flags); 6 alliance holds (only in the alliance column). The writer keeps the high nibble
and only the low nibble changes, so the designers evidently meant states as the low nibble
and flags as persistent bits — the whole-byte compare in 0x17B46 defeats that.

### 3.3 What actually happens each month (faithful behaviour)
- Hostile pair with no flags (`rel[a][b] ≤ 30`) where a is stronger but not double: relation
  climbs 3–7 a month until it is 31–37, then stops (rc 1 gives 9/10 → 0/2). E.g. new game:
  POR (≈1880) vs TUR (≈1340), rel 30 → POR→TUR state 1 in month 1.
- Friendly pair with no flags (`rel 71–110`) where b is more than twice a: relation climbs until
  it is 111–117 (max: 110 + 7). Then a→b gives 0x08 → 0; b→a (pc 0) gives 0x89 (bit 0x80 set
  permanently). Royal commissions 7/8 (SNR0) clamp the result to 100 when they add +5/+10.
- Allied (0x20) or blockaded (0x10) pairs: relation never changes here.
- `rel` stays ≤ 117, so `rc ≤ 3` and the index never passes 47.

### 3.4 High-nibble flags
- **0x20 = 동맹 (alliance)** and **0x10 = 봉쇄 (blockade / port entry ban)** — names from the
  guild screen header msg 1083 "동맹 봉쇄 " (§4.2).
- 0x40 / 0x80: only from the rc-3 overrun (0x80 reachable); never tested.
- Writers: new-game data (§5); SNR3 (Otto) chapter 0 block 3 (AT_SEA day 1, file 0x865):
  `ws[ESP][ENG] |= 0x10; ws[ENG][ESP] |= 0x10` (plus 10000 gold, pirate fame +300,
  standing with Spain := 20); 0x17BD1 clears `ws[n][n]`. No code clears 0x10/0x20, and no other
  script touches `+0x12..+0x18` (all D0/DC `hero_tbl` uses in SNR0–6 checked).

## 4. Every reader of `+0x12..+0x18`

Found by scanning every near/far call of 0x5AD2 plus the only inline base (`add si, 0x1106` in
the script accessor 0x3162E); there are no absolute references to DS:0x1118..0x1125.

| reader | test | effect |
|---|---|---|
| 0x179AD | `ws[a][b] & 0x20`, `& 0x10` | table column (§2.2) |
| 0x17B46 | `ws[a][b] == 1 / == 4` | §2.3 |
| 0xFB8E battle category | `ws[E][P] & 0x10` → 3; `ws[P][E] & 0x20` → 6 (P = player nationality, E = enemy fleet/10; later tests override) | pirate-fame multiplier (0x10497) and standing changes (0x10693); documented in battle.md §11.3/11.4, town.md §6–7 |
| 0x2C899 guild 나라정보 | `ws[n][m] & 0x20`, `& 0x10` | ☆ in the 동맹 / 봉쇄 columns (§4.2) |
| 0x8993 town entry from sea | `ws[portNation][playerNationality] & 0x10` | harbour guards (§4.1) |
| 0x280A3 harbour office | `ws[portNation][playerFleet/10] & 0x10` | guards may leave at night (§4.1) |
| SNR scripts via D0/DC table 0 | only SNR3's write above | |

Not read by: palace 세력상황 (0x29BC8), fleet AI (missions, targets, encounters, reinforcements
0x10B78, NPC fights 0x1A183), port entry at sea, markets, investment.

### 4.1 Blockade: harbour guards ✅
Town sprites: 8 × 3 bytes at DS:0xC48 (`x, y, kind`); entries 0–3 walk (0x6147), entries 4–7
stand still. Collision 0x6050 (skipped at night): a sprite within ±1 tile of the player →
returns `k+1`, or **7 if k > 3 and kind == 2** (guard). Night = 0x603B: tick < 12 or ≥ 60.

0x8993 (called on arrival from sea by the town entry 0x8AB2 → 0x8B44, after the player is put
at `(door3.x, door3.y+1)`, door3 = harbour door from ZA_DAT DS:0x892/0x893; and by 0x6147 at
night):
```
for i in 0..3: b = i + (i == 3)                       ; buildings 0,1,2,4
    sprite[i]   = (door[b].x − 2, door[b].y + 1, 2)
    sprite[4+i] = (door[b].x + 2, door[b].y + 1, i)
    if i == 2: sprite[2] = door[2]; sprite[6].xy = (0xFF, 0xFF)
n = port.13 & 7
if !night and n < 6 and ws[n][player.31 & 0xF] & 0x10 and player is at (door3.x, door3.y+1):
    for s in 0..2: sprite[4+s] = (door3.x + 2(s−1), door3.y + 2 + s/2, kind 2)   ; 3 guards
```
Bumping a guard (town walk 0x65E5 → 0x63A1 case 7 at 0x64FD, when the talk cooldown
`[0x950E] ≥ 10`) prints **msg 622** with the player's nation name (DS:0x866[nationality]):
"[원작 문장 생략]
주길 바란다." Guards are obstacles; there is no arrest, fine or battle. The harbour office
itself still works (supplies are allowed).

Harbour office 0x280A3, before its menu: if `tick ≤ 18 or tick ≥ 54` and `rand(3) == 0` and
port nation n < 6 and `ws[n][fleet(player).index / 10] & 0x10` → sprites 4–7 are reset to the
door positions (guards gone). Note the index here is the hero's **fleet group** (the starting
nation: Joan 0, Catalina 1, Otto 3, Ernst 5, Pietro 4, Al 2), not the current nationality used
by 0x8993. At night 0x6147 calls 0x8993, which also drops the guards.

### 4.2 Guild 나라정보 0x2CA2A → 0x2C899 ✅
After msg 86 and paying 100 gold (msg 163 if short, 87 on no):
```
msg 1081 "수익:%5d    공헌도:" power[n];  then |100 − standing[n]| (red ESC C2 if standing < 100)
msg 1082 "우호관계 " + msg 1083 "동맹 봉쇄 "
for m in 0..5, m != n:  "%-14s" name(m),  |30 − rel[n][m]| (red if rel < 30),
                        "☆" at column 0x29 if ws[n][m] & 0x20,  "☆" at column 0x2E if ws[n][m] & 0x10
nat[n].+2 < 7: msg 88 "%s([원작 문장 생략]." (target 6 prints 해적)
           else msg 853 "[원작 문장 생략]."
msg 89 "[원작 문장 생략]." port(nat[n].+4)
```
So the displayed "relation" is `rel − 30` (30 = neutral). Already in Guild.swift `buyNews`
(without the red colouring).

## 5. Messages and side effects of declaring war / peace / taking a port

None. 0x17BD1, 0x179AD, 0x17B46 and 0x17AB4 call no text routine (0x551C/0x8D4B); there is no
"war declared", "peace" or "port fell" news anywhere in MESSAGE.DAT (searched for 전쟁, 선전,
점령, 동맹, 봉쇄, 평화, 강화, 함락, 휴전…; only msgs 622, 781, 883, 1082–1085 relate).
The player's standing, fame and his own support are not touched. The player sees changes only
through 나라정보 (relations, ☆ flags), 여관 항구의지지율 (support) and port ownership.

## 6. New-game values (DS image, DATA1[15] over MAIN)

| n | power | +2 enemy | +3 policy | +4 target | +9 agg | +0xA cap | rel to 0..6 (+0xB) | ws to 0..6 (+0x12) | +0x19.. |
|---|---|---|---|---|---|---|---|---|---|
| 0 POR | 0 | 2 | 0 | 17 | 60 | 0 | 100 85 30 50 70 50 40 | 00 **25** 00 00 01 00 00 | FF×7 |
| 1 ESP | 0 | 6 | 1 | 3 | 70 | 1 | 85 100 35 45 65 50 20 | **21** 00 00 00 01 00 00 | FF×7 |
| 2 TUR | 0 | 4 | 2 | 61 | 80 | 2 | 30 35 100 55 25 50 70 | 00 00 00 00 **12** 01 00 | FF×7 |
| 3 ENG | 0 | 1 | 5 | 52 | 90 | 29 | 50 45 55 100 50 60 60 | 01 01 00 00 01 01 00 | FF×7 |
| 4 ITA | 0 | 2 | 0 | 27 | 50 | 8 | 70 65 25 50 100 50 30 | 00 01 **12** 00 00 00 00 | FF×7 |
| 5 NED | 0 | 0 | 5 | 59 | 85 | 33 | 50 50 50 60 50 100 60 | 00 00 00 01 01 00 00 | FF×7 |
| 6 pirates | 0 | 1 | 8 | 0xFF | 100 | 4 | 40 20 70 60 30 60 100 | 00 ×7 | FF×7 |

`+5..+8` are 0 for all. The relation matrix is symmetric. Flags: **POR ↔ ESP allied (0x20)**,
**TUR ↔ ITA blockade (0x10)**; Otto's prologue adds ESP ↔ ENG blockade. The low nibbles are
overwritten in the first month.

## 7. Remaster sketch (faithful)

```swift
static let warTable: [Int] = [0,3,0, 1,3,5, 0,3,1, 1,3,5,  6,4,9, 1,3,10, 6,7,9, 0,3,10,
    6,4,2, 6,3,1, 6,7,8, 6,7,8,  0x78,5,0x89, 7,0x99,8, 0x78,7,0x89, 7,0x99,9]  // 36..47 = DS:0xAC98

mutating func relationsMonth() {                    // 0x17BD1
    for a in 0..<6 { for b in 0..<6 {
        if a == b { memory.setNB(a, 0x12 + a, 0); continue }
        // 0x179AD
        let pa = Int(Int16(truncatingIfNeeded: power(a))), pb = Int(Int16(truncatingIfNeeded: power(b)))
        let pc = pa / 2 > pb ? 0 : pb / 2 > pa ? 1 : pb < pa ? 2 : 3
        let f = memory.nb(a, 0x12 + b), r = memory.nb(a, 0xB + b)
        let fc = f & 0x20 != 0 ? 0 : f & 0x10 != 0 ? 1 : 2
        var v = Self.warTable[12 * ((r + 9) / 40) + 3 * pc + fc]
        switch v {
        case 7: v = rng(100) >= r ? 0 : 3
        case 8: v = rng(100) <= r ? 0 : 2
        case 9: v = rng(20) + 30 <= r ? 0 : 2
        case 10: v = rng(10) + 30 > r ? 2 : 0
        default: break
        }
        memory.setNB(a, 0x12 + b, (f & 0xF0) | v)
        // 0x17B46 (whole byte)
        switch memory.nb(a, 0x12 + b) {
        case 1:
            let x = (memory.nb(b, 0xB + a) + rng(5) + 3) & 0xFF
            memory.setNB(b, 0xB + a, x); memory.setNB(a, 0xB + b, x)
        case 4:   // unreachable; kept for completeness / the optional fix
            let chance = power(b) != 0 ? min(10 * power(a) / power(b), 50) : 50
            if rng(50) < chance { takePort(a, from: b) }      // §2.4
        default: break
        }
    }}
}
```
An optional "as designed" mode would switch on `ws & 0x0F` in 0x17B46 instead; that enables
wars only for blockaded pairs (TUR–ITA, ESP–ENG after Otto's prologue) with `a > 2b` and
rel ≥ 31, and port captures by the lower-indexed nation then revert the next day (§2.4).

Gaps in the remaster today: no monthly relation update (WorldMonth.swift line 6), no harbour
guards / msg 622 (§4.1). 0xFB8E (BattleEnd.swift) and 나라정보 (Guild.swift) already read
the flags correctly.

## 8. Open questions
1. Intended meaning of states 0, 2, 3, 5, 6 (no reader exists; §3.2 guesses only), and whether
   the whole-byte compare is also in the Japanese/English releases.
2. Whether the three guards physically seal the landing spot in every town (depends on each
   ZA_DAT door layout and the town map; not checked). The rest of the walker system (0x6147,
   talk cases 1–6, 8 of 0x63A1) is not decoded here.
3. Bit 0x80 of `ws` (from the 0x89 overrun) and 0x40 are never tested.
4. Side finding: town.md §3.3 says power uses `economy × (flag 0x08 ? 1 : 2)`; the code at
   0x174C3 gives **×2 when 0x08 is set** (fleets.md and WorldMonth.swift are right).
5. Side finding: ports 4 알제 and 5 튀니스 have `port.13 = 0x00` (nation 0) in the DS image
   with `support[0] = 0`; the first daily pass 0x1902A makes them nation 6.
