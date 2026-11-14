#!/usr/bin/env python3
"""Print the NPC fleet state of a new game as JSON (see docs/re/fleets.md).

usage: extract_fleets.py [--nations] [--tables] [--graph] [game_dir]

Default output: the 70 fleet records (DS:0x2DB2, 133 B each) as they are when a new game
starts, i.e. MAIN.EXE's data segment with DATA1.LZW[15] copied over DS:0xC30.
  --nations  also the 7 nation records (DS:0x1106, 32 B each)
  --tables   also the monthly ship-rebuild tables (DS:0xAC98, 0xACC2, 0xACEC, 0xAD16)
  --graph    also the NPC route graph (DATA1.LZW[4], node count DATA1.LZW[5])
"""
import json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ls11

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DS = 0x378B0
NEW_GAME_DS = 0xC30

FLEETS, FLEET_SIZE, FLEET_COUNT = 0x2DB2, 133, 70
PERSONS, PERSON_SIZE = 0x1242, 50
PORTS, PORT_SIZE = 0x5F54, 20
SHIPS, SHIP_SIZE = 0x57CE, 25
NATIONS, NATION_SIZE = 0x1106, 32
NATION_NAMES = ["Portugal", "Spain", "Turkey", "England", "Italy", "Netherlands", "Pirates"]
CLASS_NAMES = ["Balsa", "Hansa Kogge", "Dhow", "Buss", "Tarette", "Caravela Latina",
               "Caravela Redonda", "Brigantine", "Nao", "Carrack", "Galleon", "Xebec",
               "Pinnace", "Sloop", "Frigate", "Barque", "Ship", "Junk", "Light Galley",
               "Flanders Galley", "Venetian Galley", "La Reale", "Ironclad", "Atakebune", "Sekibune"]
ROLES = {0: "hero", 1: "merchant", 2: "merchant", 3: "merchant", 4: "merchant",
         5: "galley", 6: "galley", 7: "galleon", 8: "galleon", 9: "galleon"}


def load_image(path):
    b = open(path, "rb").read()
    pages, lastp, hdrp = struct.unpack_from("<H", b, 4)[0], struct.unpack_from("<H", b, 2)[0], \
        struct.unpack_from("<H", b, 8)[0]
    size = (pages - 1) * 512 + (lastp or 512)
    return b[hdrp * 16:size]


def data_segment(game):
    seg = bytearray(load_image(game + "/MAIN.EXE")[DS:])
    d = ls11.unpack(game + "/DATA1.LZW")[15]
    seg[NEW_GAME_DS:NEW_GAME_DS + len(d)] = d
    return bytes(seg)


def cstr(b):
    return b.split(b"\0")[0].decode("cp949", "replace")


def person_name(seg, i):
    if i >= 120:
        return None
    r = seg[PERSONS + i * PERSON_SIZE:PERSONS + (i + 1) * PERSON_SIZE]
    return (cstr(r[0:13]) + " " + cstr(r[13:26])).strip()


def port_name(seg, i):
    if i >= 130:
        return None
    return cstr(seg[PORTS + i * PORT_SIZE + 4:PORTS + (i + 1) * PORT_SIZE])


def ship_class(seg, rec):
    return seg[SHIPS + rec * SHIP_SIZE + 0x12]


def fleets(seg):
    out = []
    for i in range(FLEET_COUNT):
        r = seg[FLEETS + i * FLEET_SIZE:FLEETS + (i + 1) * FLEET_SIZE]
        x, y, dx, dy, lx, ly, cflags, err = struct.unpack_from("<HHHHHHHh", r, 0)
        ships = []
        for s in range(10):
            crew, hull, maxhull, rudder, sail, guns, rec, fl = struct.unpack_from("<HBBBBBBB", r, 0x2B + 9 * s)
            if fl & 0x30 != 0x10:
                continue
            cls = ship_class(seg, rec)
            ships.append({"slot": s, "crew": crew, "hull": hull, "maxHull": maxhull, "rudder": rudder,
                          "sail": sail, "guns": guns, "shipRecord": rec, "class": cls,
                          "className": CLASS_NAMES[cls] if cls < 25 else None, "cannonType": fl & 7,
                          "flags": fl})
        admiral = r[0x2A]
        out.append({
            "index": i,
            "group": i // 10,                      # nation record index (6 = pirates)
            "role": ROLES[i % 10] if i < 60 else "pirate",
            "x": x, "y": y,
            "dest": [dx, dy],                      # +4/+6
            "localTarget": [lx, ly],               # +8/+0xA
            "routeFlags": cflags,                  # +0xC (word): bits0-2 slot, 4-7 slot mask, 8-15 = +0xD
            "lineError": err,                      # +0xE
            "waypoints": list(struct.unpack_from("<4H", r, 0x10)),
            "accum": [r[0x18], r[0x19]],
            "heading": r[0x1A],
            "mission": r[0x1B],
            "target": r[0x1C],                     # port (missions 0-2,9) or person (5-8,10)
            "spoils": list(r[0x1D:0x21]),
            "cargoGood": r[0x21],
            "cargoQty": struct.unpack_from("<H", r, 0x22)[0],
            "funds": struct.unpack_from("<H", r, 0x24)[0],
            "home": r[0x26], "homeName": port_name(seg, r[0x26]),
            "stay": r[0x27],
            "strength": r[0x28],
            "state": r[0x29],                      # 1 active, 0x10 in port, 0x20 docked/stopped, 0x40 script
            "active": bool(r[0x29] & 1),
            "admiral": admiral, "admiralName": person_name(seg, admiral),
            "ships": ships,
        })
    return out


def nations(seg):
    out = []
    for n in range(7):
        r = seg[NATIONS + n * NATION_SIZE:NATIONS + (n + 1) * NATION_SIZE]
        out.append({"index": n, "name": NATION_NAMES[n],
                    "power": struct.unpack_from("<H", r, 0)[0], "enemy": r[2], "policy": r[3],
                    "targetPort": r[4], "playerStanding": list(r[5:9]), "aggression": r[9],
                    "capital": r[0xA], "capitalName": port_name(seg, r[0xA]),
                    "relations": list(r[0xB:0x12]), "warState": list(r[0x12:0x19]),
                    "tail": list(r[0x19:0x20])})
    return out


def nibble_table(seg, off, base):
    """7 nations x 3 tiers of u16; three 4-bit class numbers each (rand(3) picks one)."""
    t = []
    for n in range(7):
        row = []
        for tier in range(3):
            w = struct.unpack_from("<H", seg, off + 2 * (3 * n + tier))[0]
            row.append([((w >> (4 * k)) & 0xF) + base - 40 for k in range(3)])
        t.append(row)
    return t


def tables(seg):
    return {
        "merchantClasses": nibble_table(seg, 0xAC98, 0x28),   # fleets 10n+1..4 (0x17CC3)
        "galleyClasses": nibble_table(seg, 0xACC2, 0x30),     # fleets 10n+5..6 (0x17DB7)
        "galleonClasses": nibble_table(seg, 0xACEC, 0x28),    # fleets 10n+7..9 (0x17EAC)
        "rivalUpgradeClasses": [[((seg[0xAD16 + t] >> (4 * k)) & 0xF) + 9 for k in range(2)]
                                for t in range(4)],          # 0x186DF, nibble = peerage/5
        "missionByPolicy": [struct.unpack_from("<H", seg, 0xBC42 + 2 * p)[0] for p in range(9)],
        "regionWeights": list(seg[0xAC50:0xAC58]),
    }


def graph(game):
    d = ls11.unpack(game + "/DATA1.LZW")
    n = struct.unpack_from("<H", d[5], 0)[0]
    nodes = []
    for i in range(n):
        x, y, a, b, c, e = struct.unpack_from("<6H", d[4], 16 * i)
        nb = [v if v != 0xFFFF else None for v in (a, b, c, e)]
        nodes.append({"x": x & 0x7FFF, "y": y, "next": nb, "cost": list(d[4][16 * i + 12:16 * i + 16])})
    return nodes


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    game = args[0] if args else ROOT + "/original/GAME"
    seg = data_segment(game)
    out = {"fleets": fleets(seg)}
    if "--nations" in sys.argv:
        out["nations"] = nations(seg)
    if "--tables" in sys.argv:
        out["tables"] = tables(seg)
    if "--graph" in sys.argv:
        out["routeGraph"] = graph(game)
    json.dump(out if len(out) > 1 else out["fleets"], sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
