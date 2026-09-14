extends SceneTree
##
## Reproduces every claim in docs/why-set-cell-draws-nothing.md against a real
## engine.
##
## Standalone: builds its own TileSets and TileMapLayers in memory, needs no
## project assets. Run through verify_set_cell.sh, which builds the empty
## project this script expects and gives it a real GL context — "draws nothing"
## is read back from rendered pixels, not inferred from get_cell_tile_data().
##
## Prints PASS/FAIL per check and a final "SET CELL:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
## LG_SERRPROBE=setonly|draw|lookup runs one scenario and quits, so the wrapper can
## count the ERROR lines each one prints.
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

const RED := Color(1, 0, 0, 1)

var failures := 0


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


# A 32x32 RED texture: room for one 1x1 tile at (0,0) or one 2x2 tile.
func red_source(tile_size_in_atlas := Vector2i(1, 1)) -> TileSetAtlasSource:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(RED)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0), tile_size_in_atlas)
	return src


func red_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(red_source())
	return ts


# Puts the layer in its own transparent SubViewport, renders two frames and
# returns "RED" or "nothing" for the centre of cell (0,0).
func drawn(layer: TileMapLayer) -> String:
	var vp := SubViewport.new()
	vp.size = Vector2i(32, 32)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	if layer.get_parent():
		layer.reparent(vp)
	else:
		vp.add_child(layer)
	await process_frame
	await process_frame
	var c := vp.get_texture().get_image().get_pixel(8, 8)
	layer.get_parent().remove_child(layer)
	vp.queue_free()
	if c.a < 0.01:
		return "nothing"
	return "RED" if c.r > 0.9 and c.g < 0.1 else str(c)


func layer_with(ts: TileSet) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	return layer


func error_probe(mode: String) -> void:
	var layer := layer_with(red_tileset())
	layer.set_cell(Vector2i(0, 0), 0, Vector2i(1, 0))
	if mode == "draw":
		await drawn(layer)
	if mode == "lookup":
		layer.get_cell_tile_data(Vector2i(0, 0))
	print("SERRPROBE DONE")
	quit(0)


func _initialize() -> void:
	var probe := OS.get_environment("LG_SERRPROBE")
	if probe != "":
		await error_probe(probe)
		return

	var L: TileMapLayer
	var ts: TileSet

	# --- control: the setup draws at all -----------------------------------
	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	check_eq("K1 control: set_cell(c, 0, (0,0)) on a real tile draws RED", await drawn(L), "RED")

	# --- the default arguments erase -----------------------------------------
	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	L.set_cell(Vector2i(0, 0))
	check_eq("S1 set_cell(coords) with no other argument ERASES: source id -1", L.get_cell_source_id(Vector2i(0, 0)), -1)
	check_eq("S1 ... and the cell leaves get_used_cells()", L.get_used_cells(), [])
	check_eq("S1 ... and nothing is drawn", await drawn(L), "nothing")
	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0)
	check_eq("S2 set_cell(coords, 0) without atlas_coords also ERASES: default atlas (-1,-1)", L.get_cell_source_id(Vector2i(0, 0)), -1)

	# --- a cell the TileSet cannot resolve is stored anyway --------------------
	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0, Vector2i(1, 0))
	check_eq("S3 atlas coords with no tile: the cell is STORED (source 0, atlas (1,0))",
		[L.get_cell_source_id(Vector2i(0, 0)), L.get_cell_atlas_coords(Vector2i(0, 0))], [0, Vector2i(1, 0)])
	check_eq("S3 ... it is in get_used_cells()", L.get_used_cells(), [Vector2i(0, 0)])
	check_eq("S3 ... get_cell_tile_data() is null", L.get_cell_tile_data(Vector2i(0, 0)), null)
	check_eq("S3 ... and nothing is drawn", await drawn(L), "nothing")

	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 5, Vector2i(0, 0))
	check_eq("S4 source id that does not exist: stored as 5", L.get_cell_source_id(Vector2i(0, 0)), 5)
	check_eq("S4 ... and nothing is drawn", await drawn(L), "nothing")

	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0), 3)
	check_eq("S5 alternative id that does not exist: stored as 3", L.get_cell_alternative_tile(Vector2i(0, 0)), 3)
	check_eq("S5 ... and nothing is drawn", await drawn(L), "nothing")

	# --- the cell stays, so fixing the TileSet fixes the map -----------------
	ts = red_tileset()
	L = layer_with(ts)
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 1))
	check_eq("S6 before: (0,1) has no tile, nothing drawn", await drawn(L), "nothing")
	var src0 := ts.get_source(0) as TileSetAtlasSource
	src0.create_tile(Vector2i(0, 1))
	check_eq("S6 create_tile((0,1)) afterwards: the SAME cell now draws RED, no set_cell again", await drawn(L), "RED")

	L = TileMapLayer.new()
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	check_eq("S7 no tile_set yet: the cell is still stored", L.get_used_cells(), [Vector2i(0, 0)])
	L.tile_set = red_tileset()
	check_eq("S7 ... and draws RED once a tile_set is assigned", await drawn(L), "RED")

	# --- source ids are not positions ----------------------------------------
	ts = TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	var first := ts.add_source(red_source())
	ts.remove_source(first)
	var second := ts.add_source(red_source())
	check_eq("S8 remove a source and add one back: the new id is 1, not 0", [first, second, ts.get_source_count()], [0, 1, 1])
	L = layer_with(ts)
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	check_eq("S8 ... so set_cell(c, 0, ...) draws nothing", await drawn(L), "nothing")
	L = layer_with(ts)
	L.set_cell(Vector2i(0, 0), ts.get_source_id(0), Vector2i(0, 0))
	check_eq("S8 ... get_source_id(0) is 1 and draws RED", await drawn(L), "RED")

	# --- big tiles are addressed by their origin ------------------------------
	ts = TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	var big := red_source(Vector2i(2, 2))
	ts.add_source(big)
	L = layer_with(ts)
	L.set_cell(Vector2i(0, 0), 0, Vector2i(1, 1))
	check_eq("S9 2x2 tile: set_cell with a coordinate inside it but not its origin draws nothing", await drawn(L), "nothing")
	check_eq("S9 ... get_tile_at_coords((1,1)) returns the origin (0,0)", big.get_tile_at_coords(Vector2i(1, 1)), Vector2i(0, 0))
	L = layer_with(ts)
	L.set_cell(Vector2i(0, 0), 0, big.get_tile_at_coords(Vector2i(1, 1)))
	check_eq("S9 ... and set_cell with that origin draws RED", await drawn(L), "RED")

	# --- create_tile can fail quietly as far as your code is concerned --------
	var src := red_source()
	src.create_tile(Vector2i(3, 0))
	check_eq("S10 create_tile outside the 32 px texture: has_tile() is false afterwards", src.has_tile(Vector2i(3, 0)), false)
	var bare := TileSetAtlasSource.new()
	bare.create_tile(Vector2i(0, 0))
	check_eq("S10 create_tile on an atlas with no texture yet: has_tile() is false", bare.has_tile(Vector2i(0, 0)), false)

	# --- the layer switch ------------------------------------------------------
	L = layer_with(red_tileset())
	L.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	L.enabled = false
	check_eq("S11 enabled = false: the cell is still stored", L.get_cell_source_id(Vector2i(0, 0)), 0)
	check_eq("S11 ... and nothing is drawn", await drawn(L), "nothing")

	print("SET CELL: " + ("ALL PASS" if failures == 0 else "%d FAIL" % failures))
	quit(0 if failures == 0 else 1)
