extends SceneTree

# Asks Godot itself, 256 times, which tile it picks for a given 8-neighbourhood.
#
# For every mask 0..255 it paints a centre cell plus exactly the neighbours the
# mask names, then reads the terrain peering bits back off the tile the ENGINE
# chose for the centre. That read-back is the canonical mask: what the engine
# actually distinguishes. The rule this repo documents (a corner bit only counts
# when both adjacent side bits are set) is re-implemented below and has to agree
# on all 256 — and a complete blob set has to resolve to exactly 47 tiles.
#
# Run it against the set this repo ships, or against your own:
#
#   godot --headless --script docs/verify_blob47.gd
#   godot --headless --script docs/verify_blob47.gd -- res://my_tileset.tres
#
# On an INCOMPLETE set it does not just fail: it lists the neighbourhoods your
# set cannot answer and the tile the engine silently substituted for each. That
# substitution is the whole reason this script exists — a missing blob tile
# produces no error and no empty cell, so the only way to see it is to ask.
#
# Prints one SWEEP line of JSON (raw mask -> resolved mask) so the table in
# why-47-tiles-not-256.md is the engine's own output, not a transcription.

const DEFAULT_TILESET := "res://tiles/blobsmith_tileset.tres"

const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128

const BIT_NAMES := {N: "N", NE: "NE", E: "E", SE: "SE", S: "S", SW: "SW", W: "W", NW: "NW"}

var failures := 0

func check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		failures += 1

func tileset_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.ends_with(".tres") or arg.ends_with(".res"):
			return arg
	return DEFAULT_TILESET

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

func spell(mask: int) -> String:
	var parts: Array[String] = []
	for bit in [N, NE, E, SE, S, SW, W, NW]:
		if mask & bit:
			parts.append(BIT_NAMES[bit])
	return "none" if parts.is_empty() else "+".join(parts)

# A corner bit survives only when both of its adjacent side bits are present.
func canonical(mask: int) -> int:
	var m := mask & 0b01010101
	if (mask & NE) and (mask & N) and (mask & E):
		m |= NE
	if (mask & SE) and (mask & S) and (mask & E):
		m |= SE
	if (mask & SW) and (mask & S) and (mask & W):
		m |= SW
	if (mask & NW) and (mask & N) and (mask & W):
		m |= NW
	return m

func _initialize() -> void:
	var path := tileset_path()
	var ts: TileSet = load(path)
	check("tileset loads (%s)" % path, ts != null)
	if ts == null:
		print("---")
		print("BLOB47 SWEEP: cannot load %s — pass a path after `--`" % path)
		quit(1)
		return

	# 47 is a property of ONE terrain mode. Reading corner peering bits off a
	# sides-only set is not a failing test, it is the wrong question — and the
	# engine answers it with a wall of errors and -1. So ask the mode first.
	if ts.get_terrain_sets_count() < 1:
		check("tileset has a terrain set", false)
		print("---")
		print("BLOB47 SWEEP: %s has no terrain set — nothing to resolve." % path)
		quit(1)
		return
	var mode := ts.get_terrain_set_mode(0)
	if mode != TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES:
		var named := "MATCH_CORNERS" if mode == TileSet.TERRAIN_MODE_MATCH_CORNERS else "MATCH_SIDES"
		check("terrain set 0 is MATCH_CORNERS_AND_SIDES (it is %s)" % named, false)
		print("")
		print("This set uses %s, which reads %d of the 8 neighbours, so a" % [named, 4])
		print("complete set of it is 2^4 = 16 tiles, not 47. 47 is the count for")
		print("MATCH_CORNERS_AND_SIDES, which reads all 8. Neither mode has 256")
		print("tiles — see docs/why-47-tiles-not-256.md. Change the terrain set's")
		print("mode in the TileSet inspector to check a blob-47 sheet here.")
		print("---")
		print("BLOB47 SWEEP: wrong terrain mode for this check")
		quit(1)
		return

	var pairs := [
		[N, TileSet.CELL_NEIGHBOR_TOP_SIDE],
		[NE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
		[E, TileSet.CELL_NEIGHBOR_RIGHT_SIDE],
		[SE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER],
		[S, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
		[SW, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
		[W, TileSet.CELL_NEIGHBOR_LEFT_SIDE],
		[NW, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	]

	var sweep := {}
	var distinct := {}
	var substituted := []
	var unpainted := []

	for mask in range(256):
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)

		var cells: Array[Vector2i] = [Vector2i(0, 0)]
		for p in pairs:
			var bit: int = p[0]
			if mask & bit:
				cells.append(offset_of(bit))
		layer.set_cells_terrain_connect(cells, 0, 0, false)

		var centre := layer.get_cell_tile_data(Vector2i(0, 0))
		if centre == null:
			unpainted.append(mask)
			layer.queue_free()
			continue

		var resolved := 0
		for p in pairs:
			var bit: int = p[0]
			var neighbor: int = p[1]
			if centre.get_terrain_peering_bit(neighbor) == 0:
				resolved |= bit

		sweep[mask] = resolved
		distinct[resolved] = true
		if resolved != canonical(mask):
			substituted.append(mask)

		layer.queue_free()

	check("all 256 neighbourhoods painted a tile (%d empty)" % unpainted.size(), unpainted.is_empty())

	# The gap report. On a complete set this list is empty; on a set with holes
	# it is the answer to "which cells will look wrong and never tell me".
	if substituted.is_empty():
		check("engine agrees with the corner-needs-both-sides rule on all 256", true)
	else:
		check("engine agrees with the corner-needs-both-sides rule on all 256 (%d disagree)" % substituted.size(), false)
		print("")
		print("NEIGHBOURHOODS THIS SET CANNOT ANSWER — the engine substituted a")
		print("different tile, with no error and no empty cell:")
		for mask in substituted:
			print("  neighbourhood %3d (%s)" % [mask, spell(mask)])
			print("      wanted tile %3d (%s)" % [canonical(mask), spell(canonical(mask))])
			print("      engine used %3d (%s)" % [sweep[mask], spell(sweep[mask])])
		print("")

	check("engine distinguishes exactly 47 tiles (got %d)" % distinct.size(), distinct.size() == 47)
	check("a lone cell resolves to mask 0", sweep.get(0, -1) == 0)
	check("all 8 neighbours resolves to mask 255", sweep.get(255, -1) == 255)
	check("a lone NE corner is not distinguished from no neighbour at all",
		sweep.get(NE, -1) == 0)
	check("N+E without the NE corner differs from N+E+NE",
		sweep.get(N | E, -2) != sweep.get(N | E | NE, -1))

	# How many of the 256 neighbourhoods each canonical tile has to answer.
	# Documented claim: it is 2 ** (4 - number of ADJACENT side pairs present),
	# because only an adjacent pair makes its corner bit meaningful.
	var load_of := {}
	for mask in sweep:
		var r: int = sweep[mask]
		load_of[r] = load_of.get(r, 0) + 1
	var histogram := {}
	var formula_holds := true
	for tile in load_of:
		histogram[load_of[tile]] = histogram.get(load_of[tile], 0) + 1
		var adjacent_pairs := 0
		for pair in [[N, E], [E, S], [S, W], [W, N]]:
			if (tile & pair[0]) and (tile & pair[1]):
				adjacent_pairs += 1
		if load_of[tile] != int(pow(2, 4 - adjacent_pairs)):
			formula_holds = false
	check("each tile answers 2^(4 - adjacent side pairs) neighbourhoods", formula_holds)

	print("HISTOGRAM " + JSON.stringify(histogram))
	print("SWEEP " + JSON.stringify(sweep))
	print("---")
	if failures == 0:
		print("BLOB47 SWEEP: ALL PASS")
		quit(0)
	else:
		print("BLOB47 SWEEP: %d FAILURES" % failures)
		quit(1)
