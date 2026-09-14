extends SceneTree
##
## Reproduces every claim in docs/why-get-custom-data-returns-null.md against a
## real engine.
##
## Standalone: builds its own TileSets, TileMapLayers and CharacterBody2D in
## memory, needs no project assets. Run through verify_tile_custom_data.sh,
## which builds the empty project this script expects.
##
## Prints PASS/FAIL per check and a final "CUSTOM DATA:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
## LG_CDPROBE=get_wrong|set_wrong|get_right runs one call and quits, so the
## wrapper can count the ERROR lines each one prints.
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

var failures := 0


func check_eq(name: String, got: Variant, want: Variant) -> void:
	# typeof first: in GDScript 0 == false and 2 == 2.0, and the page is about
	# telling those apart.
	var ok: bool = typeof(got) == typeof(want) and got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))
	if not ok:
		failures += 1


# One 16x16 tile at atlas (0,0), optionally with a full-square collision polygon.
func tileset(with_collision := false) -> TileSet:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	if with_collision:
		ts.add_physics_layer()
	ts.add_source(src)
	if with_collision:
		var td := tile(ts)
		td.add_collision_polygon(0)
		td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	return ts


func tile(ts: TileSet) -> TileData:
	return (ts.get_source(0) as TileSetAtlasSource).get_tile_data(Vector2i(0, 0), 0)


func add_layer(ts: TileSet, layer_name: String, type: int) -> void:
	var i := ts.get_custom_data_layers_count()
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(i, layer_name)
	ts.set_custom_data_layer_type(i, type)


# hp:int = 5, ladder:bool = true
func hp_ladder() -> TileSet:
	var ts := tileset()
	add_layer(ts, "hp", TYPE_INT)
	add_layer(ts, "ladder", TYPE_BOOL)
	tile(ts).set_custom_data("hp", 5)
	tile(ts).set_custom_data("ladder", true)
	return ts


func error_probe(mode: String) -> void:
	var ts := hp_ladder()
	match mode:
		"get_wrong":
			tile(ts).get_custom_data("HP")
		"set_wrong":
			tile(ts).set_custom_data("nope", 1)
		"get_right":
			tile(ts).get_custom_data("hp")
	print("CDPROBE DONE")
	quit(0)


# A floor of tiles on row 2 (y 32..48), a 10x12 CharacterBody2D whose origin is
# at its feet, dropped from y=0 at x. Returns [layer, body] after it has landed.
func landed_body(x: float, quadrant := 0) -> Array:
	var ts := tileset(true)
	add_layer(ts, "surface", TYPE_STRING)
	tile(ts).set_custom_data("surface", "ice")
	var L := TileMapLayer.new()
	L.tile_set = ts
	if quadrant > 0:
		L.set("physics_quadrant_size", quadrant)
	root.add_child(L)
	for cx in range(-2, 40):
		L.set_cell(Vector2i(cx, 2), 0, Vector2i(0, 0))
	var body := CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(10, 12)
	cs.shape = sh
	cs.position = Vector2(0, -6)
	body.add_child(cs)
	body.position = Vector2(x, 0)
	root.add_child(body)
	await physics_frame
	for i in 90:
		body.velocity.y += 20
		body.move_and_slide()
		await physics_frame
	return [L, body]


func surface_under(L: TileMapLayer, p: Vector2) -> Variant:
	var td := L.get_cell_tile_data(L.local_to_map(L.to_local(p)))
	return td.get_custom_data("surface") if td else null


func _initialize() -> void:
	var probe := OS.get_environment("LG_CDPROBE")
	if probe != "":
		await error_probe(probe)
		return

	var ts: TileSet
	var td: TileData

	# --- control -------------------------------------------------------------
	ts = hp_ladder()
	check_eq("K1 control: get_custom_data(\"hp\") after set_custom_data(\"hp\", 5) is 5", tile(ts).get_custom_data("hp"), 5)

	# --- the value you get when nothing was set -------------------------------
	ts = tileset()
	add_layer(ts, "hp", TYPE_INT)
	add_layer(ts, "ladder", TYPE_BOOL)
	add_layer(ts, "name", TYPE_STRING)
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(3, "untyped")
	td = tile(ts)
	check_eq("D1 int layer, never set on this tile: 0, not null", td.get_custom_data("hp"), 0)
	check_eq("D1 bool layer, never set: false", td.get_custom_data("ladder"), false)
	check_eq("D1 String layer, never set: \"\"", td.get_custom_data("name"), "")
	check_eq("D2 a layer added without a type is TYPE_NIL", ts.get_custom_data_layer_type(3), TYPE_NIL)
	check_eq("D2 ... and reads null even though the layer exists", td.get_custom_data("untyped"), null)
	add_layer(ts, "late", TYPE_INT)
	check_eq("D3 layer added after the tile was made: the tile reads its default 0", td.get_custom_data("late"), 0)

	# --- names ------------------------------------------------------------------
	ts = hp_ladder()
	td = tile(ts)
	check_eq("D4 names are case-sensitive: get_custom_data(\"HP\") is null", td.get_custom_data("HP"), null)
	td.set_custom_data("nope", 1)
	check_eq("D4 set_custom_data on a missing name creates no layer", ts.get_custom_data_layer_by_name("nope"), -1)
	if td.has_method("has_custom_data"):  # 4.4+
		check_eq("D4 4.4+: has_custom_data(\"HP\") false, has_custom_data(\"hp\") true", [td.has_custom_data("HP"), td.has_custom_data("hp")], [false, true])
	check_eq("D5 by index: get_custom_data_by_layer_id(1) is ladder's true", td.get_custom_data_by_layer_id(1), true)
	ts.set_custom_data_layer_name(0, "health")
	check_eq("D6 renaming a layer keeps the value under the new name", td.get_custom_data("health"), 5)
	check_eq("D6 ... and the old name still reads 5 on this TileSet object", td.get_custom_data("hp"), 5)

	# --- types ------------------------------------------------------------------
	ts = hp_ladder()
	td = tile(ts)
	td.set_custom_data("hp", "7")
	check_eq("D7 set_custom_data(\"hp\", \"7\") on an int layer stores the String \"7\"", td.get_custom_data("hp"), "7")
	ts = hp_ladder()
	td = tile(ts)
	ts.set_custom_data_layer_type(0, TYPE_STRING)
	check_eq("D8 changing a layer int -> String turns the stored 5 into null", td.get_custom_data("hp"), null)
	ts = tileset()
	add_layer(ts, "speed", TYPE_FLOAT)
	td = tile(ts)
	td.set_custom_data("speed", 2.5)
	ts.set_custom_data_layer_type(0, TYPE_INT)
	check_eq("D8 changing a layer float -> int turns 2.5 into 2", td.get_custom_data("speed"), 2)

	# --- reordering layers from code: the name lookup goes stale ---------------
	ts = hp_ladder()
	td = tile(ts)
	ts.add_custom_data_layer(0)
	check_eq("R1 add_custom_data_layer(0): the values move up (index 1 is 5, index 2 is true)",
		[td.get_custom_data_by_layer_id(1), td.get_custom_data_by_layer_id(2)], [5, true])
	check_eq("R1 ... the layer names move up (index 1 \"hp\", index 2 \"ladder\")",
		[ts.get_custom_data_layer_name(1), ts.get_custom_data_layer_name(2)], ["hp", "ladder"])
	check_eq("R1 ... but get_custom_data_layer_by_name still says hp=0, ladder=1",
		[ts.get_custom_data_layer_by_name("hp"), ts.get_custom_data_layer_by_name("ladder")], [0, 1])
	check_eq("R1 ... so get_custom_data(\"hp\") is null and get_custom_data(\"ladder\") is hp's 5",
		[td.get_custom_data("hp"), td.get_custom_data("ladder")], [null, 5])
	ts.set_custom_data_layer_name(0, "new")
	check_eq("R1 ... naming the new layer does not refresh the other names", td.get_custom_data("ladder"), 5)
	ts = hp_ladder()
	td = tile(ts)
	ts.move_custom_data_layer(1, 0)
	check_eq("R2 move_custom_data_layer(1, 0): get_custom_data(\"hp\") is ladder's true",
		[td.get_custom_data("hp"), td.get_custom_data("ladder")], [true, 5])
	ts = hp_ladder()
	td = tile(ts)
	ts.remove_custom_data_layer(0)
	check_eq("R3 control: remove_custom_data_layer(0) does refresh — ladder is true, hp gone",
		[td.get_custom_data("ladder"), ts.get_custom_data_layer_by_name("hp")], [true, -1])
	ts = hp_ladder()
	ts.add_custom_data_layer(0)
	ResourceSaver.save(ts, "user://custom_data_check.tres")
	var re: TileSet = ResourceLoader.load("user://custom_data_check.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	check_eq("R4 the same TileSet saved and loaded again reads hp=5, ladder=true",
		[tile(re).get_custom_data("hp"), tile(re).get_custom_data("ladder")], [5, true])
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://custom_data_check.tres"))

	# --- the cell under a character -----------------------------------------------
	var L := TileMapLayer.new()
	L.tile_set = hp_ladder()
	root.add_child(L)
	check_eq("C1 an empty cell: get_cell_tile_data() is null", L.get_cell_tile_data(Vector2i(0, 0)) == null, true)
	check_eq("C2 local y=16.0 is row 1, y=15.99 is row 0 — the top edge belongs to the cell below",
		[L.local_to_map(Vector2(8, 16)), L.local_to_map(Vector2(8, 15.99))], [Vector2i(0, 1), Vector2i(0, 0)])
	L.queue_free()

	var lb: Array = await landed_body(40.0)
	var PL: TileMapLayer = lb[0]
	var body: CharacterBody2D = lb[1]
	check_eq("C3 control: the body landed (is_on_floor)", body.is_on_floor(), true)
	check_eq("C3 it rests ABOVE the floor's top edge y=32 (safe_margin), not on it", body.global_position.y < 32.0 and body.global_position.y > 31.9, true)
	check_eq("C3 ... so the cell at its origin is the empty row 1, and its tile data is null",
		[PL.local_to_map(PL.to_local(body.global_position)), surface_under(PL, body.global_position)], [Vector2i(2, 1), null])
	check_eq("C4 one pixel lower is the floor: surface \"ice\"", surface_under(PL, body.global_position + Vector2(0, 1)), "ice")
	var col := body.get_last_slide_collision()
	check_eq("C5 collision point minus normal lands in the floor cell (2,2)",
		PL.local_to_map(PL.to_local(col.get_position() - col.get_normal())), Vector2i(2, 2))

	var has_quadrant := "physics_quadrant_size" in PL
	var rid_cell := PL.get_coords_for_body_rid(col.get_collider_rid())
	if not has_quadrant:
		check_eq("Q1 4.3/4.4 (no physics_quadrant_size): get_coords_for_body_rid is the cell (2,2)", rid_cell, Vector2i(2, 2))
	else:
		check_eq("Q1 4.5+: physics_quadrant_size defaults to 16", PL.get("physics_quadrant_size"), 16)
		check_eq("Q1 ... and get_coords_for_body_rid returns (0,0) for a body standing on cell (2,2)", rid_cell, Vector2i(0, 0))
		body.queue_free()
		PL.queue_free()
		lb = await landed_body(280.0)
		col = (lb[1] as CharacterBody2D).get_last_slide_collision()
		check_eq("Q2 standing on cell (17,2): get_coords_for_body_rid returns (1,0), the index of its 16x16 chunk, not a cell",
			(lb[0] as TileMapLayer).get_coords_for_body_rid(col.get_collider_rid()), Vector2i(1, 0))
		(lb[1] as Node).queue_free()
		(lb[0] as Node).queue_free()
		lb = await landed_body(40.0, 1)
		col = (lb[1] as CharacterBody2D).get_last_slide_collision()
		check_eq("Q3 with physics_quadrant_size = 1 it is the cell (2,2) again",
			(lb[0] as TileMapLayer).get_coords_for_body_rid(col.get_collider_rid()), Vector2i(2, 2))

	print("CUSTOM DATA: " + ("ALL PASS" if failures == 0 else "%d FAILED" % failures))
	quit(0)
