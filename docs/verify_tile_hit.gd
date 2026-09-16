extends SceneTree
##
## Reproduces every claim in docs/why-the-tile-you-hit-is-the-wrong-one.md
## against a real engine.
##
## Standalone: builds a 16x16 TileSet with one full-square collision polygon, a
## TileMapLayer and a CharacterBody2D in memory, needs no project assets. Run
## through verify_tile_hit.sh, which builds the empty project this script
## expects. Headless is fine: the physics server is real in a headless build.
##
## The sweep: one isolated tile at cell (20,20). A body starts 30 px away and
## move_and_collide()s 40 px toward the tile's centre from 8 directions (above,
## below, left, right and the four diagonals), shifted sideways from -10 to +10 px
## in steps of 2 — 11 approaches per direction, 88 per body shape, run with a
## 10x12 RectangleShape2D and with a radius-5, height-14 CapsuleShape2D. The tile
## is isolated on purpose: whatever the body hit, it hit (20,20), so every answer
## can be scored right or wrong.
##
## Every expected number was first printed by an exploratory pass on 4.3, 4.4 and
## 4.7, and only then written down. Where the engines differ the check is
## per-version (the ids say so).
##
## Prints PASS/FAIL per check and a final "TILE HIT:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
##   godot --headless --path <proj> --script verify_tile_hit.gd [-- --invert]
##
## --invert flips the expectation of N1 and R2 on purpose, so a run that cannot
## fail is visible.

const TARGET := Vector2i(20, 20)
const EPS := 0.5

var failures := 0
var checks := 0
var invert := false


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "N1" or id == "R2"):
		want = "deliberately wrong"
	var ok: bool = typeof(got) == typeof(want) and got == want
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))


func tileset() -> TileSet:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_physics_layer()
	ts.add_source(src)
	var td := src.get_tile_data(Vector2i(0, 0), 0)
	td.add_collision_polygon(0)
	td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	return ts


# quadrant 0 = leave the layer at its default.
func layer(quadrant: int) -> TileMapLayer:
	var L := TileMapLayer.new()
	L.tile_set = tileset()
	if quadrant > 0:
		L.set("physics_quadrant_size", quadrant)
	root.add_child(L)
	return L


func body(kind: String, feet_origin := false) -> CharacterBody2D:
	var b := CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	if kind == "rect":
		var sh := RectangleShape2D.new()
		sh.size = Vector2(10, 12)
		cs.shape = sh
	else:
		var sh := CapsuleShape2D.new()
		sh.radius = 5
		sh.height = 14
		cs.shape = sh
	if feet_origin:
		cs.position = Vector2(0, -6)
	b.add_child(cs)
	root.add_child(b)
	return b


func cell_at(L: TileMapLayer, p: Vector2) -> Vector2i:
	return L.local_to_map(L.to_local(p))


# The pattern the page recommends: step EPS into the surface along the normal;
# if that cell is empty the point was a tile corner, so try EPS either way along
# each axis and take the first cell that holds a tile.
func hit_cell(L: TileMapLayer, col: KinematicCollision2D) -> Vector2i:
	var p := col.get_position() - col.get_normal() * EPS
	for o in [Vector2.ZERO, Vector2(-EPS, 0), Vector2(EPS, 0), Vector2(0, -EPS), Vector2(0, EPS)]:
		var c := cell_at(L, p + o)
		if L.get_cell_source_id(c) != -1:
			return c
	return cell_at(L, p)


const DIRS := {
	"above": Vector2(0, 1), "below": Vector2(0, -1), "left": Vector2(1, 0), "right": Vector2(-1, 0),
	"above-left": Vector2(1, 1), "above-right": Vector2(-1, 1), "below-left": Vector2(1, -1), "below-right": Vector2(-1, -1),
}


# Returns a Dictionary of counts over the 88 approaches of one body shape.
func sweep(L: TileMapLayer, kind: String) -> Dictionary:
	var r := {"hits": 0, "collider_is_layer": 0, "naive": 0, "naive_miss_empty": 0, "normal": 0,
		"normal_miss_on_corner": 0, "pattern": 0, "rid_cell": 0, "rid_11": 0,
		"naive_below": 0, "naive_right": 0}
	var b := body(kind)
	var c := L.map_to_local(TARGET)
	for dn in DIRS:
		var d: Vector2 = (DIRS[dn] as Vector2).normalized()
		var side := Vector2(-d.y, d.x)
		for off in range(-10, 11, 2):
			b.global_position = L.to_global(c) - d * 30 + side * off
			var col := b.move_and_collide(d * 40)
			if col == null:
				continue
			r.hits += 1
			if col.get_collider() == L:
				r.collider_is_layer += 1
			var naive := cell_at(L, col.get_position())
			if naive == TARGET:
				r.naive += 1
				if dn == "below": r.naive_below += 1
				if dn == "right": r.naive_right += 1
			elif L.get_cell_source_id(naive) == -1:
				r.naive_miss_empty += 1
			if cell_at(L, col.get_position() - col.get_normal() * EPS) == TARGET:
				r.normal += 1
			else:
				var p := col.get_position()
				if fmod(p.x, 16.0) == 0.0 and fmod(p.y, 16.0) == 0.0:
					r.normal_miss_on_corner += 1
			if hit_cell(L, col) == TARGET:
				r.pattern += 1
			var rc := L.get_coords_for_body_rid(col.get_collider_rid())
			if rc == TARGET:
				r.rid_cell += 1
			if rc == Vector2i(1, 1):
				r.rid_11 += 1
	b.queue_free()
	return r


# Three isolated tiles: (20,20) and (23,20) share the 16x16 chunk (1,1); (40,20)
# is in chunk (2,1). One drop onto each from above.
func three_tiles(L: TileMapLayer) -> Array:
	var cells := [Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)]
	var b := body("rect", true)
	var out := []
	for cc in cells:
		b.global_position = L.to_global(L.map_to_local(cc)) + Vector2(0, -30)
		var col := b.move_and_collide(Vector2(0, 40))
		out.append([col.get_collider_rid(), col.get_collider_shape_index(), L.get_coords_for_body_rid(col.get_collider_rid()), hit_cell(L, col)])
	b.queue_free()
	return out


# A floor on row 5 (y 80..96) from x 0 to 128; a 10x12 body, origin at its feet,
# centred on x=48 — the boundary between cells (2,5) and (3,5). 30 frames of
# gravity to land, then 30 frames recorded.
func standing(L: TileMapLayer) -> Dictionary:
	for cx in range(0, 8):
		L.set_cell(Vector2i(cx, 5), 0, Vector2i(0, 0))
	await physics_frame
	await physics_frame
	var b := body("rect", true)
	b.global_position = Vector2(48, 60)
	await physics_frame
	var r := {"frames": 0, "count_one": 0, "rid": {}, "pattern": {}, "on_floor": 0}
	for i in 60:
		b.velocity.y += 20
		b.move_and_slide()
		if i >= 30:
			r.frames += 1
			if b.is_on_floor(): r.on_floor += 1
			if b.get_slide_collision_count() == 1: r.count_one += 1
			for j in b.get_slide_collision_count():
				var col := b.get_slide_collision(j)
				var rc := L.get_coords_for_body_rid(col.get_collider_rid())
				r.rid[rc] = r.rid.get(rc, 0) + 1
				var pc := hit_cell(L, col)
				r.pattern[pc] = r.pattern.get(pc, 0) + 1
		await physics_frame
	b.queue_free()
	return r


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
	var v := Engine.get_version_info()
	var ver := "%d.%d" % [v.major, v.minor]

	var L := layer(0)
	L.set_cell(TARGET, 0, Vector2i(0, 0))
	await physics_frame
	await physics_frame
	var has_quadrant := "physics_quadrant_size" in L

	# ---- K: the harness can tell a right cell from a wrong one ----------------
	check("K1", [cell_at(L, Vector2(328, 328)), cell_at(L, Vector2(336, 320))], [TARGET, Vector2i(21, 20)],
		"control: the tile's centre reads (20,20), its top-right corner (336,320) reads (21,20)")

	var rect := sweep(L, "rect")
	var cap := sweep(L, "capsule")
	print("NOTE %s rect: %s" % [ver, rect])
	print("NOTE %s capsule: %s" % [ver, cap])

	check("K2", [rect.hits, cap.hits], [88, 88], "control: every one of the 88 approaches per shape hit the tile")

	# ---- C: what the collision object is ----------------------------------------
	check("C1", [rect.collider_is_layer, cap.collider_is_layer], [88, 88],
		"get_collider() is the TileMapLayer itself on every hit, not an object per tile")

	# ---- N: the contact point, used directly ------------------------------------
	check("N1", [rect.naive, cap.naive], [37, 37],
		"local_to_map(to_local(get_position())) is the hit tile on only 37 of 88 approaches, for both shapes")
	check("N2", [rect.naive_below, rect.naive_right, cap.naive_below, cap.naive_right], [0, 0, 0, 0],
		"hitting a tile from below or from the right, it is never the hit tile (0 of 11 each)")
	check("N3", [rect.naive_miss_empty, cap.naive_miss_empty], [51, 51],
		"every wrong answer is an empty neighbour cell (get_cell_source_id == -1)")

	# ---- F: minus the normal, then the corner fallback --------------------------
	check("F1", [rect.normal, cap.normal], [72, 81],
		"get_position() - get_normal() * 0.5 fixes most of it: 72/88 rectangle, 81/88 capsule")
	check("F2", [rect.normal_miss_on_corner, cap.normal_miss_on_corner], [16, 7],
		"every one it still gets wrong is a contact point exactly on a tile corner")
	check("F3", [rect.pattern, cap.pattern], [88, 88],
		"minus the normal plus a half-pixel probe along each axis for a non-empty cell: 88/88 for both")

	# ---- R: get_collider_rid() + get_coords_for_body_rid() ----------------------
	if not has_quadrant:
		check("R1", has_quadrant, false, ver + ": TileMapLayer has no physics_quadrant_size property")
		check("R2", [rect.rid_cell, cap.rid_cell], [88, 88],
			ver + ": get_coords_for_body_rid(get_collider_rid()) is the hit cell on 88/88 for both shapes")
	else:
		check("R1", L.get("physics_quadrant_size"), 16, ver + ": physics_quadrant_size exists and defaults to 16")
		check("R2", [rect.rid_cell, cap.rid_cell, rect.rid_11, cap.rid_11], [0, 0, 88, 88],
			ver + ": get_coords_for_body_rid() is never the cell (0/88): it is (1,1), the 16x16 chunk, on 88/88")
	L.queue_free()
	await physics_frame

	# ---- Q: several tiles, one physics body? ------------------------------------
	L = layer(0)
	for cc in [Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)]:
		L.set_cell(cc, 0, Vector2i(0, 0))
	await physics_frame
	await physics_frame
	var t := three_tiles(L)
	print("NOTE %s three tiles, default layer: %s" % [ver, t])
	check("Q1", [t[0][3], t[1][3], t[2][3]], [Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)],
		"control: the recommended pattern names each of the three tiles")
	if not has_quadrant:
		check("Q2", [t[0][0] != t[1][0], t[1][0] != t[2][0]], [true, true],
			ver + ": each tile is its own physics body — three different collider RIDs")
		check("Q3", [t[0][2], t[1][2], t[2][2]], [Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)],
			ver + ": and get_coords_for_body_rid() gives each tile's cell")
	else:
		check("Q2", [t[0][0] == t[1][0], t[1][0] != t[2][0], t[0][1], t[1][1]], [true, true, 0, 1],
			ver + ": (20,20) and (23,20) are ONE body (same RID, shape index 0 and 1); (40,20) is another")
		check("Q3", [t[0][2], t[1][2], t[2][2]], [Vector2i(1, 1), Vector2i(1, 1), Vector2i(2, 1)],
			ver + ": get_coords_for_body_rid() gives (1,1), (1,1), (2,1) — hitting two different tiles returns the same coords")
	var st: Dictionary = await standing(L)
	print("NOTE %s standing, default layer: %s" % [ver, st])
	L.queue_free()
	await physics_frame

	# ---- S: standing on the seam between two floor tiles ------------------------
	check("S1", [st.on_floor, st.count_one], [30, 30],
		"a body centred on the seam of cells (2,5)|(3,5): on the floor, and get_slide_collision_count() is 1 on 30/30 frames, never 2")
	check("S2", st.pattern.keys(), [Vector2i(3, 5)],
		"the recommended pattern reports only (3,5), on every frame — one of the two tiles, not both")
	if not has_quadrant:
		check("S3", [st.rid.size(), st.rid.has(Vector2i(2, 5)), st.rid.has(Vector2i(3, 5))], [2, true, true],
			ver + ": get_coords_for_body_rid() reports (2,5) on some frames and (3,5) on others")
	else:
		check("S3", st.rid.keys(), [Vector2i(0, 0)],
			ver + ": get_coords_for_body_rid() reports (0,0), the chunk, on every frame")

	# ---- P: physics_quadrant_size = 1 (only where the property exists) ----------
	if has_quadrant:
		var L1 := layer(1)
		L1.set_cell(TARGET, 0, Vector2i(0, 0))
		await physics_frame
		await physics_frame
		var r1 := sweep(L1, "rect")
		var c1 := sweep(L1, "capsule")
		check("P1", [r1.rid_cell, c1.rid_cell], [88, 88],
			ver + ": with physics_quadrant_size = 1, get_coords_for_body_rid() is the hit cell on 88/88 again")
		L1.queue_free()
		await physics_frame
		L1 = layer(1)
		for cc in [Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)]:
			L1.set_cell(cc, 0, Vector2i(0, 0))
		await physics_frame
		await physics_frame
		var t1 := three_tiles(L1)
		check("P2", [t1[0][0] != t1[1][0], t1[0][2], t1[1][2], t1[2][2]], [true, Vector2i(20, 20), Vector2i(23, 20), Vector2i(40, 20)],
			ver + ": ... and each tile is its own body with its own cell")
		var st1: Dictionary = await standing(L1)
		print("NOTE %s standing, quadrant 1: %s" % [ver, st1])
		check("P3", [st1.count_one, st1.rid.size(), st1.rid.has(Vector2i(2, 5)), st1.rid.has(Vector2i(3, 5))], [30, 2, true, true],
			ver + ": ... and on the seam it reports (2,5) on some frames and (3,5) on others, still one collision a frame")
		L1.queue_free()

	if failures == 0:
		print("TILE HIT: ALL PASS (%d checks)" % checks)
	else:
		print("TILE HIT: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
