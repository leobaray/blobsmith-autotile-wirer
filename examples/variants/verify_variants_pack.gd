extends SceneTree

# Engine gate for the free tile-variants pack (grass / stone / sand / water).
#
# The README promises one mechanism and four facts about it:
#
#   several atlas tiles may declare the IDENTICAL set of terrain peering bits;
#   set_cells_terrain_connect then picks among them at random, weighted by each
#   tile's `probability`.
#
# so: (a) the four interior tiles are interchangeable as far as the solver is
# concerned, (b) painting a field actually uses all four, (c) the plain one's
# share follows the weights it was given, and (d) `probability` is the knob —
# zero the variants and the field goes back to one repeated tile. `set_cell`
# never consults it: what you ask for is what is stored.
#
# Enum values are read by NAME, so a future renumber fails loudly.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const SIDES := [
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE,
]
const CORNERS := [
	TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
]
const FIELD := 24          # the painted square
const MARGIN := 2          # cells inside it that are surely interior

func side_mask(td: TileData) -> int:
	var m := 0
	for k in range(4):
		if td.get_terrain_peering_bit(SIDES[k]) == 0:
			m |= 1 << k
	return m

func id_of(c: Vector2i) -> String:
	return "%d:%d/0" % [c.x, c.y]

# every cell of the painted square that is not on its border: those are the ones
# whose tile must be one of the four interchangeable interior tiles.
func interior_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(MARGIN, FIELD - MARGIN):
		for x in range(MARGIN, FIELD - MARGIN):
			out.append(Vector2i(x, y))
	return out

func paint_square(layer: TileMapLayer) -> void:
	var cells: Array[Vector2i] = []
	for y in range(FIELD):
		for x in range(FIELD):
			cells.append(Vector2i(x, y))
	layer.clear()
	layer.set_cells_terrain_connect(cells, 0, 0, false)

func tally(layer: TileMapLayer) -> Dictionary:
	var counts := {}
	for c in interior_cells():
		var a := layer.get_cell_atlas_coords(c)
		counts[a] = int(counts.get(a, 0)) + 1
	return counts

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://variants/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("VARIANTS: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("VARIANTS: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d variant tilesets" % (man as Array).size())

	var n_interior := int((man as Array)[0]["interior_tiles"].size())
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var tiles: int = int(entry["tiles"])
		var plain_w: float = float(entry["plain_weight"])
		var var_w: float = float(entry["variant_weight"])
		var want_ids: Array = entry["interior_tiles"]

		var ts: TileSet = load("res://variants/%s.tres" % base)
		ck("V1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("V2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("V3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: sheet is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		ck("V4", src.get_tiles_count() == tiles,
			"%s: %d tiles in the atlas — 16 Match Sides masks plus %d extra copies of the interior one" % [base, tiles, tiles - 16])
		ck("V5", ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: square cell %dx%d" % [base, T, T])
		ck("V6", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES,
			"%s: terrain mode is Match Sides" % base)
		ck("V7", ts.get_terrain_name(0, 0) == entry["terrain"], "%s: terrain named '%s'" % [base, entry["terrain"]])
		ck("V8", ts.get_physics_layers_count() == 0, "%s: no physics layer — walk-over terrain" % base)

		# the four interchangeable tiles, found by their bits, not by position
		var full: Array[Vector2i] = []
		var by_mask := {}
		# corner bits on a Match Sides tileset: asked of the tile data itself,
		# because TileSet.is_valid_terrain_peering_bit does not exist in 4.3.
		var corner_bits := 0
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			if td == null:
				continue
			for cn in CORNERS:
				if td.is_valid_terrain_peering_bit(cn):
					corner_bits += 1
			var m := side_mask(td)
			by_mask[m] = int(by_mask.get(m, 0)) + 1
			if m == 15:
				full.append(coords)
		full.sort()
		var got_ids: Array[String] = []
		for c in full:
			got_ids.append(id_of(c))
		var want_sorted := want_ids.duplicate()
		want_sorted.sort()
		ck("V9", got_ids == want_sorted,
			"%s: exactly %d tiles declare all four side peering bits, and they are the ones the manifest names (%s)" % [base, n_interior, str(got_ids)])
		ck("V10", by_mask.size() == 16 and corner_bits == 0,
			"%s: the tiles cover all 16 side combinations (%d distinct) and a Match Sides terrain set has no valid corner peering bit at all (%d)" % [base, by_mask.size(), corner_bits])

		var probs: Array[float] = []
		for c in full:
			probs.append(src.get_tile_data(c, 0).probability)
		var plain_count := 0
		var sum_w := 0.0
		for p in probs:
			sum_w += p
			if is_equal_approx(p, plain_w):
				plain_count += 1
		ck("V11", plain_count == 1 and probs.size() == n_interior and sum_w > 0.0,
			"%s: one interior tile weighs %.2f and the other %d weigh %.2f (weights %s)" % [base, plain_w, n_interior - 1, var_w, str(probs)])

		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		paint_square(layer)

		var counts := tally(layer)
		var total := 0
		var stray := 0
		for c in counts.keys():
			total += int(counts[c])
			if not (c in full):
				stray += 1
		ck("V12", stray == 0 and total == interior_cells().size(),
			"%s: every one of the %d cells away from the border got one of the interchangeable interior tiles (%d strays)" % [base, total, stray])
		ck("V13", counts.size() == n_interior,
			"%s: painting one square used all %d interior tiles — the field is not one tile repeated (used %d)" % [base, n_interior, counts.size()])

		# the share of the plain tile follows the weights it was given
		var plain_coords: Vector2i = full[0]
		for i in range(full.size()):
			if is_equal_approx(src.get_tile_data(full[i], 0).probability, plain_w):
				plain_coords = full[i]
		var share := float(int(counts.get(plain_coords, 0))) / float(total)
		var expect := plain_w / sum_w
		ck("V14", absf(share - expect) < 0.12,
			"%s: the plain tile took %.1f%% of the field, against the %.1f%% its weight asks for" % [base, share * 100.0, expect * 100.0])

		# probability is the knob: zero the decorated ones and the field goes back
		# to a single repeated tile. --invert skips the zeroing, so the gate must fail.
		if not invert:
			for c in full:
				if c != plain_coords:
					src.get_tile_data(c, 0).probability = 0.0
		paint_square(layer)
		var zeroed := tally(layer)
		ck("V15", zeroed.size() == 1 and zeroed.has(plain_coords),
			"%s: with the decorated tiles at probability 0, connect paints only the plain one (%d distinct tiles)" % [base, zeroed.size()])

		# set_cell never consults probability: what you ask for is what is stored
		var asked: Vector2i = full[0] if full[0] != plain_coords else full[1]
		layer.clear()
		layer.set_cell(Vector2i(0, 0), 0, asked, 0)
		ck("V16", layer.get_cell_atlas_coords(Vector2i(0, 0)) == asked
			and src.get_tile_data(asked, 0).probability == 0.0,
			"%s: set_cell stored the tile whose probability is 0 — probability only steers the terrain solver" % base)

		ts = null
		layer.queue_free()
		root.remove_child(layer)

	if failures == 0:
		print("VARIANTS %d/%d PASS" % [checked, checked])
	else:
		print("VARIANTS: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
