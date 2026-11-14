# Sound effects — the FMDRV effect channel (대항해시대 II, Korean DOS)

Addresses are MAIN.EXE load-image offsets (file offset = addr + 0x5400); `DS:n` = image
0x378B0 + n; FMDRV.COM addresses are COM offsets (org 0x100), as in music.md. "tick" = one count
of the FMDRV countdown timer used by the game's wait 0x5958 = **60.31 Hz** (291.304 Hz × 0x35/256,
INT 08h handler 0x1FC/0x20E), "LFO tick" = 61.44 Hz (× 0x36/256).
Marks: ✅ read in full · 🔎 read, some details skipped · ❓ not decoded.

**Headline.** MAIN.EXE has exactly **8 sound effects**, all played on **one** OPL2 channel
(FMDRV effect channel 0 = OPL channel 4) through INT 66h AH 5/6/7: a 22-byte voice from a table
at DS:0xB48 (8 records, same format as the D2.MML voices) plus one note. There are no sampled
sounds, no sinking, purchase, menu-click, door, discovery or victory sounds — those moments are
silent (or only change the music). The 8 effects: cannon (volley fired / shell lands), boarding,
duel hit, duel miss, sailing level up, village treasure, sea-event alarm, storm wind (held for
the whole storm). Effects need the FM driver (`[0x420]`) and option bit `[0xC30] & 8`
(default on, no UI). A new effect cuts the previous one. Rendered by `tools/sfx.py` to
`assets/sfx/*.wav` + `index.json` (§7). OPEN.EXE and END.EXE link the same wrappers but never
call the effect ones ✅.

---------------------------------------------------------------------------------------------

## 1. MAIN.EXE sound wrappers ✅

All are far procs in segment 0 that fill a REGS block and call `int86(0x66)` 0x3574 /
`int86x` 0x35F4 (DS = the game's DS, so voice pointers are `DS:bx`). Every one returns at once
if `[0x420]` (FM driver present, set at 0x16E72 from 0x1540) is 0.

| addr | in | INT 66h | gate | callers |
|---|---|---|---|---|
| 0x95BE | bx = DS voice | AH 5, AL 0 (effect ch 0 = OPL ch 4), DS:DX = voice | `[0x420]` | 12 (§2) |
| 0x95FA | ax, bx voices | AH 5 on ch 0 (ax) and ch 1 (bx) | `[0x420]` | **none** |
| 0x965A | al = note | AH 6, AL 0, DL = note | `[0x420]` **and `[0xC30] & 8`** | 12 (§2) |
| 0x968C | al, dl notes | AH 6 on ch 0 and ch 1 | same | **none** |
| 0x96DE | – | AH 5 AL 0 null voice (mute ch 0), AH 7 AL 0, AH 7 AL 1 (key off ch 0, 1) | `[0x420]` | 11 (§2) |
| 0x5958 | ax = n | AH F1 AL 1 BX = n (timer 1), then poll AH F1 AL 0 until 0 | – | the waits below |
| 0x949C | ax = n | **PC speaker**, not FMDRV (§6) | `[0xC30] & 8` | 2 |

OPL channel 5 (effect channel 1) is never used by the game ✅. No other code writes ports
0x388/0x389; no other INT 66h call touches the effect channels (AH 80/81 are never called).

## 2. Call sites ✅

Found with `re.py calls` (near calls from segment 0, far calls from everywhere) and `re.py refs`
on the 8 voice addresses: the 12 voice loads, 12 note calls and 8 voice references match one to
one; no far pointer to the wrappers exists in DS.

### 2.1 Effects (voice + note)

| site | routine / moment | voice | note | duration in game |
|---|---|---|---|---|
| 0xC636 | 0xC583 cannonball flight, start: every volley 0xCAFB (from 0xE5CD, player and AI) when the attacker's **or** the target's cell is in view | 0xB74 | 0x24 | until cut: flight = 1 tick per pixel of the major axis (~0.53 s per cell) 🔎, then the impact re-triggers it |
| 0xCB72 | 0xCAFB volley, **target** cell in view: shell lands, before the burst / spout frames (4 × 8 ticks) | 0xB74 | 0x24 | not muted, rings out (~1.5 s) |
| 0xCFF2 | 0xCEF6 boarding animation (from 0xE6F5, every boarding exchange) | 0xB8A | 0x30 | 3 passes × 8 frames × 2 ticks = **48 ticks** (passes whose cell is out of view are skipped), then 0x96DE at 0xD0D9 |
| 0x11FF1 | 0x11E80 duel exchange, step 3, **hit** (`[bp-0x2E] ≠ 0`, 4 steps) | 0xB5E | 0x30 | not muted (2 ticks of animation left), rings out |
| 0x11FF7 | 0x11E80 duel exchange, step 3, **no hit** (6 steps) | 0xB48 | 0x30 | not muted, rings out |
| 0x1B6B0 | 0x1B5E8 sailing-level-up report (msg 1075/1076 + 1077, stat gains 1078), called from port arrival 0x1B6EE for the admiral (0x1B761) and each mate (0x1B7BD) | 0xBB6 | 0x3C | **20 ticks**, then 0x96DE at 0x1B6C8, then key wait |
| 0x34192 | 0x340FD village 보물탐색, find succeeded **and category (`+6 & 7`) = 0 (보물)**: after the find picture 0x5A51(0xA0, 0x10, 0x40), before msg 431 | 0xBA0 | 0x3C | not muted, rings out (~1.5 s). Other categories (원주민, 동물, 식물, 유적, 괴물, 자연) are silent |
| 0x30615, 0x3063A | 0x305DE sea event (sea_events.md §4), before msg 1176 | 0xBCC | 0x30 | 2 × (**30 ticks** on, 0x96DE), 20 ticks between |
| 0x1941B | 0x193F4 storm begins (0x19377: weather 1, a mate who notices it warns, msg 340–343 🔎), sound after the warning | 0xBE2 | 0x30 | **held** until muted (§2.2) |
| 0x84DE | 0x837D sea screen rebuilt (after battle 0x10D2D, start/load 0x16B50, 정보 screens 0x2065E, leaving port 0x273BE) if `[0xC3F] & 15 == 1` | 0xBE2 | 0x30 | held |
| 0x165D6 | 0x16588 after loading a game: 0x96DE (0x165C8), then the storm sound if in a storm | 0xBE2 | 0x30 | held |
| 0x20DC0 | 0x20D83 environment screen: BGM switched **on** during a storm | 0xBE2 | 0x30 | held |

The duel exchange loop (0x11F71..0x12020) waits 2 ticks per step; the sound starts with frame
step 3, together with the defender's raised stance on a hit (sprites.md §7.3).

### 2.2 Mutes (0x96DE) without a following effect

| site | moment |
|---|---|
| 0xD0D9 | end of the boarding animation |
| 0x1B6C8 | end of the level-up sound |
| 0x3062D, 0x30652 | end of each sea-event blast; 0x306B1 again after the texts |
| 0x1980E | storm over (msg 360/361 "[원작 문장 생략]"), weather cleared |
| 0x1B70E | port arrival 0x1B6EE (weather cleared: `[0xC3F] &= 0xC0`) |
| 0x29152 | 성스런 향유 used during a storm (storm ended, msg 1105/1106) |
| 0x20DDA | environment screen: BGM switched **off** (stops the storm sound too) |
| 0x165C8 | after loading a game |
| 0x17041 | game end / ending 0x17032 |

So the storm sound runs from the storm's start to one of: storm over, port arrival, holy oil,
BGM off, load, game end — or until any other effect replaces it (e.g. a battle's first volley);
0x837D restarts it when the sea screen comes back. The storm start itself does not check BGM
bit 4, so with BGM off a new storm is still heard ✅ (quirk).

### 2.3 Moments without any sound ✅
Sinking (0xC42A, 0xE36E), derelicts, battle start/end (music only), buying/selling, menus and
clicks, doors / entering buildings, discoveries and port sightings (0x3070D), level-ups of the
battle level (0xE30B → 0x1B570, silent), relics, the fog event, ship loss in fog, rats/scurvy.

## 3. Effect voices DS:0xB48–0xBF7 ✅

Eight 22-byte records in the static data of MAIN.EXE (not in the saved data DATA1[15]); format
music.md §5.2 (bytes 0-10 = OPL regs 20, 23, C0, E0, E3, 40, 43, 60, 63, 80, 83; 11 transpose;
12-21 software LFO). `python3 tools/sfx.py voices` prints them.

```
B48  af af 0c 03 00 00 00 f6 f5 11 ff  08  64 19 01 16 05 32 00 00 01 01   duel miss
B5E  ac a9 0c 03 00 00 00 f6 f5 11 ff  0c  40 1f 02 16 05 32 00 00 01 01   duel hit
B74  20 00 0e 00 00 07 00 f0 f0 08 05  e8  40 1f 02 ce 0a f1 00 00 01 01   cannon
B8A  23 21 0d 03 01 85 45 5f 53 0f 0f  00  50 46 01 64 0b 8d 00 00 00 01   boarding
BA0  01 11 0f 00 02 00 00 fa f1 f0 ff  18  58 1b 01 1a 0a 00 00 00 00 01   treasure
BB6  00 00 00 00 00 0f 08 ff 90 a0 03  0b  10 27 04 64 0f 81 00 00 02 01   level up
BCC  00 00 00 00 00 08 00 f0 f0 00 04  f5  10 27 02 9c 0f 81 00 00 02 01   sea event
BE2  0a 00 0e 02 02 07 00 70 20 00 00  00  46 00 02 32 0f 00 00 00 00 01   storm
```

Operators (mod / car): multiplier, TL, AR/DR/SL/RR, EGT, waveform; all KSL 0 except B8A (2/1),
KSR only on BA0's carrier, hardware AM only on B48/B5E (both ops, 1 dB at 3.7 Hz since reg BD = 0),
no hardware vibrato.

| voice | conn, FB | modulator | carrier | tr | key (Hz) | software LFO (all 8 enable it) |
|---|---|---|---|---|---|---|
| B48 duel miss | FM, 6 | ×15 TL0 15/6/1/1 EGT1 W3 | ×15 TL0 15/5/15/15 EGT1 W0 | +8 | 412.7 (ops 6.2 kHz) | square, 6.1 Hz, ±7 cents, no delay |
| B5E duel hit | FM, 6 | ×12 TL0 15/6/1/1 EGT1 W3 | ×9 TL0 15/5/15/15 EGT1 W0 | +12 | 520.4 (6.2 / 4.7 kHz) | triangle, 6.1 Hz, ±7 cents, no delay |
| B74 cannon | FM, 7 | ×0.5 TL7 15/0/0/8 EGT1 W0 | ×0.5 TL0 15/0/0/5 EGT0 W0 | −24 | 32.5 (ops 16 Hz) | triangle, 6.1 Hz, ±3.0 semitones, no delay |
| B8A boarding | **additive**, 6 | ×3 TL5 5/15/0/15 EGT1 W3 | ×1 TL5 5/3/0/15 EGT1 W1 | 0 | 260.2 | square, **30.7 Hz, ±6.6 semitones** (alternates every LFO tick), free running |
| BA0 treasure | **additive**, 7 | ×1 TL0 15/10/15/0 EGT0 W0 | ×1 TL0 15/1/15/15 EGT0 W2 | +24 | 2081.6 | square, 7.7 Hz, ±1.7 semitones (trill), free running |
| BB6 level up | FM, 0 | ×0.5 TL15 15/15/10/0 EGT0 W0 | ×0.5 TL8 9/0/0/3 EGT0 W0 | +11 | 981.6 (ops 491 Hz) | **one-shot ramp** up +15.5 semitones in 4 LFO ticks (65 ms), after a 5-tick delay |
| BCC sea event | FM, 0 | ×0.5 TL8 15/0/0/0 EGT0 W0 | ×0.5 TL0 15/0/0/4 EGT0 W0 | −11 | 137.7 (ops 69 Hz) | triangle (step 20000: 6-tick cycle), **10.2 Hz, ±10.9 semitones**, 5-tick delay |
| BE2 storm | FM, 7 | ×10 TL7 7/0/0/0 EGT0 W2 | ×0.5 TL0 **2**/0/0/0 EGT0 W2 | 0 | 260.2 (2.6 kHz / 130 Hz) | triangle, **15.27 s cycle (938 LFO ticks), ±9.4 semitones**, free running |

LFO numbers from bytes 12-20: speed (u16), wave, pitch depth/127 × range (B48/B5E 40 cents, B74
and BA0 7 semitones, B8A 8, BB6/BCC/BE2 18), delay (1 = none, 2 = 5 LFO ticks, 0 = free running).
Every amplitude sensitivity (bytes 18/19) is 0, so the amplitude depths (bytes 17) do nothing.

What they sound like (from the parameters, not heard ❓): FB 6/7 with a high multiplier or a
low note is OPL noise. Cannon = a 16 Hz carrier phase-modulated by a feedback-noise modulator,
full level at once, falling at RR 5 (~2.5 s for 96 dB): a noise "boom". Boarding = a harsh
30 Hz two-pitch rattle (sabres) held at full level. Duel hit/miss = metallic clangs at 4.7 /
6.2 kHz decaying in ~1.6 s. Treasure = a bright additive bell at 2 kHz with a 7.7 Hz trill,
~1.5 s. Level up = an almost pure 491 Hz sine that leaps up 15.5 semitones after 80 ms.
Sea event = a 69 Hz FM tone warbling ±11 semitones at 10 Hz (a siren). Storm = noise with a
2.6 kHz feedback modulator, 1 s fade-in, pitch swelling ±9 semitones over 15 s (wind).

## 4. How FMDRV plays an effect ✅

**AH 5 (0x3AF), DS:DX = voice, AL = 0/1** — channel struct `0x4A4 + 0x2E·(4 + AL)` (0x328);
0x6CA silences it (A0/B0 = 0 → key off, SL/RR = 0x0F, TL = 0x3F). Null DS:DX: 0x8C2 clears the
struct (voice pointer too, so the LFO stops) and writes TL 0x3F to both operators — **the mute**.
Otherwise volume `+5` = 0 (loudest, carrier TL = voice TL), flag 08 (LFO on, as `F8`) and voice
load 0xA1E (the same routine as the music's `F4`: 11 registers, transpose, LFO flags, volume).
The driver keeps the **far pointer** to MAIN.EXE's record and reads the LFO bytes from it on
every LFO tick.

**AH 6 (0x3F1), AL = channel, DL = note ≤ 0x5F** — clears flags 02/20/40 (no slide, no tie) and
runs the music note routine 0xC31 with the struct's default length/gate 0x30/0x2D (≠ 0, so a
note): note + voice transpose → block = n/12 (max 7), F-number table 0x63C,
`Hz = fnum·49716/2^(20−block)` (music.md §5.1); key off if sounding, write A0/B0, key on, LFO
restart.

**AH 7 (0x40C)** — key off (0x6AE).

**Duration and release.** The sequencer tick 0xCD8 only walks the 4 music structs and the
rhythm struct, so an effect note has **no length or gate**: it sounds until (a) the game mutes
it (0x96DE: key off + TL 63 + RR 15 → silent within ~2 ms), (b) the next effect reloads the
voice (same instant cut), or (c) its own envelope decays (EGT 0 / SL 15 voices). The software
LFO tick 0x120E walks all **6** channels (0x1274, `cx = 6`), so effect voices get their pitch
LFO exactly as music voices do. The fade (AH 2) and the volume refresh in it touch only
channels 0-3, so music fades do not affect effects; the effect channel is mixed on top of
the 4 music channels at full volume.

The game's waits are FMDRV countdown timer 1 (AH F1): decremented when `[0x123] += 0x35`
carries, i.e. 60.31 Hz; 30 ticks = 0.497 s, 20 = 0.332 s, 48 = 0.796 s.

## 5. The option bit ✅

`[0xC30] & 8` = sound effects. Read only by 0x965A, 0x968C (FM notes) and 0x949C (PC speaker).
Set by the new-game initialisation `[0xC30] = 0xFF` (0x15A44), stored in the save game, and
**never changed** by any code (the environment screen toggles bits 1, 4, 0x80 only;
newgame.md §7.1). So effects are always on in practice. With the bit clear the voices are
still loaded (0x95BE/0x96DE do not test it) but no note is keyed: silence.

## 6. PC speaker beep 🔎 (not rendered)

0x949C(n): if `[0xC30] & 8`, 0x16A0(1) sets port 0x61 bits 0-1 (speaker on), wait n ticks
(0x5958), 0x16A0(0) speaker off. The game never programs PIT channel 2, so the pitch is whatever
the BIOS left there (usually its 896 Hz beep divisor 0x533) ❓. Callers: 0x494A, the text
printer's control-character handler 0x4936 for **BEL (7)**: 3 ticks — no BEL occurs in
MESSAGE.DAT, MENU.DAT (their 0x07 bytes are layout header bytes), ITEM.MES or the scenario texts;
and 0x15B0E at start-up: when the check 0x354EE fails (3 tries; probably the manual-word copy
protection), clear screen, beep 3 ticks, wait 50, exit. Neither happens in normal play.

## 7. Rendering — `tools/sfx.py` ✅

```
python3 -I tools/sfx.py voices          # §3 table from MAIN.EXE
python3 -I tools/sfx.py list            # effects, scripts, call sites
python3 -I tools/sfx.py check           # render in memory + sanity numbers, exit 1 on a problem
python3 -I tools/sfx.py render [NAME…]  # assets/sfx/<name>.wav + index.json (numpy, scipy)
```

- Each effect is a script of the game's own calls (voice / note / wait n ticks / mute, or
  "ring" = left keyed on, "loop" = held). `FxDriver` subclasses `mml.Driver` with one struct
  (OPL ch 4, slots 9/12) and replays the INT 08h handler: 291.3 Hz interrupts, LFO ticks on the
  0x36 accumulator, the countdown on the 0x35 accumulator; AH 5/6/7 as in §4. Register writes
  are therefore exact: the driver's own voice, note and LFO code from tools/mml.py.
- `FxSynth` subclasses `mml.Synth` and renders at the chip rate 49716 Hz, then resamples to
  44.1 kHz (polyphase 1225/1381). Two differences from the music renderer:
  1. the FB operator is iterated per sample (`phase += (y[n−1] + y[n−2])·2^(FB−7)` cycles) so
     FB 6/7 gives the chaotic noise of the chip instead of the steady-state table's buzz;
  2. DR 0 + SL 0 + EGT 0: the chip leaves the decay phase at once (attenuation = SL) and then
     falls at RR while the key is held (Nuked-OPL3 behaviour); mml.Synth holds full level.
     This matters for B74, BB6, BCC.
- Gain = the music bank's gain (`assets/music/index.json` 0.516491) and the same soft knee,
  so effects and songs keep the original FM mix level against each other.
- "ring" effects end where they have decayed to −60 dB of their peak (20 ms fade); muted
  effects end 50 ms after the mute; the storm is rendered as the 1.2 s attack + one LFO cycle
  (938 LFO ticks = 15.266 s), whose last 80 ms are crossfaded (equal power) into the 80 ms
  before the loop start, so `[loopStart, loopEnd)` loops seamlessly; `storm_loop.wav` is that
  body alone.

Sanity check (`check`, 2026-11-04): all non-silent, no DC, no clipping, no NaN.

| file | length | peak / RMS dBFS | notes |
|---|---|---|---|
| cannon.wav | 1.557 s | −1.8 / −21.0 | noise burst; key 32.5 Hz, LFO ±3 st visible in the A0/B0 log |
| boarding.wav | 0.845 s | −8.8 / −20.9 | 118 ms attack, flat, cut at 0.796 s |
| duel_hit.wav | 1.024 s | −3.8 / −21.2 | −60 dB at ~1.0 s |
| duel_miss.wav | 1.045 s | −3.6 / −21.0 | |
| level_up.wav | 0.381 s | −11.7 / −17.6 | pitch 982 → 2391 Hz (key) between 0.096 and 0.15 s, cut at 0.332 s |
| treasure.wav | 1.489 s | −1.0 / −25.7 | trill 1887 / 2288 Hz every 65 ms |
| sea_event.wav | 1.377 s | −5.2 / −14.4 | 0.497 s on, 0.332 s gap (−90 dB), 0.497 s on |
| storm.wav | 16.467 s, loop 1.2015–16.4673 s | −6.0 / −16.8 | fade-in (carrier AR 2) within 2 dB of full after ~0.6 s; loop seam step 0.05 vs median sample step 0.14 |
| storm_loop.wav | 15.266 s | | loop body only |

`index.json`: `sampleRate`, `gain`, and per effect `name`, `file`, `moment`, `voice`, `note`,
`pitchHz` (key frequency), `script`, `sites` (address + routine), `remark`, `duration`,
`loopStart`/`loopEnd` (storm; null otherwise) and `loopFile` (storm).

## 8. For the remaster

One effect player with a **single voice**: starting an effect stops the one playing; "mute"
stops it at once. Play at the same volume as the music player (the files share the music's
gain). Respect a sound-effect option (the original's is always on).

- [ ] Naval battle, each volley (attacker or target visible): `cannon.wav` when the cannonball
      leaves; when it lands on a visible target, `cannon.wav` again (restart) with the burst /
      spout. No sound for sinking or for derelicts.
- [ ] Boarding exchange: `boarding.wav` from the start of the sabre animation; stop it when the
      animation ends (0.8 s for 3 visible passes).
- [ ] Duel exchange, when animation step 3 is shown (3 × 2 ticks ≈ 0.1 s after the exchange
      starts; on a hit together with the defender's raised pose): `duel_hit.wav` if the
      exchange hits, else `duel_miss.wav`; let it ring.
- [ ] Port arrival, each sailing-level-up report (admiral, then each mate): after the stat lines,
      `level_up.wav` (0.33 s, then cut), then wait for a key.
- [ ] Village 보물탐색 success with a treasure (category 0) only: `treasure.wav` with the find
      picture; let it ring.
- [ ] Sea event: `sea_event.wav` (both blasts, 1.33 s) before "제독님, 큰일났습니다！！" (msg
      1176); replaces sea_events.md §7's alarm item.
- [ ] Storm: start `storm.wav` (or `storm_loop.wav` with a 1 s fade-in) when the storm begins
      and loop `[loopStart, loopEnd)`; stop on storm end, port arrival, holy oil, game end, load
      (restart if the loaded game is in a storm), BGM turned off (restart when turned on during
      a storm); a battle's effects replace it, and it restarts when the sea screen returns
      after battle / info screens.
- [ ] Silent moments (§2.3) stay silent.

## 9. Open questions

1. Real-chip sound: the files come from a model, not a recording. The FB noise is a float
   iteration, not the chip's log-sin/exp integer pipeline; envelope curves, hardware AM and the
   sound card's output filter are approximations (music.md §8). A capture from DOSBox (OPL2,
   `nuked` core) of a battle, a storm and a sea event would settle the timbre.
2. The music renderer (`tools/mml.py`) shares two approximations fixed here: voices 0x108,
   0x134, 0x14A of D2.MML have carriers with DR 0 / SL 0 / EGT 0 / RR 5-9, which the chip lets
   decay while held but `mml.Synth` holds at full level; and its FB 6/7 operators use the
   steady-state table. Porting `FxSynth.envelope` / `feedback_op` into mml.py and re-rendering
   the songs would make them consistent.
3. Cannonball flight time (0xC583: 1 tick per pixel of the major axis, constants 0xE100,
   0x7080, 0x258) decides when the second boom cuts the first; not measured per distance 🔎.
4. The PC-speaker pitch (§6) and what 0x354EE checks.
