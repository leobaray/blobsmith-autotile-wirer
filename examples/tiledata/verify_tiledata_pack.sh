#!/usr/bin/env bash
# Runs every claim in examples/tiledata/README.md against a real Godot 4 binary,
# with the real TileSets, in a throwaway project — and then runs the pack's own
# tool, check_tileset_custom_data.gd, both ways: clean on the eight packed
# TileSets (and on the pack's own scripts), and finding the faults in TileSets
# and a script deliberately written the broken way.
#
#   examples/tiledata/verify_tiledata_pack.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/tiledata/verify_tiledata_pack.sh /path/to/godot --invert   # must exit 1
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

config/name="BlobsmithTileDataPackCheck"
PG
mkdir "$PROJ/tiledata" "$PROJ/broken_scripts"
cp "$HERE"/*_data_*.png "$HERE"/*_data_*.tres "$HERE/manifest.json" "$HERE/tile_data_example.gd" "$PROJ/tiledata/"
cp "$HERE/verify_tiledata_pack.gd" "$PROJ/verify_tiledata_pack.gd"
cp "$HERE/check_tileset_custom_data.gd" "$PROJ/check_tileset_custom_data.gd"

# broken one: the five layers of the pack, as they go wrong by hand. Layer 3 has
# no name (what Godot leaves when you give a second layer a name already taken),
# layer 4 has type Nil (what a layer added from code starts with). Tile 1:0 was
# added after the others were filled, and alternative 1 of tile 0:0 is a new
# flip of a filled tile: every layer at its default. Tile 2:0 has a Vector2 in
# the String layer and 1:1 has "no" in the bool layer — values Godot cannot
# convert, which load as null. Tile 0:1 never got its ground name.
cat > "$PROJ/tiledata/broken_on_purpose.tres" <<'BR'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="meadow_data_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
0:0/0/custom_data_0 = "road"
0:0/0/custom_data_1 = 1.0
0:0/0/custom_data_2 = true
0:0/0/custom_data_3 = 1
0:0/1 = 1
1:0/0 = 0
2:0/0 = 0
2:0/0/custom_data_0 = Vector2(1, 2)
2:0/0/custom_data_1 = 2.0
2:0/0/custom_data_2 = true
0:1/0 = 0
0:1/0/custom_data_1 = 3.0
0:1/0/custom_data_2 = true
1:1/0 = 0
1:1/0/custom_data_0 = "mud"
1:1/0/custom_data_1 = 3.0
1:1/0/custom_data_2 = "no"

[resource]
tile_size = Vector2i(16, 16)
custom_data_layer_0/name = "ground"
custom_data_layer_0/type = 4
custom_data_layer_1/name = "move_cost"
custom_data_layer_1/type = 3
custom_data_layer_2/name = "walkable"
custom_data_layer_2/type = 1
custom_data_layer_3/name = ""
custom_data_layer_3/type = 2
custom_data_layer_4/name = "footstep"
custom_data_layer_4/type = 0
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR

# no custom data layer at all: the TileSet you start from
cat > "$PROJ/tiledata/no_layers_on_purpose.tres" <<'BR2'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="meadow_data_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0

[resource]
tile_size = Vector2i(16, 16)
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR2

# a player script with one layer name one letter off
cat > "$PROJ/broken_scripts/player_on_purpose.gd" <<'BR3'
extends Node2D

@export var ground_layer: TileMapLayer

func speed_here() -> float:
	var td := ground_layer.get_cell_tile_data(ground_layer.local_to_map(ground_layer.to_local(global_position)))
	if td == null or td.get_custom_data("ground") == "":
		return 1.0
	return 1.0 / float(td.get_custom_data("move_cst"))
BR3

shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1

OUT="$(timeout 600 "$GODOT" --headless --path "$PROJ" --script verify_tiledata_pack.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |MANIFEST |TILEDATA)'

if ! printf '%s\n' "$OUT" | grep -qE '^TILEDATA'; then
  echo "ERROR: the script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi

# X1 asks for a misspelled layer name on purpose, and the engine answers with
# exactly one ERROR line. It is the measured behaviour, not a fault in the pack,
# so it is the only line exempted — and it is counted.
MISSPELT='TileSet has no layer with name: move_cst'
# only engine lines count: a PASS line that quotes the word ERROR is not one
ERRS="$(printf '%s\n' "$OUT" | grep -E '^(USER |SCRIPT )?ERROR')"
NE="$(printf '%s\n' "$ERRS" | grep -c "$MISSPELT")"
E="$(printf '%s\n' "$ERRS" | grep -E 'ERROR' | grep -vc "$MISSPELT")"
if [ "$E" = "0" ] && [ "$NE" = "1" ]; then
  echo "PASS P0  the verification run (8 TileSets, load, paint, read back, A*) prints 0 ERROR / SCRIPT ERROR lines besides the $NE 'no layer with name' line X1 provokes on purpose"
else
  echo "FAIL P0  the verification run printed $E unexpected ERROR lines ($NE for the X1 misspelling, expected 1):"
  printf '%s\n' "$ERRS" | grep -v "$MISSPELT" | head -5
  exit 1
fi

# --- the pack's own tool, both ways ------------------------------------------
TARGETS=()
for t in "$PROJ"/tiledata/*_data_*.tres; do TARGETS+=("res://tiledata/$(basename "$t")"); done
CLEAN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_custom_data.gd -- "${TARGETS[@]}" --scripts res://tiledata 2>&1)"
CLEAN_RC=$?
if [ "$CLEAN_RC" = "0" ] && printf '%s\n' "$CLEAN" | grep -qE '^CUSTOM-DATA-CHECK OK  48 tiles, 0 faults' \
   && printf '%s\n' "$CLEAN" | grep -qE '^SCRIPTS res://tiledata  5 layer names used in code' \
   && ! printf '%s\n' "$CLEAN" | grep -q 'LAYER-NEVER-READ'; then
  echo "PASS T1  check_tileset_custom_data.gd reports 0 faults over the 8 packed TileSets (48 tiles) and finds all 5 layer names read by the pack's own tile_data_example.gd, exit 0"
else
  echo "FAIL T1  the tool did not come back clean on the pack (rc=$CLEAN_RC):"; printf '%s\n' "$CLEAN" | tail -5
  exit 1
fi

BROKEN="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_custom_data.gd -- res://tiledata/broken_on_purpose.tres 2>&1)"
BROKEN_RC=$?
if [ "$BROKEN_RC" = "1" ] \
   && [ "$(printf '%s\n' "$BROKEN" | grep -c 'FAULT LAYER-UNNAMED')" = "1" ] \
   && [ "$(printf '%s\n' "$BROKEN" | grep -c 'FAULT LAYER-NO-TYPE')" = "1" ] \
   && [ "$(printf '%s\n' "$BROKEN" | grep -c 'FAULT TILE-UNFILLED')" = "2" ] \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT TILE-UNFILLED .*tile (1, 0) has' \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT TILE-UNFILLED .*tile (0, 0) alternative 1 has' \
   && [ "$(printf '%s\n' "$BROKEN" | grep -c 'FAULT TYPE-MISMATCH')" = "2" ] \
   && printf '%s\n' "$BROKEN" | grep -q "FAULT TYPE-MISMATCH .*tile (2, 0) layer 'ground'" \
   && printf '%s\n' "$BROKEN" | grep -q "FAULT TYPE-MISMATCH .*tile (1, 1) layer 'walkable'" \
   && [ "$(printf '%s\n' "$BROKEN" | grep -c 'FAULT EMPTY-STRING')" = "1" ] \
   && printf '%s\n' "$BROKEN" | grep -q "FAULT EMPTY-STRING .*tile (0, 1) layer 'ground'" \
   && printf '%s\n' "$BROKEN" | grep -q 'CUSTOM-DATA-CHECK 7 FAULTS'; then
  echo "PASS T2  the tool names the unnamed layer, the Nil-typed layer, the tile added later and the new alternative (every layer at its default), the two values that loaded as null and the missing ground name — 7 faults, exit 1"
else
  echo "FAIL T2  the tool did not catch the deliberate faults (rc=$BROKEN_RC):"; printf '%s\n' "$BROKEN" | tail -12
  exit 1
fi

NOLAYER="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_custom_data.gd -- res://tiledata/no_layers_on_purpose.tres 2>&1)"
NOLAYER_RC=$?
if [ "$NOLAYER_RC" = "1" ] \
   && printf '%s\n' "$NOLAYER" | grep -q 'FAULT NO-CUSTOM-DATA' \
   && printf '%s\n' "$NOLAYER" | grep -q 'CUSTOM-DATA-CHECK 1 FAULTS'; then
  echo "PASS T3  the tool finds a TileSet with no custom data layer at all and exits 1"
else
  echo "FAIL T3  the tool did not catch the missing custom data layers (rc=$NOLAYER_RC):"; printf '%s\n' "$NOLAYER" | tail -8
  exit 1
fi

SCR="$(timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_custom_data.gd -- res://tiledata/meadow_data_16px.tres --scripts res://broken_scripts 2>&1)"
SCR_RC=$?
if [ "$SCR_RC" = "1" ] \
   && [ "$(printf '%s\n' "$SCR" | grep -c 'FAULT NAME-NOT-DECLARED')" = "1" ] \
   && printf '%s\n' "$SCR" | grep -q "FAULT NAME-NOT-DECLARED  'move_cst' (at res://broken_scripts/player_on_purpose.gd:9)" \
   && printf '%s\n' "$SCR" | grep -q 'CUSTOM-DATA-CHECK 1 FAULTS'; then
  echo "PASS T4  with --scripts the tool names the one layer name a script asks for that the TileSet does not declare ('move_cst', file and line) and exits 1"
else
  echo "FAIL T4  the tool did not catch the misspelled layer name in code (rc=$SCR_RC):"; printf '%s\n' "$SCR" | tail -8
  exit 1
fi

printf '%s\n' "$OUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -qE '^TILEDATA [0-9]+/[0-9]+ PASS' || exit 1
exit 0
