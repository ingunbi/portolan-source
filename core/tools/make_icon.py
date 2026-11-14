#!/usr/bin/env python3
"""Draws Portolan's app icon (a gold compass rose on navy) with no outside artwork.

usage: python3 tools/make_icon.py IOS_ICON_PNG ANDROID_ICON_PNG
       e.g. python3 tools/make_icon.py ../ipad/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon.png \\
            ../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
Needs Pillow (pip install pillow). The icon is original artwork released with the project's license.
"""
import math
import sys
from pathlib import Path
from PIL import Image, ImageDraw

S = 4096                      # drawn large, then scaled down for smooth edges
NAVY_TOP, NAVY_BOTTOM = (6, 16, 40), (20, 38, 80)
GOLD, GOLD_DARK = (232, 184, 84), (176, 128, 44)


def rose() -> Image.Image:
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):                       # vertical navy gradient
        t = y / (S - 1)
        c = tuple(round(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3))
        for x in range(S):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    d.ellipse([cx - 1750, cy - 1750, cx + 1750, cy + 1750], outline=GOLD, width=70)
    d.ellipse([cx - 1560, cy - 1560, cx + 1560, cy + 1560], outline=GOLD_DARK, width=24)
    for k in range(32):                      # 32 wind marks around the ring
        a = math.tau * k / 32
        r0, r1 = 1560, 1560 - (150 if k % 4 == 0 else 80)
        d.line([cx + r0 * math.sin(a), cy - r0 * math.cos(a), cx + r1 * math.sin(a), cy - r1 * math.cos(a)], fill=GOLD, width=22)

    def spike(angle_deg, length, half_width, fill):
        a = math.radians(angle_deg)
        tip = (cx + length * math.sin(a), cy - length * math.cos(a))
        left = (cx + half_width * math.sin(a - math.pi / 2), cy - half_width * math.cos(a - math.pi / 2))
        right = (cx + half_width * math.sin(a + math.pi / 2), cy - half_width * math.cos(a + math.pi / 2))
        d.polygon([tip, left, (cx, cy), right], fill=fill)

    for angle in (45, 135, 225, 315):        # short diagonal points
        spike(angle, 1050, 190, GOLD_DARK)
    for angle in (0, 90, 180, 270):          # long cardinal points, light and dark halves
        a = math.radians(angle)
        tip = (cx + 1500 * math.sin(a), cy - 1500 * math.cos(a))
        left = (cx + 230 * math.sin(a - math.pi / 2), cy - 230 * math.cos(a - math.pi / 2))
        right = (cx + 230 * math.sin(a + math.pi / 2), cy - 230 * math.cos(a + math.pi / 2))
        d.polygon([tip, left, (cx, cy)], fill=GOLD)
        d.polygon([tip, right, (cx, cy)], fill=GOLD_DARK)
    d.ellipse([cx - 150, cy - 150, cx + 150, cy + 150], fill=NAVY_BOTTOM, outline=GOLD, width=34)
    return img


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    big = rose()
    for target, size in ((sys.argv[1], 1024), (sys.argv[2], 512)):
        path = Path(target)
        path.parent.mkdir(parents=True, exist_ok=True)
        big.resize((size, size), Image.LANCZOS).save(path, optimize=True)
        print("wrote", path)
