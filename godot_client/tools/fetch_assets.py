#!/usr/bin/env python3
"""Fetch curated CC0 assets from Poly Haven (api.polyhaven.com + CDN).

For each asset the files API is queried for its real URL list, so the CDN
layout is never guessed. Models come down as 1k GLBs (gltf container + .bin +
textures), HDRIs as .hdr, terrain textures as diff/nor/arm/dis jpgs.
Everything lands in godot_client/assets/raw/ ready for Godot import.
"""
import concurrent.futures as cf
import json
import os
import sys
import time
import urllib.request

API = "https://api.polyhaven.com"
OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "assets", "raw"))

TERRAIN_TEXTURES = [
    "aerial_rocks_02", "brown_mud_leaves_01", "coast_sand_rocks_02",
    "forrest_ground_01", "grass_medium_01", "mud_02", "rock_06",
    "rock_face_04", "snow_02", "worn_gravel_01", "sand_01", "cracked_mud_02",
]

DAY_HDRIS = ["kloofendal_48d_partly_cloudy_puresky", "quarry_01_puresky",
             "autumn_field_puresky", "farm_field_puresky"]
NIGHT_HDRIS = ["dikhololo_night", "moonless_golf", "clarens_night_01"]
SUNSET_HDRIS = ["belfast_sunset_puresky", "venice_sunset"]

# Village/prop models that fit a blocky world.
MODELS = [
    "Barrel_01", "wooden_barrels_01", "wooden_crate_01", "wooden_crate_02",
    "treasure_chest", "metal_tool_chest", "wooden_lantern_01", "Lantern_01",
    "painted_wooden_stool", "chinese_stool", "painted_wooden_bench",
    "planter_pot_clay", "potted_plant_01", "ceramic_pot", "street_lamp_01",
    "wine_barrel_01", "old_military_crate",
]


def http_json(url: str, dest: str, tries: int = 3):
    if os.path.exists(dest):
        try:
            return json.load(open(dest))
        except Exception:
            pass
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lvx/1"})
            with urllib.request.urlopen(req, timeout=90) as r:
                data = r.read()
            open(dest, "wb").write(data)
            return json.loads(data)
        except Exception as exc:
            print(f"  api retry {i}: {url.split('/')[-1]} ({exc})")
            time.sleep(1.5)
    return None


def download(url: str, dest: str) -> str:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return "cached"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "lvx/1"})
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(data)
        return f"ok {len(data)//1024}KB"
    except Exception as exc:
        return f"skip ({exc.__class__.__name__})"


def fetch_model(name: str):
    info = http_json(f"{API}/files/{name}", f"/tmp/ph_files_{name}.json")
    if not info or "gltf" not in info:
        return [(None, os.path.join(OUT, "models", name + ".gltf"),
                 "skip (no gltf)")]
    res = info["gltf"]
    # Prefer 1k textures, else the smallest available.
    want = next((r for r in ("1k", "2k", "4k", "8k") if r in res),
                next(iter(res)))
    chosen = res[want]
    include = chosen.get("gltf", {}).get("include", {})
    jobs = []
    # The .gltf container sits at the bundle root; includes carry .bin + textures.
    root_url = chosen.get("gltf", {}).get("url")
    if root_url:
        jobs.append((name,
                     os.path.join(OUT, "models", name, f"{name}_{want}.gltf"),
                     root_url))
    for rel, meta in include.items():
        url = meta.get("url")
        if not url:
            continue
        dest = os.path.join(OUT, "models", name, rel)
        jobs.append((name, dest, url))
    if not jobs:
        return [(name, os.path.join(OUT, "models", name + ".gltf"),
                 "skip (empty)")]
    return jobs


def main() -> int:
    os.makedirs(OUT, exist_ok=True)

    # --- HDRIs ---
    hdri_jobs = []
    for name in DAY_HDRIS + NIGHT_HDRIS + SUNSET_HDRIS:
        hdri_jobs.append((f"HDRIs/hdr/1k/{name}_1k.hdr",
                          os.path.join(OUT, "hdri", f"{name}.hdr")))

    # --- Terrain textures ---
    tex_jobs = []
    for name in TERRAIN_TEXTURES:
        for m in ("diff", "nor_gl", "arm", "disp"):
            tex_jobs.append((f"Textures/jpg/1k/{name}/{name}_{m}_1k.jpg",
                             os.path.join(OUT, "textures", f"{name}_{m}.jpg")))

    # --- Models via files API ---
    model_jobs = []
    for name in MODELS:
        model_jobs.extend(fetch_model(name))

    all_jobs = [(None, d, f"https://dl.polyhaven.org/file/ph-assets/{p}")
                for p, d in hdri_jobs + tex_jobs] + model_jobs

    print(f"fetching {len(all_jobs)} files...")
    ok = skip = 0
    with cf.ThreadPoolExecutor(max_workers=12) as pool:
        futures = {pool.submit(download, url, dest): (name, dest)
                   for name, dest, url in all_jobs if url and url != "skip (empty)"}
        for fut in cf.as_completed(futures):
            name, dest = futures[fut]
            status = fut.result()
            rel = os.path.relpath(dest, OUT)
            if status.startswith(("ok", "cached")):
                ok += 1
            else:
                skip += 1
                print(f"  {status} {rel}")

    print(f"\ndone: {ok} fetched, {skip} unavailable")
    print("output:", OUT)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
