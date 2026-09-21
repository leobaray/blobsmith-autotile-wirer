extends SceneTree

# Engine gate for the free walkable-floor navigation pack (dungeon / meadow /
# deck / cave).
#
# The README promises four floor+wall terrain sets, 32 tiles each, where every
# FLOOR tile carries a full-cell navigation polygon in centred coordinates and
# every WALL tile carries collision and no navigation — and it promises that a
# path works the moment the room is painted. So the claims are not read off the
# resource alone: the room is painted into a real TileMapLayer with
# set_cells_terrain_connect, and the questions are put to NavigationServer2D and
# PhysicsDirectSpaceState2D.
#
# Two things here are deliberate (docs/verify_tile_navigation.gd measured why):
#   * each TileSet gets its OWN navigation map (map_create + map_set_active) and
#     the layer is pointed at it. In a --script SceneTree the World2D default map
#     never activates, so every path against it is empty and a gate that expects
#     "empty" would pass for the wrong reason.
#   * the map is asked for a path only after map_get_iteration_id() has moved
#     past the value held when the edit was made AND the region count is the one
#     the edit should produce, and then the answer has to stop changing. No
#     fixed number of frames anywhere — that number is not a constant.
#
# Every expectation (room, start, goal, gap, door, sizes, names, layers) is read
# from manifest.json. `--invert` shifts one expectation (the goal cell) by one
# cell on the first TileSet, so the gate must FAIL.

var failures := 0
var checked := 0
const FRAME_BUDGET := 240

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const SIDES := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE,
]
const DIRS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]

func poly_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(pts.size()):
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

func v2i(a: Array) -> Vector2i:
	return Vector2i(int(a[0]), int(a[1]))

func centre(c: Vector2i, T: int) -> Vector2:
	return Vector2(c.x * T + T * 0.5, c.y * T + T * 0.5)

# the room plan: cell -> terrain (0 floor, 1 wall), from the manifest
func plan(room: Dictionary) -> Dictionary:
	var out := {}
	var w := int(room["w"])
	var h := int(room["h"])
	var ix := int(room["inner_wall_x"])
	var iy: Array = room["inner_wall_y"]
	for y in range(h):
		for x in range(w):
			var wall := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if x == ix and y >= int(iy[0]) and y <= int(iy[1]):
				wall = true
			out[Vector2i(x, y)] = 1 if wall else 0
	return out

func cells_of(p: Dictionary, terrain: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in p:
		if p[c] == terrain:
			out.append(c)
	out.sort()
	return out

func path_len(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i - 1].distance_to(pts[i])
	return l

# Walks every segment of the path in 0.25 px steps. Returns the number of
# samples that lie STRICTLY inside a wall cell (more than 0.01 px from its
# boundary) — a point on the shared edge of a wall and a floor cell is legal,
# that is where a full-cell mesh puts its corners — and whether any sample lay in
# `through` (the gap).
func walk(pts: PackedVector2Array, p: Dictionary, T: int, through: Vector2i) -> Dictionary:
	var inside := 0
	var hit_through := false
	var worst := Vector2.ZERO
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, int(ceil(a.distance_to(b) / 0.25)))
		for s in range(n + 1):
			var q := a.lerp(b, float(s) / n)
			var c := Vector2i(int(floor(q.x / T)), int(floor(q.y / T)))
			if c == through:
				hit_through = true
			if p.get(c, -1) == 1:
				var lx := q.x - c.x * T
				var ly := q.y - c.y * T
				if lx > 0.01 and ly > 0.01 and lx < T - 0.01 and ly < T - 0.01:
					inside += 1
					worst = q
	return {"inside": inside, "through": hit_through, "worst": worst}

func point_hits(space: PhysicsDirectSpaceState2D, at: Vector2) -> int:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = at
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return space.intersect_point(q, 8).size()

func fresh_map() -> RID:
	var m := NavigationServer2D.map_create()
	NavigationServer2D.map_set_active(m, true)
	NavigationServer2D.map_set_cell_size(m, 1.0)
	return m

# Waits for the map to be DONE applying an edit: the iteration id must move past
# `id_before` and the region count must be `regions`, for 3 frames running; then
# the path answer itself must stop changing for 8 frames (the bookkeeping and the
# path are updated independently — docs/verify_tile_navigation.gd, settle_path).
# Returns the frames waited until the id first moved, and the settled path.
func settle(map: RID, id_before: int, regions: int, from: Vector2, to: Vector2) -> Dictionary:
	var moved_at := -1
	var still := 0
	var frames := 0
	while frames < FRAME_BUDGET:
		await physics_frame
		frames += 1
		var id := int(NavigationServer2D.map_get_iteration_id(map))
		if id != id_before and moved_at < 0:
			moved_at = frames
		if id != id_before and NavigationServer2D.map_get_regions(map).size() == regions:
			still += 1
			if still >= 3:
				break
		else:
			still = 0
	var last := PackedVector2Array()
	var same := 0
	for i in range(FRAME_BUDGET):
		await physics_frame
		var now := NavigationServer2D.map_get_path(map, from, to, true, 1)
		if now.size() == last.size() and (now.size() == 0 or now[now.size() - 1].is_equal_approx(last[last.size() - 1])):
			same += 1
			if same >= 8:
				break
		else:
			same = 0
			last = now
	return {"moved_at": moved_at, "path": last, "id": int(NavigationServer2D.map_get_iteration_id(map))}

func hex_to_color(h: String) -> Color:
	return Color(h)

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://navigation/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("NAVIGATION: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("NAVIGATION: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d walkable-floor tilesets" % (man as Array).size())

	var first := true
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var navbits: int = int(entry["navigation_layers_bitmask"])
		var ts: TileSet = load("res://navigation/%s.tres" % base)
		ck("N1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("N2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("N3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"])
			and src.get_tiles_count() == int(entry["tiles"]) and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: %dx%d sheet, %d tiles, square cell %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"]), int(entry["tiles"]), T, T])
		var names: Array = entry["terrains"]
		ck("N4", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES and ts.get_terrains_count(0) == 2
			and ts.get_terrain_name(0, 0) == names[0] and ts.get_terrain_name(0, 1) == names[1],
			"%s: one Match Sides terrain set, terrain 0 '%s' and terrain 1 '%s'" % [base, names[0], names[1]])
		ck("N5", ts.get_navigation_layers_count() == 1 and ts.get_navigation_layer_layers(0) == navbits
			and ts.get_physics_layers_count() == 1 and ts.get_physics_layer_collision_layer(0) == int(entry["collision_layer"]),
			"%s: one navigation layer with layers = %d (what a NavigationAgent2D asks for by default), one physics layer with collision_layer = %d"
				% [base, ts.get_navigation_layer_layers(0), ts.get_physics_layer_collision_layer(0)])

		# --- every tile, read back through TileData ------------------------------
		var floor_ok := 0
		var floor_n := 0
		var wall_ok := 0
		var wall_n := 0
		var combos := {}
		var empty_bits := 0
		var h := T * 0.5
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			var m := 0
			for k in range(4):
				var b := td.get_terrain_peering_bit(SIDES[k])
				if b == -1:
					empty_bits += 1
				if b == td.terrain:
					m |= 1 << k
			combos[str(td.terrain) + ":" + str(m)] = true
			var np := td.get_navigation_polygon(0)
			if td.terrain == int(entry["floor_terrain"]):
				floor_n += 1
				var good := np != null and np.get_polygon_count() == 1 and td.get_collision_polygons_count(0) == 0
				if good:
					var vs := np.get_vertices()
					var idx := np.get_polygon(0)
					var pts := PackedVector2Array()
					for j in idx:
						pts.append(vs[j])
					good = pts.size() == 4 and is_equal_approx(poly_area(pts), float(T * T))
					for v in vs:
						if absf(v.x) > h + 0.001 or absf(v.y) > h + 0.001:
							good = false
				if good:
					floor_ok += 1
			elif td.terrain == int(entry["wall_terrain"]):
				wall_n += 1
				var no_nav := np == null or np.get_polygon_count() == 0
				if no_nav and td.get_collision_polygons_count(0) == 1:
					var cp := td.get_collision_polygon_points(0, 0)
					if cp.size() == 4 and is_equal_approx(poly_area(cp), float(T * T)):
						wall_ok += 1
		ck("N6", floor_n == int(entry["floor_tiles"]) and floor_ok == floor_n,
			"%s: all %d floor tiles carry one navigation polygon, a full cell of %d px^2 with every vertex inside (-%d,-%d)..(%d,%d) — centred, not (0,0)..(%d,%d) — and no collision (%d/%d)"
				% [base, floor_n, T * T, T / 2, T / 2, T / 2, T / 2, T, T, floor_ok, floor_n])
		ck("N7", wall_n == int(entry["wall_tiles"]) and wall_ok == wall_n,
			"%s: all %d wall tiles carry NO navigation polygon and one full-cell collision polygon (%d/%d)"
				% [base, wall_n, wall_ok, wall_n])
		var wall_all := combos.has("1:15")
		ck("N8", combos.size() == 17 and wall_all and empty_bits == 0,
			"%s: 16 floor tiles cover all 16 floor/wall side combinations, the one wall tile is Wall on all four sides, and no side bit is left empty (%d distinct, %d empty) — the edge between floor and wall belongs to the wall, on both tiles"
				% [base, combos.size(), empty_bits])

		# --- the art claim --------------------------------------------------------
		var img := src.texture.get_image()
		var shade := hex_to_color(entry["floor_shade"])
		var band_ok := 0
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			if td.terrain != int(entry["floor_terrain"]):
				continue
			var m := 0
			for k in range(4):
				if td.get_terrain_peering_bit(SIDES[k]) == td.terrain:
					m |= 1 << k
			var X := coords.x * T
			var Y := coords.y * T
			var mid := int(T / 2) + 1
			var probes := [[X + T - 1, Y + mid, 1], [X + mid, Y + T - 1, 2], [X, Y + mid, 4], [X + mid, Y, 8]]
			var ok := true
			for q in probes:
				if img.get_pixel(q[0], q[1]).is_equal_approx(shade) != ((m & int(q[2])) == 0):
					ok = false
			if ok:
				band_ok += 1
		ck("N9", band_ok == 16,
			"%s: the %dpx shade band is drawn on exactly the floor sides that meet a wall, in all 16 floor tiles (%d/16)"
				% [base, int(entry["band_px"]), band_ok])

		# --- painted into the running tree, asked of the servers -------------------
		var room: Dictionary = entry["room"]
		var p := plan(room)
		var floors := cells_of(p, 0)
		var walls := cells_of(p, 1)
		var start := v2i(room["start"])
		var goal := v2i(room["goal"])
		var gap := v2i(room["gap"])
		var door := v2i(room["door"])
		var want_goal := goal + (Vector2i(1, 0) if invert and first else Vector2i.ZERO)
		var A := centre(start, T)
		var B := centre(goal, T)

		var map := fresh_map()
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		layer.set_navigation_map(map)
		var id0 := int(NavigationServer2D.map_get_iteration_id(map))
		layer.set_cells_terrain_connect(floors, 0, 0, false)
		layer.set_cells_terrain_connect(walls, 0, 1, false)

		# asked in the same frame the room was painted, before the id can move
		var early := NavigationServer2D.map_get_path(map, A, B, true, 1)
		var id_early := int(NavigationServer2D.map_get_iteration_id(map))
		ck("N10", early.size() == 0 and id_early == id0,
			"%s: asked in the frame the room was painted, before map_get_iteration_id() moves (still %d), the map answers an EMPTY path (%d points) — the query has to wait for the id"
				% [base, id_early, early.size()])

		var s1: Dictionary = await settle(map, id0, floors.size(), A, B)
		var path: PackedVector2Array = s1["path"]

		var agree := 0
		for c in p:
			var td := layer.get_cell_tile_data(c)
			if td == null or td.terrain != p[c]:
				continue
			var good := true
			for k in range(4):
				var nb: Vector2i = c + DIRS[k]
				if p.has(nb) and td.get_terrain_peering_bit(SIDES[k]) != (1 if (p[nb] == 1 or p[c] == 1) else 0):
					good = false
			if good:
				agree += 1
		ck("N11", agree == p.size(),
			"%s: set_cells_terrain_connect painted the %dx%d room (%d floor, %d wall) with every cell's terrain as asked and every side bit right — Wall on each floor/wall edge, Floor between two floors (%d/%d)"
				% [base, int(room["w"]), int(room["h"]), floors.size(), walls.size(), agree, p.size()])

		var regions := NavigationServer2D.map_get_regions(map).size()
		ck("N12", s1["moved_at"] > 0 and regions == floors.size(),
			"%s: after the iteration id moved (frame %d, id %d -> %d) the map holds one region per FLOOR cell and none for the walls: %d regions for %d floor + %d wall cells"
				% [base, s1["moved_at"], id0, s1["id"], regions, floors.size(), walls.size()])

		var got_first := layer.local_to_map(path[0]) if path.size() else Vector2i(-99, -99)
		var got_last := layer.local_to_map(path[path.size() - 1]) if path.size() else Vector2i(-99, -99)
		ck("N13", path.size() > 0 and got_first == start and got_last == want_goal
			and path[0].is_equal_approx(A) and path[path.size() - 1].is_equal_approx(B),
			"%s: the path from the centre of %s to the centre of %s starts and ends exactly there, in the right cells (%s -> %s) — no half-tile offset"
				% [base, str(start), str(want_goal), str(got_first), str(got_last)])

		var w1 := walk(path, p, T, gap)
		var straight := A.distance_to(B)
		var l1 := path_len(path)
		ck("N14", path.size() > 0 and w1["inside"] == 0 and w1["through"] and l1 > straight + T,
			"%s: the path goes AROUND the inner wall through the gap %s: %d points, %.1f px long against %.1f px straight, 0 samples inside a wall cell (%d)"
				% [base, str(gap), path.size(), l1, straight, w1["inside"]])

		# the half-tile check, asked of the mesh itself
		var q_in := Vector2(start.x * T + T * 0.25, start.y * T + T * 0.25)
		var cp_in := NavigationServer2D.map_get_closest_point(map, q_in)
		var wall_c := centre(Vector2i(int(room["inner_wall_x"]), start.y), T)
		var cp_wall := NavigationServer2D.map_get_closest_point(map, wall_c)
		ck("N15", cp_in.is_equal_approx(q_in) and is_equal_approx(cp_wall.distance_to(wall_c), T * 0.5),
			"%s: a point in the TOP-LEFT quarter of a floor cell %s is on the mesh (closest point %s), and the centre of a wall cell is pulled %.2f px to the wall's edge — the polygon covers the art, not the cell half a tile down-right"
				% [base, str(q_in), str(cp_in), cp_wall.distance_to(wall_c)])

		var space := layer.get_world_2d().direct_space_state
		var hit_wall := point_hits(space, wall_c)
		var hit_floor := point_hits(space, A)
		ck("N16", hit_wall >= 1 and hit_floor == 0,
			"%s: the physics server finds a collider at the wall cell's centre (%d) and none on the floor cell (%d) — walls block bodies, floors do not"
				% [base, hit_wall, hit_floor])

		# --- close the corridor: paint the gap as wall ----------------------------
		var id1 := int(NavigationServer2D.map_get_iteration_id(map))
		var only_gap: Array[Vector2i] = [gap]
		layer.set_cells_terrain_connect(only_gap, 0, 1, false)
		var s2: Dictionary = await settle(map, id1, floors.size() - 1, A, B)
		var cut: PackedVector2Array = s2["path"]
		var cut_last := cut[cut.size() - 1] if cut.size() else Vector2(-1, -1)
		var wall_x := float(int(room["inner_wall_x"]) * T)
		ck("N17", cut.size() > 0 and not cut_last.is_equal_approx(B) and cut_last.x <= wall_x + 0.01
			and walk(cut, p, T, Vector2i(-99, -99))["inside"] == 0,
			"%s: with the gap painted as wall the room is two rooms, and the path does NOT come back empty — it comes back %d points long ending at %s, on the start side of the wall (x <= %d), %.1f px short of the goal. `if path.is_empty()` never fires"
				% [base, cut.size(), str(cut_last), int(wall_x), cut_last.distance_to(B)])

		# --- reopen it ----------------------------------------------------------------
		var id2 := int(NavigationServer2D.map_get_iteration_id(map))
		layer.set_cells_terrain_connect(only_gap, 0, 0, false)
		var s3: Dictionary = await settle(map, id2, floors.size(), A, B)
		var back: PackedVector2Array = s3["path"]
		ck("N18", back.size() > 0 and back[back.size() - 1].is_equal_approx(B) and is_equal_approx(path_len(back), l1),
			"%s: painting the gap back as floor restores the full path to the goal, same length (%.1f px)"
				% [base, path_len(back)])

		# --- open a door in the inner wall --------------------------------------------
		p[door] = 0
		var id3 := int(NavigationServer2D.map_get_iteration_id(map))
		var only_door: Array[Vector2i] = [door]
		layer.set_cells_terrain_connect(only_door, 0, 0, false)
		var s4: Dictionary = await settle(map, id3, floors.size() + 1, A, B)
		var direct: PackedVector2Array = s4["path"]
		ck("N19", direct.size() > 0 and direct[direct.size() - 1].is_equal_approx(B) and is_equal_approx(path_len(direct), straight)
			and walk(direct, p, T, door)["through"],
			"%s: painting the door %s as floor makes the path the straight line through it: %.1f px, against %.1f px around"
				% [base, str(door), path_len(direct), l1])

		# --- the two ways to paint it that are not the one above --------------------
		# (a) the DEFAULT 4th argument. The editor's Connect tool passes
		#     ignore_empty_terrains = false; a script that leaves it out gets true.
		var d := TileMapLayer.new()
		d.tile_set = ts
		d.navigation_enabled = false
		root.add_child(d)
		d.set_cells_terrain_connect(floors, 0, 0)
		d.set_cells_terrain_connect(walls, 0, 1)
		var d_used := d.get_used_cells().size()
		var d_walls := 0
		for c in d.get_used_cells():
			if d.get_cell_tile_data(c).terrain == 1:
				d_walls += 1
		root.remove_child(d)
		d.free()
		ck("N20", d_used < p.size(),
			"%s: the same two calls WITHOUT the 4th argument (ignore_empty_terrains defaults to true) paint %d of the %d cells, %d of them walls — every cell next to an empty cell is left empty, because no tile here has an empty side. Pass false, as the editor does"
				% [base, d_used, p.size(), d_walls])

		# (b) walls first, then the floor
		var map2 := fresh_map()
		var o := TileMapLayer.new()
		o.tile_set = ts
		root.add_child(o)
		o.set_navigation_map(map2)
		var id20 := int(NavigationServer2D.map_get_iteration_id(map2))
		o.set_cells_terrain_connect(walls, 0, 1, false)
		o.set_cells_terrain_connect(floors, 0, 0, false)
		var so: Dictionary = await settle(map2, id20, floors.size(), A, B)
		var opath: PackedVector2Array = so["path"]
		var off_art := 0
		var q := plan(room)
		for c in q:
			var td := o.get_cell_tile_data(c)
			if td == null:
				off_art += 1
				continue
			for k in range(4):
				var nb: Vector2i = c + DIRS[k]
				if q.has(nb) and td.get_terrain_peering_bit(SIDES[k]) != (1 if (q[nb] == 1 or q[c] == 1) else 0):
					off_art += 1
					break
		ck("N21", NavigationServer2D.map_get_regions(map2).size() == floors.size() and opath.size() > 0
			and is_equal_approx(path_len(opath), l1) and walk(opath, q, T, gap)["inside"] == 0,
			"%s: painting the walls FIRST and the floor second gives the same navigation (%d regions, %.1f px path, none of it inside a wall) — but %d floor cells come out with a shade band missing on a side that touches a wall, so paint the floor first"
				% [base, NavigationServer2D.map_get_regions(map2).size(), path_len(opath), off_art])
		root.remove_child(o)
		o.free()
		NavigationServer2D.free_rid(map2)

		first = false
		root.remove_child(layer)
		layer.free()
		NavigationServer2D.free_rid(map)
		await physics_frame
		ts = null

	if failures == 0:
		print("NAVIGATION %d/%d PASS" % [checked, checked])
	else:
		print("NAVIGATION: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
