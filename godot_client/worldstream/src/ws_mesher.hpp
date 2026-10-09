#pragma once

// Module 2: geometry synthesis.
//
// Turns a parsed TileFeatureSet into one GPU-ready MeshletBatch. The pipeline
// per structure is the same one a modern renderer uses:
//
//   footprint polygon --earcut--> roof + walls (triangles)
//   spline polyline   --ribbon--> road quads
//   all triangles     --meshopt--> vertex-cache order, vertex-fetch order,
//                                  64/126 meshlets with normal cones
//
// Everything here is deterministic: the same TileFeatureSet in always
// produces byte-identical batch out. That is a test requirement (the unit
// suite compares batches) and a streaming requirement (a tile re-fetched
// after eviction must not visibly differ from the one it replaces).

#include <string>

#include "ws_types.hpp"

namespace ws {

struct MesherParams {
    // Half-width of a road ribbon, metres. Spline carries no width tag yet,
    // so one width is applied to every road in the tile.
    float road_width_m = 3.0f;
    // Lift of road ribbons above the ground plane, metres. Roads and building
    // bases share y=0; without the lift the two coplanar surfaces z-fight.
    float road_lift_m = 0.05f;
};

// Extrudes every footprint into a closed prism and every spline into a ground
// ribbon, then meshes the whole tile as one batch. `out` is cleared and its
// vectors re-used (capacity retained), like TileFeatureSet in parse.
//
// Returns false and fills `error` only when `set` contains a feature that
// cannot be meshed at all (a ring with fewer than 3 points after welding); an
// empty tile is success with an empty batch, because "no data here" is not a
// failure anywhere else in the pipeline either.
bool build_structures(const TileFeatureSet& set,
                      const MesherParams& params,
                      MeshletBatch& out,
                      std::string& error);

}  // namespace ws
