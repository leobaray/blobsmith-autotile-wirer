extends SceneTree
##
## Reproduces every claim in docs/why-the-tile-under-the-mouse-is-the-wrong-one.md
## against a real engine.
##
## Standalone: builds its own TileMapLayers in memory, needs no project assets.
## Run through verify_mouse_to_cell.sh, which builds the empty project this
## script expects.
##
## Prints PASS/FAIL per check and a final "MOUSE TO CELL:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
## LG_SELFTEST=1 flips the expectation of M1, to prove the harness can fail.

var failures := 0


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = got == want
	if name.begins_with("M1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


func make_layer(shape := TileSet.TILE_SHAPE_SQUARE, size := Vector2i(16, 16)) -> TileMapLayer:
	var ts := TileSet.new()
	ts.tile_shape = shape
	ts.tile_size = size
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	return layer


func _initialize() -> void:
	var layer := make_layer()
	root.add_child(layer)

	# --- the grid itself ---------------------------------------------------
	check_eq("M1 local_to_map floors: (15.9,0) is cell (0,0)", layer.local_to_map(Vector2(15.9, 0)), Vector2i(0, 0))
	check_eq("M1 local_to_map floors: (16,0) is cell (1,0)", layer.local_to_map(Vector2(16, 0)), Vector2i(1, 0))
	check_eq("M1 local_to_map floors: (-1,-1) is cell (-1,-1)", layer.local_to_map(Vector2(-1, -1)), Vector2i(-1, -1))
	check_eq("M1 local_to_map floors: (-16.1,0) is cell (-2,0)", layer.local_to_map(Vector2(-16.1, 0)), Vector2i(-2, 0))
	check_eq("M2 hand-rolled Vector2i(pos / 16) truncates: (-1,-1) becomes (0,0)", Vector2i(Vector2(-1, -1) / 16.0), Vector2i(0, 0))
	check_eq("K1 control: (pos / 16).floor() gives (-1,-1)", Vector2i((Vector2(-1, -1) / 16.0).floor()), Vector2i(-1, -1))
	check_eq("M3 map_to_local returns the cell CENTRE: (0,0) -> (8,8)", layer.map_to_local(Vector2i(0, 0)), Vector2(8, 8))
	check_eq("M3 map_to_local returns the cell CENTRE: (-1,2) -> (-8,40)", layer.map_to_local(Vector2i(-1, 2)), Vector2(-8, 40))

	# --- the node's own transform -----------------------------------------
	layer.position = Vector2(100, 50)
	check_eq("M4 layer at (100,50): global (120,60) passed raw -> (7,3)", layer.local_to_map(Vector2(120, 60)), Vector2i(7, 3))
	check_eq("M4 layer at (100,50): to_local() first -> (1,0)", layer.local_to_map(layer.to_local(Vector2(120, 60))), Vector2i(1, 0))
	layer.position = Vector2.ZERO
	layer.scale = Vector2(2, 2)
	check_eq("M5 layer scaled 2x: global (40,0) passed raw -> (2,0)", layer.local_to_map(Vector2(40, 0)), Vector2i(2, 0))
	check_eq("M5 layer scaled 2x: to_local() first -> (1,0)", layer.local_to_map(layer.to_local(Vector2(40, 0))), Vector2i(1, 0))
	check_eq("M5 layer scaled 2x: map_to_local(1,0) is still LOCAL (24,8)", layer.map_to_local(Vector2i(1, 0)), Vector2(24, 8))
	check_eq("M5 layer scaled 2x: to_global() of it is (48,16)", layer.to_global(layer.map_to_local(Vector2i(1, 0))), Vector2(48, 16))
	layer.scale = Vector2.ONE

	var parent := Node2D.new()
	root.add_child(parent)
	layer.reparent(parent)
	parent.position = Vector2(32, 0)
	parent.rotation = PI / 2
	check_eq("M6 rotated parent: pos - global_position -> (0,1), wrong", layer.local_to_map(Vector2(32, 20) - layer.global_position), Vector2i(0, 1))
	check_eq("M6 rotated parent: to_local() -> (1,0)", layer.local_to_map(layer.to_local(Vector2(32, 20))), Vector2i(1, 0))
	parent.rotation = 0
	parent.position = Vector2.ZERO

	# --- the camera ---------------------------------------------------------
	var cam := Camera2D.new()
	cam.zoom = Vector2(2, 2)
	cam.position = Vector2(200, 0)
	root.add_child(cam)
	for i in 3:
		await process_frame
	var vs := root.get_visible_rect().size
	var ct := root.get_canvas_transform()
	check_eq("M7 the camera lives in the canvas transform: origin = viewport centre - position * zoom", ct.origin, vs / 2 - Vector2(200, 0) * 2)
	var ev := InputEventMouseButton.new()
	ev.position = Vector2(vs.x / 2 + 20, vs.y / 2)
	var want := Vector2i((Vector2(200, 0) + Vector2(20, 0) / 2).floor() / 16)
	check_eq("M7 event.position passed raw ignores the camera", layer.local_to_map(ev.position) == want, false)
	check_eq("M7 make_input_local(event).position -> the cell under the pointer", layer.local_to_map(layer.make_input_local(ev).position), want)
	check_eq("M7 canvas_transform.affine_inverse() * event.position -> same cell", layer.local_to_map(layer.to_local(ct.affine_inverse() * ev.position)), want)
	check_eq("M8 get_global_mouse_position() already includes the camera",
		layer.get_global_mouse_position(), ct.affine_inverse() * root.get_mouse_position())

	layer.position = Vector2(100, 50)
	layer.scale = Vector2(2, 2)
	check_eq("M8 get_local_mouse_position() == to_local(get_global_mouse_position()), camera + offset + scale",
		layer.get_local_mouse_position(), layer.to_local(layer.get_global_mouse_position()))
	check_eq("K2 control: under offset + scale, global and local mouse positions differ",
		layer.get_local_mouse_position() == layer.get_global_mouse_position(), false)
	layer.position = Vector2.ZERO
	layer.scale = Vector2.ONE

	var cl := CanvasLayer.new()
	root.add_child(cl)
	var hud := make_layer()
	cl.add_child(hud)
	check_eq("M9 a TileMapLayer under a CanvasLayer ignores the camera: make_input_local == raw",
		hud.local_to_map(hud.make_input_local(ev).position), hud.local_to_map(ev.position))

	# --- non-square shapes ------------------------------------------------
	var iso := make_layer(TileSet.TILE_SHAPE_ISOMETRIC, Vector2i(64, 32))
	root.add_child(iso)
	check_eq("M10 isometric 64x32: local (0,0) is cell (-1,-1), not (0,0)", iso.local_to_map(Vector2(0, 0)), Vector2i(-1, -1))
	check_eq("M10 isometric 64x32: map_to_local(0,0) is (32,16)", iso.map_to_local(Vector2i(0, 0)), Vector2(32, 16))
	check_eq("M10 isometric: (0,17) is cell (-1,1)", iso.local_to_map(Vector2(0, 17)), Vector2i(-1, 1))
	check_eq("K3 control: the naive floor(pos / tile_size) says (0,0) for the same point", Vector2i((Vector2(0, 17) / Vector2(64, 32)).floor()), Vector2i(0, 0))
	check_eq("M11 a new TileSet's tile_layout is STACKED", iso.tile_set.tile_layout, TileSet.TILE_LAYOUT_STACKED)
	check_eq("M11 stacked isometric: map_to_local(0,1) is (64,32)", iso.map_to_local(Vector2i(0, 1)), Vector2(64, 32))
	check_eq("M11 stacked isometric: map_to_local(1,1) is (128,32)", iso.map_to_local(Vector2i(1, 1)), Vector2(128, 32))
	var rt_ok := true
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 3), Vector2i(-3, -2)]:
		if iso.local_to_map(iso.map_to_local(c)) != c:
			rt_ok = false
	check_eq("M12 local_to_map(map_to_local(c)) == c for isometric cells incl. negative", rt_ok, true)
	var hex := make_layer(TileSet.TILE_SHAPE_HEXAGON, Vector2i(16, 16))
	root.add_child(hex)
	check_eq("M12 hexagon 16x16: map_to_local(0,1) is (16,20), half a tile right", hex.map_to_local(Vector2i(0, 1)), Vector2(16, 20))

	print("MOUSE TO CELL: " + ("ALL PASS" if failures == 0 else "%d FAILED" % failures))
	quit(0 if failures == 0 else 1)
