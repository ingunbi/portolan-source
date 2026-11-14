#!/usr/bin/env python3
"""Opening (OPEN.EXE + OPGRAPH.LZW) and endings (END.EXE + ENDGRP.DAT, END_PUT.DAT, EVENT*.DAT).

Exports every picture the two programs show as PNG and the texts + scene order as JSON:

    assets/opening/*.png, assets/opening/opening.json
    assets/endings/*.png, assets/endings/endings.json

usage: build/venv/bin/python -I tools/endings.py [game_dir] [assets_dir]

Neither EXE is packed (plain Microsoft C 6 MZ images, 23 / 22 relocations); addresses below are
load-image offsets as printed by tools/mzdis.py. docs/re/endings.md explains the programs.
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/original/GAME"
OUT = sys.argv[2] if len(sys.argv) > 2 else ROOT + "/assets"

END_DS = 0x8D70    # DGROUP 0x8D7 (C start-up 0x669B `mov di, 0x8D7`)
OPEN_DS = 0x9960   # DGROUP 0x996 (C start-up 0x2CF3 `mov di, 0x996`)
TICK_HZ = 60.3     # FMDRV count-down timer 1 (INT 66h AH=F1), the unit of every wait below

# ---------------------------------------------------------------------------------------------
# helpers


def cstr(img, a):
    return img[a:img.index(b"\0", a)]


def text(img, ds, off):
    return cstr(img, ds + off).decode("cp949")


def palette_at(img, a):
    """48-byte palette: 16 x (B, R, G), 0..15 per channel (as MAIN.EXE 0x40ECE)."""
    p = img[a:a + 48]
    return [(p[i * 3 + 1] * 17, p[i * 3 + 2] * 17, p[i * 3] * 17) for i in range(16)]


def low8(pal):
    """3-plane pictures use the first 8 colours of the palette they are shown with
    (END.EXE copies them into colours 0-7 or 8-15, 0x24C8 / 0x216A)."""
    return list(pal[:8]) * 2


def save(path, w, h, px, pal):
    png.write_png(path, w, h, b"".join(bytes(pal[c]) for c in px))


def save_rgba(path, w, h, px, ink):
    """ink: colour index -> (r, g, b) or None (transparent)."""
    out = bytearray()
    for c in px:
        v = ink.get(c)
        out += bytes(v) + b"\xff" if v else b"\0\0\0\0"
    png.write_png(path, w, h, bytes(out))


def pictures(blob):
    return [K.decode_rle4(blob, o)[:3] for o in K.offset_table(blob)]


def hexkey(off):
    return f"0x{off:04X}"


# ---------------------------------------------------------------------------------------------
# END.EXE

END_PALETTES = [0x84 + 0x30 * k for k in range(12)]       # DS:0x84..0x2C3

HERO_NAMES = ["조안 페레로 (João Ferrero)", "카탈리나 에란초 (Catalina Erantzo)", "옷토 스피노라 (Otto Spinola)",
              "에르네스트 로페스 (Ernesto Lopez)", "피에트로 콘티 (Pietro Conti)", "알 베자스 (Al Vezas)"]
SHORT = ["João", "Catalina", "Otto", "Ernesto", "Pietro", "Al"]
NATIONS = ["Portugal", "Spain", "Turkey", "England", "Italy", "Netherlands"]

FACES = {  # END_PUT.DAT portraits (64x80, 3 planes, 0x780 bytes each), as used by the dialogues
    0: "João (hero 0)", 1: "Catalina (hero 1)", 2: "Otto (hero 2)", 3: "Ernesto (hero 3)",
    4: "Pietro (hero 4)", 5: "Al (hero 5)",
    6: "ruler of Portugal (6 + nation, duke ending)", 7: "ruler of Spain", 8: "ruler of Turkey",
    9: "ruler of England", 10: "ruler of Italy", 11: "ruler of the Netherlands",
    12: "Duke Leon Ferrero (João's father)", 13: "Rocco", 14: "Sir Gilbert", 15: "King Henry VIII",
    16: "Paula (Ernesto's companion)", 17: "Duke Leon Ferrero (Pietro's ending)", 18: "the duchess (마님)",
    19: "Pablisson (Leon's father)", 20: "Camilo",
}

# ENDGRP.DAT: palette (END DS offset) each picture is shown with, and what it is.
ENDGRP = {
    0: (0x144, "staff roll picture 1: port"), 1: (0x174, "staff roll picture 2: market"),
    2: (0x294, "staff roll picture 3: tavern"), 3: (0x294, "staff roll picture 4: sea battle"),
    4: (0x1A4, "staff roll picture 5: storm"), 5: (0x1D4, "staff roll picture 6: the six heroes"),
    6: (0x204, "closing picture: the closed book"), 7: (0x84, "diary background: desk with the open book, at (0,30)"),
    8: (0x84, "diary lamp frame A, at (480,30)"), 9: (0x84, "diary lamp frame B"),
    10: (0xB4, "João portrait"), 11: (0xB4, "João portrait, final frame"),
    15: (0xE4, "Catalina portrait"), 16: (0xE4, "Catalina portrait, final frame"),
    23: (0x294, "Otto portrait"), 30: (0x114, "Pietro portrait"),
    37: (0x294, "Ernesto and Paula portrait"), 38: (0x294, "Ernesto and Paula, final frame"),
    45: (0x294, "Al portrait"), 46: (0x294, "Al portrait, final frame"),
    53: (0x294, "'Fin', at (424,250)"), 54: (0x294, "epilogue text panel 1 (1 plane, scrolled)"),
    55: (0x294, "epilogue text panel 2"), 56: (0x234, "homecoming dialogue background (640x400)"),
    57: (0x294, "KOEI logo, at (216,80)"), 58: (0x294, "(c)1995 KOEI, at (184,200)"),
}
# per hero: portrait pictures, its palette, eye-blink sprites, lamp/second sprites (END 0x40A,
# 0x60C, 0x4A7, 0x51C, 0x86E), blink position 0x33CE, flame position 0x31C3 / 0x320C (screen pixels,
# the portrait has already slid to x = 0)
HERO_ART = [
    dict(portrait=10, final=11, palette=0xB4, at=(256, 30), size=(384, 300), eyes=12, eyesAt=(232, 86), sprite=None),
    dict(portrait=15, final=16, palette=0xE4, at=(256, 30), size=(384, 300), eyes=17, eyesAt=(192, 94),
         sprite=dict(first=20, at=(32, 182), kind="lamp flame")),
    dict(portrait=23, final=None, palette=0x294, at=(256, 30), size=(384, 300), eyes=24, eyesAt=(208, 78),
         sprite=dict(first=27, at=(24, 206), kind="lamp flame")),
    dict(portrait=37, final=38, palette=0x294, at=(336, 0), size=(304, 384), eyes=39, eyesAt=(80, 56),
         sprite=dict(first=42, at=(32, 296), kind="lamp flame")),
    dict(portrait=30, final=None, palette=0x114, at=(256, 30), size=(384, 300), eyes=31, eyesAt=(200, 150),
         sprite=dict(first=34, at=(32, 206), kind="lamp flame")),
    dict(portrait=45, final=46, palette=0x294, at=(256, 30), size=(384, 300), eyes=47, eyesAt=(144, 86),
         sprite=dict(first=50, at=(224, 86), kind="second character's eyes (open, half, closed)")),
]
for _h, _a in enumerate(HERO_ART):
    for k in range(3):
        ENDGRP[_a["eyes"] + k] = (_a["palette"], f"{SHORT[_h]} eye blink {('open', 'half', 'closed')[k]}")
        if _a["sprite"]:
            ENDGRP[_a["sprite"]["first"] + k] = (_a["palette"], f"{SHORT[_h]} {_a['sprite']['kind']} {k}")

# 0x0000: per ending code the five EVENT pictures loaded into buffers 0..4 (file digit, picture);
# buffer k is diary page k, buffer 4 is also the picture beside the homecoming narration.
EVENT_SLOTS = [
    [(1, 0), (1, 3), (1, 1), (1, 4), (1, 2)],
    [(2, 4), (2, 0), (2, 1), (2, 5), (2, 3)],
    [(0, 0), (3, 1), (3, 0), (3, 3), (3, 2)],
    [(4, 0), (4, 1), (4, 4), (4, 3), (4, 2)],
    [(5, 2), (5, 1), (5, 4), (5, 3), (5, 0)],
    [(0, 0), (6, 1), (6, 3), (6, 2), (6, 0)],
]
SCROLL_PALETTES = [0x144, 0x174, 0x294, 0x294, 0x1A4, 0x1D4]   # DS:0x52.. (staff roll pictures 0-5)

# homecoming scene, one function per ending (far pointers DS:0x1D8E; duke ending 0x1441)
DIALOGUE_FUNCS = {0: (0xEF0, 0x1026), 1: (0x1026, 0x107A), 2: (0x107A, 0x11AF), 3: (0x12F9, 0x13ED),
                  4: (0x11AF, 0x12F9), 5: (0x13ED, 0x1441), "duke": (0x1441, 0x14E8)}
NAME_ARGS = {0x3DA8: "{given}", 0x3DEB: "{family}"}   # name halves copied from INT 65h AH=2

EPILOGUE = []  # ENDGRP 54 / 55 are shown as the original pictures; their text is not transcribed in this repository


def split_style(s):
    """Leading ESC x n codes (C colour, B background, F/M render flags) -> dict, rest of text."""
    style = {}
    while s.startswith("\x1b") and len(s) >= 3:
        style[{"C": "color", "B": "background", "F": "f", "M": "m", "R": "r"}.get(s[1], s[1])] = int(s[2], 16)
        s = s[3:]
    return style, s


def fill_names(fmt, args):
    out, k = "", 0
    i = 0
    while i < len(fmt):
        if fmt.startswith("%s", i):
            out += NAME_ARGS.get(args[k], "?") if k < len(args) else "?"
            k += 1
            i += 2
        else:
            out += fmt[i]
            i += 1
    return out


def dialogue(img, start, end):
    """Walk one homecoming function and return its steps. Recognised calls: 0x3B8B / 0x3C09 speech
    window top / bottom (face, format, args), 0x3C87 close windows, 0x3F60 put picture buffer 4,
    0x29B7 draw an EVENT picture, 0x2126 + 0xE1C narration."""
    from capstone import Cs, CS_ARCH_X86, CS_MODE_16
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    regs, stack, steps = {}, [], []
    for i in md.disasm(img[start:end], start):
        ops = [o.strip() for o in i.op_str.split(",")] if i.op_str else []
        if i.mnemonic == "mov" and ops[0] in ("ax", "bx", "cx", "dx"):
            try:
                regs[ops[0]] = int(ops[1], 0)
            except ValueError:
                regs[ops[0]] = {"word ptr [0x3da0]": "hero", "word ptr [0x3db6]": "nation"}.get(ops[1], ops[1])
        elif i.mnemonic == "add" and ops == ["cx", "6"]:
            regs["cx"] = "ruler"
        elif i.mnemonic == "sub" and ops[0] == ops[1]:
            regs[ops[0]] = 0
        elif i.mnemonic == "push" and ops[0] != "cs":
            stack.append(regs.get(ops[0], {"word ptr [0x3da0]": "hero"}.get(ops[0], ops[0])))
        elif i.mnemonic == "call":
            t, args = int(i.op_str, 16), list(reversed(stack))
            if t in (0x3B8B, 0x3C09):
                face, fmt = args[0], args[1]
                steps.append({"say": {"window": "top" if t == 0x3B8B else "bottom",
                                      "face": face if isinstance(face, int) else face,
                                      "text": fill_names(text(img, END_DS, fmt), args[2:]),
                                      "ds": hexkey(fmt)}})
            elif t == 0x3C87:
                steps.append({"closeWindows": True})
            elif t == 0x3F60:
                steps.append({"picture": {"eventSlot": 4, "x": 224, "y": 96}})
            elif t == 0x29B7:
                steps.append({"picture": {"event": regs["bx"], "x": regs["ax"], "y": regs["dx"]}})
            elif t == 0x2126:
                style, body = split_style(text(img, END_DS, args[0]))
                steps.append({"narration": {"text": fill_names(body, args[1:]), "style": style, "ds": hexkey(args[0]),
                                            "x": 192, "y": 248, "right": 432}})
            stack = []
    return steps


def diary(img, hero):
    """0x3783: page k of hero h = 9 line pointers at DS:0x3876 + 2*((5h + k)*9 + j); 0 = empty line."""
    pages = []
    for k in range(5):
        ptrs = struct.unpack_from("<9H", img, END_DS + 0x3876 + 2 * (hero * 5 + k) * 9)
        lines = [text(img, END_DS, p) if p else "" for p in ptrs]
        while lines and not lines[-1]:
            lines.pop()
        n = sum(len(cstr(img, END_DS + p)) for p in ptrs if p)
        f, i = EVENT_SLOTS[hero][k]
        pages.append({"picture": f"event{f}_{i}.png", "sepia": f"event{f}_{i}_sepia.png", "lines": lines,
                      "bytes": n, "holdTicks": ((130 - n) * 3) & 0xFF})
    return pages


def export_endings(out):
    os.makedirs(out, exist_ok=True)
    _, img, _ = mzdis.load(GAME + "/END.EXE")
    assert cstr(img, END_DS + 8).startswith(b"MS Run-Time Library"), "END.EXE DGROUP moved"
    pals = {off: palette_at(img, END_DS + off) for off in END_PALETTES}

    # pictures
    grp = pictures(open(GAME + "/ENDGRP.DAT", "rb").read())
    pic_meta = []
    for n, (w, h, px) in enumerate(grp):
        pal_off, role = ENDGRP[n]
        pal = pals[pal_off] if n in (7, 8, 9, 56) else low8(pals[pal_off])
        save(f"{out}/endgrp_{n:02}.png", w, h, px, pal)
        pic_meta.append({"id": n, "file": f"endgrp_{n:02}.png", "w": w, "h": h, "palette": hexkey(pal_off), "role": role})

    put = open(GAME + "/END_PUT.DAT", "rb").read()
    std = low8(pals[0x234])
    for f in range(21):
        save(f"{out}/face_{f:02}.png", 64, 80, K.planar_bytes(put[f * 0x780:(f + 1) * 0x780], 64, 80, 3), std)

    sepia = low8(pals[0x264])
    events = {}
    for f, i in sorted({s for slots in EVENT_SLOTS for s in slots} | {(5, 5)}):
        w, h, px = pictures(open(f"{GAME}/EVENT{f}.DAT", "rb").read())[i]
        save(f"{out}/event{f}_{i}.png", w, h, px, std)
        save(f"{out}/event{f}_{i}_sepia.png", w, h, px, sepia)
        events[f"event{f}_{i}"] = {"w": w, "h": h, "source": f"EVENT{f}.DAT #{i}"}

    endings = []
    for hero in range(6):
        art = HERO_ART[hero]
        steps = dialogue(img, *DIALOGUE_FUNCS[hero])
        for s in steps:
            p = s.get("picture")
            if p and "eventSlot" in p:
                f, i = EVENT_SLOTS[hero][4]
                p["file"] = f"event{f}_{i}.png"
            elif p and "event" in p:
                p["file"] = f"event5_{p.pop('event')}.png"    # EVENT5.DAT is still open (Pietro)
        endings.append({
            "code": hero, "hero": hero, "name": HERO_NAMES[hero], "script": f"SNR{hero + 1}.DAT `ending {hero}`",
            "homecoming": steps,
            "diary": diary(img, hero),
            "portrait": {"file": f"endgrp_{art['portrait']:02}.png",
                         "final": f"endgrp_{art['final']:02}.png" if art["final"] else None,
                         "palette": hexkey(art["palette"]), "drawAt": list(art["at"]), "size": list(art["size"]),
                         "slideTo": [0, art["at"][1]],
                         "finalAt": [0, art["at"][1]] if art["final"] else None,
                         "finalIsEyesClosed": art["final"] is None and hero in (2, 4)},
            "eyes": {"frames": [f"endgrp_{art['eyes'] + k:02}.png" for k in range(3)], "at": list(art["eyesAt"])},
            "sprite": None if not art["sprite"] else {
                "kind": art["sprite"]["kind"], "at": list(art["sprite"]["at"]),
                "frames": [f"endgrp_{art['sprite']['first'] + k:02}.png" for k in range(3)],
                "order": [1, 2, 1, 0] if hero == 5 else [0, 2, 0, 1],
                "frameTicks": [6, 6, 6, 480] if hero == 5 else [12, 12, 12, 12]},
        })
    duke = dialogue(img, *DIALOGUE_FUNCS["duke"])

    data = {
        "source": "END.EXE (DS = image 0x8D70), ENDGRP.DAT, END_PUT.DAT, EVENT*.DAT; see docs/re/endings.md",
        "tickHz": TICK_HZ,
        "screen": [640, 400],
        "palettes": {hexkey(o): [list(c) for c in p] for o, p in pals.items()},
        "music": {"homecoming": {"song": 19, "file": "song19.m4a", "endBankSong": 1},
                  "diaryAndStaffRoll": {"song": 22, "file": "song22.m4a", "endBankSong": 2}},
        "codes": [
            {"code": "0..5", "what": "story ending of hero = code (SNR{code+1}.DAT `ending n`)", "program": "END.EXE"},
            {"code": "0x0F", "what": "duke ending: peerage rank 9 reached at the palace (MAIN 0x2A5E6) with story mode on; "
                             "END gets code 0x100 | hero", "program": "END.EXE"},
            {"code": "0x10", "what": "52 years elapsed (MAIN 0x15A8B): retirement, message 1016", "program": "MAIN.EXE"},
            {"code": "0x18", "what": "flagship sunk in a storm (0x197DF), message 1014 + GRAPH.DAT 61", "program": "MAIN.EXE"},
            {"code": "0x19", "what": "no crew left (0x18F8D), message 1015 + GRAPH.DAT 61", "program": "MAIN.EXE"},
            {"code": "0x1A", "what": "fleet battle lost (0x1067E), message 1013 + GRAPH.DAT 61", "program": "MAIN.EXE"},
            {"code": "0x80", "what": "quit from the start menu (0x16987): KOEI logo GRAPH 60/62, exit to DOS", "program": "MAIN.EXE"},
            {"code": "0x88", "what": "'end the game' confirmed (0x20F82): back to the start menu, nothing shown", "program": "MAIN.EXE"},
        ],
        "names": "{given} / {family}: hero record +0 / +0xD passed by MAIN through INT 65h AH=1 as 'given family'. "
                 "Particle markers X(는) X(를) X(야) X(여) are resolved from the last syllable as in MAIN.EXE.",
        "faces": [{"id": f, "file": f"face_{f:02}.png", "who": FACES[f]} for f in range(21)],
        "pictures": pic_meta,
        "eventPictures": events,
        "windows": {"top": {"frame": [104, 16, 312, 144], "face": [120, 32], "text": [192, 32]},
                    "bottom": {"frame": [160, 176, 312, 144], "face": [176, 192], "text": [248, 192]}},
        "endings": endings,
        "dukeEnding": {"code": "0x0F", "homecoming": duke,
                       "faceNotes": "'ruler' = face 6 + nation of the hero (person +0x31 & 0xF), 'hero' = face of the hero id",
                       "picture": "eventSlot 4 of the hero (as the story ending)", "diary": None},
        "epilogue": {"panels": ["endgrp_54.png", "endgrp_55.png"], "lines": EPILOGUE,
                     "window": {"x": 384, "y": 210, "w": 240, "h": 160}, "ticksPerLine": 6, "color": 7},
        "sequence": SEQUENCE,
    }
    json.dump(data, open(out + "/endings.json", "w"), ensure_ascii=False, indent=1)
    return data


SEQUENCE = [  # END.EXE main 0x1A8 -> 0x7CE; ticks of TICK_HZ; colours 0-7 = "lower", 8-15 = "upper" palette half
    {"scene": "homecoming", "addr": "0x14E8", "steps": [
        "music song 19 (END bank 1), looping",
        "draw endgrp_56 at (0,0), fade to palette 0x0234 (1 step = 1 tick, channel +-1 per step)",
        "story endings: the hero's dialogue; code 0x0F: dukeEnding (each window line waits for a key; "
        "a window opens with an expanding frame, lines are typed into it)",
        "close windows; the eventSlot-4 picture (192x144) at (224,96); narration typed at (192,248), "
        "right margin 432, waits for a key (blinking cursor)",
        "music fade 20 steps, fade to black, clear"]},
    {"scene": "diary", "addr": "0x566, 0x598", "storyOnly": True, "steps": [
        "music song 22 (END bank 2), looping",
        "endgrp_07 at (0,30), palette 0x0084; lamp: endgrp_08 / 09 alternate at (480,30) every 24 ticks during waits",
        "wait 900, dim colours 0-7 to half (0x249D), wait 300",
        "5 pages k = 0..4: fill the picture box (8,100,192x144) with colour 8 in 12 interleaved passes (1 tick each); "
        "upper half := palette 0x0294 (standard colours); reveal eventSlot k bottom-up in 12 passes (1 tick each); "
        "wait 120; fade the upper half to 0x0264 (sepia), 6 ticks per step; wait 60; type the 9 lines at "
        "(208, 100 + 24*j), 3 ticks per byte, colour 15; hold holdTicks; dissolve the text area (208,100,272x208) "
        "back to the empty book (4 passes x 16 steps, 5 ticks each); wait 60",
        "fade colours 0-7 to black (5 ticks per step); clear everything except the last picture"]},
    {"scene": "staffRoll", "addr": "0x84A..0xB09", "steps": [
        "draw the portrait (colours 0-7) at portrait.drawAt; fade: lower half -> portrait palette, upper half "
        "(last diary picture) -> black, 19 ticks per step; wait 20; clear the picture box",
        "slide the portrait left 8 px per tick to x = 0",
        "upper half -> palette 0x0144, fill (392,50,224x160) with colour 8",
        "for k = 0..5: dissolve endgrp_0k into (392,50) while fading the upper half to its palette "
        "(3 planes x 16 steps, 6 ticks each); wait 60; eye blink; wait 180; blink; wait 180; blink; wait 60",
        "the whole time (2-tick frames): epilogue scroller (1 line per 3 frames), eye blink sprite frames 6 ticks, "
        "hero sprite (lamp flame / Al's companion) per endings[].sprite",
        "final frame: dissolve portrait.final at portrait.finalAt (João, Catalina, Ernst, Al) or close the eyes "
        "(Otto, Pietro: half, closed, 6 ticks each); dissolve steps are now 5 ticks",
        "wait 60; fade colours 0-7 to black (11 ticks per step)",
        "dissolve endgrp_06 (closed book) into (392,50), upper half -> 0x0204; wait 60; clear the left half",
        "lower half -> 0x0294; dissolve endgrp_53 'Fin' into (424,250); wait 60",
        "fade upper half to black (11 ticks/step); music fade 120 steps while the lower half fades (11 ticks/step)",
        "clear; endgrp_57 at (216,80), endgrp_58 at (184,200), fade in to 0x0294; wait for a key; fade out; "
        "END.EXE exits and KOEI.COM returns to DOS"]},
]

# ---------------------------------------------------------------------------------------------
# OPEN.EXE

OPEN_PALETTES = [0xF6 + 0x30 * k for k in range(13)]       # DS:0xF6..0x365

# OPGRAPH.LZW entries: palette (OPEN DS offset) per entry, per-picture overrides, what they are
OP_PAL = {0: 0x2D6, 1: 0x126, 2: 0x126, 3: 0xF6, 4: 0xF6, 5: 0xF6, 6: 0xF6, 7: 0xF6, 8: 0xF6, 9: 0x186,
          10: 0xF6, 11: 0x126, 12: 0x126, 13: 0xF6}
OP_PAL_PIC = {(0, 6): 0x1B6, (0, 7): 0x216, (0, 8): 0x216, (0, 9): 0x276, (0, 10): 0x246,
              (0, 11): 0x276, (0, 12): 0x276, (0, 13): 0x276, (0, 14): 0x276, (0, 15): 0x276}
OP_ROLES = {
    (0, 0): "KOEI logo", (0, 1): "KOEI PRESENTS", (0, 2): "REKOEITION SERIES", (0, 3): "AN EIJI FUKUZAWA PRODUCTION",
    (0, 4): "from its", (0, 5): "title kanji mask: the water texture shows inside", (0, 6): "water texture shown through the mask (palette cycled)",
    (0, 7): "title kanji silhouette A", (0, 8): "title kanji silhouette B", (0, 9): "title 'II'",
    (0, 10): "final title 大航海時代II", (13, 0): "caption: prologue", (13, 9): "caption: finale",
}
PLANE_FRAMES = {(4, 1), (4, 2), (5, 1), (5, 2), (6, 1), (6, 2), (7, 1), (7, 2)}   # 4 one-bit frames, one per plane
CHAR_SCENES = [  # OPEN.EXE scene functions 3..10: OPGRAPH entry, caption, layout (screen pixels)
    dict(scene=3, who="Otto Spinola", entry=3, caption=1, captionAt=(288, 64), big=6, bigOutline=5, bigAt=(88, 48),
         portrait=7, portraitAt=(152, 64), eyes=8, eyesAt=(184, 104), emblem="stars 3/0-4 (32x32)"),
    dict(scene=4, who="Catalina Erantzo", entry=4, caption=2, captionAt=(48, 64), big=3, bigAt=(88, 48),
         portrait=4, portraitAt=(192, 48), eyes=5, eyesAt=(432, 120), emblem="pistol 4/0 still, 4/1-2 = 8 turning frames, ends at (168,56)"),
    dict(scene=5, who="Ernesto Lopez", entry=5, caption=3, captionAt=(288, 64), big=3, bigAt=(88, 48),
         portrait=4, portraitAt=(184, 64), eyes=5, eyesAt=(208, 112), emblem="quill 5/0-2, ends at (56,232)"),
    dict(scene=6, who="Pietro (Piedro) Conti", entry=6, caption=4, captionAt=(48, 64), big=3, bigAt=(88, 48),
         portrait=4, portraitAt=(360, 80), eyes=5, eyesAt=(376, 128), emblem="gold mask coin 6/0-2, ends at (464,176)"),
    dict(scene=7, who="Al Vezas", entry=7, caption=5, captionAt=(288, 64), big=3, bigAt=(88, 48),
         portrait=4, portraitAt=(160, 48), eyes=5, eyesAt=(200, 88), emblem="dagger 7/0-2, ends at (144,232)"),
    dict(scene=8, who="the heroines", entry=8, caption=6, captionAt=(48, 176), big=5, bigAt=(88, 48),
         portrait=None, eyes=[(6, (344, 120)), (9, (368, 192)), (12, (440, 112))],
         emblem="spinning coins 8/0-4 at (336,96), (360,176), (424,88)"),
    dict(scene=9, who="Commander Ezequiel and Marquis Martinez", entry=9, caption=7, captionAt=(288, 128), big=10,
         bigAt=(88, 48), portrait=None, eyes=None, palette=0x186,
         emblem="flames 9/0-4 (72x40) at (216,72) and 9/5-9 (80x48) at (136,200)"),
    dict(scene=10, who="João Ferrero", entry=10, caption=8, captionAt=(48, 64), big=0, bigAt=(88, 48),
         portrait=4, portraitAt=(304, 72), eyes=1, eyesAt=(368, 120), emblem="stars 3/0-4 (OPGRAPH 3 reloaded)"),
]
CAPTIONS = [  # OPGRAPH 13, English text pictures (colour 7 text, colour 8 drop shadow; 0 and 9 colour 8 only)
    "Here begins the glorious tale of the journey\nbeyond the shores of Europe into the Age of Exploration.",
    "Otto Spinola\nAge:25    Sex:Male\n Royal Knight of the British Empire, Otto is on a secret mission for King "
    "HenryⅧ. With a fleet of pirate ships, he must capture all vessels sailing under the flag of Spain.",
    "Catalina Errantzo\nAge:18    Sex:Female\n This red-haired pirate girl hails from Spain. She seeks revenge on "
    "Portugal for the deaths of two men-her brother and her beloved.",
    "Ernesto Lopez\nAge:23    Sex:Male\n Ernesto is a renown geographer from Holland. At the request of the "
    "caetographer Mercator, he sets sail to plot out a detailed map of the world.",
    "Piedro Conti\nAge:33    Sex:Male\n The Conti family went bankrupt years ago,leaving Piedro with a large debt "
    "to pay. With his knack for exploration, his mission is to make a profit in trading exotic goods.",
    "Al Vezas\nAge:19    Sex:Male\n Born from poverty, Al has struggled as a tradeer in Turkey for many years. "
    "Now, with a merchant ship, he is preparing for a career of trade in foreign lands. He has pledged his "
    "life to the pursuit of wealth.",
    " The girls who relate any charactor in the Great Voyage.\nAnd then they help their lover.",
    " Commander Ezeguiel is chasing pirate girl Catalina.\n Marquis Martines plotted to overthrow the Kingdom "
    "of Portugal.",
    "João Ferrero\nAge:18    Sex:Male\n As the son of Prince Leon Ferrero, João sails for the prosperity of "
    "Portugal. In his worldly travels, he hopes to discover the legendary kingdom of Prester John.",
    "In the name of glory, these explorers\nset sail into the unknown world.",
]


def export_opening(out):
    os.makedirs(out, exist_ok=True)
    _, img, _ = mzdis.load(GAME + "/OPEN.EXE")
    assert cstr(img, OPEN_DS + 8).startswith(b"MS Run-Time Library"), "OPEN.EXE DGROUP moved"
    assert cstr(img, OPEN_DS + 0x5E) == b"C:OPGRAPH.LZW"
    pals = {off: palette_at(img, OPEN_DS + off) for off in OPEN_PALETTES}
    scenes_tbl = [struct.unpack_from("<H", img, OPEN_DS + 0x740 + 4 * k)[0] for k in range(12)]

    arc = ls11.unpack(GAME + "/OPGRAPH.LZW")
    files, decoded = [], {}
    for e, blob in enumerate(arc):
        for s, (w, h, px) in enumerate(pictures(blob)):
            decoded[(e, s)] = (w, h, px)
            pal_off = OP_PAL_PIC.get((e, s), OP_PAL[e])
            pal = pals[pal_off]
            name = f"op{e:02}_{s:02}"
            meta = {"entry": e, "pic": s, "w": w, "h": h, "palette": hexkey(pal_off), "role": OP_ROLES.get((e, s), "")}
            if (e, s) in PLANE_FRAMES:
                meta["frames"] = []
                for p in range(4):
                    save_rgba(f"{out}/{name}_f{p}.png", w, h, bytes((c >> p) & 1 for c in px), {1: pal[7]})
                    meta["frames"].append(f"{name}_f{p}.png")
                meta["role"] = "4 one-bit animation frames, one per bitplane (drawn in colour 7)"
            elif e == 13:
                ink = {7: pal[7], 8: (0, 0, 0)} if 1 <= s <= 8 else {8: pal[7]}
                save_rgba(f"{out}/{name}.png", w, h, px, ink)
                meta["file"], meta["text"] = f"{name}.png", CAPTIONS[s]
                meta["note"] = "RGBA: text colour 7 of the palette, colour 8 = shadow (black) or text (captions 0, 9)"
            elif (e, s) == (0, 5):
                save_rgba(f"{out}/{name}.png", w, h, px, {0: (255, 255, 255)})   # opaque = inside the kanji
                meta["file"] = f"{name}.png"
                meta["note"] = "RGBA: opaque = kanji shape (colour 0 inside, colour 8 = outside in the original)"
            else:
                save(f"{out}/{name}.png", w, h, px, pal)
                meta["file"] = f"{name}.png"
            files.append(meta)

    # the two pans: OPGRAPH 1 + 2 (scene 2) and 11 + 12 (scene 11) continue each other to the right
    pans = []
    for a, b, name in ((1, 2, "pan_ships"), (11, 12, "pan_finale")):
        for fr in (0, 1):
            wa, h, pa = decoded[(a, fr)]
            wb, _, pb = decoded[(b, fr)]
            px = bytearray()
            for y in range(h):
                px += pa[y * wa:(y + 1) * wa] + pb[y * wb:(y + 1) * wb]
            save(f"{out}/{name}_{fr}.png", wa + wb, h, bytes(px), pals[0x126])
        pans.append({"file": [f"{name}_0.png", f"{name}_1.png"], "w": wa + wb, "h": h, "from": [f"op{a:02}", f"op{b:02}"]})

    scenes = [
        {"scene": 0, "addr": hex(scenes_tbl[0]), "what": "credits", "steps": [
            "music: OPEN bank song 1 = D2.MML song 21 (assets/music/song21.m4a), looping, until OPEN.EXE ends",
            "op00_00 (KOEI logo) at (216,96); fade in to 0x02A6 (logo only, 4 ticks/step), wait 60, fade to 0x02D6 (text)",
            "op00_01 'KOEI PRESENTS' at (216,224); wait 120; fade out (4 ticks/step)",
            "op00_03 'AN EIJI FUKUZAWA PRODUCTION' at (120,174); wait 120; fade out",
            "op00_04 'from its' at (248,132) + op00_02 'REKOEITION SERIES' at (128,188); fade in as above; wait 120; "
            "fade out; wait 60"]},
        {"scene": 1, "addr": hex(scenes_tbl[1]), "what": "title", "steps": [
            "op00_05 mask at (40,120); op00_06 water texture shows through it, palette 0x01B6 cycled (0x49DC) "
            "for about 90 steps, then fade to 0x01E6 (white)",
            "op00_07 / op00_08 kanji silhouettes at (40,120) with white palettes 0x0216 (flash), op00_09 'II' at (528,112)",
            "sparkles op00_11..15 (32x32) run along the title, palette 0x0276",
            "op00_10 final title at (0,120); fade to 0x0246 (4 ticks/step)"]},
        {"scene": 2, "addr": hex(scenes_tbl[2]), "what": "prologue caption and the fleet", "steps": [
            "wait 120; fade to 0x0336 (white); white band (0,100)-(640,300); caption op13_00 at (32,180) shimmers in "
            "(8 steps x 4 ticks), wait 180, shimmers out",
            "op01_00 at (0,100); fade to 0x0126 (8 ticks/step); waves: op01_00 / op01_01 alternate",
            "pan: the 640x200 view scrolls right 8 px every 16 ticks for 40 columns into op02 (pan_ships, 960 wide), "
            "fading to black over the last 16 steps"]},
    ]
    for c in CHAR_SCENES:
        e = c["entry"]
        steps = [f"emblem: {c['emblem']}"]
        if c.get("bigOutline") is not None:
            steps.append(f"outline op{e:02}_{c['bigOutline']:02} at {c['bigAt']}, palette 0x00F6")
        steps.append(f"op{e:02}_{c['big']:02} dissolves in at {c['bigAt']} (plane by plane), wait 120")
        if c["portrait"] is not None:
            steps.append(f"portrait op{e:02}_{c['portrait']:02} dissolves in at {c['portraitAt']}")
        steps.append(f"caption op13_{c['caption']:02} at {c['captionAt']}")
        if isinstance(c["eyes"], list):
            steps += [f"eyes op{e:02}_{f:02}..{f + 2:02} blink at {at}" for f, at in c["eyes"]]
        elif c["eyes"] is not None:
            steps.append(f"eyes op{e:02}_{c['eyes']:02}..{c['eyes'] + 2:02} blink at {c['eyesAt']} for 90 frames")
        steps.append("next OPGRAPH entry is loaded; fade to black")
        scenes.append({"scene": c["scene"], "addr": hex(scenes_tbl[c["scene"]]), "what": c["who"],
                       "palette": hexkey(c.get("palette", 0xF6)), "steps": steps})
    scenes.append({"scene": 11, "addr": hex(scenes_tbl[11]), "what": "finale", "steps": [
        "fade to black; op11_00 at (0,100); fade to 0x0126; waves op11_00 / op11_01",
        "pan right into op12 (pan_finale, 896 wide), 8 px per step",
        "fade to 0x0336 (white), white band; caption op13_09 at (128,180) shimmers in, wait, out",
        "fade to black; OPEN.EXE fades the music (20 steps) and exits; KOEI.COM starts MAIN.EXE (start menu)"]})

    data = {
        "source": "OPEN.EXE (DS = image 0x9960), OPGRAPH.LZW (14 LS11 entries, GRAPH.DAT picture containers); "
                  "see docs/re/endings.md",
        "tickHz": TICK_HZ, "screen": [640, 400], "skip": "Esc ends a wait (0x4DDF); Enter / Space end timer waits (0x4D17)",
        "music": {"song": 21, "file": "song21.m4a", "openBankSong": 1},
        "palettes": {hexkey(o): [list(c) for c in p] for o, p in pals.items()},
        "pictures": files,
        "pans": pans,
        "captions": CAPTIONS,
        "scenes": scenes,
    }
    json.dump(data, open(out + "/opening.json", "w"), ensure_ascii=False, indent=1)
    return data


def main():
    e = export_endings(OUT + "/endings")
    o = export_opening(OUT + "/opening")
    print(f"endings: {len(e['pictures'])} ENDGRP pictures, 21 faces, {len(e['eventPictures'])} EVENT pictures, "
          f"{sum(len(x['homecoming']) for x in e['endings'])} dialogue steps, "
          f"{sum(len(p['lines']) for x in e['endings'] for p in x['diary'])} diary lines")
    print(f"opening: {len(o['pictures'])} OPGRAPH pictures, {len(o['scenes'])} scenes")


if __name__ == "__main__":
    main()
