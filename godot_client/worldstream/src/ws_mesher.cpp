// Module 2 implementation: extrusion, ribbons and meshletisation.
//
// One batch per tile. Footprints become closed prisms (earcut-triangulated
// roof, wall quads), splines become ground ribbons, and the whole tile is
// then handed to meshoptimizer: vertex-cache order, vertex-fetch order, and
// 64-vertex / 126-triangle meshlets with normal cones. Determinism comes from
// the pipeline itself -- every stage is order-fixed and allocation-stable --
// so a re-fetched tile meshes to the same bytes.

#include "ws_mesher.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

#include <earcut.hpp>
#include <meshoptimizer.h>

namespace ws {

namespace {

// Earcut works on std::array<double, 2> rings; the adapter is the one
// documented by mapbox/earcut.hpp.
using EarcutPoint = std::array<double, 2>;

// meshlet limits, matching ws_types.hpp and the mesh-shader hardware limits.
constexpr std::size_t kMaxMeshletVertices = kMeshletMaxVertices;   // 64
constexpr std::size_t kMaxMeshletTriangles = kMeshletMaxTriangles; // 126

struct BatchBuilder {
    MeshletBatch* batch = nullptr;

    // Positions mirrored as a separate float3 stream for meshopt, which wants
    // positions strided rather than interleaved with normals/materials.
    std::vector<float> positions;

    void vertex(const Vec3& p, const Vec3& n, std::uint32_t material, float ao) {
        BuildVertex v;
        v.px = p.x; v.py = p.y; v.pz = p.z;
        v.nx = n.x; v.ny = n.y; v.nz = n.z;
        v.material_id = material;
        v.ao = ao;
        batch->vertices.push_back(v);
        positions.push_back(p.x);
        positions.push_back(p.y);
        positions.push_back(p.z);
    }

    void tri(std::uint32_t a, std::uint32_t b, std::uint32_t c) {
        batch->indices.push_back(a);
        batch->indices.push_back(b);
        batch->indices.push_back(c);
    }

    std::uint32_t base() const {
        return static_cast<std::uint32_t>(batch->vertices.size());
    }

    // Drop consecutive duplicate points. MVT rings are explicitly closed (the
    // decoder emits the start point again at ring_end), and a zero-length
    // edge produces a degenerate triangle plus a zero-length normal.
    static void weld_ring(std::vector<Vec2>& ring, float eps) {
        std::vector<Vec2> out;
        out.reserve(ring.size());
        for (const Vec2& p : ring) {
            if (out.empty() ||
                std::fabs(p.x - out.back().x) > eps ||
                std::fabs(p.y - out.back().y) > eps) {
                out.push_back(p);
            }
        }
        // The decoder's closing duplicate is the common case: drop the last
        // point if it equals the first (rings are implicitly closed here).
        if (out.size() >= 2 &&
            std::fabs(out.front().x - out.back().x) <= eps &&
            std::fabs(out.front().y - out.back().y) <= eps) {
            out.pop_back();
        }
        ring = std::move(out);
    }
};

// Roof + walls for one footprint. The roof is the earcut triangulation of the
// ring-with-holes at height h; walls are one quad per ring edge. Normals are
// exact (edge normalised), AO is a cheap height gradient on walls and full
// brightness on roofs -- a real AO bake is a render-side pass, and the field
// exists so that pass has somewhere to write.
void emit_footprint(BatchBuilder& b, const Footprint& f) {
    const float h = f.height_m;

    // --- roof ---
    // earcut's default adapter consumes std::array<double, 2> rings, outer
    // first. ws::Vec2 is float, hence the explicit widening here rather than
    // a range constructor.
    std::vector<std::vector<EarcutPoint>> polygon;
    polygon.reserve(1 + f.holes.size());
    const auto ring_to_earcut = [](const std::vector<Vec2>& ring) {
        std::vector<EarcutPoint> out;
        out.reserve(ring.size());
        for (const Vec2& p : ring) {
            out.push_back(EarcutPoint{p.x, p.y});
        }
        return out;
    };
    polygon.push_back(ring_to_earcut(f.ring));
    for (const auto& hole : f.holes) {
        polygon.push_back(ring_to_earcut(hole));
    }
    const std::vector<std::uint32_t> roof_idx =
        mapbox::earcut<std::uint32_t>(polygon);

    const std::uint32_t roof_base = b.base();
    for (const Vec2& p : f.ring) {
        b.vertex(Vec3{p.x, h, p.y}, Vec3{0.0f, 1.0f, 0.0f}, f.roof_material_id, 1.0f);
    }
    // Hole vertices follow the outer ring in the same order earcut consumed
    // them, so roof_idx addresses them correctly.
    for (const auto& hole : f.holes) {
        for (const Vec2& p : hole) {
            b.vertex(Vec3{p.x, h, p.y}, Vec3{0.0f, 1.0f, 0.0f}, f.roof_material_id, 1.0f);
        }
    }
    for (std::size_t i = 0; i + 2 < roof_idx.size(); i += 3) {
        b.tri(roof_base + roof_idx[i], roof_base + roof_idx[i + 1],
              roof_base + roof_idx[i + 2]);
    }

    // --- walls ---
    const auto emit_walls = [&](const std::vector<Vec2>& ring) {
        for (std::size_t i = 0; i < ring.size(); ++i) {
            const Vec2& a = ring[i];
            const Vec2& c = ring[(i + 1) % ring.size()];
            const float ex = c.x - a.x;
            const float ez = c.y - a.y;
            const float len = std::sqrt(ex * ex + ez * ez);
            if (len <= 1e-6f) {
                continue;  // degenerate edge; no wall to draw
            }
            const Vec3 n{ez / len, 0.0f, -ex / len};  // edge rotated -90 deg
            const std::uint32_t v0 = b.base();
            b.vertex(Vec3{a.x, 0.0f, a.y}, n, f.material_id, 0.6f);
            b.vertex(Vec3{c.x, 0.0f, c.y}, n, f.material_id, 0.6f);
            b.vertex(Vec3{c.x, h, c.y}, n, f.material_id, 1.0f);
            b.vertex(Vec3{a.x, h, a.y}, n, f.material_id, 1.0f);
            b.tri(v0 + 0, v0 + 1, v0 + 2);
            b.tri(v0 + 0, v0 + 2, v0 + 3);
        }
    };
    emit_walls(f.ring);
    for (const auto& hole : f.holes) {
        emit_walls(hole);
    }
}

// One ribbon quad per spline segment. No miter joins: overlapping quads at
// joints are invisible at road widths and a correct join is a large amount of
// geometry work for a ground decal.
void emit_spline(BatchBuilder& b, const Spline& s, const MesherParams& params) {
    const float half = params.road_width_m * 0.5f;
    const float y = params.road_lift_m;
    for (std::size_t i = 0; i + 1 < s.points.size(); ++i) {
        const Vec2& a = s.points[i];
        const Vec2& c = s.points[i + 1];
        const float ex = c.x - a.x;
        const float ez = c.y - a.y;
        const float len = std::sqrt(ex * ex + ez * ez);
        if (len <= 1e-6f) {
            continue;
        }
        const float nx = (ez / len) * half;
        const float nz = -(ex / len) * half;
        const std::uint32_t v0 = b.base();
        const Vec3 up{0.0f, 1.0f, 0.0f};
        b.vertex(Vec3{a.x - nx, y, a.y - nz}, up, s.material_id, 1.0f);
        b.vertex(Vec3{a.x + nx, y, a.y + nz}, up, s.material_id, 1.0f);
        b.vertex(Vec3{c.x + nx, y, c.y + nz}, up, s.material_id, 1.0f);
        b.vertex(Vec3{c.x - nx, y, c.y - nz}, up, s.material_id, 1.0f);
        // Wound so the up normal faces the camera: CCW seen from +y.
        b.tri(v0 + 0, v0 + 2, v0 + 1);
        b.tri(v0 + 0, v0 + 3, v0 + 2);
    }
}

// Turn the built triangle soup into meshlets. Runs the two meshopt passes the
// renderer depends on -- vertex-cache order, then vertex-fetch order -- and
// then splits into 64/126 clusters with normal cones.
bool meshletize(BatchBuilder& b, MeshletBatch& out, std::string& error) {
    const std::size_t vertex_count = out.vertices.size();
    const std::size_t index_count = out.indices.size();

    // Pass 1: vertex cache. In-place is explicitly supported.
    meshopt_optimizeVertexCache(out.indices.data(), out.indices.data(),
                                index_count, vertex_count);

    // Pass 2: vertex fetch. The remap is applied to every vertex stream --
    // the interleaved batch buffer and the float3 position mirror -- because
    // meshopt builds buffers per stream.
    std::vector<unsigned int> remap(vertex_count);
    const std::size_t unique =
        meshopt_optimizeVertexFetchRemap(remap.data(), out.indices.data(),
                                         index_count, vertex_count);
    if (unique == 0) {
        error = "meshopt reported zero unique vertices";
        return false;
    }

    std::vector<BuildVertex> fetched(unique);
    std::vector<float> fetched_positions(unique * 3);
    std::vector<unsigned int> fetched_indices(index_count);
    meshopt_remapVertexBuffer(fetched.data(), out.vertices.data(),
                              vertex_count, sizeof(BuildVertex), remap.data());
    meshopt_remapVertexBuffer(fetched_positions.data(), b.positions.data(),
                              vertex_count, sizeof(float) * 3, remap.data());
    meshopt_remapIndexBuffer(fetched_indices.data(), out.indices.data(),
                             index_count, remap.data());

    out.vertices = std::move(fetched);
    out.indices = std::move(fetched_indices);
    b.positions = std::move(fetched_positions);

    // Pass 3: meshlets with normal cones.
    const std::size_t bound = meshopt_buildMeshletsBound(
        index_count, kMaxMeshletVertices, kMaxMeshletTriangles);
    std::vector<meshopt_Meshlet> mvo(bound);
    std::vector<unsigned int> meshlet_vertices(bound * kMaxMeshletVertices);
    std::vector<unsigned char> meshlet_triangles(bound * kMaxMeshletTriangles * 3);

    const std::size_t meshlet_count = meshopt_buildMeshlets(
        mvo.data(), meshlet_vertices.data(), meshlet_triangles.data(),
        out.indices.data(), index_count, b.positions.data(), out.vertices.size(),
        sizeof(float) * 3, kMaxMeshletVertices, kMaxMeshletTriangles,
        1.0f /* cone_weight: cones on, worth 1% of cluster size */);

    out.meshlets.reserve(meshlet_count);
    for (std::size_t i = 0; i < meshlet_count; ++i) {
        const meshopt_Meshlet& m = mvo[i];
        Meshlet out_m;
        out_m.vertex_offset = m.vertex_offset;
        out_m.triangle_offset = m.triangle_offset;
        out_m.vertex_count = m.vertex_count;
        out_m.triangle_count = m.triangle_count;

        const meshopt_Bounds bounds = meshopt_computeMeshletBounds(
            meshlet_vertices.data() + m.vertex_offset,
            meshlet_triangles.data() + m.triangle_offset, m.triangle_count,
            b.positions.data(), out.vertices.size(), sizeof(float) * 3);
        out_m.cone_axis[0] = static_cast<float>(bounds.cone_axis_s8[0]) / 127.0f;
        out_m.cone_axis[1] = static_cast<float>(bounds.cone_axis_s8[1]) / 127.0f;
        out_m.cone_axis[2] = static_cast<float>(bounds.cone_axis_s8[2]) / 127.0f;
        out_m.cone_axis[3] = 0.0f;
        out_m.cone_cutoff = bounds.cone_cutoff;
        out.meshlets.push_back(out_m);
    }

    // The batch-level indirection buffers: local indices widened to 32-bit and
    // the byte triangles copied verbatim, both truncated to what was used.
    //
    // Truncating to the last *used* meshlet, not to mvo.back(): meshopt is
    // given a worst-case-sized array and typically fills a fraction of it, so
    // mvo.back() is usually an unwritten slot whose zero counts would truncate
    // both buffers to nothing.
    const meshopt_Meshlet& last = mvo[meshlet_count - 1];
    out.meshlet_vertices.assign(meshlet_vertices.begin(),
                                meshlet_vertices.begin() +
                                    (last.vertex_offset + last.vertex_count));
    out.meshlet_triangles.assign(meshlet_triangles.begin(),
                                 meshlet_triangles.begin() +
                                     (last.triangle_offset +
                                      last.triangle_count * 3));

    // Batch bounds for the per-tile culling test.
    Vec3 lo{out.vertices[0].px, out.vertices[0].py, out.vertices[0].pz};
    Vec3 hi = lo;
    for (const BuildVertex& v : out.vertices) {
        lo.x = std::fmin(lo.x, v.px); lo.y = std::fmin(lo.y, v.py); lo.z = std::fmin(lo.z, v.pz);
        hi.x = std::fmax(hi.x, v.px); hi.y = std::fmax(hi.y, v.py); hi.z = std::fmax(hi.z, v.pz);
    }
    out.bounds_min = lo;
    out.bounds_max = hi;
    return true;
}

}  // namespace

bool build_structures(const TileFeatureSet& set,
                      const MesherParams& params,
                      MeshletBatch& out,
                      std::string& error) {
    out.vertices.clear();
    out.indices.clear();
    out.meshlet_vertices.clear();
    out.meshlet_triangles.clear();
    out.meshlets.clear();
    out.bounds_min = Vec3{};
    out.bounds_max = Vec3{};
    error.clear();

    BatchBuilder b;
    b.batch = &out;

    for (const Footprint& f : set.footprints) {
        if (f.ring.size() < 3) {
            error = "footprint ring has fewer than 3 points";
            return false;
        }
        Footprint welded = f;
        BatchBuilder::weld_ring(welded.ring, 0.001f);
        for (auto& hole : welded.holes) {
            BatchBuilder::weld_ring(hole, 0.001f);
        }
        if (welded.ring.size() < 3) {
            // Collapsed after welding; a zero-area footprint cannot be
            // extruded. Skipping one degenerate feature must not fail the
            // whole tile -- real OSM data contains them.
            continue;
        }
        emit_footprint(b, welded);
    }

    for (const Spline& s : set.splines) {
        emit_spline(b, s, params);
    }

    if (out.vertices.empty()) {
        return true;  // empty tile, empty batch
    }
    if (out.indices.size() % 3 != 0) {
        error = "index count is not a multiple of three";
        return false;
    }

    return meshletize(b, out, error);
}

}  // namespace ws
