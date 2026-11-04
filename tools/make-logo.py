#!/usr/bin/env python3
"""Renders the Guildhall logo ("The Hall") with no image libraries.

    python3 tools/make-logo.py <out-dir>

Writes:
  Logo.tga      64x64 RGBA, for the game (minimap button, addon list icon, header)
  logo-256.png  for the README / GitHub
  logo-512.png  for Discord / social preview

Shapes are in a 64x64 design grid, matching the mockup SVG. Each pixel is
supersampled (SS x SS) for smooth edges.
"""
import math
import os
import struct
import sys
import zlib

GOLD = (0xF0, 0xC2, 0x4B)
FIELD = (0x6E, 0x10, 0x10)
SS = 8


def inside_tri(x, y, a, b, c):
    def s(p, q, r):
        return (p[0] - r[0]) * (q[1] - r[1]) - (q[0] - r[0]) * (p[1] - r[1])
    d1, d2, d3 = s((x, y), a, b), s((x, y), b, c), s((x, y), c, a)
    neg = d1 < 0 or d2 < 0 or d3 < 0
    pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (neg and pos)


def rect(x, y, x0, y0, x1, y1):
    return x0 <= x <= x1 and y0 <= y <= y1


def sample(x, y):
    """Colour (r, g, b) or None (transparent) at design coordinates x, y."""
    r = math.hypot(x - 32, y - 32)
    if r > 31:
        return None
    if r >= 28:
        return GOLD  # ring
    holes = (
        rect(x, y, 28, 41, 36, 48) or math.hypot(x - 32, y - 41) <= 4  # arched door
        or rect(x, y, 20, 35, 24, 41) or rect(x, y, 40, 35, 44, 41)  # windows
    )
    hall = (
        rect(x, y, 31, 9, 33, 16)  # flag pole
        or inside_tri(x, y, (32, 9), (40, 11.5), (32, 14))  # banner
        or inside_tri(x, y, (12, 31), (32, 16), (52, 31))  # roof
        or rect(x, y, 17, 31, 47, 48)  # walls
        or rect(x, y, 14, 47, 50, 50.5)  # steps
    )
    if hall and not (holes and y < 48):
        return GOLD
    return FIELD


def render(size):
    px = []
    scale = 64.0 / size
    n = SS * SS
    for j in range(size):
        row = []
        for i in range(size):
            acc = [0, 0, 0, 0]
            for sj in range(SS):
                for si in range(SS):
                    x = (i + (si + 0.5) / SS) * scale
                    y = (j + (sj + 0.5) / SS) * scale
                    c = sample(x, y)
                    if c:
                        acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; acc[3] += 1
            a = acc[3]
            if a:
                row.append((acc[0] // a, acc[1] // a, acc[2] // a, round(255 * a / n)))
            else:
                row.append((0, 0, 0, 0))
        px.append(row)
    return px


def write_tga(path, px):
    h, w = len(px), len(px[0])
    # Uncompressed true-colour, 32 bpp, 8 alpha bits, top-left origin.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    body = bytearray()
    for row in px:
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(path, "wb") as f:
        f.write(header + bytes(body))


def write_png(path, px):
    h, w = len(px), len(px[0])
    raw = bytearray()
    for row in px:
        raw.append(0)
        for p in row:
            raw += bytes(p)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    write_tga(os.path.join(out, "Logo.tga"), render(64))
    for size in (256, 512):
        write_png(os.path.join(out, f"logo-{size}.png"), render(size))
    print("wrote", ", ".join(sorted(os.listdir(out))))


if __name__ == "__main__":
    main()
