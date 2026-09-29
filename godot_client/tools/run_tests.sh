#!/bin/sh
# Runs the full Godot test suite headlessly.
# Usage: sh tools/run_tests.sh [path-to-godot-binary]
GODOT_BIN="${1:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd /tmp
GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
  --editor --quit >/dev/null 2>&1   # rebuild the class cache first
FAIL=0
for t in mesher_test world_test interaction_test render_settings_test \
    e2e_test features_test render_test zylann_test gameplay_test creature_test \
    crafting_ui_test engineering_test engineering_sim_test \
    engineering_world_test diagnostics_test multiplayer_test \
    robustness_test; do
  printf "%-15s " "$t"
  OUT=$(GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
    --script "res://tools/$t.gd" 2>&1 | grep -vE "fontconfig|Godot Engine")
  if echo "$OUT" | grep -q "PASS"; then
    echo "PASS"
  else
    echo "FAIL"
    echo "$OUT" | grep -iE "FAIL|ERROR" | head -5
    FAIL=1
  fi
done
exit $FAIL
