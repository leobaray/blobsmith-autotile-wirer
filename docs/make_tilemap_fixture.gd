# Builds the legacy `TileMap` scene that docs/verify_tilemap_convert.gd checks the
# conversion of, and saves it as res://legacy.tscn.
#
#   godot --headless --path <proj> --script make_tilemap_fixture.gd
#
# It lives in its own file, and mentions no type that arrived after it, precisely
# so it also runs on **Godot 4.2** — the last version before `TileMapLayer`
# existed. That is the migration people actually have: a project written when
# TileMap was the only option. A fixture built by the newest engine would quietly
# assume the file on disk already looks modern.
#
# The scene is deliberately awkward: every per-layer key set to a non-default, an
# erased cell, an empty layer, negative and near-int16 coordinates, all three
# transform flags, a real alternative tile, a child node under the TileMap and a
# second TileMap deeper in the tree.
extends SceneTree

func _init() -> void:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.7, 0.3))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for y in 4:
		for x in 4:
			src.create_tile(Vector2i(x, y))
	# A real alternative tile, so the alternative field carries an id AND flags
	# rather than only flags.
	src.create_alternative_tile(Vector2i(0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(src, 3)
	var src_id := 3

	var root := Node2D.new()
	root.name = "World"

	var tm := TileMap.new()
	tm.name = "TileMap"
	tm.tile_set = ts
	tm.position = Vector2(8, -4)
	tm.rendering_quadrant_size = 32
	tm.collision_animatable = true
	tm.collision_visibility_mode = TileMap.VISIBILITY_MODE_FORCE_SHOW
	tm.navigation_visibility_mode = TileMap.VISIBILITY_MODE_FORCE_HIDE

	tm.set_layer_name(0, "Ground")
	tm.add_layer(-1)
	tm.set_layer_name(1, "Walls")
	tm.set_layer_modulate(1, Color(1, 0.5, 0.25, 0.8))
	tm.set_layer_y_sort_enabled(1, true)
	tm.set_layer_y_sort_origin(1, 7)
	tm.set_layer_z_index(1, 3)
	tm.add_layer(-1)
	tm.set_layer_name(2, "Deco")
	tm.set_layer_enabled(2, false)
	tm.set_layer_navigation_enabled(2, false)

	# Ground: a run, plus one erased cell — the record Godot keeps in the file.
	for x in range(-2, 3):
		tm.set_cell(0, Vector2i(x, 1), src_id, Vector2i(3, 0), 0)
	tm.set_cell(0, Vector2i(0, 0), src_id, Vector2i(1, 2), 0)
	tm.erase_cell(0, Vector2i(-2, 1))

	# Walls: negative coordinates, near-int16 coordinates, all three transform
	# flags, and the alternative tile created above (with and without flags).
	tm.set_cell(1, Vector2i(5, -7), src_id, Vector2i(0, 0), 0)
	tm.set_cell(1, Vector2i(-300, 400), src_id, Vector2i(2, 1), 0)
	tm.set_cell(1, Vector2i(30000, -30000), src_id, Vector2i(1, 1), 0)
	tm.set_cell(1, Vector2i(1, 1), src_id, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_FLIP_H)
	tm.set_cell(1, Vector2i(2, 1), src_id, Vector2i(0, 0),
		TileSetAtlasSource.TRANSFORM_FLIP_V | TileSetAtlasSource.TRANSFORM_TRANSPOSE)
	tm.set_cell(1, Vector2i(3, 1), src_id, Vector2i(0, 0), 1)
	tm.set_cell(1, Vector2i(4, 1), src_id, Vector2i(0, 0),
		1 | TileSetAtlasSource.TRANSFORM_FLIP_H | TileSetAtlasSource.TRANSFORM_FLIP_V
		| TileSetAtlasSource.TRANSFORM_TRANSPOSE)
	# Deco stays empty on purpose: an empty layer has no tile_data line at all.

	root.add_child(tm)
	tm.owner = root
	# A child of the TileMap. Its parent= path must survive the conversion, which
	# is the whole reason the TileMap becomes a Node2D of the same name.
	var pin := Marker2D.new()
	pin.name = "SpawnPoint"
	pin.position = Vector2(48, 16)
	tm.add_child(pin)
	pin.owner = root

	# A second TileMap, deeper, sharing the TileSet: proves the parent path of the
	# generated layers is the full path, not just the node name.
	var level := Node2D.new()
	level.name = "Level"
	root.add_child(level)
	level.owner = root
	var tm2 := TileMap.new()
	tm2.name = "Background"
	tm2.tile_set = ts
	tm2.set_layer_name(0, "Sky")
	tm2.set_cell(0, Vector2i(0, 0), src_id, Vector2i(2, 2), 0)
	level.add_child(tm2)
	tm2.owner = root

	var ps := PackedScene.new()
	ps.pack(root)
	var err := ResourceSaver.save(ps, "res://legacy.tscn")
	var text := FileAccess.get_file_as_string("res://legacy.tscn")
	var ok := err == OK and text.contains("format = 2") and text.contains("layer_0/tile_data")
	print("FIXTURE  engine=%s  saved=%s  format2=%s  tile_data=%s"
		% [Engine.get_version_info().string, str(err == OK),
			str(text.contains("format = 2")), str(text.contains("layer_0/tile_data"))])
	quit(0 if ok else 1)
