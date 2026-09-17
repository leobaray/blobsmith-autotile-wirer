#!/usr/bin/env bash
# Runs every claim in docs/why-you-cannot-drop-through-the-one-way-tile.md
# against a real Godot 4 binary, in a throwaway project with nothing configured.
#
#   docs/verify_one_way_drop.sh /path/to/Godot_v4.7-stable_linux.x86_64
#   docs/verify_one_way_drop.sh /path/to/godot --invert   # must exit 1
#
# Headless is fine: nothing on that page is about pixels. The claims run real
# physics frames with a real CharacterBody2D.
#
# X1 is counted here, not in the script: it is about the engine's error line,
# which GDScript cannot read.
#
# The gate is the summary line, not Godot's exit code: a GDScript parse error
# still exits 0 and measures nothing.
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

cat > "$PROJ/project.godot" <<'EOT'
config_version=5

[application]

config/name="BlobsmithOneWayDropCheck"
EOT
cp "$HERE/verify_one_way_drop.gd" "$PROJ/verify_one_way_drop.gd"
shift   # everything after the binary is passed through to the script

OUT="$(timeout 300 "$GODOT" --headless --path "$PROJ" --script verify_one_way_drop.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |NOTE |ONE WAY DROP)'

if ! printf '%s\n' "$OUT" | grep -q '^ONE WAY DROP: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# X1: E1 calls add_collision_exception_with(TileMapLayer) exactly once, and it
# is the only place the script can print this error.
EXC="$(printf '%s\n' "$OUT" | grep -c 'Collision exception only works between two nodes that inherit from PhysicsBody2D')"
X_FAIL=0
if [ "$EXC" = "1" ]; then
  echo "PASS X1  add_collision_exception_with(TileMapLayer) prints one 'Collision exception only works between two nodes that inherit from PhysicsBody2D' error"
else
  echo "FAIL X1  add_collision_exception_with(TileMapLayer) error lines (got $EXC, want 1)"; X_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
[ "$X_FAIL" -eq 0 ] || exit 1
printf '%s\n' "$OUT" | grep -q '^ONE WAY DROP: ALL PASS' || exit 1
exit 0
