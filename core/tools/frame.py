#!/usr/bin/env python3
"""Frame screens of the sea and the port (docs/re/frame.md). Run with build/venv/bin/python -I.

usage: frame.py [OUT_DIR]        default assets/frame

Writes
  frame_sea_type1.png / frame_sea_type2.png     GRAPH.DAT 2 / 4 (layout option [0xC30] & 0x80 set / clear)
  frame_port_type1.png / frame_port_type2.png   GRAPH.DAT 3 / 5
  font_ascii.png    HANKAKU.FNT 0x20..0x7F, 8x16 cells, 16 per row (white on transparent)
  font_digits.png   DATA1[14] 0x24D0 digit glyphs '0'..'9' 8x16 (used instead of the ASCII digits)
  font_hangul.png   ALL_FONT.16P, 16x14 cells, 94 per row, row = lead-byte row (A1..AC, B0..C8)
  check_sea.png, check_port.png       composed screens, layout type 1 (sample state, index.json "checkRenders")
  check_sea_type2.png, check_port_type2.png   the same on the type-2 frames
  sample_faces.png, sample_message.png, sample_popup.png, sample_list.png   windows drawn by the original rules
  index.json        regions, panel fields, gauges, dials, text engine, window rules, list layouts

Everything is composed on a 640x400 canvas of palette indices, like the VGA planes, and converted with
the daylight palette DS:0xAD82 (colours 0..7 = main table 0x40ECE = every time-of-day table).
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png
import sprites as S
import portmaps as PM

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0
NEW_GAME_DS = 0xC30
W, H = 640, 400
MAIN_PAL = 0x40ECE
DAY_PAL = DS + 0xAD82
TOD_PAL = DS + 0xAD22          # + 0x30 * phase, phases 0..4
CHART_PAL = DS + 0xAF50

FRAMES = {("sea", 1): 2, ("sea", 2): 4, ("port", 1): 3, ("port", 2): 5}
MONTHS = 0x94C6                # DS: "Jan".."Dec", pointer table DS:0x94F6
WIND_DIAL, CALM_DIAL = 0x490, 0x1D90
DIGITS = 0x24D0
MORE_MARK = 0x20B0
DITHER = 0x280
CORNERS, EDGES = 0x2C20, 0x2CA0
LIST_PIECES, LIST_UP, LIST_DOWN = 0x39A0, 0x3BA0, 0x3C20
LIST_TABLE = 0x1034            # DS: 10 B per code: x col, y, w cols, rows, scroll top
SHADOW = {"right": (0xAF, 0x5F), "bottomLeft": (0xFA, 0xF5), "bottom": (0xAA, 0x55)}   # DS:0x9560/0x9550/0x9558


# --------------------------------------------------------------------------------------------- data

class Game:
    def __init__(self):
        _, self.img, _ = mzdis.load(GAME + "/MAIN.EXE")
        self.d1 = ls11.unpack(GAME + "/DATA1.LZW")
        self.ui = self.d1[14]
        seg = bytearray(self.img[DS:])
        seg[NEW_GAME_DS:NEW_GAME_DS + len(self.d1[15])] = self.d1[15]
        self.ds = bytes(seg)
        self.text = json.load(open(ROOT + "/assets/text.json"))
        self.graph = open(GAME + "/GRAPH.DAT", "rb").read()
        self.graph_offs = K.offset_table(self.graph)
        self.ascii = open(GAME + "/HANKAKU.FNT", "rb").read()
        self.hangul = self.load_hangul()

    def palette(self, addr):
        return K.bbr_table(self.img, addr)

    def picture(self, n):
        w, h, px, _ = K.decode_rle4(self.graph, self.graph_offs[n])
        return w, h, px

    def load_hangul(self):
        """ALL_FONT.16P: 30-byte records (code LE u16 = trail, lead; 14 rows x 2 bytes). Record i = glyph index i (0x4686)."""
        d = open(GAME + "/ALL_FONT.16P", "rb").read()
        glyphs = {}
        for i in range(len(d) // 30):
            code = d[i * 30 + 1] << 8 | d[i * 30]          # stored trail byte first
            hi, lo = code >> 8, code & 0xFF
            assert (hi - (0xA4 if hi >= 0xB0 else 0xA1)) * 94 + lo - 0xA1 == i, (i, hex(code))
            glyphs[code] = d[i * 30 + 2:i * 30 + 30]
        return glyphs

    def u8(self, off):
        return self.ds[off]

    def u16(self, off):
        return struct.unpack_from("<H", self.ds, off)[0]

    def cstr(self, off):
        e = self.ds.index(b"\0", off)
        return self.ds[off:e].decode("cp949")

    def msg(self, n):
        return self.text["message"][n]


# --------------------------------------------------------------------------------------------- canvas

class Canvas:
    """640x400 palette indices plus the text engine state of 0x4655 / 0x4970."""

    def __init__(self, g, w=W, h=H):
        self.g, self.w, self.h = g, w, h
        self.px = bytearray(w * h)
        self.col, self.y = 0, 0
        self.left, self.right, self.pitch = 0, 79, 24
        self.fg, self.bg = 7, 0

    # pixels -----------------------------------------------------------------------------------
    def put(self, x, y, w, h, px, alpha=None, key=None):
        for j in range(h):
            if not 0 <= y + j < self.h:
                continue
            for i in range(w):
                v = px[j * w + i]
                if (alpha is not None and not alpha[j * w + i]) or (key is not None and v == key):
                    continue
                if 0 <= x + i < self.w:
                    self.px[(y + j) * self.w + x + i] = v

    def fill(self, x1, y1, x2, y2, c):
        """Inclusive rectangle (0x219DD)."""
        for y in range(max(0, y1), min(self.h, y2 + 1)):
            for x in range(max(0, x1), min(self.w, x2 + 1)):
                self.px[y * self.w + x] = c

    def fill_cols(self, col, y, cols, rows, c):
        """0x906(x col, y, width cols, rows, colour)."""
        self.fill(8 * col, y, 8 * (col + cols) - 1, y + rows - 1, c)

    def xor_rect(self, x1, y1, x2, y2, c):
        """0x63E mode 0x1nn on the solid source: XOR colour planes (x2, y2 exclusive)."""
        for y in range(y1, y2):
            for x in range(x1, x2):
                self.px[y * self.w + x] ^= c

    def and_pattern(self, col, y, rows_bytes):
        """0x3CA mode 2 (AND) with a 1-byte-wide pattern equal on all planes: bit 0 -> colour 0."""
        for j, b in enumerate(rows_bytes):
            for i in range(8):
                if not b >> (7 - i) & 1 and 0 <= y + j < self.h:
                    self.px[(y + j) * self.w + 8 * col + i] = 0

    def stamp(self, x, y, w, h, data, off, colour):
        """1-bit stamp in one colour (0x63E mode 0x4nn)."""
        bw = (w + 7) // 8
        for j in range(h):
            for i in range(w):
                if data[off + j * bw + i // 8] >> (7 - i % 8) & 1:
                    self.px[(y + j) * self.w + x + i] = colour

    def i4(self, x, y, w, h, off, data=None):
        px, _ = S.decode(data if data is not None else self.g.ui, w, h, "i4", off)
        self.put(x, y, w, h, px)

    def tile8(self, col, y, cols, rows, off):
        """0x8A6: repeat an 8x8 i4 piece over cols x rows; pattern row = screen y & 7."""
        px, _ = S.decode(self.g.ui, 8, 8, "i4", off)
        for j in range(rows):
            r = (y + j) & 7
            for c in range(cols):
                for i in range(8):
                    self.px[(y + j) * self.w + 8 * (col + c) + i] = px[r * 8 + i]

    def rgb(self, pal):
        return b"".join(bytes(pal[v]) for v in self.px)

    def save(self, path, pal):
        png.write_png(path, self.w, self.h, self.rgb(pal))

    # text --------------------------------------------------------------------------------------
    def locate(self, col, y):
        self.col, self.y = col, y

    def margins(self, left, right):
        self.left, self.right = left, right

    def newline(self):
        if self.col != self.left:                    # 0x490E: no-op at the left margin
            self.col = self.left
            if self.y + self.pitch <= 400:
                self.y += self.pitch

    def glyph(self, code):
        """-> (cols, rows, row bytes) as fetched by 0x46BB (+ DATA1 digits, [0xC2E] = 1)."""
        if code >= 0x200:
            return 2, 14, self.g.hangul.get(code, bytes(28))
        if 0x30 <= code <= 0x39:
            o = (0x21D + code) * 16
            return 1, 16, self.g.ui[o:o + 16]
        i = code - 0x20 if 0x20 <= code <= 0x7F else 0
        return 1, 16, self.g.ascii[i * 16:i * 16 + 16]

    def putc(self, code):
        cols, rows, bits = self.glyph(code)
        if self.col > (77 if cols == 2 else 78):
            self.newline()
        x0 = 8 * self.col
        for j in range(rows):
            for i in range(8 * cols):
                on = bits[j * cols + i // 8] >> (7 - i % 8) & 1
                if on:
                    self.px[(self.y + j) * self.w + x0 + i] = self.fg
                elif self.bg:
                    self.px[(self.y + j) * self.w + x0 + i] = self.bg
        self.col += cols
        if self.col > self.right:
            self.newline()

    def puts(self, s):
        """Printf output: EUC-KR text with ESC C/B/R/= and CR/LF handling of 0x4970."""
        b = s.encode("cp949") if isinstance(s, str) else s
        i = 0
        while i < len(b):
            c = b[i]
            if c == 0x1B:
                op, a = chr(b[i + 1]), b[i + 2]
                if op == "C":
                    self.fg = a - 0x30
                elif op == "B":
                    self.bg = a - 0x30
                elif op == "R":
                    self.left = a - 0x20
                elif op == "=":
                    self.y, self.col = (a - 0x20) * 8, b[i + 3] - 0x20
                    i += 1
                i += 3
            elif 0xA1 <= c <= 0xC8 and i + 1 < len(b):
                self.putc(c << 8 | b[i + 1])
                i += 2
            elif c == 0x0A:
                self.newline()
                i += 1
            elif c == 0x0D:
                self.col = self.left
                i += 1
            else:
                self.putc(c)
                i += 1

    def text(self, x, y, s, fg=0, bg=7):
        self.fg, self.bg = fg, bg
        self.locate(x // 8, y)
        self.puts(s)

    # panel pieces ----------------------------------------------------------------------------
    def gauge(self, col, y, v):
        """0x913F with colours 0x91BE(2, 1): 50x4 px bar at x 8col+10."""
        v = max(0, min(100, v)) // 2
        x = 8 * col + 10
        if v:
            self.fill(x, y + 2, x + v - 1, y + 5, 2)
        if v != 50:
            self.fill(x + v, y + 2, 8 * col + 0x3B, y + 5, 1)

    def dial(self, y, d, force):
        """0x8D97(y, dir, force): 40x40 dial at (568, y); calm when force 0 or dir >= 8; force at (536, y+24)."""
        off = CALM_DIAL if force == 0 or d >= 8 else WIND_DIAL + 0x320 * d
        self.i4(568, y, 40, 40, off)
        if force >= 0:
            self.text(536, y + 24, "%d" % force)

    # windows ---------------------------------------------------------------------------------
    def frame_window(self, col, y, cols, style, h):
        """0x71FA: corners, style edges, interior colour 7; returns the text cursor (col+1, y+8)."""
        e = EDGES + 0x80 * style
        self.i4(8 * col, y, 8, 8, CORNERS)
        self.tile8(col + 1, y, cols - 2, 8, e)
        self.i4(8 * (col + cols - 1), y, 8, 8, CORNERS + 0x20)
        self.tile8(col, y + 8, 1, h - 16, e + 0x20)
        self.fill_cols(col + 1, y + 8, cols - 2, h - 16, 7)
        self.tile8(col + cols - 1, y + 8, 1, h - 16, e + 0x40)
        self.i4(8 * col, y + h - 8, 8, 8, CORNERS + 0x40)
        self.tile8(col + 1, y + h - 8, cols - 2, 8, e + 0x60)
        self.i4(8 * (col + cols - 1), y + h - 8, 8, 8, CORNERS + 0x60)
        self.margins(col + 1, col + cols - 2)
        self.text(8 * (col + 1), y + 8, "")

    def message_window(self, col, y, cols, style, h):
        """0x76EB -> 0x761B: frame, 4-px checker drop shadow, margins col+2..col+cols-3, cursor (col+2, y+16)."""
        self.frame_window(col, y, cols, style, h)
        for i in range(h // 2):
            self.and_pattern(col + cols, y + 4 + 2 * i, SHADOW["right"])
        for k in range(2):
            self.and_pattern(col, y + h + 2 * k, SHADOW["bottomLeft"])
            for c in range(1, cols):
                self.and_pattern(col + c, y + h + 2 * k, SHADOW["bottom"])
        self.margins(col + 2, col + cols - 3)
        self.text(8 * (col + 2), y + 16, "")

    def face_window(self, col, y, kao=None):
        """0x7C45: 0x71FA(col, y, 39, 0, 144), portrait at (col+2, y+16), text col+11..col+36 from y+16."""
        self.frame_window(col, y, 39, 0, 144)
        if kao is not None:
            px = K.planar_bytes(kao, 64, 80, 3)
            self.put(8 * (col + 2), y + 16, 64, 80, px)
        self.margins(col + 11, col + 36)
        self.text(8 * (col + 11), y + 16, "")

    def more_mark(self):
        """0x140EA: the key-wait marker, colour 2, mid column, this line or 24 px lower."""
        col = min(78, self.left + (self.right - self.left) // 2)
        y = min(0x180, self.y if self.col == self.left else self.y + 24)
        self.stamp(8 * col, y, 16, 16, self.g.ui, MORE_MARK, 2)

    def popup(self, col, y, items, sel=None, disabled=()):
        """0x13CA3: 0x76EB(col, y, mw+4, 0, 24(n+1)); centred items every 24 px; XOR-7 highlight; dither greys."""
        widths = [len(s.encode("cp949")) for s in items]
        mw = max(widths)
        self.message_window(col, y, mw + 4, 0, 24 * (len(items) + 1))
        self.margins(col + 2, col + mw + 1)
        rects = []
        for i, s in enumerate(items):
            yy = y + 16 + 24 * i
            self.text(8 * (col + 2 + (mw - widths[i]) // 2), yy, s)
            if i in disabled:
                for c in range(mw):
                    self.stamp(8 * (col + 2 + c), yy, 8, 16, self.g.ui, DITHER, 7)
            rects.append((8 * (col + 1), yy, 8 * (col + mw + 3), yy + 16))
        if sel is not None:
            self.xor_rect(*rects[sel], 7)
        return rects

    def list_window(self, code, rows_text, header, sel=None):
        """0x147E0 + 0x153BF: list window of layout `code` (DS:0x1034)."""
        x, y, w, r, _ = struct.unpack_from("<5h", self.g.ds, LIST_TABLE + 10 * code)
        h = 16 * r + 40
        self.fill_cols(x, y, w + 4, h, 7)
        P = lambda k: LIST_PIECES + 0x20 * k
        self.i4(8 * x, y, 8, 8, P(0))
        for i in range(w + 2):
            self.i4(8 * (x + 1 + i), y, 8, 8, P(1))
        self.i4(8 * (x + w + 3), y, 8, 8, P(2))
        for s in range(0, h - 16, 8):
            self.i4(8 * x, y + 8 + s, 8, 8, P(3))
        self.i4(8 * (x + w + 3), y + 8, 8, 8, P(4))
        self.i4(8 * x, y + 16, 8, 8, P(5))
        for i in range(w + 2):
            self.i4(8 * (x + 1 + i), y + 16, 8, 8, P(6))
        self.i4(8 * (x + w + 3), y + 16, 8, 8, P(7))
        self.i4(8 * x, y + 24, 8, 8, P(8))
        for i in range(w):
            self.i4(8 * (x + 1 + i), y + 24, 8, 8, P(9))
        self.i4(8 * (x + w + 1), y + 24, 8, 8, P(10))
        for s in range(0, h - 40, 8):
            self.i4(8 * (x + w + 1), y + 32 + s, 8, 8, P(11))
        self.i4(8 * x, y + h - 8, 8, 8, P(12))
        for i in range(w):
            self.i4(8 * (x + 1 + i), y + h - 8, 8, 8, P(6))
        self.i4(8 * (x + w + 1), y + h - 8, 8, 8, P(13))
        for s in range(0, h - 56, 8):
            self.i4(8 * (x + w + 2), y + 40 + s, 8, 8, P(14))
            self.i4(8 * (x + w + 3), y + 40 + s, 8, 8, P(15))
        self.i4(8 * (x + w + 2), y + 24, 16, 16, LIST_UP)
        self.i4(8 * (x + w + 2), y + h - 16, 16, 16, LIST_DOWN)
        hw = len(header.encode("cp949"))
        self.margins(x + 1, x + w + 4)
        self.text(8 * (x + (w + 2 - hw + 2) // 2), y + 4, header)
        for i, s in enumerate(rows_text[:r]):
            self.text(8 * (x + 1), y + 32 + 16 * i, s)
        if sel is not None:
            self.xor_rect(8 * (x + 1), y + 32 + 16 * sel, 8 * (x + 1 + w), y + 48 + 16 * sel, 7)
        return {"x": 8 * x, "y": y, "w": 8 * (w + 4), "h": h}


# --------------------------------------------------------------------------------------------- exports

def export_frames(g, out):
    pal = g.palette(MAIN_PAL)
    res = {}
    for (screen, t), n in sorted(FRAMES.items()):
        w, h, px = g.picture(n)
        used = sorted(set(px))
        assert (w, h) == (W, H) and max(used) <= 7, (n, used)
        name = f"frame_{screen}_type{t}.png"
        png.write_png(f"{out}/{name}", w, h, b"".join(bytes(pal[v]) for v in px))
        res.setdefault(screen, {})[f"type{t}"] = {"file": name, "graph": n, "coloursUsed": used}
    return res


def glyph_png(path, cells, cw, ch, per_row, cols):
    """cells: list of (cols, rows, bytes) 1-bit glyphs -> white on transparent atlas."""
    n = len(cells)
    rows_n = (n + per_row - 1) // per_row
    iw, ih = per_row * cw, rows_n * ch
    out = bytearray(iw * ih * 4)
    for k, (gc, gr, bits) in enumerate(cells):
        ox, oy = (k % per_row) * cw, (k // per_row) * ch
        for j in range(gr):
            for i in range(8 * gc):
                if bits[j * gc + i // 8] >> (7 - i % 8) & 1:
                    p = ((oy + j) * iw + ox + i) * 4
                    out[p:p + 4] = b"\xff\xff\xff\xff"
    png.write_png(path, iw, ih, bytes(out))
    return iw, ih


def export_fonts(g, out):
    glyph_png(f"{out}/font_ascii.png", [(1, 16, g.ascii[i * 16:i * 16 + 16]) for i in range(96)], 8, 16, 16, 1)
    glyph_png(f"{out}/font_digits.png", [(1, 16, g.ui[DIGITS + 16 * d:DIGITS + 16 * d + 16]) for d in range(10)],
              8, 16, 10, 1)
    rows = list(range(0xA1, 0xAD)) + list(range(0xB0, 0xC9))
    cells = [(2, 14, g.hangul.get(hi << 8 | lo, bytes(28))) for hi in rows for lo in range(0xA1, 0xFF)]
    iw, ih = glyph_png(f"{out}/font_hangul.png", cells, 16, 14, 94, 2)
    return {
        "ascii": {"file": "font_ascii.png", "source": "HANKAKU.FNT", "cell": [8, 16], "perRow": 16, "first": 32,
                  "count": 96, "note": "glyph of byte c at index c-0x20; other bytes -> index 0 (space)"},
        "digits": {"file": "font_digits.png", "source": "DATA1.LZW[14] 0x24D0 + 16*d", "cell": [8, 16],
                   "note": "'0'..'9' are always drawn with these ([0xC2E] = 1 after start-up)"},
        "hangul": {"file": "font_hangul.png", "source": "ALL_FONT.16P (30-byte records: code u16 LE (trail byte first), 14 rows x 2 B)",
                   "cell": [16, 14], "perRow": 94, "size": [iw, ih], "leadRows": rows,
                   "index": "row = position of the lead byte in leadRows, column = trail - 0xA1 (EUC-KR / KS X 1001)"},
        "rule": "ASCII cells 8x16, EUC-KR cells 16x14 drawn at the same y; with a background colour != 0 the "
                "cell is opaque (fg on bits, bg elsewhere), bg 0 = transparent",
    }


# --------------------------------------------------------------------------------------------- field tables

def sea_fields():
    F = lambda i, x, y, fmt, src, redraw, **k: dict(screen="sea", id=i, x=x, y=y, format=fmt, fg=0, bg=7,
                                                     source=src, redraw=redraw, **k)
    every, panel = "every sea frame (0x6D03)", "0x7F00 events"
    f = [
        F("year", 536, 16, "%2d", "1501 + [0x56E]", every, routine="0x7053"),
        F("month", 576, 16, "%s", "DS:0x94F6[[0x56F]] Jan..Dec", every, routine="0x706C"),
        F("day", 608, 16, "%2d", "[0x570] + 1", every, routine="0x7096"),
        F("windForce", 536, 88, "%d", "[0xC3D] & 7", every, routine="0x8D97"),
        F("currentForce", 536, 136, "%d", "[0xC3E] & 7", every, routine="0x8D97"),
        F("speedKnots", 552, 208, "%2d", "([0xC15C] + 1) / 2", every, routine="0x6E42"),
        F("daysAtSea", 552, 240, "%3d", "[0x2D54]", panel, routine="0x82C4"),
        F("water", 48, 264, "%5d", "sum cargo +0 / 10", panel),
        F("food", 48, 296, "%5d", "sum cargo +2 / 10", panel),
        F("lumber", 48, 328, "%5d", "sum cargo +4", panel),
        F("shot", 48, 360, "%5d", "sum cargo +6", panel),
    ]
    dials = [
        {"id": "wind", "x": 568, "y": 64, "dir": "([0xC3D] >> 3) & 7", "force": "[0xC3D] & 7", "forceAt": [536, 88]},
        {"id": "current", "x": 568, "y": 112, "dir": "([0xC3E] >> 3) & 7", "force": "[0xC3E] & 7", "forceAt": [536, 136]},
        {"id": "heading", "x": 568, "y": 160, "dir": "player fleet +0x1A (8 = none)", "force": None, "forceAt": None},
    ]
    gauges = [
        {"id": "rudder", "labels": ["Rudder", "선회력"], "y": 72, "value": "slowest ship slot +4 (raw)"},
        {"id": "sails", "labels": ["Sails", "추진력"], "y": 96, "value": "slowest ship slot +5 (raw)"},
        {"id": "hull", "labels": ["Hull", "내구도"], "y": 120, "value": "min slot +2 over ships (start 100)"},
        {"id": "draft", "labels": ["Draft", "흘수"], "y": 144, "value": "100 * cargo(slowest)+0xA / class(+6) capacity"},
        {"id": "range", "labels": ["Range", "감시범위"], "y": 168, "value": "100 * [0xC176] / 24"},
        {"id": "crew", "labels": ["Crew", "승무원"], "y": 192, "value": "100 * sum crew / sum ship +0x15"},
        {"id": "condition", "labels": ["Con.", "컨디션"], "y": 216, "value": "sum(crew * cargo+0x1C) / sum crew"},
    ]
    return f, dials, gauges


def port_fields():
    F = lambda i, x, y, fmt, src, **k: dict(screen="port", id=i, x=x, y=y, format=fmt, fg=0, bg=7, source=src,
                                            redraw="0x86F2 events", **k)
    return [
        F("year", 48, 16, "15%2d", "[0x56E] + 1 (1501..1509 print '15 n')"),
        F("monthDay", 24, 40, "%s.%2d", "DS:0x94F6[[0x56F]], [0x570] + 1"),
        F("clock", 8, 144, "%2d:%02d %c.M", "h = (tick/3 + 11) % 12 + 1, m = 20 * (tick % 3), A if tick < 36 else P"),
        F("fame", 48, 248, "%5u", "max(family[[0x1241]] +0, +2, +4)"),
        F("goldCoins", 40, 320, "%5d", "gold DS:0x123A % 10000"),
        F("goldIngots", 40, 360, "%5u", "gold / 10000", note="after \\n: left margin col 5, pitch 40"),
        F("region", 488, 8, "msg 385 + market +0x21, msg 1135", "market ports < 100; supply ports msg 1136"),
        F("portName", 488, 24, "msg 1137 '\\n%s항'", "port record +4", clear=[488, 24, 144, 16, 7]),
        F("economy", 560, 96, "%5d", "market +0", marketOnly=True),
        F("economyInvestment", 560, 128, "%5u", "market +2", marketOnly=True),
        F("industry", 560, 160, "%5d", "market +4", marketOnly=True),
        F("industryInvestment", 560, 192, "%5u", "market +6", marketOnly=True),
        F("priceIndex", 560, 224, "%4d", "sum market[+0xE..+0x17] / 10 + 50 (0x1AE1E)", marketOnly=True),
    ]


def month(g, m):
    return g.cstr(g.u16(0x94F6 + 2 * m))


# --------------------------------------------------------------------------------------------- check renders

def sea_view(c, fx, fy):
    """24x24 chips around a fleet tile (view origin = fleet - 11), daylight, known ports shown."""
    idx = json.load(open(ROOT + "/assets/seamap/index.json"))
    chips = open(ROOT + "/assets/seamap/chips.bin", "rb").read()
    atlas = open(ROOT + "/assets/seamap/chips_indexed.bin", "rb").read()
    over = {}
    known = set(idx["newGameKnownPorts"])
    for m in idx["markers"]:
        if m["kind"] in ("port", "supply") and m["id"] in known | {0}:
            for k, ch in enumerate(m["chips"]):
                over[(m["x"] + k % 2, m["y"] + k // 2)] = ch
    ox, oy = fx - 11, fy - 11
    for ty in range(24):
        for tx in range(24):
            x, y = ox + tx, oy + ty
            ch = over.get((x, y), chips[y * 2160 + x % 2160])
            c.put(96 + 16 * tx, 8 + 16 * ty, 16, 16, atlas[ch * 256:ch * 256 + 256])
    return ox, oy, chips


def check_sea(g, out, pal, t=1):
    c = Canvas(g)
    w, h, px = g.picture(FRAMES[("sea", t)])
    c.put(0, 0, w, h, px)
    # fleet west of Lisbon (port 0 at 120,358) on a free 2x2 of open sea
    fy = 358
    chips = open(ROOT + "/assets/seamap/chips.bin", "rb").read()
    fx = next(x for x in range(118, 90, -1)
              if all(chips[(fy + j) * 2160 + x + i] == 0 for i in (0, 1) for j in (0, 1)))
    sea_view(c, fx, fy)
    heading = 2                                                   # E
    off = 0x4000 + 0x1000 + 0x400 * g.u8(0x9526 + heading)        # sail-only player sprite, frame 0
    spx, sal = S.decode_w3(g.d1[11], 32, 32, off)
    c.put(96 + 16 * 11, 8 + 16 * 11, 32, 32, spx, sal)
    st = dict(year=21, month=0, day=0, windDir=1, windForce=3, curDir=4, curForce=1, heading=heading,
              speed=17, days=5, rudder=40, sails=60, hull=100, draft=35, range=100 * 8 // 24, crew=90,
              condition=100, water=400, food=400, lumber=10, shot=20)
    c.text(536, 16, "%2d" % (1501 + st["year"]))
    c.text(576, 16, month(g, st["month"]))
    c.text(608, 16, "%2d" % (st["day"] + 1))
    c.dial(64, st["windDir"], st["windForce"])
    c.dial(112, st["curDir"], st["curForce"])
    c.dial(160, st["heading"], -1)
    c.text(552, 208, "%2d" % ((st["speed"] + 1) // 2))
    for y, k in zip((72, 96, 120, 144, 168, 192, 216), ("rudder", "sails", "hull", "draft", "range", "crew", "condition")):
        c.gauge(2, y, st[k])
    for i, k in enumerate(("water", "food")):
        c.text(48, 264 + 32 * i, "%5d" % (st[k] // 10))
    for i, k in enumerate(("lumber", "shot")):
        c.text(48, 328 + 32 * i, "%5d" % st[k])
    c.text(552, 240, "%3d" % st["days"])
    name = "check_sea.png" if t == 1 else "check_sea_type2.png"
    c.save(f"{out}/{name}", pal)
    return {"file": name, "frame": FRAMES[("sea", t)], "fleetTile": [fx, fy], "state": st,
            "note": "sample values (not a saved game); view = seamap chips.bin, daylight palette"}


def char_frame(d, f):
    """CHAR.LZW frame f -> 32x32 (indices, alpha), town_walk.md §1."""
    px, al = [0] * 1024, [1] * 1024
    for q in range(4):
        o = f * 0x280 + q * 0xA0
        for y in range(16):
            for x in range(16):
                i, b = o + y * 2 + x // 8, 7 - x % 8
                p = (16 * (q // 2) + y) * 32 + 16 * (q % 2) + x
                if d[i + 128] >> b & 1:
                    al[p] = 0
                else:
                    px[p] = sum((d[i + 32 * k] >> b & 1) << k for k in range(4))
    return px, al


def check_port(g, out, pal, t=1):
    port = 0
    c = Canvas(g)
    w, h, px = g.picture(FRAMES[("port", t)])
    c.put(0, 0, w, h, px)
    maps = ls11.unpack(GAME + "/PORTMAP.LZW")
    sets = ls11.unpack(GAME + "/PORTCHIP.LZW")
    s = open(GAME + "/CHIP_NO.DAT", "rb").read()[port]
    chips = [PM.chip_rows(sets[2 * s], k * 128) for k in range(len(sets[2 * s]) // 128)]
    za = open(GAME + "/ZA_DAT.DAT", "rb").read()
    dx, dy = za[port * 24 + 6], za[port * 24 + 7]                   # door 3 = harbour office
    cx, cy = max(0, min(72, dx - 12)), max(0, min(72, dy - 13))
    tiles = maps[port]
    for ty in range(24):
        for tx in range(24):
            rows = chips[tiles[(cy + ty) * 96 + cx + tx]]
            c.put(96 + 16 * tx, 8 + 16 * ty, 16, 16, b"".join(rows))
    hero = ls11.unpack(GAME + "/CHAR.LZW")[0]
    hpx, hal = char_frame(hero, 2 * 2)                               # facing down, step 0
    c.put(96 + 16 * (dx - cx), 8 + 16 * (dy + 1 - cy), 32, 32, hpx, hal)
    # panel 0x84FD: market and port name from the new-game data segment; date, gold, fame are samples
    # (the new-game code fills them in later: DATA1[15] has year 0 = 1501, which the port prints as "15 1")
    year, mon, day, tick = 21, 0, 0, 24
    gold, fame = 12345, 350
    mk = 0x697C + 37 * port
    vals = dict(economy=g.u16(mk), economyInvestment=g.u16(mk + 2), industry=g.u16(mk + 4),
                industryInvestment=g.u16(mk + 6), priceIndex=sum(g.ds[mk + 0xE:mk + 0x18]) // 10 + 50)
    name = g.cstr(0x5F54 + 20 * port + 4)
    c.text(48, 16, "15%2d" % (year + 1))
    c.text(24, 40, "%s.%2d" % (month(g, mon), day + 1))
    c.text(8, 144, "%2d:%02d %c.M" % ((tick // 3 + 11) % 12 + 1, 20 * (tick % 3), "A" if tick < 36 else "P"))
    c.pitch = 40
    c.margins(5, 79)
    c.text(48, 248, "%5u" % fame)
    c.text(40, 320, "%5d\n%5u" % (gold % 10000, gold // 10000))
    c.pitch = 16
    c.margins(0x3D, 79)
    c.text(488, 8, g.msg(385 + g.u8(mk + 0x21)) + g.msg(1135))
    c.fill_cols(0x3D, 24, 18, 16, 7)
    c.puts(g.msg(1137).replace("%s", name))
    c.pitch = 32
    c.margins(0x46, 79)
    c.text(560, 96, "%5d\n%5u\n%5d\n%5u\n%4d" % tuple(vals.values()))
    c.pitch = 24
    name = "check_port.png" if t == 1 else "check_port_type2.png"
    c.save(f"{out}/{name}", pal)
    return {"file": name, "frame": FRAMES[("port", t)], "port": port, "camera": [cx, cy], "hero": [dx, dy + 1],
            "state": dict(year=year, month=mon, day=day, tick=tick, gold=gold, fame=fame, region=g.u8(mk + 0x21), **vals),
            "note": "market / port from the new-game data segment (DATA1[15] over DS:0xC30); date 1522-01-01, tick 24 "
                    "= 08:00, gold 12345 and fame 350 are samples; day palette"}


def samples(g, out, pal):
    """Windows drawn by the original rules over the sea frame (map window filled with colour 9)."""
    kao = ls11.unpack(GAME + "/KAO.LZW")
    w, h, px = g.picture(2)

    def base():
        c = Canvas(g)
        c.put(0, 0, w, h, px)
        c.fill(96, 8, 479, 391, 9)
        return c

    # face windows 0x7D71 (upper) / 0x7D9F (lower); speaker name = first text line
    c = base()
    c.face_window(13, 16, kao[0])
    c.puts("§조안§\n제독님, 출항 준비가 끝났습니다.")
    c.face_window(20, 192, kao[12])
    c.puts("§레온 페레로§\n조심해서 다녀오너라.")
    c.more_mark()
    c.save(f"{out}/sample_faces.png", pal)
    # plain message window with shadow, as the sea event / sighting report 0x3024A
    c = base()
    c.message_window(16, 160, 36, 0, 128)
    c.puts(g.msg(1176))
    c.more_mark()
    c.save(f"{out}/sample_message.png", pal)
    # tab popup (정보, MENU 26) right-aligned by 0x204A2, item 1 selected, item 9 disabled; frame styles 0..2
    c = base()
    items = g.text["menus"][26]
    mw = max(len(s.encode("cp949")) for s in items)
    rects = c.popup(0x4A - mw, 48, items, sel=1, disabled=(9,))
    for st in range(3):
        c.frame_window(13 + 11 * st, 296, 10, st, 64)
        c.puts("style %d" % st)
    c.save(f"{out}/sample_popup.png", pal)
    # list window, code 6 (인물명), row 2 selected
    c = base()
    names = [g.cstr(0x1242 + 50 * i) for i in range(8)]
    lw = c.list_window(6, names, g.text["menus"][47][6], sel=2)
    c.save(f"{out}/sample_list.png", pal)
    return {"files": ["sample_faces.png", "sample_message.png", "sample_popup.png", "sample_list.png"],
            "popupHotRects": rects, "listWindow": lw}


# --------------------------------------------------------------------------------------------- index

def list_layouts(g):
    heads = g.text["menus"][47]
    res = []
    for k in range(len(heads)):
        x, y, w, r, top = struct.unpack_from("<5h", g.ds, LIST_TABLE + 10 * k)
        res.append({"code": k, "header": heads[k], "xCol": x, "y": y, "wCols": w, "rows": r,
                    "rect": [8 * x, y, 8 * (w + 4), 16 * r + 40]})
    return res


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/assets/frame"
    os.makedirs(out, exist_ok=True)
    g = Game()
    pal = g.palette(DAY_PAL)
    main_pal = g.palette(MAIN_PAL)
    assert pal[:8] == main_pal[:8] and all(g.palette(TOD_PAL + 0x30 * k)[:8] == main_pal[:8] for k in range(5))
    frames = export_frames(g, out)
    fonts = export_fonts(g, out)
    sea_f, dials, gauges = sea_fields()
    index = {
        "source": "docs/re/frame.md; MAIN.EXE 0x837D/0x8AB2 (frames), 0x6D03/0x7F00/0x8E07 (sea), 0x84FD (port)",
        "canvas": [W, H],
        "palette": {
            "frames": "colours 0..7 only; identical in 0x40ECE and every DS:0xAD22+0x30k table -> no tint",
            "rgb0to7": main_pal[:8],
            "chartTint": {"palette": "DS:0xAF50 (항해도 inside the map window)", "colour3": "f4c", "colour6": "fa0"},
        },
        "layoutOption": {"byte": "[0xC30]", "bit": "0x80", "set": "type1 (default, English labels)",
                         "clear": "type2 (Korean labels)", "ui": "환경 row 2 레이아웃"},
        "frames": frames,
        "regions": {
            "both": {"mapWindow": [96, 8, 384, 384],
                     "tabs": [[616, 72 + 80 * t, 24, 80] for t in range(4)],
                     "tabHit": [[618, 72 + 80 * t, 22, 80] for t in range(4)]},
            "sea": {"statePanel": [8, 16, 80, 208], "cargoPanel": [8, 232, 80, 160], "dateScroll": [488, 8, 144, 32],
                    "navigationPanel": [488, 56, 128, 208], "wheel": [496, 272, 120, 120],
                    "wheelPieces": {"x": [496, 536, 576], "y": [272, 312, 352], "size": 32, "ref": "sprites.md §3.2"}},
            "port": {"dateScroll": [8, 8, 80, 48], "mermaid": [0, 56, 96, 168], "clockBox": [8, 142, 72, 16],
                     "userDataPanel": [8, 224, 80, 168], "portNameScroll": [488, 8, 144, 40],
                     "marketPanel": [488, 64, 128, 232], "compass": [504, 304, 96, 96],
                     "compassArrows": {"N": [528, 304], "E": [552, 336], "S": [528, 368], "W": [504, 336], "size": [40, 24]},
                     "buildingPicture": [104, 16], "keeperWindow": [240, 8, 240, 128]},
        },
        "fields": sea_f + port_fields(),
        "dials": {"size": [40, 40], "source": "DATA1.LZW[14] i4", "offset": "0x490 + 0x320*dir (N, NE, E .. NW)",
                  "calm": "0x1D90 when force == 0 or dir >= 8", "files": "assets/sprites/ui/wind_dial_*.png",
                  "needle": "points the way the wind / current blows toward", "items": dials},
        "gauges": {"xCol": 2, "x": [26, 75], "rows": "y+2 .. y+5", "length": 50, "value": "clamp(v, 0, 100) / 2 px",
                   "filledColour": 2, "emptyColour": 1, "routine": "0x913F, colours 0x91BE(2, 1)", "items": gauges},
        "text": {"defaults": {"leftCol": 0, "rightCol": 79, "pitch": 24, "fg": 7, "bg": 0},
                 "panels": "ESC C0 ESC B7: colour 0 on colour 7, opaque cells",
                 "wrap": "a glyph may start at any col <= right margin; after it col > right -> newline",
                 "newline": "only if col != left margin: col = left, y += pitch",
                 "escapes": {"C": "fg", "B": "bg (0 = transparent)", "R": "left margin = n - 0x20",
                             "=": "y = (a-0x20)*8, col = b-0x20", "F": "4/5 = black drop shadow +1,+1", "W": "wait"}},
        "fonts": fonts,
        "windows": {
            "frame": {"routine": "0x71FA(col, y, cols, style, h)", "corners": "DATA1[14] 0x2C20 TL, 0x2C40 TR, 0x2C60 BL, 0x2C80 BR",
                      "edges": "0x2CA0 + 0x80*style: top +0, left +0x20, right +0x40, bottom +0x60 (8x8, tiled, row = y & 7)",
                      "interior": 7, "textCursor": "(col+1, y+8)", "margins": "col+1 .. col+cols-2",
                      "files": "assets/sprites/ui/frame_*.png"},
            "message": {"routine": "0x76EB(col, y, cols, style, h) = save 0x5086 + 0x761B",
                        "textCursor": "(col+2, y+16)", "margins": "col+2 .. col+cols-3",
                        "shadow": {"offset": [4, 4], "thickness": 4, "op": "AND with 50% checkerboard (pixels -> colour 0)",
                                   "right": "col+cols, rows y+4..y+h+3, left 4 px", "bottom": "rows y+h..y+h+3, x 8col+4 .. 8(col+cols)-1"},
                        "common": [{"use": "sea events / reports / talk", "rect": [128, 160, 288, 128], "style": 0},
                                   {"use": "battle and reports", "rect": [160, 128, 240, 96], "style": 0},
                                   {"use": "fleet organisation prompts", "rect": [160, 64, 240, 72], "style": 0},
                                   {"use": "voyage log", "rect": [120, 32, 336, 320], "style": 0}],
                        "keyWait": {"stamp": "DATA1[14] 0x20B0 16x16 1-bit", "colour": 2, "blink": "4 ticks on / 4 off",
                                    "x": "8 * (left + (right-left)/2)", "y": "cursor y if at left margin else +24, max 384"}},
            "face": {"routine": "0x7C45(col, y): 0x71FA(col, y, 39, 0, 144), no shadow",
                     "portrait": "(8(col+2), y+16) 64x80", "text": "cols col+11 .. col+36 from y+16",
                     "upper": {"rect": [104, 16, 312, 144], "portrait": [120, 32], "text": [192, 32], "routine": "0x7D71 / 0x7C8E"},
                     "lower": {"rect": [160, 192, 312, 144], "portrait": [176, 208], "text": [248, 208],
                               "routine": "0x7D9F / 0x7CAE / 0x7CCE / 0x7D45"},
                     "bottom": {"rect": [96, 288, 376, 104], "portrait": [112, 300], "text": [184, 296], "routine": "0x7CF9"},
                     "speakerName": "first text line '§name§' + newline, same colours (msg 1134 '§%s§' for 0x7CF9/0x7D45)"},
            "popup": {"routine": "0x13CA3(col, y, n, cancellable, items)", "window": "0x76EB(col, y, mw+4, 0, 24(n+1))",
                      "item": "centred: col+2+(mw-width)/2, y+16+24i", "hot": "(8(col+1), y+16+24i) - (8(col+mw+3), +16)",
                      "highlight": "XOR colour 7 on the hot rect", "disabled": "AA55 dither stamped in colour 7",
                      "tabMenus": "0x204A2: col = 0x4A - mw (right-aligned at x 592+)"},
            "list": {"routine": "0x153BF(code, n) -> 0x147E0", "rect": "(8x, y, 8(w+4), 16r+40)",
                     "pieces": "DATA1[14] 0x39A0 + 0x20k (assets/sprites/ui/list_piece_NN.png), buttons 0x3BA0 / 0x3C20",
                     "header": "MENU 47[code] centred over w+2 cols at y+4", "rows": "(8(x+1), y+32+16i), width 8w"},
            "listLayouts": list_layouts(g),
        },
    }
    index["checkRenders"] = {"sea": check_sea(g, out, pal), "port": check_port(g, out, pal),
                             "seaType2": check_sea(g, out, pal, 2), "portType2": check_port(g, out, pal, 2),
                             "samples": samples(g, out, pal)}
    with open(f"{out}/index.json", "w") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    print("wrote", out, sorted(os.listdir(out)))


if __name__ == "__main__":
    main()
