extends SceneTree

# Every claim in docs/why-y-sort-draws-the-wrong-order.md, asked of a real
# Godot 4 binary.
#
#   docs/verify_y_sort.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# Half of these claims are about draw ORDER, and draw order is not a property
# you can read: it is the thing the renderer does with the properties. So this
# script does not reason about the scene tree — it renders the scene into a
# SubViewport and reads the contested pixel back. That is why the runner needs
# a real rendering driver (xvfb + opengl3) and not --headless: the headless
# build swaps in a dummy renderer whose textures come back null.
#
# The scene is the same in almost every check. Two 16x16 tiles, RED at cell
# (0,0) and BLUE at cell (0,1). RED is drawn 8 px DOWN via texture_origin so
# that it lands on top of BLUE's cell. The band y=16..23 is therefore claimed
# by both tiles, and whichever colour that pixel comes back as is the one the
# renderer put last.

var failures := 0
var checks := 0

const RED := Color(1, 0, 0, 1)
const BLUE := Color(0, 0, 1, 1)
const GREEN := Color(0, 1, 0, 1)

func check(id: String, claim: String, cond: bool, measured: Variant = null) -> void:
	checks += 1
	if not cond:
		failures += 1
	var line := ("PASS  " if cond else "FAIL  ") + id + "  " + claim
	if measured != null:
		line += "   [measured: " + str(measured) + "]"
	print(line)

func declares(cls: String, prop: String) -> bool:
	for p in ClassDB.class_get_property_list(cls, true):
		if String(p.name) == prop:
			return true
	return false

func solid(c: Color, w := 16, h := 16) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)

func name_of(c: Color) -> String:
	if c.a < 0.5: return "."
	if c.r > 0.5: return "R"
	if c.g > 0.5: return "G"
	if c.b > 0.5: return "B"
	return "?"

# --- the two-tile scene ------------------------------------------------------

func two_tile_set(red_texorg: Vector2i, red_yso: int, red_z: int, blue_z: int) -> TileSet:
	var img := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	for x in range(32):
		for y in range(16):
			img.set_pixel(x, y, RED if x < 16 else BLUE)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	src.create_tile(Vector2i(1, 0))
	var rd := src.get_tile_data(Vector2i(0, 0), 0)
	rd.texture_origin = red_texorg
	rd.y_sort_origin = red_yso
	rd.z_index = red_z
	src.get_tile_data(Vector2i(1, 0), 0).z_index = blue_z
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	return ts

# Returns the whole column x=8, y=0..39 as a string of R/B/. so that geometry
# and order are both visible in one measured value.
func two_tile_column(ysort: bool, red_yso := 0, red_texorg := Vector2i(0, -8),
		red_z := 0, blue_z := 0, quadrant := 16) -> String:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var layer := TileMapLayer.new()
	layer.tile_set = two_tile_set(red_texorg, red_yso, red_z, blue_z)
	layer.y_sort_enabled = ysort
	layer.rendering_quadrant_size = quadrant
	layer.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))
	layer.set_cell(Vector2i(0, 1), 0, Vector2i(1, 0))
	vp.add_child(layer)
	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	var col := ""
	for y in range(0, 40):
		col += name_of(img.get_pixel(8, y))
	vp.queue_free()
	return col

# The contested band only. "B" = BLUE won, "R" = RED won.
func winner(ysort: bool, red_yso := 0, red_texorg := Vector2i(0, -8),
		red_z := 0, blue_z := 0, quadrant := 16) -> String:
	var col: String = await two_tile_column(ysort, red_yso, red_texorg, red_z, blue_z, quadrant)
	return col.substr(20, 1)

# --- the sibling-layer scene -------------------------------------------------

func three_tile_set() -> TileSet:
	var img := Image.create(48, 16, false, Image.FORMAT_RGBA8)
	for x in range(48):
		for y in range(16):
			img.set_pixel(x, y, RED if x < 16 else (BLUE if x < 32 else GREEN))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for i in range(3):
		src.create_tile(Vector2i(i, 0))
	src.get_tile_data(Vector2i(0, 0), 0).texture_origin = Vector2i(0, -8)  # RED   drawn 8 px DOWN
	src.get_tile_data(Vector2i(2, 0), 0).texture_origin = Vector2i(0, 8)   # GREEN drawn 8 px UP
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	return ts

# Layer A (added first) holds RED above BLUE and GREEN below it; layer B
# (added second) holds only BLUE. If the two layers sorted per TILE, RED would
# land behind BLUE and GREEN in front of it. If they sort as whole NODES, both
# of A's tiles end up on the same side of B.
func layer_column(parent_ysort: bool, layer_ysort: bool) -> String:
	var ts := three_tile_set()
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var parent := Node2D.new()
	parent.y_sort_enabled = parent_ysort
	vp.add_child(parent)
	var a := TileMapLayer.new()
	a.tile_set = ts
	a.y_sort_enabled = layer_ysort
	a.set_cell(Vector2i(0, 0), 0, Vector2i(0, 0))   # RED   -> drawn y  8..23
	a.set_cell(Vector2i(0, 2), 0, Vector2i(2, 0))   # GREEN -> drawn y 24..39
	parent.add_child(a)
	var b := TileMapLayer.new()
	b.tile_set = ts
	b.y_sort_enabled = layer_ysort
	b.set_cell(Vector2i(0, 1), 0, Vector2i(1, 0))   # BLUE  -> drawn y 16..31
	parent.add_child(b)
	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	var col := ""
	for y in range(0, 44):
		col += name_of(img.get_pixel(8, y))
	vp.queue_free()
	return col

# --- the child-node scene ----------------------------------------------------

func blue_tile_set() -> TileSet:
	var src := TileSetAtlasSource.new()
	src.texture = solid(BLUE)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	return ts

# A sprite parented to the layer, always DRAWN over the tile at cell (0,1);
# only its sort position moves. `offset` cancels the move so that the pixels
# never shift and the only variable is the sort key.
func child_winner(layer_ysort: bool, sprite_y: float, layer_yso := 0) -> String:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var layer := TileMapLayer.new()
	layer.tile_set = blue_tile_set()
	layer.y_sort_enabled = layer_ysort
	layer.y_sort_origin = layer_yso
	layer.set_cell(Vector2i(0, 1), 0, Vector2i(0, 0))
	vp.add_child(layer)
	var spr := Sprite2D.new()
	spr.texture = solid(GREEN)
	spr.centered = false
	spr.position = Vector2(0, sprite_y)
	spr.offset = Vector2(0, 16 - sprite_y)
	layer.add_child(spr)
	await process_frame
	await process_frame
	var c := vp.get_texture().get_image().get_pixel(8, 24)
	vp.queue_free()
	return name_of(c)

func _init() -> void:
	print("godot ", Engine.get_version_info().string, "   renderer: ",
		RenderingServer.get_video_adapter_name())
	print("---")

	# ---- what the editor actually exposes ------------------------------------

	var tml := TileMapLayer.new()
	var td := TileData.new()

	check("Y1", "`TileMapLayer.y_sort_enabled` exists and ships OFF",
		declares("TileMapLayer", "y_sort_enabled") or declares("CanvasItem", "y_sort_enabled"),
		tml.y_sort_enabled)
	check("Y2", "a new TileMapLayer really has y_sort_enabled == false",
		tml.y_sort_enabled == false, tml.y_sort_enabled)
	check("Y3", "`TileData.y_sort_origin` exists and defaults to 0",
		declares("TileData", "y_sort_origin") and td.y_sort_origin == 0, td.y_sort_origin)
	check("Y4", "`TileData.texture_origin` is a SEPARATE property, defaulting to (0,0)",
		declares("TileData", "texture_origin") and td.texture_origin == Vector2i(0, 0),
		td.texture_origin)
	check("Y5", "`TileData.z_index` exists and defaults to 0",
		declares("TileData", "z_index") and td.z_index == 0, td.z_index)
	check("Y6", "TileMapLayer declares its OWN `y_sort_origin` — Node2D does not",
		declares("TileMapLayer", "y_sort_origin") and not declares("Node2D", "y_sort_origin"),
		[declares("TileMapLayer", "y_sort_origin"), declares("Node2D", "y_sort_origin")])
	check("Y7", "`rendering_quadrant_size` ships at 16",
		tml.rendering_quadrant_size == 16, tml.rendering_quadrant_size)
	check("Y8", "the superseded `TileMap` class is still registered in this build",
		ClassDB.class_exists("TileMap"))

	# ---- geometry: what texture_origin moves ---------------------------------

	var base: String = await two_tile_column(false, 0, Vector2i(0, 0))
	check("Y9", "with no offsets the two cells tile the column exactly: RED 0..15, BLUE 16..31",
		base == "RRRRRRRRRRRRRRRRBBBBBBBBBBBBBBBB........", base)

	var up: String = await two_tile_column(false, 0, Vector2i(0, 8))
	check("Y10", "texture_origin.y = +8 moves the tile 8 px UP, not down — the offset is SUBTRACTED",
		up == "RRRRRRRR........BBBBBBBBBBBBBBBB........", up)

	var down: String = await two_tile_column(false, 0, Vector2i(0, -8))
	check("Y11", "texture_origin.y = -8 moves it DOWN, into the next cell's band",
		down.begins_with("........RRRRRRRR"), down)

	# ---- order: the advice that page 1 gives ---------------------------------

	check("Y12", "y-sort OFF: the tile written to the LATER cell wins the contested band",
		await winner(false) == "B", await winner(false))
	check("Y13", "turning y_sort_enabled ON changes NOTHING here — same pixel, same winner",
		await winner(true) == "B", await winner(true))
	check("Y14", "…and it stays unchanged however far texture_origin drags the art (-64)",
		await winner(true, 0, Vector2i(0, -64)) == "B",
		await winner(true, 0, Vector2i(0, -64)))

	# ---- order: the property that does move it -------------------------------

	check("Y15", "y_sort_origin = +16 is still not enough: the tie goes to the later cell",
		await winner(true, 16) == "B", await winner(true, 16))
	check("Y16", "y_sort_origin = +17 flips it — one unit past the tie",
		await winner(true, 17) == "R", await winner(true, 17))
	check("Y17", "the flip point says the key is the cell CENTRE: 0 + 8 + 17 > 16 + 8",
		await winner(true, 15) == "B" and await winner(true, 17) == "R",
		[await winner(true, 15), await winner(true, 17)])

	# ---- order: a child node against the tiles -------------------------------

	check("Y18", "y-sort OFF: a child sprite is drawn after the tiles whatever its position",
		await child_winner(false, 0.0) == "G" and await child_winner(false, 40.0) == "G",
		[await child_winner(false, 0.0), await child_winner(false, 40.0)])
	check("Y19", "y-sort ON: the same sprite goes BEHIND the tile at sort y = 23",
		await child_winner(true, 23.0) == "B", await child_winner(true, 23.0))
	check("Y20", "…and in front at 24 — the centre of cell (0,1) of a 16 px TileSet",
		await child_winner(true, 24.0) == "G", await child_winner(true, 24.0))
	check("Y21", "`TileMapLayer.y_sort_origin` = +16 shifts every tile's key and takes the band back",
		await child_winner(true, 24.0, 16) == "B", await child_winner(true, 24.0, 16))

	# ---- order: two layers ----------------------------------------------------

	var l_off_off: String = await layer_column(false, false)
	var l_off_on: String = await layer_column(false, true)
	var l_on_off: String = await layer_column(true, false)
	var l_on_on: String = await layer_column(true, true)

	check("Y22", "two sibling layers, nothing sorted: the later layer wins BOTH contested bands",
		l_off_off.substr(16, 16) == "BBBBBBBBBBBBBBBB", l_off_off)
	check("Y23", "y-sorting the LAYERS only changes nothing — they still stack by tree order",
		l_off_on == l_off_off, l_off_on)
	check("Y24", "y-sorting the PARENT only changes nothing either",
		l_on_off == l_off_off, l_on_off)
	check("Y25", "parent AND layers y-sorted: the two layers interleave PER TILE (RED behind, GREEN in front)",
		l_on_on.substr(16, 8) == "BBBBBBBB" and l_on_on.substr(24, 8) == "GGGGGGGG", l_on_on)

	# ---- z_index outranks all of it -------------------------------------------

	check("Y26", "one tile with z_index = 1 wins the band the y-sort had given away",
		await winner(true, 0, Vector2i(0, -8), 1, 0) == "R",
		await winner(true, 0, Vector2i(0, -8), 1, 0))
	check("Y27", "the same happens from the other side: z_index = -1 on the winner",
		await winner(true, 0, Vector2i(0, -8), 0, -1) == "R",
		await winner(true, 0, Vector2i(0, -8), 0, -1))

	# ---- the setting people are told to tune ----------------------------------

	var q := []
	for qs in [1, 16, 128]:
		q.append(await winner(true, 64, Vector2i(0, -8), 0, 0, qs))
	check("Y28", "rendering_quadrant_size (1 / 16 / 128) does not change a y-sorted result",
		q == ["R", "R", "R"], q)

	print("---")
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)
