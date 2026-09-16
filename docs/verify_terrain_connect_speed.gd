extends SceneTree
##
## Reproduces every claim in docs/why-set-cells-terrain-connect-is-slow.md
## against a real engine.
##
## Standalone: builds a 47-tile corners-and-sides TileSet in memory (the same
## builder as addons/blobsmith_wirer/wirer_core.gd, blank texture), needs no
## project assets. Run through verify_terrain_connect_speed.sh, which builds the
## empty project this script expects.
##
## Two kinds of claim:
##   - equivalence (A*, B*, C*, N*): exact tile-by-tile comparisons, no noise.
##   - speed (P*): wall-clock times on this machine. Only RATIOS are asserted,
##     each with a wide margin under what was measured, and every number is the
##     median of 3 runs. The milliseconds are printed, never asserted.
##
## Prints PASS/FAIL per check and a final "TERRAIN SPEED:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
##   godot --headless --path <proj> --script verify_terrain_connect_speed.gd [-- --invert]
##
## --invert flips the expectation of A1 and P2 on purpose, so a run that cannot
## fail is visible.

const SEED := 1234
const FILL := 0.6

const NB := {
	1: TileSet.CELL_NEIGHBOR_TOP_SIDE,
	2: TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	4: TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	8: TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	16: TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	32: TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	64: TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	128: TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
}
const OFF := {
	1: Vector2i(0, -1), 2: Vector2i(1, -1), 4: Vector2i(1, 0), 8: Vector2i(1, 1),
	16: Vector2i(0, 1), 32: Vector2i(-1, 1), 64: Vector2i(-1, 0), 128: Vector2i(-1, -1),
}

var failures := 0
var checks := 0
var invert := false
var lookup := {}      # canonical mask -> atlas coords
var mask_of_tile := {} # atlas coords -> canonical mask


func check(id: String, cond: bool, why: String) -> void:
	checks += 1
	if invert and (id == "A1" or id == "P2"):
		cond = not cond
	print(("PASS  " if cond else "FAIL  ") + id + "  " + why)
	if not cond:
		failures += 1


func note(s: String) -> void:
	print("NOTE  " + s)


# A corner bit only counts when both adjacent side bits are present.
static func canonical_mask(mask: int) -> int:
	var m := mask & 0b01010101
	if mask & 2 and mask & 1 and mask & 4: m |= 2
	if mask & 8 and mask & 16 and mask & 4: m |= 8
	if mask & 32 and mask & 16 and mask & 64: m |= 32
	if mask & 128 and mask & 1 and mask & 64: m |= 128
	return m


# 47 tiles, 8 columns, ascending canonical mask: the wirer_core layout.
func build_tileset() -> TileSet:
	var seen := {}
	for m in 256:
		seen[canonical_mask(m)] = true
	var masks: Array = seen.keys()
	masks.sort()
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_terrain_set(0)
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	ts.add_terrain(0)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(Image.create(128, 96, false, Image.FORMAT_RGBA8))
	src.texture_region_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	for i in masks.size():
		var pos := Vector2i(i % 8, i / 8)
		src.create_tile(pos)
		var td := src.get_tile_data(pos, 0)
		td.terrain_set = 0
		td.terrain = 0
		for bit in NB:
			if masks[i] & bit:
				td.set_terrain_peering_bit(NB[bit], 0)
	return ts


# The lookup the page tells you to build, read back from the TileSet's own
# peering bits — not from the sheet layout above — so it works for any complete
# 47-tile set, whatever order its tiles are in.
func tile_lookup(ts: TileSet, source_id: int, terrain: int) -> Dictionary:
	var src := ts.get_source(source_id) as TileSetAtlasSource
	var out := {}
	for i in src.get_tiles_count():
		var coords := src.get_tile_id(i)
		var td := src.get_tile_data(coords, 0)
		if td.terrain != terrain:
			continue
		var m := 0
		for bit in NB:
			if td.get_terrain_peering_bit(NB[bit]) == terrain:
				m |= bit
		out[m] = coords
	return out


# A seeded noise map: every cell of an n x n square is land with probability FILL.
# Noise on purpose — it produces every one of the 47 neighbourhoods, isolated
# cells and one-wide strips included, which a smooth blob would not.
func noise_cells(n: int) -> Array[Vector2i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out: Array[Vector2i] = []
	for y in n:
		for x in n:
			if rng.randf() < FILL:
				out.append(Vector2i(x, y))
	return out


func new_layer(ts: TileSet) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.tile_set = ts
	get_root().add_child(l)
	return l


func drop(l: TileMapLayer) -> void:
	get_root().remove_child(l)
	l.free()


# Cells whose source or atlas coords differ, over the square plus a 1-cell border.
func diff(a: TileMapLayer, b: TileMapLayer, n: int) -> int:
	var d := 0
	for y in range(-1, n + 1):
		for x in range(-1, n + 1):
			var c := Vector2i(x, y)
			if a.get_cell_source_id(c) != b.get_cell_source_id(c) \
					or a.get_cell_atlas_coords(c) != b.get_cell_atlas_coords(c):
				d += 1
	return d


# ---- the four ways of filling the same map --------------------------------

func paint_one_call(l: TileMapLayer, cells: Array[Vector2i]) -> void:
	l.set_cells_terrain_connect(cells, 0, 0)


func paint_per_cell(l: TileMapLayer, cells: Array[Vector2i]) -> void:
	for c in cells:
		l.set_cells_terrain_connect([c], 0, 0)


func paint_chunks(l: TileMapLayer, cells: Array[Vector2i], size: int) -> void:
	var buckets := {}
	for c in cells:
		var k := Vector2i(c.x / size, c.y / size)
		if not buckets.has(k):
			buckets[k] = [] as Array[Vector2i]
		buckets[k].append(c)
	for k in buckets:
		l.set_cells_terrain_connect(buckets[k], 0, 0)


# What the solver has to find, computed directly: the 8-neighbour mask of each
# land cell, reduced to canonical, looked up, then plain set_cell.
func paint_precomputed(l: TileMapLayer, cells: Array[Vector2i], canonical := true) -> void:
	var land := {}
	for c in cells:
		land[c] = true
	for c in cells:
		var m := 0
		for bit in OFF:
			if land.has(c + OFF[bit]):
				m |= bit
		if canonical:
			m = canonical_mask(m)
		# the non-canonical control: a raw mask with a lone corner has no tile
		l.set_cell(c, 0, lookup[m] if lookup.has(m) else Vector2i(6, 5))


# Median wall time of 3 runs, in ms, each on a fresh layer.
func time_ms(ts: TileSet, cells: Array[Vector2i], how: String) -> float:
	var runs: Array[float] = []
	for i in 3:
		var l := new_layer(ts)
		var t0 := Time.get_ticks_usec()
		match how:
			"one": paint_one_call(l, cells)
			"per_cell": paint_per_cell(l, cells)
			"chunks": paint_chunks(l, cells, 16)
			"pre": paint_precomputed(l, cells)
		runs.append((Time.get_ticks_usec() - t0) / 1000.0)
		drop(l)
	runs.sort()
	return runs[1]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true

	var ts := build_tileset()
	lookup = tile_lookup(ts, 0, 0)
	for m in lookup:
		mask_of_tile[lookup[m]] = m
	check("S2", lookup.size() == 47,
		"reading peering bits back gives 47 distinct masks, one tile each (%d)" % lookup.size())
	check("S0", (ts.get_source(0) as TileSetAtlasSource).get_tiles_count() == 47,
		"the in-memory TileSet has 47 terrain tiles")

	var N := 128
	var cells := noise_cells(N)
	var cells64 := noise_cells(64)
	note("map %dx%d seed %d fill %.1f -> %d land cells; 64x64 same seed -> %d" % [N, N, SEED, FILL, cells.size(), cells64.size()])

	# ---- equivalence ---------------------------------------------------------
	var one := new_layer(ts)
	paint_one_call(one, cells)

	var n_used := one.get_used_cells().size()
	check("N1", n_used == cells.size(),
		"one call on an empty layer fills exactly the listed cells (used %d, listed %d)" % [n_used, cells.size()])

	var hist := {}
	for c in cells:
		hist[one.get_cell_atlas_coords(c)] = true
	check("S1", hist.size() == 47,
		"the noise map makes the engine use all 47 tiles (used %d distinct)" % hist.size())

	var per := new_layer(ts)
	paint_per_cell(per, cells)
	var d_per := diff(one, per, N)
	check("A1", d_per == 0,
		"one set_cells_terrain_connect call and one call PER CELL give the same map (%d of %d cells differ)" % [d_per, (N + 2) * (N + 2)])
	drop(per)

	var ch := new_layer(ts)
	paint_chunks(ch, cells, 16)
	var d_ch := diff(one, ch, N)
	check("A2", d_ch == 0,
		"one call per 16x16 chunk gives the same map, no seams at chunk edges (%d cells differ)" % d_ch)
	drop(ch)

	var pre := new_layer(ts)
	paint_precomputed(pre, cells)
	var d_pre := diff(one, pre, N)
	check("B1", d_pre == 0,
		"neighbour mask -> canonical -> lookup -> set_cell gives the engine's map (%d cells differ)" % d_pre)
	drop(pre)

	# Control: the same lookup WITHOUT the corner rule must disagree, or diff()
	# is not telling maps apart.
	var raw := new_layer(ts)
	paint_precomputed(raw, cells, false)
	var d_raw := diff(one, raw, N)
	check("K1", d_raw > 1000,
		"control: the same lookup with raw (non-canonical) masks differs from the engine (%d cells differ)" % d_raw)
	drop(raw)

	# N2: a call rewrites cells it was not given. Erase one cell in a filled
	# 20x20 block through the terrain API: the 8 neighbours change too.
	var block := new_layer(ts)
	var all: Array[Vector2i] = []
	for y in 20:
		for x in 20:
			all.append(Vector2i(x, y))
	block.set_cells_terrain_connect(all, 0, 0)
	var before := {}
	for c in all:
		before[c] = block.get_cell_atlas_coords(c)
	block.set_cells_terrain_connect([Vector2i(10, 10)], 0, -1)
	var changed := 0
	for c in all:
		if block.get_cell_atlas_coords(c) != before[c]:
			changed += 1
	check("N2", changed == 9 and block.get_cell_source_id(Vector2i(10, 10)) == -1,
		"a call listing ONE cell (erase, terrain -1) inside a filled block changes 9 cells: it and its 8 neighbours (changed %d)" % changed)
	drop(block)

	# ---- path vs connect -------------------------------------------------------
	var ring: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]
	var c_ring := new_layer(ts)
	c_ring.set_cells_terrain_connect(ring, 0, 0)
	var p_ring := new_layer(ts)
	p_ring.set_cells_terrain_path(ring, 0, 0)
	var cm: Array[int] = []
	var pm: Array[int] = []
	for c in ring:
		cm.append(mask_of_tile[c_ring.get_cell_atlas_coords(c)])
		pm.append(mask_of_tile[p_ring.get_cell_atlas_coords(c)])
	check("C1", cm == [28, 112, 193, 7],
		"connect on a 2x2 block joins every pair, corners included (masks %s)" % str(cm))
	check("C2", pm == [4, 80, 65, 4],
		"path over the same 4 cells in ring order joins only consecutive cells, no corners, last not joined to first (masks %s)" % str(pm))
	var line: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	var c_line := new_layer(ts)
	c_line.set_cells_terrain_connect(line, 0, 0)
	var p_line := new_layer(ts)
	p_line.set_cells_terrain_path(line, 0, 0)
	var d_line := diff(c_line, p_line, 3)
	check("C3", d_line == 0, "on a straight 3-cell line path and connect agree (%d differ)" % d_line)
	for l in [c_ring, p_ring, c_line, p_line]:
		drop(l)

	# ---- speed (ratios only) ---------------------------------------------------
	var t_one := time_ms(ts, cells, "one")
	var t_per := time_ms(ts, cells, "per_cell")
	var t_ch := time_ms(ts, cells, "chunks")
	var t_pre := time_ms(ts, cells, "pre")
	var t_one64 := time_ms(ts, cells64, "one")
	note("median of 3, %d cells: one call %.1f ms | per cell %.1f ms | 16x16 chunks %.1f ms | precomputed set_cell %.1f ms" % [cells.size(), t_one, t_per, t_ch, t_pre])
	note("one call per land cell: %.1f us at 128x128, %.1f us at 64x64" % [t_one * 1000.0 / cells.size(), t_one64 * 1000.0 / cells64.size()])

	var t_repaint := 0.0
	var l2 := new_layer(ts)
	paint_one_call(l2, cells)
	var t0 := Time.get_ticks_usec()
	paint_one_call(l2, cells)
	t_repaint = (Time.get_ticks_usec() - t0) / 1000.0
	drop(l2)
	note("the same one call again over a layer that already holds the map: %.1f ms (one run)" % t_repaint)

	check("P1", t_per >= 2.0 * t_one,
		"one call per cell is at least 2x slower than one call (%.1fx: %.1f vs %.1f ms)" % [t_per / t_one, t_per, t_one])
	check("P2", t_one >= 10.0 * t_pre,
		"one terrain call is at least 10x slower than precomputing and calling set_cell (%.1fx: %.1f vs %.1f ms)" % [t_one / t_pre, t_one, t_pre])
	var growth := t_one / t_one64
	var cell_growth := float(cells.size()) / cells64.size()
	check("P3", growth >= 2.0 and growth <= 8.0,
		"64x64 -> 128x128 (%.2fx the cells) costs one call %.2fx the time: linear-ish, not the 16x of quadratic (%.1f -> %.1f ms)" % [cell_growth, growth, t_one64, t_one])
	check("P4", t_ch <= 3.0 * t_one and t_ch >= t_one / 3.0,
		"16x16 chunks cost about the same as one call, within 3x either way (%.2fx)" % [t_ch / t_one])

	drop(one)
	if failures == 0:
		print("TERRAIN SPEED: ALL PASS (%d checks)" % checks)
	else:
		print("TERRAIN SPEED: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
