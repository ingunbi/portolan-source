# Scenario script VM (SNR0..6.DAT / SNR0..6.MES)

Status: the bytecode is fully decoded. `tools/snr.py all --check` decodes all 7 files
(186 blocks, 24,738 instructions) with no desync, no invalid opcode, and every trigger and jump
target landing on an instruction boundary.

All code addresses are MAIN.EXE load-image offsets. `DS:n` = image `0x378B0 + n`.

Disassembler usage:

```
build/venv/bin/python tools/snr.py 1              # whole SNR1 as pseudo-code, dialogue resolved
build/venv/bin/python tools/snr.py 1 0.0 --raw    # chapter 0 block 0 with bytes
build/venv/bin/python tools/snr.py 1 --triggers   # trigger tables only
build/venv/bin/python tools/snr.py all --check    # self-check (exit 1 on any desync)
```

Each output line is `<block-relative pc> <file offset> <instruction>`. Jump targets and trigger
offsets are block-relative (this is what the VM uses). `SAY[w1 face 19] #1 "..."` is the
folded form of `win 1; face 19; say #1; wait` (use `--plain` to unfold).

---

## 1. Files and which one runs

| file | used by | text |
|---|---|---|
| `SNR0.DAT` | every hero: guild jobs, Venice bank, royal commissions (shared) | `SNR0.MES` (192 lines) |
| `SNR{h+1}.DAT` | hero `h = [DS:0x1241]`: 1 Joan, 2 Catalina, 3 Otto, 4 Ernst, 5 Pietro, 6 Al | `SNR{h+1}.MES` |

0x3217E (called at game start/load from 0x16155) patches the digit of `"C:SNR*.DAT"` (DS:0xA40)
and `"C:SNR*.MES"` (DS:0xA9C) and opens both pairs:
`[0x55C]/[0x55E]` = hero DAT/MES, `[0x566]/[0x568]` = SNR0 DAT/MES. The `F4 n` ending codes in
the files confirm the mapping (SNR1 ends with `ending 0`, SNR2 `ending 1`, ... SNR6 `ending 5`).
`EVENT{h+1}.DAT` (pictures for opcode `CB`) is patched the same way (0x16173).

## 2. SNRn.DAT format

All multi-byte numbers are **big-endian**.

```
0x00  "SNDT" + 12 zero bytes
0x10  u32 chapter_offset[]   absolute file offsets, terminated by 0xFFFFFFFF
chapter:  u16 block_offset[]  relative to the chapter start, terminated by 0xFFFF
block:    trigger table, then bytecode
```

A block runs from its offset to the next block/chapter header (or EOF). The loader (0x32206)
reads the u32 at `0x10 + 4*chapter`; if it is 0xFFFFFFFF the context's chapter becomes 0xFF
(scenario finished). Otherwise it reads the u16 at `chapter_base + 2*block` and loads 0x4000
bytes from `chapter_base + block_offset` into the script buffer (EMS page `[0xC14]`). The PC is
block-relative; jumps are absolute within the block.

Trigger table (4 bytes per entry, at the start of every block):

```
u8 key1, u8 key2, u16 offset      ; offset is block-relative
FF xx xx xx                       ; end of table (only key1 is checked)
```

SNR1: 6 chapters, 40 blocks. SNR0: 13 chapters, 35 blocks. (`snr.py N --triggers` lists all.)

## 3. Runtime: contexts, triggers, results

### 3.1 Two script contexts

| | hero context (SNR1..6) | shared context (SNR0) |
|---|---|---|
| chapter / block | `DS:0xC60` / `DS:0xC61` | `DS:0xCEA` / `DS:0xCEB` |
| flags f0..f63 (bit n of byte n>>3) | `DS:0xC62..0xC69` | `DS:0xCEC..0xCF3` |
| vars v0..v63 (u16) | `DS:0xC6A..0xCE9` | `DS:0xCF4..0xD73` |
| find trigger / run | 0x32E02 / 0x32D86 (both: 0x32EB6) | 0x32CC1 / 0x32C30 (both: 0x32D65) |
| wildcard 0xA3 matches key1 < | 100 (ports) | 0x82 (ports and supply ports) |
| enabled when | `[0xC30] & 0x40` and chapter != 0xFF | always |

The VM itself works through pointers: `[0x44A]` flags, `[0x44C]` vars, `[0x448]` chapter,
`[0x449]` block, `[0x450]`/`[0x452]` DAT/MES handles, `[0x44E]` PC, `[0x454]:[0x456]` far
byte pointer, `[0xBC20]` current opcode. All state above lives in the saved block
(save-file offset = DS address - 0xB99).

New game (0x16588): everything is 0 (chapter 0, block 0). If the story option bits
`[0xC30] & 0x42` are clear the hero context is disabled with `[0xC60] = 0xFF`.

### 3.2 Trigger lookup (0x32E02 / 0x32CC1)

`find(key1, key2)`: load block (chapter, block), PC = 0, walk the table:

```
for (k1, k2, off) in table:            # stop at k1 == 0xFF -> no script (return 0)
    if (k1 == key1 or (key1 < LIMIT and k1 == 0xA3)) and (k2 == key2 or k2 == 0xFF):
        PC = off; return 1             # first match wins, so specific entries come first
```

`key2` is also stored in `[0xBC1C]` (used by `E8` to redraw the building afterwards).

| key1 | key2 | fired by |
|---|---|---|
| port 0..129 | building 0..11 (below) | entering a building (0x1B08E -> 0x1B17F: SNR0 first, then hero unless SNR0 set v63) |
| port | 5 / 0x15 | palace (5 = at the gate, 0x15 = audience with the ruler, 0x29EDD) |
| port | 6 | guild, again after a job is chosen (0x2C86E, SNR0 only) |
| 0xA0 at sea | days since departure `[0x2D54]` | start of each day at sea (day loop 0x1AC8F), hero context only |
| 0xA1 battle start | enemy admiral's person id (var v60, set by 0x10C96) | 0xFA3A hero, 0xFA5C SNR0; result 0 cancels the battle |
| 0xA2 battle end | enemy admiral (v60) | 0x10A45 SNR0, 0x10A50 hero |
| 0xA3 | building | wildcard "any port" (see LIMIT) |
| any | 0xFF | wildcard "any key2" |

Building numbers (door table DS:0x88C, handler table DS:0xAE88):
0 market 0x24C9E, 1 tavern 0x26FF5, 2 shipyard 0x2C310, 3 harbor/pier 0x280A3, 4 inn 0x286A5,
5 palace 0x2A424, 6 guild 0x2CB18, 7 residence of a story NPC 0x2D9A8 (NPC table DS:0x29B2),
8 bank 0x28C33, 9 item shop 0x297B9, 10 church 0x2C5EB, 11 fortune teller 0x2CD51.

### 3.3 Running (0x32C30 / 0x32D86 -> main loop 0x32B8B)

1. v63 := 0 (`[0xD72]` / `[0xCE8]`).
2. seed := ((hero sail exp `+0x26` + sail level `+0x24`) * month * year + day [+ tick in the
   hero context]) << 8 (`[0xBC36]`, 32-bit). So `rand` is repeatable within the same day.
3. loop: fetch opcode; dispatch on `op >> 6` (0x323B1 / 0x325B1 / 0x326EB / 0x3287A); stop when
   a handler returns 0 (`F2`, `F4`, or an invalid opcode -> error dialog 0x31326).
4. close all windows (0x314DD).
5. if `F0` ran: block++ and reload. If `F1` ran: chapter++, block := 0, **flags f0..f31 := 0**,
   reload (f32..f63 and all vars survive). If the next chapter is 0xFFFFFFFF the context's chapter
   becomes 0xFF and it never triggers again.
6. store chapter/block back. SNR0 only: if the chapter changed, chapter and block are reset to 0
   (in SNR0 `next_chapter` means "job finished, back to chapter 0").
7. return value: 1, or 0 if `F8` (`leave`) ran.

What the caller does with the result:

- building entry (0x1B1B2): either context returning 0 -> you are put back outside without the
  building's menu (except the inn, which always opens).
- **v63** of either context (`[0xD72]`, `[0xCE8]`) non-zero -> the game skips its own standard
  line for the event: every building handler tests it before its greeting (e.g. tavern 0x2701A,
  market 0x24CBF) and still opens the menu; at battle start it skips the pre-battle hail
  (0xFA70 -> 0xF9CA), at battle end the result message (0x10A55). A non-zero SNR0 v63 also
  stops the hero script from running at building entry. Scripts set `v63 = 1` when they did
  the talking themselves.
- battle start: result 0 -> battle cancelled (`[0xA509] = 8`).

## 4. The VM

There is no stack. Operands are the 64 vars `vN`, the 64 flags `fN`, immediates, and DS
pointers stored in vars (`word[vN]`, `byte[vN]` = memory at the address held in vN; this is how
scripts touch game records, after `D0`/`DC` load an address).

Source operand resolver 0x322FE, mode `m`, byte `n`:
`0` vN, `1` word at address vN, `2` fN as 0xFFFF/0, `3` immediate n.
Destination resolver 0x3236A: `0` &vN, `1` address in vN, `2` bit mask of fN.

### 4.1 0x00-0x3F MOV `00DD SSAA` (0x323B1), 3 bytes `op dst src` (+1)

| A | meaning |
|---|---|
| 0 | word move. If D != 2 and S = 3 the immediate is **16-bit**: `op dst hi lo` (4 bytes) |
| 1 | byte move (D=0: `vN = (u8)src`; D=1: store one byte) |
| 3 | system value, `src` byte selects it (S bits ignored), always into `v[dst]` |
| 2 | invalid |

D: 0 `v[dst]`, 1 `*v[dst]`, 2 `f[dst] = (src != 0)` (needs A=0, S!=0). D=3, and D<2 with S=2,
are invalid. System values (A=3): 0 copy the text buffer (set by `D4`) to the address in v[dst]
(needs D=1; used to rename people), 1 sea area `(y/24)*90 + x/24` of the player's fleet
`[0xC6DA]`, 2 year (`[0x56E]`, years since 1501), 3 month (`[0x56F]`, 0-based), 4 day
(`[0x570]`, 0-based), 5 current port `[0xC3A]` (0xFF at sea), 6 duel result `[0xA538]`,
7 tick `[0x571]` (72 per day, 3 per hour: 66 = 22:00).

Used encodings: `0C` v=imm16, `0D` v=(u8)imm, `00` v=v, `04` v=word[v], `05` v=byte[v],
`0F` v=sys, `10` word[v]=v, `11` byte[v]=v, `14` word[v]=word[v], `1C` word[v]=imm16,
`1D` byte[v]=imm, `1F` strcpy, `2C` f=imm.

### 4.2 0x40-0x7F arithmetic `01oD SSoo` (0x325B1), 3 bytes `op dst src`

op = `opcode & 0x23`: 0 `+=`, 1 `-=`, 2 `*=`, 3 `/=` (unsigned; divide by 0 gives 0xFFFF and an
error dialog), 0x20 `|=`, 0x21 `&=`, 0x22 `>>=` (count & 7), 0x23 `<<=`.
D: 0 dst = vN (word), 1 dst = byte at address vN. S: 0 vN (word), 1 byte at address vN,
2 flag (byte 0xFF/0), 3 immediate byte (so only 0..255).

### 4.3 0x80-0xBF conditional jump `10LL RRcc` (0x326EB)

The jump is taken when the condition is **false** (compiled `if (cond) { ... }`):

- L = 0/1: `op a b hi lo` (5 bytes). left = va or word[va]; right = source mode R with b.
  cc: 0 `==`, 1 `!=`, 2 `>=`, 3 `<=` (unsigned 16-bit).
- L = 2 (flag), R = 3: `op f hi lo` (4 bytes). Condition `f == (cc & 1)`.
  `AD f` = "if f set ... else goto", `AC f` = "if f clear ... else goto".
- L = 2, R = 2: `op f g hi lo` (5 bytes), condition `f == g`.
- L = 3, or L = 2 with R < 2 or cc >= 2: invalid.

The disassembler prints the jump condition directly, e.g. `8E 01 42 00 F7` = `if v1 < 66 goto 00f7`.

### 4.4 0xC0-0xFF (0x3287A, jump table 0x3289E)

Size includes the opcode. `w` = big-endian u16, `b` = byte.

| op | size | name in snr.py | handler | semantics |
|---|---|---|---|---|
| C0 b | 2 | `win b` | 0x31428 | select speech window b (0..3, at DS:0xBBBA+24b). Opens/frames it if not open (max 2 open, `[0xBC1D]`, ids `[0xBC1E..F]`), clears it if already open. Joan's files: 0 narration (no portrait), 1 other speaker, 2 hero side, 3 picture frame |
| C3 | 1 | `win_close` | 0x31480 | close the most recently opened window |
| C4 | 1 | `win_close_all` | 0x314DD | close all windows (also done automatically at script end) |
| C5 b | 2 | `win_clear b` | 0x31525 | clear window b if open |
| C7 | 1 | `wait` | 0x140EA | wait for key/click |
| C8 w | 3 | `say #w` | 0x31FBE + 0x31550 | load MES line w, expand `$` codes into DS:0x45A, print in the current window (0x4B6F) |
| C9 b w | 4 | `vb = menu #w` | 0x3213C + 0x3155B | line w split at `\n` into choices (pointers DS:0xBC22), menu at (60,80) via 0x13CA3, choice index -> vb |
| CA b | 2 | `bgm b` | 0x3158A | play music b (0x94C6); b = 0x15 also calls 0x9541(0) |
| CB w w b | 6 | `picture b at (x,y)` | 0x315A4 | draw image b of `EVENT{h+1}.DAT` at x, y (0x5A51), then reopen GRAPH.DAT |
| CC w | 3 | `face w` | 0x315F4 | portrait w (KAO.LZW index) in the current window (0x7B76) |
| CD b | 2 | `face vb` | 0x315F4 | portrait number from vb |
| D0 d t i f | 5 | `vd = &table[vi]+f` | 0x3162E | address of field f of record vi of table t (list below) |
| DC d t i f | 5 | `vd = &table[i]+f` | 0x3162E | same with an immediate index |
| D1 b | 2 | `fleet_replan vb` | 0x317DD -> 0x3325D | recompute the AI course of fleet vb from its mission fields (+0x1B mode, +0x1C target, +0x29 flags); scripts set those fields first, e.g. to make a fleet chase the player |
| D4 w | 3 | `text_buffer = #w` | 0x31FBE | expand MES line w into DS:0x45A without printing (for MOV sys 0) |
| E2 a b | 3 | `cargo_add` | 0x317F8 | add vb units of trade good (u8)va to the player's ships, filling slots with that good or empty ones up to free capacity |
| E3 a b | 3 | `cargo_take` | 0x318FB | remove up to vb of good va; afterwards vb = amount of that good left in the fleet (vb = 0 in -> count) |
| E4 b | 2 | `gold = vb` | 0x319C4 | gold := (s16)vb, cap 600,000,000; refresh status in port |
| E6 b | 2 | `gold += vb` | 0x31A00 | gold += (s16)vb, same cap |
| E7 b | 2 | `gold -= vb` | 0x31A42 | if vb >= gold then gold := 0 else gold -= vb |
| E8 b | 2 | `duel b` | 0x31A8F -> 0x12846 | sword duel hero vs person b; result in sys 6 `[0xA538]` (starts at 100; scripts treat <=40 as lost, >=160 as won, 41..159 as undecided/fight again, >=100 as "winning") ; redraws the building `[0xBC1C]` |
| E9 b | 2 | `fb = yes_no()` | 0x31AF7 | yes/no prompt (0x13FDB), yes sets fb |
| EA b | 2 | `vb = gold / 10000` | 0x31B3E | |
| EB b w | 4 | `vb = rand(w)` | 0x31B68 | seed = seed*0x5D588B65 + 1; vb = ((seed>>8) & 0x7FFF) % w; w = 0 gives 0 |
| EC b | 2 | `seed = vb << 8` | 0x31BBC | |
| ED b | 2 | `vb = seed >> 8` | 0x31BDA | |
| EE b | 2 | `vb = cargo_free()` | 0x31BFF | total free cargo capacity of the active ships |
| F0 | 1 | `next_block` | 0x32AFB | after the script ends: block++ |
| F1 | 1 | `next_chapter` | 0x32B01 | after the script ends: chapter++, block 0, clear f0..f31 |
| F2 | 1 | `end` | 0x3292A | stop |
| F4 b | 2 | `ending b` | 0x17032 | game end sequence b (clears story bits 0x02/0x40 of `[0xC30]`, hands the code to END.EXE through `int 65h`). Story endings use b = hero id; b & 0xF0 = 0x10 / 0x80 are other endings |
| F8 | 1 | `leave` | 0x32B1F | result := 0 (leave the building / cancel the battle); execution continues |
| F9 t x | 3 | `order_ship t` | 0x31C64 | order a new ship of type t in the first free slot of the player's fleet (status 0x20 under construction, durability 9/10 of type, crew 0, cargo cleared, docked at port \| 0x80). x is read and ignored |
| FA x w | 4 | `deliver_ship` | 0x31DAC | finish the ship under construction (status 0x10), captain := `[0x574]`, name := MES line w. x ignored |
| FB b | 2 | `join b` | 0x31E52 | person b joins: first free slot of the officer list DS:0x2D57, person `+0x2E` = 6, fleet/port copied from the hero |
| FC b d | 3 | `woman[b].affection += d` | 0x31EA8 | record DS:0x2B56+17b `+0x0D` (cap 100) |
| FE w | 3 | `goto w` | 0x32B72 | |
| FF | 1 | `nop` | | |
| others | | `BAD` | 0x3291E | error dialog, stop (C1 C2 C6 CE CF D2 D3 D5-DB DD-E1 E5 EF F3 F5-F7 FD; none occur in the files) |

Note: `F4` advances the PC counter `[0x44E]` by 1 although it reads an operand byte. The PC is
only used for error messages; fetching uses the byte pointer, so `F4` is 2 bytes in the stream.

### 4.5 D0/DC record tables (0x3162E, jump table 0x31654)

| t | name (snr.py) | address | note |
|---|---|---|---|
| 0 | hero_tbl | DS:0x1106 + 32i | 7 records, purpose not checked |
| 1 | family | DS:0x11E6 + 14i | +0 trade fame, +2 battle (pirate) fame, +4 adventure fame (u16), +6..+0xB hostility per nation, +0xD peerage rank |
| 2 | gold | DS:0x123A (index ignored) | fixed block: +0 gold u32, +4 bank, +7 = `0x1241` hero id |
| 3 | person | DS:0x1242 + 50i | +0 given name, +0xD family name, +0x1A portrait (u16), +0x1C abilities, +0x23 luck, +0x24/0x25 levels, +0x2C fleet, +0x2D port, +0x2E role (3 first mate, 4 accountant, 6 joined, 2 ship captain, 1 admiral), +0x31 flags (low nibble = nation, 0 = Portugal) |
| 4 | npc | DS:0x29B2 + 21i | story NPCs living in residences: name[16], +0x10 residence type, +0x11 portrait, +0x14 port |
| 5 | woman | DS:0x2B56 + 17i | barmaids/heroines (카를로타, 루치아, ...): +0xB portrait, +0xC port, +0xD affection, +0x10 flags |
| 6 | player | DS:0x2D54 (index ignored) | +0 days at sea, +1/+2 rations, +3 officers[30] (DS:0x2D57), +0x21 salaries[30], +0x3F items[20] (DS:0x2D93, 0xFF = empty) |
| 7 | ship_slot | i<10: `[0xC6DA]`+0x2B+9i, else DS:0x5666+9i | ship slots of the current fleet |
| 8 | fleet | DS:0x2DB2 + 0x85i | +0 x, +2 y, +0xC, +0x1B mission mode, +0x1C target, +0x28, +0x29 flags, +0x2A admiral |
| 9 | cargo | DS:0x5210 + 30i | |
| 10 | ship | DS:0x57CE + 25i | |
| 11 | ship_type | DS:0x5E28 + 12i | |
| 12 | port | DS:0x5F54 + 20i | +4 name, +0x13 nation (& 7) and flags (bit 0x20 toggled by Joan's story for Sakai/Nagasaki) |
| 13 | market | DS:0x697C + 37i | |
| 14 | trade_zone | DS:0x77F0 + 128i | |
| 15 | yard_stock | DS:0x7E70 + 8i | |
| 16 | supply_pt | DS:0x7E88 + 7i | |
| 17 | item_def | DS:0x8144 + 26i | item name at +0 (item 3 레이피어, 12 프람베르그, 0x34 은제 머리장식, 98 성자의 지팡이) |
| 18 | discovery | COLONY.DAT record i (0xDA bytes) loaded to DS:0xBEF6 | |
| 19 | tbl19 | DS:0xC0B6 + 2i | runtime table, not identified |

### 4.6 Text

MES file: BE u32 offset table (entry count = first offset / 4), NUL-terminated EUC-KR lines;
`#w` is the line index (= index into `assets/text.json["scenarioN"]`). Line fetch 0x31F21 reads
up to 256 bytes. Expansion 0x31FBE:

| code | replaced by |
|---|---|
| `$n` | hero given name (person `+0`, e.g. 조안) |
| `$s` | hero family name (person `+0xD`, e.g. 페레로) |
| `$dNN` | decimal value of var NN (two digits) |
| `$rNN` | string at the address held in var NN (e.g. a port or item name loaded with `DC`) |
| `$x` other | x |

After each substitution `[0x8BCE]` gets a flag from 0x4184 (string) / 0x4240 (number); the
particle markers in the text (`(를)`, `(야)`, `(이냐)`, `(라고)`) are then resolved when printing.
`§name§` at the start of a line is the speaker label. A `\n` splits lines (and menu choices).

## 5. Game state the scripts use (summary)

- Hero context flags: the hero files only use f0..f16, so all story flags are chapter-local
  (cleared by `next_chapter`); the chapter/block position is the real progress state. f16 is the
  usual target of `yes_no()`. Vars are scratch per script (SNR1 uses v0..v12; other heroes up to
  v30) except **v60** = enemy admiral of the current
  battle (written by the game); **v63** = "the script spoke, skip the game's standard greeting/message" (cleared before every run).
- SNR0: f16 royal summons eligible (computed by the scripts), f17 summoned (set natively at
  0x257F4 / 0x2831B when a messenger delivers the summons, read at 0x29EFE), f18 commission
  accepted; f16..f18 and the chapter are cleared on failure (0x108E3).
  v0..v2 offered job kinds (0 상품수송, 1 상품구입, 2 편지배달, 3 해적퇴치, 4 빚독촉; names DS:0xB84A),
  v3..v5 their seeds, v6 active job code = SNR0 chapter (read natively as `[0xD00]`, values
  1..12), v8 chosen seed, v16 target port (`[0xD14]`), v17 goods (`[0xD16]`), v18 quantity
  (`[0xD18]`), v19 (`[0xD1A]`), v23 rank tier `min(rank,6)/3`, v29 rank, v30 commission chapter
  (`[0xD30]`), v31 commission seed.
- Guild flow: entering the guild runs SNR0 chapter 0 block 0 (generates offers); the native menu
  0x2C77F lists them, sets block = kind+1 and v8, re-runs SNR0 `(port, 6)` (job briefing), then
  sets SNR0 chapter := v6. The trade, tavern and guild code compare `[0xD00]` with the job codes.
  Chapters 1–2 have market triggers (goods jobs), 3 guild, 4 battle start/end (pirate hunt),
  5 Venice (13) bank (debt collection), 6..12 palace / audience (royal commissions), entered at
  the audience (0x29F05) by chapter := v30 when f17 is set and the port's nation is the hero's.

## 6. Joan Ferrero (SNR1) walkthrough

Offsets: `block-relative / file`. Text line numbers are `#n` in `scenario1`. Requirements marked
"fame" are the adventure fame `family[0]+4` with the hero still Portuguese (`person[0]+0x31 & 0xF == 0`).

### Chapter 0 — prologue in Lisbon (block 0: file 0x032..0x86E)

Triggers: Lisbon residence/tavern/palace/church/shipyard/harbor/market/item shop/any, at-sea day 1.

| trigger | condition | what happens |
|---|---|---|
| residence 0x02C/0x05E | !f0 | father's audience (0x12A/0x15C, #22–54): ordered to find Prester John; `order_ship 5` Caravel Latina (0x22A/0x25C); Rocco (person 69) joins; f0 := 1 |
| residence | f0, !f5 | butler Marco turns you away (#0) |
| residence | f5, !f1, tick >= 66 (22:00) | mother's farewell (#1–17), item[0] := 0x34 silver hair ornament (0x0E9/0x11B), f1 := 1. Before 22:00: refused (#18) |
| residence | f1 | farewell with Marco (#19–21) |
| tavern 0x264/0x296 | !f0 | Carlotta and Lucia (#56–62), f4 := 1 (later visits: #55) |
| tavern | f0, !f5 | v63; Carlotta hands over 1000 gold from the duke (`0C 00 03 E8 E6 00` at 0x35F/0x391); Lucia arranges the night visit to the mother; affection of woman 0 and 1 := 100; f5 := 1 |
| tavern | f5, !f1 | reminder "come between 22:00 and 24:00" (#63) |
| palace 0x3CC | | before f0 "your father is looking for you" (#87); after: "you are a commoner now" (#88); leave |
| church 0x3E2 | !f0 | priest Felipe asks for a sailor (#90–94), f7 := 1 |
| church | f0, !f2 | Enrico (person 70) joins to be taken to Zipangu (#104–124); port 98 Sakai and 99 Nagasaki `+0x13 |= 0x20`; f2 := 1 |
| church | f2, !f8 | 1000 gold offer, menu #97 take/donate/refuse (0x43B/0x46D): take = gold += 1000 (0x44D/0x47F), donate = hero luck (+0x23) := 100; f8 := 1 |
| shipyard 0x55F | f0, !f3 | ship delivered: `deliver_ship` name #132 『헤르메스Ⅱ세』 (0x59B/0x5CD), f3 := 1 |
| harbor 0x5A4 | f0, f3, f2, f1, !f10 | Rocco's trading lecture (#142–157); yes/no: Enrico becomes accountant (`person[70]+0x2E := 4`) and Rocco first mate (`person[69]+0x2E := 3`); f10 := 1. Missing steps give hints (#133–141) |
| market 0x749 | | hints, refuses without a ship |
| item shop 0x77C | f0, !f9 | rapier (item 3) put in item[1]; f9 := 1 |
| any 0x7C7 | | random flavour lines (`rand(3)`) |
| at sea day 1 0x83A | | `next_block` |

Block 1 (0x86E): at sea day 3 -> stowaway "Domingo" (person 71) joins (#189–205), `next_chapter`.

### Chapter 1 — the missing crown prince (file 0x922)

- Block 0: Lisbon residence on day <= 3 (0-based) of a month: Marco gives 1000 gold allowance
  once (`0C 00 03 E8 E6 00` at 0x044/0x96E; f6 re-armed on day 3 at sea). **Harbor of any port
  with fame >= 2000 -> next_block.**
- Block 1: tavern of a port other than Lisbon/Sevilla/Istanbul, tick 13..51: Rocco's rumour that
  Prince Albert vanished (f0). Inn: Domingo ran to the shipyard (f8). Shipyard: Antonio Khan
  (person 60) attacks (needs f0), `duel 60`; Catalina (person 1) intervenes, picture 0 (f1 := 1). Harbor
  with f1: Domingo is revealed as Prince Albert -> next_block.
- Block 2: Lisbon. Residence before f5: the mother says the duke was arrested; if
  `person[60]+0x31 & 0x20` Antonio Khan ambushes you, `duel 60` repeated until the result is
  <= 40 (lost) or >= 160 (won: Antonio gets fleet 60 / at sea, hero battle level `+0x25` +1);
  person 71 is renamed 알베르트 황태자 with portrait 21 (`D4` + `MOV sys 0`), f5. Palace with f5: trial
  of the duke, the prince clears him (f2). Residence with f2: father's thanks, yes/no stay
  (f16); refusing gives the Flamberge (item 12) in the first free item slot (unless already
  owned); family `+2` and `+4` fame +1000 each (cap 50000); f3. Harbor with f3: the prince leaves the fleet (officer slot
  cleared), f4. At sea day 1 with f4 -> `next_chapter`.

### Chapter 2 — Catalina and the kidnapping of Lucia (file 0x12A9)

- Block 0: any building in any port with fame >= 8000 -> next_block.
- Blocks 1–2: random (`rand(2)`) encounters with Catalina in taverns/buildings; harbor resolves
  (f2), next at-sea day 1 -> next_block.
- Block 3: harbor of any port: Catalina challenges you; fleet 10 (hers) is moved onto the
  player's position, mission 7, flags 65, `fleet_replan` -> next_block.
- Block 4: battle start vs admiral 1 (Catalina), v63 -> next_block. Block 5: battle end vs
  admiral 1; Catalina's flags `+0x31 |= 0x20` -> next_block.
- Block 6: tavern outside Lisbon: Al (person 5) tells that Lucia has been kidnapped and asks you
  to look for Sapa; `woman[1]+0x10 &= ~8` -> next_block. Block 7: Lisbon tavern -> next_block.
- Block 8: taverns of ports 72..80 (Middle East); Sapa is found in Basra (76) -> next_block.
- Block 9: Istanbul (2) tavern/inn: meet Al -> `next_chapter`.

### Chapter 3 — Prester John at Massawa (file 0x1CF4)

Fame >= 16000 (checked at sea day 5 and in any port) starts it. Massawa (74) tavern, church,
residence (King Tafari I, picture 3), the Saint's staff quest, a date-based wait (block 6:
next month, day >= 10), Muslim fleets (persons whose fleet is 25..29) moved to (458,548) and set
to attack (block 7); battle start/end vs those fleets (blocks 9–11); Pietro hands over the
Saint's staff (item 98) into the first free item slot, or takes item slot 19 in exchange
(block 12, 0x0BF/0x28F7). Block 13 has a hidden bonus: the Lisbon residence pays 10,000 gold
with no flag guarding it. Ends at Massawa harbor (block 14) -> `next_chapter`.

### Chapter 4 — Enrico to Japan (file 0x2BBF)

Tavern in a port <= 93 with fame >= 30000: Enrico's request; Sakai/Nagasaki `+0x13 &= 0xD0`.
Nagasaki (99) harbor: Enrico leaves the fleet, adventure fame +1000 -> `next_chapter`.

### Chapter 5 — finale (file 0x2E47)

Fame >= 40000 -> letter at the Lisbon guild; visit Enrico in Sakai (98); South America
(ports 42..56): Antonio Khan (person 60) becomes 죽음의 신 루돌프 (portrait 59), duel; Catalina;
the Spanish fleets (persons whose fleet is 15..19) and Catalina's fleet 10 are set to chase you
(block 4); Marquis Martinez's fleets (60..69) at battle start (block 6).
Attacking Catalina or the Spanish fleet when Rocco warns you (yes/no f16) is the bad end: the
hero's given name becomes 몰인정한 인간 / 형편없는 인간, the first six abilities 10, charm 50,
luck 0, and `next_chapter` runs past the last chapter (story over, no ending). Destroying Martinez -> block 7: Lisbon residence `ending 0`
(file 0x3C2C).

## 7. Open questions

1. `[0xC30]` story bits: exact meaning of 0x02 vs 0x40 (new-game option screen) and why `F4`
   keeps 0x40 for code 0x0F.
2. `F4` codes other than the hero endings (`b & 0xF0` = 0x10, 0x80, value 0x0F); END.EXE side.
3. Duel result `[0xA538]`: confirm the scale (start 100, <=40 loss, >=160 win) in 0x12846/0x12694.
4. Window geometry: the records at DS:0xBBBA hold initial values in MAIN.EXE (12 words each: window col, y,
   cols, h; portrait col, y, cols, h; text col, y, cols, h): 0 narration (30, 8, 30, 128) with a 136×112 picture
   slot at (104, 16) and text (32, 16, 26 cols, 112); 1 upper face window (13, 16, 39, 144), portrait (120, 32),
   text (24, 32, 26, 112); 2 lower face window (20, 176, 39, 144), portrait (176, 192), text (31, 192, 26, 112);
   3 picture frame (13, 16, 26, 160), picture (112, 24, 192×144). Whether code rewrites them at runtime is
   not confirmed. The speaker is the text's own first line `§name§` (frame.md §4.3); the `(을)/(를)`-style
   particle markers (0x4B6F, `[0x8BCE]`) are still open.
5. `C9` menu: value returned on cancel (0x13CA3 compares with 0xFF).
6. Building 3 is assumed to be the harbor/pier (scripts use it for departures); check 0x280A3.
   Key2 0x15 = palace audience is inferred from 0x29EDD (caller not located by the linear sweep).
7. Fleet mission fields used with `D1` (+0x0C, +0x1B modes 0/7/10, +0x1C, +0x28, +0x29 flags
   0x01/0x10/0x40/0x41, +0x2A) need the fleet AI (0x330CF, 0x33197, 0x332B9) documented.
8. Port record `+0x13` bit 0x20 (set for Sakai/Nagasaki in chapter 0, cleared with the nation
   bits in chapter 4): probably "closed to the player".
9. Person `+0x2E` role values beyond 1/2/3/4/6, and `+0x31` bit 0x20 (set on Catalina/Antonio).
10. Tables 0 (DS:0x1106 ×32) and 19 (DS:0xC0B6) are unidentified; SNR0 reads v40 without any
    script writing it (native writer not found).
11. SNR0 job chapters 1..5 and the royal commission chapters 6..12 are decoded but not yet
    described rule by rule (reward formulas use v20..v22 by rank tier v23).
12. Other heroes' files (SNR2..6) decode cleanly but are not walked through.
