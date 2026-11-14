#!/usr/bin/env python3
"""Linear 16-bit disassembly of an MZ executable, with relocations marked.

usage: mzdis.py FILE [start_hex [len_hex]]   (addresses are load-image offsets)
"""
import struct, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_16


def load(path):
    b = open(path, "rb").read()
    h = dict(zip("sig lastp pages nreloc hdrp minp maxp ss sp csum ip cs lfarlc ovl".split(), struct.unpack_from("<14H", b)))
    size = (h["pages"] - 1) * 512 + (h["lastp"] or 512)
    img = b[h["hdrp"] * 16:size]
    rel = {seg * 16 + off for off, seg in (struct.unpack_from("<HH", b, h["lfarlc"] + i * 4) for i in range(h["nreloc"]))}
    return h, img, rel


if __name__ == "__main__":
    h, img, rel = load(sys.argv[1])
    start = int(sys.argv[2], 16) if len(sys.argv) > 2 else h["cs"] * 16 + h["ip"]
    n = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x100
    md = Cs(CS_ARCH_X86, CS_MODE_16)
    for i in md.disasm(img[start:start + n], start):
        print(f"{i.address:06x} {i.bytes.hex():<14} {i.mnemonic} {i.op_str}")
