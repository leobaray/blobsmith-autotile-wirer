extends SceneTree

# Engine gate for the free light-occluder pack (dungeon / crypt / forest / scifi).
#
# Two modes, one file, both run by verify_occluder_pack.sh:
#
#   (default, --headless)  what the ENGINE says about the tiles: every wall tile
#       reports its occluder through the running version's API (4.3: one per
#       layer, get_occluder; 4.4+: get_occluder_polygons_count /
#       get_occluder_polygon), floors report none, the room painted into a live
#       TileMapLayer reports the occluder on every wall cell and on no floor cell,
#       the physics server finds the walls, and the file format is re-measured
#       both ways (the 4.3 key the pack uses loads everywhere; the 4.4+ key loads
#       as NOTHING on 4.3; re-saving in 4.4+ writes the 4.4+ key).
#
#   --render  (needs a real GL context: the sh runs it under xvfb-run with
#       --rendering-driver opengl3)  whether the SHADOW is there. The headless
#       renderer is a dummy: it draws nothing and exposes no query for the canvas
#       light occluders a TileMapLayer hands the RenderingServer, so a shadow
#       cannot be observed --headless. Here the room is rendered into a
#       SubViewport three times — light off, light with shadows, light without —
#       and every floor pixel is classified lit/dark and compared with plain
#       geometry: is the segment from the light to that pixel blocked by a wall
#       cell? Pixels within 1 px of a shadow edge are left out (a pixel is
#       counted only when the segment clears every wall by 1 px or crosses one
#       by 1 px). Then the traps: shadow_enabled off, occlusion light_mask not
#       matching shadow_item_cull_mask, no occlusion layer, the 4.4+ receiver
#       rule, occlusion_enabled, a light with no texture, a polygon from (0,0).
#
# Every expectation (room, light, sizes, names, masks) is read from manifest.json.
# `--invert` shifts one expectation per mode (headless: one more occluding cell
# than there are walls, on the first TileSet; render: BEHIND expected lit), so
# the gate must FAIL.

var failures := 0
var checked := 0
var invert := false
var render := false

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

func minor() -> int:
	return int(Engine.get_version_info().minor)

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

# the occluders of one tile on layer 0, through the API this version has
func occluders(td: TileData) -> Array:
	var out := []
	if td.has_method("get_occluder_polygons_count"):
		for i in range(int(td.call("get_occluder_polygons_count", 0))):
			var p: OccluderPolygon2D = td.call("get_occluder_polygon", 0, i)
			if p != null:
				out.append(p)
	else:
		var p: OccluderPolygon2D = td.get_occluder(0)
		if p != null:
			out.append(p)
	return out

func full_cell(p: OccluderPolygon2D, T: int) -> bool:
	if p == null or p.polygon.size() != 4 or not is_equal_approx(poly_area(p.polygon), float(T * T)):
		return false
	for v in p.polygon:
		if absf(v.x) > T * 0.5 + 0.001 or absf(v.y) > T * 0.5 + 0.001:
			return false
	return true

# the room plan: cell -> terrain (0 floor, 1 wall), from the manifest
func plan(room: Dictionary) -> Dictionary:
	var out := {}
	var w := int(room["w"])
	var h := int(room["h"])
	var px: Array = room["pillar_x"]
	var py: Array = room["pillar_y"]
	for y in range(h):
		for x in range(w):
			var wall := x == 0 or y == 0 or x == w - 1 or y == h - 1
			if x >= int(px[0]) and x <= int(px[1]) and y >= int(py[0]) and y <= int(py[1]):
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

func paint(ts: TileSet, room: Dictionary) -> TileMapLayer:
	var p := plan(room)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.set_cells_terrain_connect(cells_of(p, 0), 0, 0, false)
	layer.set_cells_terrain_connect(cells_of(p, 1), 0, 1, false)
	return layer

func point_hits(space: PhysicsDirectSpaceState2D, at: Vector2) -> int:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = at
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return space.intersect_point(q, 8).size()

func load_manifest() -> Array:
	var f := FileAccess.open("res://occluder/manifest.json", FileAccess.READ)
	if f == null:
		return []
	var man: Variant = JSON.parse_string(f.get_as_text())
	return man if typeof(man) == TYPE_ARRAY else []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	invert = "--invert" in args
	render = "--render" in args
	var man := load_manifest()
	var tag := "OCCLUDER-RENDER" if render else "OCCLUDER"
	if man.is_empty():
		print("FAIL M0  manifest.json missing or empty — pack was not staged")
		print("%s: 1 FAIL" % tag)
		quit(1)
		return
	print("MANIFEST %d light-occluder tilesets (%s mode, Godot %s)" % [man.size(), "render" if render else "headless", Engine.get_version_info().string])
	if render:
		await run_render(man)
	else:
		await run_headless(man)
	if failures == 0:
		print("%s %d/%d PASS" % [tag, checked, checked])
	else:
		print("%s: %d FAIL of %d" % [tag, failures, checked])
	quit(1 if failures > 0 else 0)

# ============================================================================
# headless: the engine's own answers about the tiles
# ============================================================================
func run_headless(man: Array) -> void:
	var first := true
	var probe := PointLight2D.new()
	var default_cull := probe.shadow_item_cull_mask
	probe.free()
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var path := "res://occluder/%s.tres" % base
		var ts: TileSet = load(path)
		ck("O1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("O2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("O3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"])
			and src.get_tiles_count() == int(entry["tiles"]) and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: %dx%d sheet, %d tiles, square cell %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"]), int(entry["tiles"]), T, T])
		var names: Array = entry["terrains"]
		ck("O4", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES and ts.get_terrains_count(0) == 2
			and ts.get_terrain_name(0, 0) == names[0] and ts.get_terrain_name(0, 1) == names[1],
			"%s: one Match Sides terrain set, terrain 0 '%s' and terrain 1 '%s'" % [base, names[0], names[1]])
		ck("O5", default_cull == 1 and ts.get_occlusion_layers_count() == 1 and ts.get_occlusion_layer_light_mask(0) == int(entry["occluder_light_mask"])
			and ts.get_physics_layers_count() == 1 and ts.get_physics_layer_collision_layer(0) == int(entry["collision_layer"]),
			"%s: one occlusion layer with light_mask = %d (PointLight2D.shadow_item_cull_mask defaults to %d), one physics layer with collision_layer = %d"
				% [base, ts.get_occlusion_layer_light_mask(0), default_cull, ts.get_physics_layer_collision_layer(0)])

		# --- every tile, read back through TileData, with this version's API -----
		var api := "get_occluder_polygons_count/get_occluder_polygon" if minor() >= 4 else "get_occluder"
		var floor_ok := 0
		var floor_n := 0
		var wall_ok := 0
		var wall_n := 0
		var legacy_ok := 0
		var combos := {}
		var empty_bits := 0
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
			var occ := occluders(td)
			if td.terrain == int(entry["floor_terrain"]):
				floor_n += 1
				if occ.is_empty() and td.get_occluder(0) == null and td.get_collision_polygons_count(0) == 0:
					floor_ok += 1
			elif td.terrain == int(entry["wall_terrain"]):
				wall_n += 1
				if occ.size() == 1 and full_cell(occ[0], T):
					wall_ok += 1
				# the deprecated 4.3 getter still answers on 4.4+
				if full_cell(td.get_occluder(0), T):
					legacy_ok += 1
		ck("O6", wall_n == int(entry["wall_tiles"]) and wall_ok == wall_n and legacy_ok == wall_n,
			"%s: every wall tile reports exactly one occluder through %s — a full cell of %d px^2, every vertex inside (-%d,-%d)..(%d,%d) — and get_occluder(0) returns the same polygon (%d/%d)"
				% [base, api, T * T, T / 2, T / 2, T / 2, T / 2, wall_ok, wall_n])
		ck("O7", floor_n == int(entry["floor_tiles"]) and floor_ok == floor_n,
			"%s: all %d floor tiles report NO occluder (through %s and get_occluder) and no collision (%d/%d)"
				% [base, floor_n, api, floor_ok, floor_n])
		var wall_td := src.get_tile_data(v2i(entry["wall_atlas"]), 0)
		var cp := wall_td.get_collision_polygon_points(0, 0) if wall_td.get_collision_polygons_count(0) == 1 else PackedVector2Array()
		ck("O8", cp.size() == 4 and is_equal_approx(poly_area(cp), float(T * T)),
			"%s: the wall tile also carries one full-cell collision polygon (%.0f px^2)" % [base, poly_area(cp)])
		ck("O9", combos.size() == 17 and combos.has("1:15") and empty_bits == 0,
			"%s: 16 floor tiles cover all 16 floor/wall side combinations, the one wall tile is Wall on all four sides, no side bit left empty (%d distinct, %d empty)"
				% [base, combos.size(), empty_bits])

		# --- the art claim --------------------------------------------------------
		var img := src.texture.get_image()
		var shade := Color(entry["floor_shade"])
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
		ck("O10", band_ok == 16,
			"%s: the %dpx shade band is drawn on exactly the floor sides that meet a wall, in all 16 floor tiles (%d/16)"
				% [base, int(entry["band_px"]), band_ok])

		# --- painted into the running tree ------------------------------------------
		var room: Dictionary = entry["room"]
		var p := plan(room)
		var floors := cells_of(p, 0)
		var walls := cells_of(p, 1)
		var layer := paint(ts, room)
		root.add_child(layer)
		await physics_frame
		await physics_frame
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
		ck("O11", agree == p.size(),
			"%s: set_cells_terrain_connect painted the %dx%d room (%d floor, %d wall incl. a 2x2 pillar) with every cell's terrain and side bits right (%d/%d)"
				% [base, int(room["w"]), int(room["h"]), floors.size(), walls.size(), agree, p.size()])
		var occ_cells := 0
		var occ_on_floor := 0
		for c in p:
			var td := layer.get_cell_tile_data(c)
			if td == null:
				continue
			var occ := occluders(td)
			if p[c] == 1 and occ.size() == 1 and full_cell(occ[0], T):
				occ_cells += 1
			elif p[c] == 0 and not occ.is_empty():
				occ_on_floor += 1
		var want_walls := walls.size() + (1 if invert and first else 0)
		ck("O12", occ_cells == want_walls and occ_on_floor == 0,
			"%s: read back from the painted TileMapLayer (get_cell_tile_data), %d of %d wall cells carry the full-cell occluder and %d of %d floor cells carry one"
				% [base, occ_cells, want_walls, occ_on_floor, floors.size()])
		var space := layer.get_world_2d().direct_space_state
		var pillar := Vector2i(int(room["pillar_x"][0]), int(room["pillar_y"][0]))
		var lc := v2i(room["light"])
		var hw := point_hits(space, centre(pillar, T))
		var hf := point_hits(space, centre(lc, T))
		ck("O13", hw >= 1 and hf == 0,
			"%s: the physics server finds a collider at a pillar cell's centre (%d) and none on the light's floor cell (%d)" % [base, hw, hf])
		var has_prop := "occlusion_enabled" in layer
		ck("O14", (has_prop and layer.get("occlusion_enabled") == true) if minor() >= 4 else not has_prop,
			"%s: TileMapLayer.occlusion_enabled %s" % [base, ("exists and defaults to true on %d.%d" % [4, minor()]) if minor() >= 4 else "does not exist on 4.3"])
		root.remove_child(layer)
		layer.free()

		# --- the file format, both directions ------------------------------------------
		var text := FileAccess.get_file_as_string(path)
		var re_old := RegEx.new()
		re_old.compile("(?m)^\\d+:\\d+/0/occlusion_layer_0/polygon = ")
		var re_new := RegEx.new()
		re_new.compile("(?m)occlusion_layer_\\d+/polygon_\\d+/polygon")
		var n_old := re_old.search_all(text).size()
		var n_new := re_new.search_all(text).size()
		ck("O15", n_old == int(entry["wall_tiles"]) and n_new == 0 and wall_ok == wall_n,
			"%s: the .tres stores the occluder under the 4.3 key '%s' (%d line, %d with the 4.4+ polygon_N key) and %d.%d reads it back as 1 occluder"
				% [base, entry["occluder_key"], n_old, n_new, 4, minor()])
		var alt_path := "res://occluder/_fmt44_%s.tres" % base
		var alt := FileAccess.open(alt_path, FileAccess.WRITE)
		alt.store_string(text.replace("/occlusion_layer_0/polygon = ", "/occlusion_layer_0/polygon_0/polygon = "))
		alt.close()
		var ts44: TileSet = ResourceLoader.load(alt_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var n44 := -1
		if ts44 != null:
			n44 = occluders((ts44.get_source(0) as TileSetAtlasSource).get_tile_data(v2i(entry["wall_atlas"]), 0)).size()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(alt_path))
		ck("O16", n44 == (0 if minor() < 4 else 1),
			"%s: the same file with the key 4.4+ writes (occlusion_layer_0/polygon_0/polygon) loads on %d.%d with %d occluder(s) on the wall tile%s"
				% [base, 4, minor(), n44, " — silently: 4.3 does not read that key" if minor() < 4 else ""])
		var out_path := "user://resaved_%s.tres" % base
		ResourceSaver.save(ts, out_path)
		var saved := FileAccess.get_file_as_string(out_path)
		var s_old := re_old.search_all(saved).size()
		var s_new := RegEx.create_from_string("(?m)^\\d+:\\d+/0/occlusion_layer_0/polygon_0/polygon = ").search_all(saved).size()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
		ck("O17", (s_old == 1 and s_new == 0) if minor() < 4 else (s_old == 0 and s_new == 1),
			"%s: re-saved by %d.%d through ResourceSaver.save the occluder is written under the %s key (%d old-key, %d new-key lines)%s"
				% [base, 4, minor(), "4.3" if minor() < 4 else "4.4+", s_old, s_new, " — a file 4.3 then opens with no occluders" if minor() >= 4 else ""])
		first = false
		ts = null

# ============================================================================
# render: the shadow itself, read back from a real GL frame
# ============================================================================
var vp: SubViewport
var light: PointLight2D
var layer_r: TileMapLayer

func flat_texture() -> Texture2D:
	var img := Image.create(1024, 1024, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(img)

func stage(ts: TileSet, room: Dictionary, T: int) -> void:
	if vp:
		root.remove_child(vp)
		vp.free()
	vp = SubViewport.new()
	vp.size = Vector2i(int(room["w"]) * T, int(room["h"]) * T)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	layer_r = paint(ts, room)
	vp.add_child(layer_r)
	light = PointLight2D.new()
	light.position = centre(v2i(room["light"]), T)
	light.texture = flat_texture()
	light.shadow_enabled = true
	vp.add_child(light)

func frame() -> PackedByteArray:
	for i in 4:
		await process_frame
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img.get_data()

func lum(d: PackedByteArray, i: int) -> float:
	return (d[i] + d[i + 1] + d[i + 2]) / 765.0

# segment a->b against the square [x0,x1]x[y0,y1] (slab test)
func seg_hits(a: Vector2, b: Vector2, x0: float, y0: float, x1: float, y1: float) -> bool:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	for axis in 2:
		var p0 := a.x if axis == 0 else a.y
		var dd := d.x if axis == 0 else d.y
		var lo := x0 if axis == 0 else y0
		var hi := x1 if axis == 0 else y1
		if absf(dd) < 1e-9:
			if p0 < lo or p0 > hi:
				return false
		else:
			var ta := (lo - p0) / dd
			var tb := (hi - p0) / dd
			if ta > tb:
				var s := ta
				ta = tb
				tb = s
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return false
	return true

# per floor pixel: 1 = in plain sight of the light, 0 = behind a wall, -1 = within
# 1 px of a shadow edge (left out). Only the walls INSIDE the perimeter are
# tested: the room's floor is one convex rectangle, and a segment between two
# points of a convex region never leaves it, so it cannot touch a perimeter cell.
func geometry(room: Dictionary, T: int) -> Dictionary:
	var p := plan(room)
	var w := int(room["w"])
	var h := int(room["h"])
	var inner := []
	for c in p:
		if p[c] == 1 and c.x > 0 and c.y > 0 and c.x < w - 1 and c.y < h - 1:
			inner.append(c)
	var L := centre(v2i(room["light"]), T)
	var M := 1.0
	var vis := {}
	var W := w * T
	for c in p:
		if p[c] != 0:
			continue
		for y in range(c.y * T, c.y * T + T):
			for x in range(c.x * T, c.x * T + T):
				var P := Vector2(x + 0.5, y + 0.5)
				var grown := false
				var shrunk := false
				for wc in inner:
					var x0: float = wc.x * T
					var y0: float = wc.y * T
					if seg_hits(L, P, x0 - M, y0 - M, x0 + T + M, y0 + T + M):
						grown = true
						if seg_hits(L, P, x0 + M, y0 + M, x0 + T - M, y0 + T - M):
							shrunk = true
				vis[y * W + x] = 0 if shrunk else (1 if not grown else -1)
	return vis

# compares a shadowed frame with the light-off frame, pixel by pixel
func classify(base: PackedByteArray, shot: PackedByteArray, nosh: PackedByteArray, vis: Dictionary) -> Dictionary:
	var r := {"in_light": 0, "lit": 0, "dark": 0, "agree": 0, "counted": 0, "hidden": 0, "edge": 0, "mis_lit": 0, "mis_dark": 0}
	for k in vis:
		var i: int = k * 4
		var reach := lum(nosh, i) - lum(base, i) > 0.05
		if not reach:
			continue
		r["in_light"] += 1
		var is_lit := lum(shot, i) - lum(base, i) > 0.05
		r["lit" if is_lit else "dark"] += 1
		var v: int = vis[k]
		if v == -1:
			r["edge"] += 1
			continue
		r["counted"] += 1
		if v == 0:
			r["hidden"] += 1
		if (v == 1) == is_lit:
			r["agree"] += 1
		elif is_lit:
			r["mis_lit"] += 1
		else:
			r["mis_dark"] += 1
	return r

func px_at(d: PackedByteArray, base: PackedByteArray, at: Vector2, W: int) -> bool:
	var i := (int(at.y) * W + int(at.x)) * 4
	return lum(d, i) - lum(base, i) > 0.05

func run_render(man: Array) -> void:
	var first := true
	var first_entry: Dictionary = man[0]
	for entry in man:
		var base_name: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var room: Dictionary = entry["room"]
		var W := int(room["w"]) * T
		var path := "res://occluder/%s.tres" % base_name
		var ts: TileSet = load(path)
		if ts == null:
			ck("R0", false, "%s: tileset loads" % base_name)
			continue
		var vis := geometry(room, T)
		stage(ts, room, T)
		light.enabled = false
		var off: PackedByteArray = await frame()
		light.enabled = true
		light.shadow_enabled = false
		var nosh: PackedByteArray = await frame()
		light.shadow_enabled = true
		var shot: PackedByteArray = await frame()
		var r := classify(off, shot, nosh, vis)
		ck("R1", r["counted"] > 0 and r["hidden"] > 0 and r["agree"] == r["counted"],
			"%s: rendered with shadows on, %d of %d floor pixels agree with line of sight from the light (%d behind the pillar dark, %d in sight lit; %d pixels within 1 px of a shadow edge left out; wrongly lit %d, wrongly dark %d)"
				% [base_name, r["agree"], r["counted"], r["hidden"], r["counted"] - r["hidden"], r["edge"], r["mis_lit"], r["mis_dark"]])
		var behind := centre(v2i(room["behind"]), T)
		var control := centre(v2i(room["control"]), T)
		var b_lit := px_at(shot, off, behind, W)
		var c_lit := px_at(shot, off, control, W)
		var want_b := true if invert and first else false
		ck("R2", b_lit == want_b and c_lit and px_at(nosh, off, behind, W),
			"%s: the centre of cell %s, straight behind the pillar, is %s; the centre of %s, about as far but in sight, is %s; with shadows off the first is lit — distance is not the reason"
				% [base_name, str(v2i(room["behind"])), "lit" if b_lit else "dark", str(v2i(room["control"])), "lit" if c_lit else "dark"])
		var r_off := classify(off, nosh, nosh, vis)
		ck("R3", r_off["dark"] == 0 and r_off["in_light"] == r["in_light"],
			"%s: the same room with shadow_enabled = false (the PointLight2D default): %d dark floor pixels of %d reached — the walls cast nothing"
				% [base_name, r_off["dark"], r_off["in_light"]])
		ts.set_occlusion_layer_light_mask(0, 2)
		var mm: PackedByteArray = await frame()
		ts.set_occlusion_layer_light_mask(0, int(entry["occluder_light_mask"]))
		var r_mm := classify(off, mm, nosh, vis)
		ck("R4", r_mm["dark"] == 0,
			"%s: occlusion layer light_mask = 2 against the light's shadow_item_cull_mask = 1: %d dark floor pixels — no shadow, no warning"
				% [base_name, r_mm["dark"]])
		var bare: TileSet = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		bare.remove_occlusion_layer(0)
		layer_r.tile_set = bare
		var nl: PackedByteArray = await frame()
		layer_r.tile_set = ts
		var r_nl := classify(off, nl, nosh, vis)
		ck("R5", bare.get_occlusion_layers_count() == 0 and r_nl["dark"] == 0,
			"%s: the same TileSet with its occlusion layer removed: %d dark floor pixels — the occluders go with the layer" % [base_name, r_nl["dark"]])
		if first:
			print("INFO  %s: %d floor pixels reached by the light, %d of them dark with shadows on" % [base_name, r["in_light"], r["dark"]])
		first = false
		ts = null

	# --- the traps, once, on the first TileSet ------------------------------------
	var e: Dictionary = first_entry
	var T: int = int(e["tile_size"])
	var room: Dictionary = e["room"]
	var W := int(room["w"]) * T
	var path := "res://occluder/%s.tres" % e["base"]
	var vis := geometry(room, T)
	var ts: TileSet = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	stage(ts, room, T)
	light.enabled = false
	var off: PackedByteArray = await frame()
	light.enabled = true
	light.shadow_enabled = false
	var nosh: PackedByteArray = await frame()
	light.shadow_enabled = true

	# R6: masks that DO share a bit, receiver included
	ts.set_occlusion_layer_light_mask(0, 3)
	light.shadow_item_cull_mask = 2
	layer_r.light_mask = 3
	var r6 := classify(off, await frame(), nosh, vis)
	ck("R6", r6["hidden"] > 0 and r6["agree"] == r6["counted"],
		"%s: occlusion light_mask 3, light shadow_item_cull_mask 2, layer light_mask 3 — the masks share bit 2 and the shadow is back (%d of %d floor pixels agree with line of sight)"
			% [e["base"], r6["agree"], r6["counted"]])
	# R7: the receiver rule — same masks, the layer's own light_mask left at 1
	layer_r.light_mask = 1
	var r7 := classify(off, await frame(), nosh, vis)
	ck("R7", (r7["dark"] > 0 and r7["agree"] == r7["counted"]) if minor() < 4 else r7["dark"] == 0,
		"%s: same, but the layer's own light_mask left at 1 (no bit in common with shadow_item_cull_mask 2): %d dark floor pixels — %s"
			% [e["base"], r7["dark"], "4.3 still shadows the floor" if minor() < 4 else "since 4.4 the item RECEIVING the shadow is filtered too, and the floor is lit but never shadowed"])
	ts.set_occlusion_layer_light_mask(0, 1)
	light.shadow_item_cull_mask = 1
	# R8: occlusion_enabled
	layer_r.set("occlusion_enabled", false)
	var r8 := classify(off, await frame(), nosh, vis)
	ck("R8", r8["dark"] == 0 if minor() >= 4 else (r8["dark"] > 0 and r8["agree"] == r8["counted"]),
		"%s: TileMapLayer.set(\"occlusion_enabled\", false): %d dark floor pixels — %s"
			% [e["base"], r8["dark"], "4.4+ turns the layer's shadows off" if minor() >= 4 else "4.3 has no such property, the call does nothing and the shadow stays"])
	layer_r.set("occlusion_enabled", true)
	# R9: a PointLight2D with no texture
	# a fresh light that never had a texture (setting texture = null on a live
	# light makes the GL driver print an error on 4.7, which is not the point)
	light.enabled = false
	var bare_light := PointLight2D.new()
	bare_light.position = light.position
	bare_light.shadow_enabled = true
	vp.add_child(bare_light)
	var tx: PackedByteArray = await frame()
	var reached := 0
	for k in vis:
		if lum(tx, k * 4) - lum(off, k * 4) > 0.05:
			reached += 1
	vp.remove_child(bare_light)
	bare_light.free()
	light.enabled = true
	ck("R9", reached == 0,
		"%s: a PointLight2D with shadows on and no texture lights %d floor pixels — nothing, before or behind the wall" % [e["base"], reached])
	# R10: the polygon authored from (0,0) to (T,T)
	var src := ts.get_source(0) as TileSetAtlasSource
	var wtd := src.get_tile_data(v2i(e["wall_atlas"]), 0)
	var shifted := OccluderPolygon2D.new()
	shifted.polygon = PackedVector2Array([Vector2(0, 0), Vector2(T, 0), Vector2(T, T), Vector2(0, T)])
	if wtd.has_method("set_occluder_polygon"):
		wtd.call("set_occluder_polygon", 0, 0, shifted)
	else:
		wtd.set_occluder(0, shifted)
	var r10 := classify(off, await frame(), nosh, vis)
	ck("R10", r10["agree"] < r10["counted"] and r10["mis_lit"] > 0 and r10["mis_dark"] > 0,
		"%s: the wall occluder authored from (0,0) to (%d,%d) instead of centred: %d floor pixels that should be dark are lit and %d that should be lit are dark — the shadow moved half a tile"
			% [e["base"], T, T, r10["mis_lit"], r10["mis_dark"]])
	root.remove_child(vp)
	vp.free()
	vp = null
