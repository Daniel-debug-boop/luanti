"""The canonical binary layout of a converted chunk file.

This module is the single definition of the format. `tools/convert_world.py`
writes it and `godot_client/scripts/world/chunk_files.gd` reads it, and the two
disagreed: the writer packed `"<IHHBB"` -- 4 + 2 + 2 + 1 + 1 = **10** bytes --
while the reader defined `HEADER_SIZE := 9`. Nothing errored, because a
one-byte shift is still a readable file. Every chunk in every world was read
one byte out of step: the `reserved` byte was consumed as the first content
id, and the whole content/light/param2 triple was displaced. The last
param2 byte was read past the end of the payload.

The format is declared here as data rather than repeated as prose in two
languages, and `header_struct()` is what both sides' tests check against, so
the next disagreement fails a test instead of corrupting a world quietly.

Layout, all little-endian:

=========  ====  ===================================================
offset    size  field
=========  ====  ===================================================
0         4     magic    u32, 'LVXC' (0x4358564C)
4         2     version  u16, currently 1
6         2     flags    u16, Luanti block flags
8         1     cwidth   u8, 1 or 2 bytes per content id
9         1     reserved u8, written as 0, skipped on read
10        var   content  cwidth * 4096 bytes, big-endian per id
10+cw*4096 4096  light    one byte per node
10+cw*4096+4096  4096  param2   one byte per node
=========  ====  ===================================================

Content ids are big-endian within the array, which is what Luanti's own
MapNode stores, and it is independent of the little-endian header.
"""

import struct

MAGIC = 0x4358564C
"""b'LVXC', little-endian, so the file starts with the bytes 'L','V','X','C'."""

VERSION = 1

BLOCK_VOLUME = 4096
"""Nodes per chunk: 16 x 16 x 16."""

HEADER_STRUCT = struct.Struct("<IHHBB")
"""The whole header. `struct.calcsize` of this is 10 -- see HEADER_SIZE."""

HEADER_SIZE = HEADER_STRUCT.size
"""10. This constant is the reason the format is declared once: the bug was a
hardcoded 9 that did not match the struct it described."""

RESERVED = 0
"""Written as 0. Read and ignored, and skipped explicitly rather than by
assuming the header is 9 bytes long."""


def pack_header(version: int, flags: int, cwidth: int) -> bytes:
    """The 10 header bytes for one chunk."""
    if cwidth not in (1, 2):
        raise ValueError("cwidth must be 1 or 2, got %r" % (cwidth,))
    return HEADER_STRUCT.pack(MAGIC, version, flags & 0xFFFF, cwidth, RESERVED)


def unpack_header(blob: bytes, offset: int = 0) -> dict:
    """Parse a header, raising on anything the reader would have to guess at."""
    if len(blob) - offset < HEADER_SIZE:
        raise ValueError("chunk file is shorter than its %d-byte header"
                         % HEADER_SIZE)
    magic, version, flags, cwidth, _reserved = HEADER_STRUCT.unpack_from(
        blob, offset)
    if magic != MAGIC:
        raise ValueError("bad magic %08x, expected %08x" % (magic, MAGIC))
    if version != VERSION:
        raise ValueError("unsupported chunk version %d" % version)
    if cwidth not in (1, 2):
        raise ValueError("cwidth must be 1 or 2, got %d" % cwidth)
    return {"version": version, "flags": flags, "cwidth": cwidth}


def payload_offset(cwidth: int) -> int:
    """Byte offset of the content array: the header, and nothing before it."""
    return HEADER_SIZE


def expected_size(cwidth: int) -> int:
    """Total file size for a given content width."""
    return HEADER_SIZE + cwidth * BLOCK_VOLUME + 2 * BLOCK_VOLUME