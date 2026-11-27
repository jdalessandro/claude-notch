#!/usr/bin/env python3
"""Renders App/AppIcon.icns from the RobotMark sprite in Shared/IslandViews.swift (no third-party tools; needs iconutil).
Usage: make_icon.py [white]. Run after changing the sprite or its colours, and commit the result."""
import os, re, struct, subprocess, sys, tempfile, zlib

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(root, "Shared/IslandViews.swift")).read()
grid = re.findall(r'^\s+"([.LMD]{16})",$', src, re.M)
assert len(grid) == 14, "sprite not found"
tones = {"M": (0xD9, 0x78, 0x57), "L": (0xEE, 0x9A, 0x7C), "D": (0xA9, 0x55, 0x3A)}
# Tile background: pass "white" for a white tile, default is pure black.
BG = (255, 255, 255) if "white" in sys.argv[1:] else (0, 0, 0)

def render(size):
    """Dark rounded tile (macOS icon grid: 824/1024 plate) with the robot centred, nearest-neighbour."""
    plate = size * 824 / 1024
    off, rad = (size - plate) / 2, plate * 0.225
    cell = max(1, int(plate * 0.62 / 16))  # whole pixels per sprite cell
    ox, oy = (size - cell * 16) // 2, (size - cell * 14) // 2
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px = (0, 0, 0, 0)
            cx = min(max(x + .5, off + rad), off + plate - rad)
            cy = min(max(y + .5, off + rad), off + plate - rad)
            d = ((x + .5 - cx) ** 2 + (y + .5 - cy) ** 2) ** .5
            if d <= rad - .5 or (off <= x < off + plate and off <= y < off + plate and d <= rad):
                a = 255 if d <= rad - .5 else int(255 * max(0, min(1, rad + .5 - d)))
                px = (*BG, a)
                gx, gy = (x - ox) // cell, (y - oy) // cell
                if 0 <= gx < 16 and 0 <= gy < 14 and x >= ox and y >= oy and grid[gy][gx] != ".":
                    px = (*tones[grid[gy][gx]], 255)
            rows += bytes(px)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            open(os.path.join(iconset, name), "wb").write(render(base * scale))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "App/AppIcon.icns")], check=True)
print("wrote App/AppIcon.icns")
