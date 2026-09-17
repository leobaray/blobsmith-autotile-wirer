extends SceneTree
##
## Reproduces every claim in docs/why-you-cannot-drop-through-the-one-way-tile.md
## against a real engine.
##
## Standalone: builds a 16x16 TileSet with two physics layers — layer 0 on
## collision bit 1, layer 1 on collision bit 2 — and three tiles, each one
## full-square collision polygon: (0,0) solid on layer 0, (1,0) one-way on
## layer 0, (2,0) one-way on layer 1. A TileMapLayer gets a platform row
## (0,5)..(9,5) (top edge y = 80) and a solid ground row (0,10)..(9,10) (top
## edge y = 160). Needs no project assets. Run through verify_one_way_drop.sh,
## which builds the empty project this script expects. Headless is fine: the
## physics server is real in a headless build.
##
## The player is a CharacterBody2D with a 12x14 rectangle (so it rests at
## y = 73 on the platform and y = 153 on the ground), collision_layer 0,
## collision_mask 3, all other properties default. Every frame of a run is
## "await physics_frame; velocity.y += 980/60; move_and_slide()" at the default
## 60 physics ticks. Positions are read as places (on platform, in ground, …),
## not as floats.
##
## Every expected value was first printed by an exploratory pass on 4.3, 4.4
## and 4.7, and only then written down. Where the engines differ the check is
## per-version (the description says so).
##
## Prints PASS/FAIL per check and a final "ONE WAY DROP:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
##   godot --headless --path <proj> --script verify_one_way_drop.gd [-- --invert]
##
## --invert flips the expectation of D2 and M1 on purpose, so a run that cannot
## fail is visible.

const SOLID := Vector2i(0, 0)
const ONE_WAY := Vector2i(1, 0)
const ONE_WAY_BIT2 := Vector2i(2, 0)
const G := 980.0

var failures := 0
var checks := 0
var invert := false
var L: TileMapLayer
var cb: CharacterBody2D
var ver := ""
var minor := 0


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "D2" or id == "M1"):
		want = "deliberately wrong"
	var ok: bool = typeof(got) == typeof(want) and got == want
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))


func tileset(margin: float) -> TileSet:
	var img := Image.create(48, 16, false, Image.FORMAT_RGBA8)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_physics_layer()
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_layer(1, 2)
	ts.add_source(src)
	var sq := PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)])
	for t in [SOLID, ONE_WAY, ONE_WAY_BIT2]:
		src.create_tile(t)
		var pl := 1 if t == ONE_WAY_BIT2 else 0
		var td := src.get_tile_data(t, 0)
		td.add_collision_polygon(pl)
		td.set_collision_polygon_points(pl, 0, sq)
		if t != SOLID:
			td.set_collision_polygon_one_way(pl, 0, true)
			td.set_collision_polygon_one_way_margin(pl, 0, margin)
	return ts


# Frees the previous layer, builds a new one and lets physics settle.
func fresh(plat: Vector2i, alt := 0, margin := 1.0) -> void:
	if L != null:
		L.queue_free()
		await physics_frame
	L = TileMapLayer.new()
	L.tile_set = tileset(margin)
	root.add_child(L)
	for x in 10:
		L.set_cell(Vector2i(x, 5), 0, plat, alt)
		L.set_cell(Vector2i(x, 10), 0, SOLID)
	await physics_frame
	await physics_frame


func put(pos: Vector2, vy := 0.0) -> void:
	cb.collision_mask = 3
	cb.floor_snap_length = 1.0
	cb.velocity = Vector2(0, vy)
	cb.global_position = pos


# n frames of gravity + move_and_slide.
func run(n: int, grav := true) -> void:
	for i in n:
		await physics_frame
		if grav:
			cb.velocity.y += G / 60.0
		cb.move_and_slide()


# Stands the body on the platform (or the ground) and lets it settle.
func stand(on_ground := false, x := 72.0) -> void:
	put(Vector2(x, 140.0 if on_ground else 60.0))
	await run(30)


func where() -> String:
	var y := cb.global_position.y
	if y < 72.5:
		return "above platform"
	if y < 73.5:
		return "on platform"
	if y < 103.0:
		return "in platform"
	if y < 152.5:
		return "between"
	if y < 153.5:
		return "on ground"
	if y < 183.0:
		return "in ground"
	return "below ground"


func nudge(k: float, snap: float, frames := 40, grav := true) -> String:
	await stand()
	cb.floor_snap_length = snap
	cb.global_position.y += k
	await run(frames, grav)
	return where()


func mask_drop(bit: int, n: int, on_ground := false) -> Array:
	await stand(on_ground)
	cb.set_collision_mask_value(bit, false)
	await run(n)
	var mid := where()
	cb.set_collision_mask_value(bit, true)
	await run(40)
	return [mid, where()]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
	var v := Engine.get_version_info()
	ver = "%d.%d" % [v.major, v.minor]
	minor = v.minor

	cb = CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var sh := RectangleShape2D.new()
	sh.size = Vector2(12, 14)
	cs.shape = sh
	cb.add_child(cs)
	cb.collision_layer = 0
	root.add_child(cb)
	await physics_frame

	# ---- K / D: standing on it and pressing down ------------------------------
	await fresh(ONE_WAY)
	await stand()
	check("K1", [where(), cb.is_on_floor()], ["on platform", true],
		"control: dropped from y = 60 the body settles on the one-way platform, is_on_floor() true")

	for i in 30:
		await physics_frame
		cb.velocity = Vector2(0, 2000)
		cb.move_and_slide()
	check("D1", [where(), cb.is_on_floor()], ["on platform", true],
		"velocity.y = 2000 (33 px a frame) + move_and_slide for 30 frames: still on the platform, is_on_floor() true")

	var d2 := []
	for snap in [0.0, 1.0, 32.0]:
		d2.append([await nudge(0.9, snap), await nudge(1.0, snap)])
	check("D2", d2, [["on platform", "on ground"], ["on platform", "on ground"], ["on platform", "on ground"]],
		"position.y += 0.9 then gravity: back on the platform; += 1.0: falls to the ground — the same with floor_snap_length 0, 1 (default) and 32")

	var d4 := [await nudge(1.0, 1.0, 5, false), cb.is_on_floor()]
	check("D4", d4, ["in platform", false],
		"position.y += 1.0 with velocity 0 and no gravity: 5 frames later it is still inside the platform, not pushed out, is_on_floor() false")

	await fresh(ONE_WAY, 0, 4.0)
	check("D3", [await nudge(3.9, 1.0), await nudge(4.0, 1.0)], ["on platform", "on ground"],
		"one_way_margin = 4: position.y += 3.9 comes back onto the platform, += 4.0 falls through")

	# ---- M: clearing the collision_mask bit for N frames ----------------------
	await fresh(ONE_WAY)
	var m1 := []
	for n in [1, 2, 3]:
		m1.append(await mask_drop(1, n))
	check("M1", m1, [["on platform", "on platform"], ["in platform", "on platform"], ["in platform", "on ground"]],
		"from standing, mask bit cleared for 1 or 2 physics frames then restored (0.27 and 0.81 px sunk in): back on the platform; for 3 frames (1.63 px in): falls to the ground")
	check("M3", m1[2][0], "in platform",
		"restored after 3 frames the body is still inside the platform, and it is not pushed back up — it falls on (M1)")

	await fresh(ONE_WAY, 0, 4.0)
	check("M2", [await mask_drop(1, 4), await mask_drop(1, 5)], [["in platform", "on platform"], ["in platform", "on ground"]],
		"one_way_margin = 4: 4 frames is not enough (back on the platform), 5 frames drops")

	# ---- L: platforms on their own physics layer ------------------------------
	await fresh(ONE_WAY_BIT2)
	var l1 := [await mask_drop(2, 3), await mask_drop(1, 3), (await mask_drop(2, 30, true))[1], cb.is_on_floor()]
	check("L1", l1, [["in platform", "on ground"], ["on platform", "on platform"], "on ground", true],
		"platforms on physics layer bit 2: clearing bit 2 for 3 frames drops through; clearing bit 1 does not; standing on the ground with bit 2 cleared for 30 frames stays on the ground")

	await fresh(ONE_WAY)
	var l2 := [await mask_drop(1, 3, true), await mask_drop(1, 20, true)]
	check("L2", l2, [["in ground", "on ground"], ["below ground", "below ground"]],
		"one shared layer, standing on the SOLID ground: bit cleared 3 frames, the ground pushes it back up; 20 frames, it falls through the ground")
	var l3 := await mask_drop(1, 10, true)
	if minor < 7:
		check("L3", [l3, cb.is_on_floor()], [["in ground", "in ground"], false],
			ver + ": 10 frames on the solid ground, then restored: the body stays stuck inside the ground, is_on_floor() false")
	else:
		check("L3", [l3, cb.is_on_floor()], [["in ground", "on ground"], true],
			ver + ": 10 frames on the solid ground, then restored: pushed back up onto the ground")

	# ---- E: collision exceptions ----------------------------------------------
	await fresh(ONE_WAY)
	await stand()
	cb.add_collision_exception_with(L)
	await run(30)
	check("E1", [where(), cb.get_collision_exceptions().size()], ["on platform", 0],
		"add_collision_exception_with(the TileMapLayer): no exception is added (the list stays empty) and the body stays on the platform")

	await stand()
	var prid := cb.get_last_slide_collision().get_collider_rid()
	PhysicsServer2D.body_add_collision_exception(cb.get_rid(), prid)
	await run(40)
	check("E2", [where(), cb.is_on_floor()], ["on ground", true],
		"PhysicsServer2D.body_add_collision_exception with the platform's collider RID: the body drops and lands on the ground, which still collides")
	PhysicsServer2D.body_remove_collision_exception(cb.get_rid(), prid)

	# A body straddling (3,5) and (4,5), and one more platform tile in the next 16x16 chunk.
	L.set_cell(Vector2i(20, 5), 0, ONE_WAY)
	await physics_frame
	await stand(false, 64.0)
	var srid := cb.get_last_slide_collision().get_collider_rid()
	var scell := L.get_coords_for_body_rid(srid)
	PhysicsServer2D.body_add_collision_exception(cb.get_rid(), srid)
	await run(40)
	var straddle := where()
	await stand(false, 20 * 16 + 8.0)
	var far := where()
	PhysicsServer2D.body_remove_collision_exception(cb.get_rid(), srid)
	print("NOTE %s straddling body's collider RID -> get_coords_for_body_rid %s" % [ver, scell])
	if minor < 7:
		check("E3", [scell, straddle, far], [Vector2i(3, 5), "on platform", "on platform"],
			ver + ": that RID is one cell's body, (3,5); excepting it the body stays on (4,5); the far tile collides")
	else:
		check("E3", [scell, straddle, far], [Vector2i(0, 0), "on ground", "on platform"],
			ver + ": that RID is the 16x16 chunk (0,0); excepting it drops the body through BOTH tiles; the platform in the next chunk (20,5) still collides")

	# ---- T: transforms ---------------------------------------------------------
	var t1 := []
	for alt in [TileSetAtlasSource.TRANSFORM_FLIP_V, TileSetAtlasSource.TRANSFORM_FLIP_H, TileSetAtlasSource.TRANSFORM_TRANSPOSE]:
		await fresh(ONE_WAY, alt)
		await stand()
		var above := [where(), cb.is_on_floor()]
		put(Vector2(72, 120), -600.0)
		await run(20)
		t1.append([above, cb.global_position.y < 60.0])
	check("T1", t1, [[["on platform", true], true], [["on platform", true], true], [["on platform", true], true]],
		"flip_v, flip_h and transpose alternatives: each still blocks from above and lets a body at -600 px/s through from below")

	await fresh(ONE_WAY)
	L.rotation = PI
	await physics_frame
	await physics_frame
	var c := L.to_global(L.map_to_local(Vector2i(4, 5)))   # (-72, -88): platform spans y -96..-80
	put(c + Vector2(0, -40))
	await run(30)
	var fell := cb.global_position.y > -60.0
	put(c + Vector2(0, 40), -600.0)
	var highest := 999.0
	for i in 20:
		await run(1)
		highest = min(highest, cb.global_position.y)
	check("T2", [fell, highest > -73.5 and highest < -72.5], [true, true],
		"TileMapLayer node rotated 180 degrees: a body falling onto the platform passes through, a body jumping up at -600 px/s is stopped under it (highest y = -73)")
	L.rotation = 0.0

	# ---- J: jumping up through ------------------------------------------------
	for plat in [ONE_WAY, SOLID]:
		await fresh(plat)
		await stand(true)
		cb.velocity.y = -500
		var ceil := false
		var top := 999.0
		for i in 60:
			await physics_frame
			cb.velocity.y += G / 60.0
			cb.move_and_slide()
			ceil = ceil or cb.is_on_ceiling()
			top = min(top, cb.global_position.y)
		if plat == ONE_WAY:
			check("J1", [ceil, top < 66.0, where(), cb.is_on_floor()], [false, true, "on platform", true],
				"jump at -500 px/s from the ground: rises past the platform (top y < 66), is_on_ceiling() never true, lands on the platform")
		else:
			check("J2", [ceil, where()], [true, "on ground"],
				"control: the same jump under a solid (not one-way) row hits the ceiling and comes back to the ground")

	L.queue_free()
	if failures == 0:
		print("ONE WAY DROP: ALL PASS (%d checks)" % checks)
	else:
		print("ONE WAY DROP: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
