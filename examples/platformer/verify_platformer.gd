extends SceneTree
##
## Runs every claim in examples/platformer/README.md against a real Godot 4 binary,
## with the real platformer_demo.tscn and the real player.gd. Use
## verify_platformer.sh; it builds a throwaway project with this folder copied to
## res://platformer/ so nothing is written into yours.
##
## Movement is driven by real physics frames at the default 60 ticks, and input by
## Input.action_press / action_release on the built-in ui_* actions — the player
## script reads them exactly as it does when a person presses the keys.
## Positions are compared as whole pixels (roundi), never as raw floats.
##
## Level geometry (16px tiles, from manifest.json): the floor under the first
## platform has its top edge at y = 192, the platform cells (4..7, 9) have their
## top edge at y = 144. The player's shape is 12x14, so it rests at y = 185 on
## the floor and y = 137 on the platform.
##
## Every expected value was first printed by an exploratory pass (the NOTE lines)
## on 4.3, 4.4 and 4.7, and only then written down.
##
##   godot --headless --path <proj> --script verify_platformer.gd [-- --invert]
##
## --invert flips the expectation of T2 and P3 on purpose, so a run that cannot
## fail is visible. Prints PASS/FAIL per check and a final "PLATFORMER:" line.

const DIR := "res://platformer/"
const FLOOR_Y := 185
const PLAT_Y := 137
const PLAT_X := 96.0
const OPEN_X := 344.0   # floor cell 21: nothing above it within jump height

var failures := 0
var checks := 0
var invert := false
var scene: Node
var player: CharacterBody2D
var level: TileMapLayer


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "T2" or id == "P3"):
		want = "deliberately wrong"
	var ok: bool = typeof(got) == typeof(want) and got == want
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))


func note(id: String, text: String) -> void:
	print("NOTE %s %s" % [id, text])


# ---- terrain ----------------------------------------------------------------
const PAIRS := [
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[Vector2i(1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(-1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
]
const SIDES := [
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE], [Vector2i(-1, 0), TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_SIDE], [Vector2i(0, -1), TileSet.CELL_NEIGHBOR_TOP_SIDE],
]


func is_ground(l: TileMapLayer, c: Vector2i) -> bool:
	var td := l.get_cell_tile_data(c)
	return td != null and td.terrain_set == 0 and td.terrain == 0


# [ground cells, disagreeing shared sides/corners, sides whose bit does not match whether a ground cell is there]
func terrain_audit(l: TileMapLayer) -> Array:
	var n := 0
	var bad := 0
	var side_bad := 0
	for c in l.get_used_cells():
		if not is_ground(l, c):
			continue
		n += 1
		var td := l.get_cell_tile_data(c)
		for p in PAIRS:
			var nc: Vector2i = c + p[0]
			if is_ground(l, nc) and td.get_terrain_peering_bit(p[1]) != l.get_cell_tile_data(nc).get_terrain_peering_bit(p[2]):
				bad += 1
		for s in SIDES:
			if (td.get_terrain_peering_bit(s[1]) == 0) != is_ground(l, c + s[0]):
				side_bad += 1
	return [n, bad, side_bad]


# ---- physics helpers ----------------------------------------------------------
func frames(n: int) -> void:
	for i in n:
		await physics_frame


func place(pos: Vector2) -> void:
	player.velocity = Vector2.ZERO
	player.global_position = pos
	await frames(40)


# presses ui_accept for one physics frame (optionally with ui_down held), then
# runs n frames; returns [min y, max y, ever on ceiling, final y (int), on floor]
func jump(n: int, down := false) -> Array:
	if down:
		Input.action_press("ui_down")
	Input.action_press("ui_accept")
	var lo := 1e9
	var hi := -1e9
	var ceil := false
	for i in n:
		await physics_frame
		if i == 1:
			Input.action_release("ui_accept")
		lo = min(lo, player.global_position.y)
		hi = max(hi, player.global_position.y)
		ceil = ceil or player.is_on_ceiling()
	Input.action_release("ui_accept")
	Input.action_release("ui_down")
	await frames(2)
	return [roundi(lo), roundi(hi), ceil, roundi(player.global_position.y), player.is_on_floor()]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
	print("Godot " + Engine.get_version_info()["string"])

	var mf := FileAccess.open(DIR + "manifest.json", FileAccess.READ)
	if mf == null:
		print("PLATFORMER: manifest.json missing")
		quit(3)
		return
	var manifest: Dictionary = JSON.parse_string(mf.get_as_text())

	# ---- S: the files -----------------------------------------------------------
	var packed: PackedScene = load(DIR + "platformer_demo.tscn")
	check("S1", packed != null, true, "platformer_demo.tscn loads (relative paths to the .tres and player.gd)")
	if packed == null:
		print("PLATFORMER: scene did not load")
		quit(1)
		return
	scene = packed.instantiate()
	level = scene.get_node("Level")
	player = scene.get_node("Player")
	check("S2", [player.get_script() != null, player.collision_mask, level.tile_set != null],
		[true, 3, true], "the scene has a Player (CharacterBody2D) with player.gd and collision_mask 3, and a Level TileMapLayer with the TileSet")

	for entry in manifest["tilesets"]:
		var base: String = entry["base"]
		var ts: TileSet = load(DIR + base + ".tres")
		var src := ts.get_source(0) as TileSetAtlasSource
		check("S3", [src.texture.get_width(), src.texture.get_height(), src.get_tiles_count()],
			[int(entry["sheet_w"]), int(entry["sheet_h"]), 50], "%s loads with its PNG next to it: sheet %dx%d, 50 tiles" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		check("S4", [ts.get_physics_layers_count(), ts.get_physics_layer_collision_layer(0), ts.get_physics_layer_collision_layer(1)],
			[2, 1, 2], "%s: two physics layers, layer 0 on collision bit 1 (value 1), layer 1 on bit 2 (value 2)" % base)
		check("S5", [ts.get_terrain_sets_count(), ts.get_terrain_set_mode(0), ts.get_terrains_count(0), ts.get_terrain_name(0, 0)],
			[1, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES, 1, "Ground"], "%s: terrain set 0, Match Corners and Sides, one terrain \"Ground\"" % base)
		var ground := 0
		var plat := 0
		var odd := []
		var T := int(entry["tile_size"])
		for i in src.get_tiles_count():
			var at := src.get_tile_id(i)
			var td := src.get_tile_data(at, 0)
			if at.y < 6:
				if td.terrain_set == 0 and td.terrain == 0 and td.get_collision_polygons_count(0) == 1 and td.get_collision_polygons_count(1) == 0 \
						and not td.is_collision_polygon_one_way(0, 0):
					ground += 1
				else:
					odd.append(at)
			else:
				var pts := td.get_collision_polygon_points(1, 0) if td.get_collision_polygons_count(1) == 1 else PackedVector2Array()
				var top_ok := pts.size() == 4 and roundi(pts[0].y) == -T / 2 and roundi(pts[2].y) == -T / 2 + T / 4
				if td.terrain_set == -1 and td.get_collision_polygons_count(0) == 0 and td.get_collision_polygons_count(1) == 1 \
						and td.is_collision_polygon_one_way(1, 0) and top_ok:
					plat += 1
				else:
					odd.append(at)
		check("S6", [ground, plat, odd], [47, 3, []],
			"%s: 47 ground tiles (terrain Ground, square polygon on layer 0 only, not one-way) and 3 platform tiles (no terrain, no polygon on layer 0, one polygon on layer 1 covering the top %d px, one_way)" % [base, T / 4])

	# ---- T: the painted level -----------------------------------------------------
	var a := terrain_audit(level)
	note("T", "ground cells %d, disagreements %d, side bits not matching a neighbour %d" % a)
	check("T1", a[0], int(manifest["demo"]["ground_cells"]), "every one of the %d ground cells in the scene is a Ground terrain tile" % int(manifest["demo"]["ground_cells"]))
	check("T2", [a[1], a[2]], [0, 0], "every touching pair of ground cells agrees on every shared side and corner, and every side bit is set exactly where a ground cell is")
	var ctl := level.duplicate() as TileMapLayer
	ctl.set_cell(Vector2i(5, 13), 0, Vector2i(0, 0))   # an interior floor cell swapped for the lone-island tile
	var ca := terrain_audit(ctl)
	ctl.free()
	note("T3", "control (one floor cell swapped for the island tile): ground %d, disagreements %d, side mismatches %d" % ca)
	check("T3", [ca[1] > 0, ca[2] > 0], [true, true], "control: the same audit on a copy with one floor cell (5,13) swapped for the island tile does find disagreements")

	# ---- P: the player in the demo scene -------------------------------------------
	root.add_child(scene)
	await frames(90)
	note("P1", "spawn %s -> y %d, on floor %s" % [str(Vector2(2 * 16 + 8, 9 * 16 + 8)), roundi(player.global_position.y), player.is_on_floor()])
	check("P1", [roundi(player.global_position.y), player.is_on_floor()], [FLOOR_Y, true],
		"the player spawned in the air at (40, 152) falls and stands on the floor: y = 185, is_on_floor() true")

	await place(Vector2(PLAT_X, FLOOR_Y))
	var j1 := await jump(90)
	note("P2", "jump from under the platform: min y %d, max y %d, ceiling %s, final y %d, on floor %s" % j1)
	check("P2", [j1[0] < PLAT_Y - 7, j1[2], j1[3], j1[4]], [true, false, PLAT_Y, true],
		"jump from the floor under the platform: rises past it (highest y < 130), never touches a ceiling, and ends standing on it: y = 137, is_on_floor() true")

	var d := await jump(90, true)
	note("P3", "down + jump on the platform: min y %d, max y %d, ceiling %s, final y %d, on floor %s, mask %d" % (d + [player.collision_mask]))
	check("P3", [d[1], d[3], d[4], player.collision_mask], [FLOOR_Y, FLOOR_Y, true, 3],
		"ui_down held + ui_accept on the platform: drops through, lands on the floor below (lowest point y = 185, never inside the ground), is_on_floor() true, collision_mask back to 3")

	await place(Vector2(PLAT_X, PLAT_Y))
	var j2 := await jump(90)
	note("P4", "jump alone on the platform: min y %d, max y %d, final y %d, on floor %s" % [j2[0], j2[1], j2[3], j2[4]])
	check("P4", [j2[0] < PLAT_Y, j2[1], j2[3], j2[4]], [true, PLAT_Y, PLAT_Y, true],
		"control: ui_accept alone on the platform jumps and lands back on it (lowest y = 137)")

	await place(Vector2(OPEN_X, FLOOR_Y))
	var g := await jump(90, true)
	note("P5", "down + jump on the solid floor: min y %d, max y %d, final y %d, on floor %s" % [g[0], g[1], g[3], g[4]])
	check("P5", [g[0] < FLOOR_Y, g[1], g[3], g[4]], [true, FLOOR_Y, FLOOR_Y, true],
		"control: ui_down + ui_accept on the solid floor is a normal jump — it leaves the floor and lands back on it, never below y = 185")

	var sweep := []
	for n in [1, 2, 3, 4, 5, 6]:
		player.drop_frames = n
		await place(Vector2(PLAT_X, PLAT_Y))
		var r := await jump(60, true)
		sweep.append([n, r[3]])
	player.drop_frames = 6
	note("P7", "drop_frames sweep [frames, final y]: %s" % str(sweep))
	check("P7", sweep, [[1, PLAT_Y], [2, PLAT_Y], [3, PLAT_Y], [4, FLOOR_Y], [5, FLOOR_Y], [6, FLOOR_Y]],
		"drop_frames 1, 2 or 3: the body is back on the platform (y = 137); 4, 5 or 6 (the default): it drops to the floor (y = 185)")

	# control: the same tileset with one_way switched off on the platform polygons
	var ts: TileSet = level.tile_set
	var src := ts.get_source(0) as TileSetAtlasSource
	for x in 3:
		src.get_tile_data(Vector2i(x, 6), 0).set_collision_polygon_one_way(1, 0, false)
	await place(Vector2(PLAT_X, FLOOR_Y))
	var j3 := await jump(90)
	note("P6", "one_way off, jump from under: min y %d, max y %d, ceiling %s, final y %d, on floor %s" % j3)
	check("P6", [j3[0] > PLAT_Y, j3[2], j3[3], j3[4]], [true, true, FLOOR_Y, true],
		"control: with one_way switched off on the platform polygons the same jump hits the plank from below (is_on_ceiling() true) and lands back on the floor, not on top")

	scene.queue_free()
	if failures == 0:
		print("PLATFORMER: ALL PASS (%d checks)" % checks)
	else:
		print("PLATFORMER: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
