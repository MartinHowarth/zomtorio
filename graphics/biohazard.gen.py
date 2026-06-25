#!/usr/bin/env python3
"""Generate graphics/biohazard.png — the red warning triangle + black biohazard
symbol drawn over infected buildings in alt-mode (see lib/infection.lua).

No image libraries are available in this environment, so this hand-rolls a PNG
(stdlib zlib/struct only). EDIT THE TUNABLES BELOW to improve the symbol, then
regenerate from the repo root:

    python3 graphics/biohazard.gen.py

It prints an ASCII preview and writes graphics/biohazard.png (64x64 RGBA).
(Or just edit graphics/biohazard.png directly in any image editor — keep it
64x64 RGBA with transparency outside the triangle.)
"""
import math, zlib, struct, os

# ----------------------------------------------------------------- TUNABLES
N = 64                                   # canvas size (keep the sprite 64x64)
RED = (200, 24, 24, 255)                 # triangle fill
BLK = (0, 0, 0, 255)                     # symbol + triangle border
CLR = (0, 0, 0, 0)                       # transparent (outside the triangle)
BORDER = 2.4                             # triangle border thickness (px)

# Warning triangle vertices (apex up). Widen/narrow the sign here.
A = (32.0, 4.0); B = (4.0, 59.0); C = (60.0, 59.0)

# Biohazard symbol = a centre dot + three "ring" lobes 120 deg apart. Tweak these
# to reshape it: cx/cy = centre; LOBE_DIST = how far the lobes sit from centre;
# RING_OUTER/RING_INNER = each lobe's ring radii (thickness = outer-inner);
# DOT = centre dot radius; LOBE_ANGLES = orientation (degrees, image coords).
cx, cy      = 32.0, 40.0
LOBE_DIST   = 9.0
RING_OUTER  = 7.2
RING_INNER  = 3.4
DOT         = 4.2
LOBE_ANGLES = (-90, 30, 150)             # one lobe points up
# ---------------------------------------------------------------------------

LOBES = [(cx + LOBE_DIST*math.cos(math.radians(a)),
          cy + LOBE_DIST*math.sin(math.radians(a))) for a in LOBE_ANGLES]

def edge(p, a, b):
    return (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0])

def dist_seg(p, a, b):
    ax, ay = a; bx, by = b; px, py = p; dx, dy = bx-ax, by-ay
    l2 = dx*dx + dy*dy
    t = 0 if l2 == 0 else max(0, min(1, ((px-ax)*dx + (py-ay)*dy)/l2))
    return math.hypot(px-(ax+t*dx), py-(ay+t*dy))

def biohazard(p):
    if math.hypot(p[0]-cx, p[1]-cy) <= DOT:
        return True
    for (lx, ly) in LOBES:
        if RING_INNER <= math.hypot(p[0]-lx, p[1]-ly) <= RING_OUTER:
            return True
    return False

def tri_inside(p):
    s1, s2, s3 = edge(p, A, B), edge(p, B, C), edge(p, C, A)
    return (s1 >= 0 and s2 >= 0 and s3 >= 0) or (s1 <= 0 and s2 <= 0 and s3 <= 0)

def near_edge(p):
    return min(dist_seg(p, A, B), dist_seg(p, B, C), dist_seg(p, C, A)) <= BORDER

def px(x, y):
    p = (x+0.5, y+0.5)
    if not tri_inside(p): return CLR
    if biohazard(p):      return BLK
    if near_edge(p):      return BLK
    return RED

def main():
    raw = bytearray()
    for y in range(N):
        raw.append(0)                                  # PNG filter byte: none
        for x in range(N):
            raw += bytes(px(x, y))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    out = os.path.join(os.path.dirname(__file__), "biohazard.png")
    with open(out, "wb") as f:
        f.write(png)

    chars = {CLR: ' ', RED: '.', BLK: '#'}
    for y in range(0, N, 2):
        print(''.join(chars[px(x, y)] for x in range(0, N, 2)))
    print("wrote", out)

if __name__ == "__main__":
    main()
