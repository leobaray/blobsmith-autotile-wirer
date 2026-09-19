extends SceneTree

# Engine gate for the free roads / fences / pipes / streams pack.
#
# The README promises: square cells, a Match Sides terrain set with a tile for
# every one of the 16 side combinations, collision exactly on fence and pipe
# (the post plus one rectangle per connected arm), and that painting with
# set_cells_terrain_connect picks a tile whose four sides agree with the four
# neighbours actually painted, in every cell of a network with a loop, a cross,
# T-junctions, a spur and a lone post.
#
# It also measures the trap the README is about: two parallel lines one cell
# apart. set_cells_terrain_connect joins them into a ladder — even when each line
# is painted by its own call — while set_cells_terrain_path keeps them apart.
#
# Neighbours are asked from the engine (get_neighbor_cell), never computed by
# hand. Enum values are read by NAME, so a future renumber fails loudly.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const SIDES := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE,
]

func mask_of(layer: TileMapLayer, c: Vector2i) -> int:
	var td := layer.get_cell_tile_data(c)
	if td == null:
		return -1
	var m := 0
	for k in range(4):
		if td.get_terrain_peering_bit(SIDES[k]) == 0:
			m |= 1 << k
	return m

# A small network: a 5x5 loop, a cross at its centre, T's where the column and
# the cross-bar meet the loop, a 4-way where a spur leaves it, a dead end, and a
# lone post with no neighbour at all.
func network() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(5):
		cells.append(Vector2i(x, 0))
		cells.append(Vector2i(x, 4))
	for y in range(1, 4):
		cells.append(Vector2i(0, y))
		cells.append(Vector2i(4, y))
		cells.append(Vector2i(2, y))          # a column through the loop: two T's
	cells.append(Vector2i(1, 2))              # (1,2) and (3,2) cross the column at (2,2)
	cells.append(Vector2i(3, 2))              # and join the walls: (0,2) and (4,2) become T's
	for x in range(5, 8):
		cells.append(Vector2i(x, 2))          # spur out of the right side: a T and a dead end
	cells.append(Vector2i(9, 5))              # lone post
	return cells

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://lines/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("LINES: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("LINES: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d line-connector tilesets" % (man as Array).size())

	var cells := network()
	var painted := {}
	for c in cells:
		painted[c] = true
	var first := true
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var collide: bool = entry["collision"]
		var ts: TileSet = load("res://lines/%s.tres" % base)
		ck("L1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("L2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("L3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: sheet is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		ck("L4", src.get_tiles_count() == 16, "%s: 16 tiles in the atlas" % base)
		ck("L5", ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: square cell %dx%d" % [base, T, T])
		ck("L6", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES, "%s: terrain mode is Match Sides" % base)
		ck("L7", ts.get_terrain_name(0, 0) == entry["terrain"], "%s: terrain named '%s'" % [base, entry["terrain"]])

		var masks := {}
		var poly_ok := 0
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			if td == null:
				continue
			var m := 0
			for k in range(4):
				if td.get_terrain_peering_bit(SIDES[k]) == 0:
					m |= 1 << k
			masks[m] = true
			var arms := 0
			for k in range(4):
				if m & (1 << k):
					arms += 1
			if collide:
				if ts.get_physics_layers_count() == 1 and td.get_collision_polygons_count(0) == 1 + arms:
					poly_ok += 1
			elif ts.get_physics_layers_count() == 0:
				poly_ok += 1
		ck("L8", masks.size() == 16, "%s: the 16 tiles cover all 16 side combinations (got %d distinct)" % [base, masks.size()])
		ck("L9", poly_ok == 16, ("%s: 16/16 tiles collide as post + one rectangle per connected arm (got %d)" if collide
			else "%s: no physics layer — walk-over terrain (got %d/16)") % [base, poly_ok])

		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)

		layer.set_cells_terrain_connect(cells, 0, 0, false)
		var agree := 0
		var first_diff := ""
		for c in cells:
			var td := layer.get_cell_tile_data(c)
			var ok := td != null
			if td != null:
				for n in SIDES:
					var want: bool = painted.has(layer.get_neighbor_cell(c, n))
					if invert and first and c == cells[0]:
						want = not want         # --invert: the gate must catch this
					if (td.get_terrain_peering_bit(n) == 0) != want:
						ok = false
			if ok:
				agree += 1
			elif first_diff == "":
				first_diff = " first at %s" % str(c)
		first = false
		ck("L10", agree == cells.size(),
			"%s: connect paints a loop, a cross, T's, a dead end and a lone post: %d/%d cells connect exactly where a neighbour is painted%s"
				% [base, agree, cells.size(), first_diff])
		ck("L11", mask_of(layer, Vector2i(2, 2)) == 15 and mask_of(layer, Vector2i(9, 5)) == 0 and mask_of(layer, Vector2i(7, 2)) == 4,
			"%s: the cross gets the 4-arm tile, the lone post the 0-arm tile, the spur end a single left arm" % base)

		# the trap: two parallel lines, rows 0 and 1, six cells each
		var r0: Array[Vector2i] = []
		var r1: Array[Vector2i] = []
		for x in range(6):
			r0.append(Vector2i(x, 0))
			r1.append(Vector2i(x, 1))
		layer.clear()
		layer.set_cells_terrain_connect(r0, 0, 0)
		layer.set_cells_terrain_connect(r1, 0, 0)
		var rungs := 0
		for c in r0:
			if mask_of(layer, c) & 2 and mask_of(layer, c + Vector2i(0, 1)) & 8:
				rungs += 1
		ck("L12", rungs == 6,
			"%s: connect, one call per line: the two parallel lines are joined into a ladder (%d/6 columns get a rung)" % [base, rungs])

		layer.clear()
		layer.set_cells_terrain_connect(r0 + r1, 0, 0)
		var got := []
		for c in r0 + r1:
			got.append(mask_of(layer, c))
		ck("L12b", got == [3, 7, 7, 7, 7, 6, 9, 13, 13, 13, 13, 12],
			"%s: connect, both lines in one call: the same ladder, masks %s" % [base, str(got)])

		layer.clear()
		layer.set_cells_terrain_path(r0, 0, 0)
		layer.set_cells_terrain_path(r1, 0, 0)
		var clean := 0
		for c in r0 + r1:
			var want := (1 if c.x < 5 else 0) | (4 if c.x > 0 else 0)
			if mask_of(layer, c) == want:
				clean += 1
		ck("L13", clean == 12,
			"%s: path, one call per line: %d/12 cells connect only along their own line (no rungs)" % [base, clean])

		var branch: Array[Vector2i] = [Vector2i(2, 1), Vector2i(2, 2)]
		layer.clear()
		layer.set_cells_terrain_path(r0, 0, 0)
		branch.insert(0, Vector2i(2, 0))
		layer.set_cells_terrain_path(branch, 0, 0)
		ck("L14", mask_of(layer, Vector2i(2, 0)) == 7 and mask_of(layer, Vector2i(1, 0)) == 5 and mask_of(layer, Vector2i(3, 0)) == 5
			and mask_of(layer, Vector2i(2, 1)) == 10 and mask_of(layer, Vector2i(2, 2)) == 8,
			"%s: a branch drawn with path starting ON the line turns that cell into a T and leaves its neighbours alone" % base)

		layer.queue_free()
		root.remove_child(layer)

	if failures == 0:
		print("LINES %d/%d PASS" % [checked, checked])
	else:
		print("LINES: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
