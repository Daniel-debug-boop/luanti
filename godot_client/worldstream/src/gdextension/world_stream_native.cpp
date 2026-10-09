// GDExtension implementation. Every method is a thin, allocation-conscious
// translation between Godot's variant containers and the ws:: modules, which
// means the only logic here is conversion -- no algorithm is reimplemented in
// the binding, and therefore none can drift from the tested native code.

#include "world_stream_native.h"

#include <vector>

#include <godot_cpp/core/class_db.hpp>

#include "ws_mesher.hpp"

namespace godot {

// Bumped when a returned dictionary's shape changes incompatibly. The GDScript
// facade checks it, because "the extension is present" and "the extension is
// the one this script was written against" are different questions.
namespace {
constexpr int64_t kModuleVersion = 1;
}  // namespace

// --- WorldStreamBatch --------------------------------------------------------

int64_t WorldStreamBatch::footprint_count() const {
    return static_cast<int64_t>(features.footprints.size());
}

int64_t WorldStreamBatch::spline_count() const {
    return static_cast<int64_t>(features.splines.size());
}

Dictionary WorldStreamBatch::footprint(int64_t index) const {
    Dictionary out;
    if (index < 0 || static_cast<std::size_t>(index) >= features.footprints.size()) {
        return out;
    }
    const ws::Footprint &f = features.footprints[static_cast<std::size_t>(index)];

    PackedVector2Array ring;
    ring.resize(static_cast<int64_t>(f.ring.size()));
    for (std::size_t i = 0; i < f.ring.size(); ++i) {
        ring.set(static_cast<int64_t>(i), Vector2(f.ring[i].x, f.ring[i].y));
    }

    Array holes;
    for (const auto &hole : f.holes) {
        PackedVector2Array h;
        h.resize(static_cast<int64_t>(hole.size()));
        for (std::size_t i = 0; i < hole.size(); ++i) {
            h.set(static_cast<int64_t>(i), Vector2(hole[i].x, hole[i].y));
        }
        holes.push_back(h);
    }

    out["ring"] = ring;
    out["holes"] = holes;
    out["height_m"] = f.height_m;
    out["levels"] = static_cast<int64_t>(f.levels);
    out["class"] = static_cast<int64_t>(f.cls);
    out["action"] = static_cast<int64_t>(f.action);
    out["material_id"] = static_cast<int64_t>(f.material_id);
    out["roof_material_id"] = static_cast<int64_t>(f.roof_material_id);
    return out;
}

Dictionary WorldStreamBatch::spline(int64_t index) const {
    Dictionary out;
    if (index < 0 || static_cast<std::size_t>(index) >= features.splines.size()) {
        return out;
    }
    const ws::Spline &s = features.splines[static_cast<std::size_t>(index)];
    PackedVector2Array points;
    points.resize(static_cast<int64_t>(s.points.size()));
    for (std::size_t i = 0; i < s.points.size(); ++i) {
        points.set(static_cast<int64_t>(i), Vector2(s.points[i].x, s.points[i].y));
    }
    out["points"] = points;
    out["material_id"] = static_cast<int64_t>(s.material_id);
    out["action"] = static_cast<int64_t>(s.action);
    return out;
}

void WorldStreamBatch::_bind_methods() {
    ClassDB::bind_method(D_METHOD("footprint_count"), &WorldStreamBatch::footprint_count);
    ClassDB::bind_method(D_METHOD("spline_count"), &WorldStreamBatch::spline_count);
    ClassDB::bind_method(D_METHOD("footprint", "index"), &WorldStreamBatch::footprint);
    ClassDB::bind_method(D_METHOD("spline", "index"), &WorldStreamBatch::spline);
}

// --- WorldStreamNative -------------------------------------------------------

PackedInt64Array WorldStreamNative::cells_around(double lat, double lon,
                                                 int64_t resolution,
                                                 int64_t radius) const {
    PackedInt64Array out;
    if (resolution < ws::kMinStreamingResolution ||
        resolution > ws::kMaxStreamingResolution) {
        // Outside the streaming band the tiles are either uselessly coarse or
        // larger than a city; refusing is honest, silently clamping would
        // stream something the caller did not ask for.
        return out;
    }

    ws::CellSet set;
    if (!ws::cells_around(ws::LatLon{lat, lon}, static_cast<int>(resolution),
                          static_cast<int>(radius), set)) {
        return out;
    }

    out.resize(static_cast<int64_t>(set.cells.size()));
    for (std::size_t i = 0; i < set.cells.size(); ++i) {
        out.set(static_cast<int64_t>(i), static_cast<int64_t>(set.cells[i]));
    }
    return out;
}

PackedFloat64Array WorldStreamNative::cell_center(int64_t h3_index) const {
    PackedFloat64Array out;
    ws::LatLon centre{};
    if (!ws::cell_center(static_cast<std::uint64_t>(h3_index), centre)) {
        return out;
    }
    out.push_back(centre.lat);
    out.push_back(centre.lon);
    return out;
}

Dictionary WorldStreamNative::parse_tile(const PackedByteArray &data,
                                          int64_t h3_index, int64_t resolution,
                                          double tile_size_m) const {
    Dictionary out;
    Ref<WorldStreamBatch> batch;
    batch.instantiate();

    ws::ParseStats stats;
    std::string error;
    const ws::TileKey key{static_cast<std::uint64_t>(h3_index),
                          static_cast<std::uint8_t>(resolution)};

    const bool ok = ws::parse_vector_tile(data.ptr(), static_cast<std::size_t>(data.size()),
                                          key, tile_size_m, batch->features, stats, error);

    Dictionary stats_dict;
    stats_dict["buildings"] = static_cast<int64_t>(stats.buildings);
    stats_dict["highways"] = static_cast<int64_t>(stats.highways);
    stats_dict["landuse"] = static_cast<int64_t>(stats.landuse);
    stats_dict["total_points"] = static_cast<int64_t>(stats.total_points);

    out["ok"] = ok;
    out["error"] = String(error.c_str());
    out["stats"] = stats_dict;
    if (ok) {
        out["batch"] = batch;
    }
    return out;
}

Dictionary WorldStreamNative::build_meshlets(const Ref<WorldStreamBatch> &batch,
                                              double road_width_m,
                                              double road_lift_m) const {
    Dictionary out;
    if (batch.is_null()) {
        out["ok"] = false;
        out["error"] = "no batch: parse_tile returns one on success";
        return out;
    }

    ws::MesherParams params;
    params.road_width_m = static_cast<float>(road_width_m);
    params.road_lift_m = static_cast<float>(road_lift_m);

    ws::MeshletBatch mesh;
    std::string error;
    const bool ok = ws::build_structures(batch->features, params, mesh, error);
    out["ok"] = ok;
    out["error"] = String(error.c_str());
    if (!ok) {
        return out;
    }

    // De-interleaved: Godot's own arrays are the ones a Mesh or a MultiMesh
    // consumes directly, so the interleaved BuildVertex layout (which exists
    // for the mesh-shader path) is unpacked once, here.
    PackedVector3Array positions;
    PackedVector3Array normals;
    PackedInt32Array materials;
    PackedFloat32Array ao;
    positions.resize(static_cast<int64_t>(mesh.vertices.size()));
    normals.resize(static_cast<int64_t>(mesh.vertices.size()));
    materials.resize(static_cast<int64_t>(mesh.vertices.size()));
    ao.resize(static_cast<int64_t>(mesh.vertices.size()));
    for (std::size_t i = 0; i < mesh.vertices.size(); ++i) {
        const ws::BuildVertex &v = mesh.vertices[i];
        const int64_t j = static_cast<int64_t>(i);
        positions.set(j, Vector3(v.px, v.py, v.pz));
        normals.set(j, Vector3(v.nx, v.ny, v.nz));
        materials.set(j, static_cast<int32_t>(v.material_id));
        ao.set(j, v.ao);
    }

    PackedInt32Array indices;
    indices.resize(static_cast<int64_t>(mesh.indices.size()));
    for (std::size_t i = 0; i < mesh.indices.size(); ++i) {
        indices.set(static_cast<int64_t>(i), static_cast<int32_t>(mesh.indices[i]));
    }

    PackedInt32Array meshlet_vertices;
    meshlet_vertices.resize(static_cast<int64_t>(mesh.meshlet_vertices.size()));
    for (std::size_t i = 0; i < mesh.meshlet_vertices.size(); ++i) {
        meshlet_vertices.set(static_cast<int64_t>(i),
                             static_cast<int32_t>(mesh.meshlet_vertices[i]));
    }

    PackedByteArray meshlet_triangles;
    meshlet_triangles.resize(static_cast<int64_t>(mesh.meshlet_triangles.size()));
    for (std::size_t i = 0; i < mesh.meshlet_triangles.size(); ++i) {
        meshlet_triangles.set(static_cast<int64_t>(i), mesh.meshlet_triangles[i]);
    }

    Array meshlets;
    for (const ws::Meshlet &m : mesh.meshlets) {
        Dictionary d;
        d["vertex_offset"] = static_cast<int64_t>(m.vertex_offset);
        d["triangle_offset"] = static_cast<int64_t>(m.triangle_offset);
        d["vertex_count"] = static_cast<int64_t>(m.vertex_count);
        d["triangle_count"] = static_cast<int64_t>(m.triangle_count);
        d["cone_axis"] = Vector3(m.cone_axis[0], m.cone_axis[1], m.cone_axis[2]);
        d["cone_cutoff"] = m.cone_cutoff;
        meshlets.push_back(d);
    }

    out["positions"] = positions;
    out["normals"] = normals;
    out["materials"] = materials;
    out["ao"] = ao;
    out["indices"] = indices;
    out["meshlet_vertices"] = meshlet_vertices;
    out["meshlet_triangles"] = meshlet_triangles;
    out["meshlets"] = meshlets;
    out["bounds_min"] = Vector3(mesh.bounds_min.x, mesh.bounds_min.y, mesh.bounds_min.z);
    out["bounds_max"] = Vector3(mesh.bounds_max.x, mesh.bounds_max.y, mesh.bounds_max.z);
    out["triangles"] = static_cast<int64_t>(mesh.triangle_count());
    return out;
}

int64_t WorldStreamNative::module_version() const { return kModuleVersion; }

void WorldStreamNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("cells_around", "lat", "lon", "resolution", "radius"),
                         &WorldStreamNative::cells_around);
    ClassDB::bind_method(D_METHOD("cell_center", "h3_index"),
                         &WorldStreamNative::cell_center);
    ClassDB::bind_method(D_METHOD("parse_tile", "data", "h3_index", "resolution",
                                  "tile_size_m"),
                         &WorldStreamNative::parse_tile);
    ClassDB::bind_method(D_METHOD("build_meshlets", "batch", "road_width_m",
                                  "road_lift_m"),
                         &WorldStreamNative::build_meshlets,
                         DEFVAL(3.0), DEFVAL(0.05));
    ClassDB::bind_method(D_METHOD("module_version"), &WorldStreamNative::module_version);
}

}  // namespace godot
