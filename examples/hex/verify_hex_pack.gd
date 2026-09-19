extends SceneTree

# Engine gate for the free hexagon terrain pack.
#
# The README promises: the cell is a hexagon on the stated offset axis, the
# terrain set is Match Sides with a tile for every one of the 64 side
# combinations, the collision polygon is the hexagon, and painting with
# set_cells_terrain_connect picks a tile whose six sides agree with the six
# neighbours actually painted — in every cell, not just an interior one.
#
# That last check is the one that could quietly be wrong: hexagon peering-bit
# names depend on tile_offset_axis (the same name reaches a different cell on
# each axis), so a pack wired with the other axis's names would still load and
# still fill an island, and disagree here. The neighbour for each bit is asked
# from the engine (get_neighbor_cell), never computed by hand.
#
# Enum values are read by NAME, so a future renumber fails loudly.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const POINTY_SIDES := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE,
]
const FLAT_SIDES := [
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE,
]

# A ragged island with holes and a one-cell spur, so single-neighbour and
# all-but-one masks both occur, on odd and even rows/columns alike.
func paint_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(8):
		for x in range(9):
			if Vector2i(x, y) in [Vector2i(3, 3), Vector2i(4, 3), Vector2i(6, 5), Vector2i(2, 6)]:
				continue                      # holes
			if (x == 8 and y > 2) or (y == 7 and x < 3):
				continue                      # ragged edges
			cells.append(Vector2i(x, y))
	cells.append(Vector2i(9, 1))              # a spur: exactly one neighbour
	return cells

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://hex/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("HEX: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("HEX: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d hexagon tilesets" % (man as Array).size())

	var cells := paint_cells()
	var painted := {}
	for c in cells:
		painted[c] = true
	var first_cell := true
	for entry in man:
		var base: String = entry["base"]
		var pointy: bool = entry["orientation"] == "pointy"
		var T: int = int(entry["tile_size"])
		var sides: Array = POINTY_SIDES if pointy else FLAT_SIDES
		var ts: TileSet = load("res://hex/%s.tres" % base)
		ck("H1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("H2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("H3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: sheet is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		ck("H4", src.get_tiles_count() == 64, "%s: 64 tiles in the atlas" % base)
		ck("H5", ts.tile_shape == TileSet.TILE_SHAPE_HEXAGON, "%s: tile_shape is Hexagon" % base)
		var want_axis := TileSet.TILE_OFFSET_AXIS_HORIZONTAL if pointy else TileSet.TILE_OFFSET_AXIS_VERTICAL
		ck("H6", ts.tile_offset_axis == want_axis, "%s: tile_offset_axis is %s (%s-top)"
			% [base, "Horizontal" if pointy else "Vertical", "pointy" if pointy else "flat"])
		ck("H7", ts.tile_size == Vector2i(T, T), "%s: cell is %dx%d" % [base, T, T])
		ck("H8", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES, "%s: terrain mode is Match Sides" % base)
		ck("H9", ts.get_terrain_name(0, 0) == entry["terrain"], "%s: terrain named '%s'" % [base, entry["terrain"]])
		ck("H10", ts.get_physics_layers_count() == 1, "%s: one physics layer" % base)

		var h := T / 2.0
		var q := T / 4.0
		var want_poly := PackedVector2Array([Vector2(0, -h), Vector2(h, -q), Vector2(h, q), Vector2(0, h), Vector2(-h, q), Vector2(-h, -q)]) if pointy \
			else PackedVector2Array([Vector2(-h, 0), Vector2(-q, -h), Vector2(q, -h), Vector2(h, 0), Vector2(q, h), Vector2(-q, h)])
		var hex_polys := 0
		var masks := {}
		for i in range(src.get_tiles_count()):
			var td := src.get_tile_data(src.get_tile_id(i), 0)
			if td == null:
				continue
			if td.get_collision_polygons_count(0) == 1 and td.get_collision_polygon_points(0, 0) == want_poly:
				hex_polys += 1
			var m := 0
			for k in range(6):
				if td.get_terrain_peering_bit(sides[k]) == 0:
					m |= 1 << k
			masks[m] = true
		ck("H11", hex_polys == 64, "%s: 64/64 tiles carry the hexagon collision polygon (got %d)" % [base, hex_polys])
		ck("H12", masks.size() == 64, "%s: the 64 tiles cover all 64 side combinations (got %d distinct)" % [base, masks.size()])

		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		var step := layer.map_to_local(Vector2i(0, 1)) - layer.map_to_local(Vector2i(0, 0)) if pointy \
			else layer.map_to_local(Vector2i(1, 0)) - layer.map_to_local(Vector2i(0, 0))
		var want_step := Vector2(T / 2.0, T * 0.75) if pointy else Vector2(T * 0.75, T / 2.0)
		ck("H13", step == want_step, "%s: the next %s is offset by %s (3/4-cell spacing, half-cell stagger)"
			% [base, "row" if pointy else "column", str(want_step)])

		layer.set_cells_terrain_connect(cells, 0, 0, false)
		var filled := 0
		var agree := 0
		var first_diff := ""
		for c in cells:
			if layer.get_cell_source_id(c) != -1:
				filled += 1
			var td := layer.get_cell_tile_data(c)
			var ok := td != null
			if td != null:
				for n in sides:
					var want: bool = painted.has(layer.get_neighbor_cell(c, n))
					if invert and first_cell and c == cells[0]:
						want = not want         # --invert: the gate must catch this
					if (td.get_terrain_peering_bit(n) == 0) != want:
						ok = false
			if ok:
				agree += 1
			elif first_diff == "":
				first_diff = " first at %s" % str(c)
		first_cell = false
		ck("H14", filled == cells.size(), "%s: terrain paint filled all %d cells (got %d)" % [base, cells.size(), filled])
		ck("H15", agree == cells.size(),
			"%s: in %d/%d painted cells all 6 sides connect exactly where a neighbour is painted%s"
				% [base, agree, cells.size(), first_diff])

		# the trap the README warns about, measured: the same tileset switched to the
		# other offset axis still loads and still fills the island, but its bit names
		# now point at other neighbours, so cells come out with the wrong edges
		ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_VERTICAL if pointy else TileSet.TILE_OFFSET_AXIS_HORIZONTAL
		var other: Array = FLAT_SIDES if pointy else POINTY_SIDES
		layer.clear()
		layer.set_cells_terrain_connect(cells, 0, 0, false)
		var filled2 := 0
		var wrong := 0
		for c in cells:
			if layer.get_cell_source_id(c) != -1:
				filled2 += 1
			var td := layer.get_cell_tile_data(c)
			if td == null:
				continue
			for n in other:
				if (td.get_terrain_peering_bit(n) == 0) != painted.has(layer.get_neighbor_cell(c, n)):
					wrong += 1
					break
		ck("H16", filled2 == cells.size() and wrong > 0,
			"%s: switched to the other offset axis it still fills %d/%d cells, and %d of them get the wrong edges"
				% [base, filled2, cells.size(), wrong])
		ts.tile_offset_axis = want_axis

		layer.queue_free()
		root.remove_child(layer)

	if failures == 0:
		print("HEX %d/%d PASS" % [checked, checked])
	else:
		print("HEX: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
