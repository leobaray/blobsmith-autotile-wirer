extends SceneTree

# Asks Godot which tiles terrain painting places when the cells a player sees as
# one shape are split across two TileMapLayers.
#
# The question behind it is the one every "my autotile has a seam down the
# middle" report describes without naming: the painted tiles look wrong exactly
# at the boundary between two layers, and nothing in the editor says why.
#
# Claim ids (X*) are the ones cited in
# docs/why-terrain-does-not-connect-across-two-tilemaplayers.md. Every check
# prints PASS/FAIL and the script exits non-zero if any fails, so a newer Godot
# tells you which line stopped holding.

var failures := 0

func check(id: String, name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + id + "  " + name)
	if not cond:
		failures += 1

func note(s: String) -> void:
	print("NOTE  " + s)

func mk(ts: TileSet) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.tile_set = ts
	get_root().add_child(l)
	return l

# The painted shape as a plain list of atlas coords, in the order of `cells`.
func shape(l: TileMapLayer, cells: Array) -> Array:
	var out := []
	for c in cells:
		out.append(l.get_cell_atlas_coords(c))
	return out

func s(a: Array) -> String:
	var parts := PackedStringArray()
	for v in a:
		parts.append(str(v))
	return "[" + ", ".join(parts) + "]"

func _init() -> void:
	var ts: TileSet = load("res://tiles/blobsmith_tileset.tres")
	check("X0", "the 47-blob tileset loads and declares one terrain set",
		ts != null and ts.get_terrain_sets_count() == 1)
	if ts == null:
		print("CROSS LAYER: ERROR - no tileset, nothing measured")
		quit(1)
		return

	# The shape: a 2x2 block. Split down the middle it is two vertical columns.
	var left: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1)]
	var right: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, 1)]
	var both: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1)]

	# --- the reference: the whole block on ONE layer, one call ---------------
	var one := mk(ts)
	one.set_cells_terrain_connect(both, 0, 0)
	var block := shape(one, both)
	note("one layer, one call:   " + s(block))
	var block_distinct := {}
	for v in block:
		block_distinct[v] = true
	check("X1", "one layer paints the 2x2 block as four different tiles (a corner each)",
		block_distinct.size() == 4)

	# --- the same shape split across two layers ------------------------------
	var la := mk(ts)
	var lb := mk(ts)
	la.set_cells_terrain_connect(left, 0, 0)
	var a_before := shape(la, left)
	lb.set_cells_terrain_connect(right, 0, 0)
	var a_after := shape(la, left)
	var b_shape := shape(lb, right)
	note("layer A (left half):   " + s(a_after))
	note("layer B (right half):  " + s(b_shape))

	check("X2", "each layer paints an isolated column - the two halves come out identical",
		a_after == b_shape)
	check("X3", "the split result differs from the one-layer result on the touching cells",
		a_after != [block[0], block[1]])
	check("X4", "painting layer B never changes a single cell of layer A",
		a_before == a_after)

	# --- order does not rescue it -------------------------------------------
	var lc := mk(ts)
	var ld := mk(ts)
	ld.set_cells_terrain_connect(right, 0, 0)
	lc.set_cells_terrain_connect(left, 0, 0)
	check("X5", "painting right-then-left gives the same wrong shape as left-then-right",
		shape(lc, left) == a_after and shape(ld, right) == b_shape)

	# --- what actually fixes it: one LAYER, not one CALL ---------------------
	var fixed := mk(ts)
	fixed.set_cells_terrain_connect(left, 0, 0)
	fixed.set_cells_terrain_connect(right, 0, 0)
	var fixed_shape := shape(fixed, both)
	note("one layer, two calls:  " + s(fixed_shape))
	check("X6", "two separate calls on the SAME layer reach the one-call result - the boundary is the layer, not the call",
		fixed_shape == block)

	# --- when you genuinely need two layers: mirror the result ---------------
	var mirror := mk(ts)
	for c in right:
		mirror.set_cell(c, fixed.get_cell_source_id(c), fixed.get_cell_atlas_coords(c), fixed.get_cell_alternative_tile(c))
	check("X7", "copying the painted cells to a second layer with set_cell keeps the connected tiles",
		shape(mirror, right) == [block[2], block[3]])

	# --- and the neighbour it does read is the one already on its own layer --
	var pre := mk(ts)
	pre.set_cells_terrain_connect(left, 0, 0)
	var before_touch := shape(pre, left)
	pre.set_cells_terrain_connect(right, 0, 0)
	check("X8", "the second call rewrites cells the first call painted - connect reads its own layer, including cells you did not pass in",
		shape(pre, left) != before_touch)

	if failures == 0:
		print("CROSS LAYER: ALL PASS")
	else:
		print("CROSS LAYER: " + str(failures) + " FAILED")
	quit(1 if failures > 0 else 0)
