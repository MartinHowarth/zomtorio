#!/usr/bin/env python3
# Generate a static molten-ember/lava overlay (graphics/ember.png) for the zombie
# pyre — a partly-opaque patch of glowing coals that sits on top of the wooden crate
# (drawn always, idle AND working) so the pit always reads as smouldering, while the
# animated flames only play while it's actually burning. Pure stdlib (zlib + a tiny
# fixed-seed value noise), drawn onto a transparent 128x128 RGBA canvas.
#
# Run from the repo root:  python3 graphics/ember.gen.py
import os, zlib, struct, math

N = 128
DST = os.path.join(os.path.dirname(__file__), "ember.png")

px = bytearray(N * N * 4)  # transparent RGBA


def put(x, y, rgba):
    if 0 <= x < N and 0 <= y < N:
        i = (y * N + x) * 4
        px[i], px[i+1], px[i+2], px[i+3] = rgba


# Deterministic value-noise so the texture is stable across regenerations (no RNG).
def noise(x, y):
    v = math.sin(x * 0.27 + y * 0.13) + math.sin(x * 0.11 - y * 0.31) \
        + math.sin((x + y) * 0.19) + math.sin((x - y) * 0.23)
    return (v / 4.0 + 1.0) / 2.0  # 0..1


def lerp(a, b, t):
    return a + (b - a) * t


def main():
    cx, cy = N / 2.0, N / 2.0
    rad = N * 0.46

    CRUST = (44, 14, 10)        # dark cooled crust
    GLOW = (210, 70, 18)        # molten orange
    HOT = (255, 184, 60)        # hot yellow vein

    for y in range(N):
        for x in range(N):
            dx, dy = x - cx, y - cy
            d = math.sqrt(dx * dx + dy * dy) / rad   # 0 centre .. 1 rim
            if d > 1.0:
                continue
            h = noise(x, y)                          # local "heat" 0..1
            # hotter toward the centre; crust at the cooler/edge bits
            heat = max(0.0, min(1.0, h * (1.15 - d * 0.9)))
            if heat < 0.45:
                c = CRUST
            elif heat < 0.72:
                t = (heat - 0.45) / 0.27
                c = (int(lerp(CRUST[0], GLOW[0], t)),
                     int(lerp(CRUST[1], GLOW[1], t)),
                     int(lerp(CRUST[2], GLOW[2], t)))
            else:
                t = (heat - 0.72) / 0.28
                c = (int(lerp(GLOW[0], HOT[0], t)),
                     int(lerp(GLOW[1], HOT[1], t)),
                     int(lerp(GLOW[2], HOT[2], t)))
            # Mostly opaque: the interior stays solid (so the embers read strongly on
            # the crate) and only the rim fades, so there's no hard edge.
            edge = max(0.0, 1.0 - (d ** 3))
            alpha = int(max(0, min(255, (200 + heat * 55) * edge)))
            put(x, y, (c[0], c[1], c[2], alpha))

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
    print("wrote %s (%dx%d ember)" % (DST, N, N))


if __name__ == "__main__":
    main()
