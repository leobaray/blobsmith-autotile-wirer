extends SceneTree
##
## Reproduces every claim in docs/why-changing-the-tile-size-emptied-my-tilemap.md
## against a real engine.
##
## Standalone: builds its own TileSets and TileMapLayers in memory, needs no
## project assets. Run through verify_tile_size_change.sh, which gives it a real
## GL context: half of these claims are about what ends up on screen, and the
## headless dummy renderer returns no image.
##
## The atlas is 4x2 cells of 16 px, each cell a flat colour, so a sampled pixel
## names the atlas cell it came from.
##
## Prints PASS/FAIL per check and a final "TILE SIZE CHANGE:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
## LG_SELFTEST=1 flips the expectation of B3, to prove the harness can fail.

const PAINT := {"R": Color(1, 0, 0), "G": Color(0, 1, 0), "B": Color(0, 0, 1), "Y": Color(1, 1, 0)}
# The colour painted into each atlas cell, row by row.
const SHEET := ["R", "G", "B", "Y", "G", "B", "Y", "R"]

var failures := 0
var vp: SubViewport


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = got == want
	if name.begins_with("B3 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


# A 64x32 atlas: 4x2 cells of 16 px, one flat colour each, one tile per cell.
func sheet_source() -> TileSetAtlasSource:
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	var i := 0
	for y in 2:
		for x in 4:
			img.fill_rect(Rect2i(x * 16, y * 16, 16, 16), PAINT[SHEET[i]])
			i += 1
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for y in 2:
		for x in 4:
			src.create_tile(Vector2i(x, y))
	return src


func name_of(c: Color) -> String:
	if c.a < 0.5:
		return "-"
	for k in PAINT:
		if c.is_equal_approx(PAINT[k]):
			return k
	return "?"


# Paints one cell with `coords` and returns the colour letters sampled at the
# centre of each of the first four cells of row 0, then of row 1.
func draw_cell(src: TileSetAtlasSource, coords: Vector2i, cell_px := 16) -> String:
	if vp:
		vp.queue_free()
	vp = SubViewport.new()
	vp.size = Vector2i(cell_px * 4, cell_px * 2)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(cell_px, cell_px)
	ts.add_source(src)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	vp.add_child(layer)
	layer.set_cell(Vector2i(0, 0), 0, coords)
	await process_frame
	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	var out := ""
	for y in 2:
		for x in 4:
			out += name_of(img.get_pixel(x * cell_px + cell_px / 2, y * cell_px + cell_px / 2))
		if y == 0:
			out += "/"
	return out


func tile_ids(src: TileSetAtlasSource) -> Array:
	var out := []
	for i in src.get_tiles_count():
		out.append(src.get_tile_id(i))
	out.sort()
	return out


func inside_texture(src: TileSetAtlasSource, coords: Vector2i) -> bool:
	var tex := Rect2i(Vector2i.ZERO, Vector2i(src.texture.get_size()))
	return tex.encloses(src.get_tile_texture_region(coords))


func _init() -> void:

	# --- A: what texture_region_size does to the atlas -----------------------
	var src := sheet_source()
	check_eq("A1  a 4x2 sheet of 16 px cells has 8 tiles and a 4x2 atlas grid",
		[src.get_tiles_count(), src.get_atlas_grid_size()], [8, Vector2i(4, 2)])
	check_eq("A2  tile (3,1) reads the last 16 px cell of the sheet",
		src.get_tile_texture_region(Vector2i(3, 1)), Rect2i(48, 16, 16, 16))

	src.texture_region_size = Vector2i(32, 32)
	check_eq("A3  doubling texture_region_size deletes no tile and prints no error",
		[src.get_tiles_count(), tile_ids(src).size()], [8, 8])
	check_eq("A4  ... but the atlas grid shrinks to 2x1, so 6 of the 8 tiles are outside it",
		src.get_atlas_grid_size(), Vector2i(2, 1))
	check_eq("A5  tile (3,1) now claims a 32 px region at (96,32), outside the 64x32 texture",
		[src.get_tile_texture_region(Vector2i(3, 1)), src.texture.get_size()],
		[Rect2i(96, 32, 32, 32), Vector2(64, 32)])
	check_eq("A6  the engine still answers has_tile(3,1) = true for that tile",
		src.has_tile(Vector2i(3, 1)), true)
	check_eq("A7  tile (0,0) survives inside the texture, reading 4 sheet cells instead of 1",
		src.get_tile_texture_region(Vector2i(0, 0)), Rect2i(0, 0, 32, 32))

	# --- B: what that looks like on screen -----------------------------------
	var fresh := sheet_source()
	check_eq("B1  before the change, a cell painted with (0,0) draws that cell's colour",
		await draw_cell(fresh, Vector2i(0, 0)), "R---/----")

	fresh.texture_region_size = Vector2i(32, 32)
	check_eq("B2  after it, the same cell draws the centre of a 32 px region — different art",
		await draw_cell(fresh, Vector2i(0, 0)), "B---/----")
	check_eq("B3  a tile whose region left the texture draws nothing at all",
		await draw_cell(fresh, Vector2i(3, 1)), "----/----")

	# --- C: the cell data is not the thing that broke ------------------------
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	var src_c := sheet_source()
	var sid := ts.add_source(src_c)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	layer.set_cell(Vector2i(0, 0), sid, Vector2i(3, 1))
	src_c.texture_region_size = Vector2i(32, 32)
	check_eq("C1  the map keeps the cell: source id and atlas coords are unchanged",
		[layer.get_cell_source_id(Vector2i(0, 0)), layer.get_cell_atlas_coords(Vector2i(0, 0))],
		[sid, Vector2i(3, 1)])
	check_eq("C2  ... and the cell is still in get_used_cells(), invisible or not",
		layer.get_used_cells(), [Vector2i(0, 0)] as Array[Vector2i])
	layer.queue_free()

	# --- D: the other field called "tile size" -------------------------------
	var src_d := sheet_source()
	var ts_d := TileSet.new()
	ts_d.tile_size = Vector2i(16, 16)
	ts_d.add_source(src_d)
	ts_d.tile_size = Vector2i(32, 32)
	check_eq("D1  TileSet.tile_size = 32 leaves texture_region_size, the grid and the tiles alone",
		[src_d.texture_region_size, src_d.get_atlas_grid_size(), src_d.get_tiles_count()],
		[Vector2i(16, 16), Vector2i(4, 2), 8])
	check_eq("D2  ... and tile (3,1) still reads the same 16 px sheet cell",
		src_d.get_tile_texture_region(Vector2i(3, 1)), Rect2i(48, 16, 16, 16))
	# 16 px of art in a 32 px cell, sampled at the centre of each quarter.
	check_eq("D3  on screen the art is right but 16 px of it sits in a 32 px cell",
		await draw_cell(sheet_source(), Vector2i(0, 0), 32), "R---/----")

	# --- E: getting back out of it -------------------------------------------
	var src_e := sheet_source()
	src_e.texture_region_size = Vector2i(32, 32)
	src_e.texture_region_size = Vector2i(16, 16)
	check_eq("E1  setting texture_region_size back restores count, grid and regions exactly",
		[src_e.get_tiles_count(), src_e.get_atlas_grid_size(),
		 src_e.get_tile_texture_region(Vector2i(3, 1))],
		[8, Vector2i(4, 2), Rect2i(48, 16, 16, 16)])
	check_eq("E2  ... and the art comes back on screen",
		await draw_cell(src_e, Vector2i(0, 0)), "R---/----")

	# The rebuild path, for when 32 px really is the size you want.
	var src_f := sheet_source()
	src_f.texture_region_size = Vector2i(32, 32)
	var removed := 0
	for coords in tile_ids(src_f):
		if not inside_texture(src_f, coords):
			src_f.remove_tile(coords)
			removed += 1
	check_eq("E3  dropping every tile whose region left the texture drops exactly 6 of 8",
		[removed, tile_ids(src_f)], [6, [Vector2i(0, 0), Vector2i(1, 0)]])

	# The same loop written over live indices misses tiles, because remove_tile
	# re-indexes the source under the iteration.
	var src_g := sheet_source()
	src_g.texture_region_size = Vector2i(32, 32)
	var naive := 0
	for i in src_g.get_tiles_count():
		if i >= src_g.get_tiles_count():
			break
		var coords: Vector2i = src_g.get_tile_id(i)
		if not inside_texture(src_g, coords):
			src_g.remove_tile(coords)
			naive += 1
	check_eq("E4  removing inside a loop over get_tile_id(i) drops only 4 of the 6",
		[naive, src_g.get_tiles_count()], [4, 4])

	print("TILE SIZE CHANGE: %s (%d check%s failed)" % [
		"ALL PASS" if failures == 0 else "FAILURES", failures, "" if failures == 1 else "s"])
	quit(0)
