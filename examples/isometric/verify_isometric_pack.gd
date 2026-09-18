extends SceneTree

# Engine gate for the free isometric 47-blob pack.
#
# The README promises a stranger three things a square tileset cannot give:
# the cell is a diamond (shape AND layout), the collision polygon is that
# diamond rather than its bounding box, and the terrain wiring still picks the
# right tile. The first two are properties; the third is the one that could
# quietly be wrong, because the pack's peering bits are the SQUARE pack's bits
# under a rename (right_side -> top_right_side, and so on round the ring).
#
# So the last check is not "does it paint" but "does it paint THE SAME": the
# same cells are painted on the isometric tileset and on the square starter
# tileset of the same terrain and size, and every cell must land on the same
# atlas coordinate. If the rename were rotated by one step the shapes would
# still fill, still look plausible, and disagree here.
#
# The enum values are read from TileSet by NAME. Asserting `tile_shape == 1`
# would keep passing if Godot ever renumbered the enum and the pack started
# shipping half-offset squares.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const ISO_SIDES := [
	TileSet.CELL_NEIGHBOR_TOP_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_SIDE,
]
const ISO_CORNERS := [
	TileSet.CELL_NEIGHBOR_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_CORNER,
]

# A deliberately ragged region: a solid rectangle only ever exercises a handful
# of the 47 masks, so a rename that is wrong on the diagonals would not show.
func paint_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for y in range(6):
		for x in range(7):
			if (x == 3 and y == 2) or (x == 4 and y == 2) or (x == 1 and y == 4):
				continue                      # holes: every diagonal mask appears
			if x == 6 and y > 3:
				continue                      # a ragged edge
			cells.append(Vector2i(x, y))
	return cells

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://isometric/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("ISOMETRIC: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("ISOMETRIC: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d isometric tilesets" % (man as Array).size())

	var cells := paint_cells()
	for entry in man:
		var base: String = entry["base"]
		var terrain: String = entry["terrain"]
		var T: int = int(entry["tile_size"])
		var W: int = int(entry["cell_w"])
		var H: int = int(entry["cell_h"])
		var ts: TileSet = load("res://isometric/%s.tres" % base)
		ck("P1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("P2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("P3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: sheet is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		ck("P4", src.get_tiles_count() == 47, "%s: 47 tiles in the atlas" % base)

		# the two properties the repo's isometric doc is about
		ck("P5", ts.tile_shape == TileSet.TILE_SHAPE_ISOMETRIC, "%s: tile_shape is Isometric" % base)
		ck("P6", ts.tile_layout == TileSet.TILE_LAYOUT_DIAMOND_RIGHT,
			"%s: tile_layout is Diamond Right (Stacked would be a rectangle)" % base)
		ck("P7", ts.tile_size == Vector2i(W, H), "%s: cell is the %dx%d diamond footprint" % [base, W, H])
		ck("P8", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES,
			"%s: terrain mode is Match Corners and Sides" % base)
		ck("P9", ts.get_terrain_name(0, 0) == terrain, "%s: terrain named '%s'" % [base, terrain])
		ck("P10", ts.get_physics_layers_count() == 1, "%s: one physics layer" % base)

		# the collision shape is the diamond, not the bounding box: a square here
		# would collide half a tile out into empty space on all four diagonals
		var want_poly := PackedVector2Array([
			Vector2(-W / 2.0, 0), Vector2(0, -H / 2.0), Vector2(W / 2.0, 0), Vector2(0, H / 2.0)])
		var diamond_polys := 0
		for i in range(src.get_tiles_count()):
			var td := src.get_tile_data(src.get_tile_id(i), 0)
			if td != null and td.get_collision_polygons_count(0) == 1 \
					and td.get_collision_polygon_points(0, 0) == want_poly:
				diamond_polys += 1
		ck("P11", diamond_polys == 47,
			"%s: 47/47 tiles carry the diamond collision polygon (got %d)" % [base, diamond_polys])

		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)

		# Diamond Right steps +x by half a cell in each axis; Stacked would step a
		# whole width right. This is the layout claim measured, not assumed.
		ck("P12", layer.map_to_local(Vector2i(1, 0)) - layer.map_to_local(Vector2i(0, 0)) == Vector2(W / 2.0, -H / 2.0),
			"%s: +x moves half a cell right and half a cell UP (the diamond axis)" % base)

		layer.set_cells_terrain_connect(cells, 0, 0, false)
		var filled := 0
		for c in cells:
			if layer.get_cell_source_id(c) != -1:
				filled += 1
		ck("P13", filled == cells.size(),
			"%s: terrain paint filled all %d cells (got %d)" % [base, cells.size(), filled])

		# (1,1) is the one cell in the ragged region with all eight neighbours painted;
		# (2,1) touches the hole at (3,2) and would legitimately miss a corner bit.
		var interior := layer.get_cell_tile_data(Vector2i(1, 1))
		var sides_ok := interior != null
		var corners_ok := interior != null
		if interior != null:
			for n in ISO_SIDES:
				if interior.get_terrain_peering_bit(n) != 0:
					sides_ok = false
			for n in ISO_CORNERS:
				if interior.get_terrain_peering_bit(n) != 0:
					corners_ok = false
		ck("P14", sides_ok, "%s: an interior tile peers on all 4 ISOMETRIC sides" % base)
		ck("P15", corners_ok, "%s: an interior tile peers on all 4 ISOMETRIC corners" % base)

		# --- the rename is correct, or this disagrees -----------------------
		var sq_ts: TileSet = load("res://starter-pack/%s_47blob_%dpx.tres" % [base.split("_")[0], T])
		if sq_ts == null:
			ck("P16", false, "%s: the square starter tileset to compare against is missing" % base)
		else:
			var sq := TileMapLayer.new()
			sq.tile_set = sq_ts
			root.add_child(sq)
			sq.set_cells_terrain_connect(cells, 0, 0, false)
			var same := 0
			var first_diff := ""
			for c in cells:
				var a := layer.get_cell_atlas_coords(c)
				var b := sq.get_cell_atlas_coords(c)
				if invert and c == cells[0]:
					b = b + Vector2i(1, 0)      # --invert: the gate must catch this
				if a == b:
					same += 1
				elif first_diff == "":
					first_diff = " first at %s: iso %s vs square %s" % [str(c), str(a), str(b)]
			ck("P16", same == cells.size(),
				"%s: every one of the %d painted cells picks the SAME tile as the square pack (got %d)%s"
					% [base, cells.size(), same, first_diff])
			sq.queue_free()
			root.remove_child(sq)

		layer.queue_free()
		root.remove_child(layer)

	if failures == 0:
		print("ISOMETRIC %d/%d PASS" % [checked, checked])
	else:
		print("ISOMETRIC: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
