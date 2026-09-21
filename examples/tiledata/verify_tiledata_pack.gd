extends SceneTree

# Engine gate for the free tile-data pack (meadow / volcano / swamp / snow).
#
# The README promises eight TileSets whose six tiles each carry five custom data
# layers already filled in — ground, move_cost, walkable, damage, footstep — and
# that a game can read them back from a painted map and feed an AStarGrid2D with
# them. So the claims are not read off the .tres: a 16x10 map is painted into a
# real TileMapLayer with set_cells_terrain_connect, every cell is asked through
# get_cell_tile_data(cell).get_custom_data(name), the pack's own
# tile_data_example.gd is run against the same layer, and the A* path it builds
# is compared with a Dijkstra over the same data.
#
# The traps section (X1..X9) runs once, on fresh copies of the first TileSet
# loaded with CACHE_MODE_IGNORE, and measures the ways reading tile data goes
# wrong without a word — each one is a line in the README only because it is
# measured here.
#
# Every expectation (kinds, values, map, start, goal, bridge, ford) is read from
# manifest.json. `--invert` shifts one expectation (the move_cost expected at the
# start cell) by +1 on the first TileSet, so the gate must FAIL.

var failures := 0
var checked := 0

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

func v2i(a: Array) -> Vector2i:
	return Vector2i(int(a[0]), int(a[1]))

# the role of every map cell, from the manifest: fill, then the rectangles in order
func plan(m: Dictionary) -> Dictionary:
	var out := {}
	for y in range(int(m["h"])):
		for x in range(int(m["w"])):
			out[Vector2i(x, y)] = int(m["fill"])
	for r in m["rects"]:
		for y in range(int(r["y0"]), int(r["y1"]) + 1):
			for x in range(int(r["x0"]), int(r["x1"]) + 1):
				out[Vector2i(x, y)] = int(r["role"])
	return out

func cells_of(p: Dictionary, role: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for c in p:
		if p[c] == role:
			out.append(c)
	out.sort()
	return out

func paint(layer: TileMapLayer, p: Dictionary, roles: int, ignore_empty: bool) -> void:
	for role in range(roles):
		layer.set_cells_terrain_connect(cells_of(p, role), 0, role, ignore_empty)

# what the manifest says a kind's value for `layer` is, typed as the layer is
func expect(kind: Dictionary, layer: Dictionary) -> Variant:
	var v: Variant = kind[layer["name"]]
	match String(layer["type"]):
		"float":
			return float(v)
		"int":
			return int(v)
		"bool":
			return bool(v)
	return String(v)

# an AStarGrid2D over the map rect, 4-neighbour. `use_data`: solid from walkable
# and weight from move_cost; `use_solid` alone: solid from walkable, every weight 1.
func grid_from(layer: TileMapLayer, rect: Rect2i, T: int, use_solid: bool, use_weight: bool) -> AStarGrid2D:
	var g := AStarGrid2D.new()
	g.region = rect
	g.cell_size = Vector2(T, T)
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	g.update()
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			var td := layer.get_cell_tile_data(c)
			if td == null:
				g.set_point_solid(c, true)
				continue
			if use_solid:
				g.set_point_solid(c, not td.get_custom_data("walkable"))
			if use_weight:
				g.set_point_weight_scale(c, td.get_custom_data("move_cost"))
	return g

# the cost A* minimises with DIAGONAL_MODE_NEVER: the move_cost of every cell
# entered, i.e. every cell of the path but the first
func cost_of(layer: TileMapLayer, path: Array) -> float:
	var s := 0.0
	for i in range(1, path.size()):
		s += float(layer.get_cell_tile_data(path[i]).get_custom_data("move_cost"))
	return s

func count_where(layer: TileMapLayer, path: Array, layer_name: String, pred: Callable) -> int:
	var n := 0
	for c in path:
		if pred.call(layer.get_cell_tile_data(c).get_custom_data(layer_name)):
			n += 1
	return n

# the true minimum, independent of AStarGrid2D: Dijkstra over the painted cells,
# entering a cell costs its move_cost, walkable = false cells are closed
func dijkstra(layer: TileMapLayer, rect: Rect2i, from: Vector2i, to: Vector2i) -> float:
	var dist := {from: 0.0}
	var done := {}
	while true:
		var best := Vector2i(-1, -1)
		var bd := INF
		for c in dist:
			if not done.has(c) and dist[c] < bd:
				bd = dist[c]
				best = c
		if bd == INF:
			return INF
		if best == to:
			return bd
		done[best] = true
		for d in DIRS:
			var n: Vector2i = best + d
			if not rect.has_point(n):
				continue
			var td := layer.get_cell_tile_data(n)
			if td == null or not td.get_custom_data("walkable"):
				continue
			var nd: float = bd + float(td.get_custom_data("move_cost"))
			if nd < float(dist.get(n, INF)):
				dist[n] = nd
	return INF

func has_any(path: Array, cells: Array) -> bool:
	for c in cells:
		if v2i(c) in path:
			return true
	return false

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://tiledata/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("TILEDATA: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("TILEDATA: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d tile-data tilesets" % (man as Array).size())
	var example_script: GDScript = load("res://tiledata/tile_data_example.gd")

	var first := true
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var kinds: Array = entry["kinds"]
		var layers: Array = entry["layers"]
		var ts: TileSet = load("res://tiledata/%s.tres" % base)
		ck("D1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("D2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("D3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"])
			and src.get_tiles_count() == int(entry["tiles"]) and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: %dx%d sheet, %d tiles, square cell %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"]), int(entry["tiles"]), T, T])
		var names_ok := ts.get_terrain_sets_count() == 1 and ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES and ts.get_terrains_count(0) == kinds.size()
		for kd in kinds:
			if names_ok and ts.get_terrain_name(0, int(kd["terrain"])) != kd["terrain_name"]:
				names_ok = false
		ck("D4", names_ok, "%s: one Match Sides terrain set with the %d terrains the manifest names, in role order (%s ... %s)"
			% [base, kinds.size(), kinds[0]["terrain_name"], kinds[kinds.size() - 1]["terrain_name"]])
		var lay_ok := ts.get_custom_data_layers_count() == layers.size()
		for i in range(layers.size()):
			if lay_ok and (ts.get_custom_data_layer_name(i) != layers[i]["name"] or ts.get_custom_data_layer_type(i) != int(layers[i]["variant_type"])
					or ts.get_custom_data_layer_by_name(layers[i]["name"]) != i):
				lay_ok = false
		ck("D5", lay_ok, "%s: %d custom data layers, named and typed as the manifest says, each found by name at its own index (ground:String, move_cost:float, walkable:bool, damage:int, footstep:String)"
			% [base, ts.get_custom_data_layers_count()])

		# --- every tile, read back through TileData ------------------------------
		var vals_ok := 0
		var vals_n := 0
		var terr_ok := 0
		for kd in kinds:
			var td := src.get_tile_data(v2i(kd["atlas"]), 0)
			if td == null:
				continue
			for l in layers:
				vals_n += 1
				var got: Variant = td.get_custom_data(l["name"])
				if typeof(got) == int(l["variant_type"]) and got == expect(kd, l):
					vals_ok += 1
			var sides_empty := true
			for s in SIDES:
				if td.get_terrain_peering_bit(s) != -1:
					sides_empty = false
			if td.terrain_set == 0 and td.terrain == int(kd["terrain"]) and sides_empty:
				terr_ok += 1
		ck("D6", vals_n == kinds.size() * layers.size() and vals_ok == vals_n,
			"%s: every tile's %d custom data values read back with the manifest's value AND the layer's type — none left at the default by accident (%d/%d)"
				% [base, layers.size(), vals_ok, vals_n])
		ck("D7", terr_ok == kinds.size(),
			"%s: each of the %d tiles is its own terrain, with all four side peering bits empty (-1), so neighbours never disagree about an edge (%d/%d)"
				% [base, kinds.size(), terr_ok, kinds.size()])

		# --- painted into the running tree ------------------------------------------
		var m: Dictionary = entry["map"]
		var p := plan(m)
		var rect := Rect2i(0, 0, int(m["w"]), int(m["h"]))
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		paint(layer, p, kinds.size(), false)
		var painted_ok := 0
		for c in p:
			var td := layer.get_cell_tile_data(c)
			if td != null and td.terrain == p[c] and layer.get_cell_atlas_coords(c) == v2i(kinds[p[c]]["atlas"]):
				painted_ok += 1
		ck("D8", painted_ok == p.size(),
			"%s: set_cells_terrain_connect(cells, 0, kind, false), one call per kind, painted the %dx%d map with every cell the kind asked for (%d/%d)"
				% [base, int(m["w"]), int(m["h"]), painted_ok, p.size()])

		var dflt := TileMapLayer.new()
		dflt.tile_set = ts
		root.add_child(dflt)
		for role in range(kinds.size()):
			dflt.set_cells_terrain_connect(cells_of(p, role), 0, role)
		var dflt_ok := 0
		for c in p:
			if dflt.get_cell_atlas_coords(c) == layer.get_cell_atlas_coords(c):
				dflt_ok += 1
		root.remove_child(dflt)
		dflt.free()
		ck("D9", dflt_ok == p.size(),
			"%s: the same calls WITHOUT the 4th argument (ignore_empty_terrains = true) paint the identical map (%d/%d) — with every side empty, the argument has nothing to decide"
				% [base, dflt_ok, p.size()])

		# --- the per-cell read the README's snippet does ---------------------------
		var cost_ok := 0
		var all_ok := 0
		var start := v2i(m["start"])
		for c in p:
			var kd: Dictionary = kinds[p[c]]
			var want_cost := float(kd["move_cost"]) + (1.0 if invert and first and c == start else 0.0)
			var td := layer.get_cell_tile_data(c)
			if td == null:
				continue
			if td.get_custom_data("move_cost") == want_cost:
				cost_ok += 1
			var every := true
			for l in layers:
				if td.get_custom_data(l["name"]) != expect(kd, l):
					every = false
			if every:
				all_ok += 1
		ck("D10", cost_ok == p.size() and all_ok == p.size(),
			"%s: for every painted cell, get_cell_tile_data(cell).get_custom_data(\"move_cost\") is that cell's kind's cost (%d/%d), and all five layers match (%d/%d)"
				% [base, cost_ok, p.size(), all_ok, p.size()])

		var outside := Vector2i(int(m["w"]) + 3, 1)
		var null_out := layer.get_cell_tile_data(outside) == null and layer.get_cell_source_id(outside) == -1
		var erase_at := Vector2i(0, 0)
		layer.erase_cell(erase_at)
		var null_erased := layer.get_cell_tile_data(erase_at) == null
		var one: Array[Vector2i] = [erase_at]
		layer.set_cells_terrain_connect(one, 0, p[erase_at], false)
		ck("D11", null_out and null_erased and layer.get_cell_tile_data(erase_at) != null,
			"%s: an empty cell %s and an erased cell %s both return get_cell_tile_data() == null — calling get_custom_data() on it is a null-instance error, so check first"
				% [base, str(outside), str(erase_at)])

		# player position -> cell: centre and a point just inside each corner of every cell
		var pos_ok := 0
		var pos_n := 0
		var e := T * 0.01
		for c in p:
			var o := Vector2(c.x * T, c.y * T)
			for q in [Vector2(T * 0.5, T * 0.5), Vector2(e, e), Vector2(T - e, e), Vector2(e, T - e), Vector2(T - e, T - e)]:
				pos_n += 1
				var got_cell := layer.local_to_map(o + q)
				var td := layer.get_cell_tile_data(got_cell)
				if got_cell == c and td != null and td.get_custom_data("ground") == kinds[p[c]]["ground"]:
					pos_ok += 1
		ck("D12", pos_ok == pos_n,
			"%s: on a layer at the origin, local_to_map() of a position anywhere inside a cell — its centre or %.2f px inside any corner — is that cell, and its ground reads right (%d/%d)"
				% [base, e, pos_ok, pos_n])

		# the same map on a MOVED and SCALED layer, with the pack's own example
		var moved := TileMapLayer.new()
		moved.tile_set = ts
		moved.position = Vector2(123.5, -47.0)
		moved.scale = Vector2(3, 3)
		root.add_child(moved)
		paint(moved, p, kinds.size(), false)
		var ex: Node = example_script.new()
		ex.set("layer", moved)
		root.add_child(ex)
		var naive_ok := 0
		var local_ok := 0
		var ex_ok := 0
		for c in p:
			var g := moved.to_global(moved.map_to_local(c))
			if moved.local_to_map(g) == c:
				naive_ok += 1
			if moved.local_to_map(moved.to_local(g)) == c:
				local_ok += 1
			if ex.call("ground_at", g) == kinds[p[c]]["ground"]:
				ex_ok += 1
		ck("D13", local_ok == p.size() and ex_ok == p.size() and naive_ok < p.size() / 10,
			"%s: on a layer moved to (123.5,-47) and scaled 3x, local_to_map(to_local(global_position)) finds the cell for %d/%d cell centres and tile_data_example.gd's ground_at() reads the right ground for %d/%d; passing global_position straight to local_to_map() finds it for %d/%d"
				% [base, local_ok, p.size(), ex_ok, p.size(), naive_ok, p.size()])

		# --- A* fed from the data ------------------------------------------------------
		var goal := v2i(m["goal"])
		var gd := grid_from(layer, rect, T, true, true)
		var dpath: Array = Array(gd.get_id_path(start, goal))
		var blocked_n := count_where(layer, dpath, "walkable", func(v): return not v)
		var hurt_n := count_where(layer, dpath, "damage", func(v): return int(v) > 0)
		ck("D14", dpath.size() > 0 and dpath[0] == start and dpath[dpath.size() - 1] == goal and blocked_n == 0 and hurt_n == 0
			and has_any(dpath, m["bridge"]),
			"%s: AStarGrid2D fed walkable -> set_point_solid and move_cost -> set_point_weight_scale routes %s -> %s over the bridge: %d cells, 0 on a walkable = false cell (%d), 0 on a damage > 0 cell (%d)"
				% [base, str(start), str(goal), dpath.size(), blocked_n, hurt_n])

		var dcost := cost_of(layer, dpath)
		var best := dijkstra(layer, rect, start, goal)
		var gw := grid_from(layer, rect, T, true, false)
		var wpath: Array = Array(gw.get_id_path(start, goal))
		var wcost := cost_of(layer, wpath)
		var w_hurt := count_where(layer, wpath, "damage", func(v): return int(v) > 0)
		ck("D15", is_equal_approx(dcost, best) and dcost < wcost and wpath.size() < dpath.size() and w_hurt > 0 and has_any(wpath, m["ford"]),
			"%s: the data path costs %.1f — the true minimum, Dijkstra over the same data finds %.1f. Fed walkable only (every weight 1) the grid takes the shorter %d-cell way through the ford and across %d hazard cells, costing %.1f"
				% [base, dcost, best, wpath.size(), w_hurt, wcost])

		var gu := AStarGrid2D.new()
		gu.region = rect
		gu.cell_size = Vector2(T, T)
		gu.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
		gu.update()
		var upath: Array = Array(gu.get_id_path(start, goal))
		var u_blocked := count_where(layer, upath, "walkable", func(v): return not v)
		ck("D16", upath.size() == absi(goal.x - start.x) + absi(goal.y - start.y) + 1 and u_blocked > 0,
			"%s: the same grid with NO data is a straight %d-cell line that walks across %d walkable = false cells — nothing about the tiles reaches A* unless you copy it in"
				% [base, upath.size(), u_blocked])

		var exg: AStarGrid2D = ex.call("build_astar")
		var expath: Array = Array(exg.get_id_path(start, goal))
		ck("D17", expath == dpath and is_equal_approx(cost_of(layer, expath), dcost),
			"%s: tile_data_example.gd's build_astar() on the moved, scaled layer returns the same %d-cell path at the same cost (%.1f)"
				% [base, expath.size(), cost_of(layer, expath)])
		root.remove_child(ex)
		ex.free()
		root.remove_child(moved)
		moved.free()

		# the grid is a copy: paint the bridge shut and it does not notice until refed
		var bridge_cells: Array[Vector2i] = []
		for b in m["bridge"]:
			bridge_cells.append(v2i(b))
		layer.set_cells_terrain_connect(bridge_cells, 0, kinds.size() - 1, false)
		var stale: Array = Array(gd.get_id_path(start, goal))
		var stale_blocked := count_where(layer, stale, "walkable", func(v): return not v)
		for c in bridge_cells:
			var td := layer.get_cell_tile_data(c)
			gd.set_point_solid(c, not td.get_custom_data("walkable"))
			gd.set_point_weight_scale(c, td.get_custom_data("move_cost"))
		var refed: Array = Array(gd.get_id_path(start, goal))
		var r_cost := cost_of(layer, refed)
		ck("D18", stale == dpath and stale_blocked == bridge_cells.size() and has_any(refed, m["ford"])
			and count_where(layer, refed, "walkable", func(v): return not v) == 0 and r_cost > dcost and is_equal_approx(r_cost, dijkstra(layer, rect, start, goal)),
			"%s: with the bridge painted as %s the old grid still returns the old path across %d now-blocked cells; refed from get_cell_tile_data() for those %d cells it goes by the ford at %.1f, the new minimum"
				% [base, kinds[kinds.size() - 1]["ground"], stale_blocked, bridge_cells.size(), r_cost])
		layer.set_cells_terrain_connect(bridge_cells, 0, 0, false)

		# TileData is shared by every cell painted with that tile, and IS the TileSet's tile
		var td0 := layer.get_cell_tile_data(start)
		var was: float = td0.get_custom_data("move_cost")
		td0.set_custom_data("move_cost", 99.0)
		var same_tile := 0
		var changed := 0
		for c in p:
			if layer.get_cell_atlas_coords(c) == layer.get_cell_atlas_coords(start):
				same_tile += 1
				if layer.get_cell_tile_data(c).get_custom_data("move_cost") == 99.0:
					changed += 1
		var in_set: float = src.get_tile_data(layer.get_cell_atlas_coords(start), 0).get_custom_data("move_cost")
		td0.set_custom_data("move_cost", was)
		ck("D19", same_tile > 1 and changed == same_tile and in_set == 99.0,
			"%s: set_custom_data() on the TileData of ONE cell %s changed all %d cells painted with that tile, and the TileSet's own tile — custom data is per tile, not per cell; keep per-cell state in a Dictionary"
				% [base, str(start), changed])

		first = false
		root.remove_child(layer)
		layer.free()
		ts = null

	traps((man as Array)[0])

	if failures == 0:
		print("TILEDATA %d/%d PASS" % [checked, checked])
	else:
		print("TILEDATA: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)

# --- measured once, on private copies of the first TileSet -----------------------
func traps(entry: Dictionary) -> void:
	var path := "res://tiledata/%s.tres" % entry["base"]
	var fresh := func() -> TileSet: return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var kinds: Array = entry["kinds"]
	var ts: TileSet = fresh.call()
	var src := ts.get_source(0) as TileSetAtlasSource
	var td := src.get_tile_data(v2i(kinds[0]["atlas"]), 0)

	# X1: a misspelled layer name. Built at run time so no scanner mistakes this
	# file for a script that reads the misspelled name.
	var wrong := "move_" + "cst"
	var got: Variant = td.get_custom_data(wrong)
	ck("X1", got == null and typeof(got) == TYPE_NIL and ts.get_custom_data_layer_by_name(wrong) == -1,
		"get_custom_data(\"%s\") — one letter off — returns null (type %d), not 0.0, and prints one ERROR 'TileSet has no layer with name'; get_custom_data_layer_by_name() returns -1 without printing anything, so that is the way to ask first"
			% [wrong, typeof(got)])

	# X2: by id works, until a layer before it is removed
	var by_id_ok := 0
	for kd in kinds:
		var t := src.get_tile_data(v2i(kd["atlas"]), 0)
		if t.get_custom_data_by_layer_id(1) == t.get_custom_data("move_cost"):
			by_id_ok += 1
	var ts2: TileSet = fresh.call()
	var td2 := (ts2.get_source(0) as TileSetAtlasSource).get_tile_data(v2i(kinds[0]["atlas"]), 0)
	ts2.remove_custom_data_layer(0)
	var shifted: Variant = td2.get_custom_data_by_layer_id(1)
	ck("X2", by_id_ok == kinds.size() and typeof(shifted) == TYPE_BOOL and td2.get_custom_data("move_cost") == float(kinds[0]["move_cost"]),
		"get_custom_data_by_layer_id(1) equals get_custom_data(\"move_cost\") on all %d tiles; remove layer 0 and id 1 returns %s (walkable, a bool) while the name still returns %.1f — ids are positions, names are not"
			% [by_id_ok, var_to_str(shifted), float(td2.get_custom_data("move_cost"))])

	# X3: a tile added after the layers were filled, and an alternative tile
	var ts3: TileSet = fresh.call()
	var src3 := ts3.get_source(0) as TileSetAtlasSource
	var cols := src3.texture.get_width() / ts3.tile_size.x
	var rows := src3.texture.get_height() / ts3.tile_size.y
	var sheet_img := src3.texture.get_image()
	sheet_img.convert(Image.FORMAT_RGBA8)   # blit_rect refuses two different formats
	var img := Image.create((cols + 1) * ts3.tile_size.x, rows * ts3.tile_size.y, false, Image.FORMAT_RGBA8)
	img.blit_rect(sheet_img, Rect2i(Vector2i.ZERO, sheet_img.get_size()), Vector2i.ZERO)
	src3.texture = ImageTexture.create_from_image(img)
	var added := Vector2i(cols, 0)
	src3.create_tile(added)
	var nt := src3.get_tile_data(added, 0)
	var alt := src3.create_alternative_tile(v2i(kinds[0]["atlas"]))
	var at := src3.get_tile_data(v2i(kinds[0]["atlas"]), alt)
	var defaults := [nt.get_custom_data("ground"), nt.get_custom_data("move_cost"), nt.get_custom_data("walkable"), nt.get_custom_data("damage"), nt.get_custom_data("footstep")]
	var alt_defaults := [at.get_custom_data("ground"), at.get_custom_data("move_cost"), at.get_custom_data("walkable"), at.get_custom_data("damage"), at.get_custom_data("footstep")]
	ck("X3", defaults == ["", 0.0, false, 0, ""] and alt_defaults == defaults and nt.terrain == -1,
		"a tile created after the layers were filled reads %s — and so does a new alternative (e.g. flipped) of a filled tile. Nothing warns: the tile is a free (move_cost 0), unwalkable, nameless ground with no terrain"
			% var_to_str(defaults))

	# X4: move_cost 0.0 is a weight AStarGrid2D takes without a word — and below
	# 1.0 the default heuristic overestimates, so the path stops being the cheapest.
	# (Written first as "A* goes out of its way to use the free row"; measured on
	# 4.3, 4.4 and 4.7, it does the opposite.)
	var g := AStarGrid2D.new()
	g.region = Rect2i(0, 0, 5, 3)
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	g.update()
	var straight: Array = Array(g.get_id_path(Vector2i(0, 0), Vector2i(4, 0)))
	for x in range(5):
		g.set_point_weight_scale(Vector2i(x, 1), 0.0)
	var zero_w := g.get_point_weight_scale(Vector2i(2, 1))
	var got0: Array = Array(g.get_id_path(Vector2i(0, 0), Vector2i(4, 0)))
	var free_route: Array = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(4, 0)]
	var wcost := func(pth: Array) -> float:
		var s := 0.0
		for i in range(1, pth.size()):
			s += g.get_point_weight_scale(pth[i])
		return s
	var got_cost: float = wcost.call(got0)
	var free_cost: float = wcost.call(free_route)
	ck("X4", zero_w == 0.0 and straight.size() == 5 and got0 == straight and got_cost == 4.0 and free_cost == 1.0,
		"set_point_weight_scale(cell, 0.0) — what an unfilled move_cost feeds it — is accepted with no error (reads back %.1f), and the path is no longer the cheapest: A* returns the straight %d-cell row costing %.1f while the route along the free row costs %.1f. Below 1.0 the default heuristic overestimates; keep every move_cost >= 1"
			% [zero_w, got0.size(), got_cost, free_cost])

	# X5: changing region and calling update() again wipes solid and weights
	var g2 := AStarGrid2D.new()
	g2.region = Rect2i(0, 0, 4, 1)
	g2.update()
	g2.set_point_solid(Vector2i(1, 0), true)
	g2.set_point_weight_scale(Vector2i(2, 0), 5.0)
	g2.update()
	var kept := g2.is_point_solid(Vector2i(1, 0)) and g2.get_point_weight_scale(Vector2i(2, 0)) == 5.0
	g2.region = Rect2i(0, 0, 5, 1)
	g2.update()
	var wiped := not g2.is_point_solid(Vector2i(1, 0)) and g2.get_point_weight_scale(Vector2i(2, 0)) == 1.0
	ck("X5", kept and wiped,
		"update() with the same region keeps solid points and weights; change the region (the map grew) and update() resets every point to walkable, weight 1.0 — refeed the whole grid after resizing it")

	# X6: the default diagonal mode squeezes between two solid cells that touch at a corner
	var g3 := AStarGrid2D.new()
	g3.region = Rect2i(0, 0, 2, 2)
	g3.update()
	var mode0 := g3.diagonal_mode
	g3.set_point_solid(Vector2i(1, 0), true)
	g3.set_point_solid(Vector2i(0, 1), true)
	var squeeze: Array = Array(g3.get_id_path(Vector2i(0, 0), Vector2i(1, 1)))
	g3.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	g3.update()
	g3.set_point_solid(Vector2i(1, 0), true)
	g3.set_point_solid(Vector2i(0, 1), true)
	var none: Array = Array(g3.get_id_path(Vector2i(0, 0), Vector2i(1, 1)))
	ck("X6", mode0 == AStarGrid2D.DIAGONAL_MODE_ALWAYS and squeeze == [Vector2i(0, 0), Vector2i(1, 1)] and none.is_empty(),
		"AStarGrid2D's default diagonal_mode is ALWAYS (%d): between two solid cells that touch only at a corner it returns the 2-cell diagonal %s; with DIAGONAL_MODE_NEVER there is no path"
			% [mode0, str(squeeze)])

	# X7: set_custom_data() with the wrong type is stored as that type, silently —
	# and what a save turns it into depends on whether Godot can convert it
	var ts4: TileSet = fresh.call()
	var td4 := (ts4.get_source(0) as TileSetAtlasSource).get_tile_data(v2i(kinds[0]["atlas"]), 0)
	td4.set_custom_data("move_cost", "7")
	td4.set_custom_data("walkable", "no")
	var kept_type := typeof(td4.get_custom_data("move_cost"))
	var kept_type2 := typeof(td4.get_custom_data("walkable"))
	var saved := ResourceSaver.save(ts4, "user://x7_resaved.tres")
	var ts5: TileSet = ResourceLoader.load("user://x7_resaved.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	var td5 := (ts5.get_source(0) as TileSetAtlasSource).get_tile_data(v2i(kinds[0]["atlas"]), 0)
	var back_cost: Variant = td5.get_custom_data("move_cost")
	var back_walk: Variant = td5.get_custom_data("walkable")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://x7_resaved.tres"))
	ck("X7", kept_type == TYPE_STRING and kept_type2 == TYPE_STRING and saved == OK
		and typeof(back_cost) == TYPE_FLOAT and back_cost == 7.0 and back_walk == null,
		"set_custom_data(\"move_cost\", \"7\") on a float layer and (\"walkable\", \"no\") on a bool layer both store a String (type %d, %d) with no error; saved and loaded again, \"7\" comes back as the float %s but \"no\" comes back null — the null is what check_tileset_custom_data.gd names TYPE-MISMATCH"
			% [kept_type, kept_type2, var_to_str(back_cost)])

	# X8: TileData.has_custom_data() exists from 4.4 on
	var vi := Engine.get_version_info()
	var newer := int(vi["major"]) > 4 or (int(vi["major"]) == 4 and int(vi["minor"]) >= 4)
	var has_it := ClassDB.class_has_method("TileData", "has_custom_data")
	ck("X8", has_it == newer,
		"TileData.has_custom_data() is %s on %d.%d — code that must run on 4.3 asks tile_set.get_custom_data_layer_by_name(name) >= 0 instead"
			% ["present" if has_it else "absent", int(vi["major"]), int(vi["minor"])])

	# X9: a layer added from code has no type and no name until you give it both
	var t9 := TileSet.new()
	t9.tile_size = ts.tile_size
	t9.add_custom_data_layer()
	var s9 := TileSetAtlasSource.new()
	s9.texture = src.texture
	s9.texture_region_size = ts.tile_size
	t9.add_source(s9)
	s9.create_tile(Vector2i(0, 0))
	var v9: Variant = s9.get_tile_data(Vector2i(0, 0), 0).get_custom_data_by_layer_id(0)
	ck("X9", t9.get_custom_data_layer_type(0) == TYPE_NIL and t9.get_custom_data_layer_name(0) == "" and v9 == null,
		"add_custom_data_layer() creates a layer of type Nil (%d) with an empty name, and a tile reads %s from it — check_tileset_custom_data.gd names these LAYER-NO-TYPE and LAYER-UNNAMED"
			% [t9.get_custom_data_layer_type(0), var_to_str(v9)])
