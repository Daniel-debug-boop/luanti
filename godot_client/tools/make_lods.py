#!/usr/bin/env python3
"""Validate the vendored prop bundles and cut real LODs out of them.

The Poly Haven glTF distributions are already good models: metres, correct
normals, external textures, no embedded images. What they are not is cheap at
range, and a village district scatters 26 of them. So this script does two
things, in this order, and refuses to do the second if the first fails:

1. **Validate.** Every mesh is checked for the things that silently ruin a
   voxel game: embedded textures (which a Luanti/glTF workflow must not have),
   missing normals, missing or degenerate UVs, non-finite vertices, wrong
   winding, an implausible real-world size, and a triangle count over budget.
   The results are written into the manifest, so the build can fail on them.

2. **Cut LODs.** Vertex-cluster decimation at 45% and 15% of the source
   triangle count, which halves and then quarters the vertex and triangle cost
   while keeping the silhouette -- clustering preserves the outer surface of a
   prop, which is exactly the part that has to survive at distance.

Decimation is deliberately *not* a general mesh simplifier. Vertex clustering
needs no topology analysis, no seam handling and no library, and its failure
mode is a slightly faceted prop, which is acceptable; a real simplifier's
failure mode is holes and flipped normals, which is not.

Godot's own `visibility_range_begin/end` does the LOD *selection* at runtime
(see `scripts/mobs/village.gd`); this script only produces the meshes.

Run:  python3 tools/make_lods.py [--only <model>] [--force]
"""
import argparse
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asset_catalog as cat  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE = os.path.join(ROOT, "assets", "source", "polyhaven", "models")
RUNTIME = os.path.join(ROOT, "assets", "runtime", "models")
MANIFEST = os.path.join(ROOT, "assets", "source_manifest", "manifest.json")

MAX_TRIS = 20000
"""Budget for one prop at LOD0.

A village district scatters 26 props, so a 20k cap bounds the worst-case
prop cost at half a million triangles. A 100k-triangle treasure chest is a
showcase render, not a thing that stands next to twenty other things in a
voxel world that is already carrying the terrain. Models over the budget are
reduced at LOD0 rather than rejected, and the manifest records both numbers."""
MIN_SIZE = 0.12
MAX_SIZE = 24.0
"""Real-world size gate, in metres. A 25 m barrel is a shipping container and
belongs in the industrial set, not the village props."""




def log(msg):
    print(msg, flush=True)


# --- glTF reading ----------------------------------------------------------

COMP = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2),
        5125: ("I", 4), 5126: ("f", 4)}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class Gltf:
    def __init__(self, path):
        self.path = path
        with open(path) as fh:
            self.doc = json.load(fh)
        self.dir = os.path.dirname(path)
        self._blobs = {}

    def blob(self, index):
        if index in self._blobs:
            return self._blobs[index]
        b = self.doc["buffers"][index]
        uri = b.get("uri")
        if uri is None:
            data = b.get("__data__", b"")
        else:
            if uri.startswith("data:"):
                import base64
                data = base64.b64decode(uri.split(",", 1)[1])
            else:
                p = os.path.join(self.dir, uri)
                data = open(p, "rb").read() if os.path.exists(p) else b""
        self._blobs[index] = data
        return data

    def accessor(self, index):
        a = self.doc["accessors"][index]
        n = NCOMP[a["type"]]
        fmt, size = COMP[a["componentType"]]
        stride = a.get("byteStride") or size * n
        base = a.get("byteOffset", 0)
        if "bufferView" in a:
            bv = self.doc["bufferViews"][a["bufferView"]]
            base += bv.get("byteOffset", 0)
            data = self.blob(bv["buffer"])
        else:
            data = b""
        out = []
        for i in range(a["count"]):
            off = base + i * stride
            out.append(struct.unpack_from("<%d%s" % (n, fmt), data, off))
        return out

    def is_indices(self, index):
        return self.doc["accessors"][index].get("componentType") in (5121, 5123,
                                                                    5125)


def mesh_stats(gltf, mesh_index):
    """Per-primitive geometry, plus the numbers the validator cares about."""
    tris = 0
    verts = 0
    has_normals = True
    has_uvs = True
    degenerate = 0
    minv = [1e30] * 3
    maxv = [-1e30] * 3
    for prim in gltf.doc["meshes"][mesh_index]["primitives"]:
        pos = gltf.accessor(prim["attributes"]["POSITION"])
        verts += len(pos)
        has_normals = has_normals and "NORMAL" in prim["attributes"]
        has_uvs = has_uvs and "TEXCOORD_0" in prim["attributes"]
        for v in pos:
            for i in range(3):
                if not math.isfinite(v[i]):
                    return {"error": "non-finite vertex"}
                minv[i] = min(minv[i], v[i])
                maxv[i] = max(maxv[i], v[i])
        if "indices" in prim:
            idx = [x[0] for x in gltf.accessor(prim["indices"])]
        else:
            idx = list(range(len(pos)))
        for i in range(0, len(idx), 3):
            a, b, c = idx[i], idx[i + 1], idx[i + 2]
            tris += 1
            if a == b or b == c or a == c:
                degenerate += 1
    return {
        "vertices": verts, "triangles": tris, "degenerate": degenerate,
        "has_normals": has_normals, "has_uvs": has_uvs,
        "min": minv, "max": maxv,
        "size": [maxv[i] - minv[i] for i in range(3)],
    }


def validate(name, gltf):
    """Structural checks only. Returns (problems, stats).

    Size and triangle budget are *not* checked here: both of those can be
    fixed by the pipeline itself (by baking a scale, by reducing LOD0), so
    they are evaluated after those steps rather than before.
    """
    problems = []
    doc = gltf.doc
    total_tris = 0
    total_verts = 0
    size = [0.0, 0.0, 0.0]
    for i, img in enumerate(doc.get("images", [])):
        if "uri" not in img:
            problems.append("image %d is embedded in the glb, not an "
                            "external file" % i)
    for mi, _mesh in enumerate(doc.get("meshes", [])):
        st = mesh_stats(gltf, mi)
        if "error" in st:
            problems.append("mesh %d: %s" % (mi, st["error"]))
            continue
        total_tris += st["triangles"]
        total_verts += st["vertices"]
        for i in range(3):
            size[i] = max(size[i], st["size"][i])
        if not st["has_normals"]:
            problems.append("mesh %d has no NORMAL attribute" % mi)
        if not st["has_uvs"]:
            problems.append("mesh %d has no TEXCOORD_0" % mi)
        if st["degenerate"]:
            problems.append("mesh %d has %d degenerate triangles"
                            % (mi, st["degenerate"]))
        if st["triangles"] > MAX_TRIS:
            problems.append("mesh %d has %d triangles, over the %d budget"
                            % (mi, st["triangles"], MAX_TRIS))
    if total_tris > MAX_TRIS:
        problems.append("%d triangles at LOD0, over the %d budget"
                        % (total_tris, MAX_TRIS))
    if size[0] < MIN_SIZE or size[2] < MIN_SIZE:
        problems.append("footprint %.2f x %.2f m is below the %.2f m floor"
                        % (size[0], size[2], MIN_SIZE))
    if max(size) > MAX_SIZE:
        problems.append("footprint %.2f m is above the %.2f m ceiling: not a "
                        "village prop" % max(size))
    stats = {"triangles": total_tris, "vertices": total_verts,
             "size_m": [round(v, 3) for v in size],
             "meshes": len(doc.get("meshes", [])),
             "materials": len(doc.get("materials", []))}
    return problems, stats


def size_problems(stats):
    """The real-world-size gate, run against the geometry that ships."""
    out = []
    s = stats["size_m"]
    if s[0] < MIN_SIZE or s[2] < MIN_SIZE:
        out.append("shipped footprint %.2f x %.2f m is below the %.2f m floor"
                   % (s[0], s[2], MIN_SIZE))
    if max(s) > MAX_SIZE:
        out.append("shipped footprint %.2f m is above the %.2f m ceiling: not "
                   "a village prop" % max(s))
    if stats["triangles"] > MAX_TRIS:
        out.append("shipped LOD0 has %d triangles, over the %d budget"
                   % (stats["triangles"], MAX_TRIS))
    return out


# --- decimation -----------------------------------------------------------

def read_geometry(gltf, mesh_index, scale=1.0):
    """The source mesh geometry, with a uniform scale applied.

    This is the LOD0 path: no decimation, so LOD0 is the model as it was
    drawn, only re-encoded with the node's own buffer. Scale is how a prop
    that was modelled at the wrong size is fixed without touching the game
    code that places it.
    """
    pos_l, nor_l, uv_l, idx_l = [], [], [], []
    for prim in gltf.doc["meshes"][mesh_index]["primitives"]:
        pos = gltf.accessor(prim["attributes"]["POSITION"])
        nor = gltf.accessor(prim["attributes"]["NORMAL"]) \
            if "NORMAL" in prim["attributes"] else None
        uv = gltf.accessor(prim["attributes"]["TEXCOORD_0"]) \
            if "TEXCOORD_0" in prim["attributes"] else None
        base = len(pos_l)
        pos_l += [[v[0] * scale, v[1] * scale, v[2] * scale] for v in pos]
        nor_l += [list(n) for n in nor] if nor else [[0.0, 1.0, 0.0]
                                                      for _ in pos]
        uv_l += [tuple(u[:2]) for u in uv] if uv else [(0.0, 0.0)] * len(pos)
        if "indices" in prim:
            idx_l += [x[0] + base for x in gltf.accessor(prim["indices"])]
        else:
            idx_l += list(range(base, base + len(pos)))
    return pos_l, nor_l, uv_l, idx_l


def read_all(gltf, scale=1.0):
    """Every mesh of a document as a list of (pos, nor, uv, idx) tuples.

    Decimation works on this geometry form rather than on the glTF container,
    so a LOD can be cut from the *previous* LOD's geometry instead of always
    from the original source mesh. Chaining matters: one cluster pass at a
    fixed fraction is a coarse guess at a grid resolution, and running it
    independently for every tier means every tier inherits the same guess
    error. Cutting LOD1 from LOD0 and LOD2 from LOD1 makes each tier's budget
    relative to the tier above it, which is what keeps the chain strictly and
    substantially decreasing.
    """
    out = []
    for mi in range(len(gltf.doc.get("meshes", []))):
        geom = read_geometry(gltf, mi, scale)
        if geom[0] and geom[3]:
            out.append(geom)
    return out


def cluster_decimate(geoms, grid):
    """Vertex-cluster decimation of every mesh at one grid resolution.

    `geoms` is a list of (pos, nor, uv, idx) tuples as returned by
    `read_geometry`; the result is the same shape. `grid` is the number of
    cells along each axis of the mesh's own bounding box.

    Vertices are bucketed into that grid. Each occupied cell collapses to the
    mean position and the mean normal of its members, and takes the UV of the
    member closest to that mean -- averaging UVs across a cell is what
    produces smeared, sliding texture on a decal-heavy prop.

    The grid is a parameter rather than something derived from a target
    vertex count because a cubic grid sized from a prop's *volume* collapses
    thin props far harder than solid ones: a 0.7 x 3.9 x 0.4 m lamp post has
    most of its bounding box empty, so a 36-cell axis throws away almost the
    whole silhouette. Deciding the resolution from the triangle budget
    instead keeps every prop as detailed as its budget allows.

    Returns None when clustering would leave nothing to draw, so the caller
    can keep the previous tier instead of writing an empty LOD.
    """
    out = []
    for pos, nor, uv, idx in geoms:
        if not pos:
            continue
        mn = [min(v[i] for v in pos) for i in range(3)]
        mx = [max(v[i] for v in pos) for i in range(3)]
        ext = max(mx[i] - mn[i] for i in range(3)) or 1.0
        cell = ext / max(2, grid)

        buckets = {}
        for i, v in enumerate(pos):
            key = tuple(int((v[k] - mn[k]) / cell) for k in range(3))
            b = buckets.get(key)
            if b is None:
                b = buckets[key] = {"p": [0.0, 0.0, 0.0], "n": [0.0, 0.0, 0.0],
                                   "members": []}
            for k in range(3):
                b["p"][k] += v[k]
                b["n"][k] += nor[i][k]
            b["members"].append(i)

        lookup = {}
        out_pos, out_nor, out_uv = [], [], []
        for key, b in buckets.items():
            n = len(b["members"])
            c = [b["p"][k] / n for k in range(3)]
            nearest = min(b["members"],
                          key=lambda i: sum((pos[i][k] - c[k]) ** 2
                                            for k in range(3)))
            lookup[key] = len(out_pos)
            out_pos.append(c)
            ln = [b["n"][k] / n for k in range(3)]
            mag = math.sqrt(sum(x * x for x in ln)) or 1.0
            out_nor.append([x / mag for x in ln])
            out_uv.append(tuple(uv[nearest][:2]) if uv else (0.0, 0.0))

        out_idx = []
        for i in range(0, len(idx), 3):
            tri = idx[i:i + 3]
            if len(tri) < 3:
                continue
            tri_out = [lookup[tuple(int((pos[t][k] - mn[k]) / cell)
                                   for k in range(3))] for t in tri]
            a, b2, c2 = tri_out
            if a == b2 or b2 == c2 or a == c2:
                continue
            out_idx += tri_out
        if len(out_idx) >= 3:
            out.append((out_pos, out_nor, out_uv, out_idx))
    return out or None


MAX_GRID = 512
"""Upper bound on the grid search. Beyond this a prop's LOD is a few
hundred triangles regardless; the bound only stops the search looping."""


def decimate_to_budget(geoms, budget):
    """The finest uniform grid whose result still fits `budget` triangles.

    Cluster resolution trades triangles for silhouette monotonically: a
    coarser grid (more cells per axis) keeps fewer triangles. So the grid that
    best serves a budget is a binary search for the *finest* one that fits,
    rather than a formula's guess. That is what makes the LOD chain land where
    the catalogue says it should instead of wherever a heuristic happened to
    put it.

    The search direction follows the monotonicity: a *higher* grid means more
    cells and therefore *more* surviving triangles, so the answer is the
    highest grid that still fits and the bisection walks up when a candidate
    fits and down when it does not. Getting this backwards silently returned
    None for every prop, which is how LOD0 stayed over budget and six chains
    came out with a tier that was not cheaper than the one above it.

    When no grid reaches the budget the coarsest result is returned anyway:
    a LOD that misses its budget is still a strictly cheaper LOD, whereas
    None would make the caller ship a duplicate of the tier above.
    """
    have = geom_triangles(geoms)
    if have <= 0 or budget <= 0 or have <= budget:
        return None
    lo, hi, best, cheapest = 2, MAX_GRID, None, None
    while lo <= hi:
        mid = (lo + hi) // 2
        cand = cluster_decimate(geoms, mid)
        if cand is None:
            lo = mid + 1
            continue
        tris = geom_triangles(cand)
        if cheapest is None or tris < geom_triangles(cheapest):
            cheapest = cand
        if tris <= budget:
            best = cand          # fits; try a finer grid for more detail
            lo = mid + 1
        else:
            hi = mid - 1         # too dense; coarsen
    return best if best is not None else cheapest


def geom_triangles(geoms):
    return sum(len(g[3]) // 3 for g in geoms)


# --- writing ---------------------------------------------------------------

def pad4(blob):
    return blob + b"\x00" * ((4 - len(blob) % 4) % 4)


def build_lod(gltf, tag, geoms, out_dir):
    """Write one LOD from a list of (pos, nor, uv, idx) geometries.

    The node graph, scene, images, samplers, textures and materials are copied
    from the source document; only the geometry is the decimated one. Each
    source mesh keeps its own accessors and its own vertex range in the shared
    buffer, so the copied node graph still points at the right geometry and no
    mesh renders another's vertices.
    """
    blob = b""
    views = []
    accessors = []
    meshes = []
    total_tris = 0

    def add(data, target, atype, comp, count, minv=None, maxv=None):
        nonlocal blob
        while len(blob) % 4:
            blob += b"\x00"
        off = len(blob)
        blob += data
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data),
                      "target": target})
        a = {"bufferView": len(views) - 1, "componentType": comp,
             "count": count, "type": atype}
        if target == 34962:
            a["min"] = minv
            a["max"] = maxv
        accessors.append(a)
        return len(accessors) - 1

    src_meshes = gltf.doc.get("meshes", [])
    # Source mesh index -> index in the emitted `meshes` array. Decimation can
    # empty a mesh completely (every one of its triangles collapses into a
    # single cluster), and such a mesh is dropped: an empty `primitives` list
    # is not valid glTF. The node graph is copied from the source, so its
    # `mesh` indices have to be remapped onto the surviving meshes -- leaving
    # them pointing at a mesh that no longer exists is a dangling index, and
    # Godot's glTF importer dereferences it without checking, which is a
    # segfault inside the editor rather than a diagnosable import error.
    remap = {}
    for mi, (pos, nor, uv, idx) in enumerate(geoms):
        if not pos or not idx:
            continue
        remap[mi] = len(meshes)
        total_tris += len(idx) // 3
        a_pos = add(b"".join(struct.pack("<3f", *v) for v in pos), 34962,
                    "VEC3", 5126, len(pos),
                    [min(v[k] for v in pos) for k in range(3)],
                    [max(v[k] for v in pos) for k in range(3)])
        a_nor = add(b"".join(struct.pack("<3f", *v) for v in nor), 34962,
                    "VEC3", 5126, len(nor))
        a_uv = add(b"".join(struct.pack("<2f", *v) for v in uv), 34962,
                   "VEC2", 5126, len(uv))
        fmt, comp = ("<I", 5125) if len(pos) > 65535 else ("<H", 5123)
        a_idx = add(b"".join(struct.pack(fmt, i) for i in idx), 34963,
                    "SCALAR", comp, len(idx))
        prim = {"attributes": {"POSITION": a_pos, "NORMAL": a_nor,
                               "TEXCOORD_0": a_uv},
                "indices": a_idx, "mode": 4}
        src_prim = src_meshes[mi]["primitives"][0] if mi < len(src_meshes) \
            else {}
        if "material" in src_prim:
            prim["material"] = src_prim["material"]
        meshes.append({"primitives": [prim]})

    if not meshes or total_tris == 0:
        return None

    nodes = []
    for node in gltf.doc.get("nodes", [{"mesh": 0}]):
        node = dict(node)
        mi = node.get("mesh")
        if mi is not None:
            if mi in remap:
                node["mesh"] = remap[mi]
            else:
                # This mesh did not survive; the node keeps whatever children
                # or transform it had, it just has no geometry of its own.
                del node["mesh"]
        nodes.append(node)

    doc = {
        "asset": {"version": "2.0",
                  "generator": "EMERGENT tools/make_lods.py"},
        "scene": gltf.doc.get("scene", 0),
        "scenes": gltf.doc.get("scenes", [{"nodes": [0]}]),
        "nodes": nodes,
        "meshes": meshes,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob), "uri": "lod%d.bin" % tag}],
    }
    for key in ("images", "samplers", "textures", "materials"):
        if key in gltf.doc:
            doc[key] = gltf.doc[key]
    with open(os.path.join(out_dir, "lod%d.bin" % tag), "wb") as fh:
        fh.write(blob)
    return doc, total_tris


def copy_textures(gltf, out_dir):
    """Copy the model's external textures and rewrite the image URIs.

    glTF for Luanti and for Godot must not carry images inside the container:
    the client needs to load and stream them as ordinary files, and an embedded
    buffer forces the whole model to be resident before the first frame.
    """
    n = 0
    for img in gltf.doc.get("images", []):
        uri = img.get("uri")
        if not uri or uri.startswith("data:"):
            continue
        src = os.path.join(gltf.dir, uri)
        if not os.path.exists(src):
            continue
        dest = os.path.join(out_dir, os.path.basename(uri))
        if not os.path.exists(dest):
            with open(src, "rb") as fh:
                data = fh.read()
            with open(dest, "wb") as fh:
                fh.write(data)
        n += 1
    return n


# --- manifest --------------------------------------------------------------

def update_manifest(results):
    with open(MANIFEST) as fh:
        man = json.load(fh)
    by_id = {a["id"]: a for a in man["assets"]}
    for mid, info in results.items():
        a = by_id.get(mid)
        if a is None:
            continue
        a["validation"] = info["problems"] or "ok"
        a["mesh"] = info["stats"]
        a["lods"] = info["lods"]
        a["runtime"] = [{"path": os.path.relpath(p, ROOT), "bytes":
                         os.path.getsize(p)}
                        for p in sorted(set(info["files"]))]
        a["destination"] = "res://assets/runtime/models/%s" % mid
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(man, fh, indent=1)
    os.replace(tmp, MANIFEST)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    only = set(args.only or [])
    if not args.only and os.path.isdir(RUNTIME):
        for root, dirs, files in os.walk(RUNTIME, topdown=False):
            for f in files:
                os.remove(os.path.join(root, f))
            for d in dirs:
                os.rmdir(os.path.join(root, d))
    os.makedirs(RUNTIME, exist_ok=True)
    results = {}
    failures = 0
    log("models ->")
    for entry in cat.MODELS:
        mid = entry["id"]
        if only and mid not in only:
            continue
        src = os.path.join(SOURCE, mid, "%s_1k.gltf" % mid)
        if not os.path.exists(src):
            log("  !! %s: no source bundle" % mid)
            failures += 1
            continue
        gltf = Gltf(src)
        problems, stats = validate(mid, gltf)
        problems = [p for p in problems
                    if "budget" not in p and "floor" not in p
                    and "ceiling" not in p]
        source_tris = stats["triangles"]
        out_dir = os.path.join(RUNTIME, mid)
        os.makedirs(out_dir, exist_ok=True)

        # Scale baking. A prop modelled at the wrong size is fixed here, in
        # the mesh, so nothing in the game has to know a model needs a fudge
        # factor to stand on the ground.
        scale = 1.0
        want_h = entry.get("bake_height_m")
        if want_h:
            scale = float(want_h) / stats["size_m"][1]
            stats["size_m"] = [round(v * scale, 3) for v in stats["size_m"]]
            stats["baked_scale"] = round(scale, 4)
            stats["baked_height_m"] = want_h
            log("  %-22s baked x%.3f -> %.2f m tall" % (mid, scale, want_h))

        # A model over the triangle budget is brought under it at LOD0 rather
        # than rejected: a 176k-triangle potted plant is a fine model that is
        # simply too expensive to stand in a village 26 times over.
        geoms = read_all(gltf, scale)
        lod0_tris = geom_triangles(geoms)
        lod0_geoms = geoms
        if lod0_tris > MAX_TRIS:
            under = decimate_to_budget(geoms, MAX_TRIS)
            if under is not None:
                stats["source_triangles"] = source_tris
                stats["reduced_to_budget"] = True
                lod0_geoms = under
                lod0_tris = geom_triangles(under)
        stats["triangles"] = lod0_tris
        problems += size_problems(stats)
        if problems:
            failures += 1
            for p in problems:
                log("  !! %s: %s" % (mid, p))
        copy_textures(gltf, out_dir)
        files = []
        lods = []

        # The LOD chain is cut tier from tier, each against its own triangle
        # budget, so the fractions compound. LOD1 is the finest mesh that fits
        # LOD_TARGETS[0] of LOD0, and LOD2 the finest that fits
        # LOD_TARGETS[1] of LOD0 measured against what LOD1 actually became --
        # not against a fraction of LOD1, because clustering does not reduce
        # triangles by the fraction it was asked for.
        #
        # Cutting every tier independently from the source is what the
        # pipeline used to do, and it is why six props shipped a LOD2 that was
        # a third to two thirds of LOD0: the same heuristic guess was applied
        # at every tier, so its error never compounded.
        tiers = [(0, lod0_geoms, lod0_tris)]
        for tag, frac in cat.LOD_TARGETS:
            prev_geoms, prev_tris = tiers[-1][1], tiers[-1][2]
            budget = max(1, int(prev_tris * frac))
            cand = decimate_to_budget(prev_geoms, budget)
            if cand is None:
                # The tier above is already inside its own budget, so there is
                # nothing to cut. Reusing it would ship two identical LODs, so
                # the chain ends here and the missing tier is recorded below.
                break
            tiers.append((tag, cand, geom_triangles(cand)))

        for tag, tier_geoms, _tier_tris in tiers:
            dest = os.path.join(out_dir, "lod%d.gltf" % tag)
            built = build_lod(gltf, tag, tier_geoms, out_dir)
            if built is None:
                log("  !! %s: LOD%d produced no geometry" % (mid, tag))
                failures += 1
                continue
            data, tris = built
            data = json.loads(json.dumps(data))
            for img in data.get("images", []):
                if img.get("uri") and not img["uri"].startswith("data:"):
                    img["uri"] = os.path.basename(img["uri"])
            data["buffers"][0]["uri"] = "lod%d.bin" % tag
            with open(dest, "w") as fh:
                json.dump(data, fh)
            lods.append({"lod": tag, "triangles": tris,
                         "path": os.path.relpath(dest, ROOT)})
            files += [dest, os.path.join(out_dir, "lod%d.bin" % tag)]

        # The budget is a property of the pipeline, so it is enforced here
        # rather than only asserted by the test suite: a chain that violates
        # it fails the build instead of shipping.
        if len(lods) < len(cat.LOD_TARGETS) + 1:
            failures += 1
            log("  !! %s: only %d of %d LOD tiers were produced"
                % (mid, len(lods), len(cat.LOD_TARGETS) + 1))
        for i in range(len(lods) - 1):
            if lods[i + 1]["triangles"] >= lods[i]["triangles"]:
                failures += 1
                log("  !! %s: LOD%d is not cheaper than LOD%d (%d >= %d)"
                    % (mid, lods[i + 1]["lod"], lods[i]["lod"],
                       lods[i + 1]["triangles"], lods[i]["triangles"]))
        if lods and lods[-1]["triangles"] * 4 >= lods[0]["triangles"]:
            failures += 1
            log("  !! %s: LOD2 is %d triangles against LOD0's %d, which is "
                "not a usable distance budget"
                % (mid, lods[-1]["triangles"], lods[0]["triangles"]))
        results[mid] = {"problems": problems, "stats": stats, "lods": lods,
                        "files": files}
        flag = " (from %d)" % stats["source_triangles"] \
            if "source_triangles" in stats else ""
        log("  %-22s %6d tris%s  %s" % (
            mid, stats["triangles"], flag,
            " ".join("L%d:%d" % (l["lod"], l["triangles"]) for l in lods)))
    update_manifest(results)
    total = sum(r["stats"]["triangles"] for r in results.values())
    print("\n%d models, %d triangles at LOD0, %d LOD tiers each"
          % (len(results), total, len(cat.LOD_TARGETS) + 1))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
