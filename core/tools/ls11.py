#!/usr/bin/env python3
"""Koei LS10/LS11 archive decoder.

Layout: 'LS1x' magic + 12 zero bytes, 256-byte dictionary, then big-endian
(comp_size, raw_size, offset) triples terminated by a zero word, then bitstreams.
"""
import struct, sys


class Bits:
    def __init__(self, data):
        self.d, self.p, self.b = data, 0, 0

    def bit(self):
        v = (self.d[self.p] >> (7 - self.b)) & 1
        self.b += 1
        if self.b == 8:
            self.b, self.p = 0, self.p + 1
        return v

    def code(self):
        n, a = 0, 0
        while True:
            b = self.bit()
            a = (a << 1) | b
            n += 1
            if not b:
                break
        c = 0
        for _ in range(n):
            c = (c << 1) | self.bit()
        return a + c


def entries(blob):
    if blob[:3] != b"LS1":
        raise ValueError("not an LS1x archive")
    out, p = [], 0x110
    while True:
        csize = struct.unpack_from(">I", blob, p)[0]
        if csize == 0:
            return out
        rsize, off = struct.unpack_from(">II", blob, p + 4)
        out.append((csize, rsize, off))
        p += 12


def decode(blob, entry):
    csize, rsize, off = entry
    if csize == rsize:
        return blob[off:off + rsize]
    table, bits, out = blob[0x10:0x110], Bits(blob[off:off + csize]), bytearray()
    while len(out) < rsize:
        v = bits.code()
        if v < 256:
            out.append(table[v])
        else:
            dist, length = v - 256, bits.code() + 3
            for _ in range(length):
                out.append(out[-dist])
    if len(out) != rsize:
        raise ValueError(f"size mismatch {len(out)} != {rsize}")
    return bytes(out)


def unpack(path):
    blob = open(path, "rb").read()
    return [decode(blob, e) for e in entries(blob)]


if __name__ == "__main__":
    for path in sys.argv[1:]:
        blob = open(path, "rb").read()
        es = entries(blob)
        items = [decode(blob, e) for e in es]
        print(f"{path.split('/')[-1]:14} magic={blob[:4].decode()} n={len(es):4} raw={sum(map(len, items))} first={[len(i) for i in items[:6]]}")
