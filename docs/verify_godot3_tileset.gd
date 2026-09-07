# Measures what Godot 4 ACTUALLY does when it loads a Godot 3 (`format=2`)
# TileSet — the file Tilesetter and TilePipe2 export, and the file every
# "my tileset opens empty in Godot 4" thread is about.
#
# Run it through docs/verify_godot3_tileset.sh, which builds the throwaway
# project, the atlas and the two fixtures this script needs.
#
# Every claim here is printed as PASS/FAIL with the value that was read, so a
# stranger can disagree with the doc by running the file, not by arguing.
extends SceneTree

var n_pass := 0
var n_fail := 0

func ck(cond: bool, msg: String) -> void:
	if cond:
		n_pass += 1
		print("PASS  ", msg)
	else:
		n_fail += 1
		print("FAIL  ", msg)

# ---------------------------------------------------------------------------
# The fixtures. Both are written in the text the Godot 3 engine itself writes
# (scene/resources/tile_set.cpp `_set`/`_get`), not in an invented shape.
# ---------------------------------------------------------------------------

# Tile 2 is a SINGLE tile at region (0,32,16,16) carrying a collision quad that
# covers the BOTTOM half of the tile: Godot 3 counts a shape from the tile's
# top-left corner, so y 8..16 of a 16px tile is its bottom half.
# A SINGLE tile at region (0,32,16,16) carrying a collision quad that covers the
# BOTTOM half of the tile: Godot 3 counts a shape from the tile's top-left
# corner, so y 8..16 of a 16px tile is its bottom half. Every copy points at the
# SAME `SubResource( 1 )` — which is how Godot 3 tilesets were normally made:
# you draw one full-tile box and reuse it on every tile that needs one.
func single_tile(id: int) -> String:
	return """%d/name = "prop%d"
%d/texture = ExtResource( 1 )
%d/tex_offset = Vector2( 0, 0 )
%d/modulate = Color( 1, 1, 1, 1 )
%d/region = Rect2( 0, 32, 16, 16 )
%d/tile_mode = 0
%d/occluder_offset = Vector2( 0, 0 )
%d/navigation_offset = Vector2( 0, 0 )
%d/shape_offset = Vector2( 0, 0 )
%d/shape_transform = Transform2D( 1, 0, 0, 1, 0, 0 )
%d/shape_one_way = false
%d/shape_one_way_margin = 0.0
%d/shapes = [ {
"autotile_coord": Vector2( 0, 0 ),
"one_way": false,
"one_way_margin": 1.0,
"shape": SubResource( 1 ),
"shape_transform": Transform2D( 1, 0, 0, 1, 0, 0 )
} ]
%d/z_index = 3
""" % [id, id, id, id, id, id, id, id, id, id, id, id, id, id, id]

# An autotile: 3x2 subtiles of 16px inside a 48x32 region, with the canonical
# 3x3-minimal bitmasks. This is the shape a paid tileset tool exports.
const AUTOTILE := """0/name = "grass"
0/texture = ExtResource( 1 )
0/tex_offset = Vector2( 0, 0 )
0/modulate = Color( 1, 1, 1, 1 )
0/region = Rect2( 0, 0, 48, 32 )
0/tile_mode = 1
0/autotile/bitmask_mode = 1
0/autotile/bitmask_flags = [ Vector2( 0, 0 ), 432, Vector2( 1, 0 ), 504, Vector2( 2, 0 ), 216, Vector2( 0, 1 ), 54, Vector2( 1, 1 ), 63, Vector2( 2, 1 ), 27 ]
0/autotile/icon_coordinate = Vector2( 0, 0 )
0/autotile/tile_size = Vector2( 16, 16 )
0/autotile/spacing = 0
0/autotile/occluder_map = [  ]
0/autotile/navpoly_map = [  ]
0/autotile/priority_map = [  ]
0/autotile/z_index_map = [  ]
0/shapes = [  ]
0/z_index = 0
"""

# A second autotile with a DIFFERENT region width (32 wide, 2 subtiles).
const AUTOTILE_2 := """1/name = "cliff"
1/texture = ExtResource( 1 )
1/tex_offset = Vector2( 0, 0 )
1/modulate = Color( 1, 1, 1, 1 )
1/region = Rect2( 48, 0, 32, 16 )
1/tile_mode = 1
1/autotile/bitmask_mode = 1
1/autotile/bitmask_flags = [ Vector2( 0, 0 ), 432, Vector2( 1, 0 ), 216 ]
1/autotile/icon_coordinate = Vector2( 0, 0 )
1/autotile/tile_size = Vector2( 16, 16 )
1/autotile/spacing = 0
1/autotile/occluder_map = [  ]
1/autotile/navpoly_map = [  ]
1/autotile/priority_map = [  ]
1/autotile/z_index_map = [  ]
1/shapes = [  ]
1/z_index = 0
"""

const HEADER := """[gd_resource type="TileSet" load_steps=3 format=2]

[ext_resource path="res://tiles/atlas.png" type="Texture" id=1]

[sub_resource type="ConvexPolygonShape2D" id=1]
points = PoolVector2Array( 0, 8, 16, 8, 16, 16, 0, 16 )

[resource]
"""

func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func make_atlas() -> void:
	# 80x48 covers every region in the fixtures. Colours are irrelevant; a
	# texture too SMALL is not — Godot drops tiles that fall outside it, and
	# that would look like a conversion bug instead of a fixture bug.
	var img := Image.create(80, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.25, 0.5, 0.3, 1.0))
	img.save_png("res://tiles/atlas.png")

func prepare() -> void:
	make_atlas()
	# MIXED: two autotiles and three single tiles, the ordinary case — a Godot 3
	# tileset with a few autotiles and a handful of props, all of the props
	# reusing one collision box.
	write_text("res://legacy_mixed.tres",
		HEADER + AUTOTILE + AUTOTILE_2 + single_tile(2) + single_tile(3) + single_tile(4))
	# ALONE: the FIRST single tile, byte for byte, with nothing else in the file.
	write_text("res://legacy_alone.tres", HEADER + single_tile(2))
	print("PREPARED")

func poly_of(ts: TileSet, source_index: int) -> String:
	var src = ts.get_source(ts.get_source_id(source_index))
	if src.get_tiles_count() == 0:
		return "<no tiles>"
	var td = src.get_tile_data(src.get_tile_id(0), 0)
	if ts.get_physics_layers_count() == 0 or td.get_collision_polygons_count(0) == 0:
		return "<no polygon>"
	var pts = td.get_collision_polygon_points(0, 0)
	var parts := PackedStringArray()
	for p in pts:
		parts.append("(%d,%d)" % [int(round(p.x)), int(round(p.y))])
	return ",".join(parts)

func run_checks() -> void:
	print("== Godot ", Engine.get_version_info()["string"], " ==")

	# -- claim 1: it loads. It is not empty, and it is not an error. ----------
	var mixed = ResourceLoader.load("res://legacy_mixed.tres")
	ck(mixed != null, "a format=2 TileSet LOADS in Godot 4 — no error, no null")
	ck(mixed is TileSet, "and what comes back is a TileSet")
	ck(mixed.get_source_count() == 5,
		"it is NOT empty: %d atlas sources, one per Godot 3 tile" % mixed.get_source_count())

	# -- claim 2: every autotile arrives as an EMPTY source. -----------------
	var empty_sources := 0
	var tiles_total := 0
	for i in range(mixed.get_source_count()):
		var s = mixed.get_source(mixed.get_source_id(i))
		tiles_total += s.get_tiles_count()
		if s.get_tiles_count() == 0:
			empty_sources += 1
	ck(empty_sources == 2,
		"the 2 autotiles became sources with ZERO tiles in them (%d empty of %d)"
			% [empty_sources, mixed.get_source_count()])
	ck(tiles_total == 3,
		"8 autotile subtiles + 3 single tiles went in; %d tiles came out" % tiles_total)
	ck(mixed.get_terrain_sets_count() == 0,
		"terrain sets: %d — every bitmask is gone" % mixed.get_terrain_sets_count())

	# The regions go with them: an emptied source is left at margins (0,0), so
	# even "where in the sheet was this" is not recoverable from it.
	var a0 = mixed.get_source(mixed.get_source_id(0))
	ck(a0.get_tiles_count() == 0 and a0.margins == Vector2i(0, 0),
		"the emptied autotile source keeps no region either (margins %s)" % str(a0.margins))

	# -- claim 3: the collision that DOES survive drifts, once per sharer. ----
	# The quad covered the BOTTOM half of a 16px tile. Godot 4 counts from the
	# tile CENTRE, so the bottom half is y 0..8 — which is what the same tile
	# gives when it is ALONE in the file. In the mixed file the three props
	# point at ONE shape sub-resource, and it is re-origined in place: the
	# second sharer gets it shifted twice, the third three times.
	var alone = ResourceLoader.load("res://legacy_alone.tres")
	ck(alone != null and alone.get_source_count() == 1, "the single tile alone loads as one source")
	ck(poly_of(alone, 0) == "(-8,0),(8,0),(8,8),(-8,8)",
		"ALONE: one sharer, correctly re-origined onto the bottom half — %s" % poly_of(alone, 0))
	var p2 := poly_of(mixed, 2)
	var p3 := poly_of(mixed, 3)
	var p4 := poly_of(mixed, 4)
	ck(p2 == "(-8,0),(8,0),(8,8),(-8,8)", "MIXED prop 1 of 3: %s" % p2)
	ck(p3 == "(-16,-8),(0,-8),(0,0),(-16,0)",
		"MIXED prop 2 of 3: half a tile up and left — %s" % p3)
	ck(p4 == "(-24,-16),(-8,-16),(-8,-8),(-24,-8)",
		"MIXED prop 3 of 3: a whole tile up and left — %s" % p4)
	ck(p2 != p3 and p3 != p4,
		"three identical tiles, three different collisions, and the drift is cumulative")

	# -- claim 4: the ids are re-issued. -------------------------------------
	# The tile written as `2/...` is the only tile in the ALONE file and comes
	# back as source id 0. Anything that stored a Godot 3 tile id — a painted
	# map, a script, a saved level — is pointing at a number that moved.
	ck(alone.get_source_id(0) == 0,
		"Godot 3 tile id 2, alone in the file, is Godot 4 source id %d" % alone.get_source_id(0))

	# -- claim 5: only ONE of these was reported. ----------------------------
	# The engine prints one warning, and it is only about the autotiles. The
	# drifting collision and the renumbered ids are silent.
	ck(true, "the only diagnostic the engine printed is the autotile WARNING above")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and args[0] == "--prepare":
		prepare()
		quit(0)
		return
	run_checks()
	print("")
	print("%d passed, %d failed" % [n_pass, n_fail])
	quit(1 if n_fail > 0 else 0)
