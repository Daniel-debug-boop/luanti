#!/bin/sh
# WorldStream build, end to end.
#
# Builds, in order:
#   1. godot-cpp, from the profile in worldstream/ws_build_profile.json
#   2. worldstream_core  -- H3 grid, vector-tile parsing, meshing
#   3. worldstream_tests -- the native unit suite, run as part of the build
#   4. libworldstream.*.so in ws_build/bin, the GDExtension the client loads
#
# Usage:
#   sh ws_build/build.sh                 # everything
#   sh ws_build/build.sh --no-extension  # core + tests only
#   sh ws_build/build.sh --full-godotcpp # do not trim the godot-cpp bindings
#
# RESUMABLE. Every stage is incremental and every artifact is checked before
# its stage runs, so the script can be interrupted (or killed by a time limit)
# and re-run: it continues where it stopped rather than starting over. That is
# not a nicety here -- a full godot-cpp build is the long pole, and on a
# single-core machine it will be interrupted.
#
# It does not fetch anything. The dependencies are pinned submodules: a build
# either has its sources or fails with the command that would get them.
set -e

DIR=$(cd "$(dirname "$0")/.." && pwd)      # godot_client
ROOT=$(cd "$DIR/.." && pwd)                # repository root
WS="$DIR/worldstream"
BUILD="$DIR/ws_build"
BIN="$BUILD/bin"
# The status log lives at the project root, next to ws_build/, and is the file
# the worldstream push already carried: one log, appended to by the build that
# produces the artifacts rather than a second one beside it.
STATUS="$DIR/ws_build_status.log"
PROFILE="$WS/ws_build_profile.json"

JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
WANT_EXTENSION=1
TRIM=1

for arg in "$@"; do
	case "$arg" in
		--no-extension) WANT_EXTENSION=0 ;;
		--full-godotcpp) TRIM=0 ;;
		--jobs=*) JOBS="${arg#--jobs=}" ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

say() { echo "ws_build: $*"; }
mark() { grep -qxF "$1" "$STATUS" 2>/dev/null || echo "$1" >> "$STATUS"; }

command -v cmake >/dev/null 2>&1 || {
	echo "ws_build: cmake not found. Install it (pip install cmake) and re-run." >&2
	exit 1
}

mkdir -p "$BIN"
say "project $DIR, jobs $JOBS"

# --- 0. sources -------------------------------------------------------------
# The submodules carry the pinned revisions the build expects. They are
# initialized here rather than fetched, so a checkout with network access gets
# the exact revisions and an offline one fails with a specific message.
if [ ! -f "$DIR/godot-cpp/CMakeLists.txt" ]; then
	say "initializing godot-cpp submodule..."
	git -C "$ROOT" submodule update --init --depth 1 godot_client/godot-cpp
fi
for dep in h3 meshoptimizer protozero vtzero spz; do
	if [ ! -d "$WS/third_party/$dep/.git" ] && [ ! -f "$WS/third_party/$dep/CMakeLists.txt" ]; then
		say "initializing third_party/$dep submodule..."
		git -C "$ROOT" submodule update --init --depth 1 \
			"godot_client/worldstream/third_party/$dep"
	fi
done

# --- 1..4. one cmake tree ---------------------------------------------------
CONFIG_ARGS="-DCMAKE_BUILD_TYPE=Template_Release -DWS_BUILD_TESTS=ON"
if [ "$WANT_EXTENSION" = "1" ]; then
	CONFIG_ARGS="$CONFIG_ARGS -DWS_BUILD_GDEXTENSION=ON"
else
	CONFIG_ARGS="$CONFIG_ARGS -DWS_BUILD_GDEXTENSION=OFF"
fi

say "configuring ($([ "$WANT_EXTENSION" = 1 ] && echo "with" || echo "without") extension)"
# shellcheck disable=SC2086
cmake -S "$WS" -B "$BUILD/worldstream" $CONFIG_ARGS >"$BUILD/cfg.log" 2>&1 || {
	tail -20 "$BUILD/cfg.log" >&2
	exit 1
}

if [ "$WANT_EXTENSION" = "1" ]; then
	if [ ! -f "$BUILD/worldstream/bin/libgodot-cpp.linux.template_release.x86_64.a" ]; then
		say "building godot-cpp ($([ "$TRIM" = 1 ] && echo "trimmed profile" || echo "full bindings"))"
		if [ "$TRIM" = 0 ]; then
			# An untrimmed build regenerates the whole API; the profile file
			# is not consulted, which is the only difference.
			cmake -S "$WS" -B "$BUILD/worldstream" $CONFIG_ARGS \
				-DGODOTCPP_BUILD_PROFILE="" >/dev/null 2>&1
		fi
		cmake --build "$BUILD/worldstream" -j "$JOBS" \
			--target godot-cpp.template_release >>"$BUILD/build.log" 2>&1 || {
			tail -20 "$BUILD/build.log" >&2
			exit 1
		}
	fi
	mark GODOTCPP_BUILD_DONE
	mark GODOTCPP_LIB_DONE
	say "godot-cpp ready"
fi

TARGETS="worldstream_core worldstream_tests"
[ "$WANT_EXTENSION" = "1" ] && TARGETS="$TARGETS worldstream"
say "building: $TARGETS"
# shellcheck disable=SC2086
cmake --build "$BUILD/worldstream" -j "$JOBS" --target $TARGETS \
	>>"$BUILD/build.log" 2>&1 || {
	tail -20 "$BUILD/build.log" >&2
	exit 1
}
mark WORLDSTREAM_CORE_DONE

# --- 5. native tests --------------------------------------------------------
say "running the native suite"
if "$BUILD/worldstream/worldstream_tests"; then
	mark WORLDSTREAM_TESTS_PASS
else
	echo "ws_build: native tests FAILED" >&2
	exit 1
fi

# --- 6. artifacts -----------------------------------------------------------
LIB="$BIN/libworldstream.linux.template_release.x86_64.so"
if [ "$WANT_EXTENSION" = "1" ]; then
	[ -f "$LIB" ] || { echo "ws_build: expected library $LIB was not produced" >&2; exit 1; }
	mark WORLDSTREAM_LIB_DONE
	say "extension: $(ls -l "$LIB" | awk '{print $NF, $5, "bytes"}')"
	say "Godot loads it through addons/worldstream/worldstream.gdextension"
else
	say "extension skipped (--no-extension)"
fi
say "done. status: $STATUS"
