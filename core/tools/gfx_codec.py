#!/usr/bin/env python3
"""Decoders for the game's bitmap formats (routines at MAIN.EXE image 0xFC4 / 0x12FD).

Compressed image: u16le width (bit 15 = flag), u16le height, 8 x u16le dictionary, stream.
The stream works in 4-pixel-wide units. A 4-plane unit is a 16-bit value holding one
nibble per plane. Output is byte-interleaved planes, MSB is the leftmost pixel.
"""
import struct


def decode_rle4(d, pos=0):
    """Returns (w, h, pixels[w*h] 0..15, end_pos)."""
    w, h = struct.unpack_from("<HH", d, pos)
    w &= 0x7FFF
    pos += 4
    dic = struct.unpack_from("<8H", d, pos)
    pos += 16
    stride = (w + 3) // 4
    units = [0] * (stride * h + 64)
    for y in range(h):
        x = 0
        base = y * stride
        while x < stride:
            b = d[pos]
            pos += 1
            if b & 0x80:
                n = (b & 15) + 1
                k = ((b >> 4) & 3) + 1
                back = k * stride if b & 0x40 else k
                for i in range(n):
                    units[base + x + i] = units[base + x + i - back]
            else:
                n = (b & 7) + 1
                op = b & 0x78
                if op == 0:
                    v = 0
                elif op & 0x40:
                    v = dic[(op >> 3) & 7]
                elif op == 0x38:
                    v = (d[pos] << 8) | d[pos + 1]
                    pos += 2
                else:
                    a = d[pos]
                    pos += 1
                    v = {
                        0x08: a,
                        0x10: (a & 0x0F) | ((a & 0xF0) << 4),
                        0x18: (a & 0x0F) | ((a << 8) & 0xF000),
                        0x20: a << 4,
                        0x28: ((a & 0x0F) << 4) | ((a << 8) & 0xF000),
                        0x30: a << 8,
                    }[op]
                for i in range(n):
                    units[base + x + i] = v
            x += n
    px = bytearray(w * h)
    for y in range(h):
        for ux in range(stride):
            v = units[y * stride + ux]
            for sub in range(4):
                sx = ux * 4 + sub
                if sx >= w:
                    break
                bit = 3 - sub
                # plane p lives in nibble p of the unit
                px[y * w + sx] = sum(((v >> (p * 4 + bit)) & 1) << p for p in range(4))
    return w, h, bytes(px), pos


def planar_bytes(d, w, h, planes):
    """Raw byte-interleaved planes (KAO.LZW: 64x80x3)."""
    bw = (w + 7) // 8
    px = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            i = (y * bw + x // 8) * planes
            bit = 7 - x % 8
            px[y * w + x] = sum(((d[i + p] >> bit) & 1) << p for p in range(planes))
    return bytes(px)


def bbr_table(blob, off=0x40ECE, n=16):
    """16-colour table in MAIN.EXE image: 3 bytes (b, r, g), each 0..15."""
    return [(blob[off + i * 3 + 1] * 17, blob[off + i * 3 + 2] * 17, blob[off + i * 3] * 17) for i in range(n)]


def offset_table(d):
    """Big-endian u32 offsets; first one gives the table size."""
    n = struct.unpack(">I", d[:4])[0] // 4
    return list(struct.unpack(">%dI" % n, d[:n * 4]))
