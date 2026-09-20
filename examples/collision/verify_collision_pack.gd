extends SceneTree

# Engine gate for the free solid-collision pack (rock / brick / ice / wood).
#
# The README promises four solid Match Sides terrains, 16 tiles each, every tile
# carrying a full-cell collision polygon on a physics layer whose collision_layer
# is 1 — and, unlike every other pack in this repo, it promises that the polygons
# STOP SOMETHING. So the claims here are not read off the resource: the tiles are
# painted into a real TileMapLayer inside the running scene tree and the questions
# are put to PhysicsDirectSpaceState2D, after a physics frame, the same server the
# player's body would ask.
#
# What gets measured that counting polygons cannot:
#   * a ray dropped on a painted cell stops at the cell's TOP EDGE, not somewhere
#     inside it and not at the far side of the map;
#   * the shared edge of two painted cells is solid — the "my character falls
#     through the crack between two tiles" report;
#   * a one-cell hole in a painted block really is empty, so collision exists
#     exactly where tiles do;
#   * erasing a cell drops its collider in the same frame;
#   * `collision_enabled = false` on the layer removes every collider while the
#     TileSet stays perfectly wired — the switch that makes a correct pack look
#     broken.
#
# Enum values are read by NAME, so a future renumber fails loudly.

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

# a 5x3 block with one cell missing: a straight run, four corners and a hole
const HOLE := Vector2i(2, 1)

func shape() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for x in range(5):
		for y in range(3):
			if Vector2i(x, y) != HOLE:
				cells.append(Vector2i(x, y))
	return cells

func mask_of(layer: TileMapLayer, c: Vector2i) -> int:
	var td := layer.get_cell_tile_data(c)
	if td == null:
		return -1
	var m := 0
	for k in range(4):
		if td.get_terrain_peering_bit(SIDES[k]) == 0:
			m |= 1 << k
	return m

func poly_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(pts.size()):
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

func hits_at(space: PhysicsDirectSpaceState2D, at: Vector2) -> int:
	var q := PhysicsPointQueryParameters2D.new()
	q.position = at
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return space.intersect_point(q, 8).size()

func hex_to_color(h: String) -> Color:
	return Color(h)

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://collision/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("COLLISION: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("COLLISION: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d solid-collision tilesets" % (man as Array).size())

	var cells := shape()
	var painted := {}
	for c in cells:
		painted[c] = true
	var first := true
	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var band: int = int(entry["band_px"])
		var ts: TileSet = load("res://collision/%s.tres" % base)
		ck("K1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("K2", src != null and src.texture != null, "%s: atlas source and texture resolved" % base)
		if src == null or src.texture == null:
			continue
		ck("K3", src.texture.get_width() == int(entry["sheet_w"]) and src.texture.get_height() == int(entry["sheet_h"])
			and src.get_tiles_count() == 16 and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE and ts.tile_size == Vector2i(T, T),
			"%s: %dx%d sheet, 16 tiles, square cell %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"]), T, T])
		ck("K4", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_SIDES
			and ts.get_terrain_name(0, 0) == entry["terrain"],
			"%s: terrain mode is Match Sides, terrain named '%s'" % [base, entry["terrain"]])

		# --- the wiring the pack is about -------------------------------------
		ck("K5", ts.get_physics_layers_count() == 1
			and ts.get_physics_layer_collision_layer(0) == 1
			and ts.get_physics_layer_collision_mask(0) == 1,
			"%s: exactly one physics layer, collision_layer = %d (0 here is the silent killer: bodies exist on no layer)"
				% [base, ts.get_physics_layer_collision_layer(0)])

		var polys_ok := 0
		var area_ok := 0
		var masks := {}
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			var td := src.get_tile_data(coords, 0)
			if td == null:
				continue
			var m := 0
			for k in range(4):
				if td.get_terrain_peering_bit(SIDES[k]) == 0:
					m |= 1 << k
			masks[m] = coords
			if td.get_collision_polygons_count(0) == 1:
				polys_ok += 1
				var pts := td.get_collision_polygon_points(0, 0)
				if pts.size() == 4 and is_equal_approx(poly_area(pts), float(T * T)):
					area_ok += 1
		ck("K6", polys_ok == 16 and area_ok == 16,
			"%s: all 16 tiles carry exactly one collision polygon, each a 4-point full cell of %d px^2 (%d/%d wired, %d/%d full)"
				% [base, T * T, polys_ok, 16, area_ok, 16])
		ck("K7", masks.size() == 16, "%s: the 16 tiles cover all 16 side combinations (got %d distinct)" % [base, masks.size()])

		# --- the art claim ----------------------------------------------------
		var img := src.texture.get_image()
		var border := hex_to_color(entry["border"])
		var band_ok := 0
		for m in range(16):
			var X := (m % 4) * T
			var Y := int(m / 4) * T
			var half := int(T / 2)
			var probes := [[X + T - 1, Y + half, 1], [X + half, Y + T - 1, 2], [X, Y + half, 4], [X + half, Y, 8]]
			var ok := true
			for p in probes:
				var is_band := img.get_pixel(p[0], p[1]).is_equal_approx(border)
				if is_band != ((m & int(p[2])) == 0):
					ok = false
			if ok:
				band_ok += 1
		ck("K8", band_ok == 16,
			"%s: the %dpx dark edge band is drawn on exactly the sides with no neighbour, in all 16 tiles (%d/16) — two painted cells read as one mass"
				% [base, band, band_ok])

		# --- painted into the running tree, asked of the physics server --------
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		layer.set_cells_terrain_connect(cells, 0, 0, false)
		await physics_frame
		await physics_frame
		var space := layer.get_world_2d().direct_space_state

		var agree := 0
		for c in cells:
			var want := 0
			for k in range(4):
				if painted.has(c + DIRS[k]):
					want |= 1 << k
			if mask_of(layer, c) == want:
				agree += 1
		ck("K9", agree == cells.size() and mask_of(layer, HOLE) == -1,
			"%s: connect wrote a tile in each of the %d listed cells with its side bits matching its neighbours (%d/%d), and nothing in the hole"
				% [base, cells.size(), agree, cells.size()])

		var top := float(T) * 0.5
		var q := PhysicsRayQueryParameters2D.create(Vector2(top, -float(T) * 3.0), Vector2(top, float(T) * 0.5))
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		var hit_y: float = hit["position"].y if hit.has("position") else -9999.0
		if invert and first:
			hit_y += 1.0                      # --invert: the gate must catch this
		ck("K10", hit.has("position") and is_equal_approx(hit_y, 0.0),
			"%s: a ray dropped on cell (0,0) stops at the cell's top edge y = 0 (got %.3f) — the polygon is where the art is"
				% [base, hit_y])

		var seam := hits_at(space, Vector2(float(T), float(T) * 0.5))
		ck("K11", seam >= 1,
			"%s: the shared edge of cells (0,0) and (1,0) is solid (%d colliders at x = %d) — no crack to fall through between two painted cells"
				% [base, seam, T])

		var in_hole := hits_at(space, Vector2(HOLE.x * T + T * 0.5, HOLE.y * T + T * 0.5))
		var outside := hits_at(space, Vector2(-float(T), -float(T)))
		ck("K12", in_hole == 0 and outside == 0,
			"%s: collision exists exactly where tiles do — the one-cell hole at %s is empty and so is a cell nobody painted"
				% [base, str(HOLE)])

		layer.erase_cell(Vector2i(0, 0))
		await physics_frame
		ck("K13", hits_at(space, Vector2(top, top)) == 0,
			"%s: erasing a cell drops its collider in the same frame — the collision does not outlive the tile" % base)
		layer.set_cells_terrain_connect(cells, 0, 0, false)
		await physics_frame

		layer.collision_enabled = false
		await physics_frame
		var off_hits := hits_at(space, Vector2(top, top))
		layer.collision_enabled = true
		await physics_frame
		var on_hits := hits_at(space, Vector2(top, top))
		ck("K14", off_hits == 0 and on_hits >= 1,
			"%s: TileMapLayer.collision_enabled = false removes every collider with the TileSet untouched (%d), true brings them back (%d) — the switch that makes a correct pack look broken"
				% [base, off_hits, on_hits])

		first = false
		root.remove_child(layer)
		layer.free()
		await physics_frame
		ts = null

	if failures == 0:
		print("COLLISION %d/%d PASS" % [checked, checked])
	else:
		print("COLLISION: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
