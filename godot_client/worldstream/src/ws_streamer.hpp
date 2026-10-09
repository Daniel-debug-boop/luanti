#pragma once

// Module 1: geospatial streaming and zero-copy vector-tile parsing.
//
// Turns a lat/lon into H3 cells, and H3 cells into parsed building/highway/
// landuse features. The vtzero parse is zero-copy in the sense that matters:
// the tile buffer is owned by the caller and every geometry point is read into
// a pre-sized, pre-reserved output vector. No temporary std::string, no
// per-feature allocation, no map lookups keyed by string.

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "ws_arena.hpp"
#include "ws_types.hpp"

namespace ws {

// --- H3 grid ----------------------------------------------------------------

// Resolutions 8-10 give cells roughly 460 m / 174 m / 66 m across, which is the
// right range for city-block streaming: small enough that a player sees detail
// before arriving, large enough that a resident city is a few hundred cells.
constexpr int kMinStreamingResolution = 8;
constexpr int kMaxStreamingResolution = 10;

struct LatLon {
    double lat = 0.0;  // degrees
    double lon = 0.0;  // degrees
};

// The H3 cells that should be resident around a position: the centre cell plus
// `radius` rings, at one resolution.
struct CellSet {
    std::vector<std::uint64_t> cells;
    int resolution = kMaxStreamingResolution;
};

// Maps a position onto the H3 grid and returns the cell plus its `radius`-ring
// neighbourhood. Returns false if H3 rejected the input (invalid resolution, or
// a position that does not project onto a valid cell).
bool cells_around(LatLon origin, int resolution, int radius, CellSet& out);

// Cell centroid, for placing a tile's local origin in world space.
bool cell_center(std::uint64_t index, LatLon& out);

// --- tile fetching ----------------------------------------------------------

// Supplies the raw bytes of a vector tile. Returning an empty buffer means "no
// data here" (ocean, no OSM coverage) and is not an error.
//
// This is an interface rather than a baked-in HTTP client so the tile source can
// be a local file cache, an in-memory test fixture, or a network fetcher, and
// so Module 1 can be tested with no I/O at all.
class TileSource {
public:
    virtual ~TileSource() = default;
    virtual bool fetch(const std::uint64_t cell, std::string& out_buffer) = 0;
};

// --- parsing ----------------------------------------------------------------

struct ParseStats {
    std::size_t buildings = 0;
    std::size_t highways = 0;
    std::size_t landuse = 0;
    std::size_t total_points = 0;
};

// Parses a Mapbox Vector Tile into `out`.
//
// `scale` converts tile integer units to metres: OSM vector tiles are defined
// at extent 4096 over a tile of `tile_size_m` metres, so scale = tile_size_m /
// 4096.
//
// `out` is cleared and its vectors are re-used (capacity retained) across
// calls, which is what keeps steady-state parsing allocation-free.
//
// Returns false and fills `error` when the buffer is not a valid vector tile.
bool parse_vector_tile(const void* data,
                       std::size_t size,
                       const TileKey& key,
                       double tile_size_m,
                       TileFeatureSet& out,
                       ParseStats& stats,
                       std::string& error);

}  // namespace ws