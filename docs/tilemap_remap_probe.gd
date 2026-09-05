extends SceneTree
##
## The engine half of the /godot-tilemap-remap-tiles/ proof.
##
## Two modes, both driven by test/tilemap-remap.test.js:
##
##   MODE=make  godot --headless --path <proj> --script tilemap_remap_probe.gd
##     Writes a project whose SHEET MOVED: old_tileset.tres lays its eight tiles
##     out 4 wide, new_tileset.tres lays the same eight, in the same reading
##     order, 2 wide. Every tile carries its name in a custom data layer, so a
##     cell can be asked WHICH tile it resolves to instead of merely which
##     coordinate it points at. Then paints painted.tscn against the old sheet
##     and saves it - the .tscn under test is written by the engine, not by us.
##
##   MODE=read SCENE=res://x.tscn [TILESET=res://new_tileset.tres]
##     Loads the scene, optionally swaps in another TileSet, and prints one
##     RESULT line of JSON: for every used cell its coordinates, what it points
##     at, and the name of the tile that actually resolves - "MISSING" when the
##     coordinate no longer holds a tile. That last field is the whole point:
##     it is the difference between "the file still loads" and "the map is
##     still right".

const NAMES := ["A", "B", "C", "D", "E", "F", "G", "H"]
const TILE := 16

func _sheet(cols: int, rows: int) -> ImageTexture:
	var img := Image.create(cols * TILE, rows * TILE, false, Image.FORMAT_RGBA8)
	for i in range(NAMES.size()):
		var x := (i % cols) * TILE
		var y := (i / cols) * TILE
		var c := Color.from_hsv(float(i) / float(NAMES.size()), 0.8, 0.9)
		img.fill_rect(Rect2i(x, y, TILE, TILE), c)
	return ImageTexture.create_from_image(img)


func _build_tileset(cols: int, rows: int) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(0, "name")
	ts.set_custom_data_layer_type(0, TYPE_STRING)

	var src := TileSetAtlasSource.new()
	src.texture = _sheet(cols, rows)
	src.texture_region_size = Vector2i(TILE, TILE)
	# The source has to belong to the TileSet before any TileData is touched:
	# set_custom_data() reaches back through the tile's owner for the layer
	# names, and on an orphan source it fails with "Parameter tile_set is null".
	ts.add_source(src, 0)
	for i in range(NAMES.size()):
		var coords := Vector2i(i % cols, i / cols)
		src.create_tile(coords)
		src.get_tile_data(coords, 0).set_custom_data("name", NAMES[i])
		if i == 0:
			# One alternative, on the first tile of both sheets: a remap has to
			# carry the alternative id across, and the destination has to own it.
			var alt := src.create_alternative_tile(coords, 1)
			src.get_tile_data(coords, alt).set_custom_data("name", NAMES[i] + "#alt")
	return ts


func _make() -> int:
	var old_ts := _build_tileset(4, 2)
	var new_ts := _build_tileset(2, 4)
	if ResourceSaver.save(old_ts, "res://old_tileset.tres") != OK:
		push_error("cannot save old_tileset.tres")
		return 2
	if ResourceSaver.save(new_ts, "res://new_tileset.tres") != OK:
		push_error("cannot save new_tileset.tres")
		return 2

	var layer := TileMapLayer.new()
	layer.name = "Ground"
	layer.tile_set = load("res://old_tileset.tres")
	# Eight cells in a row, one per tile, in sheet reading order.
	for i in range(NAMES.size()):
		layer.set_cell(Vector2i(i, 0), 0, Vector2i(i % 4, i / 4), 0)
	# A flipped cell, an alternative, and an erased one: the three things a
	# rewrite is most likely to lose.
	layer.set_cell(Vector2i(2, 1), 0, Vector2i(2, 0), 0)
	# A flipped cell: the transform lives in the high bits of the same field
	# that carries the alternative id, so a rewrite that touches one can lose
	# the other. Both are in the scene on purpose.
	layer.set_cell(Vector2i(1, 1), 0, Vector2i(5 % 4, 5 / 4), TileSetAtlasSource.TRANSFORM_FLIP_H)
	layer.set_cell(Vector2i(3, 1), 0, Vector2i(0, 0), 1)
	layer.set_cell(Vector2i(4, 1), 0, Vector2i(1, 0), 0)
	layer.erase_cell(Vector2i(4, 1))

	var root_node := Node2D.new()
	root_node.name = "Level"
	root_node.add_child(layer)
	layer.owner = root_node

	var packed := PackedScene.new()
	if packed.pack(root_node) != OK:
		push_error("cannot pack the scene")
		return 2
	if ResourceSaver.save(packed, "res://painted.tscn") != OK:
		push_error("cannot save painted.tscn")
		return 2
	print("MADE ok")
	return 0


func _read() -> int:
	var scene_path := OS.get_environment("SCENE")
	if scene_path.is_empty():
		push_error("set SCENE")
		return 2
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("cannot load " + scene_path)
		return 2
	var inst := packed.instantiate()
	var layer := inst.get_node("Ground") as TileMapLayer
	if layer == null:
		push_error("no Ground TileMapLayer in " + scene_path)
		return 2

	var swap := OS.get_environment("TILESET")
	if not swap.is_empty():
		var ts: TileSet = load(swap)
		if ts == null:
			push_error("cannot load " + swap)
			return 2
		layer.tile_set = ts

	var cells := []
	for c in layer.get_used_cells():
		var td := layer.get_cell_tile_data(c)
		var atlas := layer.get_cell_atlas_coords(c)
		cells.append({
			"x": c.x, "y": c.y,
			"source": layer.get_cell_source_id(c),
			"atlas_x": atlas.x, "atlas_y": atlas.y,
			"alternative": layer.get_cell_alternative_tile(c),
			"flip_h": (layer.get_cell_alternative_tile(c) & TileSetAtlasSource.TRANSFORM_FLIP_H) != 0,
			"tile": "MISSING" if td == null else str(td.get_custom_data("name")),
		})
	cells.sort_custom(func(a, b): return a["y"] < b["y"] if a["y"] != b["y"] else a["x"] < b["x"])
	print("RESULT " + JSON.stringify({"engine": Engine.get_version_info()["string"], "cells": cells}))
	return 0


func _initialize() -> void:
	var mode := OS.get_environment("MODE")
	var code := 0
	match mode:
		"make": code = _make()
		"read": code = _read()
		_:
			push_error("set MODE to make or read")
			code = 2
	quit(code)
