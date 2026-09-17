#!/usr/bin/env bash
# Runs every claim in examples/animated-water/README.md against a real Godot 4
# binary, with the real TileSets and demo scene, in a throwaway project.
#
#   examples/animated-water/verify_animated_water.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/animated-water/verify_animated_water.sh /path/to/godot --invert   # must exit 1
#
# Cannot use --headless: W11/W12 read the animation frame on screen back from a
# rendered SubViewport, and the headless dummy renderer returns no image. It asks
# for a real GL context on a virtual X server (xvfb-run) and runs at --fixed-fps 60,
# so a 0.2 s frame is exactly 12 rendered frames. --audio-driver Dummy: on a
# machine with no sound card the ALSA driver prints an ERROR line W2 would count.
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# W1 and W2 are counted here, not in the script: they are about the engine's
# ERROR lines, which GDScript cannot read.
#
# Exit: 0 all pass, 1 any FAIL, 2 usage, 3 the script did not finish.
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
set -uo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary [--invert]" >&2
  exit 2
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found: W11/W12 are about what is rendered and cannot be" >&2
  echo "measured on the headless (dummy) renderer." >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithAnimatedWaterCheck"
EOF
mkdir "$PROJ/animated-water"
cp "$HERE"/*.png "$HERE"/*.tres "$HERE/animated_water_demo.tscn" "$HERE/manifest.json" "$PROJ/animated-water/"
cp "$HERE/verify_animated_water.gd" "$PROJ/verify_animated_water.gd"
shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

# W1: the demo scene run as a game for 60 frames
RUN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --quit-after 60 res://animated-water/animated_water_demo.tscn 2>&1)"
OUT="$(timeout 300 xvfb-run -a -s "-screen 0 640x480x24" \
  "$GODOT" --rendering-driver opengl3 --audio-driver Dummy --fixed-fps 60 --path "$PROJ" --script verify_animated_water.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |NOTE |ANIMATED WATER)'

if ! printf '%s\n' "$OUT" | grep -q '^ANIMATED WATER: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

W_FAIL=0
E1="$(printf '%s\n' "$RUN" | grep -cE 'ERROR')"
if [ "$E1" = "0" ]; then
  echo "PASS W1  animated_water_demo.tscn run as the main scene for 60 frames prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL W1  animated_water_demo.tscn run for 60 frames printed $E1 ERROR lines:"; printf '%s\n' "$RUN" | grep -E 'ERROR' | head -5; W_FAIL=1
fi
E2="$(printf '%s\n' "$OUT" | grep -cE 'ERROR')"
if [ "$E2" = "0" ]; then
  echo "PASS W2  the verification run (both TileSets, paint, controls, rendered frames, demo) prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL W2  the verification run printed $E2 ERROR lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR' | head -5; W_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
[ "$W_FAIL" -eq 0 ] || exit 1
printf '%s\n' "$OUT" | grep -q '^ANIMATED WATER: ALL PASS' || exit 1
exit 0
