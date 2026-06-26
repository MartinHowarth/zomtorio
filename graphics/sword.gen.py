#!/usr/bin/env python3
# Generate a simple upright sword icon (graphics/sword.png) for the melee
# technologies. Pure stdlib (zlib) — draws procedurally onto a transparent 128x128
# RGBA canvas (no external source asset needed), then encodes a PNG.
#
# Run from the repo root:  python3 graphics/sword.gen.py
import os, zlib, struct

N = 128
DST = os.path.join(os.path.dirname(__file__), "sword.png")

px = bytearray(N * N * 4)  # transparent RGBA


def put(x, y, rgba):
    if 0 <= x < N and 0 <= y < N:
        i = (y * N + x) * 4
        px[i], px[i+1], px[i+2], px[i+3] = rgba


def fill_rect(x0, y0, x1, y1, rgba):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            put(x, y, rgba)


def main():
    cx = N // 2
    BLADE_EDGE = (150, 158, 170, 255)   # steel
    BLADE_MID  = (210, 218, 230, 255)   # bright highlight ridge
    GUARD      = (196, 150, 40, 255)    # brass crossguard
    GRIP       = (96, 60, 34, 255)      # leather-wrapped hilt
    POMMEL     = (210, 168, 56, 255)    # brass pommel

    # Blade: a tapering double-edged blade from tip (top) to the guard, with a
    # bright central ridge so it reads as metal.
    tip_y, guard_y = 12, 84
    half_w = 7
    for y in range(tip_y, guard_y):
        # widen from the tip over the first ~14px, then hold the full width.
        t = min(1.0, (y - tip_y) / 14.0)
        hw = max(1, int(half_w * t))
        fill_rect(cx - hw, y, cx + hw, y, BLADE_EDGE)
        # central ridge highlight
        fill_rect(cx - max(1, hw // 3), y, cx + max(1, hw // 3), y, BLADE_MID)

    # Crossguard: a horizontal brass bar just below the blade.
    fill_rect(cx - 26, guard_y, cx + 26, guard_y + 7, GUARD)
    # rounded-ish quillon ends
    fill_rect(cx - 30, guard_y + 1, cx - 26, guard_y + 6, GUARD)
    fill_rect(cx + 26, guard_y + 1, cx + 30, guard_y + 6, GUARD)

    # Grip: leather-wrapped hilt below the guard.
    fill_rect(cx - 4, guard_y + 8, cx + 4, guard_y + 28, GRIP)

    # Pommel: a brass knob at the base.
    fill_rect(cx - 7, guard_y + 28, cx + 7, guard_y + 34, POMMEL)

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
    print("wrote %s (%dx%d sword)" % (DST, N, N))


if __name__ == "__main__":
    main()
