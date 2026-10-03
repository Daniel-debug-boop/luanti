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
    robustness_test architecture_test systems_test playable_test \
    asset_test; do
  printf "%-15s " "$t"
  # A suite is red when it says so, and green otherwise. The runner used to
  # grep for the literal word PASS, which only ever worked for the suites that
  # happen to print it -- asset_test reports `N checks, 0 FAILURES` and was
  # read as a failure while it was green. Each suite reports failures in one of
  # three shapes, and all three are matched here:
  #   * `FAIL: <what>` on stderr, from the check helpers,
  #   * `RESULT: FAIL (n)`, from the suites that print a summary line,
  #   * `N FAILURES` with a non-zero N, from the summary line of the rest.
  # The count has to be matched as `[1-9][0-9]*` rather than the bare word:
  # asset_test's green line also contains "FAILURES", as `0 FAILURES`, and a
  # plain `FAILURES` match reports that green suite red.
  OUT=$(GODOT_SILENCE_ROOT_WARNING=1 "$GODOT_BIN" --headless --path "$DIR" \
    --script "res://tools/$t.gd" 2>&1 | grep -vE "fontconfig|Godot Engine")
  if echo "$OUT" | grep -qE "^FAIL: |RESULT: FAIL|[1-9][0-9]* FAILURES|FAILURES \("; then
    echo "FAIL"
    echo "$OUT" | grep -iE "^ *FAIL|RESULT:|SCRIPT ERROR" | head -5
    FAIL=1
  else
    echo "PASS"
  fi
done
exit $FAIL
