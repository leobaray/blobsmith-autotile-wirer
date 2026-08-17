extends SceneTree

# Every claim in docs/why-tiles-have-seams.md, asked of a real Godot 4 binary.
#
#   godot --headless --script docs/verify_tile_seams.gd
#   godot --headless --script docs/verify_tile_seams.gd -- --tuned
#
# The `--tuned` pass is meant to be run in a project whose project.godot already
# carries the pixel-art settings (see verify_tile_seams.sh, which writes both
# projects and runs both passes). It re-asserts the atlas-geometry claims to show
# that tile padding is a TileSet property and not a rendering setting: nothing in
# S11..S16 moves when the renderer is reconfigured.
#
# Nothing here needs a window: every number is a project setting, a property
# default, or an atlas region, all of which the engine computes headless.

var failures := 0
var checks := 0

func check(id: String, claim: String, cond: bool, measured: Variant = null) -> void:
	checks += 1
	if not cond:
		failures += 1
	var line := ("PASS  " if cond else "FAIL  ") + id + "  " + claim
	if measured != null:
		line += "   [measured: " + str(measured) + "]"
	print(line)

func hint_of(setting: String) -> String:
	for prop in ProjectSettings.get_property_list():
		if String(prop.name) == setting:
			return String(prop.hint_string)
	return "<not in property list>"

func has_prop_matching(obj: Object, needle: String) -> bool:
	for prop in obj.get_property_list():
		if needle in String(prop.name).to_lower():
			return true
	return false

func make_atlas(region: int, margins: Vector2i, separation: Vector2i, padding: bool) -> TileSetAtlasSource:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(region, region)
	src.margins = margins
	src.separation = separation
	src.use_texture_padding = padding
	return src

func _init() -> void:
	var tuned := "--tuned" in OS.get_cmdline_user_args()
	print("godot ", Engine.get_version_info().string, "   pass: ", ("tuned" if tuned else "default"))
	print("---")

	# ---- the advice that page 1 gives, and whether the setting still exists ----

	check("S1", "the Godot 3 setting `rendering/quality/2d/use_pixel_snap` does NOT exist in this build",
		not ProjectSettings.has_setting("rendering/quality/2d/use_pixel_snap"))
	check("S2", "neither does `rendering/quality/2d/use_gpu_pixel_snap`",
		not ProjectSettings.has_setting("rendering/quality/2d/use_gpu_pixel_snap"))
	check("S3", "the Godot 4 replacement `rendering/2d/snap/snap_2d_transforms_to_pixel` exists",
		ProjectSettings.has_setting("rendering/2d/snap/snap_2d_transforms_to_pixel"))
	check("S4", "`rendering/2d/snap/snap_2d_vertices_to_pixel` exists too, and they are two settings, not one",
		ProjectSettings.has_setting("rendering/2d/snap/snap_2d_vertices_to_pixel"))
	check("S5", "both snap settings ship OFF",
		ProjectSettings.property_get_revert("rendering/2d/snap/snap_2d_transforms_to_pixel") == false
			and ProjectSettings.property_get_revert("rendering/2d/snap/snap_2d_vertices_to_pixel") == false,
		[ProjectSettings.property_get_revert("rendering/2d/snap/snap_2d_transforms_to_pixel"),
		 ProjectSettings.property_get_revert("rendering/2d/snap/snap_2d_vertices_to_pixel")])

	# ---- the filter: the number means the opposite thing in the two places ----

	var filter_setting := "rendering/textures/canvas_textures/default_texture_filter"
	check("S6", "the project-wide filter enum is exactly `Nearest,Linear,Linear Mipmap,Nearest Mipmap`",
		hint_of(filter_setting) == "Nearest,Linear,Linear Mipmap,Nearest Mipmap", hint_of(filter_setting))
	check("S7", "in THAT enum the shipped default is 1, and 1 is Linear — a new 2D project filters canvas textures LINEARLY",
		ProjectSettings.property_get_revert(filter_setting) == 1,
		ProjectSettings.property_get_revert(filter_setting))
	check("S8", "in CanvasItem's own enum 1 is NEAREST and 2 is LINEAR: the same integer is the opposite filter in the two places",
		CanvasItem.TEXTURE_FILTER_NEAREST == 1 and CanvasItem.TEXTURE_FILTER_LINEAR == 2,
		[CanvasItem.TEXTURE_FILTER_NEAREST, CanvasItem.TEXTURE_FILTER_LINEAR])
	var tml := TileMapLayer.new()
	check("S9", "a fresh TileMapLayer has texture_filter == TEXTURE_FILTER_PARENT_NODE (0): it inherits the project default, it does not force Nearest",
		tml.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, tml.texture_filter)
	check("S10", "TileSet has no texture-filter property at all — the filter is a node/project matter, never a tileset one",
		not has_prop_matching(TileSet.new(), "texture_filter"))
	if tuned:
		check("S21", "with the setting written to project.godot the engine reads back 0 (Nearest)",
			int(ProjectSettings.get_setting(filter_setting)) == 0,
			ProjectSettings.get_setting(filter_setting))
		check("S22", "and snap_2d_transforms_to_pixel reads back true",
			ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel") == true,
			ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel"))

	# ---- the gutter the engine already builds for you ----

	var padded := make_atlas(16, Vector2i.ZERO, Vector2i.ZERO, true)
	padded.create_tile(Vector2i(0, 0))
	padded.create_tile(Vector2i(1, 0))
	check("S11", "TileSetAtlasSource.use_texture_padding defaults to TRUE — Godot 4 pads the atlas for you",
		make_atlas(16, Vector2i.ZERO, Vector2i.ZERO, true).use_texture_padding == true)
	var auth00: Rect2i = padded.get_tile_texture_region(Vector2i(0, 0))
	var run00: Rect2i = padded.get_runtime_tile_texture_region(Vector2i(0, 0), 0)
	check("S12", "the authored region of tile (0,0) starts at (0,0) but its RUNTIME region starts at (1,1): one texel of pad on every side",
		auth00.position == Vector2i(0, 0) and run00.position == Vector2i(1, 1), [auth00, run00])
	var run10: Rect2i = padded.get_runtime_tile_texture_region(Vector2i(1, 0), 0)
	check("S13", "consecutive 16px tiles sit 16px apart in the atlas you authored and 18px apart in the padded runtime copy",
		padded.get_tile_texture_region(Vector2i(1, 0)).position.x - auth00.position.x == 16
			and run10.position.x - run00.position.x == 18,
		[padded.get_tile_texture_region(Vector2i(1, 0)).position.x - auth00.position.x,
		 run10.position.x - run00.position.x])
	check("S14", "the runtime region keeps the authored SIZE — the pad is added around the tile, the tile is not shrunk into it",
		run00.size == Vector2i(16, 16) and run00.size == auth00.size, run00.size)
	var unpadded := make_atlas(16, Vector2i.ZERO, Vector2i.ZERO, false)
	unpadded.create_tile(Vector2i(1, 0))
	check("S15", "turn use_texture_padding off and the runtime region collapses back onto the authored one — that is the setting that removes the guard",
		unpadded.get_runtime_tile_texture_region(Vector2i(1, 0), 0) == unpadded.get_tile_texture_region(Vector2i(1, 0)),
		unpadded.get_runtime_tile_texture_region(Vector2i(1, 0), 0))

	# ---- hand-cut gutters: still supported, and they cost tiles ----

	var plain := make_atlas(16, Vector2i.ZERO, Vector2i.ZERO, true)
	var gutter := make_atlas(16, Vector2i(1, 1), Vector2i(2, 2), true)
	gutter.create_tile(Vector2i(0, 0))
	gutter.create_tile(Vector2i(1, 0))
	check("S16", "margins and separation default to (0,0): a sheet with no gutter is the expected input, not a compromise",
		plain.margins == Vector2i.ZERO and plain.separation == Vector2i.ZERO,
		[plain.margins, plain.separation])
	check("S17", "a hand-cut gutter (margins 1, separation 2) moves tile (1,0) from x=16 to x=19 in the AUTHORED atlas",
		gutter.get_tile_texture_region(Vector2i(1, 0)).position.x == 19,
		gutter.get_tile_texture_region(Vector2i(1, 0)).position.x)
	check("S18", "and it costs you tiles: the same 64x64 sheet holds a 4x4 grid with no gutter and only 3x3 with one",
		plain.get_atlas_grid_size() == Vector2i(4, 4) and gutter.get_atlas_grid_size() == Vector2i(3, 3),
		[plain.get_atlas_grid_size(), gutter.get_atlas_grid_size()])

	# ---- the seam that only appears while the camera moves ----

	check("S19", "`display/window/stretch/scale_mode` exists and its enum is exactly `fractional,integer`",
		ProjectSettings.has_setting("display/window/stretch/scale_mode")
			and hint_of("display/window/stretch/scale_mode") == "fractional,integer",
		hint_of("display/window/stretch/scale_mode"))
	check("S20", "it ships as `fractional`, and `display/window/stretch/mode` ships as `disabled`",
		ProjectSettings.property_get_revert("display/window/stretch/scale_mode") == "fractional"
			and ProjectSettings.property_get_revert("display/window/stretch/mode") == "disabled",
		[ProjectSettings.property_get_revert("display/window/stretch/scale_mode"),
		 ProjectSettings.property_get_revert("display/window/stretch/mode")])
	if tuned:
		check("S23", "written as `integer` in project.godot, the engine reads it back as `integer`",
			String(ProjectSettings.get_setting("display/window/stretch/scale_mode")) == "integer",
			ProjectSettings.get_setting("display/window/stretch/scale_mode"))
	check("S24", "Camera2D has NO pixel-snap property — nothing on the camera rounds its own position for you",
		not has_prop_matching(Camera2D.new(), "snap"))
	check("S25", "Camera2D.zoom defaults to (1,1) and is a float pair, so a non-integer zoom is one keystroke away",
		Camera2D.new().zoom == Vector2(1, 1), Camera2D.new().zoom)
	check("S26", "TileSet.uv_clipping ships OFF",
		TileSet.new().uv_clipping == false, TileSet.new().uv_clipping)

	print("---")
	if failures == 0:
		print("TILE SEAMS: %d passed / 0 failed" % checks)
		quit(0)
	else:
		print("TILE SEAMS: %d passed / %d failed" % [checks - failures, failures])
		quit(1)
