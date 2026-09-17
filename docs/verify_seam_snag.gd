extends SceneTree
##
## Reproduces every claim in docs/why-bodies-catch-on-tile-seams.md against a
## real engine.
##
## Standalone: builds a 16x16 TileSet with one physics layer and two tiles,
## (0,0) and (1,0), each one full-square collision polygon. A TileMapLayer gets
## a floor row (-2,10)..(59,10) (top edge y = 160) and, for the character
## checks, a ceiling row (-2,4)..(59,4) (bottom edge y = 80) and a wall column
## (-6,12)..(-6,59) (right face x = -80). The control is one StaticBody2D with
## one 1000x16 rectangle whose top edge is also y = 160. Needs no project
## assets. Run through verify_seam_snag.sh, which builds the empty project this
## script expects and runs it with --fixed-fps 60, so every run is the same
## sequence of 1/60 s physics steps.
##
## The box is a RigidBody2D with a 14x14 rectangle and lock_rotation on, placed
## at y = 153 and left 20 frames to settle; then every frame
## "linear_velocity.x = v; await physics_frame" for 240 frames. The ball is the
## same with a radius-7 circle and rotation free. A frame "stalls" when the body
## moved less than half of v/60 px that frame. A "bounce" is a frame whose
## linear_velocity.y points up faster than 1 px/s.
##
## Every expected value was first printed by an exploratory pass on 4.3, 4.4
## and 4.7, and only then written down. Where the engines differ the check is
## per-version (the description says so).
##
## Prints PASS/FAIL per check and a final "SEAM SNAG:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
##   godot --headless --fixed-fps 60 --path <proj> --script verify_seam_snag.gd [-- --invert]
##
## --invert flips the expectation of B1 and K1 on purpose, so a run that cannot
## fail is visible.

const FLOOR_ROW := 10
const X0 := -2
const X1 := 60           # exclusive: 62 floor cells, x = -32 .. 960

var failures := 0
var checks := 0
var invert := false
var L: TileMapLayer
var SB: StaticBody2D
var ver := ""
var minor := 0


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "B1" or id == "K1"):
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
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_physics_layer()
	ts.add_source(src)
	var sq := PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)])
	for a in [Vector2i(0, 0), Vector2i(1, 0)]:
		src.create_tile(a)
		var td := src.get_tile_data(a, 0)
		td.add_collision_polygon(0)
		td.set_collision_polygon_points(0, 0, sq)
	return ts


# q = 0 keeps the default physics_quadrant_size (and is the only value on
# 4.3/4.4, which do not have the property). two_tiles alternates (0,0)/(1,0).
func level(q := 0, two_tiles := false, room := false) -> void:
	await clear()
	L = TileMapLayer.new()
	L.tile_set = tileset()
	if q > 0:
		L.set("physics_quadrant_size", q)
	root.add_child(L)
	for x in range(X0, X1):
		L.set_cell(Vector2i(x, FLOOR_ROW), 0, Vector2i(x & 1 if two_tiles else 0, 0))
		if room:
			L.set_cell(Vector2i(x, 4), 0, Vector2i(0, 0))
	if room:
		for y in range(12, 60):
			L.set_cell(Vector2i(-6, y), 0, Vector2i(0, 0))
	await physics_frame
	await physics_frame


func control() -> void:
	await clear()
	SB = StaticBody2D.new()
	var cs := CollisionShape2D.new()
	var r := RectangleShape2D.new()
	r.size = Vector2(1000, 16)
	cs.shape = r
	cs.position = Vector2(468, 168)
	SB.add_child(cs)
	root.add_child(SB)
	await physics_frame
	await physics_frame


func clear() -> void:
	if L != null:
		L.queue_free()
		L = null
	if SB != null:
		SB.queue_free()
		SB = null
	await physics_frame


# Distinct physics bodies found under the 62 floor cells.
func bodies_under_floor() -> int:
	var rids := {}
	var space := root.get_world_2d().direct_space_state
	var q := PhysicsPointQueryParameters2D.new()
	for x in range(X0, X1):
		q.position = Vector2(x * 16 + 8, FLOOR_ROW * 16 + 8)
		for h in space.intersect_point(q, 4):
			rids[h.rid] = true
	return rids.size()


# Returns {x: final x in tenths of a px (int, so 421.9 is 4219), stalls: frames, bounces: [[x, up px/s] ...]}.
func push(ball: bool, x: float, v := 120.0, friction := -1.0) -> Dictionary:
	var rb := RigidBody2D.new()
	var cs := CollisionShape2D.new()
	if ball:
		var c := CircleShape2D.new()
		c.radius = 7
		cs.shape = c
	else:
		var r := RectangleShape2D.new()
		r.size = Vector2(14, 14)
		cs.shape = r
		rb.lock_rotation = true
	if friction >= 0.0:
		rb.physics_material_override = PhysicsMaterial.new()
		rb.physics_material_override.friction = friction
	rb.add_child(cs)
	root.add_child(rb)
	rb.global_position = Vector2(x, 153)
	for i in 20:
		await physics_frame
	var stalls := 0
	var bounces := []
	for i in 240:
		var x_before := rb.global_position.x
		rb.linear_velocity.x = v
		await physics_frame
		if rb.global_position.x - x_before < v / 120.0:
			stalls += 1
		if -rb.linear_velocity.y > 1.0:
			bounces.append([snappedf(rb.global_position.x, 0.1), snappedf(-rb.linear_velocity.y, 0.1)])
	var out := {"x": roundi(rb.global_position.x * 10.0), "stalls": stalls, "bounces": bounces}
	rb.queue_free()
	return out


# A CharacterBody2D, 12x14 rectangle or radius-6 capsule, every property at
# its default except motion_mode. Returns the number of frames it moved less
# than half its speed.
func walk(pos: Vector2, vel: Vector2, grav: float, capsule := false, floating := false) -> int:
	var cb := CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	if capsule:
		var c := CapsuleShape2D.new()
		c.radius = 6
		c.height = 14
		cs.shape = c
	else:
		var r := RectangleShape2D.new()
		r.size = Vector2(12, 14)
		cs.shape = r
	cb.add_child(cs)
	if floating:
		cb.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	root.add_child(cb)
	cb.global_position = pos
	for i in 20:
		await physics_frame
		cb.velocity = Vector2(0, cb.velocity.y + grav / 60.0)
		cb.move_and_slide()
	var stalls := 0
	for i in 180:
		await physics_frame
		var p := cb.global_position
		cb.velocity = Vector2(vel.x, vel.y if grav == 0.0 else cb.velocity.y + grav / 60.0)
		cb.move_and_slide()
		var d := cb.global_position - p
		if abs(d.x) + abs(d.y) < vel.length() / 120.0:
			stalls += 1
	cb.queue_free()
	return stalls


func near_borders(bounces: Array, borders: Array) -> bool:
	for b in bounces:
		var ok := false
		for edge in borders:
			if abs(b[0] - edge) <= 4.0:
				ok = true
		if not ok:
			return false
	return true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
	var v := Engine.get_version_info()
	ver = "%d.%d" % [v.major, v.minor]
	minor = v.minor
	if v.major != 4 or minor < 3:
		print("SEAM SNAG: needs Godot 4.3+ (TileMapLayer)")
		quit(3)
		return

	# --- control: one flat shape --------------------------------------------
	await control()
	var c_box := await push(false, 8.0)
	var c_box2 := await push(false, 240.0)
	var c_ball := await push(true, 8.0)
	check("K1", [c_box.x, c_box.stalls, c_box2.x, c_box2.stalls], [4219, 0, 6539, 0],
		"control, one StaticBody2D rectangle: the box pushed at 120 px/s from x=8 ends at 421.9 and from x=240 at 653.9, 0 stalled frames")
	check("K2", c_ball.bounces.size(), 0,
		"control: the ball rolled at 120 px/s never moves up")

	# --- the default layer --------------------------------------------------
	await level()
	var per_cell := minor < 5
	check("S1", bodies_under_floor(), 62 if per_cell else 5,
		ver + (": 62 floor cells are 62 physics bodies" if per_cell else ": 62 floor cells are 5 physics bodies (16-cell chunks: -1, 0, 1, 2, 3)"))
	var box := await push(false, 8.0)
	var box2 := await push(false, 17.7)
	var box3 := await push(false, 240.0)
	if per_cell:
		check("B1", [box.x, box2.x, box3.x], [252, 1212, 3452],
			ver + ": the box stops for good with its leading edge 0.2 px past a seam — from x=8 at 25.2 (seam 32), from 17.7 at 121.2 (seam 128), from 240 at 345.2 (seam 352)")
		check("B2", box.stalls >= 200 and box2.stalls >= 150 and box3.stalls >= 150, true,
			ver + ": and stays there (230, 180, 179 of 240 frames stalled)")
	else:
		check("B1", [box.x, box2.x, box3.x], [4219, 4316, 6539],
			ver + ": the box ends where it does on the control (421.9, 431.6, 653.9), crossing the chunk border at x=256 from 240")
		check("B2", box.stalls + box2.stalls + box3.stalls, 0,
			ver + ": 0 stalled frames")
	var ball := await push(true, 8.0)
	if per_cell:
		check("R1", ball.bounces.size() > 0 and ball.bounces[0][0] < 20.0 and ball.bounces[0][1] > 10.0, true,
			ver + ": the ball never stops but is kicked upward at the seams, the first at x=16.9 (seam 16) at 16.3 px/s")
	else:
		check("R1", ball.bounces.size() > 0 and near_borders(ball.bounces, [256.0, 512.0]), true,
			ver + ": the ball is still kicked upward, but only within 4 px of a chunk border (x=256: 23.9 px/s), not at the seams inside a chunk")
	var slick := await push(false, 8.0, 120.0, 0.0)
	if per_cell:
		check("F1", slick.x > 4000 and slick.stalls < 30, true,
			ver + ": friction 0 on the box gets it most of the way (457.3, 15 stalled frames) — not all of it")
	else:
		check("F1", [slick.x, slick.stalls], [4872, 0],
			ver + ": friction 0 on the box: 487.2, 0 stalled frames")

	# --- 4.5+: the quadrant size is the switch ------------------------------
	if not per_cell:
		await level(1)
		check("Q1", bodies_under_floor(), 62,
			ver + ": physics_quadrant_size = 1 is one body per cell again")
		var q1 := await push(false, 8.0)
		check("Q2", q1.x, 252,
			ver + ": and the box stops at 25.2 again, exactly as on 4.3/4.4")
		await level(64)
		check("Q3", bodies_under_floor(), 2,
			ver + ": physics_quadrant_size = 64 covers the whole row in 2 bodies (cells -2..-1 are chunk -1)")
		var q64 := await push(true, 8.0)
		check("Q4", q64.bounces.size(), 0,
			ver + ": and the ball never moves up — same as the control")
		await level(0, true)
		var mixed_ball := await push(true, 8.0)
		check("Q5", [bodies_under_floor(), mixed_ball.bounces.size() > 0 and near_borders(mixed_ball.bounces, [256.0, 512.0])], [5, true],
			ver + ": alternating two different tiles along the floor still gives 5 bodies and bounces only at chunk borders — merging is by shape, not by tile")

	# --- CharacterBody2D + move_and_slide ------------------------------------
	await level(0, false, true)
	var w_floor := await walk(Vector2(8, 152), Vector2(200, 0), 980.0)
	var w_cap := await walk(Vector2(8, 152), Vector2(200, 0), 980.0, true)
	var w_ceil := await walk(Vector2(8, 87), Vector2(200, 0), 0.0)
	var w_wall := await walk(Vector2(-74, 200), Vector2(-50, 200), 0.0, false, true)
	check("C1", [w_floor, w_cap, w_ceil, w_wall], [0, 0, 0, 0],
		ver + ": a CharacterBody2D never stalls across seams: walking the floor at 200 px/s (rectangle and capsule), flush under the ceiling with velocity.y = 0, and floating along a wall while pushing into it")

	await clear()
	print("---")
	if failures == 0:
		print("SEAM SNAG: ALL PASS (%d checks)" % checks)
		quit(0)
	else:
		print("SEAM SNAG: %d FAIL of %d checks" % [failures, checks])
		quit(1)
