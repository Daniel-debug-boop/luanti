#pragma once

// Core value types shared by every WorldStream module.
//
// These are deliberately free of any Godot, H3, vtzero or meshopt types so the
// synthesis, sanitization and upload stages can be built and unit-tested on
// their own. Godot types appear only in the GDExtension shim layer.

#include <cstdint>
#include <cstddef>
#include <vector>

namespace ws {

// A footprint contour in tile-local metres. The vector tile gives us integer
// tile coordinates in [0, extent]; we convert to metres at the tile scale so
// downstream stages never see tile units.
struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
};

// Why a feature was removed or rewritten. Retained per-feature rather than
// dropped, because the render layer needs to draw *something* in its place and
// the replacement depends on the reason.
enum class FeatureClass : std::uint8_t {
    Building = 0,
    Highway = 1,
    Landuse = 2,
};

enum class SanitizeAction : std::uint8_t {
    Keep = 0,
    // Converted into generic open space (park/field) rather than a structure.
    ToOpenSpace = 1,
    // Converted into a generic warehouse footprint: same mass, no identity.
    ToGenericWarehouse = 2,
    // Road geometry shortened; the spline itself is retained.
    CompressedSpline = 3,
};

// One building footprint after parsing and (optionally) sanitizing.
struct Footprint {
    FeatureClass cls = FeatureClass::Building;
    SanitizeAction action = SanitizeAction::Keep;

    // Ring vertices, tile-local metres, implicitly closed (last != first).
    std::vector<Vec2> ring;
    // Interior rings (courtyards, holes). Indices into `rings`.
    std::vector<std::vector<Vec2>> holes;

    float height_m = 3.0f;      // resolved from building:levels or height
    std::uint16_t levels = 1;
    std::uint32_t material_id = 0;   // index into the bindless material array
    std::uint32_t roof_material_id = 0;
};

struct Spline {
    SanitizeAction action = SanitizeAction::Keep;
    std::vector<Vec2> points;
    std::uint32_t material_id = 0;
};

// Identifies the H3 cell a tile was fetched for. The 64-bit H3 index packs
// resolution and the cell address, so it doubles as the cache key.
struct TileKey {
    std::uint64_t h3_index = 0;
    std::uint8_t resolution = 0;

    bool operator==(const TileKey& o) const { return h3_index == o.h3_index; }
};

// Everything parsed out of one vector tile.
struct TileFeatureSet {
    TileKey key;
    std::vector<Footprint> footprints;
    std::vector<Spline> splines;
};

// Interleaved vertex layout used by every rasterised structure. 32 bytes,
// which keeps a single vertex inside one 128-bit load and lets the vertex
// buffer stay 16-byte aligned.
struct BuildVertex {
    float px, py, pz;   // object-space position, metres
    float nx, ny, nz;   // normal
    std::uint32_t material_id;  // index into the material texture array
    float ao;                  // baked corner occlusion in [0,1]
};

// 64-vertex / 126-triangle meshlet, matching the mesh-shader hardware limits.
constexpr std::uint32_t kMeshletMaxVertices = 64;
constexpr std::uint32_t kMeshletMaxTriangles = 126;

struct Meshlet {
    std::uint32_t vertex_offset = 0;   // into the meshlet's local vertex list
    std::uint32_t triangle_offset = 0; // into the meshlet's local triangle bytes
    std::uint32_t vertex_count = 0;
    std::uint32_t triangle_count = 0;
    // Normal cone, packed for the mesh shader's fast rejection test.
    float cone_axis[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float cone_cutoff = 1.0f;
};

// One structure's GPU-ready geometry, already remapped, cache-optimised and
// split into meshlets.
struct MeshletBatch {
    std::vector<BuildVertex> vertices;
    std::vector<std::uint32_t> indices;
    std::vector<std::uint32_t> meshlet_vertices;   // 32-bit local indices
    std::vector<std::uint8_t> meshlet_triangles;  // 3 bytes per triangle
    std::vector<Meshlet> meshlets;

    // Per-draw bounding volume for GPU culling, in tile-local metres.
    Vec3 bounds_min{};
    Vec3 bounds_max{};

    bool empty() const { return meshlets.empty(); }
    std::size_t triangle_count() const { return indices.size() / 3; }
};

}  // namespace ws