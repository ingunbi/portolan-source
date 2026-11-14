#!/usr/bin/env python3
"""World map decoder (MAIN.EXE image 0x224E1 expand, 0x22734 render).

WORLDMAP.LZW holds 3 maps, each 720x1080 tiles = 30x45 blocks of 12x12 cells;
one cell is 2x2 tiles. Each map starts with 1350 u16le block offsets relative to
0xA8C. Block stream: byte b, template = b & 0x7F (>= 0x78, 8 templates of 144 cells
stored in the EXE), if bit 7 is clear an 18-byte mask follows, mask bit set = literal
cell byte in the stream, clear = template cell.
"""
import struct
import ls11

TEMPLATE_BASE = 0x378B0 + 0x6E78  # DS:0x6E78 + id * 0x90


def decode_block(m, pos, tmpl_img):
    b = m[pos]
    pos += 1
    t = b & 0x7F
    if t < 0x78:
        return None, pos
    tmpl = tmpl_img[TEMPLATE_BASE + t * 0x90:TEMPLATE_BASE + (t + 1) * 0x90]
    if b & 0x80:
        return bytes(tmpl), pos
    mask = m[pos:pos + 18]
    pos += 18
    out = bytearray(144)
    for i in range(144):
        if mask[i >> 3] & (0x80 >> (i & 7)):
            out[i] = m[pos]
            pos += 1
        else:
            out[i] = tmpl[i]
    return bytes(out), pos


def decode_map(m, tmpl_img):
    """Returns cells[(30*12)*(45*12)] for one 720x1080 map."""
    off = struct.unpack("<1350H", m[:2700])
    W, H = 30 * 12, 45 * 12
    cells = bytearray(W * H)
    bad = 0
    for i in range(1350):
        cell, _ = decode_block(m, 0xA8C + off[i], tmpl_img)
        if cell is None:
            bad += 1
            continue
        by, bx = i // 30, i % 30
        for y in range(12):
            cells[(by * 12 + y) * W + bx * 12:(by * 12 + y) * W + bx * 12 + 12] = cell[y * 12:y * 12 + 12]
    return bytes(cells), bad


def decode_world(game_dir, tmpl_img):
    """Returns cells for the full 1080x540 cell world (2160x1080 tiles)."""
    maps = ls11.unpack(game_dir + "/WORLDMAP.LZW")
    W, H = 360 * 3, 540
    world = bytearray(W * H)
    total_bad = 0
    for k, m in enumerate(maps):
        cells, bad = decode_map(m, tmpl_img)
        total_bad += bad
        for y in range(H):
            world[y * W + k * 360:y * W + (k + 1) * 360] = cells[y * 360:(y + 1) * 360]
    return bytes(world), total_bad
