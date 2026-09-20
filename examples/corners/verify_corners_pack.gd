extends SceneTree

# Engine gate for the free corner-terrain pack (grass / sand / snow / lava).
#
# The README promises: square cells, a MATCH CORNERS terrain set with a tile for
# every one of the 16 corner combinations, 16 tiles instead of the 47 a
# corners-and-sides terrain needs, no collision, and one rule for what
# set_cells_terrain_connect paints:
#
#   a corner of a cell is terrain exactly when at least one of the four cells
#   that meet at that corner was painted.
#
# That rule is what makes the two facts the README is about: painting spills a
# one-cell ring OUTSIDE the cells you listed (the boundary is drawn there), and
# two cells that touch only diagonally come out joined through the shared corner.
#
# The four cells meeting at a corner are asked from the engine
# (get_neighbor_cell with the side and corner neighbours), never computed by
# hand. Enum values are read by NAME, so a future renumber fails loudly.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const CORNERS := [
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
]
# the two sides that meet the same corner, in the order of CORNERS
const SIDE_PAIRS := [
	[TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
	[TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
	[TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE],
]

func mask_of(layer: TileMapLayer, c: Vector2i) -> int:
	var td := layer.get_cell_tile_data(c)
	if td == null:
		return -1
	var m := 0
	for k in range(4):
		if td.get_terrain_peering_bit(CORNERS[k]) == 0:
			m |= 1 << k
	return m

# the four cells that meet at corner k of cell c, from the engine
func corner_cells(layer: TileMapLayer, c: Vector2i, k: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = [c, layer.get_neighbor_cell(c, CORNERS[k])]
	for s in SIDE_PAIRS[k]:
		out.append(layer.get_neighbor_cell(c, s))
	return out

func want_mask(layer: TileMapLayer, c: Vector2i, painted: Dictionary) -> int:
	var m := 0
	for k in range(4):
		for n in corner_cells(layer, c, k):
			if painted.has(n):
				m |= 1 << k
				break
	return m

# A shape with a straight run, an L, a one-cell hole, a diagonal touch and a
# lone cell: every kind of corner a terrain can produce.
func shape() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(5):
		for y in range(4):
			if Vector2i(x, y) == Vector2i(2, 1):
				continue            # the hole
			cells.append(Vector2i(x, y))
	cells.append(Vector2i(5, 4))    # touches the block only at one corner
	cells.append(Vector2i(8, 8))    # lone cell
	return cells

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://corners/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("CORNERS: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("CORNERS: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d corner-terrain tilesets" % (man as Array).size())

	var cells := shape()
	var painted := {}
	for c in cells:
		painted[c] = true
	var first := true
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var ts: TileSet = load("res://corners/%s.tres" % base)
		ck("C1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("C2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("C3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: sheet is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		ck("C4", src.get_tiles_count() == 16,
			"%s: 16 tiles in the atlas — a corners-and-sides terrain of the same shape needs 47" % base)
		ck("C5", ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: square cell %dx%d" % [base, T, T])
		ck("C6", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS,
			"%s: terrain mode is Match Corners" % base)
		ck("C7", ts.get_terrain_name(0, 0) == entry["terrain"], "%s: terrain named '%s'" % [base, entry["terrain"]])
		ck("C8", ts.get_physics_layers_count() == 0, "%s: no physics layer — walk-over terrain" % base)

		var masks := {}
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			if td == null:
				continue
			var m := 0
			for k in range(4):
				if td.get_terrain_peering_bit(CORNERS[k]) == 0:
					m |= 1 << k
			masks[m] = coords
		ck("C9", masks.size() == 16, "%s: the 16 tiles cover all 16 corner combinations (got %d distinct)" % [base, masks.size()])

		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		layer.set_cells_terrain_connect(cells, 0, 0, false)

		# every cell of the painted set and of its one-cell ring
		var region := {}
		for c in cells:
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					region[c + Vector2i(dx, dy)] = true
		var agree := 0
		var off: Array[Vector2i] = []
		var ring := 0
		for c in region.keys():
			var want := want_mask(layer, c, painted)
			if invert and first and c == cells[0]:
				want = 0                      # --invert: the gate must catch this
			var got := mask_of(layer, c)
			if got == want or (want == 0 and got == -1):
				agree += 1
			else:
				off.append(c)
			if want > 0 and not painted.has(c):
				ring += 1
		first = false
		var only_hole: Array[Vector2i] = [Vector2i(2, 1)]
		ck("C10", agree == region.size() - 1 and off == only_hole,
			"%s: connect over a block with a hole, a diagonal touch and a lone cell: %d/%d cells carry terrain on a corner exactly where a painted cell touches it, and the only cell that does not is the one-cell hole (off: %s)"
				% [base, agree, region.size(), str(off)])
		ck("C11", ring == 35 and mask_of(layer, Vector2i(-1, -1)) == 1,
			"%s: the boundary is drawn OUTSIDE what you listed — %d cells nobody listed got a tile, and the cell diagonally off the top-left corner carries terrain on that one corner" % [base, ring])
		ck("C12", mask_of(layer, Vector2i(2, 1)) == 14,
			"%s: a one-cell hole does not survive — it comes back as a notch on one corner (mask %d), not a hole" % [base, mask_of(layer, Vector2i(2, 1))])
		ck("C13", mask_of(layer, Vector2i(5, 3)) == 7 and mask_of(layer, Vector2i(4, 4)) == 13,
			"%s: the cell touching the block only at a corner joins through it — the two cells beside the touch carry terrain on the corners they share with it" % base)
		ck("C14", mask_of(layer, Vector2i(8, 8)) == 15 and mask_of(layer, Vector2i(7, 7)) == 1,
			"%s: a single painted cell comes out solid, with its eight neighbours carrying the edge" % base)

		# the smallest hole that survives: 2x2, each cell clearing the corner that faces the middle
		var block: Array[Vector2i] = []
		for x in range(6):
			for y in range(6):
				if x >= 2 and x <= 3 and y >= 2 and y <= 3:
					continue
				block.append(Vector2i(x, y))
		layer.clear()
		layer.set_cells_terrain_connect(block, 0, 0, false)
		ck("C16", mask_of(layer, Vector2i(2, 2)) == 14 and mask_of(layer, Vector2i(3, 2)) == 13
			and mask_of(layer, Vector2i(2, 3)) == 7 and mask_of(layer, Vector2i(3, 3)) == 11,
			"%s: a 2x2 hole does survive — its four cells each clear the corner facing the middle" % base)
		layer.clear()
		layer.set_cells_terrain_connect(cells, 0, 0, false)

		var used := {}
		for c in region.keys():
			if mask_of(layer, c) >= 0:
				used[layer.get_cell_atlas_coords(c)] = true
		ck("C15", used.size() <= 16 and used.size() >= 12,
			"%s: painting that shape used %d of the 16 atlas tiles" % [base, used.size()])

		# the switch the README documents: give EVERY tile the terrain (not just the
		# solid one) and the engine stops writing outside the cells you listed —
		# the boundary moves inside the painted area instead.
		layer.clear()
		for i in range(src.get_tiles_count()):
			var td2 := src.get_tile_data(src.get_tile_id(i), 0)
			td2.terrain_set = 0
			td2.terrain = 0
		layer.set_cells_terrain_connect(cells, 0, 0, false)
		var outside := 0
		for c in region.keys():
			if not painted.has(c) and mask_of(layer, c) >= 0:
				outside += 1
		ck("C17", outside == 0 and mask_of(layer, Vector2i(8, 8)) == 0,
			"%s: with every tile given the terrain, connect writes nothing outside the listed cells (%d) and a lone cell comes out with no terrain on any corner" % [base, outside])
		ts = null

		layer.queue_free()
		root.remove_child(layer)

	if failures == 0:
		print("CORNERS %d/%d PASS" % [checked, checked])
	else:
		print("CORNERS: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
