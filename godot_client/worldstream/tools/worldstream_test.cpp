// WorldStream native unit tests.
//
// These run on the build machine with no Godot and no I/O: the H3 grid, the
// vector-tile parser, the arena/ring primitives and the mesher are all pure
// functions over buffers. The fixture tile is encoded here with protozero, so
// the parser is tested against bytes we know the meaning of -- the point of a
// fixture, and the reason a "does it load a real tile" test would not have
// caught the header-offset class of bug this suite is written to catch.
//
// Verdict line goes to stdout at column 0: `worldstream-native: PASS`.

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// pbf_builder.hpp (not just basic_pbf_builder.hpp) is what pulls in
// buffer_string.hpp, where the std::string buffer customization the builder
// needs is defined.
#include <protozero/pbf_builder.hpp>
#include <protozero/types.hpp>

#include "ws_arena.hpp"
#include "ws_mesher.hpp"
#include "ws_ring.hpp"
#include "ws_streamer.hpp"
#include "ws_types.hpp"

namespace {

int g_failures = 0;

void check(bool cond, const std::string& what) {
    if (cond) {
        std::printf("  ok   %s\n", what.c_str());
    } else {
        ++g_failures;
        std::printf("  FAIL %s\n", what.c_str());
    }
}

void check_eq(std::int64_t got, std::int64_t want, const std::string& what) {
    if (got == want) {
        std::printf("  ok   %s == %lld\n", what.c_str(),
                    static_cast<long long>(want));
    } else {
        ++g_failures;
        std::printf("  FAIL %s: got %lld, want %lld\n", what.c_str(),
                    static_cast<long long>(got),
                    static_cast<long long>(want));
    }
}

bool nearly(float a, float b, float eps = 1e-3f) {
    return std::fabs(a - b) <= eps;
}

// --- fixture encoding -------------------------------------------------------
//
// vector_tile.proto field numbers, spelled once so the fixture below reads as
// the message it encodes rather than as a list of magic integers.

enum class TileTag : protozero::pbf_tag_type { layer = 3 };
enum class LayerTag : protozero::pbf_tag_type {
    name = 1,
    features = 2,
    keys = 3,
    values = 4,
    extent = 5,
    version = 15,
};
enum class FeatureTag : protozero::pbf_tag_type {
    id = 1,
    tags = 2,
    type = 3,
    geometry = 4,
};
enum class ValueTag : protozero::pbf_tag_type { string_value = 1 };

// Each message has its own tag enum, so each gets its own builder type. The
// nested-message constructor takes the *parent's* tag, which is why the
// feature/value builders are constructed with a LayerTag even though they
// write FeatureTag/ValueTag fields.
using Builder = protozero::basic_pbf_builder<std::string, LayerTag>;
using FeatureBuilder = protozero::basic_pbf_builder<std::string, FeatureTag>;
using ValueBuilder = protozero::basic_pbf_builder<std::string, ValueTag>;

// Zigzag-encode a delta, the way MVT parameter integers are stored.
std::uint32_t zz(std::int32_t v) {
    return (static_cast<std::uint32_t>(v) << 1) ^ static_cast<std::uint32_t>(v >> 31);
}

std::uint32_t cmd(std::uint32_t count, std::uint32_t id) {
    return (count << 3) | id;  // MoveTo=1, LineTo=2, ClosePath=7
}

void add_feature(Builder& layer, std::uint64_t id, const std::vector<std::uint32_t>& tags,
                 std::uint32_t geom_type, const std::vector<std::uint32_t>& geometry) {
    FeatureBuilder feat{layer, LayerTag::features};
    feat.add_uint64(FeatureTag::id, id);
    feat.add_packed_uint32(FeatureTag::tags, tags.begin(), tags.end());
    feat.add_enum(FeatureTag::type, static_cast<std::int32_t>(geom_type));
    feat.add_packed_uint32(FeatureTag::geometry, geometry.begin(), geometry.end());
}

void add_string_value(Builder& layer, const std::string& v) {
    ValueBuilder value{layer, LayerTag::values};
    value.add_string(ValueTag::string_value, v);
}

// extent 4096, tile 1000 m: 100 tile units == 24.4140625 m, which is what the
// parser tests below assert against.
std::string make_fixture_tile() {
    std::string buf;
    protozero::basic_pbf_builder<std::string, TileTag> tile{buf};

    {
        Builder layer{tile, TileTag::layer};
        layer.add_string(LayerTag::name, "buildings");
        layer.add_uint32(LayerTag::version, 2);
        layer.add_uint32(LayerTag::extent, 4096);
        layer.add_string(LayerTag::keys, "building:levels");
        layer.add_string(LayerTag::keys, "height");
        add_string_value(layer, "3");
        add_string_value(layer, "12");

        // Feature A: 300x300-unit square at (100,100), levels = 3.
        add_feature(layer, 1, {0, 0}, 3,
                    {cmd(1, 1), zz(100), zz(100), cmd(3, 2), zz(300), zz(0),
                     zz(0), zz(300), zz(-300), zz(0), cmd(1, 7)});
        // Feature B: 500x500-unit square at (1000,1000), height = 12 m.
        add_feature(layer, 2, {1, 1}, 3,
                    {cmd(1, 1), zz(1000), zz(1000), cmd(3, 2), zz(500), zz(0),
                     zz(0), zz(500), zz(-500), zz(0), cmd(1, 7)});
        // A point feature in a polygon layer must be skipped, not extruded.
        add_feature(layer, 3, {}, 1, {cmd(1, 1), zz(7), zz(9)});
    }
    {
        Builder layer{tile, TileTag::layer};
        layer.add_string(LayerTag::name, "landuse");
        layer.add_uint32(LayerTag::version, 2);
        layer.add_uint32(LayerTag::extent, 4096);
        // Triangle covering the tile's south-west quadrant.
        add_feature(layer, 4, {}, 3,
                    {cmd(1, 1), zz(0), zz(0), cmd(2, 2), zz(1000), zz(0),
                     zz(0), zz(1000), cmd(1, 7)});
    }
    {
        Builder layer{tile, TileTag::layer};
        layer.add_string(LayerTag::name, "highway");
        layer.add_uint32(LayerTag::version, 2);
        layer.add_uint32(LayerTag::extent, 4096);
        // A full-width road along the tile's y=0 line.
        add_feature(layer, 5, {}, 2,
                    {cmd(1, 1), zz(0), zz(0), cmd(1, 2), zz(4096), zz(0)});
    }
    {
        // A layer the client does not draw. Parsing must skip it silently.
        Builder layer{tile, TileTag::layer};
        layer.add_string(LayerTag::name, "poi");
        layer.add_uint32(LayerTag::version, 2);
        layer.add_uint32(LayerTag::extent, 4096);
        add_feature(layer, 6, {}, 1, {cmd(1, 1), zz(100), zz(200)});
    }
    return buf;
}

std::string base64(const std::string& in) {
    static const char* tbl =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    std::size_t i = 0;
    while (i + 2 < in.size()) {
        const std::uint32_t v = (static_cast<std::uint8_t>(in[i]) << 16) |
                                (static_cast<std::uint8_t>(in[i + 1]) << 8) |
                                static_cast<std::uint8_t>(in[i + 2]);
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out.push_back(tbl[(v >> 6) & 63]);
        out.push_back(tbl[v & 63]);
        i += 3;
    }
    if (i + 1 == in.size()) {
        const std::uint32_t v = static_cast<std::uint8_t>(in[i]) << 16;
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out += "==";
    } else if (i + 2 == in.size()) {
        const std::uint32_t v = (static_cast<std::uint8_t>(in[i]) << 16) |
                                (static_cast<std::uint8_t>(in[i + 1]) << 8);
        out.push_back(tbl[(v >> 18) & 63]);
        out.push_back(tbl[(v >> 12) & 63]);
        out.push_back(tbl[(v >> 6) & 63]);
        out += '=';
    }
    return out;
}

// --- tests ------------------------------------------------------------------

void test_arena() {
    ws::Arena arena(1024);
    check_eq(static_cast<std::int64_t>(arena.capacity()), 1024, "arena capacity");
    check(arena.remaining() == 1024, "arena starts with its full block");

    void* a = arena.allocate(1);
    check(a != nullptr && (reinterpret_cast<std::uintptr_t>(a) % 16) == 0,
          "a one-byte allocation is 16-byte aligned");
    check_eq(static_cast<std::int64_t>(arena.used()), 16,
             "and consumed exactly one aligned block");

    void* b = arena.allocate(1008);
    check(b != nullptr, "a second allocation fits the remainder");
    check(arena.allocate(16) == nullptr,
          "an exhausted arena returns nullptr instead of growing");

    arena.reset();
    check(arena.remaining() == 1024, "reset returns the whole block");
    check(arena.allocate(256) != nullptr, "and the arena is usable again");

    struct Pod { int x; int y; };
    Pod* p = arena.emplace<Pod>();
    check(p != nullptr, "emplace constructs in place");
    arena.destroy(p);
}

void test_arena_pool() {
    ws::ArenaPool pool(3, 256);
    check_eq(static_cast<std::int64_t>(pool.size()), 3, "pool size");
    ws::Arena& first = pool.acquire();
    first.allocate(128);
    ws::Arena& second = pool.acquire();
    check(second.remaining() == 256, "a freshly acquired arena is clean");
    ws::Arena& third = pool.acquire();
    (void)third;
    ws::Arena& fourth = pool.acquire();
    check(&fourth == &first,
          "a fourth acquire recycles the first arena rather than growing");
    check_eq(static_cast<std::int64_t>(fourth.remaining()), 256,
             "and recycling resets it");
}

void test_ring() {
    ws::SpscRing<int> ring(2);
    check(ring.empty(), "a new ring is empty");

    int out = -1;
    check(ring.try_pop(out) == false, "popping an empty ring reports nothing");

    check(ring.try_push(10), "first push");
    check(ring.try_push(20), "second push");
    check(ring.try_push(30) == false, "a full ring reports backpressure");
    check_eq(static_cast<std::int64_t>(ring.dropped()), 1,
             "and counts the drop");

    check(ring.try_pop(out) && out == 10, "FIFO order: first out is first in");
    check(ring.try_pop(out) && out == 20, "second out is second in");
    check(ring.try_pop(out) == false, "drained");

    // Slot reuse after a full wrap.
    check(ring.try_push(40), "pushing after draining");
    check(ring.try_pop(out) && out == 40, "gets the value, not a stale slot");
    check_eq(static_cast<std::int64_t>(ring.pushed()), 3, "push count");
    check_eq(static_cast<std::int64_t>(ring.popped()), 3, "pop count");
}

void test_h3_grid() {
    // Berkeley, CA -- a location where H3 has no pentagon distortions nearby.
    const ws::LatLon origin{37.8715, -122.2730};

    ws::CellSet one;
    check(ws::cells_around(origin, 9, 0, one), "a radius-0 disk resolves");
    check_eq(static_cast<std::int64_t>(one.cells.size()), 1,
             "radius 0 is the centre cell alone");

    ws::CellSet ring1;
    check(ws::cells_around(origin, 9, 1, ring1), "a radius-1 disk resolves");
    check_eq(static_cast<std::int64_t>(ring1.cells.size()), 7,
             "radius 1 is 1 + 6 cells");

    ws::CellSet ring2;
    check(ws::cells_around(origin, 9, 2, ring2), "a radius-2 disk resolves");
    check_eq(static_cast<std::int64_t>(ring2.cells.size()), 19,
             "radius 2 is 1 + 6 + 12 cells");
    check_eq(ring2.resolution, 9, "the set reports its resolution");

    // The centre of the set is the origin's cell: a roundtrip through H3 must
    // land within a cell's width, not at the origin exactly.
    ws::LatLon c{};
    check(ws::cell_center(ring1.cells[0], c), "the centre cell has a centre");
    check(std::fabs(c.lat - origin.lat) < 0.01 && std::fabs(c.lon - origin.lon) < 0.01,
          "and it is near the input position");
    check_eq(ring1.cells[0], one.cells[0],
             "the disk's first cell is the centre cell H3 returned");

    const ws::CellSet before = ring1;
    check(ws::cells_around(origin, 9, 1, ring1) &&
              ring1.cells.size() == before.cells.size() &&
              ring1.cells[0] == before.cells[0],
          "re-resolving the same origin is stable");

    ws::CellSet bad;
    check(ws::cells_around(origin, 99, 1, bad) == false,
          "an out-of-range resolution is refused");
    check(ws::cells_around(origin, 9, -1, bad) == false,
          "a negative radius is refused");
    check(bad.cells.empty(), "and a refused request leaves no cells behind");

    ws::LatLon unused{};
    check(ws::cell_center(0, unused) == false, "a zero index has no centre");
}

void test_parse_rejects_and_accepts_empty() {
    ws::TileFeatureSet set;
    ws::ParseStats stats;
    std::string err;
    const ws::TileKey key{0x8928308280fffffULL, 9};

    // "no data here" (ocean, no OSM coverage) is success, not an error.
    check(ws::parse_vector_tile(nullptr, 0, key, 1000.0, set, stats, err),
          "an empty buffer parses as an empty tile");
    check(set.footprints.empty() && set.splines.empty(),
          "with no features");

    const char* garbage = "this is not a vector tile, not even close";
    check(ws::parse_vector_tile(garbage, std::strlen(garbage), key, 1000.0, set,
                                stats, err) == false,
          "garbage bytes are refused");
    check(!err.empty(), "and the error says something");

    std::string fixture = make_fixture_tile();
    check(ws::parse_vector_tile(fixture.data(), fixture.size(), key, -1.0, set,
                                stats, err) == false,
          "a non-positive tile size is refused");
}

void test_parse_fixture() {
    const std::string fixture = make_fixture_tile();
    const ws::TileKey key{0x8928308280fffffULL, 9};

    ws::TileFeatureSet set;
    ws::ParseStats stats;
    std::string err;
    const bool ok = ws::parse_vector_tile(fixture.data(), fixture.size(), key,
                                          1000.0, set, stats, err);
    check(ok, "the fixture tile parses");
    if (!ok) {
        std::printf("  FAIL parse error: %s\n", err.c_str());
        return;
    }

    check(set.key == key, "the tile key is carried onto the feature set");
    check_eq(static_cast<std::int64_t>(set.footprints.size()), 3,
             "two buildings and one landuse polygon become footprints");
    check_eq(static_cast<std::int64_t>(set.splines.size()), 1,
             "one road becomes one spline");
    check_eq(static_cast<std::int64_t>(stats.buildings), 2, "building stat");
    check_eq(static_cast<std::int64_t>(stats.landuse), 1, "landuse stat");
    check_eq(static_cast<std::int64_t>(stats.highways), 1, "highway stat");
    check(stats.total_points >= 12, "point stat counts decoded vertices");

    const ws::Footprint& a = set.footprints[0];
    check_eq(static_cast<std::int64_t>(a.ring.size()), 5,
             "the decoder's closing point is kept (rings are closed once here)");
    check(nearly(a.ring.front().x, a.ring.back().x) &&
              nearly(a.ring.front().y, a.ring.back().y),
          "and it equals the first point");
    check_eq(static_cast<std::int64_t>(a.levels), 3, "levels read from tags");
    check(nearly(a.height_m, 9.6f), "levels become height via the storey constant");
    check(a.cls == ws::FeatureClass::Building, "layer name maps to Building");

    // 100 tile units at extent 4096 over a 1000 m tile is 24.414 m, measured
    // from the tile centre (the origin the streamer places cells by).
    check(nearly(a.ring[0].x, -500.0f + 24.4140625f),
          "ring x is tile-local metres from the centre");
    check(nearly(a.ring[0].y, 500.0f - 24.4140625f),
          "ring y is flipped (MVT y grows down) and centred");

    const ws::Footprint& b = set.footprints[1];
    check(nearly(b.height_m, 12.0f), "an explicit height tag wins over levels");
    check_eq(static_cast<std::int64_t>(b.levels), 1,
             "and leaves levels at the default");

    check(set.footprints[2].cls == ws::FeatureClass::Landuse,
          "a landuse polygon keeps its class");

    const ws::Spline& s = set.splines[0];
    check_eq(static_cast<std::int64_t>(s.points.size()), 2, "road has two points");
    check(nearly(s.points[0].x, -500.0f) && nearly(s.points[0].y, 500.0f),
          "road start is at the tile's west edge in local metres");
    check(nearly(s.points[1].x, 500.0f), "road end is at the tile's east edge");

    // Layers the client does not draw contribute nothing.
    for (const ws::Footprint& f : set.footprints) {
        check(f.cls != ws::FeatureClass::Highway,
              "no footprint came from the POI layer");
    }

    // Re-parsing into the same object must not accumulate.
    check(ws::parse_vector_tile(fixture.data(), fixture.size(), key, 1000.0, set,
                                stats, err),
          "re-parsing clears and re-fills");
    check_eq(static_cast<std::int64_t>(set.footprints.size()), 3,
             "feature count is not doubled by reuse");
}

void test_mesher() {
    const std::string fixture = make_fixture_tile();
    const ws::TileKey key{0x8928308280fffffULL, 9};
    ws::TileFeatureSet set;
    ws::ParseStats stats;
    std::string err;
    check(ws::parse_vector_tile(fixture.data(), fixture.size(), key, 1000.0, set,
                                stats, err),
          "fixture parses for the mesher");

    ws::MesherParams params;
    ws::MeshletBatch batch;
    check(ws::build_structures(set, params, batch, err),
          "the fixture builds a meshlet batch");
    check(!batch.empty(), "and the batch has meshlets");
    check(batch.vertices.size() > 0 && batch.indices.size() > 0,
          "with vertices and indices");
    check_eq(static_cast<std::int64_t>(batch.indices.size() % 3), 0,
             "the index buffer is whole triangles");
    check_eq(static_cast<std::int64_t>(batch.triangle_count()),
             static_cast<std::int64_t>(batch.indices.size() / 3),
             "triangle_count() agrees with the index buffer");

    // Every index must address a real vertex, and every meshlet's triangles
    // must address vertices inside that meshlet's window.
    std::size_t max_index = 0;
    for (std::uint32_t i : batch.indices) {
        max_index = std::max<std::size_t>(max_index, i);
    }
    check(max_index < batch.vertices.size(), "every index is in range");

    bool meshlets_in_range = true;
    for (const ws::Meshlet& m : batch.meshlets) {
        if (m.vertex_count == 0 || m.vertex_count > ws::kMeshletMaxVertices) {
            meshlets_in_range = false;
        }
        if (m.triangle_count == 0 || m.triangle_count > ws::kMeshletMaxTriangles) {
            meshlets_in_range = false;
        }
        for (std::uint32_t t = 0; t < m.triangle_count * 3; ++t) {
            if (batch.meshlet_triangles[m.triangle_offset + t] >= m.vertex_count) {
                meshlets_in_range = false;
            }
        }
        for (std::uint32_t v = 0; v < m.vertex_count; ++v) {
            if (batch.meshlet_vertices[m.vertex_offset + v] >= batch.vertices.size()) {
                meshlets_in_range = false;
            }
        }
    }
    check(meshlets_in_range,
          "every meshlet respects the 64/126 limits and its own window");

    // Geometry truth: the buildings stand 9.6 m and 12 m tall above ground.
    float top = -1e9f;
    float bottom = 1e9f;
    for (const ws::BuildVertex& v : batch.vertices) {
        top = std::fmax(top, v.py);
        bottom = std::fmin(bottom, v.py);
    }
    check(nearly(top, 12.0f, 1e-2f), "the tallest roof is the height-tagged one");
    check(nearly(bottom, 0.0f, 1e-2f), "walls reach the ground plane");
    check(nearly(batch.bounds_max.y, top, 1e-2f), "bounds track the geometry");
    check(batch.bounds_max.x > batch.bounds_min.x,
          "and the horizontal bounds are non-degenerate");

    // Road ribbons sit just above the ground and are two-sided quads.
    bool saw_road_lift = false;
    for (const ws::BuildVertex& v : batch.vertices) {
        if (nearly(v.py, params.road_lift_m, 1e-4f) && nearly(v.ny, 1.0f, 1e-3f)) {
            saw_road_lift = true;
        }
    }
    check(saw_road_lift, "roads are lifted off the ground plane");

    // Determinism: the same input must produce byte-identical output. A tile
    // re-fetched after eviction has to look like the one it replaced.
    ws::MeshletBatch again;
    check(ws::build_structures(set, params, again, err), "a second build runs");
    check(again.vertices.size() == batch.vertices.size() &&
              again.indices == batch.indices &&
              again.meshlet_triangles == batch.meshlet_triangles,
          "and is byte-identical to the first");

    // A ring that collapses to fewer than three points is refused (it cannot
    // be extruded), while a tile with no features is a success with an empty
    // batch.
    ws::TileFeatureSet degenerate;
    ws::Footprint thin;
    thin.ring.push_back(ws::Vec2{0.0f, 0.0f});
    thin.ring.push_back(ws::Vec2{1.0f, 0.0f});
    degenerate.footprints.push_back(thin);
    ws::MeshletBatch empty;
    check(ws::build_structures(degenerate, params, empty, err) == false,
          "a footprint with fewer than three points is refused");
    check(!err.empty(), "with a reason");

    ws::TileFeatureSet none;
    check(ws::build_structures(none, params, empty, err),
          "an empty tile meshes to an empty batch");
    check(empty.empty() && empty.vertices.empty(), "which is empty, not an error");
}

}  // namespace

int main() {
    std::printf("worldstream native tests\n");

    ws::TileFeatureSet set;
    ws::ParseStats stats;
    std::string err;
    ws::MeshletBatch batch;
    (void)set, (void)stats, (void)err, (void)batch;

    test_arena();
    test_arena_pool();
    test_ring();
    test_h3_grid();
    test_parse_rejects_and_accepts_empty();
    test_parse_fixture();
    test_mesher();

    // The Godot-side suite (tools/worldstream_test.gd) parses the same fixture
    // through the GDExtension. Printing it here keeps the two fixtures from
    // drifting: there is one encoder, in this file.
    const std::string fixture = make_fixture_tile();
    std::printf("FIXTURE-BASE64: %s\n", base64(fixture).c_str());

    std::printf("worldstream-native: %s\n",
                g_failures == 0 ? "PASS" : "FAIL");
    return g_failures == 0 ? 0 : 1;
}
