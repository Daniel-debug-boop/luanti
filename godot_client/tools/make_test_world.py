#!/usr/bin/env python3
"""Generate a small synthetic Luanti world for testing the Godot client.

Produces a real map.sqlite containing format-29 MapBlocks (zstd-compressed),
so the client exercises the same code path it would on a genuine world.
Terrain is a simple heightmap with dirt below and air above, plus a few
scattered stone blocks, so meshing has both flat and varied regions.
"""
from __future__ import annotations

import argparse
import math
import os
import random
import sqlite3
import struct
import sys

try:
    import zstandard as zstd
except ImportError:
    zstd = None

MAP_BLOCKSIZE = 16
BLOCK_VOLUME = MAP_BLOCKSIZE ** 3

# These are ContentDB ids, not Luanti's own: the Godot side reads a
# converted world back through ContentDB with no remapping in between, so
# the only id that survives the round trip is the one both sides agree on.
# (robustness_test asserts this table against ContentDB, which is how the
# water id was found sitting on 9 -- ContentDB's wood.)
CONTENT_AIR = 0
CONTENT_STONE = 3
CONTENT_DIRT = 2
CONTENT_GRASS = 1
CONTENT_WATER = 4

VERSION = 29
LIGHT_SUN = 15


def index(x: int, y: int, z: int) -> int:
    return z * MAP_BLOCKSIZE * MAP_BLOCKSIZE + y * MAP_BLOCKSIZE + x


def terrain_height(wx: int, wz: int) -> int:
    """Smooth, deterministic height in node units."""
    return 8 + int(3 * math.sin(wx * 0.11) + 2.5 * math.cos(wz * 0.09)
                   + 1.5 * math.sin((wx + wz) * 0.05))


def content_at(wx: int, wy: int, wz: int) -> int:
    h = terrain_height(wx, wz)
    if wy > h:
        return CONTENT_AIR
    if wy == h:
        return CONTENT_GRASS
    if wy > h - 4:
        return CONTENT_DIRT
    return CONTENT_STONE


def light_at(wx: int, wy: int, wz: int) -> int:
    """Day light in the low nibble: full above ground, dimmer below."""
    h = terrain_height(wx, wz)
    if wy > h:
        return LIGHT_SUN << 4
    depth = h - wy
    val = max(0, LIGHT_SUN - depth)
    return (val & 0x0F) | ((val & 0x0F) << 4)


def make_block(bx: int, by: int, bz: int, rng: random.Random) -> bytes:
    content = bytearray()
    light = bytearray()
    param2 = bytearray()
    for lz in range(MAP_BLOCKSIZE):
        for ly in range(MAP_BLOCKSIZE):
            for lx in range(MAP_BLOCKSIZE):
                wx = bx * MAP_BLOCKSIZE + lx
                wy = by * MAP_BLOCKSIZE + ly
                wz = bz * MAP_BLOCKSIZE + lz
                cid = content_at(wx, wy, wz)
                if cid == CONTENT_STONE and rng.random() < 0.004:
                    cid = CONTENT_WATER  # a few scattered features to vary faces
                content.append(cid & 0xFF)
                light.append(light_at(wx, wy, wz) & 0xFF)
                param2.append(0)

    body = bytearray()
    flags = 0x01 | 0x02 | 0x08  # underground, day/night differs, generated
    body.append(flags)
    body += struct.pack(">H", 0xFFFF)      # lighting_complete
    body += struct.pack(">I", 0xFFFFFFFF)  # invalid timestamp
    body.append(0)                          # name_id_mapping_version
    body += struct.pack(">H", 0)            # no name-id mappings
    body.append(1)                          # content_width = 1 byte
    body.append(2)                          # params_width (always 2)
    body += content
    body += light
    body += param2

    out = bytearray()
    out.append(VERSION)
    if zstd is None:
        raise SystemExit("python 'zstandard' is required to write v29 worlds")
    out += zstd.ZstdCompressor(level=3).compress(bytes(body))
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out", help="world directory to create")
    ap.add_argument("--size", type=int, default=6,
                    help="edge length in blocks")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    db = os.path.join(args.out, "map.sqlite")
    if os.path.exists(db):
        os.remove(db)
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE blocks (
        x INTEGER, y INTEGER, z INTEGER,
        data BLOB NOT NULL,
        PRIMARY KEY (x, z, y))""")
    con.execute("CREATE TABLE auth (id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name VARCHAR(32) UNIQUE, password VARCHAR(512), "
                "last_login INTEGER)")
    con.execute("CREATE TABLE user_privileges (id INTEGER, "
                "privilege VARCHAR(32), PRIMARY KEY (id, privilege))")

    rng = random.Random(args.seed)
    n = args.size
    half = n // 2
    written = 0
    for bx in range(-half, half + 1):
        for by in range(-1, 2):
            for bz in range(-half, half + 1):
                blob = make_block(bx, by, bz, rng)
                con.execute("INSERT OR REPLACE INTO blocks VALUES (?,?,?,?)",
                            (bx, by, bz, blob))
                written += 1
    con.commit()
    con.close()

    with open(os.path.join(args.out, "world.mt"), "w") as fh:
        fh.write("enable_rollback = false\n")

    print(f"created synthetic world at {args.out}")
    print(f"  {written} blocks in a {n}x3x{n} arrangement, format {VERSION}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
