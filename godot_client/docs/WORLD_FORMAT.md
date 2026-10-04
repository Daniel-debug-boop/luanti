# The converted-chunk binary format

This is the format `tools/convert_world.py` writes and
`scripts/world/chunk_files.gd` reads. It is the boundary between a Luanti
world and this client: everything upstream of it is Luanti's own storage
(`map.sqlite`, zstd-compressed per version), everything downstream is
`VoxelBlock`.

The canonical definition is `tools/chunk_format.py`. This document explains it;
the module is what the writer and the reader's tests actually agree on, so a
disagreement fails a test instead of quietly corrupting a world.

## Layout

All integers little-endian.

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 4 | `magic` | `u32`, `0x4358564C` — the bytes `L` `V` `X` `C` |
| 4 | 2 | `version` | `u16`, currently `1` |
| 6 | 2 | `flags` | `u16`, Luanti's per-block flags (below) |
| 8 | 1 | `cwidth` | `u8`, bytes per content id: `1` or `2` |
| 9 | 1 | `reserved` | `u8`, written as `0`, skipped on read |
| 10 | `cwidth × 4096` | `content` | content id per node |
| … | 4096 | `light` | per node, low nibble day / high nibble night |
| … | 4096 | `param2` | per node, node-specific metadata |

So the header is **10 bytes**, and the whole file is
`10 + cwidth × 4096 + 8192` bytes.

Content ids are **big-endian within the array**, which is how Luanti's own
`MapNode` stores them, and is independent of the little-endian header. A
2-byte id is written high byte first.

### Flags

| Bit | Meaning |
|---:|---|
| 0 | block is underground |
| 1 | daylight/nightlight differ in this block |
| 3 | set means the block is **not** generated |

Bit 3 is inverted relative to the others, because that is how Luanti defines
it: `0x08` means "not generated". `VoxelBlock.is_generated` is therefore
`(flags & 0x08) == 0`.

## Why this document exists

The header was declared twice — as a `struct.pack("<IHHBB", ...)` in the
converter and as `const HEADER_SIZE := 9` in the reader — and the two
disagreed. `<IHHBB` is 4 + 2 + 2 + 1 + 1 = **10** bytes; the reader believed
it was 9.

Nothing failed. A chunk file read one byte out of step is still a perfectly
readable file, so every chunk in every converted world was loaded with:

- the `reserved` byte consumed as the first content id,
- the whole `content` array displaced by one,
- `light` and `param2` displaced with it,
- and the final `param2` byte read from past the end of the payload.

The world looked plausible. Stone was stone. That is the worst possible
failure mode, and it is why the format is now declared once, why the reader
rejects a file whose length does not match its declared `cwidth`, and why
`chunk_format_test` asserts the writer's output length field by field.

## Validation the reader performs

`ChunkFiles.load_chunk` returns `null`, with a warning naming the file, when:

- the file is shorter than the 10-byte header,
- `magic` is not `LVXC`,
- `version` is not `1`,
- `cwidth` is neither `1` nor `2`,
- the file length is not exactly `10 + cwidth × 4096 + 8192`.

The length check is the important one. It is what turns "this file does not
match the format" into a refusal instead of a plausible-looking wrong answer.

## Content ids: the other half of the bridge

The binary format says how ids are *stored*; it does not say what they
*mean*. Luanti numbers content ids per world, from that world's own
`content_ids.txt`, while `ContentDB` has its own 0..31 table, and the two do
not agree. Nothing used to translate between them: a converted world arrived
full of foreign ids that read as whatever foreign id happened to mean, and
only the generated fixture -- whose ids were aligned by hand -- ever looked
right. (`CONTENT_WATER = 9` in the fixture, which is ContentDB's *wood*, was
exactly this, and the check that now catches it asserts the fixture's table
against ContentDB.)

So the converter records the names:

```json
"content_names": {"3": "default:water", "9": "default:stone"}
```

and `ChunkFiles.content_map()` maps them through `ContentDB.name_to_id`,
stripping the mod namespace (`default:stone` -> `stone`). A node EMERGENT has
no block for becomes air and is listed by `ChunkFiles.unmapped_names()`,
because a block from a mod we do not ship is not something to guess at, and
"it disappeared" is only acceptable if the game says so.

A manifest with **no** `content_names` means the ids are already ContentDB's,
and they pass through untouched. That is the generated fixture, and it is why
the two conventions can coexist without either one guessing.

## Versioning

`version` is checked, not ignored. A future format change must either stay
byte-compatible or bump `VERSION` and be handled explicitly in the reader; a
reader must never accept a version it does not understand.