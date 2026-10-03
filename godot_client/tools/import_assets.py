#!/usr/bin/env python3
"""Batch-import the runtime asset tree into Godot, headlessly and reliably.

WHY THIS EXISTS
---------------
`godot --headless --import` cannot import more than one VRAM-compressed
texture per process in this environment. Reproduced on stock
Godot_v4.4-stable_linux.x86_64 with no GPU and no display:

  * one 512x512 texture with `compress/mode: 2`      -> imports in ~6 s
  * two 512x512 textures with `compress/mode: 2`     -> hangs indefinitely
  * the same two textures with `compress/mode: 0`    -> imports in ~8 s
  * running several hung processes in parallel      -> all of them hang

It is not size-dependent (16 px, 512, 1024 and 2048 px all hang on the second
file), it is not the `.import` settings block on its own, and it is not asset
volume: the default import settings, which resolve to `compress/mode: 0` in
headless, complete the whole tree without trouble.

So the fix is to give every file its own process. A Godot `.import` file and
its `.ctex` payload are named and addressed purely by the *res:// path*
(`<basename>-<md5(res://path)>.<ext>`), not by which project directory they
were produced in. A throwaway mirror project containing exactly one asset at
the same res:// path therefore emits byte-identical results, which this
script copies back into the real project.

The mirror must nest the asset under `assets/runtime/<relpath>`: payload md5
names, the `.import` `source_file` line and any `res://` paths an imported
scene records for its textures are all derived from the path *inside the
project*, so a mirror rooted at `assets/runtime` itself would bake
`res://models/...` into a project whose real path is
`res://assets/runtime/models/...`, and the harvested scene would then fail
to find its own textures.

Scene imports additionally need their sidecar files: a glTF references an
external `.bin` buffer and external image files by URI, and imports without
them produce a `valid=false` remap (or a scene whose materials have no
textures). The sidecar images are present in the mirror, but their
`compress/mode` is rewritten to `4` (uncompressed) so that the mirror's
inevitable cache-miss re-import of them cannot trigger the multi-VRAM-texture
deadlock; only the scene's own payloads are ever harvested back.

WHAT IT DOES
------------
For every file under `assets/runtime` that has no `.import` yet:

  1. build a mirror project at `/tmp/godot_import_mirror/` holding that one
     file at `assets/runtime/<relpath>`, plus sidecars for scenes, plus a
     `project.godot` carrying the real project's `[importer_defaults]`;
  2. run `godot --headless --path <mirror> --import` under a timeout;
  3. copy the generated `.import`, `.ctex` and `.md5` back into the project,
     fixing the `uid://` so it is stable and collision-free.

Import is idempotent and resumable: files that already have an `.import` are
skipped unless `--force` is given, so a run that is cut short by the shell
timeout simply picks up where it left off next time.

Usage:
    python3 tools/import_assets.py                # import everything missing
    python3 tools/import_assets.py --list         # report, import nothing
    python3 tools/import_assets.py --only rock_06 # just sets/models matching
    python3 tools/import_assets.py --force        # re-import everything
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
RUNTIME = os.path.join(PROJECT, "assets", "runtime")
MIRROR_ROOT = "/tmp/godot_import_mirror"
GODOT = os.environ.get("GODOT_BIN", "/tmp/Godot_v4.4-stable_linux.x86_64")

# Per-file wall-clock ceiling. A single VRAM-compressed texture takes ~6 s; 60 s
# is generous. The failure mode we are working around is a hang, so this bound
# is load-bearing rather than merely tidy: it is what keeps one bad file from
# stalling the whole batch.
PER_FILE_TIMEOUT = 60

# Extensions Godot imports as textures and therefore VRAM-compresses. .gltf and
# .hdr go through different importers (scene and image) and are handled by the
# same loop, but they are listed separately so the report can say what it did.
TEXTURE_EXT = (".jpg", ".jpeg", ".png", ".webp")
SCENE_EXT = (".gltf", ".glb")

SIDEcar_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"
uid="@UID@"

[deps]

source_file=""

[params]

compress/mode=4
compress/high_quality=false
compress/lossy_quality=0.7
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
"""
"""A not-yet-imported texture remap for a glTF sidecar, uncompressed."""
HDR_EXT = (".hdr", ".exr")


def res_path(rel_path):
    """The asset's real res:// path: everything hangs off assets/runtime."""
    return "assets/runtime/" + rel_path


def path_hash(rel_path):
    """The md5 Godot uses to name imported payloads: md5("res://" + relpath)."""
    return hashlib.md5(("res://" + res_path(rel_path)).encode("utf-8")).hexdigest()


def uid_for(rel_path):
    """A deterministic, *canonical* uid:// string derived from the asset path.

    Godot mints random uids and caches them in `.godot/uid_cache.bin`;
    re-deriving one from the path means every consumer -- a texture's own
    `.import` and any scene that references it -- agrees on the uid across
    machines and re-imports.

    The text form must be Godot's own canonical encoding or Godot
    re-encodes it on sight: `text_to_id` parses base 34 with a-z -> 0..24,
    '0'..'8' -> 25..33 ('z' and '9' decode to 25 and 34 but are never
    emitted), and `get_id_text` is the inverse. A non-canonical spelling of
    the same id (which is what a naive base36 encode produces) is silently
    replaced the moment a mirror imports the file, desynchronising a
    scene's texture references from the textures' own remaps.
    """
    digest = hashlib.sha1(("uid:" + res_path(rel_path)).encode("utf-8")).digest()
    idv = int.from_bytes(digest[:8], "big") & ((1 << 63) - 1)
    if idv == 0:
        idv = 1
    out = ""
    v = idv
    while v > 0:
        d = v % 34
        v //= 34
        if d <= 24:
            out = chr(ord("a") + d) + out
        elif d == 25:
            out = "0" + out
        else:
            out = chr(ord("1") + (d - 26)) + out
    return "uid://" + out


def read_importer_defaults():
    """Lift the `[importer_defaults]` block out of the real project.godot."""
    text = open(os.path.join(PROJECT, "project.godot")).read()
    m = re.search(r"\[importer_defaults\]\n\n(texture=\{.*?\n\})", text, re.S)
    if m is None:
        return ""
    return "\n[importer_defaults]\n\n" + m.group(1) + "\n"


def runtime_files():
    """Every importable file under assets/runtime, as paths relative to it."""
    out = []
    for base, _dirs, names in os.walk(RUNTIME):
        for name in sorted(names):
            if name.endswith(".import") or name.startswith("."):
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext in TEXTURE_EXT + SCENE_EXT + HDR_EXT:
                full = os.path.join(base, name)
                out.append((os.path.relpath(full, RUNTIME), full))
    return sorted(out)


def scene_sidecars(rel_path, source):
    """External files a .gltf/.glb references by URI, relative to its folder.

    Buffers (.bin) are inert data; images (.jpg/.png) are importable files,
    so their `.import` is copied across with `compress/mode=4` and the uid the
    real project will derive for them. That keeps the mirror's re-import of
    them deadlock-free and makes any uid the scene records agree with the
    uid the texture's own harvest will write.
    """
    ext = os.path.splitext(source)[1].lower()
    if ext == ".glb":
        return []                      # .glb embeds its buffer
    try:
        doc = json.load(open(source))
    except (ValueError, OSError):
        return []
    uris = []
    for buf in doc.get("buffers", []):
        if isinstance(buf.get("uri"), str):
            uris.append(buf["uri"])
    for img in doc.get("images", []):
        if isinstance(img.get("uri"), str):
            uris.append(img["uri"])
    # A glTF can list the same external image under both `buffers` and
    # `images`, which would yield duplicate sidecars and abort `build_mirror`
    # with FileExistsError. Deduplicate on the project-relative path.
    seen = set()
    out = []
    folder = os.path.dirname(source)
    for uri in uris:
        if "://" in uri or uri.startswith("data:"):
            continue
        sidecar = os.path.normpath(os.path.join(folder, uri))
        if not sidecar.startswith(folder + os.sep) or not os.path.isfile(sidecar):
            continue
        rel = os.path.relpath(sidecar, RUNTIME).replace(os.sep, "/")
        if rel in seen:
            continue
        seen.add(rel)
        out.append((uri, sidecar))
    return out


def build_mirror(rel_path, source, mirror):
    if os.path.isdir(mirror):
        shutil.rmtree(mirror)
    # The full project-relative layout, so res:// inside the mirror is
    # byte-for-byte the res:// the real project will use.
    dest = os.path.join(mirror, "assets", "runtime", rel_path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    # Symlink rather than copy: a 2 MB PNG copied 180 times is 360 MB of
    # pointless I/O, and the mirror is rebuilt for every file anyway.
    os.symlink(source, dest)

    if os.path.splitext(source)[1].lower() in SCENE_EXT:
        for uri, sidecar in scene_sidecars(rel_path, source):
            side_dest = os.path.join(os.path.dirname(dest), uri)
            os.makedirs(os.path.dirname(side_dest), exist_ok=True)
            os.symlink(sidecar, side_dest)
            # Importable sidecar images: carry their .import over in
            # deadlock-free form so the mirror re-imports them losslessly.
            side_rel = os.path.relpath(sidecar, RUNTIME).replace(os.sep, "/")
            side_import = sidecar + ".import"
            if os.path.isfile(side_import):
                body = open(side_import).read()
                body = re.sub(r"compress/mode=\d+", "compress/mode=4", body)
                # uid of the sidecar as the real project will know it.
                body = re.sub(r'uid="uid://[^"]+"',
                              'uid="%s"' % uid_for(side_rel), body)
            else:
                # A sidecar the project has not imported yet has no .import,
                # so the mirror would fall back to the real project's
                # `[importer_defaults]` -- `compress/mode: 2` -- and import
                # *every* sidecar in the mirror under VRAM compression. That is
                # the deadlock this whole script exists to avoid, and it is why
                # a prop's first glTF import used to hang: the barrel mesh
                # references nine textures, so the mirror would deadlock on
                # the second one and time out on the whole prop.
                #
                # An .import with no `dest_files` and a params block is what
                # Godot itself writes before a file has been imported: the
                # mirror imports it once, uncompressed, and the real project
                # gets the VRAM-compressed .ctex from the sidecar's own
                # dedicated run in this same script.
                body = (SIDEcar_TEMPLATE
                        .replace("@UID@", uid_for(side_rel)))
            with open(side_dest + ".import", "w") as fh:
                fh.write(body)

    with open(os.path.join(mirror, "project.godot"), "w") as fh:
        fh.write('config_version=5\n\n[application]\n\nconfig/name="import_mirror"\n')
        fh.write(read_importer_defaults())


def harvest(rel_path, mirror):
    """Copy the mirror's import output back into the project.

    Returns (ok, message). A false ok means the file could not be merged even
    though the mirror produced output, which is a bug here rather than a
    limitation of the engine. A remap that is `valid=false` or that declares
    no `dest_files` is a failed import wearing an `.import` file's clothes,
    and must not be merged: an earlier version of this script accepted a
    bare `.md5` stub as a payload and shipped broken scene remaps.
    """
    # The payload is named "<basename>-<md5>.<ext>" including the source
    # extension, so the prefix has to be the full basename, not the stem.
    stem = os.path.basename(rel_path)
    h = path_hash(rel_path)

    mirror_import = os.path.join(mirror, "assets", "runtime",
                                 rel_path + ".import")
    if not os.path.isfile(mirror_import):
        return False, "mirror produced no .import"

    body = open(mirror_import).read()
    if "valid=false" in body:
        return False, "mirror remap is valid=false (import failed)"
    if ('source_file="res://%s"' % res_path(rel_path)) not in body:
        return False, "mirror remap has the wrong source_file"
    dest = re.findall(r'res://\.godot/imported/([^"]+)', body)
    if not dest:
        return False, "mirror remap declares no dest_files"

    body = re.sub(r'uid="uid://[^"]+"', 'uid="%s"' % uid_for(rel_path), body)
    target_import = os.path.join(RUNTIME, rel_path + ".import")
    with open(target_import, "w") as fh:
        fh.write(body)

    imported_dir = os.path.join(PROJECT, ".godot", "imported")
    os.makedirs(imported_dir, exist_ok=True)
    payload = os.path.join(mirror, ".godot", "imported")
    if not os.path.isdir(payload):
        return False, "mirror produced no .godot/imported"
    moved = 0
    for name in os.listdir(payload):
        # Only the payloads belonging to this file; a glTF mirror also holds
        # its sidecar images' payloads, which belong to the texture jobs.
        if not name.startswith(stem + "-"):
            continue
        shutil.move(os.path.join(payload, name),
                    os.path.join(imported_dir, name))
        moved += 1
    if moved == 0:
        return False, "mirror .godot/imported held no payload for %s" % h
    for name in dest:
        full = os.path.join(imported_dir, os.path.basename(name))
        if not os.path.isfile(full) or os.path.getsize(full) == 0:
            return False, "dest payload missing after merge: %s" % name
    return True, "%d payload(s)" % moved


def already_imported(source, rel_path):
    """True when both the `.import` file and its payload are already in place.

    Checking only for the `.import` file is not enough. A run that is killed
    partway through leaves the `.import` file behind with an empty or absent
    `.ctex`, which `ResourceLoader` then reports as "exists" and the material
    silently falls back to a broken texture. Godot would repair that on its next
    editor scan; this script has to, because the whole point of it is that
    Godot cannot be trusted to finish a headless import here.
    The `source_file` check also rejects remaps harvested from a mirror that
    was not nested under assets/runtime: their payload md5 names and any
    scene's texture paths were derived from the wrong res:// root, so they
    must be re-imported even though they look complete.
    """
    import_file = source + ".import"
    if not os.path.isfile(import_file):
        return False
    body = open(import_file).read()
    if ('source_file="res://%s"' % res_path(rel_path)) not in body:
        return False
    if 'uid="%s"' % uid_for(rel_path) not in body:
        # A remap minted under an older uid scheme (or a random one) would
        # make every scene that references this asset spell its uid
        # differently; re-import normalises it to the canonical form.
        return False
    if "valid=false" in body:
        return False
    names = re.findall(r'res://\.godot/imported/([^"]+)', body)
    if not names:
        return False
    imported_dir = os.path.join(PROJECT, ".godot", "imported")
    for name in names:
        full = os.path.join(imported_dir, os.path.basename(name))
        if not os.path.isfile(full) or os.path.getsize(full) == 0:
            return False
    return True


def import_one(job):
    """Import one asset in its own mirror project and merge the result back."""
    index, rel_path, source, dry_run = job
    if dry_run:
        return rel_path, True, "would import"
    mirror = "%s/w%d" % (MIRROR_ROOT, index)
    build_mirror(rel_path, source, mirror)
    proc = subprocess.run(
        [GODOT, "--headless", "--path", mirror, "--import"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=PER_FILE_TIMEOUT)
    # A malformed glTF can abort this process with SIGABRT: an invalid mesh
    # index such as "Index gltf_node->mesh = N is out of bounds". Nothing was
    # imported at all -- treat it as a skipped file and let a follow-up
    # re-run retry it; a plain failed import (non-zero exit, no abort) is
    # also reported as failed.
    if proc.returncode == -6:
        return rel_path, False, "godot aborted (SIGABRT), no payload"
    if proc.returncode != 0:
        return rel_path, False, "godot exited %d" % proc.returncode
    good, msg = harvest(rel_path, mirror)
    shutil.rmtree(mirror, ignore_errors=True)
    return rel_path, good, msg


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--list", action="store_true",
                    help="report what would be imported and exit")
    ap.add_argument("--only", nargs="*", default=None,
                    help="only paths containing one of these substrings")
    ap.add_argument("--force", action="store_true",
                    help="re-import files that already have an .import")
    ap.add_argument("--timeout", type=int, default=PER_FILE_TIMEOUT,
                    help="per-file wall-clock ceiling in seconds")
    ap.add_argument("--jobs", type=int, default=1,
                    help="how many mirror projects to import concurrently. "
                         "Defaults to 1 and should stay there here: the "
                         "sandbox is a single-CPU cgroup, parallel Godot "
                         "imports stall each other and timed-out batches "
                         "leave orphans that collide with the next run.")
    args = ap.parse_args()
    globals()["PER_FILE_TIMEOUT"] = args.timeout

    if not os.path.isfile(GODOT):
        sys.exit("godot binary not found at %s (set GODOT_BIN)" % GODOT)

    todo = []
    for rel_path, full in runtime_files():
        if args.only and not any(s in rel_path for s in args.only):
            continue
        if not args.force and already_imported(full, rel_path):
            continue
        source = full
        # A failed scene import leaves a half-baked `.import`: the mirror that
        # produced it was rooted at `assets/runtime` instead of
        # `assets/runtime/<relpath>`, so its `source_file` reads
        # `res://models/...` and its `uid=` is the non-canonical base36 form.
        # `already_imported()` correctly rejects it, but re-importing by
        # symlinking straight onto the already-existing asset file raises
        # FileExistsError and aborts the whole batch. Repair it first: drop the
        # bad manifest and any scene payloads it left behind.
        if os.path.isfile(source + ".import"):
            body = open(source + ".import").read()
            if (
                ('source_file="res://%s"' % res_path(rel_path)) not in body
                or uid_for(rel_path) not in body
                or "valid=false" in body
            ):
                os.remove(source + ".import")
                imported_dir = os.path.join(PROJECT, ".godot", "imported")
                if os.path.isdir(imported_dir):
                    for name in os.listdir(imported_dir):
                        if name.startswith(os.path.basename(rel_path) + "-"):
                            try:
                                os.remove(os.path.join(imported_dir, name))
                            except OSError:
                                pass
        todo.append((rel_path, full))

    print("%d file(s) to import, %d total under assets/runtime"
          % (len(todo), len(runtime_files())))
    if args.list:
        for rel_path, _ in todo:
            print("  " + rel_path)
        return

    ok = 0
    failed = []
    # ThreadPoolExecutor rather than processes: the work here is a subprocess
    # wait, and each job owns a distinct mirror directory, so the only shared
    # state is the project directory each merge writes into -- and each merge
    # writes its own files, named by path hash, so they cannot collide.
    jobs = [(i, rel_path, full, False) for i, (rel_path, full) in enumerate(todo)]
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for done, future in enumerate(
                [pool.submit(import_one, job) for job in jobs], 1):
            try:
                rel_path, good, msg = future.result()
            except subprocess.TimeoutExpired:
                good, msg = False, "timeout after %ds" % PER_FILE_TIMEOUT
                rel_path = "?"
            except Exception as exc:                   # noqa: BLE001
                good, msg = False, "%s: %s" % (type(exc).__name__, exc)
                rel_path = "?"
            print("[%3d/%3d] %-64s %s" % (done, len(todo), rel_path,
                                           "ok" if good else "FAILED: " + msg))
            if good:
                ok += 1
            else:
                failed.append(rel_path)

    print("\n%d imported, %d failed" % (ok, len(failed)))
    for rel_path in failed:
        print("  " + rel_path)
    if failed:
        # Not a hard exit: the caller usually wants the report even when a
        # handful of files need attention, and re-running resumes.
        sys.exit(1)


if __name__ == "__main__":
    main()