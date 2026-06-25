#!/usr/bin/env python3
# Generate a greyscale version of the base small-biter icon for the kiln-dried-corpse
# item. Pure stdlib (zlib) — decodes the base RGBA PNG (a 120x64 mipmap strip),
# desaturates RGB to luminance (keeps alpha + the mipmap layout), re-encodes.
#
# Source lives in the Steam install (the headless server ships no graphics). Override
# with $BITER_SRC if your install path differs.
#
# Run from the repo root:  python3 graphics/biter-grey.gen.py
import os, zlib, struct, sys

SRC = os.environ.get("BITER_SRC",
    "/mnt/c/Program Files (x86)/Steam/steamapps/common/Factorio/data/base/graphics/icons/small-biter.png")
DST = os.path.join(os.path.dirname(__file__), "biter-grey.png")


def read_png_rgba(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    w = h = bitdepth = colortype = None
    idat = bytearray()
    i = 8
    while i < len(d):
        ln = struct.unpack(">I", d[i:i+4])[0]
        typ = d[i+4:i+8]
        chunk = d[i+8:i+8+ln]
        if typ == b"IHDR":
            w, h, bitdepth, colortype = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
        i += 12 + ln
    assert bitdepth == 8 and colortype == 6, "expected 8-bit RGBA (got bd=%s ct=%s)" % (bitdepth, colortype)
    raw = zlib.decompress(bytes(idat))
    bpp = 4
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ft = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if ft == 1:      # Sub
            for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 255
        elif ft == 2:    # Up
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif ft == 3:    # Average
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif ft == 4:    # Paeth
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, out


def write_png_rgba(path, w, h, rgba):
    stride = w * 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: None
        raw += rgba[y*stride:(y+1)*stride]
    def chunk(typ, data):
        return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    if not os.path.exists(SRC):
        sys.exit("source biter icon not found: %s (set $BITER_SRC)" % SRC)
    w, h, px = read_png_rgba(SRC)
    for p in range(0, len(px), 4):
        r, g, b = px[p], px[p+1], px[p+2]
        gy = (r*299 + g*587 + b*114) // 1000
        px[p] = px[p+1] = px[p+2] = gy  # alpha (px[p+3]) untouched
    write_png_rgba(DST, w, h, px)
    print("wrote %s (%dx%d, greyscale, alpha preserved)" % (DST, w, h))


if __name__ == "__main__":
    main()
