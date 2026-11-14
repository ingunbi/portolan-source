#!/usr/bin/env python3
"""Generated portraits of minor characters (MAIN.EXE 0x7A4E). Run with build/venv/bin/python -I.

A person whose face word (+0x1A) has a bit of 0xC000 set gets a 64x80 face assembled from five
full-width strips. The strips are not LS11 entries: they sit uncompressed after the last entry
of KAO.LZW (file offset 0x476A2), seven sets of 0x60C0 bytes, one per nation (person +0x31 & 0xF).
Every strip is 3-plane byte-interleaved like the 1920-byte portraits (24 bytes per row).

  layer   bits         count  rows    drawn
  top     v & 7          8    0..32   copied
  bottom  v >> 3 & 7     8    33..79  copied
  eyes    v >> 8 & 7     8    21..38  OR-ed onto the face
  nose    v >> 6 & 3     4    29..52  OR-ed
  mouth   v >> 11 & 7    8    45..63  OR-ed

usage:
  faces.py --sheet N out.png [--seed S] [--nation K] [--scale Z]   N random faces (nation cycles 0..6)
  faces.py --face VALUE NATION out.png [--scale Z]                  one face (VALUE hex or decimal)
  faces.py --persons out.png [--scale Z]                            the generated persons of a new game
  faces.py --export DIR                                             DIR/part_<k>.png + DIR/faces.json
"""
import json, os, random, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
W, H, ROW = 64, 80, 24            # 8 bytes x 3 planes per row
TAIL = 0x476A2                    # KAO.LZW file offset of the part sets (0x7B41: add ax, 0x76A2; adc dx, 4)
SET_SIZE = 0x60C0                 # one set per nation (0x7B3C: mul 0x60C0)
NATIONS = ["Portugal", "Spain", "Turkey", "England", "Italy", "Netherlands", "none"]

# (name, shift, count, first row, rows, blend) in file order, which is also the drawing order.
LAYERS = [
    ("top", 0, 8, 0, 33, "copy"),       # 0x7A12: read 0x318 bytes to buffer +0
    ("bottom", 3, 8, 33, 47, "copy"),   # 0x7A12: read 0x468 bytes to buffer +0x318
    ("eyes", 8, 8, 21, 18, "or"),       # 0x79AA: OR 0x1B0 bytes at +0x1F8
    ("nose", 6, 4, 29, 24, "or"),       # 0x79AA: OR 0x240 bytes at +0x2B8
    ("mouth", 11, 8, 45, 19, "or"),     # 0x79AA: OR 0x1C8 bytes at +0x438
]
PARTS_PER_SET = sum(l[2] for l in LAYERS)    # 36


def load_sets(game=GAME):
    blob = open(game + "/KAO.LZW", "rb").read()
    last = ls11.entries(blob)[-1]
    assert last[2] + last[0] == TAIL and len(blob) == TAIL + len(NATIONS) * SET_SIZE
    return blob[TAIL:]


def palette(game=GAME):
    _, img, _ = mzdis.load(game + "/MAIN.EXE")
    return K.bbr_table(img)


def part_bytes(sets, nation, layer, index):
    """Raw interleaved bytes of one strip."""
    off = nation * SET_SIZE
    for name, _, count, _, rows, _ in LAYERS:
        if name == layer:
            assert 0 <= index < count
            return sets[off + index * rows * ROW:off + (index + 1) * rows * ROW]
        off += count * rows * ROW
    raise KeyError(layer)


def compose(sets, value, nation):
    """The 1920-byte buffer 0x7A4E builds, decoded to 64x80 palette indices 0..7."""
    buf = bytearray(W // 8 * 3 * H)
    for name, shift, count, row, rows, blend in LAYERS:
        d = part_bytes(sets, nation, name, (value >> shift) & (count - 1))
        o = row * ROW
        if blend == "copy":
            buf[o:o + len(d)] = d
        else:
            for i, b in enumerate(d):
                buf[o + i] |= b
    return K.planar_bytes(buf, W, H, 3)


def sheet(path, faces, pal, cols=7, scale=2):
    """faces: list of (indices, ) 64x80 bitmaps."""
    gap = 2
    rows = (len(faces) + cols - 1) // cols
    cw, ch = (W + gap) * scale, (H + gap) * scale
    sw, sh = cols * cw, rows * ch
    out = bytearray(bytes((48, 48, 48)) * (sw * sh))
    for n, px in enumerate(faces):
        ox, oy = (n % cols) * cw, (n // cols) * ch
        for y in range(H * scale):
            line = b"".join(bytes(pal[px[(y // scale) * W + x // scale]]) for x in range(W * scale))
            o = ((oy + y) * sw + ox) * 3
            out[o:o + len(line)] = line
    png.write_png(path, sw, sh, bytes(out))


def new_game_persons(game=GAME):
    """(person, face word, nation) of the generated persons in DATA1[15] (DS:0x1242, 50 bytes)."""
    d = ls11.unpack(game + "/DATA1.LZW")[15]
    out = []
    for i in range(120):
        p = d[0x1242 + i * 50 - 0xC30:0x1242 + (i + 1) * 50 - 0xC30]
        v = struct.unpack_from("<H", p, 0x1A)[0]
        if v & 0xC000:
            out.append((i, v, p[0x31] & 0xF))
    return out


def export(out_dir, sets, pal):
    """part_<k>.png with k = nation * 36 + layer base + index (layer bases 0, 8, 16, 24, 28)."""
    os.makedirs(out_dir, exist_ok=True)
    decoded, set_meta = {}, []
    for nation in range(len(NATIONS)):
        files = {}
        for name, _, count, _, rows, blend in LAYERS:
            files[name] = []
            for index in range(count):
                fn = f"part_{nation * PARTS_PER_SET + sum(len(f) for f in files.values())}.png"
                px = K.planar_bytes(part_bytes(sets, nation, name, index), W, rows, 3)
                rgba = b"".join(bytes(pal[c]) + (b"\0" if blend == "or" and c == 0 else b"\xff") for c in px)
                png.write_png(f"{out_dir}/{fn}", W, rows, rgba)
                files[name].append(fn)
                decoded[fn] = px
        # The JSON recipe (OR on palette indices) must reproduce the game's byte-level composition.
        for v in random.Random(nation).sample(range(0x4000), 300):
            assert _recipe(decoded, files, v) == compose(sets, v, nation)
        exact = _over_is_exact(decoded, files)
        set_meta.append({"nation": nation, "name": NATIONS[nation], "alphaOverIsExact": exact, "parts": files})
    meta = {
        "source": "KAO.LZW bytes 0x476A2.., 7 sets x 0x60C0, composed by MAIN.EXE 0x7A4E",
        "width": W, "height": H,
        "generatedMask": 0xC000,
        "valueMask": 0x3FFF,
        "set": "nation = person +0x31 & 0x0F (0..6); persons >= 120 get rand(0x3FFF)|0xC000 with rand(7) each time",
        "palette": [list(c) for c in pal[:8]],
        "blendNote": ("Draw layers in order at (x, y). 'copy' replaces every pixel. 'or' skips index 0 and "
                      "otherwise writes paletteIndex(below) | paletteIndex(part); map RGB back to an index with "
                      "'palette' (8 distinct colours). Plain alpha-over gives the same picture only for sets with "
                      "alphaOverIsExact."),
        "layers": [{"name": n, "shift": s, "mask": c - 1, "count": c, "x": 0, "y": r, "width": W, "height": h,
                    "blend": b} for n, s, c, r, h, b in LAYERS],
        "sets": set_meta,
    }
    text = json.dumps(meta, indent=1)
    text = re.sub(r"\[\s+([^\[\]{}]*?)\s+\]", lambda m: "[" + " ".join(m.group(1).split()) + "]", text)
    open(out_dir + "/faces.json", "w").write(text + "\n")
    return set_meta


def _over_is_exact(decoded, files):
    """Whether alpha-over (last non-zero layer wins) equals OR for every one of the 0x4000 values.
    Layers are chosen independently, so it is enough to try every combination of the distinct
    values each layer can put at each pixel."""
    import itertools
    for i in range(W * H):
        y, x = divmod(i, W)
        cands = []
        for name, _, _, row, rows, blend in LAYERS:
            if row <= y < row + rows:
                vals = {decoded[f][(y - row) * W + x] for f in files[name]}
                cands.append(sorted(vals) if blend == "copy" else sorted(vals | {0}))
        for combo in itertools.product(*cands):
            orv, over = 0, 0
            for c in combo:
                orv |= c
                over = c or over
            if orv != over:
                return False
    return True


def _recipe(decoded, files, v):
    px = bytearray(W * H)
    for name, shift, count, row, rows, blend in LAYERS:
        p = decoded[files[name][(v >> shift) & (count - 1)]]
        for i, c in enumerate(p):
            if blend == "copy":
                px[row * W + i] = c
            elif c:
                px[row * W + i] |= c
    return bytes(px)


def main():
    a = sys.argv[1:]
    opt = lambda k, d: type(d)(a[a.index(k) + 1]) if k in a else d
    scale = opt("--scale", 2)
    sets = load_sets()
    pal = palette()
    if "--export" in a:
        ms = export(a[a.index("--export") + 1], sets, pal)
        print(f"{len(ms) * PARTS_PER_SET} parts, sets {[s['name'] for s in ms]}, "
              f"alpha-over exact for {[s['nation'] for s in ms if s['alphaOverIsExact']]}")
    elif "--sheet" in a:
        i = a.index("--sheet")
        n, out = int(a[i + 1]), a[i + 2]
        rnd = random.Random(opt("--seed", 1))
        nation = opt("--nation", -1)
        faces = [compose(sets, rnd.randrange(0x4000), nation if nation >= 0 else k % 7) for k in range(n)]
        sheet(out, faces, pal, cols=8 if nation >= 0 else 7, scale=scale)
    elif "--face" in a:
        i = a.index("--face")
        v, nation, out = int(a[i + 1], 0), int(a[i + 2]), a[i + 3]
        sheet(out, [compose(sets, v & 0x3FFF, nation)], pal, cols=1, scale=scale)
    elif "--persons" in a:
        ps = new_game_persons()
        sheet(a[a.index("--persons") + 1], [compose(sets, v & 0x3FFF, n) for _, v, n in ps], pal, cols=9, scale=scale)
        print(" ".join(f"{i}:{v:#06x}/{n}" for i, v, n in ps))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
