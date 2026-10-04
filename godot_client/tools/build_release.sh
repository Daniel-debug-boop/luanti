#!/bin/sh
# Build a ready-to-play Linux release of LuantiVoxel.
#
# Usage: sh tools/build_release.sh [path-to-godot-binary]
#
# Produces, in ../build/luantivoxel/:
#   luantivoxel.x86_64   the game
#   luantivoxel.pck      its data
#   luantivoxel-linux-x86_64.tar.gz   both, for download
#   luantivoxel-linux-x86_64.tar.gz.sha256
#
# Requires the Godot 4.4 export templates. If they are missing the script says
# so and stops, rather than exporting a broken half-package.
set -e

GODOT_BIN="${1:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/../build/luantivoxel"
VERSION="$(cat "$DIR/../VERSION_LUANTIVOXEL" 2>/dev/null || echo dev)"

if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
  echo "error: no Godot binary at '$GODOT_BIN'." >&2
  echo "Pass one: sh tools/build_release.sh /path/to/godot" >&2
  exit 1
fi

# Export templates live in a version-named subdirectory, which is the single
# most common reason an export fails with "No export template found".
TEMPLATE_DIR="$HOME/.local/share/godot/export_templates/4.4.stable"
if [ ! -f "$TEMPLATE_DIR/linux_release.x86_64" ]; then
  echo "error: Godot 4.4 export templates are not installed." >&2
  echo "Download Godot_v4.4-stable_export_templates.tpz from" >&2
  echo "https://github.com/godotengine/godot/releases/tag/4.4-stable" >&2
  echo "and unzip linux_release.x86_64 into:" >&2
  echo "  $TEMPLATE_DIR" >&2
  exit 1
fi

echo "==> Importing assets (first run only; this is the slow part)"
GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
  --import >/dev/null 2>&1 || true

# Stamp the version into the project before exporting. VERSION_LUANTIVOXEL is
# the single source: without this step the archive is named one version and
# the binary it contains reports none at all, so a bug report cannot name the
# build it came from. The stamp is a literal-line replacement, and the result
# is checked, because a silent no-op here would export the previous version.
if [ -f "$DIR/../VERSION_LUANTIVOXEL" ]; then
  echo "==> Stamping version $VERSION into project.godot"
  sed -i "s|^config/version=.*|config/version=\"$VERSION\"|" \
    "$DIR/project.godot"
  grep -q "^config/version=\"$VERSION\"$" "$DIR/project.godot" || {
    echo "error: version stamp did not take in project.godot" >&2
    exit 1
  }
fi

echo "==> Exporting Linux release"
mkdir -p "$OUT"
rm -f "$OUT"/luantivoxel.x86_64 "$OUT"/luantivoxel.pck "$OUT"/*.tar.gz*
GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
  --export-release "Linux" "$OUT/luantivoxel.x86_64"

[ -f "$OUT/luantivoxel.x86_64" ] || {
  echo "error: export produced no executable." >&2
  exit 1
}
[ -f "$OUT/luantivoxel.pck" ] || {
  echo "error: export produced no .pck -- the game would start and" \
       "immediately fail to find its content." >&2
  exit 1
}
chmod +x "$OUT/luantivoxel.x86_64"

echo "==> Smoke test: the exported game must reach 'ready' without errors"
LOG="$(cd "$OUT" && GODOT_SILENCE_ROOT_WARNING=1 ./luantivoxel.x86_64 \
  --headless --quit-after 200 2>&1 || true)"
echo "$LOG" | grep -q "\[main\] ready in" || {
  echo "error: the exported game did not reach a ready state:" >&2
  echo "$LOG" | tail -20 >&2
  exit 1
}
# A script that fails to compile prints a SCRIPT ERROR and carries on, so a
# clean "ready" line is not by itself proof the build is sound.
if echo "$LOG" | grep -q "SCRIPT ERROR"; then
  echo "error: the exported game logged script errors:" >&2
  echo "$LOG" | grep "SCRIPT ERROR" | head -5 >&2
  exit 1
fi
echo "    ok: reached ready with no script errors"

echo "==> Packaging"
ARCHIVE="luantivoxel-$VERSION-linux-x86_64.tar.gz"
# Pack into a named directory rather than flat, so unpacking gives
# luantivoxel-<version>/ rather than scattering three files into the cwd.
STAGE="$(mktemp -d)"
STAGE_DIR="$STAGE/luantivoxel-$VERSION"
mkdir -p "$STAGE_DIR"
cp "$OUT/luantivoxel.x86_64" "$OUT/luantivoxel.pck" \
  "$DIR/PLAY_README.txt" "$STAGE_DIR/"
mv "$STAGE_DIR/PLAY_README.txt" "$STAGE_DIR/README.txt"
# A player who unzips and double-clicks needs the executable bit to survive.
chmod +x "$STAGE_DIR/luantivoxel.x86_64"
( cd "$STAGE" && tar czf "$OUT/$ARCHIVE" "luantivoxel-$VERSION" )
rm -rf "$STAGE"
# Prove the archive is real rather than assuming the tar succeeded: it must
# contain the executable, the data and the instructions.
MISSING=""
for want in luantivoxel.x86_64 luantivoxel.pck README.txt; do
  tar tzf "$OUT/$ARCHIVE" | grep -q "/$want$" || MISSING="$MISSING $want"
done
if [ -n "$MISSING" ]; then
  echo "error: archive is missing:$MISSING" >&2
  exit 1
fi
( cd "$OUT" && sha256sum "$ARCHIVE" > "$ARCHIVE.sha256" )

echo
echo "Done. In $OUT:"
ls -la "$OUT" | sed 's/^/  /'
echo
echo "To play:   tar xzf $ARCHIVE"
echo "           cd luantivoxel-$VERSION"
echo "           ./luantivoxel.x86_64"
