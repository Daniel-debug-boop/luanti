#!/usr/bin/env python3
"""Convert a Luanti world into flat chunk files for the Godot client.

Godot 4.4 exposes no zstd binding, and Luanti's current world format (29)
compresses every MapBlock with zstd. Rather than take a native build
dependency into the engine, decompression happens here, offline, using the
reference zstandard implementation. The result is a dead-simple chunk format
the Godot side can read with zero compression code at runtime.

This also removes the need for the client to parse SQLite at all, which is
the other heavyweight dependency the engine would otherwise carry.

Usage:
    python3 convert_world.py <world_dir> <out_dir> [--radius N] [--center X Y Z]

Input:  a Luanti world directory containing map.sqlite
Output: <out_dir>/manifest.json plus <out_dir>/c_<x>_<y>_<z>.chunk
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import zlib

import chunk_format

try:
    import zstandard as zstd
except ImportError:  # pragma: no cover
    zstd = None

MAP_BLOCKSIZE = 16
BLOCK_VOLUME = MAP_BLOCKSIZE ** 3
ZSTD_FROM_VERSION = 29

# Node ids that carry no geometry.
CONTENT_IGNORE_THRESHOLD = 127


class BlockError(Exception):
    pass


def decompress_body(blob: bytes, version: int) -> bytes:
    """Return the uncompressed MapBlock body (everything after the version).

    Before format 29 each section was zlib-compressed separately; from 29 the
    whole block is zstd-compressed as one unit.
    """
    body = blob[1:]
    if version >= ZSTD_FROM_VERSION:
        if zstd is None:
            raise BlockError("format 29 needs the zstandard package")
        try:
            return zstd.ZstdDecompressor().decompress(
                body, max_output_size=1 << 20)
        except zstd.ZstdError as exc:
            # Content size is sometimes absent from the frame header, so fall
            # back to a streaming decompress with an unknown output size.
            try:
                dctx = zstd.ZstdDecompressor()
                with dctx.stream_reader(__import__("io").BytesIO(body)) as r:
                    return r.read()
            except Exception as exc2:
                raise BlockError(f"zstd failed: {exc} / {exc2}") from exc2
    try:
        return zlib.decompress(body)
    except zlib.error:
        # Older builds stored the block zlib-compressed in one stream; if that
        # fails the node arrays are individually compressed, handled downstream.
        return b""


def _read_varint(buf: bytes, p: int) -> tuple[int, int]:
    result = 0
    for i in range(5):
        if p + i >= len(buf):
            return result, i
        b = buf[p + i]
        result |= (b & 0x7F) << (7 * i)
        if not (b & 0x80):
            return result, i + 1
    return result, 5


def parse_block(blob: bytes) -> dict:
    """Decode one serialized MapBlock into flat node arrays."""
    if len(blob) < 2:
        raise BlockError("blob too short")
    version = blob[0]
    if version < 22 or version > 29:
        raise BlockError(f"unsupported version {version}")

    raw = decompress_body(blob, version)
    if not raw:
        raise BlockError("decompression produced nothing")

    p = 0
    flags = raw[p]
    p += 1
    if version >= 27:
        p += 2  # lighting_complete
    if version >= 29:
        p += 4  # u32 timestamp
        # NameIdMapping (see src/nameidmapping.cpp): a u8 version byte, a u16
        # count (NOT a varint), then `count` entries of (u16 id, u16 name
        # length, name bytes).
        if p < len(raw):
            p += 1
        if p + 2 <= len(raw):
            count = int.from_bytes(raw[p:p + 2], "big")
            p += 2
            for _ in range(count):
                if p + 2 > len(raw):
                    break
                p += 2  # id
                nlen = int.from_bytes(raw[p:p + 2], "big")
                p += 2 + nlen
    if p + 2 > len(raw):
        raise BlockError("truncated widths")
    content_width = raw[p]
    p += 1
    params_width = raw[p]
    p += 1
    if params_width != 2:
        raise BlockError(f"params_width {params_width} unsupported")

    n = BLOCK_VOLUME
    if content_width == 1:
        if p + n > len(raw):
            raise BlockError("truncated param0")
        content = raw[p:p + n]
        p += n
    elif content_width == 2:
        if p + n * 2 > len(raw):
            raise BlockError("truncated param0 (wide)")
        # Big-endian u16 content ids.
        content = raw[p:p + n * 2]
        p += n * 2
    else:
        raise BlockError(f"content_width {content_width} unsupported")

    if p + n > len(raw):
        raise BlockError("truncated param1")
    light = raw[p:p + n]
    p += n
    if p + n > len(raw):
        raise BlockError("truncated param2")
    param2 = raw[p:p + n]
    p += n

    return {
        "version": version,
        "flags": flags,
        "content_width": content_width,
        "content": content,
        "light": light,
        "param2": param2,
    }


def content_ids(content: bytes, width: int) -> list[int]:
    if width == 1:
        return list(content)
    return [int.from_bytes(content[i * 2:i * 2 + 2], "big")
            for i in range(len(content) // 2)]


def iter_block_positions(con: sqlite3.Connection) -> list[tuple[int, int, int]]:
    """Return (x, y, z) for every row, handling both schema generations."""
    cols = [r[1] for r in con.execute("PRAGMA table_info(blocks)")]
    if "x" in cols and "y" in cols and "z" in cols:
        return [tuple(r) for r in con.execute("SELECT x, y, z FROM blocks")]

    # Pre-5.12.0: a single packed position.
    out = []
    for (pos,) in con.execute("SELECT pos FROM blocks"):
        p = pos + 0x800800800
        out.append(((p & 0xFFF) - 0x800,
                    ((p >> 12) & 0xFFF) - 0x800,
                    ((p >> 24) & 0xFFF) - 0x800))
    return out


def fetch_blob(con: sqlite3.Connection, x: int, y: int, z: int) -> bytes | None:
    cols = [r[1] for r in con.execute("PRAGMA table_info(blocks)")]
    if "x" in cols:
        row = con.execute(
            "SELECT data FROM blocks WHERE x=? AND y=? AND z=?",
            (x, y, z)).fetchone()
    else:
        pos = (z << 24) + (y << 12) + x
        row = con.execute("SELECT data FROM blocks WHERE pos=?",
                          (pos,)).fetchone()
    return row[0] if row else None


def load_content_names(world_dir: str) -> dict[int, str]:
    """Map each Luanti content id to its node name, from content_ids.txt.

    This is the only bridge between Luanti's per-world id numbering and
    EMERGENT's own ContentDB table: the reader maps the names through
    ContentDB, so a converted world means what it looks like it means. A
    world with no content_ids.txt (a generated fixture, or a converter run
    against a format that never wrote one) simply has no names, and its ids
    pass through untouched.
    """
    path = os.path.join(world_dir, "content_ids.txt")
    if not os.path.isfile(path):
        return {}
    out: dict[int, str] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, raw = line.partition("=")
            try:
                out[int(raw.strip())] = name.strip()
            except ValueError:
                continue
    return out


def write_chunk(path: str, block: dict) -> int:
    """Write one chunk file: a 10-byte header plus the three node arrays.

    The layout lives in `chunk_format`, which `chunk_files.gd` also follows.
    It used to be spelled out here with a `struct.pack("<IHHBB", ...)` and a
    hardcoded 9, and those two disagreed: the struct is 10 bytes, so every
    file was written one byte longer than the reader expected and every chunk
    was read one byte out of step.
    """
    content = block["content"]
    header = chunk_format.pack_header(chunk_format.VERSION,
                                      block["flags"],
                                      block["content_width"])
    with open(path, "wb") as fh:
        fh.write(header)
        fh.write(content)
        fh.write(block["light"])
        fh.write(block["param2"])
    return len(header) + len(content) + len(block["light"]) + len(block["param2"])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("world", help="Luanti world directory (contains map.sqlite)")
    ap.add_argument("out", help="output directory for chunk files")
    ap.add_argument("--radius", type=int, default=6,
                    help="only convert blocks within this many chunk-units "
                         "of the centre (0 = everything)")
    ap.add_argument("--center", type=int, nargs=3, default=[0, 0, 0],
                    metavar=("X", "Y", "Z"))
    ap.add_argument("--stats", action="store_true",
                    help="print per-content-type voxel counts")
    ap.add_argument("--authoritative", action="store_true",
                    help="mark the output world as authoritative for the "
                         "overworld (the client then refuses to fill absent "
                         "chunks from the procedural generator)")
    args = ap.parse_args()

    db = os.path.join(args.world, "map.sqlite")
    if not os.path.isfile(db):
        print(f"error: no map.sqlite in {args.world}", file=sys.stderr)
        return 1
    if zstd is None:
        print("warning: python 'zstandard' not installed; format 29 worlds "
              "cannot be decompressed", file=sys.stderr)

    os.makedirs(args.out, exist_ok=True)
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)

    positions = iter_block_positions(con)
    total = len(positions)
    if args.radius > 0:
        cx, cy, cz = args.center
        r = args.radius
        positions = [p for p in positions
                     if abs(p[0] - cx) <= r and abs(p[1] - cy) <= r
                     and abs(p[2] - cz) <= r]

    written = 0
    failed = 0
    versions: dict[int, int] = {}
    content_hist: dict[int, int] = {}
    for (x, y, z) in positions:
        blob = fetch_blob(con, x, y, z)
        if blob is None:
            continue
        try:
            block = parse_block(blob)
        except BlockError as exc:
            failed += 1
            if failed <= 5:
                print(f"  skip ({x},{y},{z}): {exc}", file=sys.stderr)
            continue
        versions[block["version"]] = versions.get(block["version"], 0) + 1
        if args.stats:
            for cid in content_ids(block["content"], block["content_width"]):
                content_hist[cid] = content_hist.get(cid, 0) + 1
        write_chunk(os.path.join(args.out, f"c_{x}_{y}_{z}.chunk"), block)
        written += 1

    # The converter can watermark its output as authoritative when the caller
    # asks for it. That is what the Arnis intake path wants: a converted world
    # produced from a pinned Arnis run is the source of truth for the overworld,
    # and the client must not let the procedural generator silently re-derive
    # terrain for chunks that are simply absent.
    provenance = (chunk_format.authoritative_manifest()
                  if args.authoritative else {})

    pos_min_x = pos_max_x = pos_min_y = pos_max_y = pos_min_z = pos_max_z = None
    for (x, y, z) in positions:
        if pos_min_x is None:
            pos_min_x = pos_max_x = x
            pos_min_y = pos_max_y = y
            pos_min_z = pos_max_z = z
        else:
            pos_min_x = min(pos_min_x, x)
            pos_max_x = max(pos_max_x, x)
            pos_min_y = min(pos_min_y, y)
            pos_max_y = max(pos_max_y, y)
            pos_min_z = min(pos_min_z, z)
            pos_max_z = max(pos_max_z, z)

    manifest = {
        "format": 1,
        "source": os.path.abspath(args.world),
        "blocks_total": total,
        "blocks_written": written,
        "blocks_failed": failed,
        "serialization_versions": {str(k): v for k, v in versions.items()},
        "origin": [0, 0, 0],
        # Luanti ids -> node names, so the reader can translate them into
        # ContentDB ids. Absent or empty means "these ids are already
        # ContentDB's", which is what the generated fixture is.
        "content_names": {str(k): v
                          for k, v in sorted(load_content_names(args.world).items())},
        "bounds": {
            "x": [pos_min_x, pos_max_x],
            "y": [pos_min_y, pos_max_y],
            "z": [pos_min_z, pos_max_z],
        } if pos_min_x is not None else None,
        **provenance,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"wrote {written} chunks to {args.out}")
    print(f"  source blocks: {total}, failed: {failed}")
    print(f"  serialization versions: {manifest['serialization_versions']}")
    if provenance:
        print("  provenance: this converted world is authoritative for the "
              "overworld and must not be reinterpreted by the procedural "
              "generator")
    if args.stats and content_hist:
        top = sorted(content_hist.items(), key=lambda kv: -kv[1])[:12]
        print("  most common content ids:")
        for cid, n in top:
            kind = "air" if cid == 0 else (
                "ignore" if cid <= CONTENT_IGNORE_THRESHOLD else "solid")
            print(f"    id {cid:>5}: {n:>9} voxels ({kind})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
