// Module 1 implementation: H3 grid math and vector-tile parsing.
//
// The parsing stage is "zero-copy" where it matters: the caller owns the tile
// buffer, no std::string is built per feature, and `out`'s vectors are re-used
// across calls. Two allocations per feature remain (the ring and its holes)
// because footprints outlive the parse; they are re-used through the same
// `out` object on the next tile, which is what keeps the steady state cheap.

#include "ws_streamer.hpp"

#include <h3api.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string_view>

#include <protozero/data_view.hpp>
#include <protozero/pbf_message.hpp>
#include <vtzero/exception.hpp>
#include <vtzero/feature.hpp>
#include <vtzero/geometry.hpp>
#include <vtzero/layer.hpp>
#include <vtzero/property.hpp>
#include <vtzero/property_value.hpp>
#include <vtzero/types.hpp>
#include <vtzero/vector_tile.hpp>

namespace ws {

// --- H3 grid ----------------------------------------------------------------

bool cells_around(LatLon origin, int resolution, int radius, CellSet& out) {
    out.cells.clear();
    out.resolution = resolution;

    if (resolution < 0 || resolution > 15 || radius < 0) {
        return false;
    }
    if (!std::isfinite(origin.lat) || !std::isfinite(origin.lon)) {
        return false;
    }

    // H3's LatLng is in radians; LatLon here is in degrees (the JSON/OSM
    // convention everything upstream speaks). Converting at the boundary is
    // the only place the two units meet.
    const LatLng ll{degsToRads(origin.lat), degsToRads(origin.lon)};
    H3Index center = 0;
    if (latLngToCell(&ll, resolution, &center) != E_SUCCESS || center == 0) {
        return false;
    }

    int64_t max_size = 0;
    if (maxGridDiskSize(radius, &max_size) != E_SUCCESS || max_size <= 0) {
        return false;
    }

    std::vector<H3Index> disk(static_cast<std::size_t>(max_size), 0);
    if (gridDisk(center, radius, disk.data()) != E_SUCCESS) {
        return false;
    }

    // gridDisk pads with zeros for pentagon distortion gaps; those are not
    // cells, and shipping them would make the resident set contain indexes
    // that no tile will ever be fetched for.
    out.cells.reserve(disk.size());
    for (H3Index c : disk) {
        if (c != 0) {
            out.cells.push_back(static_cast<std::uint64_t>(c));
        }
    }
    return true;
}

bool cell_center(std::uint64_t index, LatLon& out) {
    const H3Index h = static_cast<H3Index>(index);
    // cellToLatLng happily answers for index 0, so the index is validated
    // first: a caller asking for the centre of "no cell" must get a refusal,
    // not the centre of the ocean off Null Island.
    // isValidCell is one of H3's legacy int-returning predicates: 1 is valid,
    // 0 is not (unlike the H3Error-returning calls, where 0 means success).
    if (h == 0 || isValidCell(h) == 0) {
        return false;
    }
    LatLng ll{};
    if (cellToLatLng(h, &ll) != E_SUCCESS) {
        return false;
    }
    out.lat = radsToDegs(ll.lat);
    out.lon = radsToDegs(ll.lng);  // H3 names the longitude field lng
    return true;
}

// --- parsing ----------------------------------------------------------------

namespace {

// vtzero hands out data_view (pointer + length); everything here works on
// string_view, so this is the one conversion point.
std::string_view to_view(const protozero::data_view& v) {
    return std::string_view(v.data(), v.size());
}

// FeatureClass for a layer name. Returns -1 for layers this client does not
// render. Matching is exact on the OSM layer names that actually carry the
// geometry we stream; a fuzzy contains() would pull in "building_part" and
// "landuse" overlays that duplicate what we already have.
int class_for_layer(std::string_view name) {
    if (name == "building" || name == "buildings") {
        return static_cast<int>(FeatureClass::Building);
    }
    if (name == "landuse" || name == "park" || name == "wood" ||
        name == "water") {
        return static_cast<int>(FeatureClass::Landuse);
    }
    if (name == "highway" || name == "roads" || name == "transportation") {
        return static_cast<int>(FeatureClass::Highway);
    }
    return -1;
}

// Parse "12", "12.5", "12 m" -- OSM height tags are human-written strings.
// Returns false when the value does not start with a number, which is the
// common case for "yes"/"roof" style tags and must not become height 0.
bool parse_metres(std::string_view text, float& out) {
    char* end = nullptr;
    const std::string tmp(text);  // strtof needs NUL termination
    const float v = std::strtof(tmp.c_str(), &end);
    if (end == tmp.c_str() || !std::isfinite(v) || v < 0.0f || v > 1000.0f) {
        return false;
    }
    out = v;
    return true;
}

// Average floor-to-floor height used when a building gives levels but no
// absolute height. 3.2 m is the usual commercial-storey assumption; it is a
// constant rather than a per-feature value because the error it introduces is
// dwarfed by the error already in the source data.
constexpr float kLevelHeightM = 3.2f;

// vtzero reports polygon rings with a signed area. The MVT spec fixes outer
// rings to one winding and holes to the other; vtzero's ring_type classifier
// encodes exactly that, but taking the raw int64 lets us keep one handler
// signature without pulling in its enum. Positive sum = outer ring.
bool is_outer_ring(std::int64_t area_sum) {
    return area_sum > 0;
}

// Geometry handler that turns decoded tile coordinates into tile-local
// metres. MVT y grows downward; the world's z grows "north", so y is negated.
struct FeatureHandler {
    TileFeatureSet* set = nullptr;
    ParseStats* stats = nullptr;
    double scale = 0.0;   // metres per tile unit
    float half = 0.0f;    // half the tile size, the local origin

    // Reused per feature; moved out on completion.
    std::vector<Vec2> ring;
    std::vector<std::vector<Vec2>> holes;
    std::vector<Vec2> line;
    FeatureClass cls = FeatureClass::Building;
    float height_m = 3.0f;
    std::uint16_t levels = 1;

    void reset_geometry() {
        ring.clear();
        holes.clear();
        line.clear();
    }

    // Tile-local metres, centred on the tile: the streamer places a tile by
    // its cell centroid, so (0, 0) has to be that centroid and not a corner.
    // MVT y grows downward while the world's z grows north, so y is flipped.
    Vec2 to_m(vtzero::point p) const {
        return Vec2{static_cast<float>(p.x * scale) - half,
                    half - static_cast<float>(p.y * scale)};
    }

    // Polygon rings. First ring closes the footprint; later rings with the
    // opposite winding become its holes.
    void ring_begin(std::uint32_t /*count*/) { ring.clear(); }
    void ring_point(vtzero::point p) {
        ring.push_back(to_m(p));
        if (stats != nullptr) {
            ++stats->total_points;
        }
    }
    void ring_end(std::int64_t area) {
        if (is_outer_ring(area)) {
            if (ring.size() >= 3) {
                Footprint f;
                f.cls = cls;
                f.ring = std::move(ring);
                f.holes = std::move(holes);
                f.height_m = height_m;
                f.levels = levels;
                set->footprints.push_back(std::move(f));
            }
            ring.clear();
            holes.clear();
        } else {
            if (!ring.empty()) {
                holes.push_back(std::move(ring));
                ring.clear();
            }
        }
    }

    // Linestrings become road splines.
    void linestring_begin(std::uint32_t /*count*/) { line.clear(); }
    void linestring_point(vtzero::point p) {
        line.push_back(to_m(p));
        if (stats != nullptr) {
            ++stats->total_points;
        }
    }
    void linestring_end() {
        if (line.size() >= 2) {
            Spline s;
            s.points = std::move(line);
            set->splines.push_back(std::move(s));
        }
        line.clear();
    }

    // Points (tree icons, addresses) carry no geometry this client draws.
    void points_begin(std::uint32_t) {}
    void points_point(vtzero::point) {}
    void points_end() {}
};

// Pull the height a footprint should be extruded to. `height` tag wins over
// `building:levels` because an absolute height is measured, while levels are
// multiplied by a constant.
void resolve_height(vtzero::feature& feature, float& height_m,
                    std::uint16_t& levels) {
    height_m = 3.0f;
    levels = 1;

    // next_property() is a mutable pull iterator, hence the non-const feature.
    vtzero::property prop = feature.next_property();
    while (prop.valid()) {
        const std::string_view key = to_view(prop.key());
        if (key == "height" || key == "building:height") {
            float v = 0.0f;
            if (parse_metres(to_view(prop.value().string_value()), v)) {
                height_m = v;
            }
        } else if (key == "building:levels") {
            float v = 0.0f;
            if (parse_metres(to_view(prop.value().string_value()), v) &&
                v >= 1.0f && v <= 200.0f) {
                levels = static_cast<std::uint16_t>(v + 0.5f);
            }
        }
        prop = feature.next_property();
    }

    if (height_m == 3.0f && levels > 1) {
        height_m = static_cast<float>(levels) * kLevelHeightM;
    }
}

}  // namespace

bool parse_vector_tile(const void* data,
                       std::size_t size,
                       const TileKey& key,
                       double tile_size_m,
                       TileFeatureSet& out,
                       ParseStats& stats,
                       std::string& error) {
    out.key = key;
    out.footprints.clear();
    out.splines.clear();
    stats = ParseStats{};

    if (data == nullptr || size == 0) {
        // Empty buffer is the documented "no data here" signal, not an error.
        return true;
    }
    if (tile_size_m <= 0.0 || !std::isfinite(tile_size_m)) {
        error = "tile_size_m must be positive";
        return false;
    }

    try {
        vtzero::vector_tile tile{static_cast<const char*>(data), size};

        // vtzero is a pull API: next_layer()/next_feature() until invalid.
        while (auto layer = tile.next_layer()) {
            const int cls = class_for_layer(to_view(layer.name()));
            if (cls < 0) {
                continue;
            }

            const std::uint32_t extent = layer.extent();
            if (extent == 0) {
                continue;  // degenerate layer, nothing to scale by
            }
            const double scale = tile_size_m / static_cast<double>(extent);

            FeatureHandler handler;
            handler.set = &out;
            handler.stats = &stats;
            handler.scale = scale;
            handler.half = static_cast<float>(tile_size_m * 0.5);

            while (auto feature = layer.next_feature()) {
                const bool want_polygons = cls != static_cast<int>(FeatureClass::Highway);
                const bool want_lines = cls == static_cast<int>(FeatureClass::Highway);
                const auto gtype = feature.geometry_type();

                if (want_polygons && gtype == vtzero::GeomType::POLYGON) {
                    handler.cls = static_cast<FeatureClass>(cls);
                    resolve_height(feature, handler.height_m, handler.levels);
                    const std::size_t before = out.footprints.size();
                    vtzero::decode_geometry(feature.geometry(), handler);
                    const std::size_t added = out.footprints.size() - before;
                    if (handler.cls == FeatureClass::Landuse) {
                        stats.landuse += added;
                    } else {
                        stats.buildings += added;
                    }
                } else if (want_lines && gtype == vtzero::GeomType::LINESTRING) {
                    const std::size_t before = out.splines.size();
                    vtzero::decode_geometry(feature.geometry(), handler);
                    stats.highways += out.splines.size() - before;
                }
                // Everything else (points, or a polygon in a line layer) is
                // skipped on purpose: an unusable geometry type is normal in
                // real OSM tiles and must not fail the tile.
            }
        }
    } catch (const vtzero::exception& e) {
        error = std::string("vtzero: ") + e.what();
        return false;
    } catch (const std::exception& e) {
        error = std::string("parse: ") + e.what();
        return false;
    }

    return true;
}

}  // namespace ws
