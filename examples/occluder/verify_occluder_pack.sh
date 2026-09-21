#!/usr/bin/env bash
# Runs every claim in examples/occluder/README.md against a real Godot 4 binary,
# with the real TileSets, in a throwaway project — and then runs the pack's own
# tool, check_tileset_occluders.gd, both ways: clean on the eight packed
# TileSets, and finding the faults in TileSets and scenes deliberately wired the
# broken way.
#
#   examples/occluder/verify_occluder_pack.sh /path/to/Godot_v4.x-stable_linux.x86_64
#   examples/occluder/verify_occluder_pack.sh /path/to/godot --invert   # must exit 1
#
# Two runs of verify_occluder_pack.gd:
#   * --headless: what the engine reports about the tiles (OCCLUDER n/n PASS).
#   * --render, under xvfb-run with --rendering-driver opengl3: whether the
#     shadow is really drawn (OCCLUDER-RENDER n/n PASS). The headless renderer
#     is a dummy that draws nothing, so a shadow cannot be observed --headless.
#     Without xvfb-run this half is SKIPPED, loudly, and the run exits 4 — a
#     green light with the shadow unmeasured would be a lie.
#
# The gate is the summary lines as well as the exit code: a GDScript parse error
# still exits 0 and measures nothing.
#
# Exit: 0 all pass, 1 any FAIL, 2 usage, 3 a script did not finish, 4 the render
# half could not run (no xvfb-run).
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

config/name="BlobsmithOccluderPackCheck"
PG
mkdir "$PROJ/occluder"
cp "$HERE"/*_occ_*.png "$HERE"/*_occ_*.tres "$HERE/manifest.json" "$PROJ/occluder/"
cp "$HERE/verify_occluder_pack.gd" "$PROJ/verify_occluder_pack.gd"
cp "$HERE/check_tileset_occluders.gd" "$PROJ/check_tileset_occluders.gd"

# broken one: the occlusion layer's light_mask is 0, and the one occluder was
# authored from (0,0) to (16,16). Both look wired in the editor.
cat > "$PROJ/occluder/broken_on_purpose.tres" <<'BR'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="dungeon_occ_16px.png" id="1_bsmith"]

[sub_resource type="OccluderPolygon2D" id="OccluderPolygon2D_corner"]
polygon = PackedVector2Array(0, 0, 16, 0, 16, 16, 0, 16)

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
4:0/0 = 0
4:0/0/occlusion_layer_0/polygon = SubResource("OccluderPolygon2D_corner")

[resource]
tile_size = Vector2i(16, 16)
occlusion_layer_0/light_mask = 0
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR

# half-wired: the layer is fine, but a wall tile added later has collision and
# no occluder, and one occluder has two points.
cat > "$PROJ/occluder/half_wired_on_purpose.tres" <<'BR2'
[gd_resource type="TileSet" load_steps=4 format=3]

[ext_resource type="Texture2D" path="dungeon_occ_16px.png" id="1_bsmith"]

[sub_resource type="OccluderPolygon2D" id="OccluderPolygon2D_ok"]
polygon = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)

[sub_resource type="OccluderPolygon2D" id="OccluderPolygon2D_line"]
polygon = PackedVector2Array(-8, 0, 8, 0)

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
4:0/0 = 0
4:0/0/occlusion_layer_0/polygon = SubResource("OccluderPolygon2D_ok")
4:0/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
4:1/0 = 0
4:1/0/physics_layer_0/polygon_0/points = PackedVector2Array(-8, -8, 8, -8, 8, 8, -8, 8)
0:0/0 = 0
0:0/0/occlusion_layer_0/polygon = SubResource("OccluderPolygon2D_line")

[resource]
tile_size = Vector2i(16, 16)
occlusion_layer_0/light_mask = 1
physics_layer_0/collision_layer = 1
physics_layer_0/collision_mask = 1
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR2

# no occlusion layer at all: the TileSet every new project starts with
cat > "$PROJ/occluder/no_layer_on_purpose.tres" <<'BR3'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="dungeon_occ_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0

[resource]
tile_size = Vector2i(16, 16)
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR3

# an occlusion layer and not one polygon drawn on it
cat > "$PROJ/occluder/empty_layer_on_purpose.tres" <<'BR4'
[gd_resource type="TileSet" load_steps=3 format=3]

[ext_resource type="Texture2D" path="dungeon_occ_16px.png" id="1_bsmith"]

[sub_resource type="TileSetAtlasSource" id="TileSetAtlasSource_bsmith"]
texture = ExtResource("1_bsmith")
texture_region_size = Vector2i(16, 16)
0:0/0 = 0
4:0/0 = 0

[resource]
tile_size = Vector2i(16, 16)
occlusion_layer_0/light_mask = 1
sources/0 = SubResource("TileSetAtlasSource_bsmith")
BR4

# the pack's own TileSet as Godot 4.4+ re-saves it: the occluder key becomes
# occlusion_layer_0/polygon_0/polygon
sed 's#/occlusion_layer_0/polygon = #/occlusion_layer_0/polygon_0/polygon = #' \
  "$HERE/dungeon_occ_16px.tres" > "$PROJ/occluder/format44_on_purpose.tres"

# scenes: one wired right, one wired every wrong way the checker knows
cat > "$PROJ/occluder/clean_scene_on_purpose.tscn" <<'SC1'
[gd_scene load_steps=4 format=3]

[ext_resource type="TileSet" path="res://occluder/dungeon_occ_16px.tres" id="1_ts"]

[sub_resource type="Gradient" id="Gradient_l"]

[sub_resource type="GradientTexture2D" id="GradientTexture2D_l"]
gradient = SubResource("Gradient_l")
fill = 1

[node name="Room" type="Node2D"]

[node name="Walls" type="TileMapLayer" parent="."]
tile_set = ExtResource("1_ts")

[node name="Torch" type="PointLight2D" parent="."]
shadow_enabled = true
texture = SubResource("GradientTexture2D_l")
SC1

cat > "$PROJ/occluder/broken_scene_on_purpose.tscn" <<'SC2'
[gd_scene load_steps=4 format=3]

[ext_resource type="TileSet" path="res://occluder/dungeon_occ_16px.tres" id="1_ts"]

[sub_resource type="Gradient" id="Gradient_l"]

[sub_resource type="GradientTexture2D" id="GradientTexture2D_l"]
gradient = SubResource("Gradient_l")
fill = 1

[node name="Room" type="Node2D"]

[node name="Walls" type="TileMapLayer" parent="."]
tile_set = ExtResource("1_ts")
occlusion_enabled = false

[node name="ShadowsOff" type="PointLight2D" parent="."]
texture = SubResource("GradientTexture2D_l")

[node name="WrongMask" type="PointLight2D" parent="."]
shadow_enabled = true
shadow_item_cull_mask = 2
texture = SubResource("GradientTexture2D_l")

[node name="NoTexture" type="PointLight2D" parent="."]
shadow_enabled = true
SC2

shift   # everything after the binary is passed through to the script

# the PNGs have to be imported before a .tres can load them
timeout 180 "$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1
MINOR="$("$GODOT" --version 2>/dev/null | sed -E 's/^4\.([0-9]+).*/\1/')"

OUT="$(timeout 600 "$GODOT" --headless --path "$PROJ" --script verify_occluder_pack.gd -- "$@" 2>&1)"
printf '%s\n' "$OUT" | grep -E '^(Godot |PASS |FAIL |MANIFEST |OCCLUDER)'
if ! printf '%s\n' "$OUT" | grep -qE '^OCCLUDER'; then
  echo "ERROR: the headless script did not finish — no claim was measured. Full output:" >&2
  printf '%s\n' "$OUT" >&2
  exit 3
fi
E="$(printf '%s\n' "$OUT" | grep -cE 'ERROR|WARNING')"
if [ "$E" = "0" ]; then
  echo "PASS P0  the headless run (8 TileSets: load, API read-back, paint, physics, both file formats, re-save) prints 0 ERROR / WARNING lines"
else
  echo "FAIL P0  the headless run printed $E ERROR/WARNING lines:"; printf '%s\n' "$OUT" | grep -E 'ERROR|WARNING' | head -5
  exit 1
fi

# --- the shadow itself, on a real GL context -----------------------------------
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "SKIP R*  xvfb-run not found: the shadow is NOT measured on this machine (the headless renderer draws nothing)."
  exit 4
fi
ROUT="$(timeout 600 xvfb-run -a -s "-screen 0 640x480x24" "$GODOT" --rendering-driver opengl3 --audio-driver Dummy --path "$PROJ" \
  --script verify_occluder_pack.gd -- --render "$@" 2>&1)"
printf '%s\n' "$ROUT" | grep -E '^(PASS |FAIL |INFO |OCCLUDER-RENDER)'
if ! printf '%s\n' "$ROUT" | grep -qE '^OCCLUDER-RENDER'; then
  echo "ERROR: the render script did not finish — the shadow was not measured. Full output:" >&2
  printf '%s\n' "$ROUT" >&2
  exit 3
fi
RE="$(printf '%s\n' "$ROUT" | grep -E 'ERROR' | grep -c .)"
if [ "$RE" = "0" ]; then
  echo "PASS P1  the render run (8 TileSets rendered with a PointLight2D, plus the traps) prints 0 ERROR lines"
else
  echo "FAIL P1  the render run printed $RE ERROR lines:"; printf '%s\n' "$ROUT" | grep -E 'ERROR' | head -5
  exit 1
fi

# --- the pack's own tool, both ways ------------------------------------------
chk() { timeout 180 "$GODOT" --headless --path "$PROJ" --script check_tileset_occluders.gd -- "$@" 2>&1; }
TARGETS=()
for t in "$PROJ"/occluder/*_occ_*.tres; do TARGETS+=("res://occluder/$(basename "$t")"); done
CLEAN="$(chk "${TARGETS[@]}")"; CLEAN_RC=$?
if [ "$CLEAN_RC" = "0" ] && printf '%s\n' "$CLEAN" | grep -qE '^OCCLUDER-CHECK OK  136 tiles, 0 lights, 0 faults'; then
  echo "PASS T1  check_tileset_occluders.gd reports 0 faults over the 8 packed TileSets (136 tiles), exit 0"
else
  echo "FAIL T1  the tool did not come back clean on the pack (rc=$CLEAN_RC):"; printf '%s\n' "$CLEAN" | tail -5
  exit 1
fi

BROKEN="$(chk res://occluder/broken_on_purpose.tres)"; BROKEN_RC=$?
if [ "$BROKEN_RC" = "1" ] && printf '%s\n' "$BROKEN" | grep -q 'FAULT LIGHT-MASK-ZERO' \
   && printf '%s\n' "$BROKEN" | grep -q 'FAULT POLYGON-OFFSET' \
   && printf '%s\n' "$BROKEN" | grep -q 'OCCLUDER-CHECK 2 FAULTS'; then
  echo "PASS T2  the tool finds the light_mask = 0 layer and the occluder authored from (0,0) to (16,16) and exits 1"
else
  echo "FAIL T2  the tool did not catch the deliberate faults (rc=$BROKEN_RC):"; printf '%s\n' "$BROKEN" | tail -8
  exit 1
fi

HALF="$(chk res://occluder/half_wired_on_purpose.tres)"; HALF_RC=$?
if [ "$HALF_RC" = "1" ] && printf '%s\n' "$HALF" | grep -q 'FAULT WALL-NO-OCCLUDER' \
   && printf '%s\n' "$HALF" | grep -q 'FAULT POLYGON-DEGENERATE' \
   && printf '%s\n' "$HALF" | grep -q 'OCCLUDER-CHECK 2 FAULTS'; then
  echo "PASS T3  the tool names the wall tile with collision and no occluder, and the two-point occluder, and exits 1"
else
  echo "FAIL T3  the tool did not catch the half-wired faults (rc=$HALF_RC):"; printf '%s\n' "$HALF" | tail -8
  exit 1
fi

NOLAYER="$(chk res://occluder/no_layer_on_purpose.tres res://occluder/empty_layer_on_purpose.tres)"; NOLAYER_RC=$?
if [ "$NOLAYER_RC" = "1" ] && printf '%s\n' "$NOLAYER" | grep -q 'FAULT NO-OCCLUSION-LAYER' \
   && printf '%s\n' "$NOLAYER" | grep -q 'FAULT NO-OCCLUDERS' \
   && printf '%s\n' "$NOLAYER" | grep -q 'OCCLUDER-CHECK 2 FAULTS'; then
  echo "PASS T4  the tool finds a TileSet with no occlusion layer, and one with a layer but no occluder on it, and exits 1"
else
  echo "FAIL T4  the tool did not catch the missing layer / missing occluders (rc=$NOLAYER_RC):"; printf '%s\n' "$NOLAYER" | tail -8
  exit 1
fi

# the 4.4+ key: on 4.3 the wall tile loads with NO occluder, so even without
# --for-4.3 the tool sees a wall with collision and nothing to cast a shadow
F44="$(chk res://occluder/format44_on_purpose.tres)"; F44_RC=$?
F44S="$(chk --for-4.3 res://occluder/format44_on_purpose.tres)"; F44S_RC=$?
if [ "$MINOR" -lt 4 ]; then
  if [ "$F44_RC" = "1" ] && printf '%s\n' "$F44" | grep -q 'FAULT WALL-NO-OCCLUDER' && printf '%s\n' "$F44" | grep -q 'OCCLUDER-CHECK 1 FAULTS' \
     && [ "$F44S_RC" = "1" ] && printf '%s\n' "$F44S" | grep -q 'FAULT FORMAT-4.4' && printf '%s\n' "$F44S" | grep -q 'OCCLUDER-CHECK 2 FAULTS'; then
    echo "PASS T5  on 4.3 the pack TileSet re-keyed the 4.4+ way loads its wall tile with no occluder (WALL-NO-OCCLUDER), and --for-4.3 also names the key (FORMAT-4.4)"
  else
    echo "FAIL T5  the 4.4+ key was not caught on 4.3 (rc=$F44_RC/$F44S_RC):"; printf '%s\n' "$F44" "$F44S" | tail -8
    exit 1
  fi
else
  if [ "$F44_RC" = "0" ] && printf '%s\n' "$F44" | grep -q 'NOTE FORMAT-4.4' \
     && [ "$F44S_RC" = "1" ] && printf '%s\n' "$F44S" | grep -q 'FAULT FORMAT-4.4' && printf '%s\n' "$F44S" | grep -q 'OCCLUDER-CHECK 1 FAULTS'; then
    echo "PASS T5  on 4.$MINOR the pack TileSet re-keyed the 4.4+ way loads fine (a NOTE, exit 0), and --for-4.3 turns the key into a FORMAT-4.4 fault"
  else
    echo "FAIL T5  the 4.4+ key was not reported as expected (rc=$F44_RC/$F44S_RC):"; printf '%s\n' "$F44" "$F44S" | tail -8
    exit 1
  fi
fi

SCLEAN="$(chk res://occluder/clean_scene_on_purpose.tscn)"; SCLEAN_RC=$?
SBAD="$(chk res://occluder/broken_scene_on_purpose.tscn)"; SBAD_RC=$?
if [ "$MINOR" -lt 4 ]; then WANT=3; else WANT=5; fi
ok=1
[ "$SCLEAN_RC" = "0" ] && printf '%s\n' "$SCLEAN" | grep -q 'OCCLUDER-CHECK OK  0 tiles, 1 lights, 0 faults' || ok=0
[ "$SBAD_RC" = "1" ] || ok=0
for f in LIGHT-SHADOW-OFF MASK-MISMATCH LIGHT-NO-TEXTURE; do printf '%s\n' "$SBAD" | grep -q "FAULT $f" || ok=0; done
if [ "$MINOR" -ge 4 ]; then
  for f in OCCLUSION-DISABLED RECEIVER-MASK; do printf '%s\n' "$SBAD" | grep -q "FAULT $f" || ok=0; done
else
  printf '%s\n' "$SBAD" | grep -qE 'FAULT (OCCLUSION-DISABLED|RECEIVER-MASK)' && ok=0
fi
printf '%s\n' "$SBAD" | grep -q "OCCLUDER-CHECK $WANT FAULTS" || ok=0
if [ "$ok" = "1" ]; then
  echo "PASS T6  on a scene the tool passes a light wired right and names $WANT faults in one wired wrong (shadows off, mask mismatch, no texture$( [ "$MINOR" -ge 4 ] && echo ', occlusion_enabled off, receiver light_mask'))"
else
  echo "FAIL T6  the scene checks did not come out as expected (rc=$SCLEAN_RC/$SBAD_RC):"; printf '%s\n' "$SCLEAN" "$SBAD" | tail -10
  exit 1
fi

printf '%s\n' "$OUT" "$ROUT" | grep -q '^FAIL ' && exit 1
printf '%s\n' "$OUT" | grep -qE '^OCCLUDER [0-9]+/[0-9]+ PASS' || exit 1
printf '%s\n' "$ROUT" | grep -qE '^OCCLUDER-RENDER [0-9]+/[0-9]+ PASS' || exit 1
exit 0
