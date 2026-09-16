extends SceneTree

# Asks a real Godot 4 engine every claim in docs/why-my-isometric-tilemap-is-not-a-diamond.md.
# Nothing here is asserted from the docs or from analogy with the square shape:
# each number below was first printed by an exploratory pass on 4.3, 4.4 and 4.7
# and only then written down as an expectation.
#
#   godot --headless --path <proj> --script verify_isometric_layout.gd [-- --invert]
#
# --invert flips two expectations on purpose, so a run that cannot fail is visible.

var failures := 0
var checks := 0
var invert := false

func ck(id: String, got, want, why: String) -> void:
	checks += 1
	if invert and (id == "I3a" or id == "I9a"):
		want = "deliberately wrong"
	var ok = str(got) == str(want)
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + "  got=" + str(got) + " want=" + str(want))

func _init():
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true

	var ts := TileSet.new()
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	get_root().add_child(layer)

	# ---- I1: the shape and the layout are two independent properties --------
	ck("I1a", ts.tile_layout, TileSet.TILE_LAYOUT_STACKED,
		"a fresh TileSet starts at layout Stacked (0), not a diamond layout")
	ts.tile_size = Vector2i(64, 32)
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ck("I1b", ts.tile_layout, TileSet.TILE_LAYOUT_STACKED,
		"switching tile_shape to Isometric leaves tile_layout untouched")

	# ---- I2: Isometric + the default layout is NOT a diamond ----------------
	# This is the whole bug report: the cell to the right still steps a full
	# tile width in x, exactly as on a square grid. Only y moves.
	ck("I2a", layer.map_to_local(Vector2i(1, 0)), Vector2(96, 16),
		"Isometric + Stacked: (1,0) steps a whole tile width in x, like a square grid")
	ck("I2b", layer.map_to_local(Vector2i(0, 1)), Vector2(64, 32),
		"Isometric + Stacked: (0,1) steps half a width across and a full height down")

	# ---- I3: Diamond Right is the layout that produces the diamond ----------
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_RIGHT
	ck("I3a", layer.map_to_local(Vector2i(1, 0)), Vector2(64, 0),
		"Diamond Right: +x walks up-right by half a tile in each axis")
	ck("I3b", layer.map_to_local(Vector2i(0, 1)), Vector2(64, 32),
		"Diamond Right: +y walks down-right by half a tile in each axis")
	ck("I3c", layer.map_to_local(Vector2i(1, 1)), Vector2(96, 16),
		"Diamond Right: (1,1) is one full tile width to the right of (0,0)")

	# ---- I4: Stairs Right is not a different layout at this tile size -------
	ts.tile_layout = TileSet.TILE_LAYOUT_STAIRS_RIGHT
	var stairs := [layer.map_to_local(Vector2i(1, 0)), layer.map_to_local(Vector2i(0, 1)),
		layer.map_to_local(Vector2i(1, 1))]
	ts.tile_layout = TileSet.TILE_LAYOUT_STACKED
	var stacked := [layer.map_to_local(Vector2i(1, 0)), layer.map_to_local(Vector2i(0, 1)),
		layer.map_to_local(Vector2i(1, 1))]
	ck("I4", str(stairs), str(stacked),
		"Stairs Right and Stacked place these three cells identically")

	# ---- I5: tile_offset_axis does nothing on Isometric ---------------------
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_RIGHT
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	var iso_h := layer.map_to_local(Vector2i(1, 0))
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_VERTICAL
	ck("I5a", layer.map_to_local(Vector2i(1, 0)), iso_h,
		"Isometric: flipping tile_offset_axis moves nothing")
	# control: the same property on the two shapes that do use it
	ts.tile_shape = TileSet.TILE_SHAPE_HALF_OFFSET_SQUARE
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	var half_h := layer.map_to_local(Vector2i(1, 0))
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_VERTICAL
	ck("I5b", layer.map_to_local(Vector2i(1, 0)) != half_h, true,
		"control: on Half-Offset Square the same property does move the cell")
	ts.tile_shape = TileSet.TILE_SHAPE_HEXAGON
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	var hex_h := layer.map_to_local(Vector2i(1, 0))
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_VERTICAL
	ck("I5c", layer.map_to_local(Vector2i(1, 0)) != hex_h, true,
		"control: on Hexagon it moves the cell too")

	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_RIGHT
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL

	# ---- I6: the world origin is not inside cell (0,0) ----------------------
	ck("I6a", layer.map_to_local(Vector2i(0, 0)), Vector2(32, 16),
		"map_to_local returns the CENTRE of the diamond, not its top-left")
	ck("I6b", layer.local_to_map(Vector2(0, 0)), Vector2i(0, -1),
		"the point (0,0) in local space falls in cell (0,-1), not (0,0)")

	# ---- I7: the round trip is exact ---------------------------------------
	var round_ok := true
	for c in [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1), Vector2i(2,0),
			Vector2i(0,2), Vector2i(-1,0), Vector2i(-3,7)]:
		if layer.local_to_map(layer.map_to_local(c)) != c:
			round_ok = false
	ck("I7", round_ok, true, "local_to_map(map_to_local(c)) == c for every cell tried")

	# ---- I8: tall art is texture_origin, never tile_size --------------------
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(64, 64)   # art twice as tall as the grid
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src)
	var td := src.get_tile_data(Vector2i(0, 0), 0)
	ck("I8a", td.texture_origin, Vector2i(0, 0), "texture_origin starts at zero")
	var before := layer.map_to_local(Vector2i(1, 1))
	td.texture_origin = Vector2i(0, -16)
	ck("I8b", layer.map_to_local(Vector2i(1, 1)), before,
		"texture_origin shifts the drawing and leaves the logical grid alone")
	ck("I8c", ts.tile_size, Vector2i(64, 32),
		"and tile_size is still the grid, not the art")

	# ---- I9: square and isometric take OPPOSITE neighbour constants ---------
	# A failed get_neighbor_cell returns the cell it was given. It prints an
	# error, but the value a script reads is a silent no-op.
	var sq := TileSet.new()
	sq.tile_size = Vector2i(64, 32)
	var sq_layer := TileMapLayer.new()
	sq_layer.tile_set = sq
	get_root().add_child(sq_layer)
	ck("I9a", layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE), Vector2i(0, 0),
		"Isometric: RIGHT_SIDE is not a side of a diamond, so the cell does not move")
	ck("I9b", sq_layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE), Vector2i(1, 0),
		"Square: the same constant does move one cell right")
	ck("I9c", layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE), Vector2i(0, 1),
		"Isometric: BOTTOM_RIGHT_SIDE is the +y neighbour")
	ck("I9d", layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE), Vector2i(1, 0),
		"Isometric: TOP_RIGHT_SIDE is the +x neighbour")
	ck("I9e", layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE), Vector2i(-1, 0),
		"Isometric: BOTTOM_LEFT_SIDE is the -x neighbour")
	ck("I9f", layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE), Vector2i(0, -1),
		"Isometric: TOP_LEFT_SIDE is the -y neighbour")
	ck("I9g", sq_layer.get_neighbor_cell(Vector2i(0,0), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE), Vector2i(0, 0),
		"Square: BOTTOM_RIGHT_SIDE is the one that does nothing")

	print("ISOMETRIC %d/%d PASS" % [checks - failures, checks])
	quit(1 if failures > 0 else 0)
