# Town services, money and standing (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image 0x378B0 + n.
"msg N" = MESSAGE.DAT line N, "menu N" = MENU.DAT entry N, `S0#n` = SNR0.MES line n.
Helpers: `rand(n)` 0x4D86, long div 0x36A2 (truncates toward zero), umin 0x4D42, umax 0x4D49.
Status: everything below was read from code unless marked **(inferred)**.

## 0. State used by the town code

| what | where | notes |
|---|---|---|
| gold | DS:0x123A u32 | cap 600,000,000 (0x23C34600) everywhere gold is added |
| bank balance | `B = 100*[0x123E] + [0x1240]` | `[0x123E]` s16 (hundreds, floored), `[0x1240]` u8 0..99 (or 100 after a repayment, still consistent) |
| hero index | `[0x1241]` (0..5) | = person index = family index |
| player person | `[0xC67A]` → person record | `+0x31 & 0xF` = **nationality** (0 POR,1 ESP,2 TUR,3 ENG,4 ITA,5 NED, **6 = none**); `+0x21` 검술, `+0x22` 매력, `+0x23` 운, `+0x25` battle level, `+0x30` skills (4 포술, 8 지도작성술, 0x10 측량술) |
| family record | DS:0x11E6 + 14·hero (0x5ADC) | `+0` trade fame u16, `+2` pirate fame u16, `+4` adventure fame u16 (all capped 50,000), `+6..+0xB` **standing** with nations 0..5, `+0xC` standing with "nation 6" (palace of a nationless port), `+0xD` **rank** 0..9 |
| current port | `[0xC3A]` (0xFF at sea); market ptr `[0xC6E2]` | |
| port record | DS:0x5F54 + 20·p (0x5B8E) | `+0x13`: bits 0–2 nation (6 = none), 0x08 "developing", 0x10 known, 0x20 closed (story), 0x40 visited (set on arrival 0x1B700), 0x80 shown as 식민지 instead of 동맹항 (no writer found) |
| market record | DS:0x697C + 37·p (0x5B9E) | `+0` economy, `+2` economy investment this month, `+4` industry, `+6` industry investment, `+8..+0xD` support % of nations 0..5, `+0x1C` region 0..7 (유럽, 신대륙, 서아프리카, 동아프리카, 중동, 인도, 동남아, 동부아시아) |
| nation record | DS:0x1106 + 32·n, n = 0..6 (0x5AD2) | see below |

Standing (family `+6+n`) starts at **100** for every nation, range 0..200. Despite the
"적대치" comment in HORIEDIT.H, *lower is worse*: < 80 risks arrest, ≤ 70 loses your rank, ≤ 40
loses your nationality, ≥ 130 earns royal aid.

### Nation record (DS:0x1106 + 32n)

| off | meaning | new game (POR, ESP, TUR, ENG, ITA, NED, 6) |
|---|---|---|
| +0 u16 | monthly income ("수익", 0x17464) | 0 |
| +2 | war target nation 0..6, **7 = the player** (0x175FD) | 2,6,4,1,2,0,1 |
| +3, +4 | AI fleet data (not decoded) | |
| +5 | pending **gold aid**, thousands (0..100) | 0 |
| +6 | accrues like +5 (X/1000, cap 100); no reader found | 0 |
| +7 | **aid ship type** 0..7 (0xFF none) | 0 |
| +8 | **aid ships available** | 0 |
| +9 | aggressiveness (60,70,80,90,50,85,100) | |
| +0xA | **capital port** (0 리스본, 1 세빌리아, 2 이스탄불, 29 런던, 8 제노바, 33 암스테르담, nation 6: 4 알제) | |
| +0xB..+0x11 | relation with nations 0..6 (self 100) | POR: 100,85,30,50,70,50,40 |
| +0x12..+0x18 | per-nation flag bytes (0x10, 0x20 used by 0xFB8E) | |

## 1. Buildings and access

### 1.1 Building list
All 100 market ports have all twelve buildings. Door tiles come from `ZA_DAT.DAT`
(101 × 24 B: twelve `(x, y)` byte pairs per port; record 100 is shared by every supply port and only
has the harbour). Loaded by 0x8705 to DS:0x88C; 0x5F1F maps the player tile to a building index.

Index = MENU 58 order = dispatch table DS:0xAE88 (far pointers):

| # | building | entry | hours (tick 0..71, 3 ticks/hour) |
|---|---|---|---|
| 0 | 교역소 | 0x24C9E | 12–59 (04:00–20:00) |
| 1 | 주점 | 0x26FF5 | closed 12–23 (04:00–08:00) |
| 2 | 조선소 | 0x2C310 | 12–59 |
| 3 | 항구 (harbour office) | 0x280A3 | always |
| 4 | 여관 | 0x286A5 | always |
| 5 | 왕궁 | 0x2A424 | 12–59 |
| 6 | 조합 | 0x2CB18 | 12–59 |
| 7 | NPC residence | 0x2D9A8 | always (locked if no NPC lives here, msg 933) |
| 8 | 은행 | 0x28C33 | 12–59 |
| 9 | 아이템 | 0x297B9 | 24–59 and 6–8 (08:00–20:00, 02:00–03:00) |
| 10 | 교회 | 0x2C5EB | 12–71 |
| 11 | 점술가 | 0x2CD51 | 48–71 (16:00–24:00) |

Entries 12..15 of the table are town commands (정보 0x20559, 편성 0x20703, 지휘 0x207CF, 항해 0x208C7).

### 1.2 Entering a building (0x1B08E → 0x1B150)
```
door = 0x5F1F(); if none: return
if closed by the hour table (0x1B0C1): return
cost = rand(3) + 2            # returned to the caller (ticks spent; inferred)
script hooks for (port, building): the SNR0 job script (0x32CC1 → 0x32C30) and, when
             [0xD72]==0, the hero story script (0x32E02 → 0x32D86); if either ends with ret0
             and the building is not the 여관, the building's own code is skipped
fam = family[hero]; n = port.nation
if building not in {항구, 왕궁, NPC, 교회} and n != 6 and fam.standing[n] < 80:
    if rand(3)==0 and rand(100) > standing+20: town_arrest(n) (0x1AF95); skip the building
    else msg 838 (warning) then enter
call building
```

### 1.3 Arrests
**Town arrest 0x1AF95** (msg 839, 840): escape if `검술 + battleLvl·검술/100 ≥ rand(150)` →
msg 842, 843. Otherwise msg 841, 845: `gold -= 3·gold/4`, `standing[n] += 20`.

**Palace arrest 0x2A2A2** (entered from the palace check, msg 443): escape if
`(battleLvl·검술/100 + 검술) ≥ rand(150)` → msg 446, 448. Otherwise msg 445, king 449–452:
`gold -= trunc(4·gold/5)`, bank balance `B -= trunc(4·B/5)` (debts shrink too), `standing[n] = 100`.

## 2. Bank (은행, building 8)

Entry 0x28C33: msg 97 in Venice (port 13), else msg 98 with the port name; menu 0 (4 items:
예금, 출금, 대출, 상환), dispatch DS:0xB6DE; on leaving msg 164.

```
deposit 0x28754:
  if gold <= 1000: msg 100; return
  if [0x123E] >= 10000 (B >= 1,000,000): msg 101; return
  if [0x123E] < 0 (in debt): msg 102; return
  max = min(gold, 1,000,000 - B)
  msg 103 B (or 104 if B==0); msg 105 max; v = input(0..max); if v==0 return
  msg 106 v (월 3%); B += v; msg 103 B; gold -= v

withdraw 0x288B5:
  if B <= 0: msg 104; return
  if gold > 599,999,900: msg 107; return
  msg 103 B; msg 108; v = input(0..B); if v==0 return
  if gold + v > 600,000,000: msg 109; return
  msg 110 v; B -= v; msg 103 B; gold += v

borrow 0x289CF:   r = rank
  if B > 0: msg 111; return
  if [0x123E] <= -100·r² - 10: msg 113 (credit exhausted); return
  if gold >= 1,000,000: msg 112 ("you don't need a loan") — printed, but the loan continues
  limit = 10000·r² + 1000 + B          # B <= 0
  msg 114 limit; msg 115; v = input(0..limit); if v==0 return
  msg 116 v; msg 117 (월 10%); B -= v; gold += v

repay 0x28B29:
  if B >= 0: msg 118; return
  msg 149 -B; v = input(0..min(-B, gold)); if v==0 return
  msg 120; B += v; msg 117; gold -= v
```
So a commoner (rank 0) can owe at most 1,000 (plus interest); rank r allows `10000·r² + 1000`.

**Monthly interest 0x1730D** (first day of each month, from 0x189DA):
```
rate = 3 if [0x123E] >= 0 else 10
B += trunc(B·rate/100)                 # negative balances round toward zero
B  = clamp(B, -1,000,000, 1,000,000)
```
**Unpaid debt** has no other consequence in MAIN.EXE: it compounds 10 %/month until it is pinned
at −1,000,000. No code reads the balance outside the bank, interest, and the palace arrest. (The
"셜록은행 수금" messages 608–615 are the guild's debt-collection *job*, where the player collects
someone else's debt, see §8.)

## 3. Investment, support and allied ports

### 3.1 Player investment
교역소 menu 6 item 3 투자 → 0x24A58 (economy); 조선소 menu 22 item 6 공업투자 → 0x2C24F (industry).
Both are identical except for the field:
```
if port is a capital of any nation (0x1ADEC: nation[k].+0xA == port, k=0..5): msg 2; return
if market.invest >= 50000: msg 7; return          # invest = +2 (economy) or +6 (industry)
msg 8; v = input(0 .. min(gold, 50000, 50000 - market.invest)); if v==0: msg 13; return
msg 14 if v < 500, 15 if v < 10000, else 16
market.invest += v; gold -= v
support_gain(v, base)    # base = economy (0x24936) or industry (0x2C04A)
reassign_owner()         # 0x2C16E
```
The money itself only raises the port next month: monthly 0x173CC adds `invest/300` to economy
(resp. industry), cap 1000, and clears the investment counters. So at most 50,000 per field per
port per month, i.e. +166.

**support_gain(v, base)** (0x24936 / 0x2C04A), p = player nationality:
```
g = v / base                        # u16 division
if p != 6: g = min(g, 100 - support[p]); support[p] += g
else:      g = min(g, 100)          # nobody gains, others still lose
k = #{n != p : support[n] > 0}
if k: each such n loses g/k (if it has less, it goes to 0 and the shortfall joins the remainder);
      the remainder is then taken 1 point at a time round-robin from nations with support > 0
      until it is used up or nobody has support left.
```
So with a nationality the total support is conserved; nationless investment only lowers others.

**reassign_owner()** 0x2C16E (also the rule the daily routine applies):
```
old = port.nation; new = 6
for n in 0..5: if support[n] >= 75: new = n      # last match wins
port.nation = new
if old != 6 and new != old and old != p: standing[old] -= min(5, standing[old])
if old != p and new == p:                         # the port just joined your nation
    tradeFame += min(50000 - tradeFame, economy + industry)
    standing[p] = min(200, standing[p] + 5)
```

### 3.2 Competing (AI) investment 0x33568
Merchant fleets ("[원작 문장 생략]", msg 153) carry money `M = fleet+0x24`
(fleet `[0xC12C]`, nation `[0xC164]`, target port `fleet+0x1C`). On arrival, unless `M < 2` or the
target is that nation's capital:
```
field = industry if industry <= economy else economy   # the weaker one; if full (50000) the other
field.invest = min(50000, field.invest + 100·(M/2));  M -= M/2
g = min(6·M/10, 100 - support[n]); support[n] += g
take min(g, Σ others) from the others one point at a time, round-robin
```

### 3.3 Daily and monthly rules (summary)
- Daily 0x1902A (decoded earlier): support ≥ 75 → port joins that nation (flag 0x08 if economy < 150 and
  port index > 41); the owner losing support < 75 makes the port nation 6; a flagged port reaching
  economy 150 clears 0x08 and raises all ten price indices by `min(rand(5)+10, 100 - index)`.
- Monthly 0x173CC: economy/industry += investment/300 (cap 1000), price indices drift to 50.
- Monthly nation income 0x17464 (`nation.+0`), per nation n and region r (market +0x1C):
  `ind[n][r] = Σ industry`, `eco[n][r] = Σ economy × (flag 0x08 ? 1 : 2)`, divisors DS:0xAC50 =
  4,3,3,2,3,1,1,1:
  ```
  income = eco[0]/4
  for r in 4,5,6,7: if ind[r] >= 300: income += eco[r]/div[r] else break     # eastern chain
  for r in 1,2:     if ind[r] >= 300: income += eco[r]/div[r]
  if (ind[2] >= 300 or ind[4] >= 300) and ind[3] >= 300: income += eco[3]/2
  nation[6].+0 = (Σ incomes of 0..5) / 6
  ```
- The inn's "항구의지지율" (0x285E2) lists `support[0..5]` and marks the owner (msg 1084/1085).
- 세력상황 at the palace prints `#{ports 0..99 owned by the king's nation}` (0x29B7B, msg 883) and
  per-region income lines (msg 455–457).

## 4. Royal palace (왕궁, building 5, 0x2A424)

### 4.1 Entry
```
n = port.nation; king = npc[10+n] (DS:0x29B2 record, portrait +0x11)
if standing[n] <= 80 and rand(100) > standing[n]: msg 443; palace_arrest(); return
if rank == 0 and p != 6 and (n != p or !([0xCEE] & 6)): msg 84 ("[원작 문장 생략]"); return
greet: rank>0 → msg 444 (name, title) ; rank==0 → msg 576 (special admission)
menu 16, only 4 items shown (알현, 망명, 자금원조, 선박원조; 밀회 is never offered)
disabled mask [0xA9BA]:
  망명 disabled if n == p, or a royal commission is active ([0xCEA] ∉ {0,0xFF} and v6 [0xD00] >= 6),
       or [0xCEE] & 6 (summoned / commission accepted)
  자금원조, 선박원조 disabled if n != p
after every action: if rank == 9 and [0xC30] & 2: 0x17032(15)   # ending trigger (see scenario.md)
```
`[0xCEE]` holds the SNR0 flags F16 (bit0: promotion due), F17 (bit1: summoned), F18 (bit2:
commission accepted). Rank 0 can enter only the own nation's palace after being summoned; a
nationless hero can enter any palace (to defect).

### 4.2 알현 0x29EDD
```
if n == p and F17: [0xCEA] = v30 ([0xD30]); [0xCEB] = 0; run SNR0 (port, 5)   # royal commission
if SNR0 gate (port, 0x15) passes: submenu 55 (세력상황, 사략허가서, 면세증), dispatch DS:0xB736;
   사략허가서 disabled if n != p
```
Promotion itself is done by the SNR0 commission script (see §5).

**세력상황 0x29BC8**: msg 453, msg 883 (allied-port count), region menu with income lines, msg 454. Free.

**사략허가서 0x29C3A** (privateer licence, item `0x1D + n`, own nation only):
```
already owned: msg 864;  no free item slot (of 20): msg 865
msg 866
if pirateFame < 1000: msg 867
elif pirateFame < tradeFame or pirateFame < adventureFame: msg 868
else: msg 869, king 870, 871; give item (free)
```
**면세증 0x29D46** (tax-exemption certificate, item `0x23 + n`, any palace you can enter):
```
already owned: msg 872;  no free slot: msg 865
msg 873; if [0x56F] (month index) % 6 < 3: msg 874 ("you'll have to renew soon"); msg 875 yes/no
msg 869; king msg 876
cost = 0 if n == p and rank >= 6
     = (7 - rank)·10000 if n == p
     = (11 - rank)·10000 otherwise
if cost: msg 877 (cost/10000)"0000"; yes/no; gold < cost → msg 878; else gold -= cost
msg 871; give item
```
Expiry: monthly 0x1728C removes items 0x23..0x28 from the item list when `[0x56F] % 6 == 2`
(month index 2 and 8; whether that is March/September or April/October is open question 4).
Effect: buying in that nation's
교역소 has no 20 % surcharge (×12/10 skipped, msg 762/763, 0x23DE5).

### 4.3 망명 (defection) 0x29FB0 — foreign palace only
```
king msg 458 (name) ; yes/no ; no → msg 459
yes → msg 460
  old = p; p = n (person +0x31 low nibble); player fleet [0xC6DA].+0x26 (home port) = port
  if nation[n].+2 == 7 (was hunting the player): nation[n].+2 = 6
  nation[n].+5 = +6 = +7 = 0                       # pending aid of the new nation cleared
  if standing[old] >= 30: standing[old] -= 30
  standing[n] = max(100, min(200, standing[n] + 10))
```
Rank is kept.

### 4.4 자금원조 0x2A0CD / 선박원조 0x2A155 — own nation only
```
gold aid: a = nation[n].+5; if a == 0: msg 461
          if gold + 1000a > 600,000,000: msg 530
          else msg 462 (a"000"); gold += 1000a; nation[n].+5 = 0; msg 463
ship aid: if nation[n].+8 == 0: msg 461
          if no spare ship record is free (0x12A10 lists free records 10..39 at DS:0x574)
             or the fleet already has 10 ships (0x12986): msg 531
          if no officer free to captain it (0x12AE5): msg 532
          if a ship ordered for this port is still waiting at the yard (cargo +0x1B == port|0x80,
             ship state 0x20): msg 461
          msg 464 (class name of base ship 40 + type); order ship type nation[n].+7 (0x31C64,
          same as 조선소 orders: hull 9/10 of the type); nation[n].+8 -= 1; name it (msg 555);
          msg 552 "the ship is left at the shipyard"; msg 463
```
**Monthly accrual 0x183DA** (inside 0x184C1), for every nation n = 0..5:
```
if standing[n] >= 130:
    X = rank × nation[n].income
    +5 = min(100, +5 + X/3000)        # gold aid in thousands
    +6 = min(100, +6 + X/1000)
    +7 = min(7, X/4000)               # ship class 0 발사 … 7 브리간틴
    +8 += min(10, X/4000)
elif standing[n] < 70:  +5 = +6 = +8 = 0, +7 = 0xFF
```

## 5. Rank (작위) and promotion

Titles: rank 1..9 = 기사, 준훈작, 훈작, 준남작, 남작, 자작, 백작, 후작, 공작 — DATA1.LZW entry 16
(9 × 9 B) loaded to DS:0xC685 (0x16016); the title of rank r is read at DS:0xC67C + 9·r. Rank 0
has no title. The Ottoman titles 사족…대재상 (DATA1.LZW entry 17) replace the European ones when the
hero is hero 5, whatever his current nation (info.md §1.4).

**Threshold** `T[r] = 500·(r+1)²` (table DS:0xB8B0: 500, 2000, 4500, 8000, 12500, 18000, 24500,
32000, 40000), compared with `max(trade, pirate, adventure fame)`.

Promotion is **only** done by the SNR0 royal commission blocks 6–12 (script VM 0x3287A; the
step-2 completion writes `family+0xD += 1` with `D0 0C 01 0B 0D / 05 0D 0C / 4C 0D 01 / 11 0C 0D`).
One completed commission = one rank. The chain:

1. **F16 "promotion due"** (`[0xCEE]` bit 0) is recomputed by SNR0 block 0 step 0 whenever you
   enter a building with no job active (guild event script 0x0010, any other building 0x02B0):
   `rank <= 8 and max(fame) >= 500·(rank+1)² and nationality != 6`. So 8→9 needs **40,500**
   (the fortune-teller table says 40,000 for rank 8 — a mismatch in the original).
2. **F17 "summoned"** (bit 1) is set natively when no job is active, `F16 or F17`, and F18 clear:
   - tavern 한턱내기 (0x257E2 → rumour 0x256DE → 0x257F4), any port;
   - harbour office (0x282C6), only in a port of your own nation.
   Both print msg 409 + (410 + nationality) + 416 ("…왕이 [원작 문장 생략]").
3. Block 0 also picks the commission `v30` (block 6..12) and its seed `v31`
   (script 0x008E–0x0139):
   ```
   v10 = rand(3); if v10 == 0: v30 = rand(2)+1; if rank == 0: v10 = v30   # rank 0 never gets 7/8 this way
   if v10 != 0:
     highest fame trade:  v30 = 0 if v10 == 1 else 3        # block 6 or 9
     highest pirate:      v30 = 6                            # block 12
     highest adventure:   v41 = #sites with (+6 & 0xB0) == 0x30 (reported discoveries)
                          v10 = 1 if v40 == 7; 2 if v41 == 50; if rank <= 1: v10 = 1 (0 if both)
                          v30 = v10 (+3 unless v40 == 7 or v41 == 50)   # normally block 10/11
   v30 += 6                 # ties for highest fame go to the later kind (adventure > pirate > trade)
   ```
   (v40 = `[0xD44]` treasures delivered; with rank ≥ 1 there is a 1/3 chance of the envoy jobs 7/8.)
4. **알현 at your home capital** (home port = `fleet[hero].+0x26`, the nation's capital unless you
   defected): step 0 (building 5) clears F17, sets **F18** (bit 2, commission accepted), step 1
   (event 0x15) states the task and asks yes/no. **Refusing halves all three fames** and ends it.
5. Do the task, report at the home audience (step 2): rank + 1, job ends (opcode F1 clears F0–F31,
   so F16–F18 too). Asking to quit while unfinished also halves all fames. **No deadline.**

| block | task | completion / extra |
|---|---|---|
| 6 | buy goods v18 ×v19 and bring them (tier goods 32–37 / 26–31 / 0–9, budget 1000/5000/20000, qty = min(250, budget/zone price)); no money is paid | home 교역소 is closed while it runs (S0#69) |
| 7 | carry a letter to ruler v18 = rand(6) ≠ home, audience at his capital | relations both ways +5 (cap 100) |
| 8 | envoy for a treaty, same route | relations both ways +10 |
| 9 | own nation must own `count + {2,5,10}[tier]` ports (0..99) | — |
| 10 | report discoveries worth `(tier+1)·50` points (site `+5` values) at audiences, one per visit | — |
| 11 | bring treasure item 90–96 (site `+4`) | item removed, **gold + 100,000**, v40++ |
| 12 | destroy one fleet of the nation's current war target `nation[p].+2` (6 = pirates) | — |

tier = `min(rank, 6) / 3`. Royal commissions give no fame and never lower rank. The thresholds
are the same for every hero and nation. SNR3 (Otto) gets a free rank +1 in his prologue;
scenario.md covers the hero scripts.

**Losing rank / nationality** (0x10693, run at battle end 0x109BA for every battle the player
*won* — it returns at once when the result code `[0xA509]` is odd), when the beaten fleet belongs
to your own nation:
```
standing[p] -= min(standing[p], rand(5) + 10)
if standing[p] <= 40: msg 568 국적 박탈: rank = 0, nationality = 6, cancel SNR0 job ([0xCEA]=[0xCEB]=0)
elif rank != 0 and standing[p] <= 70: msg 569 작위 박탈: rank = 0, cancel job
```

**What rank does elsewhere**: bank credit `10000·r² + 1000`; sailors `min(mood·econ/500,
(r+1)·mood)`; officer hiring score × `(1 + r/10)`; haggling floor `price·(19−r)/20`; 면세증 price
`(7−r)` / `(11−r)`·10000; guild job tier `min(r,6)/3`; royal aid `X = r × income`; palace entry
(r ≥ 1); rank 9 + `[0xC30]&2` → ending 15.

## 6. Fame (명성)

Three u16 counters in the family record, each capped at 50,000. Every writer found:

| source | fame | rule | address |
|---|---|---|---|
| a port joins your nation through your investment | trade | `+ (economy + industry)` | 0x2C22B |
| guild jobs 상품수송/상품구입/편지배달 | trade | +200/700/1500 by tier (편지 +50); penalties ×0.9 / ×0.8 | SNR0 (§8) |
| guild job 빚독촉 | trade **and** pirate | +150 / +500 | SNR0 |
| guild job 해적퇴치 | pirate | +300/700/1500 | SNR0 |
| winning a sea battle | pirate | `+200 + min(L,15)·min(L,30)·base·mult` | 0x1049D |
| sighting a port / village | adventure | port: `25 × region` (Europe 0), supply port 50, village 50 | 0x302FF |
| 발견물보고 to a patron | adventure | `value × 8` (×15 if value 100) | 0x2D019 |
| 지리보고 to a map maker | adventure | `5 × new cells` | 0x2D4AC |
| hero scripts (SNR1..6) | any | fixed amounts, e.g. +1000 | scenario.md |
| refusing / abandoning a royal commission | all three | halved (`f /= 2`) | SNR0 blocks 6–12 |
| guild job cancelled / late / debt money kept | the job's fame | `f = floor(floor(f/10)·k/10)·10`, k = 9 / 8 / 5 | SNR0 |

Selling goods gives **no** fame (sell code 0x24762..0x248D9 has no family write).

**Battle fame** (0x10388 → 0x1049D), awarded for result codes `[0xA509]` 0, 2, 4, 6 (even = the
player's side won; set at 0xA1B0: 4/5 = a side wiped out, minus 2 when it ended by the flagship
leaving; 8 skips everything): L = enemy admiral battle level (`+0x25`); base = 1 for code 2
(enemy flagship withdrew, msg 565), otherwise 3.
`mult` from 0xFB8E (privateer legality, below): nationless ×3; legality 2 → ×2, 3 → ×3, 4 → ×4,
otherwise ×1.

**0xFB8E legality** (p = player nation, e = enemy fleet index / 10):
```
r = 0; if the player holds privateer licence 0x1D+p: r = 1
  if nation[p].rel[e] <= 40: r = 2
  if nation[e].flags[p] & 0x10: r = 3
  if nation[p].+2 (war target) == e: r = 4
  if nation[p].rel[e] >= 60: r = 5
  if nation[p].flags[e] & 0x20: r = 6
```

**Effects of fame**
- 교역소 greeting: trade fame ≥ 1000 → msg 1 (recognised) instead of msg 0 (0x24CE2).
- 주점 한턱내기 (0x25742): `M = max fame`: < 1000 msg 36, < 5000 msg 132 (names the kind), else msg 133.
- 사략허가서 needs pirate fame ≥ 1000 and highest of the three.
- Promotion (`T[rank]`), fortune teller 사업운 (msg 547 prints `T[rank] - maxFame`, or 754 when due).
- Hero scripts gate chapters on fame (2000, 8000, 16000, 30000, 40000 for Joan; scenario.md).

## 7. Nation standing (family +6..+0xB)

| event | change | address |
|---|---|---|
| start | 100 each | DATA1 |
| your investment hands a port from nation `o ≠ p` to someone else | `standing[o] -= 5` | 0x2C1F2 |
| your investment makes a port join `p` | `standing[p] += 5` (cap 200) | 0x2C230 |
| caught in a town | `standing[n] += 20` | 0x1B055 |
| caught at a palace | `standing[n] = 100` | 0x2A3CE |
| defect old → n | `old -= 30` (if ≥ 30), `n = clamp(n+10, 100, 200)` | 0x2A084 |
| battle won vs a fleet of nation e ≠ 6 (e = fleet/10) | `standing[e] -= min(s, (rand(5)+10)·k/30)`, k = 30,30,10,6,3,90,60 for legality 0..6 | 0x10786 |
| same battle, e ≠ p, p ≠ 6 | legality 0,1: `+ (rand(5)+5)`; 2: ×2; 3: ×3; 4: ×4; 5, 6: `−(rand(5)+5)` (floor 0, cap 200) | 0x107C2 |
| battle won vs your own nation (e == p) | first row, then again `standing[p] -= rand(5)+10`, rank/nationality loss (§5) | 0x10819 |
| also: every won battle lowers `nation[p].rel[e]` (and copies it to `nation[e].rel[p]`) by `min(rand(5)+3, rel)` | | 0x106EF |

(All rows of 0x10693 run only for even result codes, i.e. battles the player won; lost or drawn
battles change nothing here. The routine does not check who started the fight.)

Effects: < 80 town arrest chance, ≤ 80 palace arrest chance (§1.3); ≥ 130 royal aid, < 70 aid wiped
(§4.4); monthly 0x175FD lets nation n target the player (`nation[n].+2 = 7`) when
`rand(180 - aggressiveness) + 100 < 200 - standing[n]` (never at ≥ 100; up to
`100/(180-agg)` per month at 0).

## 8. Guild (조합, building 6, 0x2CB18) — 업무알선

Entry prints msg 85 (unless a script spoke: `[0xD72]`/`[0xCE8]`), menu 1, dispatch DS:0xB8A0:
업무알선 0x2C77F, 나라정보 0x2CA2A. No rank or fame requirement.

**나라정보** 0x2CA2A: choose a nation (msg 162), msg 86 yes/no for **100 gold** (no → 87, gold < 100 →
163). Display 0x2C899: nation income (msg 1081), 공헌도 `|100 − standing[n]|`, for each other
nation `|30 − rel[j]|` with ☆ marks for flag bits 0x20 / 0x10 (exact meaning not checked), then
its war target (msg 88, or 853 if it targets you) and a port name from `nation.+4` (msg 89).

**The jobs are SNR0 script blocks 1..5** (state: `[0xCEA]` active block, `[0xCEB]` step, flags
DS:0xCEC, vars `vN` = DS:0xCF4 + 2N; see scenario.md §4–5). Script RNG
`seed = seed·0x5D588B65 + 1`, `rand(n) = ((seed>>8) & 0x7FFF) % n`, reseeded per visit from
`(year·month·(navExp+navLevel) + day) << 8`, so a guild offers the same jobs all day.

```
업무알선 0x2C77F:
  if a job is active: royal → msg 595 ; at its port → msg 931 ; else msg 338 (where to go); return
  if F16 and F17: msg 410+nat, 932 (go to the king); return
  offers: port <= 41 → three kinds rand(5) each; port >= 42 → all 편지배달
  pick one → block = kind+1, v8 = its seed, run briefing; accept → [0xCEA] = kind+1
```
tier = `min(rank,6)/3` (0, 1 for rank 3–5, 2 for rank ≥ 6). Ports are chosen by index offset from
the current port p: `v16 = p ± (rand(5) + {1,6,16}[tier])` (kept in 0..41),
`v17 = v16 ± (rand(20) + {1,16,31}[tier])` (kept in 0..99). Deadline day = `(year·12 + month + months)·30 + day`.
Fame penalty helper: `f = floor(floor(f/10)·k/10)·10`, k = 9 (cancel), 8 (late), 5 (debt not handed over).

| kind | where | parameters (tier 0/1/2) | reward | notes |
|---|---|---|---|---|
| 0 상품수송 | 교역소 of v16 → v17 | goods = zone(v16).sells[rand(6)], qty = min(rand(10)·10+50, free hold·8/10); 1/2/3 months | 1000/10000/30000, trade +200/700/1500 | cargo loaded free at v16; deliver at v17, collect pay back at v16 (no deadline for the pay); late → ×0.8 fame, job ends |
| 1 상품구입 | 교역소 of v16 | goods rand(6)+32 / rand(6)+26 / rand(10), budget 1000/5000/20000, qty = min(250, budget/zone price); 1/2/3 months | budget + 10000, trade +200/700/1500 | an advance of 10,000 is paid on acceptance (the 10,000 cap test is truncated to 16, so always 10,000); cancel → advance taken back |
| 2 편지배달 | 조합 of v17, back to 조합 of v16 | 1 month | 700, trade +50 (late: 350, no fame) | |
| 3 해적퇴치 | battles | sink (tier+1) pirate fleets (fleets 60–69); months = count | 10000/20000/30000, **pirate** +300/700/1500 | late kills: half pay, no fame |
| 4 빚독촉 | find debtor v17 = rand(41)+79 in a tavern, then 은행 of Venice (13) | tier 0: 1 bar-unit, 1 month, 5000, +150; tier ≥ 1: 2 units, 3 months, 20000, +500 | gold, trade **and** pirate fame | debtor (0x25BD7, msg 608): if `rand(100) > luck` and `rand(3)==0` he flees to another port (610/613); else pays `gold += 50000·units` (msg 609). At the bank `50000·units` is taken back and the reward paid (late: half, no fame); short of money → trade fame ×0.5, job ends. Tavern hint 0x25589 where `port%3 == v17%3` |

Deadlines are only checked when you visit the job's building or fight; an expired job blocks new
offers until you go there. One job at a time; a job also blocks the royal summons.



## 9. Item shop, church, fortune teller

### 9.1 Items (DS:0x8144 × 26 B × 100, accessor 0x5BD2)
`+0` name, `+0x15` icon, `+0x16` price/100 (u16), `+0x18` power (attack/defence/gift value/
treasure-map target; 0 = cannot be sold), `+0x19` low nibble type (0 straight sword, 1 thrusting,
2 sabre, 3 broad, 4–5 shield (unused), 6 armour, 7 instrument, 8 tool/licence, 9 consumable,
10 gift, 11 jewellery, 12 treasure map, 13 relic/quest), bit 0x10 equipped. Inventory DS:0x2D93 ×20
(0xFF empty).

Prices (gold / power): weapons 0 단도 500/5, 1 숏소드 1000/10, 2 롱소드 4000/20, 3 레이피어 3000/15,
4 에페 2000/10, 5 에스톡 6000/20, 6 숏사브르 3000/10, 7 시미타 8000/20, 8 일본도 20000/25,
9 커트라스 1500/10, 10 브로드소드 5000/20, 11 청룡언월도 24000/30, 12 프람베르그 14000/25,
13 바스터드소드 14000/25, 14 클레이모어 15000/25, 15 사브르 3000/15, 26 백호반월도 18000/25;
armour 16 하드레더 1000/10, 17 체인메일 2000/20, 18 하프플레이트 4000/30, 19 플레이트메일 8000/40;
instruments 20 사분의 4000, 21 육분의 8000, 22 경위의 12000; tools 23 회중시계 2000, 24 망원경 5000,
25 고양이 2000; 29–34 사략허가서 (price 0, unsellable); 35–40 면세증 (10000); 41 쥐약 500,
42 성스런향유 1000, 43 라임주스 1000; gifts 44 왕관 300000, 50 비단숄 3000, 51 차이나드레스 8000,
52 은제머리장식 5000, 53 백금머리빗 10000, 54 담비털가운 12000, 55 서클렛 4000, 56 공작깃털부채 3000,
57 비단리본 1000, 58 벨벳가운 5000; jewellery 59 다이아몬드왕관 100000, 60 진주팔찌 10000,
61 루비지팡이 50000, 62 은촛대 3000, 63 비취보석상자 20000, 64 보관 50000, 65 금팔찌 15000,
66 사파이어반지 18000, 67 공작석상자 8000, 68 백금브로치 20000, 69 루비반지 22000; rare 73 요도촌정
380000, 74 룬블레이드 360000, 75 성기사의갑옷 600000, 76 성기사의검 380000, 77 시바신의마검 280000,
78 에롤즈플레이트 300000; 70–72 발모제, 80–89 treasure maps, 90–98 relics (unsellable).

**Stock** (0x12E0B): market `+0x1D..+0x1F` three items (0xFF none), `+0x20` a rare item listed
only at ticks 6–8 (02:00–03:00). 52 ports stock something (e.g. 리스본 20,24,3; 세빌리아 24,6,3 /
night 13; 베네치아 17,21,4 / 68; 암스테르담 24,21,22 / 23); dump with `re.py ds 0x697c+37p+0x1d 4`.
The "비밀 아이템 가게" greeting msg 764 (0x297CE) fires at ticks 12–17 while the shop is closed —
apparently dead code. Msg 649 (midsummer night) is flavour only.

```
buy 0x294A2:  gold == 0 → msg 236; 20 items → 237
              owned already and type < 7 → 332
              price = 100·rec.+0x16 (no market / charm / licence modifier)
              msg 240 price 241, yes/no; price > gold → 239; gold -= price; first free slot = item
sell 0x295F7: equipped → 333; p = (rec.+0x16 / 2)·100; rec.+0x18 == 0 or p == 0 → 929
              msg 245/247 yes/no; on "no": if rand(100) <= luck: p += p·charm/200, msg 246, ask again
              gold = min(600M, gold + p); slot = 0xFF
equip 0x28E75: type >= 7 → 1090; three slots: weapon (0–3), shield (4–5), armour (6); toggles
```

### 9.2 Church (building 10, 0x2C5EB)
`CHIP_NO.DAT` (100 B, class per port; class 2 = Islamic, 18 ports: 이스탄불, 알제, 튀니스,
알렉산드리아, 얍파, 베이루트, 니코시아, 트리폴리, 트레비존드, 아덴, 곰브룬, 맛사와, 카이로, 바스라,
메카, 카타르, 시라흐, 무스카트). `[0xC150]` = mosque; messages are `base + 712·mosque` (91–96 vs
803–808). A Turkish hero is refused at a church (msg 90), anyone else at a mosque (msg 802).
Menu 7, dispatch DS:0xB83A.
```
예배 0x2C408: msg 92; once per visit ([0xC6D8]): luck = min(100, luck + rand(2))
기부 0x2C44E: msg 93; n = input(0..gold); if n == 0 return
              q = gold / n
              if q > 10: msg 94                   # less than ~10 % of your gold: no effect
              else: msg 95; if (rand(5)+1)·100 <= n: luck = min(100, luck + 11 - q)
              gold -= n
leave: msg 96
```
Only luck changes; no fame or standing.

### 9.3 Fortune teller (building 11, 0x2CD51)
msg 298, menu 17 (dispatch DS:0xB8C2); every reading costs **50** (msg 299 yes/no; < 50 → 300, out).
연애운 disabled for Catalina (`[0x1241]==1`), 동료운 if you have no companions.
```
인생운 0x2CB8A: msg 302 + luck/25
사업운 0x2CBA9: msg 545 (30·min(navLvl,18)² − navExp), msg 546 (same for battle level/exp),
                unless nationless: need = T[rank] − max(fame); need > 0 → msg 547 need, else msg 754
연애운 0x2CC63: first woman (DS:0x2B56 ×17 B) in this port with flag 8 and not 0x40:
                affection >= 80 → 326 (names her), >= 50 → 327, else 328; none → 329
동료운 0x2CCDE: choose companion (792); msg 78 + luck/25, then 793 + loyalty/25
```

## 10. Discoveries and the NPC residences

### 10.1 Discovery sites
`COLONY.DAT`: 100 × 218 B (`name[18]`, `+0x12` picture, `+0x13` description), read at `idx·218`
(0x33F1F). Site table DS:0x7E88 × 7 B × 100 (0x5BC2): `x,y` u16 (2×2 tiles, world cell 0x11),
`+4` relic item (0 or 0x5A+k), `+5` value, `+6` flags: 0x80 inactive, 0x40 village sighted,
0x20 found (or its map bought), 0x10 reported, low 3 bits category (DS:0x8DA: 보물, 원주민, 희귀한
동물, 식물, 유적, 괴물, 자연, 원주민). New game (0x16177): all inactive, then 50 random sites
activated; ten random inactive sites become relic sites (`+4 = 0x5A+k`) and treasure map item
`0x50+k` gets `+0x18 = site`. Values: 10..100 (도도, 나무늘보, 모아, 맘모스, 검치호, 모아이 = 100).

**Sighting** (0x3070D, every step at sea, at most one find per call):
```
I = max 직감 of admiral and companions
for port in 0..129 with !(port.+0x13 & 0x30):
   seen if |dx|,|dy| <= 2, or (weather [0xC3F]&15 != 3 and within range max([0xC176],2)
        and inside the 24×24 view and rand(200) < I)
   → log (msg 381), port.+0x13 |= 0x10, announce (msg 1172/1173/1175), adventure fame
then the same for active, unsighted sites → +6 |= 0x40 ("부락을 발견했습니다")
fame: market port → 25 × region (Europe 0); supply port → 50; village → 50 (msg 476)
```
**Landing** (상륙 0x34651) on an active site's tile: village menu 35. 보물탐색 0x340FD needs food;
`score = 7·직감/20 + 3·운/20 + bonus` (bonus `[0xBFD2]` from 환대); `score <= value` → nothing
(429); else found (431, or 430 with crew loss for categories 1 and 5), `+6 |= 0x20`, picture shown.
No fame or money at that point. 환대 costs 2 barrels of food, bonus += 5; 식량약탈 gives
`(rand(5)+2)·10` food, 1/4 counterattack, charm −2, luck −2, bonus = 0. Relics: 탐색 on a
non-village landing at a site with `(+6 & 0xF0) == 0xA0` gives the relic in the map's slot.

### 10.2 NPC residence (building 7, 0x2D9A8)
NPC table DS:0x29B2 × 21 B × 20 (0x5AFC): `name[16]`, `+0x10` type, `+0x11` portrait,
`+0x13` flags (0x10 contracted, low 2 bits pay factor k), `+0x14` port. No NPC → msg 933.
Records 10+n are the six rulers used by the palace. Type dispatch DS:0xB8FA.

**Type 0 patron** (menu 24; 마르코 리스본 k0, 모리스백작 코펜하겐 k1, 라나잼 알렉산드리아 k1,
모데나공 피사 k2, 모르데스 보르도 k0): 계약 (exclusive, msg 480–483); 발견물보고 0x2CEA0 for every
site found and not reported:
`gold += 50·value·(5−k)·(value==100 ? 4 : 1)` (msg 486 + value/25), `adventure += value·(value==100 ? 15 : 8)`,
`+6 |= 0x10`. 모험이야기 0x2D02A: rumour of the first active unsighted site 0–49 (lat/long rounded
down to 5°; fake coordinates if `rand(80) > luck`).

**Type 1 map maker** (menu 25; 베라치아노 베네치아, 헤랄드요데 엔트워프, 리베이로 바르셀로나,
올리버스 팔마, 메르카토르 암스테르담; k = 1): 계약 needs 지도작성술 (msg 496), exclusive;
기능습득 needs 항해, 지식, 직감 ≥ 75; 지리보고 0x2D3A0 pays for new exploration cells (bitmap DS:0xD74,
90×45 cells of 24×24 tiles; `[0xF9A]` total, `[0xF9C]` since last report):
`gold += 20·new·(5−k)`, `adventure += 5·new`; at 3300 cells msg 507 (world map complete).
지도확인 costs 20,000 (needs more than 20,000) and locates a treasure map to 5°.

**Type 2 줄리아노 교수 (나폴리)** teaches 측량술 (항해 ≥ 70, 지식 ≥ 80, 직감 ≥ 70); **type 3 월프 박사
(함부르크)** teaches 포술 (통솔 ≥ 75, 지식 ≥ 65, 용기 ≥ 80). Skill fee for all three skills:
`min(60000, (u16)((5000/(charm/5+1) + 200)·100))` — the 16-bit truncation makes it cheap at low charm.


## 11. Open questions

1. Port `+0x13` bit 0x80 selects "식민지" over "동맹항" in the harbour greeting (msg 580, 0x64B9),
   but no code sets it; maybe only a script or unused. Bit 0x08 "developing" halves the port's
   economy in nation income and is set/cleared by the daily routine — name is a guess.
2. Nation record `+3`, `+4`, `+6` (accrues like the gold aid, no reader found), `+0x12..` flag bits
   0x10 / 0x20 (read by 0xFB8E; probably "at war with" / "allied") — writers are in the nation AI
   (0x179A0, 0x17BD1, 0x17CC3, 0x17DB7, 0x17EAC, 0x18362, 0x184D2, 0x1863C, 0x186DF), not decoded.
3. `cost = rand(3)+2` returned by the building entry (0x1B14E) — assumed to be ticks spent; the
   caller's use was not checked.
4. 면세증 expiry runs when `[0x56F] % 6 == 2` inside the monthly routine; msg 873 says renewal is in
   April/October. Whether `[0x56F]` already holds the new month when 0x189DA runs decides
   whether certificates vanish on 1 March/September or 1 April/October.
5. Fame threshold for rank 8→9: script 40,500 vs fortune-teller table 40,000 (DS:0xB8B0[8]).
   Use the script value for promotion and the table only for the fortune-teller readout.
6. A nationless port (nation 6) still has a palace: it uses ruler NPC 16 and standing byte
   family `+0xC`; what its 알현/망명 do was not traced (defecting to "nation 6" looks possible).
7. Royal commission 11: who writes site `+4` = 90–96 (new-game data has 0; the search has no
   upper bound). Block 12 when the nation's target is 7 (the player) can never complete.
8. Battle result codes 0/1, 6/7, 8 and 9 (`[0xA509]`, writers 0xF722.., 0xA1B0) are only partly
   identified (even = won); see the battle notes when written.
9. Item shop: the 비밀 아이템 가게 greeting at ticks 12–17 (shop closed) — dead code or bug.
10. Sighting range `[0xC176]` and weather value 3 used by discovery sighting (0x3070D).
11. Not covered here: 주점 여급 menus 13/14 (선물, 조사의뢰, 정보수집), 도박 (msgs 962–1010),
    the 여관, 조선소 building/remodel. RE_NOTES has the tavern and shipyard basics.
12. RE_NOTES calls `[0x574]` "함대 최대 10척"; in the ship-aid path it is the first entry of a
    scratch list of free spare ship records (0x12A10).

## Sources
Main routines: bank 0x28754–0x28C33, interest 0x1730D; investment 0x24A58, 0x2C24F, 0x24936,
0x2C04A, 0x2C16E, AI 0x33568; palace 0x2A424, 0x29EDD, 0x29BC8, 0x29C3A, 0x29D46, 0x29FB0,
0x2A0CD, 0x2A155, 0x2A2A2; monthly aid 0x183DA, income 0x17464, war target 0x175FD; building
entry 0x1B08E/0x1B150, arrest 0x1AF95; battle fame/standing 0x10388, 0x10693, 0xFB8E; SNR0
blocks 0–12 (script disassembler in the session scratchpad, see scenario.md for the VM).
