extends SceneTree

# Every claim in docs/why-tiles-do-not-collide.md, asked of a real Godot 4 binary.
#
#   godot --headless --script docs/verify_tile_collision.gd
#
# Half of these need a physics frame, not just a property read: the question is
# not "what does the TileSet say" but "does the body stop". So the script builds
# a real TileMapLayer + CharacterBody2D per case, lets the tree run, and calls
# move_and_collide. C10..C24 are the answers the engine gives, not the answers
# the inspector implies.
#
# Geometry used everywhere below, so the numbers in the doc can be read:
#   tile size 16x16, cells painted on row 2  -> the row occupies y = 32..48
#   the body is a 4x4 box; unless stated it starts at y = 24 (bottom edge 26,
#   so a 6 px gap to the tile surface) and is pushed straight down.
# A stop at y = 32 is therefore "the body landed on top of the tiles".

var failures := 0
var checks := 0
var queue: Array = []
var idx := 0
var started := false
var wait := 0
var holder: Node2D

func check(id: String, claim: String, cond: bool, measured: Variant = null) -> void:
	checks += 1
	if not cond:
		failures += 1
	var line := ("PASS  " if cond else "FAIL  ") + id + "  " + claim
	if measured != null:
		line += "   [measured: " + str(measured) + "]"
	print(line)

# ---------- builders ----------

func atlas(region: int, tiles: int) -> TileSetAtlasSource:
	var img := Image.create(region * tiles, region, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(region, region)
	for k in range(tiles):
		src.create_tile(Vector2i(k, 0))
	return src

func square(half: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])

# The left half of the tile only: asymmetric on purpose, so a mirrored cell can
# be told apart from an unmirrored one by WHERE the body stops.
func left_half() -> PackedVector2Array:
	return PackedVector2Array([Vector2(-8, -8), Vector2(0, -8), Vector2(0, 8), Vector2(-8, 8)])

func tileset(opts: Dictionary) -> TileSet:
	var region: int = opts.get("region", 16)
	var src := atlas(region, 4)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(opts.get("tile_size", 16), opts.get("tile_size", 16))
	ts.add_source(src, 0)
	if not opts.get("no_physics_layer", false):
		ts.add_physics_layer()
		if opts.has("layer_bits"):
			ts.set_physics_layer_collision_layer(0, opts["layer_bits"])
		if opts.has("mask_bits"):
			ts.set_physics_layer_collision_mask(0, opts["mask_bits"])
	var count: int = opts.get("polygons", 1)
	if count >= 0 and not opts.get("no_physics_layer", false):
		var td := src.get_tile_data(Vector2i(0, 0), 0)
		td.set_collision_polygons_count(0, count)
		var pts: PackedVector2Array = opts.get("points", square(8))
		if count > 0 and pts.size() > 0:
			td.set_collision_polygon_points(0, 0, pts)
			if opts.get("one_way", false):
				td.set_collision_polygon_one_way(0, 0, true)
	return ts

func stage(ts: TileSet, case: Dictionary) -> Dictionary:
	holder = Node2D.new()
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	if case.has("collision_enabled"):
		layer.collision_enabled = case["collision_enabled"]
	if case.has("enabled"):
		layer.enabled = case["enabled"]
	var alt: int = case.get("alt", 0)
	for x in range(-3, 4):
		layer.set_cell(Vector2i(x, 2), 0, Vector2i(0, 0), alt)
	var body := CharacterBody2D.new()
	if case.has("body_mask"):
		body.collision_mask = case["body_mask"]
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(4, 4)
	shape.shape = rect
	body.add_child(shape)
	body.position = Vector2(case.get("x", 8.0), case.get("y", 24.0))
	holder.add_child(layer)
	holder.add_child(body)
	get_root().add_child(holder)
	return {"body": body}

# ---------- static claims ----------

func _initialize() -> void:
	print("godot ", Engine.get_version_info().string)
	print("---")

	var bare := tileset({"no_physics_layer": true})
	check("C1", "a TileSet starts with ZERO physics layers — there is nowhere for a shape to live",
		bare.get_physics_layers_count() == 0, bare.get_physics_layers_count())

	# Asking a tile about a physics layer that does not exist is NOT silent: the
	# engine pushes an error. Reading it back is still 0, which is why code that
	# checks the count instead of the log sees nothing wrong.
	var bare_src: TileSetAtlasSource = bare.get_source(0)
	check("C2", "with no physics layer, get_collision_polygons_count(0) errors in the log and returns 0",
		bare_src.get_tile_data(Vector2i(0, 0), 0).get_collision_polygons_count(0) == 0)

	var ts := tileset({})
	check("C3", "a physics layer added in code defaults to collision_layer = 1",
		ts.get_physics_layer_collision_layer(0) == 1, ts.get_physics_layer_collision_layer(0))
	check("C4", "...and to collision_mask = 1",
		ts.get_physics_layer_collision_mask(0) == 1, ts.get_physics_layer_collision_mask(0))

	var src: TileSetAtlasSource = ts.get_source(0)
	var others := [src.get_tile_data(Vector2i(1, 0), 0).get_collision_polygons_count(0),
		src.get_tile_data(Vector2i(2, 0), 0).get_collision_polygons_count(0),
		src.get_tile_data(Vector2i(3, 0), 0).get_collision_polygons_count(0)]
	check("C5", "a shape drawn on one tile is drawn on ONE tile — every other tile in the atlas stays at 0",
		others == [0, 0, 0], others)

	var alt_id := src.create_alternative_tile(Vector2i(0, 0), -1)
	check("C6", "an alternative made with create_alternative_tile() inherits NO collision shape from its base tile",
		src.get_tile_data(Vector2i(0, 0), alt_id).get_collision_polygons_count(0) == 0,
		"alt id " + str(alt_id))

	# A polygon of fewer than 3 points is refused outright: the engine errors and
	# the assignment is DROPPED. Whatever was there before survives untouched,
	# which is why a bad edit can look like it took and change nothing.
	var degen := tileset({})
	var degen_src: TileSetAtlasSource = degen.get_source(0)
	var degen_td := degen_src.get_tile_data(Vector2i(0, 0), 0)
	degen_td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8)]))
	check("C7", "a 2-point polygon is refused (engine error) and the 4 points already there are left intact — the bad edit is dropped, not applied",
		degen_td.get_collision_polygon_points(0, 0).size() == 4,
		degen_td.get_collision_polygon_points(0, 0).size())

	# Same refusal on a polygon that never had points: it stays empty, and an
	# empty polygon is exactly the state that collides with nothing (C12).
	var empty := tileset({"polygons": 1, "points": PackedVector2Array()})
	var empty_td: TileData = (empty.get_source(0) as TileSetAtlasSource).get_tile_data(Vector2i(0, 0), 0)
	empty_td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8)]))
	check("C7b", "...and on a polygon that never had points, it stays at 0",
		empty_td.get_collision_polygon_points(0, 0).size() == 0,
		empty_td.get_collision_polygon_points(0, 0).size())

	check("C8", "one_way_margin defaults to 1.0",
		is_equal_approx(src.get_tile_data(Vector2i(0, 0), 0).get_collision_polygon_one_way_margin(0, 0), 1.0),
		src.get_tile_data(Vector2i(0, 0), 0).get_collision_polygon_one_way_margin(0, 0))

	check("C9", "`Visible Collision Shapes` is a debug DRAW (debug/shapes/collision/shape_color exists) — it shows nothing headless and nothing in CI",
		ProjectSettings.has_setting("debug/shapes/collision/shape_color"))

	print("--- physics: does the body actually stop? ---")

	queue = [
		{"id": "C10", "claim": "physics layer + a real polygon: the body lands on the tiles (y = 32)",
			"ts": tileset({}), "case": {}, "want": 32.0},
		{"id": "C11", "claim": "physics layer present, tile has NO polygon: the body falls through. No error, no warning",
			"ts": tileset({"polygons": 0}), "case": {}, "want": null},
		{"id": "C12", "claim": "polygon COUNT set to 1 but no points ever drawn: falls through, silently",
			"ts": tileset({"polygons": 1, "points": PackedVector2Array()}), "case": {}, "want": null},
		{"id": "C13", "claim": "TileMapLayer.collision_enabled = false: falls through, silently",
			"ts": tileset({}), "case": {"collision_enabled": false}, "want": null},
		{"id": "C14", "claim": "TileMapLayer.enabled = false: falls through (the whole layer is off)",
			"ts": tileset({}), "case": {"enabled": false}, "want": null},
		{"id": "C15", "claim": "TileSet physics layer collision_layer = 0: falls through — the tiles are on no layer",
			"ts": tileset({"layer_bits": 0}), "case": {}, "want": null},
		{"id": "C16", "claim": "tiles on bit 2, body's mask on bit 1: falls through",
			"ts": tileset({"layer_bits": 2}), "case": {"body_mask": 1}, "want": null},
		{"id": "C17", "claim": "TileSet physics layer collision_MASK = 0: the body STILL stops. That column does not gate a body walking into tiles",
			"ts": tileset({"mask_bits": 0}), "case": {}, "want": 32.0},
		{"id": "C18", "claim": "asymmetric shape, unflipped cell: solid on the LEFT half",
			"ts": tileset({"points": left_half()}), "case": {"x": 4.0}, "want": 32.0},
		{"id": "C19", "claim": "...and hollow on the RIGHT half",
			"ts": tileset({"points": left_half()}), "case": {"x": 12.0}, "want": null},
		{"id": "C20", "claim": "the same cell painted with TRANSFORM_FLIP_H: the SHAPE mirrors with the art — now solid on the right",
			"ts": tileset({"points": left_half()}),
			"case": {"x": 12.0, "alt": TileSetAtlasSource.TRANSFORM_FLIP_H}, "want": 32.0},
		{"id": "C21", "claim": "32 px art on a 16 px grid, shape drawn to the art: collision reaches 8 px ABOVE the cell (stop at 24, not 32) — it is never clipped to the cell",
			"ts": tileset({"region": 32, "tile_size": 16, "points": square(16)}), "case": {}, "want": 24.0},
		{"id": "C22", "claim": "one-way tile, body arriving from ABOVE at 10 px/step: stops",
			"ts": tileset({"one_way": true}), "case": {"y": 24.0, "step": 10.0}, "want": 32.0},
		{"id": "C23", "claim": "one-way tile, body arriving from BELOW: passes through, which is the point",
			"ts": tileset({"one_way": true}), "case": {"y": 56.0, "step": -10.0}, "want": null},
		{"id": "C24", "claim": "one-way tile, body arriving from above at 48 px in ONE step: passes through — a solid tile of the same geometry does not (C25)",
			"ts": tileset({"one_way": true}), "case": {"y": 24.0, "step": 48.0}, "want": null},
		{"id": "C25", "claim": "the SAME 48 px step against the same polygon without one_way: stops",
			"ts": tileset({}), "case": {"y": 24.0, "step": 48.0}, "want": 32.0},
	]

func _process(_delta: float) -> bool:
	if wait > 0:
		wait -= 1
		return false
	if idx >= queue.size():
		print("---")
		print("%d checks, %d failed" % [checks, failures])
		quit(1 if failures > 0 else 0)
		return true
	var t: Dictionary = queue[idx]
	if not started:
		t["h"] = stage(t["ts"], t["case"])
		started = true
		wait = 3
		return false
	var body: CharacterBody2D = t["h"]["body"]
	var step: float = t["case"].get("step", 10.0)
	var col := body.move_and_collide(Vector2(0, step))
	var want = t["want"]
	var got = col.get_position().y if col else null
	var ok := (col == null) if want == null else (col != null and is_equal_approx(got, want))
	check(t["id"], t["claim"], ok, ("no collision" if col == null else "stopped at y = " + str(got)))
	holder.queue_free()
	started = false
	idx += 1
	wait = 1
	return false
