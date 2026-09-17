#!/usr/bin/env bash
# Runs every claim in examples/platformer/README.md against a real Godot 4 binary,
# with the real demo scene and player.gd, in a throwaway project.
#
#   examples/platformer/verify_platformer.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/platformer/verify_platformer.sh /path/to/godot --invert   # must exit 1
#
# Headless is enough: the claims are terrain data and physics frames, not pixels.
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
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithPlatformerCheck"
EOF
mkdir "$PROJ/platformer"
cp "$HERE"/*.png "$HERE"/*.tres "$HERE/player.gd" "$HERE/platformer_demo.tscn" "$HERE/manifest.json" "$PROJ/platformer/"
cp "$HERE/verify_platformer.gd" "$PROJ/verify_platformer.gd"
shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

# W1: the demo scene run as a game for 120 frames
RUN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --quit-after 120 res://platformer/platformer_demo.tscn 2>&1)"
OUT="$(timeout 300 "$GODOT" --headless --path "$PROJ" --script verify_platformer.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |NOTE |PLATFORMER)'

if ! printf '%s\n' "$OUT" | grep -q '^PLATFORMER: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

W_FAIL=0
E1="$(printf '%s\n' "$RUN" | grep -cE 'ERROR')"
if [ "$E1" = "0" ]; then
  echo "PASS W1  platformer_demo.tscn run as the main scene for 120 frames prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL W1  platformer_demo.tscn run for 120 frames printed $E1 ERROR lines:"; printf '%s\n' "$RUN" | grep -E 'ERROR' | head -5; W_FAIL=1
fi
E2="$(printf '%s\n' "$OUT" | grep -cE 'ERROR')"
if [ "$E2" = "0" ]; then
  echo "PASS W2  the verification run (scene load, tilesets, every jump) prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL W2  the verification run printed $E2 ERROR lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR' | head -5; W_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
[ "$W_FAIL" -eq 0 ] || exit 1
printf '%s\n' "$OUT" | grep -q '^PLATFORMER: ALL PASS' || exit 1
exit 0
