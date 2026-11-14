"""Minimal dependency-free PNG writer."""
import struct, zlib


def write_png(path, w, h, rgb):
    """rgb: bytes of length w*h*3 (or w*h*4 with alpha)."""
    n = len(rgb) // (w * h)
    raw = b"".join(b"\0" + rgb[y * w * n:(y + 1) * w * n] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if n == 4 else 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))
