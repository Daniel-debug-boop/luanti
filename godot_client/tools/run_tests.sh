#!/bin/sh
# Runs the full Godot test suite headlessly.
# Usage: sh tools/run_tests.sh [path-to-godot-binary]
GODOT_BIN="${1:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd /tmp
# Import assets and rebuild the class cache. Without this the imported/ cache is
# empty and every suite that touches a texture or sound fails with
# "Make sure resources have been imported" -- which is a setup failure, not a
# regression. --import is the supported headless import pass; --editor --quit
# does not import reliably.
GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
  --import >/dev/null 2>&1

# e2e_test reads a converted world from a fixed path. Generate it if absent so
# the suite is runnable on a clean checkout.
if [ ! -d /tmp/testchunks ]; then
  if python3 -c "import zstandard" >/dev/null 2>&1; then
    rm -rf /tmp/testworld /tmp/testchunks
    python3 "$DIR/tools/make_test_world.py" /tmp/testworld >/dev/null 2>&1 &&
    python3 "$DIR/tools/convert_world.py" /tmp/testworld /tmp/testchunks \
      >/dev/null 2>&1
  else
    echo "note: python 'zstandard' module missing -- e2e_test needs its" \
         "converted-world fixture and will be skipped." >&2
  fi
fi
FAIL=0
for t in mesher_test seam_test chunk_format_test player_physics_test world_test \
    interaction_test render_settings_test \
    e2e_test features_test render_test zylann_test gameplay_test creature_test \
    crafting_ui_test engineering_test engineering_sim_test \
    engineering_world_test diagnostics_test render_diagnostics_test \
    adaptive_quality_test multiplayer_test \
    robustness_test architecture_test systems_test ui_test render_test_test \
    emergent_test playable_test asset_test; do
  printf "%-22s " "$t"
  # A suite passes when it prints a verdict line at column 0 (`mesher: PASS`,
  # `asset: N checks, 0 FAILURES`) and reports no failure marker anywhere.
  #
  # Both halves are needed, and both were arrived at by getting it wrong:
  # grepping for the literal word PASS cannot see asset_test, which prints
  # `N checks, 0 FAILURES` and was reported red while green; and matching only
  # failure markers reports a suite green when it crashed before printing
  # anything at all. Per-assertion `ok`/`FAIL` lines are indented, so anchoring
  # the verdict to column 0 does not match them.
  OUT=$(GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
    --script "res://tools/$t.gd" 2>&1 | grep -vE "fontconfig|Godot Engine")
  if echo "$OUT" | grep -qE "^[A-Za-z][A-Za-z0-9_ -]*: (PASS|[0-9]+ checks, 0 FAILURES)" \
     && ! echo "$OUT" | grep -qE "^FAIL: |RESULT: FAIL|[1-9][0-9]* FAILURES|FAILURES \("; then
    echo "PASS"
  else
    echo "FAIL"
    echo "$OUT" | grep -iE "^ *FAIL|RESULT:|SCRIPT ERROR" | head -5
    FAIL=1
  fi
done
exit $FAIL
