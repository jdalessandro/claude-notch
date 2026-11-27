#!/usr/bin/env python3
"""Renders the NotchBot app icon (App/AppIcon.icns) and docs/brand/notchbot-icon.png from the robot sprite.

The sprite grid and tone colours are read from Shared/IslandViews.swift, so the logo has one source of truth.
Needs only the standard library plus macOS `iconutil`. Run from anywhere: python3 scripts/gen_icon.py
"""
import os, re, struct, subprocess, tempfile, zlib

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(root, "Shared/IslandViews.swift")).read()
grid = re.findall(r'^\s*"([.LMD]{16})",?\s*$', src.split("struct RobotMark")[1], re.M)
assert len(grid) == 14, "robot grid not found"
rows, cols = len(grid), len(grid[0])
def rgb(r, g, b): return (round(r * 255), round(g * 255), round(b * 255))
TONE = {"M": rgb(0.851, 0.467, 0.341), "L": rgb(0.933, 0.604, 0.486), "D": rgb(0.663, 0.333, 0.227)}
BG = (28, 28, 30)

def render(size):
    """RGBA bytes: a dark squircle-ish rounded square with the robot centred, nearest-neighbour sprite."""
    cell = size * 0.62 / cols
    ox, oy = (size - cols * cell) / 2, (size - rows * cell) / 2
    rad, half = size * 0.2237, size / 2
    out = bytearray()
    for y in range(size):
        out.append(0)  # PNG filter: none
        for x in range(size):
            # Coverage of the rounded square (signed distance, 1px antialias).
            dx, dy = abs(x + 0.5 - half) - (half - rad), abs(y + 0.5 - half) - (half - rad)
            d = (max(dx, 0) ** 2 + max(dy, 0) ** 2) ** 0.5 + min(max(dx, dy), 0) - rad
            a = max(0.0, min(1.0, 0.5 - d))
            c = BG
            gx, gy = int((x + 0.5 - ox) // cell), int((y + 0.5 - oy) // cell)
            if 0 <= gx < cols and 0 <= gy < rows and grid[gy][gx] in TONE: c = TONE[grid[gy][gx]]
            out += bytes((*c, round(a * 255)))
    return bytes(out)

def png(size, data):
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(data, 9)) + chunk(b"IEND", b""))

with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "AppIcon.iconset"); os.mkdir(iconset)
    cache = {}
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            cache.setdefault(px, png(px, render(px)))
            name = "icon_%dx%d%s.png" % (base, base, "@2x" if scale == 2 else "")
            open(os.path.join(iconset, name), "wb").write(cache[px])
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "App/AppIcon.icns")], check=True)
    open(os.path.join(root, "docs/brand/notchbot-icon.png"), "wb").write(cache[512])
print("wrote App/AppIcon.icns and docs/brand/notchbot-icon.png")
