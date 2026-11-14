# Portraits: KAO.LZW and generated faces of minor characters

Addresses are MAIN.EXE load-image offsets; `DS:n` = image `0x378B0+n`. `rand(n)` = 0x4D86
(`random % n`, 0 if n = 0). Tool: `build/venv/bin/python -I tools/faces.py`
(`--export assets/faces`, `--sheet N out.png [--nation K] [--seed S]`, `--face VALUE NATION out.png`,
`--persons out.png`).

Status marks: ✅ read in full · 🔎 read, some details skipped · ❓ not decoded.

---------------------------------------------------------------------------------------------

## 1. KAO.LZW layout ✅

The file handle is opened at 0x159ED (`C:KAO.LZW`, DS:0x978) and kept in `DS:0x416`.

| part | where | format | drawn by |
|---|---|---|---|
| LS11 entries 0..127 | LS11 directory | 1920 B = 64×80, 3 planes byte-interleaved (8 B × 3 per row) | 0x7B76 |
| LS11 entries 128..255 | LS11 directory | 864 B = **48×48**, 3 planes byte-interleaved (6 B × 3 per row) | 0x7BE5 |
| raw tail | file offset 0x476A2 .. 0x71BE2 (end of file) | 7 sets × 0x60C0 B of uncompressed face strips | 0x7A4E |

The last LS11 entry ends exactly at 0x476A2; the tail is read with plain seek + read, never through
the LS11 decoder, which is why it does not show up as entries.

### 1.1 The 864-byte entries are not face parts ✅

They are 48×48 pictures (animals, landmarks, weapons, ornaments). 0x7BE5(x = ax, y = dx, n = bx)
loads entry `n + 0x80` and blits it 6 bytes × 48 rows.

- n = 0..84: discoveries. 0x33F93 passes COLONY.DAT record (0xDA bytes) byte `+0x12`.
- n = 0x55 + item byte `+0x15`: items (0x28D5F), daggers/swords from 85 on.

Palette and plane handling are the same as for portraits (indices 0..7 of the main table).

## 2. Drawing a person's portrait ✅

```
0x7BD2(person record bx, x ax, y dx):
    if (p[+0x1B] & 0xC0)             ; face word +0x1A has bit 14 or 15
        0x7B2E: 0x7A4E(file offset 0x476A2 + (p[+0x31] & 0xF) * 0x60C0, value p[+0x1A])
    else
        0x7B76(KAO entry p[+0x1A])   ; LS11 entry, 64×80
```

Callers / wrappers:

| routine | what |
|---|---|
| 0x7D71 / 0x7D9F (person index al) | open the face window (0x7C45) at two fixed places; index ≥ 120 → 0x7C8E / 0x7CAE |
| 0x7C8E / 0x7CAE | stranger: `0x7B52(rand(0x3FFF) \| 0xC000)` — a new random face every time |
| 0x7B52 (value bx) | generated face with set `rand(7)` (also used directly at 0x2E2BA, 0x2E58E, 0x2E5BC) |
| 0x7CCE (set ax, value dx) | generated face with an explicit set; 0x283DA uses the current port's nation (`port +0x13 & 7`) and value `DS:0xC172` |
| 0x7CF9 / 0x7D45 | named portraits by KAO index (0x7B76) |
| scenario CC/CD `face` | 0x315F4 → 0x7B76 / 0x7BD2 |

New characters get `rand(0x3FFF) | 0xC000` (0x17F8B). Because rand(n) < n, the low 14 bits are
never 0x3FFF from a random draw (one unreachable combination).

## 3. Composition (0x7A4E) ✅

Arguments: dx:ax = file offset of the set, bx = x (byte column), `[bp+6]` = face value v,
`[bp+8]` = y. The routine builds the 1920-byte portrait in the buffer `DS:0xC12` (segment via
0x354B7) and then blits it exactly like a named portrait (0x55E, 8 bytes × 80 rows).

A set is 0x60C0 bytes: five groups of full-width strips, stored in the order they are drawn.
Every strip is 64 px wide, 3-plane byte-interleaved, 24 bytes per row.

| order | layer | index | count | strip size | buffer offset | rows | blend | reader |
|---|---|---|---|---|---|---|---|---|
| 1 | top (hair, hat, forehead, background) | `v & 7` | 8 | 0x318 (33 rows) | 0x000 | 0..32 | copy | 0x7A12 |
| 2 | bottom (jaw, beard, clothes) | `(v >> 3) & 7` | 8 | 0x468 (47 rows) | 0x318 | 33..79 | copy | 0x7A12 |
| 3 | eyes | `(v >> 8) & 7` | 8 | 0x1B0 (18 rows) | 0x1F8 | 21..38 | OR | 0x79AA |
| 4 | nose | `(v >> 6) & 3` | 4 | 0x240 (24 rows) | 0x2B8 | 29..52 | OR | 0x79AA |
| 5 | mouth | `(v >> 11) & 7` | 8 | 0x1C8 (19 rows) | 0x438 | 45..63 | OR | 0x79AA |

Group offsets inside a set: 0, 0x18C0, 0x3C00, 0x4980, 0x5280 (sum 0x60C0). Strip `i` of a group
is at group offset + i × strip size. Bits 14..15 are only the "generated" flag; all 14 low bits
are used (3+3+3+2+3).

- 0x7A12 seeks to `base + i*size` and reads `size` bytes straight into the buffer (copy).
- 0x79AA reads into a stack buffer (max 0x240) and ORs every byte into the image buffer.
  OR on interleaved plane bytes = OR of the 3-bit palette indices per pixel. Pixel 0 is therefore
  transparent; elsewhere the result is `below | part`. Strips never mix with each other (checked
  for all combinations), but in sets 4 and 5 they do mix with top/bottom pixels that are not 0
  (e.g. 7|6 = 7, 6|3 = 7), so plain alpha compositing is exact only for sets 0, 1, 2, 3 and 6.
  In set 5 up to 128 pixels per face differ (the original is lighter around the mouth).
- No palette change: indices 0..7 of the main table (`0x40ECE`), same as named portraits.

### Sets

`set = person +0x31 & 0xF` (the nation): 0 Portugal, 1 Spain, 2 Turkey (turbans), 3 England,
4 Italy, 5 Netherlands (blond), 6 nationless. The 54 generated persons of the new-game data use
0..6 only. A value ≥ 7 would read past the end of the file.

## 4. Remaster export (`assets/faces/`)

`tools/faces.py --export assets/faces` writes

- `part_<k>.png`, k = set × 36 + layer base + index (layer bases top 0, bottom 8, eyes 16,
  nose 24, mouth 28). RGBA in palette colours; copy layers are fully opaque, OR layers have
  alpha 0 where the index is 0.
- `faces.json`: `layers` (draw order, `shift`, `mask`, `x`, `y`, size, `blend`), `sets[n].parts[layer]`
  (file per index), `palette` (indices 0..7, all distinct, so RGB maps back to an index), and
  `alphaOverIsExact` per set.

Recipe: for each layer in order, `file = sets[nation].parts[name][(v >> shift) & mask]`, draw it
at (x, y); for `blend == "or"` combine palette indices with OR where the part is opaque. The export
re-checks this recipe against the byte-level composition, and the PNG round trip was checked for
1400 random values.

## 5. Open questions

- The blit (0x44D mode 0) writes VGA planes 0..2 only; plane 3 keeps what the face window
  (0x7C45 → 0x5086 / 0x71FA) left there. The remaster assumes 0 (indices 0..7) as for named
  portraits; not checked against the window fill. 🔎
- Where `DS:0xC172` (face shown at 0x283DA) and `DS:0xC126` (0x2E2BA) are set was not traced.
- 0x2E58E / 0x2E5BC draw two random strangers side by side (scene not identified).
