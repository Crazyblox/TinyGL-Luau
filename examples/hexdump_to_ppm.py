#!/usr/bin/env python3
"""Turn gallery.luau's hex output into .ppm files (and .png for convenience).

gallery.luau cannot write files because the standalone `luau` host has no `io`
library, so it prints the frame buffers as text:

    PPM <name> <width> <height>
    <width*height*6 hex digits, one row of the image per line>

Usage:
    (cd src_luau && luau examples/gallery.luau > /tmp/gallery.txt)
    python3 examples/hexdump_to_ppm.py /tmp/gallery.txt <output dir>
"""
import os
import struct
import sys
import zlib


def png_from_rgb(path, w, h, rgb):
    """Minimal PNG writer (8 bit RGB, no interlace), so the result is easy to
    look at without a PPM viewer."""
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)  # filter type 0: none
        raw += rgb[y * stride : (y + 1) * stride]

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def main():
    src = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(outdir, exist_ok=True)

    with open(src) as f:
        tokens = f.read().split()

    i = 0
    count = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "ERROR":
            print("ERROR %s %s" % (tokens[i + 1], " ".join(tokens[i + 2 :])))
            i = len(tokens)
            continue
        if tok != "PPM":
            i += 1
            continue
        name, w, h = tokens[i + 1], int(tokens[i + 2]), int(tokens[i + 3])
        i += 4
        npix = w * h
        hexlen = npix * 6
        # the pixel data may be split over any number of lines
        data = []
        total = 0
        while total < hexlen and i < len(tokens):
            part = tokens[i]
            i += 1
            if part == "PPM" or part == "ERROR":
                raise SystemExit("unexpected %s in the middle of %s" % (part, name))
            data.append(part)
            total += len(part)
        if total != hexlen:
            raise SystemExit("%s: expected %d hex digits, got %d" % (name, hexlen, total))
        rgb = bytes.fromhex("".join(data))
        assert len(rgb) == npix * 3

        base = os.path.join(outdir, name)
        with open(base + ".ppm", "wb") as fobj:
            fobj.write(b"P6\n%d %d\n255\n" % (w, h))
            fobj.write(rgb)
        png_from_rgb(base + ".png", w, h, rgb)
        print("%-16s %dx%d  %s.ppm" % (name, w, h, name))
        count += 1

    if count == 0:
        raise SystemExit("no PPM records found in %s" % src)


if __name__ == "__main__":
    main()
