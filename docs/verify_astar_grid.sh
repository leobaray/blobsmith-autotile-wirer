#!/usr/bin/env bash
# Runs every claim in docs/why-astargrid2d-walks-through-walls.md against a real
# Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_astar_grid.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Pathfinding is math, not pixels, so --headless is enough; no X server needed.
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
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT

cat > "$PROJ/project.godot" <<'EOF'
config_version=5

[application]

config/name="BlobsmithAStarGridCheck"
EOF
cp "$HERE/verify_astar_grid.gd" "$PROJ/verify_astar_grid.gd"

run() {
  timeout 180 "$GODOT" --headless --path "$PROJ" --script verify_astar_grid.gd 2>&1
}

OUT="$(run)"
echo "$OUT" | grep -E '^(Godot |PASS |FAIL |NOTE |ASTAR GRID)'

if ! printf '%s\n' "$OUT" | grep -q '^ASTAR GRID: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# E1/E2: the two mistakes that DO print something, and what they print.
E_FAIL=0
ERR="$(LG_ASTARPROBE=errors run)"
printf '%s\n' "$ERR" | grep -q '^ASTARPROBE DONE' || { echo "ERROR: probe 'errors' did not finish" >&2; printf '%s\n' "$ERR" >&2; exit 3; }
if printf '%s\n' "$ERR" | grep -q "Can't get id path. Point (0, 0) out of bounds"; then
  echo "PASS  E1 a path query on the default region prints \"Can't get id path. Point (0, 0) out of bounds\""
else
  echo "FAIL  E1 no out-of-bounds error for a path query on the default region"; E_FAIL=1
fi
if printf '%s\n' "$ERR" | grep -q 'Grid is not initialized. Call the update method.'; then
  echo "PASS  E2 set_point_solid before update() prints \"Grid is not initialized. Call the update method.\""
else
  echo "FAIL  E2 no 'Grid is not initialized' error for set_point_solid before update()"; E_FAIL=1
fi

printf '%s\n' "$OUT" | grep -q '^ASTAR GRID: ALL PASS' || exit 1
[ "$E_FAIL" -eq 0 ] || exit 1
exit 0
