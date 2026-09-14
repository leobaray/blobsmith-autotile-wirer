extends SceneTree
##
## Reproduces every claim in docs/why-astargrid2d-walks-through-walls.md against
## a real engine.
##
## Standalone: builds its own AStarGrid2D, TileSets and TileMapLayers in memory,
## needs no project assets. Pathfinding is math, not pixels, so this runs on the
## headless renderer. Run it through verify_astar_grid.sh.
##
## Prints PASS/FAIL per check and a final "ASTAR GRID:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
## LG_ASTARPROBE=errors runs only the two calls whose ERROR text the page quotes
## and quits, so the wrapper can grep for it.
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

var failures := 0
var minor: int = Engine.get_version_info().minor


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = typeof(got) == typeof(want) and got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


func ids(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(Vector2i(v))
	return out


func grid(region: Rect2i, diag := AStarGrid2D.DIAGONAL_MODE_NEVER) -> AStarGrid2D:
	var a := AStarGrid2D.new()
	a.region = region
	a.diagonal_mode = diag
	a.update()
	return a


func _init() -> void:
	if OS.get_environment("LG_ASTARPROBE") == "errors":
		var p := AStarGrid2D.new()
		p.get_id_path(Vector2i(0, 0), Vector2i(1, 0))
		p.region = Rect2i(0, 0, 5, 5)
		p.set_point_solid(Vector2i(2, 0), true)
		print("ASTARPROBE DONE")
		quit()
		return

	print("Godot ", Engine.get_version_info().string)

	# --- 1. a fresh grid has no cells ------------------------------------------
	var fresh := AStarGrid2D.new()
	check_eq("R1 default region is Rect2i(0, 0, 0, 0)", fresh.region, Rect2i())
	check_eq("R2 default cell_size is (1, 1)", fresh.cell_size, Vector2(1, 1))
	check_eq("R3 get_id_path on the default region returns []", ids(fresh.get_id_path(Vector2i(0, 0), Vector2i(1, 0))), [])
	check_eq("R4 default diagonal_mode is ALWAYS", fresh.diagonal_mode, AStarGrid2D.DIAGONAL_MODE_ALWAYS)

	# --- 2. update() wipes solids and weights ----------------------------------
	var u := AStarGrid2D.new()
	u.region = Rect2i(0, 0, 5, 5)
	check_eq("U1 setting region marks the grid dirty", u.is_dirty(), true)
	u.set_point_solid(Vector2i(2, 0), true)
	u.update()
	check_eq("U2 a solid set before update() is gone after it", u.is_point_solid(Vector2i(2, 0)), false)
	check_eq("U3 update() clears the dirty flag", u.is_dirty(), false)
	u.set_point_solid(Vector2i(2, 0), true)
	u.set_point_weight_scale(Vector2i(1, 1), 50.0)
	check_eq("U4 solid set after update() sticks", u.is_point_solid(Vector2i(2, 0)), true)
	u.region = Rect2i(0, 0, 6, 5)
	check_eq("U5 changing region marks dirty again", u.is_dirty(), true)
	u.update()
	check_eq("U6 update() after a region change wipes the solid", u.is_point_solid(Vector2i(2, 0)), false)
	check_eq("U7 ...and the weight scale (back to 1)", u.get_point_weight_scale(Vector2i(1, 1)), 1.0)
	u.set_point_solid(Vector2i(2, 0), true)
	u.cell_size = Vector2(16, 16)
	check_eq("U8 changing cell_size marks dirty", u.is_dirty(), true)
	u.update()
	check_eq("U9 update() after a cell_size change wipes the solid too", u.is_point_solid(Vector2i(2, 0)), false)
	u.offset = Vector2(8, 8)
	check_eq("U10 changing offset marks dirty", u.is_dirty(), true)
	u.update()
	u.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	check_eq("U11 changing diagonal_mode does NOT mark dirty", u.is_dirty(), false)
	check_eq("U12 an unpainted point is walkable (is_point_solid false)", u.is_point_solid(Vector2i(4, 4)), false)
	u.fill_solid_region(u.region)
	check_eq("U13 fill_solid_region(region) marks every point solid, no update() needed", u.is_point_solid(Vector2i(4, 4)) and u.is_point_solid(Vector2i(0, 0)) and not u.is_dirty(), true)

	# --- 3. diagonals cut corners by default -----------------------------------
	var d := grid(Rect2i(0, 0, 3, 3), AStarGrid2D.DIAGONAL_MODE_ALWAYS)
	d.set_point_solid(Vector2i(1, 0), true)
	d.set_point_solid(Vector2i(0, 1), true)
	check_eq("D1 ALWAYS squeezes between two solid orthogonal neighbours", ids(d.get_id_path(Vector2i(0, 0), Vector2i(1, 1))), [Vector2i(0, 0), Vector2i(1, 1)])
	d.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	check_eq("D2 ONLY_IF_NO_OBSTACLES refuses it (no path, no update() needed)", ids(d.get_id_path(Vector2i(0, 0), Vector2i(1, 1))), [])
	var d2 := grid(Rect2i(0, 0, 3, 3), AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE)
	d2.set_point_solid(Vector2i(1, 0), true)
	check_eq("D3 AT_LEAST_ONE_WALKABLE still cuts past one solid corner", ids(d2.get_id_path(Vector2i(0, 0), Vector2i(1, 1))), [Vector2i(0, 0), Vector2i(1, 1)])
	var d3 := grid(Rect2i(0, 0, 4, 4), AStarGrid2D.DIAGONAL_MODE_ALWAYS)
	check_eq("D4 default mode walks (0,0)->(3,3) as a pure diagonal", ids(d3.get_id_path(Vector2i(0, 0), Vector2i(3, 3))), [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3)])

	# --- 4. solid ends and partial paths ---------------------------------------
	var w := grid(Rect2i(0, 0, 5, 3))
	for y in 3:
		w.set_point_solid(Vector2i(2, y), true)
	check_eq("P1 target behind a full wall: []", ids(w.get_id_path(Vector2i(0, 1), Vector2i(4, 1))), [])
	check_eq("P2 allow_partial_path=true: walks to the closest reachable cell", ids(w.get_id_path(Vector2i(0, 1), Vector2i(4, 1), true)), [Vector2i(0, 1), Vector2i(1, 1)])
	check_eq("P3 solid target: []", ids(w.get_id_path(Vector2i(0, 1), Vector2i(2, 1))), [])
	check_eq("P4 get_point_path to a solid target: []", w.get_point_path(Vector2i(0, 1), Vector2i(2, 1)).size(), 0)
	if minor <= 3:
		check_eq("P5 (4.3) solid target with allow_partial_path: still []", ids(w.get_id_path(Vector2i(0, 1), Vector2i(2, 1), true)), [])
	else:
		check_eq("P5 (4.4+) solid target with allow_partial_path: stops next to it", ids(w.get_id_path(Vector2i(0, 1), Vector2i(2, 1), true)), [Vector2i(0, 1), Vector2i(1, 1)])
	if minor <= 4:
		check_eq("P6 (4.3/4.4) solid START: path found anyway", ids(w.get_id_path(Vector2i(2, 1), Vector2i(0, 1))), [Vector2i(2, 1), Vector2i(1, 1), Vector2i(0, 1)])
	elif minor >= 7:
		check_eq("P6 (4.7) solid START: []", ids(w.get_id_path(Vector2i(2, 1), Vector2i(0, 1))), [])
	else:
		print("NOTE  P6 not measured on 4.%d: got %s" % [minor, w.get_id_path(Vector2i(2, 1), Vector2i(0, 1))])
	check_eq("P7 from == to returns the one cell", ids(w.get_id_path(Vector2i(0, 1), Vector2i(0, 1))), [Vector2i(0, 1)])
	check_eq("P8 target outside region: []", ids(w.get_id_path(Vector2i(0, 1), Vector2i(9, 9))), [])

	# --- 5. weights ------------------------------------------------------------
	var s := grid(Rect2i(0, 0, 3, 3))
	check_eq("W1 straight line with no weights", ids(s.get_id_path(Vector2i(0, 1), Vector2i(2, 1))), [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)])
	s.set_point_weight_scale(Vector2i(1, 1), 10.0)
	check_eq("W2 weight 10 on the middle cell: goes around it", ids(s.get_id_path(Vector2i(0, 1), Vector2i(2, 1))), [Vector2i(0, 1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, 1)])

	# --- 6. positions: corner, not centre; layer-local, not global -------------
	var sq_ts := TileSet.new()
	var sq := TileMapLayer.new()
	sq.tile_set = sq_ts
	sq.position = Vector2(100, 50)
	root.add_child(sq)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	sq_ts.add_source(src, 0)
	sq.set_cell(Vector2i(-3, -2), 0, Vector2i(0, 0))
	sq.set_cell(Vector2i(1, 1), 0, Vector2i(0, 0))
	var used := sq.get_used_rect()
	check_eq("C1 get_used_rect covers negative cells, size is exclusive", used, Rect2i(-3, -2, 5, 4))
	var c := AStarGrid2D.new()
	c.region = used
	c.cell_size = Vector2(16, 16)
	c.update()
	check_eq("C2 region = get_used_rect(): the far cell is in bounds", c.is_in_boundsv(Vector2i(1, 1)), true)
	check_eq("C3 negative cells get negative positions", c.get_point_position(Vector2i(-3, -2)), Vector2(-48, -32))
	check_eq("C4 without offset a point is the cell's top-left corner", c.get_point_position(Vector2i(1, 1)), Vector2(16, 16))
	check_eq("C5 ...while map_to_local is the centre", sq.map_to_local(Vector2i(1, 1)), Vector2(24, 24))
	c.offset = Vector2(8, 8)
	c.update()
	check_eq("C6 offset = cell_size / 2 makes them equal", c.get_point_position(Vector2i(1, 1)), sq.map_to_local(Vector2i(1, 1)))
	check_eq("C7 points are layer-local: layer at (100,50) puts the node elsewhere", sq.to_global(sq.map_to_local(Vector2i(1, 1))), Vector2(124, 74))
	check_eq("K1 control: map_to_local of (1,1) is not the corner", sq.map_to_local(Vector2i(1, 1)) == Vector2(16, 16), false)

	# --- 7. isometric: layout must match cell_shape ----------------------------
	var shapes := {
		"ISOMETRIC_RIGHT": AStarGrid2D.CELL_SHAPE_ISOMETRIC_RIGHT,
		"ISOMETRIC_DOWN": AStarGrid2D.CELL_SHAPE_ISOMETRIC_DOWN,
	}
	var layouts := {
		"STACKED": TileSet.TILE_LAYOUT_STACKED,
		"DIAMOND_RIGHT": TileSet.TILE_LAYOUT_DIAMOND_RIGHT,
		"DIAMOND_DOWN": TileSet.TILE_LAYOUT_DIAMOND_DOWN,
	}
	var want := {
		"STACKED": "",
		"DIAMOND_RIGHT": "ISOMETRIC_RIGHT",
		"DIAMOND_DOWN": "ISOMETRIC_DOWN",
	}
	var iso_default := TileSet.new()
	iso_default.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	check_eq("I1 an isometric TileSet is created with layout STACKED", iso_default.tile_layout, TileSet.TILE_LAYOUT_STACKED)
	for lname in layouts:
		var ts := TileSet.new()
		ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
		ts.tile_size = Vector2i(64, 32)
		ts.tile_layout = layouts[lname]
		var l := TileMapLayer.new()
		l.tile_set = ts
		var matched := ""
		for sname in shapes:
			for off in [Vector2.ZERO, Vector2(32, 16)]:
				var g := AStarGrid2D.new()
				g.region = Rect2i(-4, -4, 10, 10)
				g.cell_size = Vector2(64, 32)
				g.cell_shape = shapes[sname]
				g.offset = off
				g.update()
				var all := true
				for x in range(-3, 5):
					for y in range(-3, 5):
						if g.get_point_position(Vector2i(x, y)) != l.map_to_local(Vector2i(x, y)):
							all = false
				if all:
					matched += sname + ("" if off == Vector2.ZERO else "+offset")
		l.free()
		check_eq("I2 layout %s matches cell_shape %s (64 cells, offset 0)" % [lname, want[lname] if want[lname] != "" else "none"], matched, want[lname])

	sq.free()
	print("ASTAR GRID: " + ("ALL PASS" if failures == 0 else "%d FAIL" % failures))
	quit(1 if failures else 0)
