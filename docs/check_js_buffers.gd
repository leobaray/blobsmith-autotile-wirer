extends SceneTree
##
## Loads buffers built OUTSIDE the engine and reports what the engine paints
## from them.
##
## The other direction of dump_tile_map_fixtures.gd. That script proves the JS
## decoder reads engine bytes; this one proves the JS ENCODER writes bytes a
## real TileMapLayer accepts — the direction that matters to anyone generating
## .tscn files from a script, which is the whole audience of the page shipping
## that encoder.
##
##     JS_BUFFERS=/tmp/x.json godot --headless --script check_js_buffers.gd
##
## Input JSON:  [{"name": "...", "bytes": [0, 0, ...]}, ...]
## Output:      one `RESULT {...}` line per case, with the cells the engine read.

func make_layer() -> TileMapLayer:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))

	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)

	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for y in range(2):
		for x in range(2):
			src.create_tile(Vector2i(x, y))
	src.create_alternative_tile(Vector2i(0, 0), 5)
	ts.add_source(src, 7)

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	return layer


func _initialize() -> void:
	var path := OS.get_environment("JS_BUFFERS")
	if path.is_empty():
		push_error("set JS_BUFFERS to the JSON file of buffers to check")
		quit(2)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot read " + path)
		quit(2)
		return
	var cases: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(cases) != TYPE_ARRAY:
		push_error("expected a JSON array of {name, bytes}")
		quit(2)
		return

	for c in cases:
		var data := PackedByteArray()
		for b in c["bytes"]:
			data.append(int(b))
		var layer := make_layer()
		layer.tile_map_data = data

		var used := layer.get_used_cells()
		used.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.y < b.y if a.y != b.y else a.x < b.x)
		var cells: Array = []
		for coord in used:
			var raw: int = layer.get_cell_alternative_tile(coord) & 0xFFFF
			var atlas: Vector2i = layer.get_cell_atlas_coords(coord)
			cells.append({
				"x": coord.x, "y": coord.y,
				"source_id": layer.get_cell_source_id(coord),
				"atlas_x": atlas.x, "atlas_y": atlas.y,
				"alternative": raw & 0x0FFF,
				"flip_h": (raw & 0x1000) != 0,
				"flip_v": (raw & 0x2000) != 0,
				"transpose": (raw & 0x4000) != 0,
			})

		# Re-serializing is its own check: the engine's own bytes for the map it
		# just built from ours. Identical bytes mean we wrote what it writes.
		print("RESULT " + JSON.stringify({
			"name": c["name"],
			"cells": cells,
			"reserialized": Array(layer.tile_map_data),
		}))
		layer.queue_free()

	quit(0)
