#!/usr/bin/env python3
"""ASCII preview of a PPM, for eyeballing renders in a terminal.

Usage: python3 examples/preview.py file.ppm [cols]
"""
import sys

RAMP = " .:-=+*#%@"


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(b"\n", 3)
    assert parts[0] == b"P6", parts[0]
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def main():
    path = sys.argv[1]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    w, h, body = read_ppm(path)
    rows = max(1, int(cols * h / w * 0.5))  # characters are about 2:1
    out = []
    for cy in range(rows):
        line = []
        for cx in range(cols):
            # average the box this character stands for
            x0, x1 = int(cx * w / cols), max(int(cx * w / cols) + 1, int((cx + 1) * w / cols))
            y0, y1 = int(cy * h / rows), max(int(cy * h / rows) + 1, int((cy + 1) * h / rows))
            rs = gs = bs = n = 0
            for y in range(y0, y1):
                base = y * w * 3
                for x in range(x0, x1):
                    o = base + x * 3
                    rs += body[o]
                    gs += body[o + 1]
                    bs += body[o + 2]
                    n += 1
            lum = (0.299 * rs + 0.587 * gs + 0.114 * bs) / n / 255.0
            line.append(RAMP[min(len(RAMP) - 1, int(lum * len(RAMP)))])
        out.append("".join(line))
    print("\n".join(out))

    # a few numbers, so regressions are visible without looking at the art
    total = w * h
    dark = sum(1 for i in range(0, len(body), 3) if body[i] + body[i + 1] + body[i + 2] < 24)
    print(
        "pixels=%d  near black=%.1f%%  distinct=%d"
        % (total, 100.0 * dark / total, len(set(body[i : i + 3] for i in range(0, len(body), 3))))
    )


if __name__ == "__main__":
    main()
