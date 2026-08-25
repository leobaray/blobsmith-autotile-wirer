# Builds res://scripted.tscn: the case docs/convert_tilemap_to_tilemaplayer.js
# refuses by default — a `TileMap` with a script on it. Roughly one real TileMap
# in six is this, measured on godot-demo-projects at branch 4.2.
#
#   godot --headless --path <proj> --script make_scripted_tilemap_fixture.gd
#
# Mentions no type that arrived after Godot 4.2 so it runs on the last engine
# before TileMapLayer existed — the engine the projects that need this were
# written on. Driven by docs/verify_tilemap_script_api.sh.
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

	for x in range(-2, 3):
		tm.set_cell(0, Vector2i(x, 1), src_id, Vector2i(3, 0), 0)
	tm.set_cell(0, Vector2i(0, 0), src_id, Vector2i(1, 2), 0)
	tm.erase_cell(0, Vector2i(-2, 1))
	tm.set_cell(1, Vector2i(5, -7), src_id, Vector2i(0, 0), 0)
	tm.set_cell(1, Vector2i(-300, 400), src_id, Vector2i(2, 1), 0)
	tm.set_cell(1, Vector2i(1, 1), src_id, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_FLIP_H)
	tm.set_cell(1, Vector2i(3, 1), src_id, Vector2i(0, 0), 1)
	tm.set_cell(2, Vector2i(9, 9), src_id, Vector2i(2, 2), 0)

	# The script is the whole point of this fixture.
	tm.set_script(load("res://tilemap_probe.gd"))

	root.add_child(tm)
	tm.owner = root

	var ps := PackedScene.new()
	ps.pack(root)
	var err := ResourceSaver.save(ps, "res://scripted.tscn")
	var text := FileAccess.get_file_as_string("res://scripted.tscn")
	var ok := err == OK and text.contains("script = ExtResource") and text.contains("layer_0/tile_data")
	print("SCRIPTED FIXTURE  engine=%s  saved=%s  script=%s  tile_data=%s"
		% [Engine.get_version_info().string, str(err == OK),
			str(text.contains("script = ExtResource")), str(text.contains("layer_0/tile_data"))])
	quit(0 if ok else 1)
