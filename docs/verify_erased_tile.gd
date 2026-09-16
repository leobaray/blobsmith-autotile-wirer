extends SceneTree
##
## Reproduces every claim in docs/why-the-erased-tile-still-collides.md against
## a real engine.
##
## Standalone: builds a 16x16 TileSet with two tiles — (0,0) with one full-square
## collision polygon, (1,0) with none — and a TileMapLayer with a floor row of
## eight solid tiles, cells (0,5)..(7,5), plus one solid tile at (20,5), which on
## 4.7 sits in the next 16x16 physics quadrant. The cell that gets erased is
## (3,5); its neighbours (2,5) and (4,5) must keep colliding. Needs no project
## assets. Run through verify_erased_tile.sh, which builds the empty project this
## script expects. Headless is fine: the physics server is real in a headless
## build.
##
## "Does the cell still collide" is asked four ways, always in this order:
## PhysicsDirectSpaceState2D.intersect_ray (a vertical ray through the cell
## centre), intersect_point (the cell centre, number of results), a RayCast2D's
## force_raycast_update(), and a CharacterBody2D move_and_collide() 40 px down
## into the cell from 30 px above. The body has collision_layer 0, so the queries
## can never hit it, and it is parked far away after every sweep.
##
## Every expected number was first printed by an exploratory pass on 4.3, 4.4 and
## 4.7, and only then written down. Where the engines differ the check is
## per-version (the description says so).
##
## Prints PASS/FAIL per check and a final "ERASED TILE:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
##   godot --headless --path <proj> --script verify_erased_tile.gd [-- --invert]
##   godot --headless --path <proj> --script verify_erased_tile.gd -- --probe=<name>
##
## --invert flips the expectation of S1 and U3 on purpose, so a run that cannot
## fail is visible. --probe runs one erase inside a physics callback and prints
## "ERASEPROBE DONE": the wrapper counts the engine's error lines for it (X3),
## which a script cannot read.

const C := Vector2i(3, 5)
const N2 := Vector2i(2, 5)
const N4 := Vector2i(4, 5)
const FAR := Vector2i(20, 5)
const SOLID := Vector2i(0, 0)
const EMPTY_TILE := Vector2i(1, 0)
const TRIALS := 20

var failures := 0
var checks := 0
var invert := false
var L: TileMapLayer
var rc: RayCast2D
var cb: CharacterBody2D
var ver := ""
var has_quadrant := false


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "S1" or id == "U3"):
		want = "deliberately wrong"
	var ok: bool = typeof(got) == typeof(want) and got == want
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))


func tileset() -> TileSet:
	var img := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(SOLID)
	src.create_tile(EMPTY_TILE)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_physics_layer()
	ts.add_source(src)
	var td := src.get_tile_data(SOLID, 0)
	td.add_collision_polygon(0)
	td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	return ts


# Frees the previous layer, builds a new one and lets physics settle.
func fresh() -> void:
	if L != null:
		L.queue_free()
		await physics_frame
	L = TileMapLayer.new()
	L.tile_set = tileset()
	root.add_child(L)
	for x in range(0, 8):
		L.set_cell(Vector2i(x, 5), 0, SOLID)
	L.set_cell(FAR, 0, SOLID)
	await physics_frame
	await physics_frame


func ray_hit(cell: Vector2i) -> Dictionary:
	var c := L.map_to_local(cell)
	var q := PhysicsRayQueryParameters2D.create(c + Vector2(0, -30), c + Vector2(0, 30))
	return root.world_2d.direct_space_state.intersect_ray(q)


func ray(cell: Vector2i) -> bool:
	return not ray_hit(cell).is_empty()


func point(cell: Vector2i) -> int:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = L.map_to_local(cell)
	return root.world_2d.direct_space_state.intersect_point(q).size()


func raycast(cell: Vector2i) -> bool:
	rc.global_position = L.map_to_local(cell) + Vector2(0, -30)
	rc.target_position = Vector2(0, 60)
	rc.force_raycast_update()
	return rc.is_colliding()


func sweep(cell: Vector2i) -> bool:
	cb.global_position = L.map_to_local(cell) + Vector2(0, -30)
	var hit := cb.move_and_collide(Vector2(0, 40)) != null
	cb.global_position = Vector2(-1000, -1000)
	return hit


# The three queries only — no sweep, which (see U4) changes what they see.
func queries(cell: Vector2i) -> Array:
	return [ray(cell), point(cell), raycast(cell)]


func all_four(cell: Vector2i) -> Array:
	return [ray(cell), point(cell), raycast(cell), sweep(cell)]


# Number of the 8 floor cells a ray hits.
func row_hits() -> int:
	var n := 0
	for x in 8:
		if ray(Vector2i(x, 5)):
			n += 1
	return n


# The floor as rays see it: C empty, the other 7 present.
func row_is_right() -> bool:
	return not ray(C) and row_hits() == 7


func probe(name: String) -> void:
	await fresh()
	var fired := [0]
	var act := func() -> void:
		if fired[0] > 0:
			return
		fired[0] += 1
		L.erase_cell(C)
		if name.ends_with("_upd"):
			L.update_internals()
		print("ERASEPROBE in-callback sweep C=%s N2=%s" % [sweep(C), sweep(N2)])
	if name.begins_with("area"):
		var a := Area2D.new()
		var acs := CollisionShape2D.new()
		var ash := RectangleShape2D.new()
		ash.size = Vector2(4, 4)
		acs.shape = ash
		a.add_child(acs)
		a.body_shape_entered.connect(func(_r: RID, _b: Node, _i: int, _j: int) -> void: act.call())
		a.position = L.map_to_local(C)
		root.add_child(a)
	else:
		physics_frame.connect(act)
	for i in 5:
		await physics_frame
	print("ERASEPROBE DONE fired=%d sweep_C=%s sweep_N2=%s row_right=%s" % [fired[0], sweep(C), sweep(N2), row_is_right()])
	quit(0)


func _initialize() -> void:
	var probe_name := ""
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
		elif a.begins_with("--probe="):
			probe_name = a.substr(8)
	var v := Engine.get_version_info()
	ver = "%d.%d" % [v.major, v.minor]

	rc = RayCast2D.new()
	rc.enabled = false
	root.add_child(rc)
	cb = CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(10, 12)
	cs.shape = sh
	cb.add_child(cs)
	cb.collision_layer = 0
	root.add_child(cb)
	await physics_frame

	if probe_name != "":
		await probe(probe_name)
		return

	await fresh()
	has_quadrant = "physics_quadrant_size" in L

	# ---- K: the four questions can tell a tile from no tile ---------------------
	check("K1", [all_four(C), all_four(N2)], [[true, 1, true, true], [true, 1, true, true]],
		"control: before any erase, ray, point, forced RayCast2D and move_and_collide all hit (3,5) and (2,5)")
	check("K2", all_four(Vector2i(10, 5)), [false, 0, false, false],
		"control: a cell never painted, (10,5), is a miss on all four")

	# ---- S: same frame, no update_internals -------------------------------------
	L.erase_cell(C)
	check("S1", [L.get_cell_source_id(C), queries(C)], [-1, [true, 1, true]],
		"right after erase_cell the cell reads -1, yet ray, point and RayCast2D still hit it")
	check("S2", sweep(C), true,
		"and move_and_collide into it in the same frame still collides")

	# ---- U: erase_cell + update_internals ---------------------------------------
	L.update_internals()
	var u_ray := [ray(N2), ray(N4), point(N2), raycast(N4), ray(FAR)]
	var u_c := all_four(C)
	check("U1", u_c, [false, 0, false, false],
		"after update_internals() on the same line, all four miss the erased cell")
	check("U2", [sweep(N2), sweep(N4), sweep(FAR)], [true, true, true],
		"move_and_collide still collides with the neighbours (2,5), (4,5) and the far tile (20,5)")
	print("NOTE %s after update_internals, before any sweep: ray N2, ray N4, point N2, RayCast2D N4, ray FAR = %s" % [ver, u_ray])
	if not has_quadrant:
		check("U3", u_ray, [true, true, 1, true, true],
			ver + ": ray, point and RayCast2D still hit the neighbours right after update_internals()")
	else:
		check("U3", u_ray, [false, false, 0, false, true],
			ver + ": right after update_internals() ray, point and RayCast2D MISS the neighbours (2,5), (4,5) too — the far tile (20,5) still hits")

	await fresh()
	L.erase_cell(C)
	L.update_internals()
	var before_move := row_hits()
	cb.test_move(Transform2D(0, Vector2(-1000, -1000)), Vector2(0, 1))
	check("U4", [before_move, row_hits()], [7 if not has_quadrant else 0, 7],
		ver + ": rays hit %d of the 8 floor cells after erase + update_internals, and 7 after one test_move() far away" % before_move)

	await fresh()
	var s3_before := queries(C)
	L.set_cell(C, 0, EMPTY_TILE)
	var s3_stale := queries(C) + [sweep(C)]
	L.update_internals()
	check("S3", [s3_before, s3_stale, all_four(C)], [[true, 1, true], [true, 1, true, true], [false, 0, false, false]],
		"set_cell to a tile with no collision behaves like erase_cell: still hits on the same frame, misses after update_internals()")

	await fresh()
	var nc := Vector2i(10, 5)
	L.set_cell(nc, 0, SOLID)
	var u7a := [ray(nc), sweep(nc)]
	L.update_internals()
	var u7b := [ray(nc), point(nc), raycast(nc), sweep(nc)]
	await physics_frame
	check("U5", [u7a, u7b, queries(nc)], [[false, false], [false, 0, false, true], [true, 1, true]],
		"a tile PLACED at (10,5): after update_internals() move_and_collide hits it but ray, point and RayCast2D do not until the next frame")

	# ---- R: body RIDs after the rebuild -----------------------------------------
	await fresh()
	var rids_before := {}
	var shapes_before := []
	for x in 8:
		var h := ray_hit(Vector2i(x, 5))
		rids_before[h.rid] = true
		shapes_before.append(h.shape)
	var old_c: RID = ray_hit(C).rid
	var old_n2: RID = ray_hit(N2).rid
	var old_far: RID = ray_hit(FAR).rid
	L.erase_cell(C)
	await physics_frame
	var rids_after := {}
	var shapes_after := []
	for x in 8:
		var h := ray_hit(Vector2i(x, 5))
		if h.is_empty():
			shapes_after.append(-1)
			continue
		rids_after[h.rid] = true
		shapes_after.append(h.shape)
	var new_n2: RID = ray_hit(N2).rid
	var new_far: RID = ray_hit(FAR).rid
	print("NOTE %s rids before %d after %d, shapes before %s after %s" % [ver, rids_before.size(), rids_after.size(), shapes_before, shapes_after])
	if not has_quadrant:
		check("R1", [has_quadrant, rids_before.size(), rids_after.size(), new_n2 == old_n2, new_far == old_far], [false, 8, 7, true, true],
			ver + ": no physics_quadrant_size; 8 floor tiles are 8 bodies, 7 after the erase, and the neighbour keeps its RID")
		check("R2", [shapes_before, shapes_after], [[0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, -1, 0, 0, 0, 0]],
			ver + ": every tile is shape 0 of its own body, before and after")
	else:
		check("R1", [L.get("physics_quadrant_size"), rids_before.size(), rids_after.size(), new_n2 == old_n2, new_far == old_far], [16, 1, 1, false, true],
			ver + ": physics_quadrant_size 16; the 8 floor tiles are ONE body, and the erase replaces it with a new RID — the far quadrant keeps its RID")
		check("R2", [shapes_before, shapes_after], [[0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, -1, 1, 1, 1, 1]],
			ver + ": the whole floor is shape 0 before; after, (0..2,5) is shape 0 and (4..7,5) shape 1")
	check("R3", [L.get_coords_for_body_rid(old_c), L.get_coords_for_body_rid(new_n2)], [Vector2i(0, 0), (Vector2i(0, 0) if has_quadrant else N2)],
		ver + ": get_coords_for_body_rid() on the erased tile's old RID returns (0,0) with an error; a live neighbour's returns %s" % [Vector2i(0, 0) if has_quadrant else N2])

	# ---- F: how many frames until rays see the erase -----------------------------------
	var upd_counts := {}
	for mode in ["process", "physics", "upd_process", "upd_physics"]:
		var counts := {}
		for t in TRIALS:
			await fresh()
			L.erase_cell(C)
			if mode.begins_with("upd"):
				L.update_internals()
			var k := 0
			while k < 10 and not row_is_right():
				if mode.ends_with("physics"):
					await physics_frame
				else:
					await process_frame
				k += 1
			counts[k] = counts.get(k, 0) + 1
		print("NOTE %s %s frames until rays see the floor right: %s" % [ver, mode, counts])
		if mode == "process":
			check("F1", counts, {1: TRIALS}, "without update_internals, rays see the erase after exactly 1 process_frame (20/20 trials)")
		elif mode == "physics":
			check("F2", counts, {1: TRIALS}, "... and after exactly 1 physics_frame (20/20 trials)")
		else:
			upd_counts[mode] = counts
	if not has_quadrant:
		check("F3", [upd_counts.upd_process, upd_counts.upd_physics], [{0: TRIALS}, {0: TRIALS}],
			ver + ": with update_internals, 0 frames: rays see the floor right on the same line (20/20, process and physics)")
	else:
		check("F3", [upd_counts.upd_process, upd_counts.upd_physics], [{1: TRIALS}, {1: TRIALS}],
			ver + ": with update_internals, still exactly 1 process_frame, or 1 physics_frame, before rays see the neighbours (20/20 each)")

	await fresh()
	var deferred := [-1, false]
	L.erase_cell(C)
	(func() -> void: deferred[0] = row_hits(); deferred[1] = ray(C)).call_deferred()
	await process_frame
	check("F4", deferred, ([0, false] if has_quadrant else [7, false]),
		ver + ": a call_deferred() query after erase_cell (it runs after the layer's own deferred update) — rays hit %d of 8 floor cells" % (0 if has_quadrant else 7))

	# An auto-updating RayCast2D and an erase made while physics_frame is emitted.
	for with_upd in [false, true]:
		await fresh()
		var auto := RayCast2D.new()
		auto.target_position = Vector2(0, 60)
		auto.global_position = L.map_to_local(C) + Vector2(0, -30)
		var auto_n := RayCast2D.new()
		auto_n.target_position = Vector2(0, 60)
		auto_n.global_position = L.map_to_local(N2) + Vector2(0, -30)
		root.add_child(auto)
		root.add_child(auto_n)
		await physics_frame
		await physics_frame
		L.erase_cell(C)
		if with_upd:
			L.update_internals()
		var seq_c := []
		var seq_n := []
		for i in 3:
			await physics_frame
			seq_c.append(auto.is_colliding())
			seq_n.append(auto_n.is_colliding())
		auto.queue_free()
		auto_n.queue_free()
		print("NOTE %s auto RayCast2D, update_internals=%s: over C %s, over N2 %s" % [ver, with_upd, seq_c, seq_n])
		if not with_upd:
			check("F5", [seq_c, seq_n], [[true, false, false], [true, true, true]],
				"an enabled RayCast2D, erase made from physics_frame: is_colliding() is still true on the next physics frame, false on the one after")
		elif not has_quadrant:
			check("F6", [seq_c, seq_n], [[false, false, false], [true, true, true]],
				ver + ": with update_internals() it is false on the very next physics frame, and the neighbour's stays true")
		else:
			check("F6", [seq_c, seq_n], [[false, false, false], [false, true, true]],
				ver + ": with update_internals() it is false on the next frame — but the RayCast2D over the NEIGHBOUR (2,5) also reports false for one frame")

	# ---- C: erase inside a body_shape_entered callback ---------------------------
	await fresh()
	var fired := [0, [], false]
	var a := Area2D.new()
	var acs := CollisionShape2D.new()
	var ash := RectangleShape2D.new()
	ash.size = Vector2(4, 4)
	acs.shape = ash
	a.add_child(acs)
	a.body_shape_entered.connect(func(_r: RID, _b: Node, _i: int, _j: int) -> void:
		if fired[0] > 0:
			return
		fired[0] += 1
		L.erase_cell(C)
		L.update_internals()
		fired[1] = [L.get_cell_source_id(C), sweep(C), sweep(N2)])
	a.position = L.map_to_local(C)
	root.add_child(a)
	for i in 5:
		await physics_frame
	fired[2] = row_is_right() and not sweep(C) and sweep(N2)
	a.queue_free()
	check("C1", fired, [1, [-1, false, true], true],
		"erase_cell + update_internals inside Area2D.body_shape_entered works: the sweep misses (3,5), hits (2,5), and 5 frames later the floor is right")

	# ---- M: many erases, one update ----------------------------------------------
	await fresh()
	for x in 8:
		L.erase_cell(Vector2i(x, 5))
	L.update_internals()
	var m_sweeps := 0
	for x in 8:
		if sweep(Vector2i(x, 5)):
			m_sweeps += 1
	check("M1", [m_sweeps, sweep(FAR)], [0, true],
		"erasing all 8 floor cells then ONE update_internals(): 0 of 8 sweeps collide, the far tile still does")

	L.queue_free()
	if failures == 0:
		print("ERASED TILE: ALL PASS (%d checks)" % checks)
	else:
		print("ERASED TILE: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
