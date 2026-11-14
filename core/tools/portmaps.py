#!/usr/bin/env python3
"""Port town maps and 48x48 pictures (MAIN.EXE 0x8747, 0x1D930, 0x7BE5). Run with build/venv/bin/python -I.

Port town map (loader 0x8747, drawn by the 항구지도 info screen 0x1D930 and the walking town view):
  PORTMAP.LZW   101 LS11 entries of 96x96 tile bytes (row-major). Entry p for market port p < 100;
                every supply port (100..129) uses entry 100.
  PORTCHIP.LZW  14 entries = 7 chip sets. Entry 2s: 240 tiles of 16x16, four sequential planes of
                big-endian 16-bit rows (128 B per tile, same as DATA1[11]). Entry 2s+1: 4 bytes
                (0, a, b, c) copied to DS:0xC128 = walkability thresholds (0x5F6A, 0x5FF4).
  CHIP_NO.DAT   100 bytes, chip set of market port p. Supply ports always use set 3.
  ZA_DAT.DAT    101 x 24 B: twelve (x, y) door tiles in MENU 58 building order; (255,255) or (0,0) = none.
Colours: the daytime town palette DS:0xAD82 (the 항구지도 screen sets it at 0x1DB3C). The walking town uses
  DS:0xAD22 + 0x30*phase by time of day (0x1ABE0); only colours 8..15 differ, and the main table 0x40ECE
  equals AD82 except colour 15.

Pictures (KAO.LZW entries 128..255): 48x48, three planes byte-interleaved (6 B x 3 per row), colours 0..7.
  picture n = entry 0x80 + n. Discoveries use n = COLONY.DAT byte +0x12 (0..84); items n = 0x55 + item +0x15.

usage:
  portmaps.py [--maps DIR] [--pictures DIR]     defaults: assets/portmaps, assets/pictures
Writes DIR/NNN.png for maps 0..100 (8-bit indexed PNG, 1536x1536) and portmaps.json (per port: map entry,
chip set, door tiles, walk thresholds); pictures/NNN.png for pictures 0..127 (48x48 RGB).
"""
import json, os, struct, sys, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
MAP_W = 96                      # tiles per row and column
TILE = 16
SUPPLY_SET = 3                  # 0x8884: PORTCHIP entries 6 and 7 for ports >= 100
SUPPLY_MAP = 100                # 0x8970: PORTMAP entry 100 (push 0x64)
DS = 0x378B0
DAY_PALETTE = DS + 0xAD82       # B,R,G triples like 0x40ECE
BUILDINGS = ["교역소", "주점", "조선소", "항구", "여관", "왕궁", "조합", "NPC", "은행", "아이템", "교회", "점술가"]


def chip_rows(d, o):
    """16x16 tile -> 16 rows of 16 palette indices."""
    t = [bytearray(16) for _ in range(16)]
    for p in range(4):
        for y in range(16):
            v = (d[o + p * 32 + y * 2] << 8) | d[o + p * 32 + y * 2 + 1]
            row = t[y]
            for x in range(16):
                row[x] |= ((v >> (15 - x)) & 1) << p
    return [bytes(r) for r in t]


def write_indexed_png(path, w, h, pix, pal):
    """8-bit palette PNG; pix = bytes of w*h indices."""
    raw = b"".join(b"\0" + pix[y * w:(y + 1) * w] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 3, 0, 0, 0)))
        f.write(chunk(b"PLTE", b"".join(bytes(c) for c in pal)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def render_map(tiles, chips):
    """96x96 tile bytes -> 1536x1536 index bytes."""
    out = []
    for ty in range(MAP_W):
        row = tiles[ty * MAP_W:(ty + 1) * MAP_W]
        for y in range(TILE):
            out.append(b"".join(chips[t][y] if t < len(chips) else bytes(TILE) for t in row))
    return b"".join(out)


def export_maps(out_dir, pal):
    os.makedirs(out_dir, exist_ok=True)
    maps = ls11.unpack(GAME + "/PORTMAP.LZW")
    sets = ls11.unpack(GAME + "/PORTCHIP.LZW")
    chip_no = open(GAME + "/CHIP_NO.DAT", "rb").read()
    doors = open(GAME + "/ZA_DAT.DAT", "rb").read()
    chips = [[chip_rows(sets[2 * s], k * 128) for k in range(len(sets[2 * s]) // 128)] for s in range(len(sets) // 2)]
    for m in range(len(maps)):
        s = chip_no[m] if m < 100 else SUPPLY_SET
        pix = render_map(maps[m], chips[s])
        write_indexed_png("%s/%03d.png" % (out_dir, m), MAP_W * TILE, MAP_W * TILE, pix, pal)
        # The tile numbers themselves, for the walkability test (0x5F6A) in the walking town.
        open("%s/%03d.tiles" % (out_dir, m), "wb").write(bytes(maps[m][:MAP_W * MAP_W]))
    ports = []
    for p in range(130):
        m = p if p < 100 else SUPPLY_MAP
        s = chip_no[p] if p < 100 else SUPPLY_SET
        rec = doors[m * 24:(m + 1) * 24]
        d = {}
        for i, name in enumerate(BUILDINGS):
            x, y = rec[2 * i], rec[2 * i + 1]
            if (x, y) not in ((255, 255), (0, 0)):
                d[name] = [x, y]
        ports.append({"port": p, "map": m, "chipSet": s, "doors": d})
    walk = [list(sets[2 * s + 1]) for s in range(len(sets) // 2)]
    with open(out_dir + "/portmaps.json", "w") as f:
        head = {"tile": TILE, "size": MAP_W, "buildings": BUILDINGS, "walk": walk}
        f.write(json.dumps(head, ensure_ascii=False)[:-1] + ',\n"ports": [\n')
        f.write(",\n".join(json.dumps(r, ensure_ascii=False) for r in ports) + "\n]}\n")
    return len(maps)


def export_pictures(out_dir, pal):
    os.makedirs(out_dir, exist_ok=True)
    kao = ls11.unpack(GAME + "/KAO.LZW")
    n = 0
    for k in range(128, len(kao)):
        d = kao[k]
        assert len(d) == 864, (k, len(d))
        px = K.planar_bytes(d, 48, 48, 3)
        png.write_png("%s/%03d.png" % (out_dir, k - 128), 48, 48, b"".join(bytes(pal[i]) for i in px))
        n += 1
    return n


def main():
    args = sys.argv[1:]
    maps_dir = ROOT + "/assets/portmaps"
    pics_dir = ROOT + "/assets/pictures"
    if "--maps" in args:
        maps_dir = args[args.index("--maps") + 1]
    if "--pictures" in args:
        pics_dir = args[args.index("--pictures") + 1]
    _, img, _ = mzdis.load(GAME + "/MAIN.EXE")
    print("maps:", export_maps(maps_dir, K.bbr_table(img, DAY_PALETTE)), "->", maps_dir)
    print("pictures:", export_pictures(pics_dir, K.bbr_table(img)), "->", pics_dir)


if __name__ == "__main__":
    main()
