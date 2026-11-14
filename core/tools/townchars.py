#!/usr/bin/env python3
"""Walking-town sprites (CHAR.LZW) and the town compass arrows (DATA1[6]). Run with build/venv/bin/python -I.

CHAR.LZW (loader 0x8747): 7 LS11 entries. Entry h (h = hero [0x1241], 5120 B) -> [0x70A]:0, entry 6
  (townsfolk, 15360 B) -> [0x70A]:0x1400. Frame n of the combined buffer is at [0x70A]:n*0x280.
  Frame = 640 B = four 16x16 quarters TL, TR, BL, BR (+0, +0xA0, +0x140, +0x1E0; 0x5E5E).
  Quarter = 160 B: four planes of 16 big-endian u16 rows (32 B each, same as PORTCHIP tiles), then a
  32 B mask in the same layout. Drawn by 0x1795 as `tile = (tile AND mask) OR plane` per plane:
  mask bit 1 = transparent (the plane bits are always 0 there), mask 0 = opaque (black shadow included).
  Frames per character: 8 = 4 directions x 2 steps, index dir*2 + step, dir 0 up, 1 right, 2 down, 3 left.
  Hero frame = dir*0x500 + [0x9510] (0x5FBE; [0x9510] ^= 0x280 on every draw).
  Townsfolk (entry 6, global frames 8..31):
    walker A = entry-6 frames 0..7  (sprite slots 0, 2; global ((i&1)*4 + dir + 4)*2 + step, 0x6147)
    walker B = entry-6 frames 8..15 (sprite slots 1, 3)
    standing kind k = entry-6 frames 16+2k, 17+2k (slots 4..7; global (k+12)*2 + rand(2)):
      0 man with hat (교역소 side), 1 dog (주점), 2 guard (blockade), 3 old merchant (여관)
  Sprites use colours 0..7 only, identical in all five time-of-day palettes DS:0xAD22 + 0x30*phase.

DATA1.LZW entry 6 (0x8B52 -> [0xC0E]:0x3EA0, drawn by 0x92A8): 8 compass arrows of 40x24, 480 B each,
  4 planes byte-interleaved per 8-pixel column ((y*5 + x/8)*4 + plane). Image d = arrow d normal,
  4 + d = arrow d lit (facing highlight, 0x934F). Screen position (game 640x400) per dir: up (528,304),
  right (552,336), down (528,368), left (504,336).

usage:
  townchars.py [--out DIR]       default assets/townchars
Writes one RGBA PNG per frame (32x32, transparent background), the 8 compass images (40x24, opaque) and
DIR/townchars.json (frame size, directions, frame order, who is who).
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0
DAY_PALETTE = DS + 0xAD82        # phase 2; colours 0..7 equal in every phase
FRAME = 640                      # 0x280
QUARTER = 160                    # 0xA0
DIRS = ["up", "right", "down", "left"]
HEROES = ["조안 페레로", "카탈리나 에란초", "옷토 스피노라", "에르네스트 로페스", "피에트로 콘티", "알 베자스"]
STANDING = [  # kind -> (file stem, who, slot, talk)
    ("stand_man", "man with a hat; slot 4, right of the 교역소 door", 4, "msg 578-581: what port this is"),
    ("stand_dog", "dog; slot 5, right of the 주점 door", 5, "msg 619-621 (port % 3): 멍멍 / Bowwow / 캉캉"),
    ("stand_guard", "harbour guard (blockade); slots 4-6 only when blockaded", 6, "msg 622: nationals of your nation may not call here"),
    ("stand_merchant", "old merchant; slot 7, right of the 여관 door", 7, "msg 616 + 617 (specialty of this port) or 618"),
]
WALKERS = [
    ("walker_a", "woman in a headscarf; slots 0 (starts left of 교역소) and 2 (starts on the 조선소 door)",
     [0, 2], {"0": "msg 642+port: a line about this port", "2": "msg 640/641: used ship at the shipyard (DS:0x7E70 slot 0)"}),
    ("walker_b", "bearded man; slots 1 (left of 주점) and 3 (left of 여관)",
     [1, 3], {"1": "msg 630 + day % 10: a tip", "3": "msg 623 + port nation: greeting in that language"}),
]
COMPASS_POS = [(528, 304), (552, 336), (528, 368), (504, 336)]


def quarter_rgba(d, o, pal):
    """16x16 quarter -> 16 rows of RGBA bytes."""
    rows = []
    for y in range(16):
        r = bytearray()
        for x in range(16):
            i, b = o + y * 2 + x // 8, 7 - x % 8
            if (d[i + 128] >> b) & 1:
                r += b"\0\0\0\0"
            else:
                c = sum(((d[i + p * 32] >> b) & 1) << p for p in range(4))
                r += bytes(pal[c]) + b"\xff"
        rows.append(bytes(r))
    return rows


def frame_rgba(d, f, pal):
    """Frame f of an entry -> 32x32 RGBA bytes."""
    q = [quarter_rgba(d, f * FRAME + k * QUARTER, pal) for k in range(4)]
    return b"".join(q[0][y] + q[1][y] for y in range(16)) + b"".join(q[2][y] + q[3][y] for y in range(16))


def compass_rgba(d, k, pal):
    out = bytearray()
    for y in range(24):
        for x in range(40):
            i, b = k * 480 + (y * 5 + x // 8) * 4, 7 - x % 8
            out += bytes(pal[sum(((d[i + p] >> b) & 1) << p for p in range(4))]) + b"\xff"
    return bytes(out)


def walk_set(out_dir, stem, d, first, pal):
    """Write 8 frames (4 dirs x 2 steps) starting at frame `first` of entry d; return {dir: [files]}."""
    res = {}
    for di, name in enumerate(DIRS):
        res[name] = []
        for s in range(2):
            fn = "%s_%s_%d.png" % (stem, name, s)
            png.write_png(out_dir + "/" + fn, 32, 32, frame_rgba(d, first + di * 2 + s, pal))
            res[name].append(fn)
    return res


def main():
    args = sys.argv[1:]
    out_dir = args[args.index("--out") + 1] if "--out" in args else ROOT + "/assets/townchars"
    os.makedirs(out_dir, exist_ok=True)
    _, img, _ = mzdis.load(GAME + "/MAIN.EXE")
    pal = K.bbr_table(img, DAY_PALETTE)
    ent = ls11.unpack(GAME + "/CHAR.LZW")
    assert [len(e) for e in ent] == [5120] * 6 + [15360], [len(e) for e in ent]
    n = 0
    heroes = []
    for h in range(6):
        heroes.append({"hero": h, "name": HEROES[h], "entry": h,
                       "frames": walk_set(out_dir, "hero%d" % h, ent[h], 0, pal)})
        n += 8
    walkers = []
    for k, (stem, who, slots, talk) in enumerate(WALKERS):
        walkers.append({"name": stem, "who": who, "slots": slots, "talk": talk, "entryFrames": [8 * k, 8 * k + 7],
                        "frames": walk_set(out_dir, stem, ent[6], 8 * k, pal)})
        n += 8
    standing = []
    for k, (stem, who, slot, talk) in enumerate(STANDING):
        files = []
        for s in range(2):
            fn = "%s_%d.png" % (stem, s)
            png.write_png(out_dir + "/" + fn, 32, 32, frame_rgba(ent[6], 16 + 2 * k + s, pal))
            files.append(fn)
            n += 1
        standing.append({"kind": k, "name": stem, "who": who, "slot": slot, "talk": talk,
                         "entryFrames": [16 + 2 * k, 17 + 2 * k], "frames": files})
    comp = ls11.unpack(GAME + "/DATA1.LZW")[6]
    assert len(comp) == 8 * 480
    compass = []
    for di, name in enumerate(DIRS):
        files = {}
        for lit in (0, 1):
            fn = "compass_%s%s.png" % (name, "_lit" if lit else "")
            png.write_png(out_dir + "/" + fn, 40, 24, compass_rgba(comp, di + 4 * lit, pal))
            files["lit" if lit else "normal"] = fn
        compass.append({"dir": name, "pos": list(COMPASS_POS[di]), **files})
    index = {
        "source": "CHAR.LZW (heroes: entry = hero index [0x1241]; townsfolk: entry 6); compass: DATA1.LZW entry 6",
        "frameSize": [32, 32],
        "tile": 16,
        "anchor": "sprite (x, y) = top-left map tile of the 2x2 footprint; feet = row y+1 (walkability)",
        "directions": DIRS,
        "framesPerDirection": 2,
        "frameOrder": "frame = dir*2 + step; heroes toggle step on every draw (0x5FBE), walkers use step = 1 if (x+y) even "
                      "(0x6147), standing figures pick rand(2) each redraw",
        "palette": "DS:0xAD82 colours 0..7 (identical in all time-of-day palettes DS:0xAD22 + 0x30*phase)",
        "globalFrames": "game buffer [0x70A]: frames 0..7 hero, 8..15 walker_a, 16..23 walker_b, 24..31 standing kinds 0..3",
        "heroes": heroes,
        "walkers": walkers,
        "standing": standing,
        "compass": {"size": [40, 24], "note": "town direction pad overlays (0x92A8); lit = facing highlight when 표시효과 is on",
                    "arrows": compass},
    }
    def js(v):
        if isinstance(v, list) and v and isinstance(v[0], dict):
            return "[\n " + ",\n ".join(json.dumps(e, ensure_ascii=False) for e in v) + "\n]"
        return json.dumps(v, ensure_ascii=False)
    with open(out_dir + "/townchars.json", "w") as f:
        f.write("{\n" + ",\n".join(json.dumps(k) + ": " + js(v) for k, v in index.items()) + "\n}\n")
    print("frames:", n, "compass: 8 ->", out_dir)


if __name__ == "__main__":
    main()
