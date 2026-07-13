extends SceneTree
# Headless verification of the Blobsmith Wirer addon core.

var failures := 0

func check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		failures += 1

func _initialize() -> void:
	var Core := load("res://addons/blobsmith_wirer/wirer_core.gd")

	# mask tables must match the web core exactly
	var m47: Array[int] = Core.blob47()
	check("blob47 has 47 masks", m47.size() == 47)
	check("blob47 starts at 0 ends at 255", m47[0] == 0 and m47[m47.size() - 1] == 255)
	var all_canonical := true
	for m in m47:
		if Core.canonical_mask(m) != m: all_canonical = false
	check("all masks canonical", all_canonical)
	check("blob16 has 16 masks", Core.blob16().size() == 16)
	check("lone corner dropped", Core.canonical_mask(2) == 0)
	check("valid corner kept", Core.canonical_mask(1 | 4 | 2) == 7)

	# layout detection
	check("detect 47 layout", Core.detect_layout(128, 96) == { "tile_size": 16, "sides_only": false })
	check("detect 16 layout", Core.detect_layout(256, 64) == { "tile_size": 32, "sides_only": true })
	check("reject bad layout", Core.detect_layout(100, 100).is_empty())

	# build from the real example sheet
	var tex: Texture2D = load("res://tiles/grass_47blob_16px.png")
	check("example sheet loads", tex != null)
	var ts: TileSet = Core.build_tileset(tex, 16, false, true, "Grass")
	check("tileset built", ts != null)
	var src := ts.get_source(0) as TileSetAtlasSource
	check("47 tiles created", src.get_tiles_count() == 47)
	check("terrain mode corners+sides", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	check("terrain named", ts.get_terrain_name(0, 0) == "Grass")
	check("physics layer present", ts.get_physics_layers_count() == 1)

	# save + reload round trip
	var err := ResourceSaver.save(ts, "res://tiles/addon_out.tres")
	check("saves without error", err == OK)
	var ts2: TileSet = load("res://tiles/addon_out.tres")
	check("round-trips", ts2 != null and (ts2.get_source(0) as TileSetAtlasSource).get_tiles_count() == 47)

	# paint with it
	var layer := TileMapLayer.new()
	layer.tile_set = ts2
	root.add_child(layer)
	var cells: Array[Vector2i] = []
	for y in 3:
		for x in 4:
			cells.append(Vector2i(x, y))
	layer.set_cells_terrain_connect(cells, 0, 0, false)
	var filled := true
	for c in cells:
		if layer.get_cell_source_id(c) == -1: filled = false
	check("terrain paint fills 12 cells", filled)
	var interior := layer.get_cell_tile_data(Vector2i(1, 1))
	var full := interior != null
	if full:
		for n in [TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
				TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE,
				TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER]:
			if interior.get_terrain_peering_bit(n) != 0: full = false
	check("interior resolves to full tile", full)
	check("interior has collision", interior != null and interior.get_collision_polygons_count(0) == 1)

	# 16-mode build
	var img := Image.create(8 * 16, 2 * 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex16 := ImageTexture.create_from_image(img)
	var ts16: TileSet = Core.build_tileset(tex16, 16, true, false, "T")
	check("16-mode: 16 tiles", (ts16.get_source(0) as TileSetAtlasSource).get_tiles_count() == 16)
	check("16-mode: sides terrain", ts16.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES)
	check("16-mode: no physics", ts16.get_physics_layers_count() == 0)

	print("---")
	print("ADDON VERIFY: " + ("ALL PASS" if failures == 0 else "%d FAILURES" % failures))
	quit(1 if failures > 0 else 0)
