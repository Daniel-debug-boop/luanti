#pragma once

// The GDExtension surface: two RefCounted classes and no node types.
//
// The split exists for one reason: parsing a tile and meshing it are separate
// decisions in time. A client parses a tile when its bytes arrive (possibly
// off the main thread) and meshes it only when the tile is about to be drawn,
// by which point the raw bytes may be long gone. WorldStreamBatch is the
// thing that survives between those two moments -- it owns the parsed
// features, so build_meshlets() never needs the tile buffer again.
//
// Nothing here touches the voxel world. This is a geospatial source of
// geometry, not a second world: it produces arrays, it does not register a
// terrain, and it is inert when the library is absent.

#include <cstdint>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "ws_streamer.hpp"
#include "ws_types.hpp"

namespace godot {

// A parsed tile, owned by the client between parse and mesh.
class WorldStreamBatch : public RefCounted {
    GDCLASS(WorldStreamBatch, RefCounted)

public:
    ws::TileFeatureSet features;

    int64_t footprint_count() const;
    int64_t spline_count() const;
    // One footprint, for tests and debug UI: ring, holes, height_m, levels,
    // class and action. The native side keeps the authoritative copy; this is
    // a read-out, not a handle.
    Dictionary footprint(int64_t index) const;
    Dictionary spline(int64_t index) const;

    static void _bind_methods();
};

// The module entry point for GDScript.
class WorldStreamNative : public RefCounted {
    GDCLASS(WorldStreamNative, RefCounted)

public:
    // H3 cells around a position: the centre cell plus `radius` rings, at one
    // resolution. Empty when the request is invalid -- an empty resident set
    // is a state the caller already has to handle, so it is not an error.
    PackedInt64Array cells_around(double lat, double lon, int64_t resolution,
                                  int64_t radius) const;

    // [lat, lon] in degrees, or empty when the index is not a cell.
    PackedFloat64Array cell_center(int64_t h3_index) const;

    // Parse one Mapbox vector tile. Returns {ok, error, batch, stats}.
    Dictionary parse_tile(const PackedByteArray &data, int64_t h3_index,
                          int64_t resolution, double tile_size_m) const;

    // Mesh a parsed tile into GPU-ready arrays. Returns
    // {ok, error, positions, normals, materials, ao, indices,
    //  meshlet_vertices, meshlet_triangles, meshlets, bounds_min,
    //  bounds_max, triangles}.
    Dictionary build_meshlets(const Ref<WorldStreamBatch> &batch,
                              double road_width_m, double road_lift_m) const;

    // Bumped whenever a method's shape changes; the GDScript facade refuses a
    // mismatch rather than misinterpreting an array.
    int64_t module_version() const;

    static void _bind_methods();
};

}  // namespace godot
