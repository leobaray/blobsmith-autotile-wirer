#!/usr/bin/env bash
# Runs every claim in docs/why-my-animated-tile-does-not-animate.md against a
# real Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_tile_animation.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Cannot use --headless: which animation frame is showing is read back from a
# rendered SubViewport, and the headless dummy renderer returns no image. It asks
# for a real GL context on a virtual X server, and runs with --fixed-fps 60 so
# engine time advances exactly 1/60 s per rendered frame — durations are counted
# in frames, not wall-clock time.
#
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# Needs Godot 4.3 or newer: TileMapLayer does not exist in 4.2.
set -uo pipefail

GODOT="${1:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "usage: $0 /path/to/godot-binary" >&2
  exit 2
fi
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found: these claims are about what is rendered and" >&2
  echo "cannot be measured on the headless (dummy) renderer." >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithTileAnimationCheck"
EOF
cp "$HERE/verify_tile_animation.gd" "$PROJ/verify_tile_animation.gd"

run() {
  timeout 180 xvfb-run -a -s "-screen 0 640x480x24" \
    "$GODOT" --rendering-driver opengl3 --fixed-fps 60 --path "$PROJ" --script verify_tile_animation.gd 2>&1
}

OUT="$(run)"
echo "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |TILE ANIMATION)'

if ! printf '%s\n' "$OUT" | grep -q '^TILE ANIMATION: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# E1/E2: both refusals print an engine error — and E1's names the wrong property.
# K2 is the control: the same setup without the refused call prints neither.
E_FAIL=0
probe() {
  local out
  out="$(LG_ANIMPROBE="$1" run)"
  printf '%s\n' "$out" | grep -q '^ANIMPROBE DONE' || { echo "ERROR: probe '$1' did not finish" >&2; exit 3; }
  printf '%s\n' "$out"
}
OCC="$(probe occupied)"
SPD="$(probe speed0)"
CTL="$(probe none)"
if printf '%s\n' "$OCC" | grep -q '^ERROR: Cannot set animation columns count, tiles are already present'; then
  echo "PASS  E1 refused frames_count prints 'Cannot set animation columns count' (says columns, the call was frames_count)"
else
  echo "FAIL  E1 refused frames_count did not print the columns-count error"; E_FAIL=1
fi
if printf '%s\n' "$SPD" | grep -q '^ERROR: Condition "p_speed <= 0" is true'; then
  echo "PASS  E2 set_tile_animation_speed(0) prints 'Condition \"p_speed <= 0\" is true'"
else
  echo "FAIL  E2 set_tile_animation_speed(0) did not print the p_speed error"; E_FAIL=1
fi
if printf '%s\n' "$CTL" | grep -qE '^ERROR: (Cannot set animation|Condition "p_speed)'; then
  echo "FAIL  K2 control: the setup alone printed one of those errors"; E_FAIL=1
else
  echo "PASS  K2 control: the same setup without the refused call prints neither error"
fi

printf '%s\n' "$OUT" | grep -q '^TILE ANIMATION: ALL PASS' || exit 1
[ "$E_FAIL" -eq 0 ] || exit 1
exit 0
