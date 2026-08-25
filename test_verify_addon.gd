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

	# What the dialog says when detect_layout said no. Dimensions only —
	# these are the sheets people actually drop on an autotile wirer.
	var c6: Dictionary = Core.classify_sheet(48, 32)          # 3x2 base tiles at 16px
	check("6-tile base sheet named", c6.kind == "base6" and c6.tile_size == 16
		and c6.cols == 3 and c6.rows == 2)
	check("base6 hint says it is the input", c6.hint.contains("6 base tiles"))
	var c9: Dictionary = Core.classify_sheet(48, 48)          # 3x3-minimal, Godot 3 autotile
	check("3x3-minimal named", c9.kind == "minimal9" and c9.tile_size == 16)
	var c16: Dictionary = Core.classify_sheet(64, 64)         # 4x4 wang, not 8x2
	check("16 tiles in 4x4 named", c16.kind == "wang16" and c16.tile_size == 16
		and c16.cols == 4 and c16.rows == 4)
	var c48: Dictionary = Core.classify_sheet(96, 128)        # 6x8: right count, wrong shape
	check("47-blob in wrong shape named", c48.kind == "blob47" and c48.cols == 6
		and c48.rows == 8)
	# 256x256 is honestly ambiguous: 4x4 at 64px and 16x16 at 16px are both
	# real sheets. The bigger tile is the pick; the other reading is said out
	# loud instead of being swallowed.
	var c256: Dictionary = Core.classify_sheet(256, 256)
	check("ambiguous sheet picks the larger tile",
		c256.kind == "wang16" and c256.tile_size == 64)
	check("second reading is disclosed", c256.hint.contains("16x16 tiles at 16px"))
	var cfull: Dictionary = Core.classify_sheet(512, 128)     # 32x8 at 16px
	check("256-tile row named", cfull.cols * cfull.rows in [16, 256])
	var cgrid: Dictionary = Core.classify_sheet(160, 96)      # 5x3 at 32px — nothing known
	check("plain grid measured", cgrid.kind == "grid" and cgrid.tile_size == 32
		and cgrid.cols == 5 and cgrid.rows == 3)
	var codd: Dictionary = Core.classify_sheet(130, 97)       # prime-ish: margins/separation
	check("undividable sheet admits it", codd.kind == "unknown"
		and codd.tile_size == 0)
	check("unknown hint blames margins", codd.hint.contains("margin"))
	check("every classification carries a hint",
		c6.hint != "" and c9.hint != "" and c16.hint != "" and c48.hint != ""
		and c256.hint != "" and cgrid.hint != "" and codd.hint != "")
	# the sheets the wirer DOES accept must never reach the classifier path
	check("valid 47 sheet still detected", not Core.detect_layout(128, 96).is_empty())
	check("valid 16 sheet still detected", not Core.detect_layout(256, 64).is_empty())

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
