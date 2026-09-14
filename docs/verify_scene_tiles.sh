#!/usr/bin/env bash
# Runs every claim in docs/why-my-scene-tile-is-not-there.md against a real
# Godot 4 binary. Exits non-zero if any claim fails.
#
#   docs/verify_scene_tiles.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Scene tiles are nodes, so --headless is enough; no X server needed.
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

config/name="BlobsmithSceneTilesCheck"
EOF
cp "$HERE/verify_scene_tiles.gd" "$PROJ/verify_scene_tiles.gd"

run() {
  timeout 180 "$GODOT" --headless --path "$PROJ" --script verify_scene_tiles.gd 2>&1
}

OUT="$(run)"
echo "$OUT" | grep -E '^(Godot Engine v|PASS |FAIL |SCENE TILES)'

if ! printf '%s\n' "$OUT" | grep -q '^SCENE TILES: '; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# B3: the three cells that point at no scene print nothing — no ERROR, no WARNING.
E_FAIL=0
BAD="$(LG_SCENEPROBE=bad run)"
printf '%s\n' "$BAD" | grep -q '^SCENEPROBE DONE children=0 used=3' || { echo "ERROR: probe 'bad' did not finish as expected" >&2; printf '%s\n' "$BAD" >&2; exit 3; }
if printf '%s\n' "$BAD" | grep -qE '^(ERROR|WARNING|SCRIPT ERROR)'; then
  echo "FAIL  B3 a cell pointing at no scene printed an error or warning"; E_FAIL=1
else
  echo "PASS  B3 cells pointing at no scene print no error and no warning"
fi

printf '%s\n' "$OUT" | grep -q '^SCENE TILES: ALL PASS' || exit 1
[ "$E_FAIL" -eq 0 ] || exit 1
exit 0
