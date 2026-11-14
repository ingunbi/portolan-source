#!/usr/bin/env python3
"""Sprites and small pictures the remaster still lacks (docs/re/sprites.md). Run with build/venv/bin/python -I.

usage: sprites.py [OUT_DIR] [GROUP ...]   default assets/sprites, all groups;
       writes OUT_DIR/<group>/*.png (RGBA) + OUT_DIR/<group>/index.json

Byte layouts used by MAIN.EXE's blitters (one group of bytes per 8-pixel column, MSB = leftmost pixel):
  i4    p0 p1 p2 p3     screen put 0x2A7 / 0x3D2 (modes 0 copy, 1 xor, 2 and, 3 or, 4 skip colour 0), work page 0x2431
  m3    p0 p1 p2 mask   work-page masked put 0x22C9: mask bit 1 = keep the background
  i3    p0 p1 p2        KAO-style 3-plane pictures (colours 0..7)
  w3    per 16 px: mask word, p0, p1, p2 words (bytes left first); mask 1 = keep; plane 3 cleared (0x248C)
  1-bit one bit per pixel, drawn by 0x63E in one colour (mode high byte 4) or as an AND mask (high byte 2)
GRAPH.DAT pictures use the compressed 0xFC4 format (gfx_codec.decode_rle4).
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0
MAIN_PALETTE = 0x40ECE          # image address of the default 16-colour table (B,R,G nibbles)
INFO_PAL = 0xAF80               # fleet / ship info screens (info.md §0)
DAY_PAL = 0xAD82                # town and sea daylight; colours 0..7 equal the main table
BATTLE_PAL = 0xA584             # sea battle and duel, faded in by 0xBB18
WHITE, BLACK = (255, 255, 255), (0, 0, 0)


class Ctx:
    """Shared inputs: MAIN.EXE image, LS11 archives, output root."""

    def __init__(self, out):
        _, self.img, _ = mzdis.load(GAME + "/MAIN.EXE")
        self.out = out
        self._ls11 = {}

    def ls11(self, name):
        if name not in self._ls11:
            self._ls11[name] = ls11.unpack(f"{GAME}/{name}")
        return self._ls11[name]

    def file(self, name):
        return open(f"{GAME}/{name}", "rb").read()

    def palette(self, ds_off=None):
        """RGB list from a B,R,G table; ds_off is a DS offset (None = the main table 0x40ECE)."""
        return K.bbr_table(self.img, MAIN_PALETTE if ds_off is None else DS + ds_off)

    def group(self, name):
        d = f"{self.out}/{name}"
        os.makedirs(d, exist_ok=True)
        return d


def decode(d, w, h, fmt, off=0, stride=None):
    """-> (indices, alpha) lists of w*h. stride = bytes per row (default w/8 * bytes per column)."""
    if fmt == "w3":
        return decode_w3(d, w, h, off)
    per = 3 if fmt == "i3" else 4
    bw = (w + 7) // 8
    stride = stride or bw * per
    px, al = [0] * (w * h), [1] * (w * h)
    for y in range(h):
        row = off + y * stride
        for x in range(w):
            i, b = row + (x >> 3) * per, 7 - (x & 7)
            if fmt == "i4":
                v = (d[i] >> b & 1) | (d[i + 1] >> b & 1) << 1 | (d[i + 2] >> b & 1) << 2 | (d[i + 3] >> b & 1) << 3
            elif fmt in ("i3", "m3"):
                v = (d[i] >> b & 1) | (d[i + 1] >> b & 1) << 1 | (d[i + 2] >> b & 1) << 2
                if fmt == "m3" and d[i + 3] >> b & 1:
                    al[y * w + x] = 0
            elif fmt == "mi3":
                v = (d[i + 1] >> b & 1) | (d[i + 2] >> b & 1) << 1 | (d[i + 3] >> b & 1) << 2
                if d[i] >> b & 1:
                    al[y * w + x] = 0
            else:
                raise ValueError(fmt)
            px[y * w + x] = v
    return px, al


def decode_w3(d, w, h, off):
    """World-map ship layout (0x248C): rows of 16-px groups, each mask, p0, p1, p2 as 2 bytes (left byte first)."""
    groups = w // 16
    px, al = [0] * (w * h), [1] * (w * h)
    for y in range(h):
        for x in range(w):
            g = off + (y * groups + x // 16) * 8 + (x % 16) // 8
            b = 7 - x % 8
            px[y * w + x] = sum((d[g + 2 + 2 * p] >> b & 1) << p for p in range(3))
            al[y * w + x] = 0 if d[g] >> b & 1 else 1
    return px, al


def bits(d, off, w, h):
    bw = (w + 7) // 8
    return [d[off + y * bw + (x >> 3)] >> (7 - (x & 7)) & 1 for y in range(h) for x in range(w)]


def save(path, w, h, px, pal, alpha=None, key=None):
    """RGBA PNG. alpha: list of 0/1; key: palette index drawn transparent (e.g. 0 for put mode 4)."""
    out = bytearray()
    for i, v in enumerate(px):
        a = 255
        if (alpha is not None and not alpha[i]) or (key is not None and v == key):
            a = 0
        out += bytes(pal[v]) + bytes((a,))
    png.write_png(path, w, h, bytes(out))


def save_rgba(path, w, h, pixels):
    """pixels: list of (r, g, b) or None (transparent)."""
    png.write_png(path, w, h, b"".join(bytes(p) + b"\xff" if p else b"\0\0\0\0" for p in pixels))


def write_index(ctx, group, data):
    with open(f"{ctx.group(group)}/index.json", "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)


class Group:
    """Collects PNGs and their index records for one output group."""

    def __init__(self, ctx, name):
        self.ctx, self.dir, self.files = ctx, ctx.group(name), []

    def put(self, name, w, h, px, pal, alpha=None, **rec):
        save(f"{self.dir}/{name}.png", w, h, px, pal, alpha)
        self.files.append({"name": name + ".png", "w": w, "h": h, **rec})

    def put_rgba(self, name, w, h, pixels, **rec):
        save_rgba(f"{self.dir}/{name}.png", w, h, pixels)
        self.files.append({"name": name + ".png", "w": w, "h": h, **rec})


def graph_dat(ctx):
    g = ctx.file("GRAPH.DAT")
    return g, K.offset_table(g)


# ---------------------------------------------------------------------------------------------------------------
# ships: class pictures of the info screens, the fleet screen background, cargo icons, world-map fleet sprites

SHIP_CLASS_PICTURE = 28         # 0x7EE9: GRAPH.DAT 28 + class, via 0x5A51
FLEET_SLOTS = 0xAFF0            # 10 x (x byte column, y / 16), 0x1CAB2
WORLD_SHIPS = 0x4000            # DATA1[11] (world chips, [0x42A] at sea): 32 sprites of 0x200 from here
WORLD_DIR = 0x9526              # heading 0..7 -> sprite direction 0..3 (N, E, S, W)
CARGO_ICONS = ["식수 water", "식량 food", "자재 lumber", "포탄 shot"]


def export_ships(ctx):
    G = Group(ctx, "ships")
    info = ctx.palette(INFO_PAL)
    nav = json.load(open(ROOT + "/assets/navigation.json")) if os.path.exists(ROOT + "/assets/navigation.json") else None
    g, offs = graph_dat(ctx)
    for c in range(25):
        w, h, px, _ = K.decode_rle4(g, offs[SHIP_CLASS_PICTURE + c])
        G.put(f"class_{c:02}", w, h, px, info, kind="class picture", shipClass=c,
              className=nav["classes"][c]["name"] if nav else None, source=f"GRAPH.DAT[{SHIP_CLASS_PICTURE + c}]",
              format="rle4", palette=f"DS:0x{INFO_PAL:X}", opaque=True)
    u = ctx.ls11("DATA1.LZW")[14]
    px, al = decode(u, 16, 16, "i4", 0x2BA0)
    G.put("fleet_sea_tile", 16, 16, px, info, kind="fleet screen background, tiled 40x20 from (0,0)",
          source="DATA1.LZW[14]", offset=0x2BA0, format="i4", palette=f"DS:0x{INFO_PAL:X}")
    for k, nm in enumerate(CARGO_ICONS):
        px, al = decode(u, 16, 32, "i4", 0x20D0 + 0x100 * k)
        G.put(f"cargo_{k}", 16, 32, px, info, kind="ship screen cargo icon", cargo=nm, source="DATA1.LZW[14]",
              offset=0x20D0 + 0x100 * k, format="i4", palette=f"DS:0x{INFO_PAL:X}")
    w11 = ctx.ls11("DATA1.LZW")[11]
    main = ctx.palette()
    rows = ["player, oared", "player, sail-only", "other fleet, oared", "other fleet, sail-only"]
    dirs = ["N", "E", "S", "W"]
    for r in range(4):
        for dr in range(4):
            for f in range(2):
                off = WORLD_SHIPS + r * 0x1000 + dr * 0x400 + f * 0x200
                px, al = decode(w11, 32, 32, "w3", off)
                G.put(f"world_{r}_{dr}_{f}", 32, 32, px, main, al, kind="world-map fleet sprite", row=rows[r],
                      dir=dirs[dr], frame=f, source="DATA1.LZW[11]", offset=off, format="w3",
                      palette="0x40ECE (colours 0..7 only, same in every time-of-day palette)")
    slots = [(ctx.img[DS + FLEET_SLOTS + 2 * i] * 8, ctx.img[DS + FLEET_SLOTS + 2 * i + 1] * 16) for i in range(10)]
    return {
        "palettes": {"info": {"ds": f"0x{INFO_PAL:X}", "rgb": info}, "main": main},
        "fleetScreen": {"seaTiles": [40, 20], "tile": 16, "shipSlots": slots, "picture": [128, 96],
                        "note": "0x1CAB2: ship of fleet slot i (class picture) at shipSlots[i]"},
        "shipScreen": {"note": "0x1BB79(slot, col): window at column col, class picture at (8*(col+2), 48), "
                               "figurehead at (8*(col+19), 48), cargo icon 2i+j at (8*(col+26+7j), 48+40i)"},
        "worldSprite": {"dirTable": list(ctx.img[DS + WORLD_DIR:DS + WORLD_DIR + 8]),
                        "offset": "0x4000 + 0x1000*(sail-only) + 0x2000*(not player) + 0x400*dir + 0x200*frame",
                        "frame": "(tick [0x571] + fleet's index in the row) & 1",
                        "screen": "(96 + 16*dx, 8 + 16*dy), dx, dy = fleet tile - view origin ([0xF92], [0xF94]); "
                                  "game-area y (the put adds 40 for the 480-line screen)"},
        "files": G.files,
    }


# ---------------------------------------------------------------------------------------------------------------
# ui: frame-screen pieces (DATA1[14] sheet, DATA1[6]/[7], TRANSIT.DAT tabs)

HEADINGS8 = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


def export_ui(ctx):
    G = Group(ctx, "ui")
    pal = ctx.palette(DAY_PAL)
    u = ctx.ls11("DATA1.LZW")[14]
    P = f"DS:0x{DAY_PAL:X}"

    def i4(name, d, off, w, h, src, **rec):
        px, al = decode(d, w, h, "i4", off)
        G.put(name, w, h, px, pal, source=src, offset=off, format="i4", palette=P, **rec)

    def stamp(name, off, w, h, **rec):
        b = bits(u, off, w, h)
        G.put_rgba(name, w, h, [WHITE if v else None for v in b], source="DATA1.LZW[14]", offset=off,
                   format="1-bit", **rec)

    # sea: ship's wheel pieces (DATA1[7] at [0xC0E]:0x3EA0, 0x938C); port: compass pieces (DATA1[6], 0x92A8)
    d7, d6 = ctx.ls11("DATA1.LZW")[7], ctx.ls11("DATA1.LZW")[6]
    helm_xy = {}
    for hd in range(8):
        x = 496 if hd > 4 else 536 if hd in (0, 4) else 576
        y = 272 if hd < 2 or hd == 7 else 312 if hd in (2, 6) else 352
        helm_xy[hd] = (x, y)
    for k in range(18):
        lit, hd = divmod(k, 9)
        nm = "centre" if hd == 8 else HEADINGS8[hd]
        i4(f"helm_{'lit' if lit else 'off'}_{nm}", d7, k * 0x200, 32, 32, "DATA1.LZW[7]", kind="sea panel ship's wheel",
           heading=None if hd == 8 else hd, lit=bool(lit), at=None if hd == 8 else helm_xy[hd])
    comp_xy = [(528, 304), (552, 336), (528, 368), (504, 336)]
    for k in range(8):
        lit, dr = divmod(k, 4)
        i4(f"compass_{'lit' if lit else 'off'}_{'NESW'[dr]}", d6, k * 0x1E0, 40, 24, "DATA1.LZW[6]",
           kind="port panel compass", dir=dr, lit=bool(lit), at=comp_xy[dr])
    # menu tabs of the right edge (TRANSIT.DAT 0..0x1E00, 0x91DE): 24x80 at (616, 72 + 80k)
    t = ctx.file("TRANSIT.DAT")
    names = [["INFORMATION", "MANAGEMENT", "INSTRUCTION", "NAVIGATION"], ["정보", "경영", "명령", "항해"]]
    for s in range(2):
        for k in range(4):
            i4(f"tab_{['type1', 'type2'][s]}_{k}", t, (s * 4 + k) * 0x3C0, 24, 80, "TRANSIT.DAT",
               kind="selected menu tab", layout=["TYPE 1 ([0xC30]&0x80 set)", "TYPE 2"][s], tab=k,
               label=names[s][k], at=(616, 72 + 80 * k))
    # sea panel wind dial (0x8DAF at (568, y)): 8 needles + calm
    for k in range(9):
        i4(f"wind_dial_{HEADINGS8[k] if k < 8 else 'calm'}", u, 0x490 + 0x320 * k, 40, 40, "DATA1.LZW[14]",
           kind="sea panel wind dial", heading=k if k < 8 else None)
    # window frame (0x71FA): corners, then 3 styles x (top, left, right, bottom), interior filled with colour 7
    for k, nm in enumerate(["TL", "TR", "BL", "BR"]):
        i4(f"frame_corner_{nm}", u, 0x2C20 + 0x20 * k, 8, 8, "DATA1.LZW[14]", kind="window frame corner")
    for s in range(3):
        for k, nm in enumerate(["top", "left", "right", "bottom"]):
            i4(f"frame_{s}_{nm}", u, 0x2CA0 + 0x80 * s + 0x20 * k, 8, 8, "DATA1.LZW[14]",
               kind="window frame edge (tiled)", style=s)
    # list window pieces and its scroll buttons (0x148CE..0x14C95)
    for k in range(16):
        i4(f"list_piece_{k:02}", u, 0x39A0 + 0x20 * k, 8, 8, "DATA1.LZW[14]", kind="list window frame piece")
    i4("list_up", u, 0x3BA0, 16, 16, "DATA1.LZW[14]", kind="list scroll button up")
    i4("list_down", u, 0x3C20, 16, 16, "DATA1.LZW[14]", kind="list scroll button down")
    for off, nm, kind in ((0x290, "button_up", "scroll button up (not traced)"),
                          (0x310, "button_down", "scroll button down (not traced)"),
                          (0x390, "button_minus", "gauge button − (environment screen, 0x20BD4)"),
                          (0x410, "button_plus", "gauge button + (environment screen)")):
        i4(nm, u, off, 16, 16, "DATA1.LZW[14]", kind=kind)
    # mouse cursors (0x5012 -> 0x2EE9): 24x24 image (0x48 B) + mask (0x48 B, 0 = cursor pixel)
    cur = ["arrow", "SW", "S", "SE", "W", "centre", "E", "NW", "N", "NE", "arrow_sea"]
    for k, nm in enumerate(cur):
        off = 0x2570 + 0x90 * k
        im, mk = bits(u, off, 24, 24), bits(u, off + 0x48, 24, 24)
        G.put_rgba(f"cursor_{nm}", 24, 24, [WHITE if a else BLACK if not m else None for a, m in zip(im, mk)],
                   source="DATA1.LZW[14]", offset=off, format="1-bit image + 1-bit mask", kind="mouse cursor",
                   colours="image bits white, mask-only bits black (🔎)")
    for k in range(10):
        stamp(f"digit_{k}", 0x24D0 + 16 * k, 8, 16, kind="8x16 digit glyph (text 0x4850)")
    stamp("stamp_more", 0x20B0, 16, 16, kind="▼ stamp, colour 2 (0x14148)")
    stamp("stamp_ship", 0x3CA0, 64, 64, kind="64x64 ship silhouette mask (0x8C59, 0x1AE79) ❓")
    stamp("stamp_dither", 0x280, 8, 16, kind="dither pattern AA55 (0x6920)")
    return {"palette": {"ds": f"0x{DAY_PAL:X}", "rgb": pal,
                        "note": "colours 0..7 are the same in every time-of-day palette DS:0xAD22+0x30*phase"},
            "solidPattern": {"offset": 0, "length": 0x280, "note": "0xFF bytes: source of 0x63E colour fills"},
            "files": G.files}


# ---------------------------------------------------------------------------------------------------------------
# figureheads: TRANSIT.DAT 0x1980 + 0x480*k, k = cargo +0x1D (1..10)

FIGUREHEADS = ["바다표범", "제독", "유니콘", "사자", "독수리", "위인", "포세이돈", "용", "천사", "여신"]


def export_figureheads(ctx):
    G = Group(ctx, "figureheads")
    pal = ctx.palette(INFO_PAL)
    t = ctx.file("TRANSIT.DAT")
    for k in range(1, 11):
        off = 0x1980 + 0x480 * k
        px, al = decode(t, 48, 48, "i4", off)
        G.put(f"figurehead_{k:02}", 48, 48, px, pal, figurehead=k, label=FIGUREHEADS[k - 1], source="TRANSIT.DAT",
              offset=off, format="i4", palette=f"DS:0x{INFO_PAL:X}")
    return {"palette": {"ds": f"0x{INFO_PAL:X}", "rgb": pal},
            "draw": "0x1BB79: read 0x480 B at 0x1980 + 0x480*k, put 0x3D2 mode 0 (opaque) at (8*(col+19), 48)",
            "files": G.files}


# ---------------------------------------------------------------------------------------------------------------
# gambling: DATA1[9] (0x15C0 B, loaded by 0x26E14 into the DS buffer [0xC6F2])

def export_gambling(ctx):
    G = Group(ctx, "gambling")
    pal = ctx.palette()
    d = ctx.ls11("DATA1.LZW")[9]
    for k, nm in enumerate(["spade", "heart", "club", "diamond", "back"]):
        px, al = decode(d, 32, 48, "i4", 0x300 * k)
        G.put(f"card_{nm}", 32, 48, px, pal, suit=k if k < 4 else None, source="DATA1.LZW[9]", offset=0x300 * k,
              format="i4", palette="0x40ECE 🔎")
    for k in range(6):
        px, al = decode(d, 24, 24, "i4", 0xF00 + 0x120 * k)
        G.put(f"die_{k}", 24, 24, px, pal, value=k, pips=k + 1, source="DATA1.LZW[9]", offset=0xF00 + 0x120 * k,
              format="i4", palette="0x40ECE 🔎")
    return {"cards": "0x2DB08(x, y, card): picture suit = card / 13 (4 = back) at (x, y), 32x48 opaque; rank text "
                     "DS:0xB90C (A 2..10 J Q K) printed over it with ESC C0 ESC B7 unless the back is shown",
            "dice": "0x2E5ED(x, y, value): picture = raw value 0..5 (0 = one pip), 24x24 opaque; five dice 40 px apart",
            "files": G.files}


# ---------------------------------------------------------------------------------------------------------------
# battle: HDAT.PUT, the battle pieces of DATA1[14], GRAPH.DAT 26 and 53..56

CYCLE_TABLE = 0xA53C            # 4 x 8 words for colours 8..15 (word = G<<8 | R<<4 | B), stepped every 17 timer ticks
SETS = ["player sail", "enemy sail", "player oars", "enemy oars"]
HEADINGS6 = ["N", "NE", "SE", "S", "SW", "NW"]
# 0xE8C2: 8-neighbour sea mask (bit set = neighbour is not land) -> coast cell. 0x80 NW, 0x40 N, 0x20 NE, 0x10 W,
# 0x08 E, 0x04 SW, 0x02 S, 0x01 SE (square neighbourhood, clamped at the map edge). Masks not listed stay 0x84.
COAST = {
    0x85: [0xD0, 0xD4, 0xF0, 0xF4], 0x86: [0x40, 0x60, 0xC0, 0xE0], 0x87: [0x68, 0x69, 0xE8, 0xE9],
    0x88: [0x10, 0x14, 0x80, 0x90, 0x94], 0x89: [0x08, 0x09, 0x20, 0x28, 0x29],
    0x8A: [0x16, 0x17, 0x96, 0x97], 0x8B: [0x01, 0x02, 0x03, 0x04, 0x06, 0x07], 0x8C: [0x0B, 0x0F, 0x2B, 0x2F],
}
COAST_SIDE = {0x85: "sea to the NW (land lower right)", 0x86: "sea to the N", 0x87: "sea to the NE",
              0x88: "sea to the W", 0x89: "sea to the E", 0x8A: "sea to the SW", 0x8B: "sea to the S",
              0x8C: "sea to the SE"}


def cycle_palettes(ctx, base):
    """The four palettes of the water cycle (0x16BE hooks INT 1Ch, ISR 0x3F34)."""
    out = []
    for k in range(4):
        p = list(base)
        for i in range(8):
            w = struct.unpack_from("<H", ctx.img, DS + CYCLE_TABLE + 16 * k + 2 * i)[0]
            g, r, b = w >> 8 & 15, w >> 4 & 15, w & 15
            p[8 + i] = (r * 17, g * 17, b * 17)
        out.append(p)
    return out


def export_battle(ctx):
    out = ctx.group("battle")
    H = ctx.file("HDAT.PUT")
    U = ctx.ls11("DATA1.LZW")[14]
    pal = ctx.palette(BATTLE_PAL)
    phases = cycle_palettes(ctx, pal)
    assert phases[0] == pal
    cycled = sorted({i for p in phases[1:] for i in range(16) if p[i] != pal[i]})
    files = []

    def put(name, w, h, px, alpha, what, src, off, fmt, p=pal, cycle=True, **extra):
        save(f"{out}/{name}.png", w, h, px, p, alpha)
        rec = {"name": name + ".png", "w": w, "h": h, "what": what, "source": src, "offset": off,
               "format": fmt, "palette": f"DS:0x{BATTLE_PAL:X}"}
        if cycle and any(px[i] in cycled and alpha[i] for i in range(w * h)):
            rec["cyclePhases"] = []
            for k in (1, 2, 3):
                save(f"{out}/{name}_p{k}.png", w, h, px, phases[k], alpha)
                rec["cyclePhases"].append(f"{name}_p{k}.png")
        rec.update(extra)
        files.append(rec)

    def masked(d, off, w, h, mask_first=True):
        n = (w + 7) // 8 * h
        m = bits(d, off if mask_first else off + n * 4, w, h)
        px, _ = decode(d, w, h, "i4", off + n if mask_first else off)
        assert not any(m[i] and px[i] for i in range(w * h))     # OR never lands outside the mask
        return px, [1 - v for v in m]

    def stamp(d, off, colour, name, what, src, **extra):
        b = bits(d, off, 32, 32)
        put(name, 32, 32, [colour] * 1024, b, what, src, off, "1-bit stamp (0x63E mode 0x4cc)",
            cycle=False, colour=colour, **extra)

    use = {0: "sea (cell 0x00)", 1: "sea, second variant (cell 0x01)", 2: "rocks in the sea (not generated)",
           3: "white-capped sea (not generated)", 4: "land (cell 0x84)"}
    for c in COAST:
        use[c & 0x1F] = f"coast cell {c:#x}: {COAST_SIDE[c]}"
    for k in range(13):
        px, al = decode(H, 32, 32, "i4", k * 0x200)
        put(f"chip_{k:02}", 32, 32, px, al, use[k], "HDAT.PUT", k * 0x200, "i4", chip=k)
    for s in range(4):
        for hd in range(6):
            off = 0x1A00 + (6 * s + hd) * 0x280
            px, al = masked(H, off, 32, 32)
            put(f"ship_{s}_{hd}", 32, 32, px, al, f"{SETS[s]} ship, heading {hd} {HEADINGS6[hd]}",
                "HDAT.PUT", off, "mask1 + i4", set=s, heading=hd)
    for hd in range(6):
        off = 0x5600 + hd * 0x320
        px, al = decode(H, 40, 40, "i4", off)
        put(f"arrow40_{hd}", 40, 40, px, [1 if v else 0 for v in px],
            f"heading arrow {HEADINGS6[hd]} (not referenced; colour 0 made transparent)", "HDAT.PUT", off, "i4",
            heading=hd)
    stamp(H, 0x68C0, 4, "stamp_dither", "dither fill; 0xBB5D default (bx = 0, never passed)", "HDAT.PUT")
    for off, nm, wh in ((0x6940, "stamp_box", "thin square"), (0x69C0, "stamp_box2", "square frame"),
                        (0x6A40, "stamp_cross", "crosshair circle"), (0x6AC0, "stamp_x", "X")):
        stamp(H, off, 7, nm, wh + " (not referenced)", "HDAT.PUT")
    for hd in range(6):
        stamp(H, 0x6B40 + hd * 0x80, 4, f"stamp_arrow_{hd}",
              f"path arrow, heading {HEADINGS6[hd]} (0xBB5D bl = 0x80 | heading)", "HDAT.PUT", heading=hd)
    stamp(U, 0x3820, 4, "mark_ship", "brackets: reachable cell / own ship to pick (0xBB5D bl 1, 2)", "DATA1[14]")
    stamp(U, 0x38A0, 6, "mark_fire", "enemy in gun range (0xBB5D bl 3, from 0xA24E)", "DATA1[14]")
    stamp(U, 0x3920, 3, "mark_board", "enemy adjacent: boarding (0xBB5D bl 4, from 0xA24E)", "DATA1[14]")
    for k in range(4):
        off = 0x6E40 + k * 0x280
        px, al = masked(H, off, 32, 32)
        put(f"hit_{k}", 32, 32, px, al, f"volley burst frame {k} (0xCAFB)", "HDAT.PUT", off, "mask1 + i4", frame=k)
    for k in range(4):
        off = 0x7840 + k * 0xC8
        px, al = masked(H, off, 16, 20)
        put(f"splash_{k}", 16, 20, px, al, f"water spout frame {k}, drawn at (+0 or +16, +12) (0xCAFB)",
            "HDAT.PUT", off, "mask1 + i4", frame=k)
    px, al = masked(H, 0x7B60, 8, 8)
    put("ball", 8, 8, px, al, "cannonball in flight (0xC583)", "HDAT.PUT", 0x7B60, "mask1 + i4")
    for k in range(4):
        off = 0x2E20 + k * 0x280
        px, al = masked(U, off, 32, 32, mask_first=False)
        put(f"board_{k}", 32, 32, px, al, f"boarding melee frame {k} (0xCEF6)", "DATA1[14]", off, "i4 + mask1",
            frame=k)
    for hd in range(6):
        k = (15 * hd - hd // 3) // 10
        off = 0x490 + k * 0x320
        px, al = decode(U, 40, 40, "i4", off)
        put(f"wind_{hd}", 40, 40, px, al, f"wind dial needle toward {HEADINGS6[hd]} (0xC2B6, dial frame {k})",
            "DATA1[14]", off, "i4", heading=hd, dialFrame=k)
    g, offs = graph_dat(ctx)
    for n, nm, wh in ((26, "panel", "side panel at (416,0) (0xC2B6)"),
                      (53, "result_53", "result: enemy flagship taken / duel won (codes 4, 6, 8)"),
                      (54, "result_54", "result: enemy withdrew or we fled / surrendered (codes 2, 3, 9)"),
                      (55, "result_55", "result: sunset draw (code 1)"),
                      (56, "result_56", "result: defeat (codes 5, 7)")):
        w, h, px, _ = K.decode_rle4(g, offs[n])
        put(nm, w, h, px, [1] * (w * h), wh, "GRAPH.DAT", n, "GRAPH.DAT picture", graph=n)
    return {
        "palette": {"ds": f"0x{BATTLE_PAL:X}", "rgb": pal},
        "cycle": {"table": f"0x{CYCLE_TABLE:X}", "colours": cycled, "ticksPerStep": 17, "timerHz": 18.2,
                  "phases": [[p[i] for i in cycled] for p in phases],
                  "note": "palette phase k: colours 8..15 from the table; files with cyclePhases have _p1.._p3 copies"},
        "geometry": {"cell": [32, 32], "view": [13, 12], "mapOrigin": [0, 0], "oddColumnDown": 16,
                     "cellToScreen": "x = 32*(cx - [0xA4FD]); y = 32*(cy - [0xA4FE]) + (cx odd ? 16 : 0)",
                     "minimap": {"origin": [424, 8], "cell": [4, 4], "size": [208, 192], "background": 5,
                                 "land": 0, "dots": {"own": 7, "ally": 6, "enemy": 2, "enemyReinforcement": 3},
                                 "dot": [".XX.", "XXXX", "XXXX", ".XX."]},
                     "windDial": [440, 230], "messageBox": [424, 328, 192, 56]},
        "coast": {f"{c:#x}": m for c, m in COAST.items()},
        "files": files,
    }


# ---------------------------------------------------------------------------------------------------------------
# duel: IAP1..6.LZW, IAE1.LZW, DATA1[0..3], GRAPH.DAT 23/24

BOX_W, BOX_H = 192, 120          # [0xC12] composition buffer, shown at screen (8*(0x17+k), 176)
DUEL_GROUPS = ["stance", "attack thrust 찌른다", "attack slash 벤다", "attack strike 친다",
               "defend parry 걷어낸다", "defend counter 맞받는다", "defend dodge 비킨다"]
STANCE_FRAMES = ["ready A", "ready B", "hit", "down", "victory A", "victory B"]
WEAPON_TYPES = ["검", "스트레이트", "커브", "헤비"]       # duel struct +2 (battle.md §12)


def ia_frames(e):
    """-> [(x, y, w, h, offset)] from an IA*.LZW entry."""
    n = struct.unpack_from(">I", e, 4)[0] // 8
    return [tuple(e[i * 8:i * 8 + 4]) + (struct.unpack_from(">I", e, i * 8 + 4)[0],) for i in range(n)]


def ia_strip(e):
    """All frames of one entry, each in its own 192x120 cell at its box position."""
    fr = ia_frames(e)
    W = BOX_W * len(fr)
    px, al = [0] * (W * BOX_H), [0] * (W * BOX_H)
    for k, (x, y, w, h, off) in enumerate(fr):
        p, a = decode(e, w * 8, h, "m3", off)
        for r in range(h):
            for c in range(w * 8):
                X, Y = k * BOX_W + x * 8 + c, y + r
                if a[r * w * 8 + c] and 0 <= Y < BOX_H and x * 8 + c < BOX_W:
                    px[Y * W + X], al[Y * W + X] = p[r * w * 8 + c], 1
    return W, fr, px, al


def export_duel(ctx):
    d = ctx.group("duel")
    pal = ctx.palette(BATTLE_PAL)
    files = []
    for name, actor in [(f"IAP{h}.LZW", f"hero{h - 1}") for h in range(1, 7)] + [("IAE1.LZW", "enemy")]:
        ents = ctx.ls11(name)
        assert len(ents) == 35
        for i, e in enumerate(ents):
            g, part = divmod(i, 5)
            W, fr, px, al = ia_strip(e)
            fn = f"{actor}_g{g}_{'body' if part == 0 else 'weapon%d' % (part - 1)}.png"
            save(f"{d}/{fn}", W, BOX_H, px, pal, al)
            files.append({
                "name": fn, "source": f"{name}[{i}]", "actor": actor, "group": g, "action": DUEL_GROUPS[g],
                "part": "body" if part == 0 else "weapon", "weaponType": None if part == 0 else part - 1,
                "cell": [BOX_W, BOX_H], "frames": len(fr),
                "rects": [{"x": x * 8, "y": y, "w": w * 8, "h": h} for x, y, w, h, _ in fr],
                "format": "m3", "palette": f"DS:0x{BATTLE_PAL:X}",
            })
    d1 = ctx.ls11("DATA1.LZW")
    for n, fn, w, fmt, what in [(0, "backdrop_sea.png", 384, "i4", "backdrop at sea ([0xC3A] == 0xFF)"),
                                (1, "backdrop_port.png", 384, "i4", "backdrop in port"),
                                (2, "overlay_left.png", 72, "m3", "foreground rigging, backdrop x 0..71 (sea only)"),
                                (3, "overlay_right.png", 72, "m3", "foreground rigging, backdrop x 312..383 (sea only)")]:
        px, al = decode(d1[n], w, 120, fmt)
        save(f"{d}/{fn}", w, 120, px, pal, al if fmt == "m3" else None)
        files.append({"name": fn, "source": f"DATA1.LZW[{n}]", "w": w, "h": 120, "format": fmt, "what": what,
                      "palette": f"DS:0x{BATTLE_PAL:X}"})
    g, offs = graph_dat(ctx)
    for n, fn, at, what in [(23, "screen.png", [0, 0], "duel screen (0x1230E)"),
                            (24, "screen_port.png", [80, 168], "port scenery over the window (not at sea)")]:
        w, h, px, _ = K.decode_rle4(g, offs[n])
        save(f"{d}/{fn}", w, h, px, pal)
        files.append({"name": fn, "source": f"GRAPH.DAT[{n}]", "w": w, "h": h, "at": at, "format": "rle4",
                      "what": what, "palette": f"DS:0x{BATTLE_PAL:X}"})
    return {
        "palette": {"ds": f"0x{BATTLE_PAL:X}", "rgb": pal},
        "box": {"w": BOX_W, "h": BOX_H, "screenY": 176, "screenX": "8*(23+k)", "k": "camera 0..10, see sprites.md",
                "backdropX": "8*(7+k)"},
        "groups": DUEL_GROUPS, "stanceFrames": STANCE_FRAMES, "weaponTypes": WEAPON_TYPES,
        "restOffset": {"hero": -8, "enemy": 8},
        # 0x11E80: per move row, 6 steps of (frame, offset step); frame >= 6 = frame (f-6) of the move group,
        # frame < 6 = stance frame; offset step 0 = rest, 1 = 8 px back, 2 = 16 px back. Hit: 4 steps only.
        "exchangeSteps": [
            [[6, 0], [1, 0], [7, 0], [8, 0], [0, 0], [1, 0]],
            [[6, 0], [7, 0], [8, 0], [9, 0], [0, 0], [1, 0]],
            [[6, 0], [7, 0], [8, 0], [8, 0], [0, 0], [1, 0]],
            [[1, 0], [6, 1], [7, 1], [7, 1], [8, 1], [1, 1]],
            [[1, 0], [6, 1], [7, 1], [7, 1], [8, 1], [1, 1]],
            [[6, 0], [7, 1], [7, 2], [8, 2], [8, 2], [1, 2]],
        ],
        "files": files,
    }


GROUPS = [("ships", export_ships), ("ui", export_ui), ("figureheads", export_figureheads),
          ("gambling", export_gambling), ("battle", export_battle), ("duel", export_duel)]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/assets/sprites"
    want = set(sys.argv[2:])
    ctx = Ctx(out)
    for name, fn in GROUPS:
        if want and name not in want:
            continue
        idx = fn(ctx)
        write_index(ctx, name, idx)
        print(f"{name}: {len(idx['files'])} entries")


if __name__ == "__main__":
    main()
