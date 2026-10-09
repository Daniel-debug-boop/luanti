# Arnis intake path (Godot client)

This is the engineering boundary for bringing an externally generated Luanti world
into the Godot client. The Godot client is authoritative for the play runtime;
Luanti's role in this project is the offline converter and storage format, not a
second engine running in parallel.

## Pipeline

```
OSM + elevation
  -> Arnis (external, pinned release/commit)
     -> Luanti world directory (map.sqlite, world.mt, auth.txt, content_ids.txt)
        -> tools/convert_world.py --authoritative
           -> chunk files + manifest.json
              -> VoxelWorld / ChunkFiles intake
                 -> existing streaming/mesh/runtime
```

Arnis is an offline generator. It does not run inside the client. The client's
job is to **open** the Luanti world Arnis produced and treat it as the real
world for that session, not to reimplement Arnis generation inside Godot.

## Where authority is decided

Authority is decided by the converted-world manifest, not by whether a chunk
happens to be present.

A manifest that carries:

```
"source_pipeline": "arnis",
"source_pipeline_version": "unpinned",
"world_format": "luanti-v29"
```

is an **authoritative converted world**. The client:

- loads chunks that exist on disk directly through `ChunkFiles`;
- treats an absent overworld chunk as genuinely absent, not as an invitation to
  re-derive it from the procedural generator;
- still allows player edits, streaming, and the save path exactly as before.

A manifest that omits the field keeps the older behaviour, where the procedural
generator may fill gaps. That is the generated fixture and any legacy converted
world that has not been given a provenance marker yet.

The constants `ChunkFiles.PIPELINE_NAME` and `ChunkFiles.WORLD_FORMAT` are the
GDScript side of that contract. The single Python source is
`tools/chunk_format.py::authoritative_manifest()`.

## Versioned world-format contract

Right now the only supported converted-world format is the one that comes from a
Luanti v29 `map.sqlite` and is written as `chunk_format.VERSION 1` chunk files.
That is the bridge. It is versioned on both sides:

- `manifest.json` format field for the converted-chunk package;
- per-chunk `version` in the binary header;
- `serialization_versions` in the manifest, so a world can say which Luanti
  mapblock serialization versions it actually contains;
- `world_format` in the manifest, so the client can tell an Arnis-derived Luanti
  v29 world from some future foreign source.

The next format change must either stay byte-compatible at the chunk level or
bump the chunk header version and be handled explicitly in `ChunkFiles.load_chunk`.

## Coordinate provenance

A converted world also records a `bounds` field:

```
"bounds": { "x": [min, max], "y": [min, max], "z": [min, max] }
```

That is the extent of the Luanti block coordinates that were converted. It is
not a new coordinate system. The client still uses the same chunk/node lattice it
always uses; the bounds are there so the client, the dev tools, and a bug report
can say where this world actually lives without guessing.

The deeper coordinate provenance note -- that Arnis works in a different internal
coordinate space than the Luanti runtime and that adjacent Arnis areas are placed
so they join -- is a property of the Arnis run, not of the client. The client's
responsibility is narrower: it trusts the converted Luanti block coordinates it is
given, validates that the manifest is internally consistent, and refuses to
silently invent terrain for a world that declared itself authoritative.

## What the tests cover

- The chunk binary format is declared once and both sides are tested against it.
- The authoritative provenance fields exist in the Python source, are emitted by
  the converter when asked, and are recognised by the GDScript reader.
- The reader rejects the same malformed inputs it already rejected, and the new
  manifest fields do not change the id bridge.
- The procedural generator is explicitly excluded from filling gaps inside an
  authoritative world. That is the regression test for "the old generator must not
  silently take over an Arnis world".

## What this does not do

- It does not embed Arnis in the client.
- It does not change `src/mapgen` here; the Godot client does not own that code.
- It does not claim any Arnis capability that the upstream project has not
  documented.
- It does not assume streaming inside the client is driven by Arnis at runtime.
  Arnis is offline; streaming here still uses the existing converted-chunk path.
