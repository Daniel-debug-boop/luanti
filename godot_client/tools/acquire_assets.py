#!/usr/bin/env python3
"""Fetch every asset in `asset_catalog.py` from its provider, verify it, and
record it in `assets/source_manifest/manifest.json`.

Design rules:

* **Nothing is downloaded that is not in the catalog.** The catalog is the
  review artefact; this file is only the courier.
* **Every download is verified.** Poly Haven publishes an md5 per file and it
  is checked; ambientCG does not, so the sha256 is computed and stored. A file
  that fails its checksum is deleted rather than kept.
* **Re-running is cheap and safe.** A file already on disk with the right
  checksum is left alone, so an interrupted run resumes. `--force` re-fetches.
* **Sources are not committed.** They land in `assets/source/`, which is in
  .gitignore. The manifest carries the URL and the checksum, so the exact
  bytes are reproducible from the manifest alone.

Usage:
    python3 tools/acquire_assets.py                 # everything missing
    python3 tools/acquire_assets.py --list          # what the catalog wants
    python3 tools/acquire_assets.py --only rock_06 aerial_grass_rock
    python3 tools/acquire_assets.py --force
"""
import argparse
import hashlib
import io
import json
import os
import sys
import time
import urllib.request
import zipfile
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asset_catalog as cat  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
ASSETS = os.path.join(ROOT, "assets")
SOURCE = os.path.join(ASSETS, "source")
MANIFEST = os.path.join(ASSETS, "source_manifest", "manifest.json")
PH_API = "https://api.polyhaven.com"
ACG_GET = "https://ambientcg.com/get?file=%s_1K-JPG.zip"
UA = "EMERGENT-asset-pipeline/1 (+https://github.com/Daniel-debug-boop/luanti)"

# Poly Haven map key in its files API -> our map name.
PH_MAP = {"Diffuse": "diff", "nor_gl": "nor_gl", "arm": "arm"}


def log(msg):
    print(msg, flush=True)


def fetch(url, tries=3):
    last = ""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=150) as r:
                return r.read()
        except Exception as exc:  # noqa: BLE001 - report and retry
            last = "%s: %s" % (type(exc).__name__, exc)
            time.sleep(1.5 * (i + 1))
    log("    FAILED %s (%s)" % (url.rsplit("/", 1)[-1], last))
    return None


def md5_of(data):
    return hashlib.md5(data).hexdigest()


def sha256_of(data):
    return hashlib.sha256(data).hexdigest()


def write_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def ph_json(url, cache_name):
    """Poly Haven API JSON, cached under /tmp so a rerun is offline."""
    cache = os.path.join("/tmp", "ph_cache_%s.json" % cache_name)
    if os.path.exists(cache):
        with open(cache) as fh:
            return json.load(fh)
    data = fetch(url)
    if data is None:
        return None
    try:
        parsed = json.loads(data)
    except ValueError:
        log("    FAILED json %s" % url)
        return None
    with open(cache, "w") as fh:
        json.dump(parsed, fh)
    return parsed


# --- Poly Haven textures ---------------------------------------------------

def acquire_polyhaven_texture(entry):
    sid = entry["source_id"]
    res = entry["source_res"]
    info = ph_json("%s/files/%s" % (PH_API, sid), "files_%s" % sid)
    if info is None:
        return None
    out_dir = os.path.join(SOURCE, "polyhaven", sid)
    files = []
    missing = []
    for key, our_map in PH_MAP.items():
        if key not in info or res not in info[key]:
            missing.append("%s@%s" % (key, res))
            continue
        variants = info[key][res]
        if "jpg" not in variants:
            missing.append("%s@%s (no jpg)" % (key, res))
            continue
        meta = variants["jpg"]
        ext = "jpg"
        dest = os.path.join(out_dir, "%s_%s.%s" % (our_map, res, ext))
        want = meta["md5"]
        if os.path.exists(dest) and md5_of(open(dest, "rb").read()) == want:
            status = "cached"
        else:
            data = fetch(meta["url"])
            if data is None:
                missing.append(our_map)
                continue
            got = md5_of(data)
            if got != want:
                log("    CHECKSUM MISMATCH %s (%s != %s)" % (dest, got, want))
                missing.append(our_map)
                continue
            write_file(dest, data)
            status = "ok %dKB" % (len(data) // 1024)
        files.append({
            "map": our_map, "path": os.path.relpath(dest, ROOT),
            "resolution": res, "format": ext, "md5": want,
            "bytes": os.path.getsize(dest), "source_url": meta["url"],
        })
        log("    %-8s %-6s %s" % (our_map, res, status))
    if missing:
        log("    !! %s: missing %s" % (sid, ", ".join(missing)))
        return None
    return files


# --- ambientCG textures ----------------------------------------------------

ACG_MAP = {"Color": "diff", "NormalGL": "nor_gl", "Roughness": "rough",
           "Metalness": "metal"}

def acquire_ambientcg_texture(entry):
    sid = entry["source_id"]
    out_dir = os.path.join(SOURCE, "ambientcg", sid)
    want = ["%s_1K-JPG_%s.jpg" % (sid, m) for m in ACG_MAP]
    # Already extracted? Then skip the 2.7 MB zip entirely.
    if all(os.path.exists(os.path.join(out_dir, "%s_%s.jpg" % (sid, m)))
           for m in ACG_MAP):
        log("    cached (extracted)")
        files = []
        for m in ACG_MAP:
            p = os.path.join(out_dir, "%s_%s.jpg" % (sid, m))
            files.append({"map": ACG_MAP[m],
                          "path": os.path.relpath(p, ROOT),
                          "resolution": "1k", "format": "jpg",
                          "sha256": sha256_of(open(p, "rb").read()),
                          "bytes": os.path.getsize(p)})
        return files
    url = ACG_GET % sid
    data = fetch(url)
    if data is None:
        return None
    zf = zipfile.ZipFile(io.BytesIO(data))
    files = []
    for member, our_map in ACG_MAP.items():
        name = "%s_1K-JPG_%s.jpg" % (sid, member)
        try:
            blob = zf.read(name)
        except KeyError:
            log("    !! %s has no %s" % (sid, member))
            return None
        dest = os.path.join(out_dir, name)
        write_file(dest, blob)
        files.append({"map": our_map, "path": os.path.relpath(dest, ROOT),
                      "resolution": "1k", "format": "jpg",
                      "sha256": sha256_of(blob), "bytes": len(blob)})
        log("    %-8s 1k    ok %dKB" % (our_map, len(blob) // 1024))
    # AmbientCG packs nothing; the ARM map is built by process_textures.py from
    # Roughness + Metalness, which is recorded on the derived entry.
    return files


# --- Poly Haven models and HDRIs ------------------------------------------

def acquire_model(entry):
    """Fetch a Poly Haven glTF bundle: the .gltf container, its .bin, and the
    external textures it references.

    The container and the includes are fetched from the files API's own URL
    list, so the CDN layout is never guessed. Each file is checksummed against
    the md5 the API publishes for it.
    """
    sid = entry["source_id"]
    info = ph_json("%s/files/%s" % (PH_API, sid), "files_%s" % sid)
    if info is None or "gltf" not in info or "1k" not in info["gltf"]:
        log("    !! %s: no 1k gltf" % sid)
        return None
    root = info["gltf"]["1k"]["gltf"]
    jobs = [(root, "models/%s/%s_1k.gltf" % (sid, sid))]
    for rel, meta in root.get("include", {}).items():
        jobs.append((meta, "models/%s/%s" % (sid, rel)))
    files = []
    for meta, rel in jobs:
        dest = os.path.join(SOURCE, "polyhaven", rel)
        want = meta.get("md5")
        if os.path.exists(dest) and (not want or
                                     md5_of(open(dest, "rb").read()) == want):
            log("    cached %s" % rel)
        else:
            data = fetch(meta["url"])
            if data is None:
                return None
            got = md5_of(data)
            if want and got != want:
                log("    !! CHECKSUM MISMATCH %s" % rel)
                return None
            write_file(dest, data)
            log("    ok %-52s %dKB" % (rel, len(data) // 1024))
        files.append({"path": os.path.relpath(dest, ROOT),
                      "md5": md5_of(open(dest, "rb").read()),
                      "bytes": os.path.getsize(dest),
                      "source_url": meta["url"]})
    return files


def acquire_hdri(entry):
    sid = entry["source_id"]
    info = ph_json("%s/files/%s" % (PH_API, sid), "files_%s" % sid)
    if info is None or "hdri" not in info or "1k" not in info["hdri"]:
        return None
    meta = info["hdri"]["1k"]["hdr"]
    dest = os.path.join(SOURCE, "polyhaven", "hdri", "%s_1k.hdr" % sid)
    if os.path.exists(dest) and md5_of(open(dest, "rb").read()) == meta["md5"]:
        log("    cached")
    else:
        data = fetch(meta["url"])
        if data is None:
            return None
        got = md5_of(data)
        if got != meta["md5"]:
            log("    !! CHECKSUM MISMATCH for %s" % sid)
            return None
        write_file(dest, data)
        log("    ok %dKB" % (len(data) // 1024))
    return [{"path": os.path.relpath(dest, ROOT), "md5": meta["md5"],
             "bytes": os.path.getsize(dest), "source_url": meta["url"]}]


# --- Manifest --------------------------------------------------------------

def load_manifest():
    if os.path.exists(MANIFEST):
        with open(MANIFEST) as fh:
            return json.load(fh)
    return {"generated": str(date.today()), "assets": []}


def save_manifest(man):
    man["generated"] = str(date.today())
    man["licences"] = cat.LICENCE
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(man, fh, indent=1, sort_keys=False)
    os.replace(tmp, MANIFEST)


def entry_for(man, key):
    for a in man["assets"]:
        if a["id"] == key:
            return a
    return None


def record(man, entry, kind, files, extra=None):
    rec = {
        "id": entry["id"],
        "kind": kind,
        "provider": entry["provider"],
        "source_id": entry.get("source_id", entry["id"]),
        "source_page": cat.SOURCE_PAGE.get(entry["provider"], "") +
        (entry.get("source_id", "") if entry["provider"] in
         ("ambientcg", "kaykit") else entry.get("source_id", "")),
        "licence": cat.LICENCE[entry["provider"]],
        "author": cat.AUTHORS[entry["provider"]],
        "original_resolution": entry.get("source_res", "n/a"),
        "original_format": entry.get("format", ""),
        "downloaded": str(date.today()),
        "category": entry.get("category", "unknown"),
        "blocks": entry.get("blocks", []),
        "files": files or [],
        "note": entry.get("note", ""),
    }
    if extra:
        rec.update(extra)
    old = entry_for(man, rec["id"])
    if old is not None:
        # Keep any measurement the processing step wrote.
        for k in ("measured", "runtime", "conversion", "optimization"):
            if k in old:
                rec[k] = old[k]
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", nargs="*", default=None)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--skip-models", action="store_true")
    args = ap.parse_args()

    if args.list:
        for e in cat.TEXTURES:
            log("texture  %-22s %-10s %-4s tiers=%s" % (
                e["id"], e["source_id"], e["source_res"],
                cat.tiers_for(e)))
        for e in cat.DERIVED + cat.PROCEDURAL:
            log("derived  %-22s %s" % (e["id"], e.get("note", "")[:40]))
        for e in cat.MODELS:
            log("model    %-22s lods=%s" % (e["id"], cat.LOD_TARGETS))
        for e in cat.CHARACTERS + cat.HDRIS:
            log("%-8s %s" % (e.get("category", "char"), e["id"]))
        return 0

    man = load_manifest()
    only = set(args.only or [])

    def wanted(k):
        return only == set() or k in only

    ok = True
    for entry in cat.TEXTURES:
        if not wanted(entry["id"]):
            continue
        if entry["provider"] == "polyhaven":
            files = acquire_polyhaven_texture(entry)
        elif entry["provider"] == "ambientcg":
            files = acquire_ambientcg_texture(entry)
        else:
            files = []
        if files is None:
            ok = False
            continue
        if args.force:
            for f in files:
                p = os.path.join(ROOT, f["path"])
                if os.path.exists(p):
                    os.remove(p)
            files = (acquire_polyhaven_texture(entry)
                     if entry["provider"] == "polyhaven"
                     else acquire_ambientcg_texture(entry))
        man["assets"] = [a for a in man["assets"] if a["id"] != entry["id"]]
        man["assets"].append(record(man, entry, "texture", files, {
            "hero": entry.get("hero", False),
            "role": entry.get("role", "surface"),
            "tiers": cat.tiers_for(entry),
        }))
        log("  %s %s" % ("OK " if files else "EMPTY", entry["id"]))

    for entry in cat.DERIVED:
        if not wanted(entry["id"]):
            continue
        man["assets"] = [a for a in man["assets"] if a["id"] != entry["id"]]
        man["assets"].append(record(man, dict(entry, provider="derived"), "derived", [], {
            "host": entry["host"], "metal": entry["metal"],
            "conversion": "ore_mix_v1: host rock albedo blended with the "
                          "refined metal's albedo through a deterministic "
                          "value-noise inclusion mask; ARM rebuilt with the "
                          "metal's roughness/metalness inside the mask; the "
                          "host normal map is reused unchanged (ore inclusions "
                          "are sub-voxel).",
            "tiers": [t for t in cat.TIERS if t <= cat.SOURCE_PX["1k"]],
        }))
        log("  DERIVED %s = %s + %s" % (entry["id"], entry["host"],
                                        entry["metal"]))

    for entry in cat.PROCEDURAL:
        if not wanted(entry["id"]):
            continue
        man["assets"] = [a for a in man["assets"] if a["id"] != entry["id"]]
        man["assets"].append(record(man, dict(entry, provider="procedural"),
                                    "procedural", [], {"tiers": []}))
        log("  PROCEDURAL %s" % entry["id"])

    if not args.skip_models:
        for entry in cat.MODELS:
            if not wanted(entry["id"]):
                continue
            files = acquire_model(entry)
            if files is None:
                ok = False
                continue
            man["assets"] = [a for a in man["assets"]
                             if a["id"] != entry["id"]]
            man["assets"].append(record(man, entry, "model", files, {
                "lod_targets": cat.LOD_TARGETS,
                "format": "gltf + external textures",
            }))
        for entry in cat.HDRIS:
            if not wanted(entry["id"]):
                continue
            files = acquire_hdri(entry)
            if files is None:
                ok = False
                continue
            man["assets"] = [a for a in man["assets"]
                             if a["id"] != entry["id"]]
            man["assets"].append(record(man, entry, "hdri", files))

    for entry in cat.CHARACTERS:
        if not wanted(entry["id"]):
            continue
        rel = ("addons/kaykit_character_pack_adventures/Characters/gltf/%s.glb"
               if entry["source_id"] in ("Knight", "Mage", "Barbarian")
               else "addons/kaykit_character_pack_skeletons/Characters/gltf/"
                    "%s.glb") % entry["source_id"]
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            log("  !! character %s missing at %s" % (entry["id"], rel))
            ok = False
            continue
        man["assets"] = [a for a in man["assets"] if a["id"] != entry["id"]]
        man["assets"].append(record(man, entry, "character", [{
            "path": rel, "md5": md5_of(open(p, "rb").read()),
            "bytes": os.path.getsize(p)}]))

    save_manifest(man)
    log("\nmanifest: %s (%d entries)" % (os.path.relpath(MANIFEST, ROOT),
                                         len(man["assets"])))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
