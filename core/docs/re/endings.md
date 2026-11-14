# Opening (OPEN.EXE) and endings (END.EXE)

Status: both programs are mapped scene by scene. Every picture they show decodes with the existing
`gfx_codec.decode_rle4` (no leftover bytes), all texts are extracted, and `tools/endings.py` writes
the pictures, palettes, texts and scene order to `assets/opening/` and `assets/endings/`. The
ending sequence is described down to the wait lengths; the opening's special effects
(shimmer, plane-by-plane dissolves, emblem flight paths) are described at the level of
"which picture, where, roughly how long" (§9).

Addresses are load-image offsets of the EXE named in the section (as printed by
`tools/mzdis.py`). `END DS:n` = END.EXE image `0x8D70 + n`, `OPEN DS:n` = OPEN.EXE image
`0x9960 + n`, `DS:n` alone in §2 = MAIN.EXE (`0x378B0 + n`). Waits are in **ticks of the FMDRV
count-down timer 1** (INT 66h AH=F1, 60.3 Hz, docs/re/music.md §2).

```
build/venv/bin/python -I tools/endings.py      # writes assets/endings/*, assets/opening/*
```

---

## 1. Programs, packing

`PLAY.BAT` runs `FMDRV` and `VOYAGE2.COM`. VOYAGE2.COM (895 bytes) is a PKLITE-compressed crack
loader (strings "World Crack maker", "[H.B.D.I]", "koei.com") that starts **KOEI.COM**, KOEI's
own launcher (776 bytes, not packed). KOEI.COM (entry 0x392, main 0x347):

1. sets video mode 12h, hooks INT 24h (disk-error prompt, 0x2A4) and **INT 65h** (0x2E0);
2. execs `FMDRV.COM` (flag `[0x111]` so it is unloaded at exit), `OPEN.EXE`, `MAIN.EXE`;
3. if MAIN's exit code (AL) is non-zero it execs `END.EXE`; then restores INT 65h, unloads the
   driver (INT 66h AH=FF) and exits to DOS. **There is no way back from END.EXE to MAIN.EXE**.

INT 65h (KOEI.COM 0x2E0) is a tiny mailbox between the three programs:

| AH | function |
|---|---|
| 0 | returns the word at 0x1E6 (not used by OPEN/MAIN/END) |
| 1 | copy 21 bytes from CX:BX into the name buffer 0x1EC |
| 2 | return CX:BX = the name buffer |
| 3..8 | AL = 0: store BX in word slot AH-3 (0x201 + 2·(AH-3)); AL ≠ 0: return it in AX |

**OPEN.EXE and END.EXE are not packed.** Both are plain Microsoft C 6 (1990 run-time) MZ images
with 23 / 22 relocations and one code segment, so `tools/mzdis.py` disassembles them directly
(calls wrap at 64 KB: capstone prints `call 0x1xxxx` for some near calls in OPEN.EXE, read them
modulo 0x10000).

| | OPEN.EXE | END.EXE |
|---|---|---|
| size / image | 42,167 / 0xA2B7 | 52,241 / 0xCA11 |
| entry, `main` | 0x2CE6 (C start-up), 0x7EA6 | 0x668E, 0x01A8 |
| DGROUP | 0x996 (image 0x9960) | 0x8D7 (image 0x8D70) |
| song bank | segment 0x8A5 (INT 66h AH=0) | segment 0x76B (0x5A3C) |
| files | `C:OPGRAPH.LZW` | `A:ENDGRP.DAT`, `A:END_PUT.DAT`, `B:EVENT*.DAT`, `all_font.16p`, `hankaku.fnt` (drive letters patched to the current drive, 0x17A) |

Both have the same INT 66h wrappers as MAIN (play = AH 1 with song index + 1, then loop on).
The banks are copies of D2.MML songs: OPEN song 1 = **D2 song 21**, END song 1 = **D2 song 19**
('ending'), END song 2 = **D2 song 22** ('staff roll') — `assets/music/song19/21/22.m4a`.

## 2. MAIN.EXE: the end routine 0x17032

Callers: the script opcode `F4 b` (0x32B18), the palace (0x2A5E9, code 0x0F), the main loop
(0x15BCF, code `[0x426]`, then 0x16F57 restarts at the start menu) and the start-menu quit
(0x1698C, code 0x80).

```
0x17032(code):
  stop effects, close windows, print "\x1bC7\x1bB0"
  switch code & 0xF0:
   0x00 (story ending 0..5, or 0x0F):
     close all windows (0x780F while [0x572]); window + message 746 "[원작 문장 생략]…" ; wait key
     if [0xC3A] != 0xFF: [0xC3B] = 0x82
     [0xC30] &= ~0x02; if code != 0x0F: [0xC30] &= ~0x40
     0x1680C(code == 0x0F ? 3 : 2)        ; save routine on C:KOUKAI2.DAT ("post-ending data")
     0x16FA4(code)                          ; music fade, [0x426] = 0, reopen tables
     name = hero.given + " " + hero.family  ; DS:0xBEAA, hero = [0xC67A]
     if code == 0x0F: code = 0x100 | hero ([0x1241]), nation = hero +0x31 & 0xF   (else nation = 0)
     INT 65h AH=1 (name), AH=3 code, AH=4 nation, AH=5 (code << 7 | nation) ^ 0x1565
     0x2F3E (shutdown), exit(1)            -> KOEI.COM runs END.EXE
   0x10: music index 0x14 (song 17); message by code & 0xF, see table
   0x80: code 0x80: KOEI logo screen (GRAPH.DAT 60 at (216,80), 62 at (184,200)), exit(0) -> DOS
         code 0x88: nothing (returns; the main loop goes back to the start menu)
   other: return
```

The 0x1x messages are printed with the date and the hero's name into a window at (0x12·8, 0x50)
(with GRAPH.DAT 61 above it at (184,32) unless bit 15 of the message number is set):

| code | set at | message | |
|---|---|---|---|
| 0x10 | 0x15A8B (year counter `[0x56E]` > 52) | 1016 | retirement after 30 years, no picture |
| 0x18 | 0x197DF | 1014 | flagship sunk in a storm |
| 0x19 | 0x18F8D | 1015 | no crew left |
| 0x1A | 0x1067E | 1013 | fleet battle lost |
| 0x80 | 0x16987 | — | quit from the start menu |
| 0x88 | 0x20F82 | — | "[원작 문장 생략]?" confirmed |

So END.EXE only ever sees **codes 0..5** (story ending of hero = code, `ending n` at the end of
SNR{n+1}.DAT) and **0x0F** = the "duke" ending: rank 9 (duke) reached at the palace with story
mode on (`[0xC30] & 2`, town.md); this keeps story bit 0x40 (answers scenario.md open question 2).

## 3. END.EXE overview

`main` 0x1A8: read INT 65h slots 3/4/5 into `[0x3DA0]` (code), `[0x3DB6]` (nation) and check
`(code << 7 | nation) ^ 0x1565`; on a mismatch it waits for a key and exits (0x1ED). The name
(AH=2) is split at the first space into `[0x3DA8]` (given name) and `[0x3DEB]` (family name). If
the code's high byte is set (0x0F path) `[0x42]` (story ending, default 1) := 0 and the high byte
is cleared, leaving code = hero. Code 5 sets the companion-blink delay `[0x45]` = 120.
Then 0xB3A allocates buffers (16 picture buffers, sizes DS:0x62), loads the fonts and END_PUT.DAT,
0x0000 loads the hero's five EVENT pictures (§5), opens ENDGRP.DAT and runs **0x7CE**:

| order | function | scene |
|---|---|---|
| 1 | 0x14E8 | homecoming: music song 19, ENDGRP 56 frame, dialogue (story ending: function DS:0x1D8E[code]; duke: 0x1441), picture + narration |
| 2 | 0x51C, 0x4A7 | load the hero's flame / companion sprites and eye-blink sprites; music song 22 |
| 3 | 0x566, 0x598 | **diary** (only if `[0x42]`, i.e. story endings): desk, five pages of picture + text |
| 4 | 0x318..0xB09 | **staff roll**: hero portrait, six pictures, scrolling epilogue, closed book, Fin, KOEI logo |

The `sequence` array in `endings.json` lists the steps with their waits; the details:

### 3.1 Homecoming (0x14E8)
- music song 19 (END bank 1), looping; ENDGRP 56 (640x400) at (0,0); fade to palette DS:0x234.
- dialogue (§4): 0x3B8B = window at the **top** (frame (104,16) 312x144, face (120,32), text from
  (192,32)), 0x3C09 = window at the **bottom** (frame (160,176) 312x144, face (176,192), text
  (248,192)). The first
  line opens the frame with an expanding animation (0x3800); every line is typed and waits for a
  key with a blinking cursor (0xE1C: Enter, Esc, '0' or a mouse button). 0x3C87 closes both
  windows (0x3A60, shrinking).
- closing: the EVENT picture of buffer 4 (192x144) at (224,96) (Pietro: EVENT5 #5 instead) and the
  narration (`\x1bC7\x1bB0\x1bF5` + text) typed from (192,248), right margin 432, key wait.
- music fade (AH 2, 20 steps), fade to black.

### 3.2 Diary (0x566 / 0x598, story endings only)
- music song 22 (END bank 2). ENDGRP 7 (desk, open book, 640x300) at (0,30), palette DS:0x84;
  the region (208,100,272x208) is saved (4 planes) for erasing the text later.
- during every wait (0x3104) the lamp alternates ENDGRP 8 / 9 at (480,30) every 24 ticks (`[0x44]`).
- wait 900; colours 0-7 dimmed to half (0x249D); wait 300.
- page k = 0..4 (0x598): the picture box (8,100,192x144) is filled with colour 8 in 12 interleaved
  passes (1 tick each, 0x2B1E); colours 8-15 := the standard 8 colours (DS:0x294); EVENT buffer k
  is ORed in bottom-up in 12 passes (0x2B67); wait 120; colours 8-15 fade to the **sepia** colours
  of DS:0x264 (6 ticks per step, 0x250C); wait 60; the 9 text lines are typed at (208, 100 + 24j)
  in colour 15, 3 ticks per byte (0x3783 / 0x3756); then a hold of `(3·((130 − bytes) mod 256)) mod
  256` ticks (8-bit arithmetic, kept in `diary[].holdTicks`); the text area dissolves back to the
  saved desk (0x2E9B: 4 passes × 16 steps, 5 ticks each ≈ 320 ticks); wait 60. A page takes about
  20 s.
- colours 0-7 fade to black (5 ticks/step); everything but the last picture is cleared (0x318).

### 3.3 Staff roll (0x6AA..0xB09)
- buffers 0..6 are refilled with ENDGRP 0..6 (drawn at (416,0) under a black palette and grabbed,
  0x6AA), ENDGRP 54/55 (1 plane) and 53 ('Fin') are grabbed too (0x707, 0x78D), and the hero's
  second portrait frame (0x60C).
- the portrait (§5) is drawn at (256,30) (Ernesto: (336,0)); palette: colours 0-7 → portrait palette,
  colours 8-15 (last diary picture) → black, 19 ticks per step; wait 20; it then **slides left 8 px
  per tick** to x = 0 (0x379).
- colours 8-15 → DS:0x144; the box (392,50,224x160) is filled with colour 8.
- for k = 0..5 (port, market, tavern, sea battle, storm, the six heroes): ENDGRP k dissolves into
  (392,50) while colours 8-15 fade to its palette (0x2DA4: 3 planes × 16 steps; one step = 3 frames
  of 2 ticks); then 30 frames, blink, 90, blink, 90, blink, 30 frames (frame = 2 ticks).
- all the time (each 2-tick frame, 0x32B7): the **epilogue scroller** (0x2FC6) moves the text
  panels ENDGRP 54+55 (240x640, colour 7) up through the window (384,210,240x160) one line every
  3 frames (grow 160 lines from the bottom, scroll 480, shrink 160 = 2,400 frames ≈ 80 s; the six
  pictures take 2,520 frames, so the scroll ends just before them); the hero sprite (§5) steps
  every `[0x45]` = 6 frames (Al: 0x3260, his companion's blink).
- final frame: João, Catalina, Ernesto, Al: the second portrait dissolves in at x = 0; Otto and Pietro
  close their eyes (half, closed; 0x3441 / 0x3498). From here on a dissolve step is a plain 5-tick
  wait (`[0x48]` = 0). Wait 60; colours 0-7 fade to black (11/step).
- ENDGRP 6 (closed book) dissolves into (392,50), colours 8-15 → DS:0x204; wait 60; the left half
  is cleared; colours 0-7 → standard; ENDGRP 53 'Fin' (192x80) dissolves in at (424,250); wait 60;
  colours 8-15 fade out (11/step), music fade over 120 steps while 'Fin' fades.
- clear; ENDGRP 57 KOEI logo at (216,80), 58 '(c)1995 KOEI CO.,LTD.' at (184,200), fade in (DS:0x294),
  wait for a key, fade out, exit.

Length of a story ending after the homecoming: diary ≈ 20 s + 5 × 20 s, staff roll ≈ 5 + 84 s,
finale ≈ 15 s, together ≈ 3.7 minutes of song 22 (240 s loop). The duke ending skips the diary.

## 4. Dialogues and narrations (homecoming)

Extracted by walking the functions (DS:0x1D8E far pointers: 0xEF0, 0x1026, 0x107A, 0x12F9 (Ernesto),
0x11AF (Pietro), 0x13ED; duke 0x1441). `{given}` / `{family}` = name halves; particle markers
`(는)` `(를)` `(야)` `(여)` are resolved after the name exactly as in MAIN (0x1742 looks the last
syllable up in batchim tables at DS:0x1EE2 / 0x234A). Texts are in END DS:0x310..0xFC9.

| ending | lines | speakers (face ids) | narration (ends with a key wait) |
|---|---|---|---|
| 0 João | 14 | João 0, father Leon Ferrero 12, Rocco 13 (recommended as Portugal's next chancellor) | [원작 문장 생략] |
| 1 Catalina | 0 | — | [원작 문장 생략]… |
| 2 Otto | 14 | Henry VIII 15, Otto 2, Sir Gilbert 14 (appointed admiral of the royal navy) | [원작 문장 생략] |
| 3 Ernesto | 10 | Ernesto 3, Paula 16 | [원작 문장 생략] |
| 4 Pietro | 14 + picture EVENT5 #5 | Pietro 4, the duchess 18, Leon Ferrero 17, Camilo 20, Pablisson 19 | [원작 문장 생략]… |
| 5 Al | 0 | — | [원작 문장 생략] |
| 0x0F duke | 4 | ruler = face 6 + nation, hero = face of the hero | [원작 문장 생략]… 공작에 임명되었다 |

A second, unreferenced copy of all these texts sits at END DS:0xFCA..0x1C8B (64 strings, several
with "%s %s" = full name instead of the given name); nothing points to it.

Text escapes (END 0x1F35, same family as MAIN): `ESC C n` colour, `ESC B n` background, `ESC F n`,
`ESC M n`, `ESC R n` render flags, `ESC = y x` locate; bytes 0xA1..0xC8 + 0xA1..0xFE are EUC-KR
(Hangul is 16 px wide, ASCII 8 px, `all_font.16p` / `hankaku.fnt`).

## 5. Per ending: pictures, portrait, sprites

EVENT pictures (0x0000; digit table `bp-0x20`, picture table `bp-0x3E`, 5 per code). Buffer k is
diary page k; buffer 4 is also the homecoming picture.

| code | buffers 0..4 (file #picture) | portrait (ENDGRP) | palette | eyes (ENDGRP, at) | sprite |
|---|---|---|---|---|---|
| 0 João | E1#0, E1#3, E1#1, E1#4, E1#2 | 10 → 11 | DS:0xB4 | 12-14 (232,86) | — |
| 1 Catalina | E2#4, E2#0, E2#1, E2#5, E2#3 | 15 → 16 | DS:0xE4 | 17-19 (192,94) | flame 20-22 (32,182) |
| 2 Otto | E0#0, E3#1, E3#0, E3#3, E3#2 | 23 (eyes close) | DS:0x294 | 24-26 (208,78) | flame 27-29 (24,206) |
| 3 Ernesto | E4#0, E4#1, E4#4, E4#3, E4#2 | 37 → 38 (304x384) | DS:0x294 | 39-41 (80,56) | flame 42-44 (32,296) |
| 4 Pietro | E5#2, E5#1, E5#4, E5#3, E5#0 | 30 (eyes close) | DS:0x114 | 31-33 (200,150) | flame 34-36 (32,206) |
| 5 Al | E0#0, E6#1, E6#3, E6#2, E6#0 | 45 → 46 | DS:0x294 | 47-49 (144,86) | companion's eyes 50-52 (224,86) |

Positions are screen pixels after the portrait slid to x = 0 (portrait at (0,30), Ernesto (0,0)).
Eye blink (0x3320): frames half, closed, half, open, 3 frames (6 ticks) each. Flames (0x3159):
frames a, a+2, a, a+1, one step every 6 frames. Al's companion (0x3260 / 0x320C, frames 50 open,
51 half, 52 closed): half, closed, half, open 3 frames apart, then 240 frames open (first blink
after 120). The duke ending uses the
same tables with code = hero. Diary texts: END DS:0x3876 + 2·((5·code + k)·9 + j), 9 line
pointers per page (0 = empty), 169 lines in all (`endings.json` `diary`).

## 6. Pictures and palettes

| file | format | content |
|---|---|---|
| `ENDGRP.DAT` | GRAPH.DAT container (BE u32 offsets), 59 pictures, decode_rle4 | §3 / `endings.json` `pictures` |
| `END_PUT.DAT` | 21 portraits 64x80, 3 planes byte-interleaved (KAO format, 0x780 each) + 544 bytes at 0x9D80: window-frame tiles (0x9DA0..0x9E9F) and the key-wait cursor (0x9D80) | faces of §4 |
| `EVENT0..6.DAT` | GRAPH.DAT container, 192x144 | the same pictures as the scenario's `picture` opcode |

All ENDGRP pictures except 56 use only colours 0-7 (3 planes). END.EXE keeps two 8-colour
palettes on screen: colours 0-7 and 8-15. A 3-plane picture is shown in the low half (normal
put) or the high half (ORed onto colour 8, or dissolved with 0x24C8 copying the palette's first
8 colours into 8-15), so **every 3-plane picture uses the first 8 colours of the palette it is
listed with**. 12 palettes at END DS:0x84 + 0x30·k (16 × B,R,G, 0..15 like MAIN):

| DS | used for |
|---|---|
| 0x084 | desk ENDGRP 7-9 (all 16) |
| 0x0B4 / 0x0E4 / 0x114 | João / Catalina / Pietro portraits and sprites |
| 0x144, 0x174, 0x1A4, 0x1D4 | staff-roll pictures 0, 1, 4, 5 (2, 3 use 0x294) |
| 0x204 | closed book (ENDGRP 6) |
| 0x234 | homecoming frame ENDGRP 56 (all 16; colours 0-7 = MAIN's palette, used by faces and EVENT pictures) |
| 0x264 | diary sepia (colours 0-7) |
| 0x294 | standard (= MAIN 0x40ECE colours 0-7): Otto, Ernesto, Al, Fin, KOEI logo, start of every fade |

Fades step every channel by 1 per step towards the target (0x22F6; 0x23A3 = the same with 6 ticks
per step); 0x2450 fades all 16 colours, 0x24F1 / 0x250C only 8-15.

## 7. OPEN.EXE overview

`main` 0x7EA6: init 0x7E61 (video, timer, song bank AH 0, `C:OPGRAPH.LZW` opened, six picture
buffers `[0x4C..0x56]`), then 0x7D7D runs the **12 scene functions** of the far-pointer table OPEN DS:0x740 and
0x7FF5 fades the music (20 steps) and exits. Enter / Space / a mouse button during a timer wait
(0x4D17) or Esc during a plain wait (0x4DDF) abort the opening (0x4CEE: music fade, fade to black,
exit). The music (song 1 = D2 song 21) starts in scene 0 and loops until the end.

OPGRAPH.LZW is an LS11 archive of 14 GRAPH.DAT-style containers; OPEN loads them one at a time
(0x8493: `[0x4C]` current entry, `[0x50]` = entry 13 (captions) for the whole run, the next
character's entry is preloaded at the end of each scene):

| entry | pictures | used in scene |
|---|---|---|
| 0 | KOEI logo, 'KOEI PRESENTS', 'RÉKOEITION SERIES', 'AN EIJI FUKUZAWA PRODUCTION', 'from its', title mask, water texture, two kanji silhouettes, 'II', final title, 5 sparkles | 0, 1 |
| 1, 2 | fleet 640x200 ×2 frames + 320x200 ×2: one 960-px panorama (`pan_ships`) | 2 |
| 3 | 5 stars 32x32, Otto outline + picture 464x280, portrait 96x120, eyes 56x24 ×3 | 3, 10 (stars) |
| 4 | pistol still + 2 × 4 plane frames 168x168, Catalina 464x280, close-up 336x232, eyes 48x24 ×3 | 4 |
| 5 | quill 96x96 (still + 8 frames), Ernesto 464x280, portrait 120x120, eyes ×3 | 5 |
| 6 | coin 56x64 (still + 8 frames), Pietro 464x280, portrait 96x120, eyes ×3 | 6 |
| 7 | dagger 136x136 (still + 8 frames), Al 464x296, portrait 104x128, eyes ×3 | 7 |
| 8 | 5 coin frames 64x64, the three heroines 464x280, 3 × 3 eye frames | 8 |
| 9 | flame frames 72x40 ×5 and 80x48 ×5, Ezequiel and Martinez 464x280 | 9 |
| 10 | João 464x280, eyes 48x16 ×3, portrait 160x144 | 10 |
| 11, 12 | ship deck 640x200 ×2 + 256x200 ×2: an 896-px panorama (`pan_finale`) | 11 |
| 13 | ten English text pictures (prologue, eight character captions, finale) | 2-11 |

The 16-colour emblem pictures of entries 4-7 (#1, #2) are **four 1-bit animation frames each, one
per bit plane** (a pistol/quill/coin/dagger turning); the tool exports them as `opNN_MM_f0..f3`.
The captions use colour 7 for the text and colour 8 for its drop shadow (the prologue and finale
lines are colour 8 only: drawn as black on a white band while the palette is white, DS:0x336).

13 palettes at OPEN DS:0xF6 + 0x30·k: 0xF6 / 0x156 character scenes (0x156 has colour 8 = cream),
0x126 the ships, 0x186 the villains, 0x1B6 water (cycled 4 colours at a time by 0x49DC),
0x1E6 / 0x216 white flashes, 0x246 sunset (final title), 0x276 blue sparkles, 0x2A6 / 0x2D6 KOEI
logo without / with the white text, 0x306 black, 0x336 white.

## 8. Opening scenes

| # | addr | scene |
|---|---|---|
| 0 | 0x5152 | credits: KOEI logo (216,96) + 'KOEI PRESENTS' (216,224); 'AN EIJI FUKUZAWA PRODUCTION' (120,174); 'from its' (248,132) + 'RÉKOEITION SERIES' (128,188); 120 ticks each, fades 4 ticks/step |
| 1 | 0x5390 | title: water texture inside the kanji mask at (40,120) with a cycling blue palette, white flashes of the kanji silhouettes, 'II' at (528,112), sparkles, final 640x128 title at (0,120) in the sunset palette |
| 2 | 0x588D | white band (0,100)-(640,300) with the prologue caption at (32,180); the fleet at (0,100), waves (two frames), pan right 320 px (8 px every 16 ticks), fade out |
| 3-7 | 0x5B4B, 0x5FA2, 0x6433, 0x67C5, 0x6BD5 | Otto, Catalina, Ernesto, Pietro, Al: emblem animation, 464x280 picture dissolving in at (88,48), wait 120, portrait + English caption + 90 frames of eye blinks |
| 8 | 0x6FF2 | the three heroines: coins, picture, caption at (48,176), three pairs of eyes |
| 9 | 0x73D3 | Ezequiel and Martinez (palette 0x186): picture, flames, caption at (288,128) |
| 10 | 0x75F1 | João: long wait (420), picture, stars, caption at (48,64), portrait 160x144 at (304,72), eyes |
| 11 | 0x7B2C | ship deck at (0,100), waves, pan into the second picture, white band with the finale caption at (128,180), fade to black |

Exact positions per character are in `opening.json` (`scenes[].steps`). After scene 11 OPEN.EXE
ends and KOEI.COM starts MAIN.EXE, which shows its start menu (music index 3 = song 18).

## 9. Output (`tools/endings.py`)

`assets/endings/` (141 files): `endgrp_00..58.png` (each in the palette it is shown with),
`face_00..20.png`, `eventN_M.png` + `eventN_M_sepia.png` for the 30 EVENT pictures the endings use,
and `endings.json`:

- `palettes` (12, RGB), `music`, `codes` (§2), `faces`, `pictures`, `eventPictures`, `windows`;
- `endings[0..5]`: `homecoming` steps (`say` {window, face, text}, `closeWindows`, `picture`,
  `narration`), `diary` (5 pages: picture, sepia picture, lines, holdTicks), `portrait`, `eyes`,
  `sprite`; `dukeEnding` (faces 'ruler' / 'hero', picture = buffer 4 of the hero);
- `epilogue`: the two scrolled panels transcribed as 32 lines + the window;
- `sequence`: the three scenes with their waits (§3).

`assets/opening/` (137 files): `opEE_PP.png` per OPGRAPH picture (plane-frame emblems as
`_f0..f3` RGBA, captions and the title mask as RGBA), `pan_ships_0/1.png` (960x200) and
`pan_finale_0/1.png` (896x200), and `opening.json` (`palettes`, `pictures` with role/palette,
`captions` transcribed, `pans`, `scenes`).

## 10. Open questions

1. Opening effects are summarised, not reproduced: 0x273D / 0x29C6 (caption shimmer, 8 steps of
   4 ticks), 0x28BB / 0x2A77 (plane-wise emblem drawing; flight paths in tables at OPEN
   DS:0x518 / 0x5B4 / 0x626), 0x4FB3 (plane-by-plane dissolve), 0x2AB4 (masked texture), and
   whether the 464x280 picture is cleared before the portrait + caption appear (the
   `0x273D(…, 0x8080)` set-up call suggests a clear). The tool's per-scene palettes are the last
   ones set in each scene.
2. END 0x5928 (the dissolve put) and 0x2E9B are decoded only as "3 planes × 16 steps"; the exact
   pixel order of the dissolve is not traced.
3. MAIN 0x1680C(2 / 3) is the KOUKAI2.DAT save routine called before END.EXE; what modes 2 and 3
   change in the saved game is not traced (`[0xC30]` bit 0x40 survives only for the duke ending).
4. `ESC F n` / `ESC M n` / `ESC R n` text flags (END 0x1F35) — probably font size / render mode.
5. The song banks inside OPEN/END were not byte-compared with D2.MML here (music.md states they
   are copies of songs 21, 19 and 22).
6. Face 9 (ruler of England, duke ending) and face 15 (Henry VIII in Otto's ending) are different
   drawings; faces 12 and 17 are both Duke Leon Ferrero.
