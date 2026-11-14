#!/usr/bin/env python3
"""Build assets/ from the original game files. Run with build/venv/bin/python -I.

usage: extract.py [game_dir] [out_dir]
"""
import collections, shutil, json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx_codec as K
import ls11, mzdis, png, worldmap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = sys.argv[1] if len(sys.argv) > 1 else ROOT + "/original/GAME"
OUT = sys.argv[2] if len(sys.argv) > 2 else ROOT + "/assets"
DS = 0x378B0
PORT_TABLE = DS + 0x5F54
WATER_COLOURS = {1, 5, 9, 12}  # palette entries used by sea and river pixels
SEA, LAND, ROUGH = 0, 1, 2


def rgb(px, pal):
    return b"".join(bytes(pal[p]) for p in px)


def chip(d, o):
    """16x16 tile: four sequential planes of big-endian 16-bit rows."""
    t = [0] * 256
    for p in range(4):
        for y in range(16):
            v = (d[o + p * 32 + y * 2] << 8) | d[o + p * 32 + y * 2 + 1]
            for x in range(16):
                t[y * 16 + x] |= ((v >> (15 - x)) & 1) << p
    return t


def ports(img):
    out = []
    for i in range(256):
        r = img[PORT_TABLE + i * 20:PORT_TABLE + (i + 1) * 20]
        x, y = struct.unpack_from("<HH", r)
        raw = r[4:18].split(b"\0")[0]
        if not raw or raw[0] < 0x80 or x >= 2160 or y >= 1080:
            break
        out.append({"id": i, "name": raw.decode("cp949"), "x": x, "y": y})
    return out


def build_tiles(cells, tiles, cell_chips):
    """Expand cells to a 2160x1080 class map (SEA/LAND/ROUGH)."""
    water = [sum(c in WATER_COLOURS for c in chip(tiles, k * 128)) / 256 > 0.55 for k in range(256)]
    W, H = 2160, 1080
    out = bytearray(W * H)
    for cy in range(540):
        for cx in range(1080):
            v = cells[cy * 1080 + cx]
            if v < 16:
                q = [LAND if v & b else SEA for b in (8, 4, 2, 1)]
            elif v in (16, 17, 18):
                q = [LAND] * 4
            else:
                q = [SEA if water[c] else ROUGH for c in cell_chips[v * 4:v * 4 + 4]]
            out[cy * 2 * W + cx * 2] = q[0]
            out[cy * 2 * W + cx * 2 + 1] = q[1]
            out[(cy * 2 + 1) * W + cx * 2] = q[2]
            out[(cy * 2 + 1) * W + cx * 2 + 1] = q[3]
    return bytes(out)


def reachable(mask, start):
    W, H = 2160, 1080
    seen = bytearray(W * H)
    q = collections.deque()
    sx, sy = start
    # nearest sea tile to the start port
    for r in range(12):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                i = (sy + dy) * W + (sx + dx) % W
                if mask[i] == SEA and not q:
                    seen[i] = 1
                    q.append(i)
    while q:
        i = q.popleft()
        y, x = divmod(i, W)
        for nx, ny in (((x + 1) % W, y), ((x - 1) % W, y), (x, y + 1), (x, y - 1)):
            if 0 <= ny < H:
                j = ny * W + nx
                if not seen[j] and mask[j] == SEA:
                    seen[j] = 1
                    q.append(j)
    return seen


SAIL_TABLE = DS + 0x714        # [|wind dir - heading|][sail type] -> 0..10
SHIP_CLASSES = DS + 0x5E28     # 25 x 12 bytes
SHIP_TEMPLATES = DS + 0x57CE   # 25-byte ship records; 40..64 are one per class


def navigation(img, windcur):
    classes = []
    for i in range(25):
        c = img[SHIP_CLASSES + i * 12:SHIP_CLASSES + (i + 1) * 12]
        t = img[SHIP_TEMPLATES + (40 + i) * 25:SHIP_TEMPLATES + (41 + i) * 25]
        classes.append({
            "name": t[:14].split(b"\0")[0].decode("cp949", "ignore").strip(),
            "unknown0": c[0], "hull": c[1], "rudder": c[2], "sail": c[3], "guns": c[4], "minCrew": c[5],
            "capacity": c[6] | c[7] << 8, "unknown8": c[8], "sailType": c[9], "price": c[10] | c[11] << 8,
            "oars": not (t[19] & 0x10),
            "oceanGoing": bool(t[19] & 0x40),            # others take five times the storm damage (0x1963B)
            # Bounds of the crew / gun split chosen at the yard (0x2AB31): berths minCrew..10×c[4], guns 0..c[8].
            "maxCrew": 10 * c[4], "maxGuns": c[8],
            # The shipyard copies these from the class template (0x31D86): cargo = capacity - guns - crew.
            "requiredIndustry": 10 * c[0],               # shipyards stock the class from this industry (0x1B8A6)
            "gunCapacity": t[0x14], "crewCapacity": t[0x15] | t[0x16] << 8, "cargoCapacity": t[0x17] | t[0x18] << 8,
        })
    assert classes[0]["name"] == "발사" and classes[16]["capacity"] == 1200
    assert all(c["capacity"] == c["gunCapacity"] + c["crewCapacity"] + c["cargoCapacity"] for c in classes)
    return {
        "sailTable": [list(img[SAIL_TABLE + r * 8:SAIL_TABLE + r * 8 + 8]) for r in range(8)],
        "windSummer": list(windcur[0:450]),
        "windWinter": list(windcur[450:900]),
        "current": list(windcur[900:1350]),
        "classes": classes,
    }


NEW_GAME_DS = 0xC30            # DATA1[15] is the new-game data segment from DS:0xC30
HERO_FLEETS = (0, 10, 30, 50, 40, 20)


def new_game(d1, plist):
    d = d1[15]
    ds = lambda a, n: d[a - NEW_GAME_DS:a - NEW_GAME_DS + n]
    year, month, day, tick = ds(0xC36, 4)                 # copied to the calendar by 0x15AC6
    heroes = []
    for i, k in enumerate(HERO_FLEETS):
        p = ds(0x1242 + i * 50, 50)
        x, y = struct.unpack_from("<HH", ds(0x2DB2 + k * 133, 4))
        port = min(plist, key=lambda q: (q["x"] - x) ** 2 + (q["y"] - y) ** 2)
        heroes.append({
            "name": (p[:13].split(b"\0")[0] + b" " + p[13:26].split(b"\0")[0]).decode("cp949").strip(),
            "leadership": p[0x1C], "seamanship": p[0x1D], "knowledge": p[0x1E], "intuition": p[0x1F],
            "courage": p[0x20], "swordplay": p[0x21], "charm": p[0x22], "luck": p[0x23],
            "navLevel": p[0x24], "battleLevel": p[0x25], "fleet": k, "port": port["id"],
            "nation": p[0x31] & 0xF, "skills": p[0x30],
        })
    persons = []
    for i in range(120):
        p = ds(0x1242 + i * 50, 50)
        persons.append({
            "name": (p[:13].split(b"\0")[0] + b" " + p[13:26].split(b"\0")[0]).decode("cp949", "replace").strip(),
            "stats": list(p[0x1C:0x24]), "navLevel": p[0x24], "battleLevel": p[0x25],
            "navExp": struct.unpack_from("<H", p, 0x26)[0], "battleExp": struct.unpack_from("<H", p, 0x28)[0],
            "loyalty": p[0x2B], "employer": p[0x2C], "port": p[0x2D], "status": p[0x2E],
            # +0x1A face; bits 0xC000 mark a face assembled from parts, i.e. a minor character
            # who can die at sea (0x192C3, 0x196D8). +0x2F bit 3 picks the casual speech lines.
            "generic": bool(p[0x1B] & 0xC0), "casual": bool(p[0x2F] & 8), "skills": p[0x30],
            "nation": p[0x31] & 0xF,                     # compared with the port's nation by the trader (0x2408A)
        })
    assert persons[85]["name"] == "미구엘 레아르" and persons[85]["port"] == 0
    assert heroes[0]["name"] == "조안 페레로" and port
    return {"year": 1501 + year, "month": month, "day": day, "tick": tick, "gold": struct.unpack("<I", ds(0x123A, 4))[0],
            "heroes": heroes, "persons": persons}


MARKETS = 0x697C               # 100 x 37 bytes, selected by 0x5B9E for ports below 100
TRADE_ZONES = 0x77F0           # 13 x 128 bytes, selected by market byte 0x21 (0x5BAE)
PORT_RECORDS = 0x5F54          # 20 bytes; byte 0x13 & 7 is the port's nation
DRINK_NAMES, DRINK_PRICES = DS + 0x7DE, DS + 0x7FA
SHIP_REGIONS, SHIP_COMMON = DS + 0xAECE, DS + 0xAF26   # 11 x 8 classes by region, 18 common classes
GOOD_NAMES, CATEGORY_NAMES, CATEGORY_ENDS = DS + 0x764, DS + 0x7CA, DS + 0x7C0


def ds_string(img, ptr_at):
    p = struct.unpack_from("<H", img, ptr_at)[0]
    return img[DS + p:DS + p + 16].split(b"\0")[0].decode("cp949")


def economy(img, d1):
    d = d1[15]
    markets = []
    for i in range(100):
        r = d[MARKETS + i * 37 - NEW_GAME_DS:MARKETS + (i + 1) * 37 - NEW_GAME_DS]
        markets.append({
            "economy": struct.unpack_from("<I", r, 0)[0], "industry": struct.unpack_from("<I", r, 4)[0],
            "support": list(r[8:14]), "prices": list(r[14:24]), "drink": r[0x24],
            "specialty": r[0x1A], "specialtyPrice": struct.unpack_from("<H", r, 0x18)[0], "specialtyEconomy": 10 * r[0x1B],
            "zone": r[0x21], "shipRegion": r[0x22], "nation": d[PORT_RECORDS + i * 20 + 0x13 - NEW_GAME_DS] & 7,
        })
    zones = []
    for z in range(13):
        r = d[TRADE_ZONES + z * 128 - NEW_GAME_DS:TRADE_ZONES + (z + 1) * 128 - NEW_GAME_DS]
        sold = [{"good": r[0x6E + k], "price": struct.unpack_from("<H", r, 0x5C + k * 2)[0], "economy": 10 * r[0x77 + k]}
                for k in range(9) if r[0x6E + k] != 0xFF]
        zones.append({"goods": sold, "sellPrices": list(struct.unpack_from("<46H", r, 0))})
    ends = list(img[CATEGORY_ENDS:CATEGORY_ENDS + 10])
    goods = [{"name": ds_string(img, GOOD_NAMES + i * 2), "category": next(c for c, e in enumerate(ends) if e > i)}
             for i in range(46)]
    categories = [ds_string(img, CATEGORY_NAMES + i * 2) for i in range(10)]
    drinks = []
    for i in range(14):
        p = struct.unpack_from("<H", img, DRINK_NAMES + i * 2)[0]
        drinks.append({"name": img[DS + p:DS + p + 16].split(b"\0")[0].decode("cp949"), "price": img[DRINK_PRICES + i]})
    assert markets[0]["economy"] == 780 and drinks[1]["name"] == "와인"
    assert goods[45]["name"] == "목재" and categories[9] == "기타" and zones[0]["goods"][0] == {"good": 11, "price": 30, "economy": 0}
    regions = [[c for c in img[SHIP_REGIONS + r * 8:SHIP_REGIONS + r * 8 + 8] if c != 0xFF] for r in range(11)]
    common = list(img[SHIP_COMMON:SHIP_COMMON + 18])
    assert max(m["shipRegion"] for m in markets) < 11 and common[17] == 13
    cannons = []
    for i in range(1, 8):                     # 0 is "미탑재"; tables DS:0x808 names, 0x818/0x828/0x838 stats, 0x848 price
        word = lambda t: struct.unpack_from("<H", img, DS + t + i * 2)[0]
        cannons.append({"name": ds_string(img, DS + 0x808 + i * 2), "power": word(0x818), "range": word(0x828),
                        "stat3": word(0x838), "price": word(0x848)})
    assert cannons[0]["name"] == "캐논" and cannons[6]["price"] == 600
    return {"markets": markets, "drinks": drinks, "zones": zones, "goods": goods, "categories": categories,
            "shipRegions": regions, "commonShips": common, "cannons": cannons}


def strings(blob):
    return [s.decode("cp949", "replace") for s in blob.split(b"\0") if s]


def be_offsets(blob, size):
    fmt = ">I" if size == 4 else ">H"
    first = struct.unpack_from(fmt, blob)[0]
    return [struct.unpack_from(fmt, blob, i)[0] for i in range(0, first, size)]


def table_strings(blob, size):
    offs = be_offsets(blob, size) + [len(blob)]
    return [blob[a:b].split(b"\0")[0].decode("cp949", "replace") for a, b in zip(offs, offs[1:])]


def item_texts(blob):
    """ITEM.MES: one 0x7C-byte record per item id (0x28C9A reads item·0x7C)."""
    return [blob[i:i + 0x7C].split(b"\0")[0].decode("cp949", "replace").rstrip() for i in range(0, len(blob) - 0x7B, 0x7C)]


def menu_items(blob):
    """MENU.DAT entries as item lists: two header bytes (width, count), then NUL-separated items."""
    offs = be_offsets(blob, 2) + [len(blob)]
    return [[t.decode("cp949", "replace") for t in blob[a + 2:b].split(b"\0") if t] for a, b in zip(offs, offs[1:])]


def main():
    for sub in ("", "/portraits", "/images"):
        os.makedirs(OUT + sub, exist_ok=True)
    _, img, _ = mzdis.load(GAME + "/MAIN.EXE")
    pal = K.bbr_table(img)
    d1 = ls11.unpack(GAME + "/DATA1.LZW")

    cells, bad = worldmap.decode_world(GAME, img)
    assert bad == 0
    mask = build_tiles(cells, d1[11], d1[18])
    open(OUT + "/world_mask.bin", "wb").write(mask)
    png.write_png(OUT + "/minimap.png", 1080, 540, b"".join(
        (bytes((14, 42, 74)) if mask[y * 2 * 2160 + x * 2] == SEA else bytes((128, 150, 104))) for y in range(540) for x in range(1080)))

    plist = ports(img)
    start = next(p for p in plist if p["name"] == "리스본")
    seen = reachable(mask, (start["x"], start["y"]))
    near = 0
    for p in plist:
        p["reachable"] = any(seen[(p["y"] + dy) * 2160 + (p["x"] + dx) % 2160] for dy in range(-5, 6) for dx in range(-5, 6))
        near += p["reachable"]
    json.dump({"ports": plist}, open(OUT + "/ports.json", "w"), ensure_ascii=False, indent=0)

    kao = ls11.unpack(GAME + "/KAO.LZW")
    faces = 0
    for i, k in enumerate(kao):
        if len(k) == 1920:
            png.write_png(f"{OUT}/portraits/{i:03}.png", 64, 80, rgb(K.planar_bytes(k, 64, 80, 3), pal))
            faces += 1

    g = open(GAME + "/GRAPH.DAT", "rb").read()
    offs = K.offset_table(g)
    for i, o in enumerate(offs):
        w, h, px, _ = K.decode_rle4(g, o)
        png.write_png(f"{OUT}/images/graph_{i:02}.png", w, h, rgb(px, pal))

    # The world chart (항해도, 0x1D340) shows picture 25 with the parchment palette DS:0xAF50.
    w, h, px, _ = K.decode_rle4(g, offs[25])
    png.write_png(f"{OUT}/images/chart.png", w, h, rgb(px, K.bbr_table(img, DS + 0xAF50)))

    # GRAPH2.DAT: the YES/NO box (image 0, 0x13FDB) and the hero select background (image 1,
    # 0x15E5F), which is shown with its own palette DS:0xAADE (newgame.md §3.1).
    g2 = open(GAME + "/GRAPH2.DAT", "rb").read()
    for i, o in enumerate(K.offset_table(g2)):
        w, h, px, _ = K.decode_rle4(g2, o)
        png.write_png(f"{OUT}/images/graph2_{i}.png", w, h, rgb(px, K.bbr_table(img, DS + 0xAADE) if i == 1 else pal))

    # Story pictures for script opcode CB (EVENT{hero+1}.DAT), same container as GRAPH.DAT.
    for n in range(7):
        e = open(f"{GAME}/EVENT{n}.DAT", "rb").read()
        for i, o in enumerate(K.offset_table(e)):
            w, h, px, _ = K.decode_rle4(e, o)
            png.write_png(f"{OUT}/images/event{n}_{i}.png", w, h, rgb(px, pal))

    # The scenario VM runs against the data segment as a new game starts (MAIN.EXE DS with
    # DATA1[15] over DS:0xC30..), and the script files themselves.
    seg = bytearray(img[DS:DS + 0x10000])
    seg[NEW_GAME_DS:NEW_GAME_DS + len(d1[15])] = d1[15]
    seg += bytes(0x10000 - len(seg))
    open(OUT + "/ds.bin", "wb").write(seg)
    os.makedirs(OUT + "/scenario", exist_ok=True)
    for n in range(7):
        shutil.copyfile(f"{GAME}/SNR{n}.DAT", f"{OUT}/scenario/SNR{n}.DAT")
    shutil.copyfile(f"{GAME}/COLONY.DAT", f"{OUT}/scenario/COLONY.DAT")   # discoveries, 0xDA-byte records
    shutil.copyfile(f"{GAME}/MONSTER.DAT", f"{OUT}/scenario/MONSTER.DAT") # sea event points (sea_events.md)
    # Route graph for fleets out of sight (DATA1[4], node count DATA1[5]): 16-byte nodes
    # x, y, next[4] (u16, 0xFFFF none), cost[4] (u8). docs/re/fleets.md §2.4.
    assert struct.unpack_from("<H", d1[5], 0)[0] == 622
    open(OUT + "/routes.bin", "wb").write(d1[4])
    shutil.copyfile(f"{GAME}/NAME.TBL", f"{OUT}/scenario/NAME.TBL")      # names for generated persons

    text = {
        "menu": table_strings(open(GAME + "/MENU.DAT", "rb").read(), 2),
        "menus": menu_items(open(GAME + "/MENU.DAT", "rb").read()),
        "message": table_strings(open(GAME + "/MESSAGE.DAT", "rb").read(), 2),
        "items": item_texts(open(GAME + "/ITEM.MES", "rb").read()),
    }
    for n in range(7):
        text[f"scenario{n}"] = table_strings(open(f"{GAME}/SNR{n}.MES", "rb").read(), 4)
    json.dump(text, open(OUT + "/text.json", "w"), ensure_ascii=False, indent=0)
    json.dump({"palette": pal}, open(OUT + "/palette.json", "w"))
    nav = navigation(img, open(GAME + "/WINDCUR.DAT", "rb").read())
    nav["newGame"] = new_game(d1, plist)
    nav.update(economy(img, d1))
    print("new game", {k: v for k, v in nav["newGame"].items() if k != "heroes"},
          [(h["name"], h["port"]) for h in nav["newGame"]["heroes"]])
    json.dump(nav, open(OUT + "/navigation.json", "w"), ensure_ascii=False)
    arrows = "↑↗→↘↓↙←↖"
    for name in ("windSummer", "windWinter", "current"):
        print(name)
        for r in range(15):
            print("  " + "".join(arrows[(b >> 3) & 7] if b & 7 else "·" for b in nav[name][r * 30:(r + 1) * 30]))

    hist = collections.Counter(mask)
    print(f"mask sea={hist[SEA]} land={hist[LAND]} rough={hist[ROUGH]}")
    print(f"ports={len(plist)} reachable={near} unreachable={[p['name'] for p in plist if not p['reachable']]}")
    print(f"portraits={faces} images={len(offs)} text={ {k: len(v) for k, v in text.items()} }")


if __name__ == "__main__":
    main()
