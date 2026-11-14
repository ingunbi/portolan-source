#!/usr/bin/env python3
"""Reverse-engineering helpers for MAIN.EXE.

usage:
  re.py dis ADDR [LEN]        disassemble the load image (hex addresses)
  re.py ds OFF [LEN]          hex dump of the data segment as a new game starts (DATA1[15] over MAIN)
  re.py words OFF N           N little-endian words from the data segment
  re.py msg N [M]             MESSAGE.DAT lines N..M
  re.py menu N [M]            MENU.DAT lines
  re.py calls ADDR            every call / lcall to a code address
  re.py refs OFF              instructions whose memory operand or immediate is a DS offset
  re.py snr N [OFF [LEN]]     hex dump of SNRn.DAT
"""
import json, os, pickle, re, struct, sys

sys.path.insert(0, os.path.dirname(__file__))
import ls11, mzdis
from capstone import Cs, CS_ARCH_X86, CS_MODE_16

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = ROOT + "/original/GAME"
DS = 0x378B0
NEW_GAME_DS = 0xC30
CACHE = ROOT + "/build/re_cache.pickle"


def image():
    _, img, rel = mzdis.load(GAME + "/MAIN.EXE")
    return img, rel


def data_segment():
    img, _ = image()
    seg = bytearray(img[DS:])
    d = ls11.unpack(GAME + "/DATA1.LZW")[15]
    seg[NEW_GAME_DS:NEW_GAME_DS + len(d)] = d
    return bytes(seg)


def text(name):
    return json.load(open(ROOT + "/assets/text.json"))[name]


def listing():
    """Linear disassembly of the code segments, cached."""
    if os.path.exists(CACHE):
        return pickle.load(open(CACHE, "rb"))
    img, _ = image()
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    out = []
    a = 0
    while a < DS:
        got = False
        for i in md.disasm(img[a:DS], a):
            out.append((i.address, i.mnemonic, i.op_str))
            a = i.address + i.size
            got = True
        if not got or a < DS:
            a += 1
    pickle.dump(out, open(CACHE, "wb"))
    return out


def far_target(op):
    m = re.match(r"0x([0-9a-f]+), 0x([0-9a-f]+)", op)
    if m:
        return int(m.group(1), 16) * 16 + int(m.group(2), 16)
    m = re.match(r"0, 0x([0-9a-f]+)", op)
    return int(m.group(1), 16) if m else None


def main():
    cmd, args = sys.argv[1], [int(x, 16) for x in sys.argv[2:]]
    if cmd == "dis":
        img, _ = image()
        md = Cs(CS_ARCH_X86, CS_MODE_16)
        a, n = args[0], args[1] if len(args) > 1 else 0x100
        for i in md.disasm(img[a:a + n], a):
            note = ""
            if i.mnemonic == "lcall":
                t = far_target(i.op_str)
                note = f"   ; -> {t:#x}" if t is not None else ""
            print(f"{i.address:06x} {i.bytes.hex():<14} {i.mnemonic} {i.op_str}{note}")
    elif cmd in ("ds", "words"):
        seg = data_segment()
        off = args[0]
        if cmd == "words":
            n = args[1]
            print(" ".join(str(v) for v in struct.unpack_from(f"<{n}H", seg, off)))
            return
        n = args[1] if len(args) > 1 else 0x40
        for r in range(off, off + n, 16):
            b = seg[r:min(r + 16, off + n)]
            print(f"{r:05x}  {b.hex(' '):<48}  {b.decode('cp949', 'replace')!r}")
    elif cmd in ("msg", "menu"):
        t = text("message" if cmd == "msg" else "menu")
        a = int(sys.argv[2])
        b = int(sys.argv[3]) if len(sys.argv) > 3 else a
        for k in range(a, b + 1):
            print(k, repr(t[k]))
    elif cmd == "calls":
        t = args[0]
        for a, m, op in listing():
            if m == "call" and op == hex(t) or m == "lcall" and far_target(op) == t:
                print(f"{a:06x} {m} {op}")
    elif cmd == "refs":
        t = hex(args[0])
        pat = re.compile(r"(?<![0-9a-fx])" + re.escape(t) + r"(?![0-9a-f])")
        for a, m, op in listing():
            if pat.search(op) and m not in ("call", "jmp") and not m.startswith("j"):
                print(f"{a:06x} {m} {op}")
    elif cmd == "snr":
        d = open(f"{GAME}/SNR{args[0]}.DAT", "rb").read()
        off = args[1] if len(args) > 1 else 0
        n = args[2] if len(args) > 2 else 0x100
        for r in range(off, min(len(d), off + n), 16):
            print(f"{r:05x}  {d[r:r + 16].hex(' ')}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
