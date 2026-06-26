#!/usr/bin/env python3
# Generate a simple flame icon (graphics/flame.png) used as the fire overlay on the
# zombie-pyre item/entity icon. Pure stdlib (zlib) — draws a teardrop flame
# (hot-white core -> yellow -> orange -> red edge) procedurally onto a transparent
# 128x128 RGBA canvas, then encodes a PNG. No external source asset needed.
#
# Run from the repo root:  python3 graphics/flame.gen.py
import os, zlib, struct

N = 128
DST = os.path.join(os.path.dirname(__file__), "flame.png")

px = bytearray(N * N * 4)  # transparent RGBA


def put(x, y, rgba):
    if 0 <= x < N and 0 <= y < N:
        i = (y * N + x) * 4
        px[i], px[i+1], px[i+2], px[i+3] = rgba


def main():
    cx = N // 2
    top, bot = 16, 116          # vertical extent of the flame
    max_hw = 38                 # widest half-width (near the base)

    CORE = (255, 244, 170, 255)  # hot white-yellow core
    YELLOW = (255, 202, 48, 255)
    ORANGE = (242, 120, 24, 255)
    RED = (198, 42, 18, 255)

    span = bot - top
    for y in range(top, bot):
        t = (y - top) / span                 # 0 at the pointed top .. 1 at the base
        # Flame profile: pointed at the top, widening toward the base, then a slight
        # inward taper over the last ~12% so the base is rounded, not a flat slab.
        hw = max_hw * (t ** 0.6)
        if t > 0.88:
            hw *= max(0.0, 1.0 - (t - 0.88) * 5.0)
        hw = max(0.0, hw)
        for x in range(int(cx - hw), int(cx + hw) + 1):
            d = abs(x - cx) / (hw + 0.001)    # 0 centre .. 1 edge
            if d > 0.82:
                c = RED
            elif d > 0.5:
                c = ORANGE
            elif d > 0.22:
                c = YELLOW
            else:
                c = CORE
            put(x, y, c)

    raw = bytearray()
    stride = N * 4
    for y in range(N):
        raw.append(0)  # filter: None
        raw += px[y*stride:(y+1)*stride]

    def chunk(typ, data):
        return struct.pack(">I", len(data)) + typ + data + \
            struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + \
        chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(DST, "wb").write(png)
    print("wrote %s (%dx%d flame)" % (DST, N, N))


if __name__ == "__main__":
    main()
