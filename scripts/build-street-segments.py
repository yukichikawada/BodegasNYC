#!/usr/bin/env python3
"""Build BodegasNYC/Resources/nyc-streets.bin from NYC Open Data (#108).

Fetches the citywide street centerline (CSCL), dataset `inkn-q76z`, through
the SODA API, keeps street segments only (`rw_type = '1'`: no highways,
bridges, tunnels, boardwalks, paths, step streets, driveways, ramps, alleys
or ferries), and packs one record per block for `StreetGrid`.

Usage (from the repo root; Python 3 standard library only):

    python3 scripts/build-street-segments.py [output_path]

The query (exactly what is fetched, page by page):

    GET https://data.cityofnewyork.us/resource/inkn-q76z.json
        ?$select=physicalid,objectid,boroughcode,the_geom
        &$where=rw_type='1'
        &$order=physicalid,objectid
        &$limit=50000&$offset=<n>          (until a page comes back empty)

The dataset stamp is the view's `rowsUpdatedAt`
(https://data.cityofnewyork.us/api/views/inkn-q76z.json). Changing it makes
the app rebuild every user's walked-block cache once.

Rules (spec #108, Implementation 1):
- A repeated `physicalid` keeps the row with the lowest `objectid`.
- A row whose geometry is null or has fewer than 2 vertices is dropped.
- MultiLineString parts are joined in order only when one part's end is
  within 1 m of the next part's start; otherwise the longest part is kept
  and the row is listed as split.
- Segments are written sorted by `physicalid`; the header's per-borough
  counts are computed after the dedupe and the drops.

File layout, little-endian:
    header:  b"NYCS", UInt16 format version, UInt32 dataset stamp,
             UInt32 segment count, 5 x UInt32 block counts (borough codes 1-5:
             Manhattan, Bronx, Brooklyn, Queens, Staten Island)
    segment: UInt32 physicalid, UInt8 borough code, UInt16 vertex count,
             vertex count x (Float32 lon, Float32 lat)
"""

import json
import math
import os
import struct
import sys
import urllib.parse
import urllib.request

DATASET = "inkn-q76z"
RESOURCE_URL = f"https://data.cityofnewyork.us/resource/{DATASET}.json"
VIEW_URL = f"https://data.cityofnewyork.us/api/views/{DATASET}.json"
PAGE_SIZE = 50000
FORMAT_VERSION = 1
JOIN_TOLERANCE_METERS = 1.0
BOROUGH_NAMES = {1: "Manhattan", 2: "Bronx", 3: "Brooklyn", 4: "Queens", 5: "Staten Island"}
DEFAULT_OUTPUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "BodegasNYC", "Resources", "nyc-streets.bin"
)


def fetch_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def fetch_rows():
    rows = []
    offset = 0
    while True:
        query = urllib.parse.urlencode(
            {
                "$select": "physicalid,objectid,boroughcode,the_geom",
                "$where": "rw_type='1'",
                "$order": "physicalid,objectid",
                "$limit": str(PAGE_SIZE),
                "$offset": str(offset),
            }
        )
        page = fetch_json(f"{RESOURCE_URL}?{query}")
        if not page:
            return rows
        rows.extend(page)
        offset += len(page)
        print(f"fetched {offset} rows", file=sys.stderr)


def meters_between(a, b):
    """Local equirectangular distance, the same plane the app matches in."""
    mean_lat = math.radians((a[1] + b[1]) / 2)
    dx = (b[0] - a[0]) * math.cos(mean_lat) * 111_320.0
    dy = (b[1] - a[1]) * 110_540.0
    return math.hypot(dx, dy)


def length_of(part):
    return sum(meters_between(p, q) for p, q in zip(part, part[1:]))


def polyline_from(geometry):
    """Returns (vertices, was_split) or (None, False) for unusable geometry."""
    if not geometry:
        return None, False
    kind = geometry.get("type")
    coordinates = geometry.get("coordinates") or []
    if kind == "LineString":
        parts = [coordinates]
    elif kind == "MultiLineString":
        parts = [part for part in coordinates if part]
    else:
        return None, False
    if not parts:
        return None, False

    joined = list(parts[0])
    for part in parts[1:]:
        if meters_between(joined[-1], part[0]) <= JOIN_TOLERANCE_METERS:
            joined.extend(part[1:])
        else:
            longest = max(parts, key=length_of)
            return [tuple(v[:2]) for v in longest], True
    return [tuple(v[:2]) for v in joined], False


def main():
    output = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUTPUT)
    stamp = int(fetch_json(VIEW_URL)["rowsUpdatedAt"])
    rows = fetch_rows()

    best = {}
    duplicates = 0
    for row in rows:
        physicalid = int(row["physicalid"])
        objectid = int(row["objectid"])
        if physicalid in best:
            duplicates += 1
            if objectid >= int(best[physicalid]["objectid"]):
                continue
        best[physicalid] = row

    segments = []
    dropped = []
    split = []
    for physicalid in sorted(best):
        row = best[physicalid]
        vertices, was_split = polyline_from(row.get("the_geom"))
        if vertices is None or len(vertices) < 2:
            dropped.append((physicalid, row["objectid"]))
            continue
        if len(vertices) > 0xFFFF:
            dropped.append((physicalid, row["objectid"]))
            continue
        borough = int(row["boroughcode"])
        if borough not in BOROUGH_NAMES:
            dropped.append((physicalid, row["objectid"]))
            continue
        if was_split:
            split.append((physicalid, row["objectid"]))
        segments.append((physicalid, borough, vertices))

    counts = [0] * 5
    for _, borough, _ in segments:
        counts[borough - 1] += 1

    body = bytearray()
    body += b"NYCS"
    body += struct.pack("<HII", FORMAT_VERSION, stamp, len(segments))
    body += struct.pack("<5I", *counts)
    vertex_total = 0
    for physicalid, borough, vertices in segments:
        body += struct.pack("<IBH", physicalid, borough, len(vertices))
        for lon, lat in vertices:
            body += struct.pack("<ff", lon, lat)
        vertex_total += len(vertices)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "wb") as handle:
        handle.write(body)

    print(f"dataset {DATASET} rowsUpdatedAt {stamp}")
    print(f"rows fetched: {len(rows)}")
    print(f"duplicate physicalid rows removed: {duplicates}")
    print(f"rows dropped (null/short geometry, bad borough): {len(dropped)}")
    for physicalid, objectid in dropped:
        print(f"  dropped physicalid {physicalid} objectid {objectid}")
    print(f"rows split (kept longest part): {len(split)}")
    for physicalid, objectid in split:
        print(f"  split physicalid {physicalid} objectid {objectid}")
    print(f"segments written: {len(segments)}, vertices: {vertex_total}")
    for code, count in enumerate(counts, start=1):
        print(f"  {BOROUGH_NAMES[code]} ({code}): {count}")
    print(f"wrote {output} ({len(body)} bytes)")


if __name__ == "__main__":
    main()
