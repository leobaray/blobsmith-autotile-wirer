extends SceneTree

# Asks Godot 4.7 which tile terrain painting actually places, and why.
#
# Page 1 of "godot 4 terrain paints wrong tiles" says two things that cannot
# both be true: "the engine picks the closest match" and "the algorithm is
# non-deterministic". Neither source measures anything. This does.
#
# Claim ids (T*) are the ones cited in docs/why-terrain-paints-the-wrong-tile.md.
# Every check prints PASS/FAIL and the script exits non-zero if any fails, so a
# newer Godot tells you which line stopped holding.

const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128

const PAIRS := [
	[N, TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[NE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
	[E, TileSet.CELL_NEIGHBOR_RIGHT_SIDE],
	[SE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER],
	[S, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
	[SW, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
	[W, TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[NW, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
]

var failures := 0
var notes: Array[String] = []

func check(id: String, name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + id + "  " + name)
	if not cond:
		failures += 1

func note(s: String) -> void:
	notes.append(s)
	print("NOTE  " + s)

func offset_of(bit: int) -> Vector2i:
	match bit:
		N: return Vector2i(0, -1)
		NE: return Vector2i(1, -1)
		E: return Vector2i(1, 0)
		SE: return Vector2i(1, 1)
		S: return Vector2i(0, 1)
		SW: return Vector2i(-1, 1)
		W: return Vector2i(-1, 0)
		NW: return Vector2i(-1, -1)
	return Vector2i.ZERO

func cells_for(mask: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = [Vector2i(0, 0)]
	for p in PAIRS:
		if mask & int(p[0]):
			cells.append(offset_of(int(p[0])))
	return cells

# Which of the 8 bits the terrain set's MODE actually uses. There is no
# is_valid_terrain_peering_bit() on TileSet in 4.7, so derive it from the mode:
# asking a sides-only set for a corner bit is an engine error, not a zero.
func valid_bits(ts: TileSet) -> int:
	match ts.get_terrain_set_mode(0):
		TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES: return 255
		TileSet.TERRAIN_MODE_MATCH_CORNERS: return NE | SE | SW | NW
		TileSet.TERRAIN_MODE_MATCH_SIDES: return N | E | S | W
	return 255

func mask_from(ts: TileSet, td: TileData) -> int:
	var ok := valid_bits(ts)
	var m := 0
	for p in PAIRS:
		if not (ok & int(p[0])):
			continue
		if td.get_terrain_peering_bit(int(p[1])) == 0:
			m |= int(p[0])
	return m

func mask_of(layer: TileMapLayer, at: Vector2i) -> int:
	var td := layer.get_cell_tile_data(at)
	if td == null:
		return -1
	return mask_from(layer.tile_set, td)

# The peering mask a tile in the atlas carries, independent of any placement.
func tile_mask(ts: TileSet, td: TileData) -> int:
	return mask_from(ts, td)

func popcount(v: int) -> int:
	var c := 0
	while v != 0:
		c += v & 1
		v >>= 1
	return c

# Identity of the placed tile, so we can tell "same mask" from "same tile".
func tile_of(layer: TileMapLayer, at: Vector2i) -> String:
	if layer.get_cell_source_id(at) == -1:
		return "<empty>"
	return "%d:%s:%d" % [layer.get_cell_source_id(at), layer.get_cell_atlas_coords(at), layer.get_cell_alternative_tile(at)]

func terrain_of(layer: TileMapLayer, at: Vector2i) -> int:
	var td := layer.get_cell_tile_data(at)
	return -1 if td == null else td.terrain

func fresh(ts: TileSet) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	return layer

func paint(ts: TileSet, cells: Array[Vector2i], ignore_empty: bool) -> TileMapLayer:
	var layer := fresh(ts)
	layer.set_cells_terrain_connect(cells, 0, 0, ignore_empty)
	return layer

const DEFAULT_TILESET := "res://tiles/blobsmith_tileset.tres"
const DEFAULT_SIDES := "res://tiles/sides16.tres"

func _initialize() -> void:
	# Run against the set this repo ships, or against your own:
	#   godot --headless --script docs/verify_terrain_choice.gd
	#   godot --headless --script docs/verify_terrain_choice.gd -- res://my.tres
	var args := OS.get_cmdline_user_args()
	var full_path: String = args[0] if args.size() > 0 else DEFAULT_TILESET
	var sides_path: String = args[1] if args.size() > 1 else DEFAULT_SIDES

	var full: TileSet = load(full_path)
	check("T0", "corners-and-sides tileset loads (%s)" % full_path, full != null)
	if full == null:
		quit(1)
		return
	if full.get_terrain_set_mode(0) != TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES:
		print("SKIP  %s is not a corners-and-sides set; T4-T8, T17-T19 need one" % full_path)
		quit(1)
		return

	var sides: TileSet = load(sides_path) if ResourceLoader.exists(sides_path) else null
	if sides == null:
		print("SKIP  no sides-only set at %s; T10-T13 skipped" % sides_path)

	# ---------------------------------------------------------------- A. determinism
	# The complaint on page 1 is that the same paint gives different tiles.
	var repeats := {}
	for i in range(30):
		var l := paint(full, cells_for(N | E | SE | S), false)
		repeats[tile_of(l, Vector2i(0, 0))] = true
		l.queue_free()
	check("T1", "30 identical paints in fresh layers -> 1 distinct tile (got %d)" % repeats.size(),
		repeats.size() == 1)

	# Same cells, reversed order in the array.
	var straight := cells_for(N | E | SE | S)
	var reversed: Array[Vector2i] = []
	for i in range(straight.size() - 1, -1, -1):
		reversed.append(straight[i])
	var la := paint(full, straight, false)
	var lb := paint(full, reversed, false)
	check("T2", "cell order in the array does not change the result",
		tile_of(la, Vector2i(0, 0)) == tile_of(lb, Vector2i(0, 0)))
	la.queue_free()
	lb.queue_free()

	# Painting the same region one cell at a time vs all at once.
	var one_by_one := fresh(full)
	for c in straight:
		var single: Array[Vector2i] = [c]
		one_by_one.set_cells_terrain_connect(single, 0, 0, false)
	var at_once := paint(full, straight, false)
	var incremental_same := true
	for c in straight:
		if tile_of(one_by_one, c) != tile_of(at_once, c):
			incremental_same = false
	check("T3", "painting cell-by-cell lands on the same tiles as painting the set at once",
		incremental_same)
	one_by_one.queue_free()
	at_once.queue_free()

	# ---------------------------------------------------------- B. the empty neighbours
	# A 3x3 block: the centre has all 8 neighbours, the border does not.
	var block: Array[Vector2i] = []
	for y in range(3):
		for x in range(3):
			block.append(Vector2i(x, y))
	var b_strict := paint(full, block, false)
	check("T4", "centre of a 3x3 block gets the fully-surrounded tile (mask 255)",
		mask_of(b_strict, Vector2i(1, 1)) == 255)
	check("T5", "the corner of that same block does NOT get the fully-surrounded tile",
		mask_of(b_strict, Vector2i(0, 0)) != 255)
	note("3x3 strict: corner(0,0) mask=%d  edge(1,0) mask=%d  centre mask=%d" % [
		mask_of(b_strict, Vector2i(0, 0)), mask_of(b_strict, Vector2i(1, 0)),
		mask_of(b_strict, Vector2i(1, 1))])

	# ignore_empty_terrains: the 4th argument, and what it does NOT cover.
	# Case 1: the block's neighbours are cells with no tile in them at all.
	var b_loose := paint(full, block, true)
	var loose_diff := 0
	for c in block:
		if tile_of(b_strict, c) != tile_of(b_loose, c):
			loose_diff += 1
	check("T6", "with EMPTY CELLS around it, ignore_empty_terrains changes nothing (%d of 9 differ)" % loose_diff,
		loose_diff == 0)

	# Case 2: the flag is about CANDIDATE TILES, not about neighbours. Make the
	# only exact match for a fully-surrounded cell a tile that belongs to no
	# terrain at all, and see whether the engine is allowed to use it.
	var noterr: TileSet = load("res://tiles/blobsmith_tileset.tres")
	var nsrc: TileSetAtlasSource = noterr.get_source(noterr.get_source_id(0)) as TileSetAtlasSource
	var interior := Vector2i(-1, -1)
	for i in range(nsrc.get_tiles_count()):
		var co := nsrc.get_tile_id(i)
		if tile_mask(noterr, nsrc.get_tile_data(co, 0)) == 255:
			interior = co
			break
	nsrc.get_tile_data(interior, 0).terrain = -1

	var n_strict := paint(noterr, block, false)
	var n_loose := paint(noterr, block, true)
	var s_centre := mask_of(n_strict, Vector2i(1, 1))
	var l_centre := mask_of(n_loose, Vector2i(1, 1))
	check("T7", "even as the only EXACT match, a terrain-less tile is not used either way (strict %d, ignore %d)" % [s_centre, l_centre],
		s_centre == l_centre and s_centre != 255)
	check("T7b", "the engine prefers a wrong-looking tile OF THE PAINTED TERRAIN over a terrain-less exact match",
		terrain_of(n_strict, Vector2i(1, 1)) == 0)
	note("no-terrain candidate: strict centre mask=%d terrain=%d | ignore_empty centre mask=%d terrain=%d" % [
		s_centre, terrain_of(n_strict, Vector2i(1, 1)),
		l_centre, terrain_of(n_loose, Vector2i(1, 1))])
	n_strict.queue_free()
	n_loose.queue_free()
	check("T8", "the centre is identical either way (it has no empty neighbour)",
		tile_of(b_strict, Vector2i(1, 1)) == tile_of(b_loose, Vector2i(1, 1)))
	note("3x3 loose:  corner(0,0) mask=%d  edge(1,0) mask=%d  centre mask=%d" % [
		mask_of(b_loose, Vector2i(0, 0)), mask_of(b_loose, Vector2i(1, 0)),
		mask_of(b_loose, Vector2i(1, 1))])

	# Painting next to an already-painted region rewrites the OLD cell too.
	var grow := fresh(full)
	var first: Array[Vector2i] = [Vector2i(0, 0)]
	grow.set_cells_terrain_connect(first, 0, 0, false)
	var lone := tile_of(grow, Vector2i(0, 0))
	var second: Array[Vector2i] = [Vector2i(1, 0)]
	grow.set_cells_terrain_connect(second, 0, 0, false)
	check("T9", "painting a neighbour rewrites the tile of the cell already there",
		tile_of(grow, Vector2i(0, 0)) != lone)
	grow.queue_free()
	b_strict.queue_free()
	b_loose.queue_free()

	# ------------------------------------------- C. the set that cannot answer the question
	# sides16 has no corner tiles at all. Every corner-distinguishing
	# neighbourhood therefore has NO exact match.
	var painted_all := true
	var distinct_sides := {}
	var sweep_sides := {}
	for mask in range(256 if sides != null else 0):
		var l := paint(sides, cells_for(mask), false)
		var m := mask_of(l, Vector2i(0, 0))
		if m == -1:
			painted_all = false
		sweep_sides[mask] = m
		distinct_sides[tile_of(l, Vector2i(0, 0))] = true
		l.queue_free()
	if sides != null:
		check("T10", "a sides-only set still paints every one of the 256 neighbourhoods (no holes left)",
			painted_all)
		check("T11", "a sides-only set can only ever produce its own 16 tiles (got %d)" % distinct_sides.size(),
			distinct_sides.size() == 16)

		# Is the fallback the "closest" tile, i.e. does it keep the side bits right?
		var sides_keep := true
		var side_mask := N | E | S | W
		var first_bad := ""
		for mask in range(256):
			var want := mask & side_mask
			var got_sides: int = int(sweep_sides[mask]) & side_mask
			if want != got_sides:
				sides_keep = false
				if first_bad == "":
					first_bad = " (first: mask %d wanted sides %d, got %d)" % [mask, want, got_sides]
		check("T12", "the fallback tile still matches every SIDE the neighbourhood asked for" + first_bad,
			sides_keep)

		# Determinism on the ambiguous case specifically.
		var amb := {}
		for i in range(30):
			var l := paint(sides, cells_for(N | E | NE), false)
			amb[tile_of(l, Vector2i(0, 0))] = true
			l.queue_free()
		check("T13", "the no-exact-match case is deterministic too (%d distinct over 30 runs)" % amb.size(),
			amb.size() == 1)

	# ------------------------------- C2. a corners-and-sides set with a tile MISSING
	# The page-1 diagnosis is "you are missing a tile variation". So remove the
	# one the engine wants for a fully-surrounded cell and watch what it does.
	var holed: TileSet = load("res://tiles/blobsmith_tileset.tres")
	var hsrc: TileSetAtlasSource = holed.get_source(holed.get_source_id(0)) as TileSetAtlasSource
	var want_gone := Vector2i(-1, -1)
	for i in range(hsrc.get_tiles_count()):
		var co := hsrc.get_tile_id(i)
		if tile_mask(holed, hsrc.get_tile_data(co, 0)) == 255:
			want_gone = co
			break
	check("C2a", "found the fully-surrounded tile in the atlas", want_gone != Vector2i(-1, -1))
	hsrc.remove_tile(want_gone)

	# What masks can the set still offer?
	var available: Array[int] = []
	for i in range(hsrc.get_tiles_count()):
		var co := hsrc.get_tile_id(i)
		var td := hsrc.get_tile_data(co, 0)
		if td.terrain == 0:
			available.append(tile_mask(holed, td))

	var hblock: Array[Vector2i] = []
	for y in range(3):
		for x in range(3):
			hblock.append(Vector2i(x, y))
	var hl := paint(holed, hblock, false)
	var got := mask_of(hl, Vector2i(1, 1))
	check("T17", "with the needed tile removed the cell is still painted, not left empty (mask %d)" % got,
		got != -1)

	# Is the replacement one of the tiles that minimise the number of
	# peering bits that disagree with what the neighbourhood asked for?
	var best := 99
	for m in available:
		best = min(best, popcount(m ^ 255))
	var got_score := popcount(got ^ 255)
	check("T18", "the substitute is a minimum-mismatch tile (its score %d, best available %d)" % [got_score, best],
		got_score == best)
	note("hole test: wanted mask 255, engine placed mask %d (%d bits off; %d tiles tie at that score)" % [
		got, got_score, available.count(got)])

	# And it is still deterministic with the hole in place.
	var hole_runs := {}
	for i in range(20):
		var l := paint(holed, hblock, false)
		hole_runs[tile_of(l, Vector2i(1, 1))] = true
		l.queue_free()
	check("T19", "the substitution is deterministic across 20 runs (%d distinct)" % hole_runs.size(),
		hole_runs.size() == 1)
	hl.queue_free()

	# --------------------------------------- D. issue #76493: tiles from another terrain
	# Same terrain set, two terrains, and terrain 0 cannot answer every
	# neighbourhood. Does the engine reach into terrain 1?
	var mixed: TileSet = load("res://tiles/sides16.tres")
	mixed.add_terrain(0)
	mixed.set_terrain_name(0, 1, "other")
	var src: TileSetAtlasSource = mixed.get_source(mixed.get_source_id(0)) as TileSetAtlasSource
	var moved := 0
	# Hand the last few tiles to the second terrain, so the set has tiles that
	# are NOT terrain 0 sitting in the same terrain set.
	for i in range(src.get_tiles_count()):
		var coords := src.get_tile_id(i)
		var td := src.get_tile_data(coords, 0)
		if td.terrain == 0 and moved < 4:
			td.terrain = 1
			moved += 1
	check("T14", "built a 2-terrain set for the cross-terrain test (%d tiles moved)" % moved, moved == 4)

	var foreign := 0
	var foreign_example := ""
	for mask in range(256):
		var l := paint(mixed, cells_for(mask), false)
		var t := terrain_of(l, Vector2i(0, 0))
		if t != 0 and t != -1:
			foreign += 1
			if foreign_example == "":
				foreign_example = "mask %d -> terrain %d" % [mask, t]
		l.queue_free()
	check("T15", "painting terrain 0 never places a tile belonging to terrain 1 (%d of 256 did%s)" % [
		foreign, ("" if foreign_example == "" else ", e.g. " + foreign_example)], foreign == 0)

	# And the centre is always the terrain we asked for.
	var wrong_terrain := 0
	for mask in range(256):
		var l := paint(full, cells_for(mask), false)
		if terrain_of(l, Vector2i(0, 0)) != 0:
			wrong_terrain += 1
		l.queue_free()
	check("T16", "with a complete set the painted cell always belongs to the requested terrain (%d wrong)" % wrong_terrain,
		wrong_terrain == 0)

	print("---")
	for n in notes:
		print("NOTE " + n)
	print("---")
	if failures == 0:
		print("TERRAIN CHOICE: ALL PASS")
		quit(0)
	else:
		print("TERRAIN CHOICE: %d FAILURES" % failures)
		quit(1)
