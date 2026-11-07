#!/usr/bin/env python3
"""Band luminance under the browse toolbar, for the #160 haze proof.

Band A is the 24 pt of rows starting 4 pt below the bottom of the toolbar
items; band B is the 24 pt of rows starting 160 pt below the top of band A.
Both span the full width. Each pixel's luminance is Rec. 601
(0.299 R + 0.587 G + 0.114 B, 0 to 255); a band's value is the mean.

Usage:
  scripts/band-luminance.py --toolbar-bottom PT [--scale 3] SHOT.png
      prints mean(A) and mean(B) for one capture
  scripts/band-luminance.py --toolbar-bottom PT [--scale 3] MAIN.png BRANCH.png
      also prints mean(A branch) / mean(A main), mean(B branch) / mean(B main)
      and |mean(B branch) - mean(B main)| / mean(B main)

--toolbar-bottom is the bottom edge of the toolbar items in points (for
example from `idb ui describe-all`: the items' frame y + height). The PNG is
an 8-bit RGB or RGBA, non-interlaced capture such as `simctl io screenshot`
writes. Standard library only (PIL is not installed on the build Mac).
"""

import argparse
import struct
import sys
import zlib

BAND_HEIGHT_PT = 24
BAND_A_OFFSET_PT = 4
BAND_B_OFFSET_PT = 160


def read_png(path):
    """Returns (width, height, channels, rows) with rows as bytearrays."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos = 8
    idat = bytearray()
    width = height = None
    channels = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace != 0 or color not in (2, 6):
                raise ValueError(f"{path}: need 8-bit RGB/RGBA, non-interlaced (depth {depth}, color {color})")
            channels = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        kind = raw[offset]
        line = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        if kind == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif kind != 0:
            raise ValueError(f"{path}: unknown filter {kind}")
        rows.append(line)
        previous = line
    return width, height, channels, rows


def band_mean(rows, width, channels, top_px, height_px):
    total = 0.0
    count = 0
    for y in range(top_px, top_px + height_px):
        line = rows[y]
        for x in range(0, width * channels, channels):
            total += 0.299 * line[x] + 0.587 * line[x + 1] + 0.114 * line[x + 2]
            count += 1
    return total / count


def bands(path, toolbar_bottom_pt, scale):
    width, height, channels, rows = read_png(path)
    a_top = round((toolbar_bottom_pt + BAND_A_OFFSET_PT) * scale)
    b_top = a_top + round(BAND_B_OFFSET_PT * scale)
    band_px = round(BAND_HEIGHT_PT * scale)
    if b_top + band_px > height:
        raise ValueError(f"{path}: band B ends at {b_top + band_px} px, image is {height} px tall")
    return band_mean(rows, width, channels, a_top, band_px), band_mean(rows, width, channels, b_top, band_px)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--toolbar-bottom", type=float, required=True, help="toolbar items' bottom edge, points")
    parser.add_argument("--scale", type=float, default=3, help="pixels per point (3 on the iPhone 17 Pro)")
    parser.add_argument("pngs", nargs="+", help="one capture, or MAIN.png BRANCH.png")
    args = parser.parse_args()
    if len(args.pngs) > 2:
        parser.error("give one capture, or a main and a branch capture")
    results = []
    for path in args.pngs:
        mean_a, mean_b = bands(path, args.toolbar_bottom, args.scale)
        results.append((mean_a, mean_b))
        print(f"{path}: mean(A) {mean_a:.2f}  mean(B) {mean_b:.2f}")
    if len(results) == 2:
        (main_a, main_b), (branch_a, branch_b) = results
        print(f"A branch/main {branch_a / main_a:.4f}")
        print(f"B branch/main {branch_b / main_b:.4f}")
        print(f"|B branch - B main| / B main {abs(branch_b - main_b) / main_b:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
