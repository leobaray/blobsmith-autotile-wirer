extends SceneTree

# Every claim in docs/why-tiles-are-not-walkable.md, asked of a real Godot 4
# binary instead of a forum.
#
#   docs/verify_tile_navigation.sh /path/to/Godot_v4.7-stable_linux.x86_64
#
# The subject is always the same corridor: six 16x16 cells painted in a row on
# one TileMapLayer, each cell carrying the same NavigationPolygon, and a path
# asked from the middle of the first cell (8,8) to the middle of the last (88,8).
#
# Two things about this file are deliberate and easy to get wrong when editing:
#
#   * it does NOT use the World2D navigation map. In a --script SceneTree the
#     default 2D map is never activated, so every query against it comes back
#     empty and every claim would "pass" for the wrong reason. Each case builds
#     its own map with map_set_active(true) and points the layer at it.
#
#   * it counts physics frames instead of awaiting a fixed number of them. The
#     headline claim (N10) is *how many frames* the map needs before it answers,
#     so a hardcoded settle would be assuming the answer.

# The frame each build first answered on, measured on an IDLE machine, six runs
# per build, identical every time. TileMapLayer does not exist before 4.3, so
# 4.2 is not in the table and never will be.
#
# This is a REFERENCE, not an expectation, and N10 does not assert equality
# against it. An earlier revision did, and it was wrong: put the same 4.7
# binary under CPU contention (200 spinning shells on a 160-core box) and it
# answered on frame 2, 11, 13 and 20 across four runs — both above the number
# tabled for it and below it, crossing the values tabled for 4.3 and 4.4 on the
# way. So the frame count is not a constant of the engine, and not a constant
# of a build either; the only thing the build fixes is what an unloaded machine
# happens to show you. That is the finding, and N30 is what to do about it.
const FRAMES_BEFORE_PATH_IDLE := {"4.3": 1, "4.4": 2, "4.7": 4}

# How long the measuring loop is willing to wait. Only has to be larger than
# any floor above; a starved run needs the headroom to report a NUMBER instead
# of "never", and "never" would fail eight unrelated claims downstream.
const FRAME_BUDGET := 240

var failures := 0
var checks := 0

const A := Vector2(8, 8)     # middle of cell (0,0)
const B := Vector2(88, 8)    # middle of cell (5,0)

func check(id: String, claim: String, cond: bool, measured: Variant = null) -> void:
	checks += 1
	if not cond:
		failures += 1
	var line := ("PASS  " if cond else "FAIL  ") + id + "  " + claim
	if measured != null:
		line += "   [measured: " + str(measured) + "]"
	print(line)

# Printed, not asserted. Some of what this file measures is real and useful and
# still not a pass/fail statement — a measurement that legitimately differs
# between runs of the same binary. Asserting `true` to get it on screen would
# inflate the check count with something that cannot fail, so it goes out as
# NOTE and is not counted.
func note(id: String, text: String, measured: Variant = null) -> void:
	print("NOTE  " + id + "  " + text + ("   [measured: " + str(measured) + "]" if measured != null else ""))

func minor() -> String:
	var v := Engine.get_version_info()
	return str(v.major) + "." + str(v.minor)

func solid(c: Color) -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)

# A square outline, in the tile's own coordinates. corner=true is the naive
# authoring (0,0)-(16,16); corner=false is the centred (-8,-8)-(8,8).
func rect_poly(x0: float, y0: float, w: float, h: float) -> NavigationPolygon:
	var np := NavigationPolygon.new()
	np.add_outline(PackedVector2Array([
		Vector2(x0, y0), Vector2(x0 + w, y0), Vector2(x0 + w, y0 + h), Vector2(x0, y0 + h)]))
	np.make_polygons_from_outlines()
	return np

func fresh_map() -> RID:
	var m := NavigationServer2D.map_create()
	NavigationServer2D.map_set_active(m, true)
	NavigationServer2D.map_set_cell_size(m, 1.0)
	return m

func tileset(nav_layers: int, bits: int, corner: bool) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	for i in range(nav_layers):
		ts.add_navigation_layer()
		ts.set_navigation_layer_layers(i, bits)
	var src := TileSetAtlasSource.new()
	src.texture = solid(Color(0, 1, 0, 1))
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src, 0)
	if nav_layers > 0:
		var poly := rect_poly(0, 0, 16, 16) if corner else rect_poly(-8, -8, 16, 16)
		src.get_tile_data(Vector2i(0, 0), 0).set_navigation_polygon(0, poly)
	return ts

func corridor(root: Node2D, ts: TileSet, map: RID, cells: int) -> TileMapLayer:
	var t := TileMapLayer.new()
	t.tile_set = ts
	root.add_child(t)
	t.set_navigation_map(map)
	for x in range(cells):
		t.set_cell(Vector2i(x, 0), 0, Vector2i(0, 0), 0)
	return t

# Waits for a map to be DONE rebuilding, instead of for a number of frames.
# An earlier revision of this file awaited a fixed 8, which is the very habit
# N10/N30 exist to argue against — and it showed: on a starved box the fixed
# wait made five unrelated claims fail because the map simply had not caught up
# yet. Stable iteration id for `quiet` consecutive frames = nothing more is
# coming.
# Waits for a map to be DONE applying an edit, instead of for a number of
# frames. An earlier revision awaited a fixed 8, which is the habit N10/N30
# exist to argue against — and it showed: on a starved box the fixed wait made
# five unrelated claims fail against a map that had simply not caught up.
#
# Three conditions, because each of the first two has a blind spot the other
# covers:
#   * the iteration id must have moved PAST the value held when the edit was
#     made. A "stable" id proves nothing if the rebuild has not STARTED — poll
#     for stability alone and a starved box returns the pre-edit map.
#   * the region count must be the one this edit should produce. The id alone
#     can be satisfied by a DIFFERENT rebuild that was already pending, and
#     then a corridor with a cell erased still answers the full six-cell path.
#   * both must hold for `quiet` consecutive frames.
# Region count is not the thing under test in any claim that calls this (the
# claims are about paths), so waiting on it is not assuming the answer. And it
# is not sufficient on its own either: map_force_update() publishes all six
# regions on a map that still answers no path at all (N12/N12b).
func settle_map(map: RID, expected_regions: int, quiet: int = 3) -> void:
	var start := int(NavigationServer2D.map_get_iteration_id(map))
	var still := 0
	for i in range(FRAME_BUDGET):
		await physics_frame
		var id := int(NavigationServer2D.map_get_iteration_id(map))
		var regions := NavigationServer2D.map_get_regions(map).size()
		if id != start and regions == expected_regions:
			still += 1
			if still >= quiet:
				return
		else:
			still = 0


# The readiness signal for a PATH query is the path query, and nothing else.
#
# settle_map() above waits for the map's own bookkeeping — iteration id moved,
# region count is the one this edit should produce. That is necessary and it is
# still not sufficient: measured on a starved 4.7, a corridor with its middle
# cell erased reported five regions and a moved id while map_get_path() went on
# answering the full six-cell path from the previous mesh. The two are updated
# independently, so a caller that trusts the bookkeeping reads a stale route.
#
# This waits for the ANSWER to stop moving instead — not for the expected
# answer, which would be assuming the result, just for it to stop changing.
func settle_path(map: RID, layers: int = 1, quiet: int = 8) -> PackedVector2Array:
	var last := PackedVector2Array()
	var same := 0
	for i in range(FRAME_BUDGET):
		await physics_frame
		var now := path_on(map, layers)
		if now.size() == last.size() and (now.size() == 0 or now[now.size() - 1].is_equal_approx(last[last.size() - 1])):
			same += 1
			if same >= quiet:
				return now
		else:
			same = 0
			last = now
	return last


func path_on(map: RID, layers: int = 1) -> PackedVector2Array:
	return NavigationServer2D.map_get_path(map, A, B, true, layers)


func _initialize() -> void:
	print("godot ", Engine.get_version_info().string)
	print("---")

	var root := Node2D.new()
	get_root().add_child(root)

	# ---------- the names a Godot 3 tutorial will send you looking for ----------

	check("N1", "there is no Navigation2D node in Godot 4 — the tutorial that tells you to add one is for Godot 3",
		not ClassDB.class_exists("Navigation2D"))
	check("N2", "there is no NavigationPolygonInstance either; the Godot 4 node is NavigationRegion2D",
		not ClassDB.class_exists("NavigationPolygonInstance") and ClassDB.class_exists("NavigationRegion2D"))
	check("N3", "a TileMapLayer never needs either of them: navigation_enabled is on the layer itself and ships ON",
		TileMapLayer.new().navigation_enabled == true)

	# ---------- cause 1: the TileSet has no navigation layer ----------

	var bare := tileset(0, 1, false)
	check("N4", "a TileSet starts with ZERO navigation layers — there is nowhere for a polygon to live",
		bare.get_navigation_layers_count() == 0, bare.get_navigation_layers_count())

	# This is not a silent failure and it is not a stored value either: the
	# engine pushes "Index p_layer_id = 0 is out of bounds" and the read comes
	# back null. In the editor the same fact shows up as a missing tab.
	var bare_src: TileSetAtlasSource = bare.get_source(0)
	var bare_td := bare_src.get_tile_data(Vector2i(0, 0), 0)
	bare_td.set_navigation_polygon(0, rect_poly(-8, -8, 16, 16))
	check("N5", "with no navigation layer, setting a tile's navigation polygon errors and stores nothing",
		bare_td.get_navigation_polygon(0) == null)

	var one := tileset(1, 1, false)
	var one_src: TileSetAtlasSource = one.get_source(0)
	check("N6", "after add_navigation_layer() the same polygon is stored and reads back with its one polygon",
		one_src.get_tile_data(Vector2i(0, 0), 0).get_navigation_polygon(0) != null
		and one_src.get_tile_data(Vector2i(0, 0), 0).get_navigation_polygon(0).get_polygon_count() == 1)

	# ---------- how the map is built out of painted cells ----------

	var map := fresh_map()
	var layer := corridor(root, tileset(1, 1, false), map, 6)
	# ---------- cause 2: the query runs before the map exists ----------

	var first_frame := -1
	var frames_seen := 0
	var regions_at := []
	for i in range(FRAME_BUDGET):
		await physics_frame
		frames_seen += 1
		var pts := path_on(map).size()
		if regions_at.size() < 10:
			regions_at.append(NavigationServer2D.map_get_regions(map).size())
		if first_frame < 0 and pts > 0:
			first_frame = i
			break

	check("N8", "the regions do not exist on the first physics frame either",
		regions_at[0] == 0, "regions per frame: " + str(regions_at))
	check("N9", "one physics frame is NOT enough: the corridor still answers no path",
		regions_at.size() > 1 and first_frame > 0, "first frame with a path: " + str(first_frame))
	# THE claim on this page. Every tutorial that says "await one physics_frame
	# and then ask for the path" was written against a machine where one was
	# enough. What this asserts is the only part that survived measurement:
	# the answer never arrives on frame 0, and the frame it does arrive on is
	# not a number you can write down. The idle reference is REPORTED next to
	# this run's value, never asserted against it — see the table comment for
	# the runs that killed the equality version of this claim.
	var idle_ref: int = FRAMES_BEFORE_PATH_IDLE.get(minor(), -1)
	check("N10", "the frame that answers is not a constant — not of the engine and not of a build; "
		+ "the only safe statement is that it is never frame 0",
		first_frame > 0,
		"first path on frame " + str(first_frame) + " of " + minor()
		+ (", idle reference " + str(idle_ref) if idle_ref >= 0 else ", no idle reference for this build")
		+ ("" if idle_ref < 0 or first_frame == idle_ref else "  <-- differs from the idle reference, which is the point"))
	check("N7", "the settled map holds one region per painted cell (6 cells -> 6 regions) — a TileMapLayer is not one navigation mesh",
		NavigationServer2D.map_get_regions(map).size() == 6,
		NavigationServer2D.map_get_regions(map).size())

	var settled: PackedVector2Array = await settle_path(map)
	check("N11", "once settled, the corridor is walkable end to end",
		settled.size() > 0 and settled[settled.size() - 1].is_equal_approx(B),
		str(settled.size()) + " points, last = " + str(settled[settled.size() - 1] if settled.size() else null))

	# map_force_update() is the usual "just force it" answer, and it half works,
	# which is worse than not working. Two calls DO publish the regions on every
	# build measured — that part is stable and is what N12 asserts. Whether the
	# map then answers a path query is not stable: 4.3 answered, 4.4 and 4.7 did
	# not, and a starved 4.7 did. So the call is not a substitute for waiting,
	# and a green result here is not permission to use it as one (N12b reports
	# what this run got without asserting it).
	var fresh2 := fresh_map()
	var layer2 := corridor(root, tileset(1, 1, false), fresh2, 6)
	await physics_frame
	NavigationServer2D.map_force_update(fresh2)
	NavigationServer2D.map_force_update(fresh2)
	var forced_regions := NavigationServer2D.map_get_regions(fresh2).size()
	var forced := path_on(fresh2).size() > 0
	check("N12", "map_force_update() does publish the regions immediately — six painted cells, six regions, no frame waited",
		forced_regions == 6, str(forced_regions) + " regions on " + minor())
	note("N12b", "...but publishing the regions is not the same as answering a query, and whether it answers "
		+ "is not a property of the build: measured both ways on the same 4.7 binary",
		minor() + " -> " + ("a path came back after force_update" if forced else "no path came back after force_update"))

	# ---------- cause 3: the polygon is authored around the wrong origin ----------

	var m_corner := fresh_map()
	var l_corner := corridor(root, tileset(1, 1, true), m_corner, 1)
	var m_center := fresh_map()
	var l_center := corridor(root, tileset(1, 1, false), m_center, 1)
	await settle_map(m_corner, 1)
	await settle_map(m_center, 1)

	var region0 := NavigationServer2D.map_get_regions(m_center)[0]
	check("N13", "a tile's region is placed at the CELL CENTRE, not at its top-left corner",
		NavigationServer2D.region_get_transform(region0).origin.is_equal_approx(Vector2(8, 8)),
		NavigationServer2D.region_get_transform(region0).origin)
	check("N14", "so an outline authored (0,0)-(16,16) puts the walkable surface half a tile down-right: "
		+ "(4,4), inside the only painted cell, is off the mesh",
		not NavigationServer2D.map_get_closest_point(m_corner, Vector2(4, 4)).is_equal_approx(Vector2(4, 4)),
		NavigationServer2D.map_get_closest_point(m_corner, Vector2(4, 4)))
	check("N15", "...while (20,20), which is in the next cell over and nothing is painted there, IS walkable",
		NavigationServer2D.map_get_closest_point(m_corner, Vector2(20, 20)).is_equal_approx(Vector2(20, 20)),
		NavigationServer2D.map_get_closest_point(m_corner, Vector2(20, 20)))
	check("N16", "the centred outline (-8,-8)-(8,8) puts (4,4) on the mesh",
		NavigationServer2D.map_get_closest_point(m_center, Vector2(4, 4)).is_equal_approx(Vector2(4, 4)),
		NavigationServer2D.map_get_closest_point(m_center, Vector2(4, 4)))
	check("N17", "...and pulls (20,20) back to the cell edge instead of accepting it",
		NavigationServer2D.map_get_closest_point(m_center, Vector2(20, 20)).is_equal_approx(Vector2(16, 16)),
		NavigationServer2D.map_get_closest_point(m_center, Vector2(20, 20)))

	# ---------- cause 4: the layer bitmask nobody sets ----------

	var m_bits := fresh_map()
	var l_bits := corridor(root, tileset(1, 2, false), m_bits, 6)
	await settle_map(m_bits, 6)
	check("N18", "TileSet.set_navigation_layer_layers(0, 2) reaches the region as navigation_layers = 2",
		NavigationServer2D.region_get_navigation_layers(NavigationServer2D.map_get_regions(m_bits)[0]) == 2,
		NavigationServer2D.region_get_navigation_layers(NavigationServer2D.map_get_regions(m_bits)[0]))
	check("N19", "a NavigationAgent2D ships with navigation_layers = 1, so it cannot use that corridor at all",
		NavigationAgent2D.new().navigation_layers == 1 and path_on(m_bits, 1).size() == 0,
		path_on(m_bits, 1).size())
	var bits_path: PackedVector2Array = await settle_path(m_bits, 2)
	check("N20", "the same query asked with layers = 2 walks the whole corridor",
		bits_path.size() > 0, bits_path.size())

	# ---------- cause 5: the switch on the layer ----------

	layer.navigation_enabled = false
	await settle_map(map, 0)
	check("N21", "navigation_enabled = false removes every region — the cells stay painted, the map empties",
		NavigationServer2D.map_get_regions(map).size() == 0 and layer.get_used_cells().size() == 6,
		str(NavigationServer2D.map_get_regions(map).size()) + " regions, " + str(layer.get_used_cells().size()) + " cells")
	layer.navigation_enabled = true
	await settle_map(map, 6)
	check("N22", "turning it back on restores them without repainting anything",
		NavigationServer2D.map_get_regions(map).size() == 6,
		NavigationServer2D.map_get_regions(map).size())

	# ---------- the failure that does not look like a failure ----------

	layer.erase_cell(Vector2i(3, 0))
	await settle_map(map, 5)
	var broken: PackedVector2Array = await settle_path(map)
	check("N23", "erasing one cell mid-corridor does not empty the path — it TRUNCATES it",
		broken.size() > 0 and not broken[broken.size() - 1].is_equal_approx(B),
		str(broken.size()) + " points, last = " + str(broken[broken.size() - 1] if broken.size() else null))
	check("N24", "the truncated path stops at the gap, so `if path.is_empty()` never fires and the agent walks into the wall",
		broken.size() > 0 and broken[broken.size() - 1].x < B.x,
		broken[broken.size() - 1] if broken.size() else null)
	layer.set_cell(Vector2i(3, 0), 0, Vector2i(0, 0), 0)
	await settle_map(map, 6)
	var repainted: PackedVector2Array = await settle_path(map)
	check("N25", "repainting the cell restores the end-to-end path",
		repainted.size() > 0 and repainted[repainted.size() - 1].is_equal_approx(B),
		repainted.size())

	# ---------- a tile with no polygon is a hole, not a wall ----------

	var ts_hole := tileset(1, 1, false)
	var hole_src: TileSetAtlasSource = ts_hole.get_source(0)
	hole_src.create_tile(Vector2i(1, 0))   # second tile, no navigation polygon on it
	var m_hole := fresh_map()
	var l_hole := TileMapLayer.new()
	l_hole.tile_set = ts_hole
	root.add_child(l_hole)
	l_hole.set_navigation_map(m_hole)
	for x in range(6):
		l_hole.set_cell(Vector2i(x, 0), 0, Vector2i(1, 0) if x == 3 else Vector2i(0, 0), 0)
	await settle_map(m_hole, 5)
	check("N28", "a painted cell whose tile carries no navigation polygon produces NO region: "
		+ "six cells, five regions, and the sixth is a hole in the middle of the corridor",
		NavigationServer2D.map_get_regions(m_hole).size() == 5 and l_hole.get_used_cells().size() == 6,
		str(NavigationServer2D.map_get_regions(m_hole).size()) + " regions from " + str(l_hole.get_used_cells().size()) + " cells")
	var hole_path: PackedVector2Array = await settle_path(m_hole)
	check("N29", "and the path over that hole is truncated exactly like an erased cell — same symptom, different cause",
		hole_path.size() > 0 and not hole_path[hole_path.size() - 1].is_equal_approx(B),
		str(hole_path.size()) + " points, last = " + str(hole_path[hole_path.size() - 1] if hole_path.size() else null))

	# ---------- the fix that is not your fix ----------

	NavigationServer2D.map_set_use_edge_connections(map, false)
	await settle_map(map, 6)
	var edge_path: PackedVector2Array = await settle_path(map)
	check("N26", "edge connections OFF does not break a tilemap corridor: neighbouring cells share an exact edge, "
		+ "so this setting is not the cause you are looking for",
		edge_path.size() > 0, edge_path.size())
	NavigationServer2D.map_set_use_edge_connections(map, true)

	check("N27", "make_polygons_from_outlines() still works but is deprecated; "
		+ "NavigationServer2D.bake_from_source_geometry_data() is the Godot 4 baking entry point",
		ClassDB.class_has_method("NavigationServer2D", "bake_from_source_geometry_data", true))

	# ---------- the pattern that does not count frames ----------

	# Everything above says the count is unsafe. This is what to do instead, and
	# it is asserted rather than recommended: poll the map's iteration id, which
	# is the number the server bumps when it has rebuilt, and ask for the path
	# once it has moved. Same code on 4.3, 4.4 and 4.7, no table, and it is
	# still correct on the starved run where a hardcoded await is not.
	check("N30a", "NavigationServer2D exposes map_get_iteration_id — the map tells you when it has rebuilt, so nothing has to guess",
		ClassDB.class_has_method("NavigationServer2D", "map_get_iteration_id", true))

	var m_poll := fresh_map()
	var l_poll := corridor(root, tileset(1, 1, false), m_poll, 6)
	var id_before := NavigationServer2D.map_get_iteration_id(m_poll)
	var polled := PackedVector2Array()
	var waited := 0
	while waited < FRAME_BUDGET:
		await physics_frame
		waited += 1
		if NavigationServer2D.map_get_iteration_id(m_poll) == id_before:
			continue
		polled = path_on(m_poll)
		if polled.size() > 0:
			break
	check("N30", "polling the iteration id walks the corridor end to end without any per-build number in the code",
		polled.size() > 0 and polled[polled.size() - 1].is_equal_approx(B),
		"id " + str(id_before) + " -> " + str(NavigationServer2D.map_get_iteration_id(m_poll))
		+ " after " + str(waited) + " frame(s), " + str(polled.size()) + " points")

	print("---")
	print("TILE NAVIGATION: ", checks - failures, " passed / ", failures, " failed")
	quit(1 if failures > 0 else 0)
