#!/usr/bin/env bash
# Runs every claim in examples/navigation/README.md against a real Godot 4 binary,
# with the real TileSets, in a throwaway project — and then runs the pack's own
# tool, check_tileset_navigation.gd, both ways: clean on the eight packed
# TileSets, and finding the faults in TileSets deliberately wired the broken way.
#
#   examples/navigation/verify_navigation_pack.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/navigation/verify_navigation_pack.sh /path/to/godot --invert   # must exit 1
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

config/name="BlobsmithNavigationPackCheck"
PG
mkdir "$PROJ/navigation"
cp "$HERE"/*_nav_*.png "$HERE"/*_nav_*.tres "$HERE/manifest.json" "$PROJ/navigation/"
cp "$HERE/verify_navigation_pack.gd" "$PROJ/verify_navigation_pack.gd"
cp "$HERE/check_tileset_navigation.gd" "$PROJ/check_tileset_navigation.gd"

# broken one: the navigation layer's bitmask is 0, and the one floor polygon was
# authored from (0,0) to (16,16). Both look wired in the editor.
cat > "$PROJ/navigation/broken_on_purpose.tres" <<'BR'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="dungeon_nav_16px.png" id="1_bsmith"]

[sub_resource type="NavigationPolygon" id="NavigationPolygon_corner"]
vertices = PackedVector2Array(0, 0, 16, 0, 16, 16, 0, 16)
polygons = Array[PackedInt32Array]([PackedInt32Array(0, 1, 2, 3)])

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
0:0/0/navigation_layer_0/polygon = SubResource("NavigationPolygon_corner")

[resource]
tile_size = Vector2i(16, 16)
navigation_layer_0/layers = 0
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR

# half-wired: the layers are fine, but a floor tile added later has no polygon,
# a wall tile carries a navigation polygon, and one polygon has an outline that
# was never turned into polygons.
cat > "$PROJ/navigation/half_wired_on_purpose.tres" <<'BR2'
[gd_resource type="TileSet" load_steps=5 format=3]

[ext_resource type="Texture2D" path="dungeon_nav_16px.png" id="1_bsmith"]

[sub_resource type="NavigationPolygon" id="NavigationPolygon_ok"]
vertices = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
polygons = Array[PackedInt32Array]([PackedInt32Array(0, 1, 2, 3)])

[sub_resource type="NavigationPolygon" id="NavigationPolygon_wall"]
vertices = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
polygons = Array[PackedInt32Array]([PackedInt32Array(0, 1, 2, 3)])

[sub_resource type="NavigationPolygon" id="NavigationPolygon_outline_only"]
outlines = Array[PackedVector2Array]([PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)])

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
0:0/0/navigation_layer_0/polygon = SubResource("NavigationPolygon_ok")
1:0/0 = 0
4:0/0 = 0
4:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
4:0/0/navigation_layer_0/polygon = SubResource("NavigationPolygon_wall")
2:0/0 = 0
2:0/0/navigation_layer_0/polygon = SubResource("NavigationPolygon_outline_only")

[resource]
tile_size = Vector2i(16, 16)
physics_layer_0/collision_layer = 1
physics_layer_0/collision_mask = 1
navigation_layer_0/layers = 1
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR2

# no navigation layer at all: the TileSet a tutorial for Godot 3 leaves you with
cat > "$PROJ/navigation/no_layer_on_purpose.tres" <<'BR3'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="dungeon_nav_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0

[resource]
tile_size = Vector2i(16, 16)
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR3

shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

OUT="$(timeout 600 "$GODOT" --headless --path "$PROJ" --script verify_navigation_pack.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |MANIFEST |NAVIGATION)'

if ! printf '%s\n' "$OUT" | grep -qE '^NAVIGATION'; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# N10 asks the map for a path in the frame the room is painted, on purpose. On
# Godot 4.3 the engine answers that query with this one ERROR line (printed once
# per run); 4.4 and 4.7 answer it silently. It is the measured behaviour, not a
# fault in the pack, so it is the only line exempted — and it is counted.
EARLY='made before first map synchronization'
NE="$(printf '%s\n' "$OUT" | grep -c "$EARLY")"
E="$(printf '%s\n' "$OUT" | grep -E 'ERROR' | grep -vc "$EARLY")"
if [ "$E" = "0" ]; then
  echo "PASS P0  the verification run (8 TileSets, load, paint, navigation and physics queries) prints 0 ERROR / SCRIPT ERROR lines besides the $NE 'before first map synchronization' line(s) N10 provokes on purpose"
else
  echo "FAIL P0  the verification run printed $E ERROR lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR' | grep -v "$EARLY" | head -5
  exit 1
fi

# --- the pack's own tool, both ways ------------------------------------------
TARGETS=()
for t in "$PROJ"/navigation/*_nav_*.tres; do TARGETS+=("res://navigation/$(basename "$t")"); done
CLEAN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_navigation.gd -- "${TARGETS[@]}" 2>&1)"
CLEAN_RC=$?
if [ "$CLEAN_RC" = "0" ] && printf '%s\n' "$CLEAN" | grep -qE '^NAVIGATION-CHECK OK  136 tiles, 0 faults'; then
  echo "PASS T1  check_tileset_navigation.gd reports 0 faults over the 8 packed TileSets (136 tiles), exit 0"
else
  echo "FAIL T1  the tool did not come back clean on the pack (rc=$CLEAN_RC):"; printf '%s\n' "$CLEAN" | tail -5
  exit 1
fi

BROKEN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_navigation.gd -- res://navigation/broken_on_purpose.tres 2>&1)"
BROKEN_RC=$?
if [ "$BROKEN_RC" = "1" ] \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT NAV-LAYERS-ZERO' \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT POLYGON-OFFSET' \
   && printf '%s\n' "$BROKEN" | grep -q 'NAVIGATION-CHECK 2 FAULTS'; then
  echo "PASS T2  the tool finds the layers = 0 bitmask and the polygon authored from (0,0) to (16,16) and exits 1"
else
  echo "FAIL T2  the tool did not catch the deliberate faults (rc=$BROKEN_RC):"; printf '%s\n' "$BROKEN" | tail -8
  exit 1
fi

HALF="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_navigation.gd -- res://navigation/half_wired_on_purpose.tres 2>&1)"
HALF_RC=$?
if [ "$HALF_RC" = "1" ] \
   && [ "$(printf '%s\n' "$HALF" | grep -c 'FAULT FLOOR-NO-POLYGON')" = "2" ] \
   && printf '%s\n' "$HALF" | grep -q 'FAULT WALL-HAS-NAV' \
   && printf '%s\n' "$HALF" | grep -q 'FAULT POLYGON-EMPTY' \
   && printf '%s\n' "$HALF" | grep -q 'NAVIGATION-CHECK 4 FAULTS'; then
  echo "PASS T3  the tool names the floor tile with no polygon, the wall carrying one and the outline-only polygon in a half-wired TileSet and exits 1"
else
  echo "FAIL T3  the tool did not catch the half-wired faults (rc=$HALF_RC):"; printf '%s\n' "$HALF" | tail -8
  exit 1
fi

NOLAYER="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_navigation.gd -- res://navigation/no_layer_on_purpose.tres 2>&1)"
NOLAYER_RC=$?
if [ "$NOLAYER_RC" = "1" ] \
   && printf '%s\n' "$NOLAYER" | grep -q 'FAULT NO-NAVIGATION-LAYER' \
   && printf '%s\n' "$NOLAYER" | grep -q 'NAVIGATION-CHECK 1 FAULTS'; then
  echo "PASS T4  the tool finds a TileSet with no navigation layer at all and exits 1"
else
  echo "FAIL T4  the tool did not catch the missing navigation layer (rc=$NOLAYER_RC):"; printf '%s\n' "$NOLAYER" | tail -8
  exit 1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -qE '^NAVIGATION [0-9]+/[0-9]+ PASS' || exit 1
exit 0
