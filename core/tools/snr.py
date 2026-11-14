#!/usr/bin/env python3
"""Disassembler for the scenario scripts SNR0..6.DAT (Uncharted Waters II, Korean DOS).

usage:
  snr.py N                      whole file as pseudo-code (N = 0..6)
  snr.py N C.S                  one block (chapter C, sub-block S)
  snr.py N --triggers           only the trigger tables
  snr.py N --check              decode everything, report desyncs / bad targets, exit 1 on error
  snr.py all --check            check all seven files

options:  --short   truncate dialogue to one line of 60 chars
          --raw     add the instruction bytes to every line
          --plain   one instruction per line (default folds `win; face; say; wait` into SAY[...])

File format and VM semantics: docs/re/scenario.md.  VM code in MAIN.EXE:
main loop 0x32B8B, class dispatch 0x00-3F 0x323B1, 0x40-7F 0x325B1, 0x80-BF 0x326EB,
0xC0-FF 0x3287A (jump table 0x3289E).
"""
import json, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0

# ---------------------------------------------------------------- names

BUILDINGS = {0: "market", 1: "tavern", 2: "shipyard", 3: "harbor", 4: "inn", 5: "palace",
             6: "guild", 7: "residence", 8: "bank", 9: "item_shop", 10: "church",
             11: "fortune_teller", 0x15: "palace_audience", 0xFF: "any"}
SPECIAL_K1 = {0xA0: "AT_SEA", 0xA1: "BATTLE_START", 0xA2: "BATTLE_END", 0xA3: "ANY_PORT"}
SYSVARS = ["text_buffer", "sea_area", "year", "month", "day", "port", "duel_result", "tick"]
# D0/DC record tables: (name, DS base, record size)  - handler 0x3162E
TABLES = [("hero_tbl", 0x1106, 32), ("family", 0x11E6, 14), ("gold", 0x123A, 0),
          ("person", 0x1242, 50), ("npc", 0x29B2, 21), ("woman", 0x2B56, 17),
          ("player", 0x2D54, 0), ("ship_slot", None, 9), ("fleet", 0x2DB2, 0x85),
          ("cargo", 0x5210, 30), ("ship", 0x57CE, 25), ("ship_type", 0x5E28, 12),
          ("port", 0x5F54, 20), ("market", 0x697C, 37), ("trade_zone", 0x77F0, 128),
          ("yard_stock", 0x7E70, 8), ("supply_pt", 0x7E88, 7), ("item_def", 0x8144, 26),
          ("discovery", 0xBEF6, 0xDA), ("tbl19", 0xC0B6, 2)]
# named fields of the two fixed blocks (DC/D0 tables 2 and 6)
DS_NAMES = {0x123A: "gold (u32)", 0x123E: "bank balance (s16, x100)", 0x1240: "bank (u16)",
            0x1241: "hero id", 0x2D54: "days at sea", 0x2D55: "water ration", 0x2D56: "food ration"}
DS_NAMES.update({0x2D57 + k: f"officer[{k}]" for k in range(30)})
DS_NAMES.update({0x2D75 + k: f"salary[{k}]" for k in range(30)})
DS_NAMES.update({0x2D93 + k: f"item[{k}]" for k in range(20)})
SHIP_TYPES = ["발사", "한자콕", "다우", "버스", "타렛테", "카라벨 라티나", "카라벨 레돈다", "브리간틴",
              "나오", "카락", "갤리온", "지벡", "파네스", "슬루프", "프리게이트", "바그", "쉽", "정크",
              "경갤리", "플랜더스 갤리", "베네치안 갤리", "라 레아르", "철갑선", "안택선", "관선"]


class Names:
    """Port / person / NPC / woman / item names from MAIN.EXE's data segment (new-game state)."""

    def __init__(self):
        self.ports, self.persons, self.npcs, self.women, self.items = {}, {}, {}, {}, {}
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import ls11, mzdis
            _, img, _ = mzdis.load(GAME + "/MAIN.EXE")
            seg = bytearray(img[DS:])
            d = ls11.unpack(GAME + "/DATA1.LZW")[15]
            seg[0xC30:0xC30 + len(d)] = d
        except Exception:
            return

        def s(o, n):
            return bytes(seg[o:o + n]).split(b"\0")[0].decode("cp949", "replace")

        for i in range(130):
            self.ports[i] = s(0x5F54 + i * 20 + 4, 14)
        for i in range(120):
            self.persons[i] = (s(0x1242 + i * 50, 13) + " " + s(0x1242 + i * 50 + 13, 13)).strip()
        for i in range(20):
            self.npcs[i] = s(0x29B2 + i * 21, 16)
        for i in range(30):
            self.women[i] = s(0x2B56 + i * 17, 11)
        for i in range(120):
            nm = s(0x8144 + i * 26, 20)
            if nm:
                self.items[i] = nm

    def port(self, k):
        return self.ports.get(k, f"port{k}")


NAMES = None


def names():
    global NAMES
    if NAMES is None:
        NAMES = Names()
    return NAMES


def mes_lines(n):
    try:
        return json.load(open(ROOT + "/assets/text.json"))[f"scenario{n}"]
    except Exception:
        d = open(f"{GAME}/SNR{n}.MES", "rb").read()
        cnt = struct.unpack_from(">I", d, 0)[0] // 4
        offs = [struct.unpack_from(">I", d, i * 4)[0] for i in range(cnt)] + [len(d)]
        return [d[offs[i]:offs[i + 1]].split(b"\0")[0].decode("cp949", "replace") for i in range(cnt)]


# ---------------------------------------------------------------- file layout

def chapters(d):
    """[(chapter_base, [absolute block offsets])] from the SNDT header."""
    assert d[:4] == b"SNDT", "not an SNDT file"
    out, i = [], 0x10
    while True:
        base = struct.unpack_from(">I", d, i)[0]
        i += 4
        if base == 0xFFFFFFFF:
            break
        subs, j = [], base
        while True:
            v = struct.unpack_from(">H", d, j)[0]
            j += 2
            if v == 0xFFFF:
                break
            subs.append(base + v)
        out.append((base, subs))
    return out


def blocks(d):
    """[(chapter, sub, start, end)]; a block runs to the next block or chapter header."""
    chs = chapters(d)
    starts = sorted({b for _, subs in chs for b in subs} | {base for base, _ in chs} | {len(d)})
    out = []
    for c, (_, subs) in enumerate(chs):
        for s, b in enumerate(subs):
            out.append((c, s, b, next(x for x in starts if x > b)))
    return out


def triggers(d, start):
    """Trigger table at the head of a block: [(k1, k2, rel_offset)], table length."""
    out, i = [], start
    while True:
        k1, k2, off = d[i], d[i + 1], struct.unpack_from(">H", d, i + 2)[0]
        i += 4
        if k1 == 0xFF:
            return out, i - start
        out.append((k1, k2, off))


def trigger_text(k1, k2):
    if k1 in SPECIAL_K1:
        what = SPECIAL_K1[k1]
        if k1 == 0xA0:
            arg = "any day" if k2 == 0xFF else f"day {k2}"
        elif k1 in (0xA1, 0xA2):
            arg = "any admiral" if k2 == 0xFF else f"admiral {k2} {names().persons.get(k2, '')}".rstrip()
        else:
            arg = BUILDINGS.get(k2, f"bldg{k2}")
        return f"{what}/{arg}"
    return f"{names().port(k1)}({k1})/{BUILDINGS.get(k2, f'bldg{k2:#x}')}"


# ---------------------------------------------------------------- decoder

class Insn:
    __slots__ = ("pc", "size", "text", "targets", "ends", "bad", "line")

    def __init__(self, pc, size, text, targets=(), ends=False, bad=False, line=None):
        self.pc, self.size, self.text = pc, size, text
        self.targets, self.ends, self.bad, self.line = list(targets), ends, bad, line


def src(mode, b, byte=False):
    """Source operand (resolver 0x322FE)."""
    return [f"v{b}", f"{'byte' if byte else 'word'}[v{b}]", f"f{b}", f"{b}"][mode]


def decode(code, pc):
    """Decode one instruction at block-relative pc.  code = the block bytes."""
    op = code[pc]

    def b(k):
        return code[pc + k]

    def w(k):
        return (code[pc + k] << 8) | code[pc + k + 1]

    cls = op >> 6
    if cls == 0:  # MOV  00DDSSAA   (0x323B1)
        a, s, dd = op & 3, (op >> 2) & 3, (op >> 4) & 3
        if a == 2 or dd == 3 or (dd < 2 and s == 2) or (dd == 2 and s == 0) or (dd == 2 and a != 0):
            return Insn(pc, 1, f"BAD_MOV {op:#04x}", bad=True)
        d1, s1 = b(1), b(2)
        if a == 3:
            name = SYSVARS[s1] if s1 < 8 else f"sys{s1}?"
            if s1 == 0:
                return Insn(pc, 3, f"strcpy(word[v{d1}] -> char*, text_buffer)")
            return Insn(pc, 3, f"v{d1} = {name}", bad=s1 > 7)
        size = 3
        if dd != 2 and a == 0 and s == 3:
            rhs, size = f"{w(2)}", 4
        else:
            rhs = src(s, s1, byte=(a == 1))
        if dd == 0:
            lhs = f"v{d1}"
            if a == 1 and s != 3:
                rhs = f"(u8){rhs}" if s == 0 else rhs
        elif dd == 1:
            lhs = f"{'byte' if a == 1 else 'word'}[v{d1}]"
        else:
            lhs = f"f{d1}"
            rhs = rhs if s == 3 else f"({rhs} != 0)"
        return Insn(pc, size, f"{lhs} = {rhs}")

    if cls == 1:  # ARITH  01oDSSoo  (0x325B1)
        o = op & 0x23
        dd, s = (op >> 4) & 1, (op >> 2) & 3
        sym = {0: "+=", 1: "-=", 2: "*=", 3: "/=", 0x20: "|=", 0x21: "&=", 0x22: ">>=", 0x23: "<<="}[o]
        lhs = f"byte[v{b(1)}]" if dd else f"v{b(1)}"
        rhs = src(s, b(2), byte=True) if s else f"v{b(2)}"
        return Insn(pc, 3, f"{lhs} {sym} {rhs}")

    if cls == 2:  # conditional jump  10LLRRcc  (0x326EB): jump when the condition is FALSE
        c, r, l = op & 3, (op >> 2) & 3, (op >> 4) & 3
        if l == 3 or (l == 2 and r < 2) or (l == 2 and c >= 2):
            return Insn(pc, 1, f"BAD_JCC {op:#04x}", bad=True)
        if l == 2:
            if r == 2:
                t = w(3)
                return Insn(pc, 5, f"if f{b(1)} != f{b(2)} goto {t:04x}", [t])
            t = w(2)
            return Insn(pc, 4, f"if {'!' if c & 1 else ''}f{b(1)} goto {t:04x}", [t])
        left = f"v{b(1)}" if l == 0 else f"word[v{b(1)}]"
        right = src(r, b(2))
        neg = ["!=", "==", "<", ">"][c]  # negation of EQ, NE, GE, LE (unsigned)
        t = w(3)
        return Insn(pc, 5, f"if {left} {neg} {right} goto {t:04x}", [t])

    # 0xC0..0xFF  (0x3287A)
    N = names()
    if op == 0xC0:
        return Insn(pc, 2, f"win {b(1)}")
    if op == 0xC3:
        return Insn(pc, 1, "win_close")
    if op == 0xC4:
        return Insn(pc, 1, "win_close_all")
    if op == 0xC5:
        return Insn(pc, 2, f"win_clear {b(1)}")
    if op == 0xC7:
        return Insn(pc, 1, "wait")
    if op == 0xC8:
        return Insn(pc, 3, f"say #{w(1)}", line=w(1))
    if op == 0xC9:
        return Insn(pc, 4, f"v{b(1)} = menu #{w(2)}", line=w(2))
    if op == 0xCA:
        return Insn(pc, 2, f"bgm {b(1)}")
    if op == 0xCB:
        return Insn(pc, 6, f"picture {b(5)} at ({w(1)},{w(3)})")
    if op == 0xCC:
        return Insn(pc, 3, f"face {w(1)}")
    if op == 0xCD:
        return Insn(pc, 2, f"face v{b(1)}")
    if op in (0xD0, 0xDC):
        d1, t, i, f = b(1), b(2), b(3), b(4)
        if t >= len(TABLES):
            return Insn(pc, 5, f"v{d1} = &table{t}?[{i}]+{f:#x}", bad=True)
        tn, base, size = TABLES[t]
        if size == 0:  # fixed block: index ignored
            a = base + f
            return Insn(pc, 5, f"v{d1} = &DS:{a:#06x}   ; {DS_NAMES.get(a, tn + f'+{f:#x}')}")
        if op == 0xD0:
            return Insn(pc, 5, f"v{d1} = &{tn}[v{i}]+{f:#x}")
        note = ""
        nm = {3: N.persons, 4: N.npcs, 5: N.women, 12: N.ports, 17: N.items}.get(t, {}).get(i)
        if nm:
            note = f"   ; {nm}"
        if base is not None:
            note = f"   ; DS:{base + i * size + f:#06x}" + (f" {nm}" if nm else "")
        return Insn(pc, 5, f"v{d1} = &{tn}[{i}]+{f:#x}{note}")
    if op == 0xD1:
        return Insn(pc, 2, f"fleet_replan v{b(1)}   ; recompute AI course of fleet v{b(1)}")
    if op == 0xD4:
        return Insn(pc, 3, f"text_buffer = #{w(1)}", line=w(1))
    if op == 0xE2:
        return Insn(pc, 3, f"cargo_add good=v{b(1)} qty=v{b(2)}")
    if op == 0xE3:
        return Insn(pc, 3, f"cargo_take good=v{b(1)} qty=v{b(2)}   ; v{b(2)} = amount left in fleet")
    if op == 0xE4:
        return Insn(pc, 2, f"gold = v{b(1)}")
    if op == 0xE6:
        return Insn(pc, 2, f"gold += v{b(1)}")
    if op == 0xE7:
        return Insn(pc, 2, f"gold -= v{b(1)}")
    if op == 0xE8:
        return Insn(pc, 2, f"duel {b(1)}   ; {N.persons.get(b(1), '')}")
    if op == 0xE9:
        return Insn(pc, 2, f"f{b(1)} = yes_no()")
    if op == 0xEA:
        return Insn(pc, 2, f"v{b(1)} = gold / 10000")
    if op == 0xEB:
        return Insn(pc, 4, f"v{b(1)} = rand({w(2)})")
    if op == 0xEC:
        return Insn(pc, 2, f"seed = v{b(1)} << 8")
    if op == 0xED:
        return Insn(pc, 2, f"v{b(1)} = seed >> 8")
    if op == 0xEE:
        return Insn(pc, 2, f"v{b(1)} = cargo_free()")
    if op == 0xF0:
        return Insn(pc, 1, "next_block")
    if op == 0xF1:
        return Insn(pc, 1, "next_chapter")
    if op == 0xF2:
        return Insn(pc, 1, "end", ends=True)
    if op == 0xF4:
        return Insn(pc, 2, f"ending {b(1):#04x}", ends=True)
    if op == 0xF8:
        return Insn(pc, 1, "leave")
    if op == 0xF9:
        t = b(1)
        return Insn(pc, 3, f"order_ship {t} {b(2)}   ; {SHIP_TYPES[t] if t < 25 else '?'}")
    if op == 0xFA:
        return Insn(pc, 4, f"deliver_ship {b(1)} name=#{w(2)}", line=w(2))
    if op == 0xFB:
        return Insn(pc, 2, f"join {b(1)}   ; {N.persons.get(b(1), '')}")
    if op == 0xFC:
        return Insn(pc, 3, f"woman[{b(1)}].affection += {b(2)}   ; {N.women.get(b(1), '')}")
    if op == 0xFE:
        return Insn(pc, 3, f"goto {w(1):04x}", [w(1)], ends=True)
    if op == 0xFF:
        return Insn(pc, 1, "nop")
    return Insn(pc, 1, f"BAD {op:#04x}", bad=True)


def disasm_block(d, start, end):
    """Linear sweep of one block.  Returns (triggers, insns, errors)."""
    code = d[start:end]
    trig, tlen = triggers(d, start)
    insns, errs, pc = [], [], tlen
    while pc < len(code):
        try:
            ins = decode(code, pc)
        except IndexError:
            errs.append(f"{pc:04x}: truncated instruction")
            break
        insns.append(ins)
        if ins.bad:
            errs.append(f"{pc:04x}: {ins.text}")
        pc += ins.size
    if pc != len(code) and not errs:
        errs.append(f"block overrun by {pc - len(code)} bytes")
    bounds = {i.pc for i in insns}
    for k1, k2, off in trig:
        if off not in bounds:
            errs.append(f"trigger {k1:02x}/{k2:02x} -> {off:04x} is not an instruction boundary")
    for i in insns:
        for t in i.targets:
            if t not in bounds:
                errs.append(f"{i.pc:04x}: jump target {t:04x} is not an instruction boundary")
    # the last instruction must not fall off the end of the block
    if insns and not insns[-1].ends:
        errs.append(f"{insns[-1].pc:04x}: block ends without end/goto")
    return trig, insns, errs


def fmt_line(t, short):
    t = t.replace("\n", "\\n")
    if short and len(t) > 60:
        t = t[:60] + "…"
    return f'"{t}"'


def dump(n, only=None, trig_only=False, short=False, raw=False, plain=False, out=sys.stdout):
    d = open(f"{GAME}/SNR{n}.DAT", "rb").read()
    lines = mes_lines(n)
    total_errs = 0
    for c, s, start, end in blocks(d):
        if only and (c, s) != only:
            continue
        trig, insns, errs = disasm_block(d, start, end)
        total_errs += len(errs)
        print(f"\n=== SNR{n} chapter {c} block {s}   file {start:#06x}..{end:#06x}", file=out)
        labels = {}
        for k1, k2, off in trig:
            labels.setdefault(off, []).append(trigger_text(k1, k2))
            print(f"  trigger {k1:02x} {k2:02x} -> {off:04x}   {trigger_text(k1, k2)}", file=out)
        for e in errs:
            print(f"  !! {e}", file=out)
        if trig_only:
            continue
        targets = {t for i in insns for t in i.targets}
        code = d[start:end]
        k = 0
        while k < len(insns):
            i = insns[k]
            if i.pc in labels:
                print(f"\n{i.pc:04x}:  ; <= {', '.join(labels[i.pc])}", file=out)
            elif i.pc in targets:
                print(f"{i.pc:04x}:", file=out)
            text, n = i.text, 1
            if not plain:
                text, n = merge_dialogue(insns, k, code, labels.keys() | targets)
            if n == 1 and i.line is not None:
                t = lines[i.line] if i.line < len(lines) else "<no such line>"
                text += "  " + fmt_line(t, short)
            elif n > 1:
                ln = insns[k + n - 1 if code[insns[k + n - 1].pc] == 0xC8 else k + n - 2].line
                t = lines[ln] if ln < len(lines) else "<no such line>"
                text += "  " + fmt_line(t, short)
            last = insns[k + n - 1]
            rb = f"{code[i.pc:last.pc + last.size].hex(' '):<18} " if raw else ""
            print(f"  {i.pc:04x} {start + i.pc:05x}  {rb}{text}", file=out)
            k += n
    return total_errs


def merge_dialogue(insns, k, code, labels):
    """Fold `win n; [face p;] say #l; [wait]` into one line when nothing jumps inside it."""
    ops = [code[x.pc] for x in insns[k:k + 4]]
    if not ops or ops[0] != 0xC0:
        return insns[k].text, 1
    j, face = 1, ""
    if j < len(ops) and ops[j] in (0xCC, 0xCD):
        face = insns[k + j].text.split(" ", 1)[1]
        j += 1
    if j >= len(ops) or ops[j] != 0xC8:
        return insns[k].text, 1
    say = insns[k + j]
    j += 1
    wait = j < len(ops) and ops[j] == 0xC7
    if wait:
        j += 1
    if any(x.pc in labels for x in insns[k + 1:k + j]):
        return insns[k].text, 1
    win = code[insns[k].pc + 1]
    head = f"SAY[w{win}" + (f" face {face}" if face else "") + "]"
    return f"{head} #{say.line}" + ("" if wait else " (no wait)"), j


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        print(__doc__)
        return
    files = range(7) if args[0] == "all" else [int(args[0])]
    only = tuple(int(x) for x in args[1].split(".")) if len(args) > 1 else None
    if "--check" in opts:
        bad = 0
        for n in files:
            d = open(f"{GAME}/SNR{n}.DAT", "rb").read()
            cnt = 0
            for c, s, start, end in blocks(d):
                trig, insns, errs = disasm_block(d, start, end)
                cnt += len(insns)
                for e in errs:
                    print(f"SNR{n} {c}.{s} ({start:#x}): {e}")
                bad += len(errs)
            print(f"SNR{n}: {len(blocks(d))} blocks, {cnt} instructions")
        sys.exit(1 if bad else 0)
    dump(files[0], only, "--triggers" in opts, "--short" in opts, "--raw" in opts, "--plain" in opts)


if __name__ == "__main__":
    main()
