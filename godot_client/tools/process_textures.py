#!/usr/bin/env python3
"""Turn the CC0 sources in `assets/source/` into the runtime texture library.

This is the only step that needs a third-party module (Pillow, see
`tools/requirements.txt`). It is offline, deterministic and never touches the
game: its whole output is files under `assets/runtime/textures/` plus the
`runtime` section of the manifest.

What it does, per texture set:

1. **Resample.** The largest available source is resampled with a Lanczos
   filter down to every tier in the ladder. A tier larger than the source is
   never written, so nothing is ever upscaled.
2. **Right format per map.** Albedo is JPEG (q88, 4:4:4, baseline, no
   progressive/interlaced scan). Normals and the packed ARM map are PNG: JPEG
   chroma subsampling would corrupt a normal's blue channel and a material's
   metalness channel, which are exactly the channels the shader reads.
3. **Strip metadata.** No EXIF, no ICC, no thumbnails. PBR albedo from both
   providers is already sRGB, so a profile would only be a way for the colour
   to shift silently between machines.
4. **Derive the ore sets.** Composition, not invention: a CC0 rock host with
   a CC0 metal of the same ore composited through a deterministic inclusion
   mask, and the ARM map rebuilt so the inclusions carry the metal's
   roughness and metalness. The result is CC0.
5. **Derive the POM height field** from the normal map's Z channel, so
   parallax occlusion and lighting agree and the 100 MB displacement maps do
   not have to be downloaded and kept resident.

Run:  python3 tools/process_textures.py [--only <set>...] [--force]
"""
import argparse
import json
import os
import random
import sys

from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asset_catalog as cat  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(ROOT, "assets")
SOURCE = os.path.join(ASSETS, "source")
RUNTIME = os.path.join(ASSETS, "runtime", "textures")
MANIFEST = os.path.join(ASSETS, "source_manifest", "manifest.json")

# How each map is encoded. The reason is in the file header and in
# ART_DIRECTION.md; the short version is that only albedo tolerates JPEG.
ENC = {
    "diff": ("jpg", 88, 0),
    "nor_gl": ("png", None, None),
    "arm": ("png", None, None),
    "rough": ("png", None, None),
    "metal": ("png", None, None),
    "height": ("png", None, None),
}

# Which provider map name produces which runtime map. Poly Haven publishes a
# packed ARM already; ambientCG does not, so it is packed here from roughness
# and metalness, with AO left fully open (ambientCG's 1K zip has no AO map).
SOURCE_MAP_FOR = {
    "polyhaven": {"diff": "diff", "nor_gl": "nor_gl", "arm": "arm"},
    "ambientcg": {"diff": "diff", "nor_gl": "nor_gl", "arm": None},
}

# Ore inclusion thresholds. Higher means rarer, smaller inclusions.
ORE_THRESHOLD = {"ore_copper": 0.585, "ore_iron": 0.600, "ore_silver": 0.640,
                 "ore_coal": 0.560}
ORE_DARKEN = {"ore_coal": 0.26}
HEIGHT_TIER = 1024
"""Parallax occlusion reads one extra texture per material, so the height field
is written at a single resolution. It is a low-frequency relief term; the
Lanczos-downsampled normal it comes from carries the high frequencies."""

DATA_CAP = 1024
"""Normals and the ARM map are written at half the albedo tier above this.

Both are high-frequency, and both are the reason the 2048 tier cost 24 MB of
PNG per set. A normal map at 1024 on a 2048 albedo is not visible as a
difference on a one-metre face, and it is a quarter of the pixels, a quarter of
the VRAM and a quarter of the import time. The albedo is what the eye resolves;
the data maps are what the shader integrates."""

_noise_cache = {}


def log(msg):
    print(msg, flush=True)


def source_dir(provider, source_id):
    if provider == "polyhaven":
        return os.path.join(SOURCE, "polyhaven", source_id)
    if provider == "ambientcg":
        return os.path.join(SOURCE, "ambientcg", source_id)
    raise ValueError(provider)


def find_source(entry, map_name):
    """Absolute path of the source file for one map of one set."""
    provider = entry["provider"]
    sid = entry.get("source_id", entry["id"])
    d = source_dir(provider, sid)
    if provider == "ambientcg":
        member = {"diff": "Color", "nor_gl": "NormalGL", "rough": "Roughness",
                  "metal": "Metalness"}.get(map_name)
        if member is None:
            return None  # the ARM map is packed from rough+metal, not shipped
        p = os.path.join(d, "%s_1K-JPG_%s.jpg" % (sid, member))
        return p if os.path.exists(p) else None
    res = entry["source_res"]
    p = os.path.join(d, "%s_%s.jpg" % (map_name, res))
    return p if os.path.exists(p) else None


def out_path(set_id, map_name, tier):
    ext = ENC[map_name][0]
    return os.path.join(RUNTIME, set_id, "%s_%d.%s" % (map_name, tier, ext))


def load_rgb(path):
    im = Image.open(path)
    im = im.convert("RGB")
    return im


def save(im, path, map_name):
    ext, quality, subsampling = ENC[map_name]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if ext == "jpg":
        # progressive=False keeps the scan baseline and non-interlaced;
        # subsampling=0 is 4:4:4, so no chroma is thrown away.
        im.save(path, "JPEG", quality=quality, subsampling=subsampling,
                optimize=True, progressive=False, exif=b"")
    else:
        # optimize=True tries several filter strategies per row and is the
        # slowest part of this script for a few percent of size; the runtime
        # cost of a texture is its VRAM footprint, not its PNG.
        im.save(path, "PNG", compress_level=6, exif=b"")


def vram_bytes(size_px, mipmapped=True):
    """Bytes a texture occupies in VRAM once the engine has it.

    Godot imports 3D-detected textures with VRAM compression (the project sets
    `importer_defaults/texture.compress/mode=2`), so the estimate is BC7 for
    colour and data maps: 16 bytes per 4x4 block, i.e. 1 byte per pixel,
    plus the mip chain at 4/3.
    """
    px = size_px * size_px
    return int(px * (4.0 / 3.0 if mipmapped else 1.0))


# --- noise -----------------------------------------------------------------

def inclusion_mask(size, seed, threshold, softness=10):
    """A deterministic blobby mask: value noise at 1/4 resolution, upsampled
    and smoothed, then thresholded.

    Deterministic means the same ore looks the same on every machine and in
    every rebuild, which is what makes the manifest's checksums meaningful.
    """
    key = (size, seed, threshold, softness)
    if key in _noise_cache:
        return _noise_cache[key]
    small = 256
    rng = random.Random(seed)
    data = bytes(rng.randrange(256) for _ in range(small * small))
    noise = Image.frombytes("L", (small, small), data)
    mask = noise.resize((size, size), Image.BICUBIC)
    mask = mask.filter(ImageFilter.GaussianBlur(softness))
    # point() with a lambda is the threshold; the blur above is what gives the
    # inclusion a soft edge instead of a jpeg-looking cut-out.
    mask = mask.point(lambda v: 255 if v > threshold * 255 else 0)
    mask = mask.filter(ImageFilter.GaussianBlur(1.2))
    _noise_cache[key] = mask
    return mask


def height_from_normal(nor):
    """Height field for parallax occlusion, from the normal map's Z channel.

    The normal already encodes the surface's relief; reading Z back out gives a
    height field that agrees with the lighting by construction. Godot samples
    it in tangent space, so green-up (OpenGL convention) is what we want, which
    is the convention the provider maps are already in.
    """
    r, _g, b = nor.split()[:3]
    z = b.point(lambda v: max(0, min(255, int(128 + v * 0.6))))
    return z


# --- per-set processing ----------------------------------------------------

def process_texture(entry, force=False, only=None):
    set_id = entry["id"]
    provider = entry["provider"]
    role = entry.get("role", "surface")
    tiers = [cat.DETAIL_TIER] if role == "detail" else cat.tiers_for(entry)
    out = []
    # A detail overlay is only ever bound as detail_albedo, so the other two
    # maps for a detail set would be files nothing loads.
    maps = ["diff"] if role == "detail" else ["diff", "nor_gl", "arm"]

    src = {m: find_source(entry, m) for m in maps}
    if provider == "ambientcg":
        rough = find_source(entry, "rough")
        metal = find_source(entry, "metal")
        if rough and metal:
            # ambientCG ships roughness and metalness separately and no AO at
            # this resolution, so the packed map is built here. R is left fully
            # open: there is no occlusion data to pack, and an AO texture that
            # is uniformly 1.0 costs the same memory and does nothing, so the
            # material simply does not bind an AO channel.
            arm = build_arm(rough, metal)
            tmp = os.path.join("/tmp", "acg_arm_%s.png" % entry["source_id"])
            arm.save(tmp, "PNG")
            src["arm"] = tmp
    missing = [m for m in maps if not src[m]]
    if missing:
        log("  !! %s: no source for %s" % (set_id, ", ".join(missing)))
        return None

    base = {m: load_rgb(src[m]) for m in maps}
    written = set()
    for tier in tiers:
        for m in maps:
            res = min(tier, DATA_CAP) if m in ("nor_gl", "arm") else tier
            dest = out_path(set_id, m, res)
            if dest in written:
                continue
            written.add(dest)
            if os.path.exists(dest) and not force:
                out.append(dest)
                continue
            im = base[m]
            if res != im.size[0]:
                im = im.resize((res, res), Image.LANCZOS)
            save(im, dest, m)
            out.append(dest)

    # The POM height field, written once per set rather than once per tier.
    #
    # It is derived from the normal map *at HEIGHT_TIER*, not from the source
    # normal. Deriving it from the source wrote a 4096x4096 height map into a
    # file called height_1024.png: 16x the pixels the name promised, 16x the
    # VRAM, and a mismatch between the rung the material asks for and the file
    # it gets. It is also derived from the downsampled normal so the relief
    # POM marches agrees with the relief the shader lights -- if they came from
    # different resolutions they would not agree at high frequencies.
    if role == "surface":
        hp = out_path(set_id, "height", HEIGHT_TIER)
        if force or not os.path.exists(hp):
            hn = base["nor_gl"]
            if hn.size[0] != HEIGHT_TIER:
                hn = hn.resize((HEIGHT_TIER, HEIGHT_TIER), Image.LANCZOS)
            save(height_from_normal(hn), hp, "height")
        if hp not in out:
            out.append(hp)
    log("  %-22s %s" % (set_id, "  ".join(
        "%s" % os.path.basename(p) for p in out)))
    return out


def build_arm(rough_path, metal_path):
    r = load_rgb(rough_path).convert("L")
    m = load_rgb(metal_path).convert("L")
    return Image.merge("RGB", (Image.new("L", r.size, 255), r, m))


def process_derived(entry, force=False):
    """Compose one ore set out of a rock host and a refined metal."""
    set_id = entry["id"]
    host = next(t for t in cat.TEXTURES if t["id"] == entry["host"])
    metal = None
    if entry.get("metal"):
        metal = next(t for t in cat.TEXTURES if t["id"] == entry["metal"])
    threshold = ORE_THRESHOLD[set_id]
    tiers = [t for t in cat.TIERS if t <= cat.SOURCE_PX["1k"]]
    seed = sum(ord(c) for c in set_id)
    out = []

    host_diff = load_rgb(find_source(host, "diff"))
    host_nor = load_rgb(find_source(host, "nor_gl"))
    host_arm = Image.open(find_source(host, "arm")).convert("RGB")

    if metal is not None:
        m_diff = load_rgb(find_source(metal, "diff"))
        m_rough = load_rgb(find_source(metal, "rough"))
        m_metal = load_rgb(find_source(metal, "metal"))
    else:
        # Coal: the inclusion is the host rock crushed down in value rather
        # than a metal composited in, because coal is not metal.
        m_diff = host_diff.point(lambda v: int(v * ORE_DARKEN[set_id]))
        m_rough = host_arm.getchannel("G").point(lambda v: min(255, v + 40))
        m_metal = Image.new("L", host_diff.size, 0)

    for tier in tiers:
        size = tier
        data = min(tier, DATA_CAP)
        mask = inclusion_mask(size, seed, threshold)
        hd = (host_diff if size == host_diff.size[0]
              else host_diff.resize((size, size), Image.LANCZOS))
        hn = (host_nor if data == host_nor.size[0]
              else host_nor.resize((data, data), Image.LANCZOS))
        ha = (host_arm if data == host_arm.size[0]
              else host_arm.resize((data, data), Image.LANCZOS))
        md = m_diff.resize((size, size), Image.LANCZOS)
        mr = m_rough.resize((data, data), Image.LANCZOS)
        mm = m_metal.resize((data, data), Image.LANCZOS)

        diff = Image.composite(md, hd, mask)
        # R (AO) stays the host rock's; G (roughness) and B (metalness) take
        # the inclusion's values where the inclusion is.
        r, g, b = ha.split()
        arm = Image.merge("RGB", (r, Image.composite(mr, g, mask),
                                  Image.composite(mm, b, mask)))
        save(diff, out_path(set_id, "diff", tier), "diff")
        save(hn, out_path(set_id, "nor_gl", data), "nor_gl")
        save(arm, out_path(set_id, "arm", data), "arm")
        if data == HEIGHT_TIER:
            save(height_from_normal(hn), out_path(set_id, "height", HEIGHT_TIER),
                 "height")
        out += [out_path(set_id, "diff", tier),
                out_path(set_id, "nor_gl", data),
                out_path(set_id, "arm", data)]
    log("  %-22s derived from %s + %s" % (set_id, host["id"],
                                          entry.get("metal") or "value crush"))
    return out


# --- manifest bookkeeping --------------------------------------------------

def update_manifest(runtime_index, measured):
    with open(MANIFEST) as fh:
        man = json.load(fh)
    for a in man["assets"]:
        files = runtime_index.get(a["id"])
        if not files:
            continue
        a["runtime"] = [{"path": os.path.relpath(p, ROOT),
                         "bytes": os.path.getsize(p)} for p in sorted(set(files))]
        a["runtime_bytes"] = sum(f["bytes"] for f in a["runtime"])
        a["measured"] = measured.get(a["id"], a.get("measured", {}))
        a["vram_bytes"] = vram_bytes(a["measured"].get("peak_tier", 1024)) * 3
        if a["kind"] == "texture":
            a["optimization"] = (
                "Lanczos resample to %s; albedo JPEG q88 4:4:4 baseline, "
                "normals and ARM PNG; EXIF/ICC stripped; no interlacing; "
                "mipmaps generated at import (project importer_defaults)."
                % ", ".join(str(t) for t in a.get("tiers", [])))
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(man, fh, indent=1)
    os.replace(tmp, MANIFEST)


def measure(set_id, tiers):
    """Record the real on-disk dimensions, read back from the files."""
    peak = max(tiers) if tiers else 0
    out = {"peak_tier": peak}
    for t in tiers:
        p = out_path(set_id, "diff", t)
        if os.path.exists(p):
            with Image.open(p) as im:
                out["%dpx" % t] = list(im.size)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--keep", action="store_true",
                    help="do not wipe the runtime tree first (incremental)")
    args = ap.parse_args()
    only = set(args.only or [])
    # The runtime tree is fully derived, so it is rebuilt from scratch unless
    # --keep is passed. That is what stops a changed ladder from leaving an
    # orphaned 2048 normal map behind for ever.
    if not args.keep and os.path.isdir(RUNTIME):
        for root, dirs, files in os.walk(RUNTIME, topdown=False):
            for f in files:
                os.remove(os.path.join(root, f))
            for d in dirs:
                os.rmdir(os.path.join(root, d))
    elif os.path.isdir(RUNTIME):
        os.makedirs(RUNTIME, exist_ok=True)
    else:
        os.makedirs(RUNTIME, exist_ok=True)

    index = {}
    measured = {}
    log("processing textures ->")
    for entry in cat.TEXTURES:
        if only and entry["id"] not in only:
            continue
        out = process_texture(entry, force=args.force)
        if out:
            index[entry["id"]] = out
            tiers = [cat.DETAIL_TIER] if entry.get("role") == "detail" \
                else cat.tiers_for(entry)
            measured[entry["id"]] = measure(entry["id"], tiers)
    for entry in cat.DERIVED:
        if only and entry["id"] not in only:
            continue
        out = process_derived(entry, force=args.force)
        if out:
            index[entry["id"]] = out
            measured[entry["id"]] = measure(entry["id"],
                                            [t for t in cat.TIERS
                                             if t <= cat.SOURCE_PX["1k"]])
    if index:
        update_manifest(index, measured)
    total = 0
    for root, _d, files in os.walk(RUNTIME):
        for f in files:
            if f.endswith((".jpg", ".png")):
                total += os.path.getsize(os.path.join(root, f))
    log("\nruntime textures: %d files, %.1f MB on disk"
        % (sum(len(v) for v in index.values()), total / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main())
