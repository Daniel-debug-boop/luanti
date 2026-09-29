#!/bin/sh
# Downloads the official Voxel Tools engine build.
#
# WHY THIS EXISTS
#   Voxel Tools (github.com/Zylann/godot_voxel) is a C++ module. It is NOT
#   usable as a GDExtension on Godot 4.4-stable: every published
#   GodotVoxelExtension.zip declares `compatibility_minimum = "4.4.1"`, and
#   4.4-stable reports itself as 4.4.0, so Godot silently skips loading it
#   (verified: ClassDB.class_exists("VoxelTerrain") == false, no error printed).
#
#   The supported route is the module build published by the project itself.
#   Release v1.4.0 is built from Godot commit 4c311cbee -- the exact same
#   engine commit as stock 4.4-stable -- with Voxel Tools 1.4.0 compiled in.
#   Verified working: VoxelTerrain, VoxelLodTerrain, VoxelInstancer,
#   VoxelMesherBlocky, VoxelGeneratorScript, VoxelStreamRegionFiles.
#
# Usage:  sh tools/fetch_voxel_engine.sh [dest-dir]
# Prints the path of the binary on success.
set -e

DEST="${1:-/tmp/voxel-engine}"
URL="https://github.com/Zylann/godot_voxel/releases/download/v1.4.0/godot.linuxbsd.editor.x86_64.zip"
BIN_NAME="godot.linuxbsd.editor.x86_64"
EXPECTED_COMMIT="4c311cbee"

mkdir -p "$DEST"
BIN="$DEST/$BIN_NAME"

if [ -x "$BIN" ]; then
	echo "already present: $BIN"
	echo "$BIN"
	exit 0
fi

ZIP="$DEST/godot.zip"
echo "downloading Voxel Tools engine (~60 MB)..."
if command -v curl >/dev/null 2>&1; then
	curl -fsSL -o "$ZIP" "$URL"
else
	wget -q -O "$ZIP" "$URL"
fi

echo "extracting..."
if command -v unzip >/dev/null 2>&1; then
	unzip -oq "$ZIP" -d "$DEST"
else
	python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$DEST"
fi
rm -f "$ZIP"
chmod +x "$BIN"

# Fail loudly if this is not the build we expect.
VER="$("$BIN" --version 2>/dev/null | tail -1)"
case "$VER" in
	*"custom_build"*"$EXPECTED_COMMIT"*) ;;
	*)
		echo "ERROR: unexpected engine build: $VER" >&2
		echo "expected a custom_build containing $EXPECTED_COMMIT" >&2
		exit 1
		;;
esac

echo "ok: $VER"
echo "$BIN"
