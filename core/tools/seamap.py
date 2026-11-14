#!/usr/bin/env python3
"""Sea-view world chips, exactly as MAIN.EXE builds them (docs/re/seamap.md).

usage: build/venv/bin/python -I tools/seamap.py [OUT] [--check-all]     (OUT default assets/seamap)

Writes
  atlas_p{0..4}.png       128 world chips (DATA1[11] 0..0x3FFF) as a 16x8 sheet, one per palette phase
  p{0..4}/chip_XX.png     the same chips one by one (16x16 RGB)
  chips_indexed.bin       128 x 256 colour indices (0..15), chip-major, row-major: palette-free atlas
  chips.bin               2160x1080 bytes, chip index per world tile, row-major (y*2160 + x); ports and
                          villages in their *hidden* state (land); `markers` in index.json reveal them
  index.json              palettes, phase table, chip classes, markers, windowOverrides, histogram
  view_lisbon.png         the 24x24-tile sea view (384x384) around 리스본 at noon, new-game port flags
  view_lisbon_phases.png  the same view in palette phases 0..4 side by side
  world.png               2160x1080, 1 px per tile = mean chip colour (day palette), all markers revealed
index.json "windowOverrides" re-runs the game's own 72x72 window build (0x22734) for every window holding a
0x59 chip and lists the tiles the view can show that differ from chips.bin; --check-all simulates all 3612
windows (proves the others never differ).
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png, worldmap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0
NEW_GAME_DS = 0xC30            # DATA1[15] = DS:0xC30.. at a new game (port and site flags live there)
W, H, THIRD = 2160, 1080, 720
PAL_BASE = 0xAD22              # DS: 5 palettes x 0x30 (B,R,G 0..15); phase 4 = sea fog
PHASE_TABLE = 0xAD1A           # DS: phase = table[tick / 12], 72 ticks a day
PORTS, SITES = 0x5F54, 0x7E88  # DS: 20-byte port records (+0x13 & 0x10 known), 7-byte sites (+6 & 0x40 seen)
LAND_FLAG, KEEP = 0x29, 0x59   # 0x219F8: chip >= 0x29 counts as land; chips >= 0x59 are left alone


def chip_pixels(d, k):
    """16x16 chip k: four sequential 32-byte planes, rows big-endian u16, MSB = left pixel."""
    o = k * 128
    t = [0] * 256
    for p in range(4):
        for y in range(16):
            v = d[o + p * 32 + y * 2] << 8 | d[o + p * 32 + y * 2 + 1]
            for x in range(16):
                t[y * 16 + x] |= ((v >> (15 - x)) & 1) << p
    return t


def lat_offset(block_row):
    """Band offset of a 24-tile block row (0x219F8 / 0x22734): 0 for rows 14..30, 0x10 for 0 and 44, else 8."""
    if block_row in (0, 44):
        return 0x10
    return 0 if 14 <= block_row <= 30 else 8


class World:
    def __init__(self):
        _, self.img, _ = mzdis.load(GAME + "/MAIN.EXE")
        d1 = ls11.unpack(GAME + "/DATA1.LZW")
        self.chipdata, self.autotile_table, self.hash, self.cell_chips = d1[11], d1[10], d1[12], d1[18]
        seg = bytearray(self.img[DS:DS + 0x10000])
        seg[NEW_GAME_DS:NEW_GAME_DS + len(d1[15])] = d1[15]
        self.ds = bytes(seg)
        self.cells, bad = worldmap.decode_world(GAME, self.img)
        assert bad == 0

    # ---- port / site lookup (0x2242D / 0x22486: hash (x + y) % 255, probe +19, DATA1[12]) -------------
    def lookup(self, x, y, sites):
        rec, size, base = (SITES, 7, 0x100) if sites else (PORTS, 20, 0)
        h = (x + y) % 255
        for _ in range(255):
            i = self.hash[base + h]
            if i == 0xFF:
                return None
            if struct.unpack_from("<HH", self.ds, rec + size * i) == (x, y):
                return i
            h = (h + 0x13) % 255
        return None

    def port_flags(self, i):
        return self.ds[PORTS + 20 * i + 0x13]

    def palettes(self):
        return [K.bbr_table(self.img, DS + PAL_BASE + 0x30 * k) for k in range(5)]

    # ---- 0x224E1 tail (0x22628): cells -> pre-chips -----------------------------------------------------
    def prepass(self, third, x0=0, y0=0, w=THIRD, h=H):
        """Rectangle of the third (tile coords, even); cells < 0x10 -> 0x41 / 0 per quadrant bit
        (8 NW, 4 NE, 2 SW, 1 SE), others -> DATA1[18] chips with chips < 0x34 stored as 0."""
        buf = bytearray(w * h)
        cc = self.cell_chips
        for cy in range(h // 2):
            row = (y0 // 2 + cy) * 1080 + third * 360 + x0 // 2
            i = 2 * cy * w
            for cx in range(w // 2):
                v = self.cells[row + cx]
                if v < 0x10:
                    q = (0x41 if v & 8 else 0, 0x41 if v & 4 else 0, 0x41 if v & 2 else 0, 0x41 if v & 1 else 0)
                else:
                    q = [c if c >= 0x34 else 0 for c in cc[v * 4:v * 4 + 4]]
                buf[i], buf[i + 1], buf[i + w], buf[i + w + 1] = q
                i += 2
        return buf

    # ---- 0x219F8: coast autotile, in place, raster order ------------------------------------------------
    def autotile(self, buf, w, h, by0):
        """Neighbours outside the rectangle are clamped (mask) or skipped (0x59 test). The land flags come
        from the values before the pass; the 0x59 test reads the buffer in place (up/left already done)."""
        land = bytes(1 if c >= LAND_FLAG else 0 for c in buf)
        tab = self.autotile_table
        for y in range(h):
            off = lat_offset(by0 + y // 24)
            rm, r0, rp = max(y - 1, 0) * w, y * w, min(y + 1, h - 1) * w
            up, down = y > 0, y < h - 1
            for x in range(w):
                i = r0 + x
                c = buf[i]
                if c >= KEEP:
                    continue
                xm, xp = (x - 1 if x else 0), (x + 1 if x < w - 1 else x)
                m = (land[rm + x] | land[rm + xp] << 1 | land[r0 + xp] << 2 | land[rp + xp] << 3 |
                     land[rp + x] << 4 | land[rp + xm] << 5 | land[r0 + xm] << 6 | land[rm + xm] << 7)
                if not land[i]:
                    m |= 0x100
                t = tab[m]
                if t == 0:
                    buf[i] = 0
                    continue
                desert = ((up and buf[i - w] == KEEP) or (x and buf[i - 1] == KEEP) or
                          (x < w - 1 and buf[i + 1] == KEEP) or (down and buf[i + w] == KEEP))
                buf[i] = t + (0x18 if desert else off)

    # ---- 0x22734 tail: cells >= 0x10 over the autotiled buffer --------------------------------------------
    def overlay(self, buf, third, x0, y0, w, h, port_known, site_seen, markers=None):
        cc = self.cell_chips
        for cy in range(h // 2):
            ty = y0 + 2 * cy
            land = 0x41 + lat_offset(ty // 24)
            row = (ty // 2) * 1080 + third * 360 + x0 // 2
            for cx in range(w // 2):
                v = self.cells[row + cx]
                if v < 0x10:
                    continue
                i = 2 * cy * w + 2 * cx
                tx = third * THIRD + x0 + 2 * cx
                if v in (0x10, 0x11, 0x12):
                    site = v == 0x11
                    k = self.lookup(tx, ty, site)
                    shown = site_seen(k) if site else port_known(k)
                    hidden = 0x59 if site and cx and buf[i - 1] == KEEP else land
                    if markers is not None:
                        markers.append({"kind": ("port", "site", "supply")[v - 0x10], "id": k, "x": tx, "y": ty,
                                        "cell": v, "chips": list(cc[v * 4:v * 4 + 4]), "hidden": hidden})
                    if not shown:
                        buf[i] = buf[i + 1] = buf[i + w] = buf[i + w + 1] = hidden
                else:
                    buf[i], buf[i + 1], buf[i + w], buf[i + w + 1] = cc[v * 4:v * 4 + 4]

    def chip_map(self, port_known, site_seen, markers=None):
        """Whole-third computation = what the sea view shows, except windowOverrides."""
        out = bytearray(W * H)
        for t in range(3):
            buf = self.prepass(t)
            self.autotile(buf, THIRD, H, 0)
            self.overlay(buf, t, 0, 0, THIRD, H, port_known, site_seen, markers)
            for y in range(H):
                out[y * W + t * THIRD:y * W + (t + 1) * THIRD] = buf[y * THIRD:(y + 1) * THIRD]
        return out

    def window(self, third, wc, wr, port_known, site_seen):
        """The game's 72x72 local map [0x430] for window block (wc 0..27, wr 0..42) of a third."""
        x0, y0 = 24 * wc, 24 * wr
        buf = self.prepass(third, x0, y0, 72, 72)
        self.autotile(buf, 72, 72, wr)
        self.overlay(buf, third, x0, y0, 72, 72, port_known, site_seen)
        return buf


def visible_range(wb, last):
    """Window-local tile range the 24x24 view can show for window block wb (view clamp, scroll margin <= 10)."""
    return (0 if wb == 0 else 3, 71 if wb == last else 69)


def window_overrides(world, chips, port_known, site_seen, every=False):
    """Tiles whose chip in the game's own window differs from the whole-third map, inside the part of
    the window the view can show. Only windows holding a 0x59 chip can differ (the 0x59 fill spreads
    right/down in raster order and restarts at each window's edge); every=True simulates all windows."""
    out = []
    for t in range(3):
        pre = world.prepass(t)
        for wr in range(43):
            for wc in range(28):
                if not every and not any(
                        KEEP in pre[(24 * wr + y) * THIRD + 24 * wc:(24 * wr + y) * THIRD + 24 * wc + 72]
                        for y in range(72)):
                    continue
                buf = world.window(t, wc, wr, port_known, site_seen)
                (xa, xb), (ya, yb) = visible_range(wc, 27), visible_range(wr, 42)
                tiles = []
                for y in range(ya, yb + 1):
                    for x in range(xa, xb + 1):
                        wx, wy = t * THIRD + 24 * wc + x, 24 * wr + y
                        if buf[y * 72 + x] != chips[wy * W + wx]:
                            tiles.append([wx, wy, buf[y * 72 + x]])
                if tiles:
                    out.append({"third": t, "blockCol": wc, "blockRow": wr,
                                "x": t * THIRD + 24 * wc, "y": 24 * wr, "tiles": tiles})
    return out


CLASSES = [  # (first, last, what) — produced by DATA1[10] + band offset (0x219F8) or placed by DATA1[18] cells
    (0x00, 0x00, "open sea (also a sea tile with no 4-neighbour land, or with land on all four sides)"),
    (0x01, 0x08, "shore, band 14..30: sea tile with land at NW-corner, N, NE, W, E, SW, S, SE (table 1..8)"),
    (0x09, 0x10, "shore, other rows (+8)"),
    (0x11, 0x18, "shore, polar rows 0/44 (+0x10)"),
    (0x19, 0x20, "shore next to desert (+0x18: a 4-neighbour is chip 0x59)"),
    (0x21, 0x32, "unused on the map (forest/cliff shores, rocks 0x30, iceberg 0x31, whirlpool 0x32)"),
    (0x33, 0x33, "placeholder"),
    (0x34, 0x3F, "mountains 2x2 (0x34..0x37 cell 0x20), hills (DATA1[18] only)"),
    (0x40, 0x40, "placeholder"),
    (0x41, 0x41, "land, block rows 14..30"),
    (0x42, 0x47, "one-tile water, rows 14..30: land N+S, E+W, N+S+W, N+E+S, N+E+W, E+S+W"),
    (0x48, 0x48, "placeholder"),
    (0x49, 0x49, "land, other rows"), (0x4A, 0x4F, "one-tile water, other rows"),
    (0x50, 0x50, "placeholder"),
    (0x51, 0x51, "land, polar rows 0/44 (snow)"), (0x52, 0x53, "one-tile water, polar"),
    (0x54, 0x58, "placeholders (polar dead ends never occur)"),
    (0x59, 0x59, "desert land (landing finds no water)"), (0x5A, 0x60, "placeholders"),
    (0x61, 0x63, "unused on the map (forest)"), (0x64, 0x68, "placeholders"),
    (0x69, 0x72, "desert edge pieces (DATA1[18] frame cells 0x13..0x1E, 0x6C..0x7C)"), (0x73, 0x73, "placeholder"),
    (0x74, 0x77, "market port 2x2 (cell 0x10, shown when port +0x13 & 0x10)"),
    (0x78, 0x7B, "supply port 2x2 (cell 0x12, same flag)"),
    (0x7C, 0x7F, "village / discovery site 2x2 (cell 0x11, shown when site +6 & 0x40)"),
]
PLACEHOLDERS = [0x33, 0x40, 0x48, 0x50, 0x54, 0x55, 0x56, 0x57, 0x58, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
                0x60, 0x64, 0x65, 0x66, 0x67, 0x68, 0x73]   # chips that show their own hex number


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = args[0] if args else ROOT + "/assets/seamap"
    os.makedirs(out, exist_ok=True)
    world = World()
    pals = world.palettes()
    chips = [chip_pixels(world.chipdata, k) for k in range(128)]

    # (a) chips per palette phase
    open(out + "/chips_indexed.bin", "wb").write(bytes(b for c in chips for b in c))
    for p, pal in enumerate(pals):
        os.makedirs(f"{out}/p{p}", exist_ok=True)
        sheet = bytearray(256 * 128 * 3)
        for k, c in enumerate(chips):
            rgb = b"".join(bytes(pal[v]) for v in c)
            png.write_png(f"{out}/p{p}/chip_{k:02X}.png", 16, 16, rgb)
            gx, gy = (k % 16) * 16, (k // 16) * 16
            for y in range(16):
                o = ((gy + y) * 256 + gx) * 3
                sheet[o:o + 48] = rgb[y * 48:(y + 1) * 48]
        png.write_png(f"{out}/atlas_p{p}.png", 256, 128, bytes(sheet))

    # (b) chip map, ports / villages hidden; markers carry the revealed chips
    markers = []
    base = world.chip_map(lambda k: False, lambda k: False, markers)
    open(out + "/chips.bin", "wb").write(base)
    # The original's passability (chip >= 0x34 blocks) replaces extract.py's colour heuristic in
    # world_mask.bin; rough ground (2) is kept for the remaster's shader.
    mask_path = ROOT + "/assets/world_mask.bin"
    if out == ROOT + "/assets/seamap" and os.path.exists(mask_path):
        mask = bytearray(open(mask_path, "rb").read())
        if len(mask) == len(base):
            for i, c in enumerate(base):
                mask[i] = 0 if c < 0x34 else (2 if mask[i] == 2 else 1)
            open(mask_path, "wb").write(mask)
    missing = [m for m in markers if m["id"] is None]
    if missing:
        print("cells without a port/site record:", missing[:10])

    known = lambda k: k is not None and bool(world.port_flags(k) & 0x10)
    overrides = window_overrides(world, base, lambda k: False, lambda k: False, "--check-all" in sys.argv)
    print(f"window overrides: {len(overrides)} windows, {sum(len(o['tiles']) for o in overrides)} tiles")

    # check renders
    def blit(img_buf, iw, chip, px, py, pal):
        for y in range(16):
            o = ((py + y) * iw + px) * 3
            img_buf[o:o + 48] = b"".join(bytes(pal[v]) for v in chips[chip][y * 16:(y + 1) * 16])

    newgame = bytearray(base)                      # new-game port flags, no village seen
    for m in markers:
        if m["kind"] != "site" and known(m["id"]):
            x, y = m["x"], m["y"]
            newgame[y * W + x], newgame[y * W + x + 1], newgame[(y + 1) * W + x], newgame[(y + 1) * W + x + 1] = m["chips"]
    lis = struct.unpack_from("<HH", world.ds, PORTS)
    vx = min(max(lis[0] - 11, (lis[0] // THIRD) * THIRD), (lis[0] // THIRD) * THIRD + THIRD - 24)   # 0x1620D
    vy = min(max(lis[1] - 11, 0), H - 24)
    strip = bytearray(5 * 392 * 384 * 3)
    for p in range(5):
        view = bytearray(384 * 384 * 3)
        for ty in range(24):
            for tx in range(24):
                c = newgame[(vy + ty) * W + vx + tx]
                blit(view, 384, c if c < 128 else 0, tx * 16, ty * 16, pals[p])
                blit(strip, 5 * 392, c if c < 128 else 0, p * 392 + tx * 16, ty * 16, pals[p])
        if p == 2:
            png.write_png(out + "/view_lisbon.png", 384, 384, bytes(view))
    png.write_png(out + "/view_lisbon_phases.png", 5 * 392, 384, bytes(strip))

    mean = []
    for c in chips:
        r = g = b = 0
        for v in c:
            q = pals[2][v]
            r, g, b = r + q[0], g + q[1], b + q[2]
        mean.append(bytes((r // 256, g // 256, b // 256)))
    full = bytearray(base)
    for m in markers:
        x, y = m["x"], m["y"]
        full[y * W + x], full[y * W + x + 1], full[(y + 1) * W + x], full[(y + 1) * W + x + 1] = m["chips"]
    png.write_png(out + "/world.png", W, H, b"".join(mean[c] if c < 128 else b"\xff\x00\xff" for c in full))

    hist = [0] * 256
    for c in base:
        hist[c] += 1
    used = {f"{c:#04x}": n for c, n in enumerate(hist) if n}
    print("chips used (hidden markers):", used)
    print("placeholder chips on the map:", {f"{c:#04x}": hist[c] for c in PLACEHOLDERS if hist[c]})
    print("chips >= 0x80 on the map:", sum(hist[128:]))
    print(f"markers: {len(markers)} ({sum(m['kind'] == 'port' for m in markers)} ports, "
          f"{sum(m['kind'] == 'supply' for m in markers)} supply, {sum(m['kind'] == 'site' for m in markers)} sites)")

    json.dump({
        "source": "MAIN.EXE 0x22734 (0x224E1 decode + pre-chips, 0x219F8 autotile, cell overlay); docs/re/seamap.md",
        "chipFormat": "DATA1[11] 0..0x3FFF: 128 chips 16x16, 4 sequential planes of 16 big-endian u16 rows",
        "chipsBin": {"file": "chips.bin", "width": W, "height": H, "order": "row-major y*2160+x",
                     "state": "ports and villages hidden (drawn as land); apply markers[].chips when shown"},
        "chipsIndexed": {"file": "chips_indexed.bin", "layout": "128 chips x 256 colour indices, row-major"},
        "palettes": {"source": "DS:0xAD22 + 0x30*phase, B,R,G 0..15, rgb here = value*17",
                     "phases": [[list(c) for c in pal] for pal in pals],
                     "names": ["night (also storm)", "dawn", "day", "dusk", "fog"],
                     "phaseOfTick": list(world.ds[PHASE_TABLE:PHASE_TABLE + 6]),
                     "note": "colours 0..7 equal in all phases; phase(tick) = phaseOfTick[tick // 12]; "
                             "storm uses phase 0, fog phase 4; changes fade 1/15 per channel per tick"},
        "atlases": [f"atlas_p{p}.png" for p in range(5)],
        "classes": [{"first": a, "last": b, "what": s} for a, b, s in CLASSES],
        "placeholders": PLACEHOLDERS,
        "bands": {"blockRow": "y // 24", "offset": "0 for rows 14..30, 0x10 for rows 0 and 44, else 8",
                  "landChip": {"rows14to30": 0x41, "otherRows": 0x49, "polarRows": 0x51, "desert": 0x59}},
        "markers": markers,
        "windowOverrides": {
            "note": "the game builds a 72x72 local map per window (block col clamp((x//24)%30-1,0,27), row "
                    "clamp(y//24-1,0,42) of the fleet, within its 720-tile third); inside these windows the "
                    "listed tiles [x, y, chip] show a different chip than chips.bin (cut desert fills)",
            "windows": overrides},
        "newGameKnownPorts": [m["id"] for m in markers if m["kind"] != "site" and known(m["id"])],
        "chipHistogram": used,
    }, open(out + "/index.json", "w"), ensure_ascii=False, indent=0)


if __name__ == "__main__":
    main()
