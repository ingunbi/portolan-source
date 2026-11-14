# Music: D2.MML and the FM driver (FMDRV.COM)

Status: the song format and the driver are fully decoded. `tools/mml.py check` decodes all
22 songs (4 channels each, song 16 has 3) with no desync: every channel stream ends on `FF`
exactly where the next stream starts, all 41 voice records are referenced, every channel of a
song reaches its `FF` on the same tick, and the second pass replays the loop body note for note.
`tools/mml.py render` re-implements the driver tick for tick, turns the resulting OPL2 register
log into audio and writes `assets/music/songNN.m4a` + `index.json`.

Driver addresses are FMDRV.COM offsets (org 0x100; file offset = address - 0x100).
MAIN.EXE addresses are load-image offsets, `DS:n` = image `0x378B0 + n` (as in RE_NOTES.md).

```
build/venv/bin/python tools/mml.py list 1      # bytecode listing of song 1 (no numpy needed)
build/venv/bin/python tools/mml.py voices      # the 41 voice records
build/venv/bin/python tools/mml.py check       # self-check, exit 1 on any problem
python3 tools/mml.py render [N ...]            # needs numpy (+ scipy optional), macOS afconvert
```

---

## 1. Hardware: AdLib / OPL2 (YM3812)

The driver identifies itself as `OPL-II Sound Driver Version 3.12, (C) 1991-93 KOEI`
(signature `SOUND-DRIVER-AD-LIB OPLDRV` at 0x14BE). It only touches ports **0x388/0x389**:

- detection 0x1393: the classic AdLib timer test (reg 4 = 0x60/0x80, reg 2 = 0xFF, reg 4 =
  0x21, status bits 0xE0 must go 0x00 -> 0xC0);
- register write 0x674: index to 0x388, 4 status reads, data to 0x389, 23 status reads (the
  3.3 / 23 us OPL2 delays);
- init 0x12CF: reg 0x01 = 0x20 (waveform select enabled), reg 0x08 = 0x40 (NTS = 1),
  reg 0xBD = 0.

No OPL3 register (0x105, port 0x38A) is ever used: 2-operator OPL2, 9 channels, waveforms 0-3.
Music uses OPL channels 0-3; channels 4-5 are two sound-effect channels; channels 6-8 are the
rhythm section (rhythm mode), which D2.MML never uses.

## 2. Driver entry points

`PLAY.BAT` runs `FMDRV` before the game. `FMDRV` with no argument installs: exit code 0;
1 = no OPL found (it still stays resident as a small stub whose calls return AX = 0xFFFF);
3 = already installed; 4 = the older KOEI `SOUND-DRIVER-AD-LIB` driver sits on INT 65h;
5 = bad argument. `FMDRV OFF` uninstalls: 0; 2 = not installed; 4 = other version; 6 = cannot
free the memory.

Installation (0x1425):

| address | what |
|---|---|
| 0x100 | overwritten with `"OPLDRV\0" "1"` - the signature checked 8 bytes before the INT 66h vector |
| 0x108 | **INT 66h** handler (`jmp 0x13E`) |
| 0x10A | far-call API entry (`call 0x26F; retf`) - same API as INT 66h, AX = 0xFFFF without a card |
| 0x10E | far-call uninstall |
| 0x1DE | INT 08h handler; PIT channel 0 reprogrammed to divisor 0x1000 = **291.304 Hz**; the BIOS handler is chained every 16th tick (18.2 Hz) |

Each timer interrupt adds the tempo increment `[0x118]` to the 16-bit accumulator `[0x11A]`
(carry = one sequencer tick, pending count `[0x11C]`) and 0x36 to the 8-bit `[0x120]` (carry
= one LFO tick, `[0x11E]`, **61.44 Hz**). After EOI it processes the pending ticks (0x8ED, on
its own stack): sequencer tick 0xCD8 first, then LFO tick 0x120E.

### INT 66h API (dispatcher 0x13E, then 0x26F with tables 0x253 / 0x267)

Results are written into the caller's saved registers.

| AH | in | function |
|---|---|---|
| 00 | DS:DX song bank | 0x33C: stop, remember the bank. MAIN.EXE: 0x1540 (`D2.MML`), OPEN.EXE / END.EXE: their own banks |
| 01 | AL song (1-based) | 0x36E: stop, start song AL (0x2B0). Returns AL = song, AH = loop flag |
| 02 | AL | 0x384: AL = 0 stop now; AL = n fade out in n steps of 4 LFO ticks (volume curve `255·k²/n²`), then stop and start the queued song |
| 03 | - | BX = tick counter `[0x5EA]` (reset at every loop), AL = current song (0 = silent), AH = loop flag |
| 04 | AL | loop flag `[0x5F2]`: at `FF` a channel jumps back to its loop point only if set |
| 05 | AL = 0/1, DS:DX voice | sound-effect channel (OPL ch 4/5): load a 22-byte voice (null = mute) |
| 06 | AL, DL note | sound-effect key on (note 0..0x5F, same pitch formula) |
| 07 | AL | sound-effect key off |
| 08 | AL song, DL loop | queue the song to start when the current one ends |
| 09 | DS:DX far proc | end-of-song callback (returns the previous one); called with AL queued, AH current, BL/BH loop flags; returns AL = song to start, BL loop, CH/CL new queue |
| 80 | AL ch 0-5 / 6 rhythm, DL | extra attenuation per channel (`+0x2C`), bit 7 = mute |
| 81 | AL ch 0-5, DL | extra transpose per channel (`+0x2D`, signed semitones) |
| 82 | DS:DX | load a 39-byte rhythm voice set (null = rhythm reset) |
| 83 | AL mask, DL volume | play rhythm drums (mask as in §5.3; AL bit 7 = keep volumes) |
| F0/F1 | AL = 0 / else, BX | read / set count-down timer 0/1 (decremented at 60.3 Hz). MAIN.EXE 0x1678..0x169F |
| FE | - | AH = 0xFF if a card is present, AL = `'1'` |
| FF | - | uninstall (restore INT 08h / 66h, PIT back to 18.2 Hz) |

### Driver data (CS = DS)

| address | content |
|---|---|
| 0x118 / 0x11A | tempo increment `T·18000/100` / accumulator (reset by every tempo change) |
| 0x128 | 0xFF = OPL present |
| 0x49C | far pointer to the song bank |
| 0x4A4 + 0x2E·n | channel struct n: 0-3 music (OPL ch 0-3), 4-5 effects; 0x5B8 rhythm |
| 0x5E6 | free-running LFO-tick counter (LFO phase for delay 0) |
| 0x5E8 | random seed (0x037D), `seed = seed·0x383 mod 0x7FFF` |
| 0x5EA | sequencer ticks since start / last loop (API 03) |
| 0x5EC | tempo |
| 0x5EE..0x5F1 | fade length, sub-counter, step, extra attenuation |
| 0x5F2 / 0x5F3 | loop flag / current song |
| 0x5F4 / 0x5F5 | queued loop flag / song |
| 0x5F6..0x5FF | rhythm: base TL of BD, HH, SD, TT, CY / per-drum volume offsets |
| 0x600 | shadow of reg 0xBD |
| 0x602 | 13 words `(2^(n/12) - 1)·0x7FFF`, n = 0..12 (slides) |
| 0x61C | 16 words LFO pitch ranges: 4, 6, 10, 14, 20, 40 cents, 1, 2, 4, 5, 7, 8, 9, 12, 14, 18 semitones |
| 0x63C | F-numbers C..B: 157 16B 181 198 1B0 1CA 1E5 202 220 241 263 287 (hex) |

Channel struct (0x2E bytes; `+0..+0x25` cleared at song start by 0x8C2):

| off | content |
|---|---|
| +0 / +2 | stream pointer (0 = finished) / loop pointer (channel start until an `FE`) |
| +4 | flags: 01 nothing read yet (no loop), 02 slide armed, 04 voice has LFO, 08 LFO on (`F8`), 20 tie, 40 keyed since voice load, 80 key on |
| +5 | volume (attenuation 0..127) |
| +6 | last note (0xFF none) |
| +7 / +8 | current length / gate (defaults 0x30 / 0x2D) |
| +9 / +A | ticks left / gate ticks left |
| +B / +C / +E | repeat counter / repeat start / repeat exit |
| +10 | current F-number + block (`block<<10 | fnum`) |
| +12 / +14 | TL per operator after volume / LFO amplitude reduction per operator |
| +16 | far pointer to the voice record |
| +1A | voice transpose |
| +1B | LFO flags: bits 0-1 state (0 idle, 1 delay, 2 run, 3 restart), 04 slide down, 40 slide running, 80 LFO active |
| +1C / +1E / +20 / +22 / +24 | LFO or slide: speed, depth, counter, direction, value |
| +26 / +27 | OPL channel / operator slot (0, 1, 2, 8, 9, 10) |
| +28 / +29 | shadow KSL/TL regs, +2A/+2B shadow A0/B0 |
| +2C / +2D | API 80 attenuation / API 81 transpose |

## 3. Timing

- Sequencer ticks per second = `291.304 · (T·180) / 65536 = 0.80009 · T`.
- Note lengths use **48 ticks per quarter note** (0x30 quarter, 0x18 eighth, 0xC0 whole), so
  **T is the tempo in BPM**. The driver starts every song at T = 120 (0x2B0) until the first
  `F2`.
- `F1 n` is an alternative (OPN timer-B style) tempo: `T = 78125 / (18·(256 - n))`, low byte.
- `F6 s n` converts n sequencer ticks to LFO ticks: `n·1250 / (16·T)`.

## 4. D2.MML layout (27,866 bytes)

| range | content |
|---|---|
| 0x0000-0x00DB | song table: 22 entries × 10 bytes = 5 × u16le: channels 0-3, rhythm (0 = none) |
| 0x00DC-0x0461 | 41 voice records × 22 bytes (shared by all songs) |
| 0x0462-0x6CD9 | channel streams, song by song, channel by channel, each ending with `FF` |

Table pointers are **relative to the start of their own 10-byte entry** (0x2B0:
`ptr = entry + word`, 0 = channel unused). The driver has no song count: song n reads entry
n-1. All 22 rhythm pointers are 0; song 16 has no channel 3.

Voice pointers (`F4`) are relative to the address of the `F4` opcode itself
(`(opcode address + word) & 0xFFFF`, i.e. negative words point back into the voice table).

## 5. Bytecode

### 5.1 Melodic channels (parser 0xBF1, jump table 0xBA3)

The parser runs when the channel's tick counter reaches 0 and executes commands until it
reaches a note or rest, which sets the counters for the following ticks.

| bytes | args | meaning (handler) | uses in D2.MML |
|---|---|---|---|
| `00`-`5F` | len, gate | note n with new length and gate (0xC23 -> 0xC31). gate = 0: **rest** | 6229 notes, 1001 rests |
| `60`-`BF` | - | note n-0x60 with the current length/gate (rest if the gate is 0) | 2144 notes, 224 rests |
| `C0`-`CF` | - | ignored | - |
| `D0` | - | repeat start (only if no repeat is open) | 8 |
| `D1`-`DF` | - | repeat end: play the section **(n & 15) + 1 times**; one level only (0x951) | 8 |
| `E0`-`ED` | 1 | ignored | - |
| `EE` x | 1 | reg 0xBD bit 7 (AM depth 4.8 dB) = x & 1 | - |
| `EF` x | 1 | reg 0xBD bit 6 (vibrato depth 14 cents) = x & 1 | - |
| `F0` v | 1 | volume = attenuation v & 0x7F (0 loudest) (0x982) | 607 |
| `F1` n | 1 | tempo, timer-B form (§3) | - |
| `F2` t | 1 | tempo t (BPM) | 46 |
| `F3` | 1 | ignored | - |
| `F4` w | 2 | voice at opcode address + w (0xA17) | 235 |
| `F5` | 2 | ignored | - |
| `F6` s n | 2 | slide the next note by s semitones (signed, \|s\| ≤ 12) over n sequencer ticks | - |
| `F7` s n | 2 | same, over n+1 LFO ticks (`speed = 0x8000/(n+1)`) | 151 |
| `F8` | - | LFO on (takes effect if the voice has its LFO enabled) | 87 |
| `F9` | - | LFO off, restore pitch and volume | - |
| `FA`-`FC` | - | ignored | - |
| `FD` | - | break: on the last pass of a repeat jump past its `Dn` | - |
| `FE` | - | loop point | 32 |
| `FF` | - | end: key off; if the loop flag is set (and something was read) reset length/gate to 0x30/0x2D, clear the repeat and jump to the loop point (channel start without `FE`); else the channel stops | 87 |

The ignored opcodes are presumably commands of KOEI's OPN (PC-98) driver that share the
compiler (detune, panning, ...). D2.MML only uses notes, rests, `Dn`, `F0 F2 F4 F7 F8 FE FF`.

**Note** (0xC31), n = byte + voice transpose (`+0x0B` of the voice) + API 81 transpose:
block = n / 12 (clamped to 7), F-number = table 0x63C[n mod 12];
`Hz = fnum · 49716 / 2^(20 - block)`. n = 48 is C4 (260.2 Hz): **n ≈ MIDI n + 12**, every
pitch 9-11 cents flat of A = 440.

- Length L = ticks until the next event; the key goes off after *gate* G ticks if G < L.
  G = L: the next note retriggers. **G > L sets the tie flag**: the next note does not
  retrigger; the same note just continues, a different note changes the F-number only (legato).
  A length byte of 0 counts as 256.
- Not tied: key off (if on), write A0/B0, key on (B0 bit 5), restart the voice LFO.
- A rest key-offs a sounding note.

**Volume** (0x989): `a = min(127, vol + API80) / 2`; carrier TL = `min(63, voiceTL + a)`;
the modulator TL gets the same only for additive voices (C0 bit 0). KSL bits are kept.

**Voice change** (`F4`, 0xA17) silences the channel first (A0/B0 = 0, SL/RR = 0x0F, TL = 0x3F),
then writes the 11 registers, sets the transpose and LFO flags and re-applies the volume.

**Slides** (`F6`/`F7`, 0xA84/0xA79) arm flag 02; the next note (or tied continuation) starts
at its own pitch and moves to ±s semitones: per LFO tick `progress += speed` (max 0x7FFF),
`fnum' = fnum·(1 + p·r)` up or `fnum / (1 + p·r)` down with `r = table0x602[s] / 0x7FFF`
(0x10A5, renormalising block/F-number). At the end the new pitch becomes the note's pitch.
D2.MML uses them as grace notes / turns (±1, ±2 semitones over 5-15 LFO ticks).

### 5.2 Voice record (22 bytes) -> OPL registers (0x75A)

`op` = operator slot of the channel, `ch` = channel.

| byte | register | | byte | meaning |
|---|---|---|---|---|
| 0 | 0x20+op modulator AM/VIB/EGT/KSR/MULT | | 11 | transpose (signed semitones) |
| 1 | 0x23+op carrier AM/VIB/EGT/KSR/MULT | | 12-13 | LFO speed (u16le, per LFO tick) |
| 2 | 0xC0+ch feedback / connection | | 14 | LFO wave: 0 saw, 1 square, 2 triangle, 3 sample & hold, 4 one-shot ramp |
| 3 | 0xE0+op modulator waveform | | 15 | pitch depth (signed, /127) |
| 4 | 0xE3+op carrier waveform | | 16 | pitch range: index into table 0x61C (low nibble) |
| 5 | 0x40+op modulator KSL/TL | | 17 | amplitude depth (signed, /127) |
| 6 | 0x43+op carrier KSL/TL | | 18-19 | amplitude sensitivity of modulator / carrier (0..15) |
| 7 | 0x60+op modulator AR/DR | | 20 | delay: 0 free running (phase from 0x5E6), 1 none, n: (n-1)·4+1 LFO ticks after key on |
| 8 | 0x63+op carrier AR/DR | | 21 | LFO enable |
| 9 | 0x80+op modulator SL/RR | | | |
| 10 | 0x83+op carrier SL/RR | | | |

Software LFO (0x1178, 61.44 Hz), only when the voice enables it and the channel ran `F8`;
reloads speed/range while the key is on and restarts on every key on:
`v` = wave value (±0x7FFF); pitch: `fnum · (1 + |v|·d·r)^±1` with d = byte 15/127,
r = range/0x7FFF (0x1098); amplitude: per operator
`level' = level - level·m/127` (level = 63 - TL), `m = u·|byte17|·sens/15`,
u = unsigned wave value (0x110D). 22 of the 41 voices enable the LFO (mostly triangle
vibrato of 5-20 cents, a few saw / square / one-shot pitch drops for drums); every amplitude
sensitivity in D2.MML is 0.

OPL features used by the 41 voices: 35 use feedback, 28 waveforms 1-3, 4 are additive;
of the 82 operators 41 have EGT = 0 (the envelope keeps decaying at the release rate while the
key is held), 28 KSR, 25 KSL, one the hardware vibrato bit, none the tremolo bit.

### 5.3 Rhythm channel (unused by D2.MML, parser 0xF33, table 0xEF4)

| bytes | meaning |
|---|---|
| `00`-`7F` | hit: bits 0-4 = HH 01, CY 02, TT 04, SD 08, BD 10 (0 = rest); bit 5: a length byte follows; bit 6: a volume byte follows (per-drum volume of the drums in the mask). Length default 0x30 |
| `80`-`9F` v | per-drum volume for the drums in bits 0-4 |
| `A0`-`CF`, `F7`-`FC` | ignored |
| `D0`-`DF` | repeat, as above |
| `E0`-`EF`, `F1`, `F3` | ignored, 1 byte |
| `F5`, `F6` | ignored, 2 bytes (`F6` is not a slide here) |
| `F0` v | master volume |
| `F2` t | tempo |
| `F4` w | rhythm voice set: `A6 B6`, 11 regs for ch 6 (BD), `A7 B7`, 11 regs for ch 7 (HH = modulator, SD = carrier), `A8 B8`, 11 regs for ch 8 (TT, CY) - 39 bytes |
| `FD` `FE` `FF` | break, loop point, end |

Drum TL = base TL of the drum (from the voice set) + master/2 + per-drum/2, key via reg 0xBD.

## 6. Songs and scenes

MAIN.EXE loads `C:D2.MML` (DS:0xAD0) into a 0x6D60-byte buffer and hands it to the driver
(0x16E3D -> 0x1540, AH = 0; `[DS:0x420]` = driver present). Music is played through
**0x94C6 (AL = game index)**: needs option bit `[DS:0xC30] & 4`, index ≤ 0x17; the same index
again does nothing; otherwise it fades the current song (AH 2, AL 0x14), waits until it has
stopped (AH 3), starts `DS:0x9608[index]` (AH 1) and turns looping on (AH 4, AL 1).
Helpers: 0x9541 loop flag, 0x9568 fade, 0x958F playing?, 0x95BE/0x95FA/0x96DE effect voices
(AH 5), 0x965A/0x968C effect notes (AH 6, option bit 8).
The scenario opcode `CA b` (`bgm b`, 0x3158A) calls 0x94C6(b) and turns looping off for b = 0x15.

| index | song | where | scene |
|---|---|---|---|
| 0x00 | 21 | OPEN.EXE (has its own copy, its song 1) | opening / title |
| 0x01 | 19 | END.EXE (own copy) | ending |
| 0x02 | 22 | END.EXE (own copy) | ending, staff roll (240 s) |
| 0x03 | 18 | 0x16ADC in 0x16ACC (MAIN.EXE start-up, before the main loop 0x15AF7, and the restart after an ending); scripts `bgm 3` (20×) | game start, story events |
| 0x04-0x09 | 2, 3, 4, 7, 6, 5 | 0x846E: `hero + 4` on leaving port | at sea, per hero (João, Catalina, Otto, Ernst, Pietro, Al); scripts use them as character themes |
| 0x0A-0x0E | 11, 9, 8, 10, 1 | 0x1ADE2: `10 + {0,0,0,1,2,1,1,1,1,2,3,4,4}[trade zone]` | port: Europe (zones 0-2); Africa + New World (3, 5-8); Ottoman / Arabia (4, 9); India (10); SE + East Asia (11, 12) |
| 0x0F | 13 | 0x1ADE2, port number ≥ 100 | supply port |
| 0x10 | 14 | 0xF9F9 | naval battle |
| 0x11 | 15 | 0x10471 battle result 0/4/6 (enemy flagship sunk or surrendered) | victory |
| 0x12 | 16 | 0x1B16C building 5 | palace |
| 0x13 | 20 | 0x1B16C building 1; scripts `bgm 19` (32×, back to the tavern after an event) | tavern |
| 0x14 | 17 | 0x1062C battle result 5/7, 0x171B8 (0x17032 code 0x1x: lost battle, storm, no crew, retirement) | game over |
| 0x15 | 12 | 0x1040D right before song 15, looping off | victory fanfare (2.8 s) |
| 0x16, 0x17 | - | table entries 0 | - |

OPEN.EXE and END.EXE have the same INT 66h wrappers (play = song index + 1, then loop on);
their banks are embedded copies of D2 songs 21 and 19 + 22 (identical channel data).

## 7. Rendered files (`assets/music`)

The files are rendered with `python3 -I tools/mml.py render --chip`, which uses `tools/sfx.py`'s
chip-accurate operator (per-sample self-feedback, so FB 6–7 voices sound as noise; the DR 0 / SL 0 /
EGT 0 envelope falls while held, as voices 0x108, 0x134 and 0x14A do on the chip; docs/re/sfx.md).
Without `--chip` the older vectorised model is used.

`tools/mml.py render` emulates the driver at the 291.3 Hz interrupt rate (tempo accumulator,
61.44 Hz LFO ticks, every register write) and renders the register log with a 2-operator FM
model in numpy (44.1 kHz mono):

- frequencies from fnum/block exactly as above, phase reset at key on, ×0.5..15 multipliers;
- envelopes in dB: exponential attack, linear decay to SL, EGT = 0 continues at RR, release
  at RR; OPL2 rate tables with KSR (NTS = 1); TL 0.75 dB; KSL 1.5/3/6 dB per octave;
- modulator -> carrier phase modulation of up to 4 cycles at full level (as in the chip),
  feedback from precomputed steady-state tables of the self-modulating operator
  (`(y[n-1] + y[n-2])·2^(FB-7)` cycles), waveforms 0-3, hardware AM/VIB bits approximated;
- 1 ms / 3 ms ramps where the chip clicks (key-on phase reset, cut of a sounding note),
  12 Hz DC block, one gain for the whole bank (stored in `index.json`, soft knee above 0.7).

Each file is the song up to the end of its first pass (`loopEnd`, where every channel hits
`FF`) followed by 8 s of the second pass fading out; song 12 is rendered once with a 3 s tail.
`index.json` lists per song: `number`, `file`, `duration`, `loopStart` / `loopEnd` (seconds;
play `[0, loopEnd)`, then loop `[loopStart, loopEnd)`; null for song 12), `channels`,
`tempo` (sequence of tempos), `gameIndex` (MAIN.EXE index, table above) and `scene`.
22 files, 20 MB AAC 128 kbit/s.

## 8. Open questions

- The ignored opcodes (`C0`-`CF`, `E0`-`ED`, `F3`, `F5`, `FA`-`FC`) and the PC-98 meaning of
  them; none occurs in D2.MML. `F1`, `F6`, `F9`, `FD`, `EE`, `EF` and the rhythm channel are
  implemented by the driver but also unused, so the emulation of those paths is untested.
- The renderer is not bit-exact: the OPL attack curve, feedback (the chip turns FB 6-7 into
  noise, the tables give a buzzy periodic wave), aliasing and the hardware LFO phases are
  approximations. Timing, pitches, gates, legato, slides and the software LFO follow the driver.
- Looping in the app: jumping from `loopEnd` back to `loopStart` cuts the release tails of the
  last notes (a short crossfade hides it); the tick grid makes the second pass up to 3 ms off
  sample-exact, which is inaudible.
- Effect voices for API 05/06 live in MAIN.EXE (DS:0xB48, 8 records): decoded, with every call
  site, in sfx.md and rendered by `tools/sfx.py`. sfx.md §9 lists two renderer approximations
  (DR 0 / SL 0 / EGT 0 envelopes, FB 6-7 noise) that also apply to the songs.
- RE_NOTES.md §사운드 still says "미분석"; it can point here.
