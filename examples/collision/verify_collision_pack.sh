#!/usr/bin/env bash
# Runs every claim in examples/collision/README.md against a real Godot 4 binary,
# with the real TileSets, in a throwaway project — and then runs the pack's own
# tool, check_tileset_collision.gd, both ways: clean on the eight packed TileSets,
# and finding the faults in a TileSet deliberately wired the broken way.
#
#   examples/collision/verify_collision_pack.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/collision/verify_collision_pack.sh /path/to/godot --invert   # must exit 1
#
# The gate is the summary line as well as the exit code: a GDScript parse error
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

cat > "$PROJ/project.godot" <<'PG'
config_version=5

[application]

config/name="BlobsmithCollisionPackCheck"
PG
mkdir "$PROJ/collision"
cp "$HERE"/*.png "$HERE"/*.tres "$HERE/manifest.json" "$PROJ/collision/"
cp "$HERE/verify_collision_pack.gd" "$PROJ/verify_collision_pack.gd"
cp "$HERE/check_tileset_collision.gd" "$PROJ/check_tileset_collision.gd"

# the broken TileSet the tool has to catch: a physics layer whose collision_layer
# is 0, and a second tile with no polygon at all. Both look wired in the editor.
cat > "$PROJ/collision/broken_on_purpose.tres" <<'BR'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="rock_solid_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
0:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
1:0/0 = 0

[resource]
tile_size = Vector2i(16, 16)
physics_layer_0/collision_layer = 0
physics_layer_0/collision_mask = 1
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR

# the second broken one: the layer is fine, but the tile added last never got a
# polygon, and one polygon is two points. Both are a click away in the editor.
cat > "$PROJ/collision/half_wired_on_purpose.tres" <<'BR2'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="rock_solid_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
0:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
1:0/0 = 0
2:0/0 = 0
2:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8)

[resource]
tile_size = Vector2i(16, 16)
physics_layer_0/collision_layer = 1
physics_layer_0/collision_mask = 1
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR2

shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

OUT="$(timeout 300 "$GODOT" --headless --path "$PROJ" --script verify_collision_pack.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |MANIFEST |COLLISION)'

if ! printf '%s\n' "$OUT" | grep -qE '^COLLISION'; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

E="$(printf '%s\n' "$OUT" | grep -cE 'ERROR')"
if [ "$E" = "0" ]; then
  echo "PASS P0  the verification run (8 TileSets, load, paint, physics queries) prints 0 ERROR / SCRIPT ERROR lines"
else
  echo "FAIL P0  the verification run printed $E ERROR lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR' | head -5
  exit 1
fi

# --- the pack's own tool, both ways ------------------------------------------
TARGETS=()
for t in "$PROJ"/collision/*_solid_*.tres; do TARGETS+=("res://collision/$(basename "$t")"); done
CLEAN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_collision.gd -- "${TARGETS[@]}" 2>&1)"
CLEAN_RC=$?
if [ "$CLEAN_RC" = "0" ] && printf '%s\n' "$CLEAN" | grep -qE '^COLLISION-CHECK OK  128 tiles, 0 faults'; then
  echo "PASS T1  check_tileset_collision.gd reports 0 faults over the 8 packed TileSets (128 tiles), exit 0"
else
  echo "FAIL T1  the tool did not come back clean on the pack (rc=$CLEAN_RC):"; printf '%s\n' "$CLEAN" | tail -5
  exit 1
fi

BROKEN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_collision.gd -- res://collision/broken_on_purpose.tres 2>&1)"
BROKEN_RC=$?
if [ "$BROKEN_RC" = "1" ] \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT LAYER-MASK-ZERO' \
   && printf '%s\n' "$BROKEN" | grep -q 'COLLISION-CHECK 1 FAULTS'; then
  echo "PASS T2  the tool finds the collision_layer = 0 fault in a TileSet wired the broken way and exits 1"
else
  echo "FAIL T2  the tool did not catch the deliberate fault (rc=$BROKEN_RC):"; printf '%s\n' "$BROKEN" | tail -8
  exit 1
fi

HALF="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_collision.gd -- res://collision/half_wired_on_purpose.tres 2>&1)"
HALF_RC=$?
if [ "$HALF_RC" = "1" ] \
   && printf '%s\n' "$HALF" | grep -q 'FAULT TILE-NO-POLYGON' \
   && printf '%s\n' "$HALF" | grep -q 'FAULT POLYGON-DEGENERATE' \
   && printf '%s\n' "$HALF" | grep -q 'COLLISION-CHECK 2 FAULTS'; then
  echo "PASS T3  the tool names the tile with no polygon and the 2-point polygon in a half-wired TileSet and exits 1"
else
  echo "FAIL T3  the tool did not catch the half-wired faults (rc=$HALF_RC):"; printf '%s\n' "$HALF" | tail -8
  exit 1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -qE '^COLLISION [0-9]+/[0-9]+ PASS' || exit 1
exit 0
