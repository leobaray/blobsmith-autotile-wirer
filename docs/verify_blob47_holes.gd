extends SceneTree

# What does Godot 4.7 actually do when the blob set has a HOLE — a canonical
# neighbourhood with no tile carrying its peering bits? The checker on
# /godot-autotile-47-tiles/ tells people which of the 47 are missing from their
# TileSet, so it has to say truthfully what the engine does with one.
#
# Method: load the complete 47-tile TileSet, delete one tile from the atlas at
# runtime, paint the neighbourhood that tile is the only exact match for, and
# read back what the engine put there.
#
#   godot --headless --script docs/verify_blob47_holes.gd
#   godot --headless --script docs/verify_blob47_holes.gd -- res://my_tileset.tres
#
# Written up in why-47-tiles-not-256.md. The removal happens on the loaded
# resource only — nothing on disk is touched.

const DEFAULT_TILESET := "res://tiles/blobsmith_tileset.tres"

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

func bits_of(td: TileData) -> String:
	if td == null:
		return "<no tile>"
	var out := []
	for p in [
		["N", TileSet.CELL_NEIGHBOR_TOP_SIDE], ["NE", TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
		["E", TileSet.CELL_NEIGHBOR_RIGHT_SIDE], ["SE", TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER],
		["S", TileSet.CELL_NEIGHBOR_BOTTOM_SIDE], ["SW", TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
		["W", TileSet.CELL_NEIGHBOR_LEFT_SIDE], ["NW", TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	]:
		if td.get_terrain_peering_bit(p[1]) == 0:
			out.append(p[0])
	return "+".join(out) if out.size() > 0 else "<island: no bits>"

func find_tile_with_all_bits(src: TileSetAtlasSource) -> Vector2i:
	# the interior tile: all eight peering bits set
	for i in range(src.get_tiles_count()):
		var coords := src.get_tile_id(i)
		var td := src.get_tile_data(coords, 0)
		var all := true
		for n in [
			TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
			TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
			TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
			TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
		]:
			if td.get_terrain_peering_bit(n) != 0:
				all = false
		if all:
			return coords
	return Vector2i(-1, -1)

func _initialize() -> void:
	var path := tileset_path()
	var ts: TileSet = load(path)
	var src := ts.get_source(0) as TileSetAtlasSource if ts != null else null
	check("tileset + atlas load (%s)" % path, ts != null and src != null)
	if src == null:
		quit(1)
		return

	var interior := find_tile_with_all_bits(src)
	check("the all-neighbours tile exists in the complete set", interior.x >= 0)

	# --- control: with the complete set, the centre of a 3x3 block gets it ---
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	var block: Array[Vector2i] = []
	for y in range(-1, 2):
		for x in range(-1, 2):
			block.append(Vector2i(x, y))
	layer.set_cells_terrain_connect(block, 0, 0, false)
	var before := layer.get_cell_tile_data(Vector2i(0, 0))
	print("control  centre = " + bits_of(before) + "  atlas " + str(layer.get_cell_atlas_coords(Vector2i(0, 0))))
	check("control: centre of a 3x3 block is the all-neighbours tile",
		layer.get_cell_atlas_coords(Vector2i(0, 0)) == interior)

	# --- now punch the hole and repaint the same block ---
	src.remove_tile(interior)
	check("tile removed (%d left)" % src.get_tiles_count(), src.get_tiles_count() == 46)

	var layer2 := TileMapLayer.new()
	layer2.tile_set = ts
	root.add_child(layer2)
	layer2.set_cells_terrain_connect(block, 0, 0, false)
	var after := layer2.get_cell_tile_data(Vector2i(0, 0))
	var after_src := layer2.get_cell_source_id(Vector2i(0, 0))
	print("hole     centre = " + bits_of(after) + "  atlas " + str(layer2.get_cell_atlas_coords(Vector2i(0, 0))) + "  source_id " + str(after_src))

	check("with the hole, the centre is NOT left empty", after_src != -1)
	check("with the hole, the centre is a DIFFERENT tile than the correct one",
		after == null or layer2.get_cell_atlas_coords(Vector2i(0, 0)) != interior)
	check("the substitute is missing at least one peering bit the neighbourhood has",
		after != null and bits_of(after) != "N+NE+E+SE+S+SW+W+NW")

	print("---")
	if failures == 0:
		print("BLOB47 HOLES: ALL PASS")
		quit(0)
	else:
		print("BLOB47 HOLES: %d FAILURES" % failures)
		quit(1)
