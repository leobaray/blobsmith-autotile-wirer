extends SceneTree
##
## Reproduces every claim in docs/what-a-flipped-tile-really-is.md against a
## real engine.
##
## Standalone: builds its own TileSet in memory, needs no project assets.
##
##     godot --headless --script verify_tile_transforms.gd
##
## Prints PASS/FAIL per check; exit code 0 only if all pass.
##
## Why this file exists next to verify_tile_map_data.gd: that one proves how a
## flip is STORED (three bits inside the 16-bit alternative field of the
## tile_map_data buffer). This one proves what the engine DOES with those bits
## — which TileData the cell resolves to, what a flip therefore cannot carry,
## and whether the terrain autotiler is allowed to reach for a flipped tile
## when the sheet is missing the one it needs. The second question is the one
## that decides whether a 47-blob sheet can be drawn with fewer tiles.

const FLIP_H := 4096      # TileSetAtlasSource.TRANSFORM_FLIP_H
const FLIP_V := 8192      # TileSetAtlasSource.TRANSFORM_FLIP_V
const TRANSPOSE := 16384  # TileSetAtlasSource.TRANSFORM_TRANSPOSE
const TRANSFORM_MASK := FLIP_H | FLIP_V | TRANSPOSE

const SRC_ID := 3

var failures := 0


func check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		failures += 1


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = got == want
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


## A 2x2 atlas under source id 3, plus one custom data layer, one physics
## layer, and an authored alternative on tile (0,0).
func make_layer() -> TileMapLayer:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))

	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(0, "label")
	ts.add_physics_layer()

	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for y in range(2):
		for x in range(2):
			src.create_tile(Vector2i(x, y))
	ts.add_source(src, SRC_ID)

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	return layer


func atlas_source(layer: TileMapLayer) -> TileSetAtlasSource:
	return layer.tile_set.get_source(SRC_ID) as TileSetAtlasSource


# --- 1. the three bits are the documented ones ------------------------------
func check_constants() -> void:
	check_eq("C1  TRANSFORM_FLIP_H is 0x1000", TileSetAtlasSource.TRANSFORM_FLIP_H, FLIP_H)
	check_eq("C1  TRANSFORM_FLIP_V is 0x2000", TileSetAtlasSource.TRANSFORM_FLIP_V, FLIP_V)
	check_eq("C1  TRANSFORM_TRANSPOSE is 0x4000", TileSetAtlasSource.TRANSFORM_TRANSPOSE, TRANSPOSE)


# --- 2. a flip needs no alternative to exist --------------------------------
# The claim people get wrong in both directions: some author an alternative
# tile per flip (four copies of every tile), others assume set_cell rejects an
# alternative id that was never created. Neither is true.
func check_flip_needs_no_authoring(layer: TileMapLayer) -> void:
	var src := atlas_source(layer)
	check_eq("C2  atlas has only the 4 base tiles", src.get_tiles_count(), 4)
	check_eq("C2  tile (0,0) has 1 alternative before any set_cell",
			src.get_alternative_tiles_count(Vector2i(0, 0)), 1)

	layer.set_cell(Vector2i(0, 0), SRC_ID, Vector2i(0, 0), FLIP_H)

	check_eq("C2  the cell reads back with the flip bit",
			layer.get_cell_alternative_tile(Vector2i(0, 0)), FLIP_H)
	check_eq("C2  set_cell created no alternative on the source",
			src.get_alternative_tiles_count(Vector2i(0, 0)), 1)
	check_eq("C2  the cell still points at the base atlas coords",
			layer.get_cell_atlas_coords(Vector2i(0, 0)), Vector2i(0, 0))
	check_eq("C2  and at the base source", layer.get_cell_source_id(Vector2i(0, 0)), SRC_ID)


# --- 3. a flipped cell resolves to the BASE TileData ------------------------
# This is the whole practical point. The flip lives in the cell, not in the
# tile, so everything a TileData carries is shared with the unflipped tile —
# and identity, not just equality: the same object comes back.
func check_shared_tiledata(layer: TileMapLayer) -> void:
	var src := atlas_source(layer)
	var base: TileData = src.get_tile_data(Vector2i(0, 0), 0)
	base.set_custom_data("label", "base")
	base.add_collision_polygon(0)
	# An L, deliberately not symmetric under any flip.
	base.set_collision_polygon_points(0, 0, PackedVector2Array([
		Vector2(-8, -8), Vector2(0, -8), Vector2(0, 0), Vector2(8, 0),
		Vector2(8, 8), Vector2(-8, 8),
	]))

	layer.set_cell(Vector2i(1, 0), SRC_ID, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(2, 0), SRC_ID, Vector2i(0, 0), FLIP_H)
	layer.set_cell(Vector2i(3, 0), SRC_ID, Vector2i(0, 0), FLIP_H | FLIP_V | TRANSPOSE)

	var plain: TileData = layer.get_cell_tile_data(Vector2i(1, 0))
	var flipped: TileData = layer.get_cell_tile_data(Vector2i(2, 0))
	var rotated: TileData = layer.get_cell_tile_data(Vector2i(3, 0))

	check("C3  a flipped cell still returns a TileData", flipped != null)
	check("C3  it is the SAME object as the unflipped cell's",
			flipped != null and flipped == plain)
	check("C3  all three transform bits at once: still the same object",
			rotated != null and rotated == plain)
	check_eq("C3  custom data is the base tile's",
			flipped.get_custom_data("label"), "base")

	var a := plain.get_collision_polygon_points(0, 0)
	var b := flipped.get_collision_polygon_points(0, 0)
	check("C3  the collision polygon read back through TileData is NOT mirrored",
			a == b)
	# Stated positively so the doc can quote the consequence, not the tautology:
	# there is no per-flip TileData to edit, so there is nothing to give a
	# flipped tile that its base does not already have.
	check_eq("C3  the base polygon still starts at its authored point",
			b[0], Vector2(-8, -8))


# --- 4. transform bits and an AUTHORED alternative are different fields -----
# create_alternative_tile() hands out small ids (1, 2, 3...) that live below
# the transform bits, so a cell can carry both at once.
func check_authored_alternative(layer: TileMapLayer) -> void:
	var src := atlas_source(layer)
	var alt: int = src.create_alternative_tile(Vector2i(1, 1))
	check("C4  an authored alternative id sits below the transform bits",
			alt > 0 and (alt & TRANSFORM_MASK) == 0)

	var alt_data: TileData = src.get_tile_data(Vector2i(1, 1), alt)
	alt_data.set_custom_data("label", "authored")

	layer.set_cell(Vector2i(4, 0), SRC_ID, Vector2i(1, 1), alt | FLIP_H)
	check_eq("C4  both survive in the cell",
			layer.get_cell_alternative_tile(Vector2i(4, 0)), alt | FLIP_H)

	var got: TileData = layer.get_cell_tile_data(Vector2i(4, 0))
	check("C4  the cell resolves to the AUTHORED alternative, not the base",
			got != null and got == alt_data)
	check_eq("C4  so an authored alternative can carry its own data",
			got.get_custom_data("label"), "authored")


# --- 5. the terrain autotiler never reaches for a flip ----------------------
# The experiment that decides whether flips can shrink a blob sheet: give the
# terrain set a "left end" piece and deliberately withhold its mirror image,
# then ask the engine to paint a run that needs the mirror. If flips were part
# of terrain matching, the right-hand cell would come back as the left end with
# FLIP_H. Measure what it actually does.
func check_terrain_ignores_flips() -> TileMapLayer:
	var layer := make_layer()
	var ts := layer.tile_set
	var src := atlas_source(layer)

	ts.add_terrain_set()
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_SIDES)
	ts.add_terrain(0)

	# (0,0) middle: connects left AND right.
	var middle: TileData = src.get_tile_data(Vector2i(0, 0), 0)
	middle.terrain_set = 0
	middle.terrain = 0
	middle.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE, 0)
	middle.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)

	# (1,0) left end: connects on the right only. Its mirror — a piece that
	# connects on the left only — is the tile we are NOT giving the engine.
	var left_end: TileData = src.get_tile_data(Vector2i(1, 0), 0)
	left_end.terrain_set = 0
	left_end.terrain = 0
	left_end.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)

	var run: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	layer.set_cells_terrain_connect(run, 0, 0, false)

	var painted := 0
	var transformed := 0
	for c in run:
		if layer.get_cell_source_id(c) == -1:
			continue
		painted += 1
		if (layer.get_cell_alternative_tile(c) & TRANSFORM_MASK) != 0:
			transformed += 1

	check_eq("C5  the autotiler painted all three cells", painted, 3)
	check_eq("C5  and used no transform bit on any of them  <-- flips cannot"
			+ " stand in for a tile the sheet does not have", transformed, 0)

	# The right-hand cell is the one whose ideal piece is missing. Name what it
	# got instead, so the doc reports the substitution rather than implying the
	# sheet was complete.
	var right := layer.get_cell_atlas_coords(Vector2i(2, 0))
	print("NOTE  the cell needing the absent mirror got atlas coords %s"
			% [right])
	check("C5  it fell back to a tile that exists in the sheet",
			right == Vector2i(0, 0) or right == Vector2i(1, 0))
	return layer


# --- 6. a flip painted by hand survives a terrain repaint of its neighbour --
# Practical consequence of C5 for anyone hand-fixing an autotiled map: the
# autotiler owns the cells it is given, and a flip you placed inside that set
# is overwritten, because the engine has no way to consider it a match.
func check_repaint_drops_manual_flip(layer: TileMapLayer) -> void:
	layer.set_cell(Vector2i(1, 0), SRC_ID, Vector2i(1, 0), FLIP_H)
	check_eq("C6  the hand-placed flip is there before the repaint",
			layer.get_cell_alternative_tile(Vector2i(1, 0)), FLIP_H)

	var run: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	layer.set_cells_terrain_connect(run, 0, 0, false)

	check_eq("C6  repainting the run through it clears the flip",
			layer.get_cell_alternative_tile(Vector2i(1, 0)) & TRANSFORM_MASK, 0)


# --- 7. controls: make the checks above capable of failing ------------------
# Every check in this file passed on its first run, which on its own is as
# consistent with "the claims are true" as with "the checks cannot fail". These
# three exist to rule out the second reading, and they ship with the file
# because a control that only ever ran once, somewhere else, proves nothing to
# the next reader.
func check_controls() -> void:
	# K1 is the control for C5. Hand the engine the mirror it was denied; if
	# the fallback to (0,0) was really the autotiler picking among what exists,
	# the answer for the same cell must now change.
	var layer := make_layer()
	var ts := layer.tile_set
	var src := atlas_source(layer)
	ts.add_terrain_set()
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_SIDES)
	ts.add_terrain(0)

	var middle: TileData = src.get_tile_data(Vector2i(0, 0), 0)
	middle.terrain_set = 0
	middle.terrain = 0
	middle.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE, 0)
	middle.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)

	var left_end: TileData = src.get_tile_data(Vector2i(1, 0), 0)
	left_end.terrain_set = 0
	left_end.terrain = 0
	left_end.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)

	var right_end: TileData = src.get_tile_data(Vector2i(0, 1), 0)
	right_end.terrain_set = 0
	right_end.terrain = 0
	right_end.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_LEFT_SIDE, 0)

	var run: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	layer.set_cells_terrain_connect(run, 0, 0, false)
	check_eq("K1  with the mirror DRAWN, the same cell takes it — so C5's"
			+ " fallback was the missing tile, not a constant",
			layer.get_cell_atlas_coords(Vector2i(2, 0)), Vector2i(0, 1))
	check_eq("K1  and even with the sheet complete, still no transform bit",
			layer.get_cell_alternative_tile(Vector2i(2, 0)) & TRANSFORM_MASK, 0)

	# K2 is the control for C3: if TileData compared equal for any two tiles,
	# "the same object comes back" would be true of everything.
	var plain_layer := make_layer()
	plain_layer.set_cell(Vector2i(0, 0), SRC_ID, Vector2i(0, 0), 0)
	plain_layer.set_cell(Vector2i(1, 0), SRC_ID, Vector2i(1, 0), 0)
	check("K2  two different base tiles do NOT compare equal",
			plain_layer.get_cell_tile_data(Vector2i(0, 0))
			!= plain_layer.get_cell_tile_data(Vector2i(1, 0)))

	# K3 is the control for C6: show the repaint is what clears the flip, by
	# putting one outside the repainted set and watching it survive.
	layer.set_cell(Vector2i(9, 9), SRC_ID, Vector2i(1, 0), FLIP_H)
	layer.set_cells_terrain_connect(run, 0, 0, false)
	check_eq("K3  a flip OUTSIDE the repainted run survives it",
			layer.get_cell_alternative_tile(Vector2i(9, 9)), FLIP_H)


# --- 8. what the PHYSICS server is handed --------------------------------
# C3 says the polygon you read back through TileData is the base tile's,
# unmirrored. That is the answer to "what does my code see", and it is the
# answer people then repeat as "collision does not flip". This section asks the
# other question — what shape the engine actually builds — because the two do
# not agree, and only one of them is what the player collides with.
func sorted_points(pts: PackedVector2Array) -> Array:
	var out: Array = []
	for p in pts:
		out.append("%.1f,%.1f" % [p.x, p.y])
	out.sort()
	return out


func mirrored_x(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2(-p.x, p.y))
	return out


## The shape the physics server holds for one cell, in cell-relative
## coordinates. Two things bite here, and both are why this is a function
## instead of an inline read:
##
##  * TileMapLayer merges neighbouring cells into ONE body, so the shape is
##    found by which cell box its points land in, never by shape index.
##  * shape_get_data() is in the BODY's frame, not the layer's. Skipping the
##    body transform still yields plausible-looking numbers — they are simply
##    off by half a tile, which is exactly the size of the effect being
##    measured. The transform is applied, not assumed to be identity.
##  * the point query answers for every body in the world, and the earlier
##    checks left their own layers sitting on the same coordinates. Without the
##    has_body_rid() filter this reads a neighbouring layer's polygon and
##    reports it as this one's.
func shape_points_for_cell(layer: TileMapLayer, cell: Vector2i) -> PackedVector2Array:
	var centre := layer.map_to_local(cell)
	var half := Vector2(layer.tile_set.tile_size) * 0.5
	var params := PhysicsPointQueryParameters2D.new()
	params.position = centre
	params.collide_with_bodies = true
	for hit in root.world_2d.direct_space_state.intersect_point(params, 32):
		var rid: RID = hit["rid"]
		if not layer.has_body_rid(rid):
			continue
		var body_xform: Transform2D = PhysicsServer2D.body_get_state(
				rid, PhysicsServer2D.BODY_STATE_TRANSFORM)
		for i in range(PhysicsServer2D.body_get_shape_count(rid)):
			var data: Variant = PhysicsServer2D.shape_get_data(
					PhysicsServer2D.body_get_shape(rid, i))
			if not (data is PackedVector2Array):
				continue
			var to_world: Transform2D = body_xform \
					* PhysicsServer2D.body_get_shape_transform(rid, i)
			var pts: PackedVector2Array = data
			var inside := pts.size() > 0
			var rel := PackedVector2Array()
			for p in pts:
				var d: Vector2 = to_world * p - centre
				if absf(d.x) > half.x + 0.01 or absf(d.y) > half.y + 0.01:
					inside = false
					break
				rel.append(d)
			if inside:
				return rel
	return PackedVector2Array()


func check_physics_is_mirrored() -> void:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_physics_layer()
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src, SRC_ID)

	# A right triangle: no flip of it maps back onto itself, so "mirrored" and
	# "not mirrored" cannot be confused.
	var base_pts := PackedVector2Array([Vector2(-8, -8), Vector2(8, 8), Vector2(-8, 8)])
	var td: TileData = src.get_tile_data(Vector2i(0, 0), 0)
	td.add_collision_polygon(0)
	td.set_collision_polygon_points(0, 0, base_pts)

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.collision_enabled = true
	root.add_child(layer)
	layer.set_cell(Vector2i(0, 0), SRC_ID, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(1, 0), SRC_ID, Vector2i(0, 0), FLIP_H)
	await physics_frame
	await physics_frame

	var plain := shape_points_for_cell(layer, Vector2i(0, 0))
	var flipped := shape_points_for_cell(layer, Vector2i(1, 0))
	check("C7  the unflipped cell has a collision shape", plain.size() == 3)
	check("C7  the flipped cell has one too", flipped.size() == 3)
	check_eq("C7  the unflipped shape is the polygon as authored",
			sorted_points(plain), sorted_points(base_pts))
	check_eq("C7  the FLIPPED cell's shape IS mirrored, though TileData (C3)"
			+ " reports it unmirrored", sorted_points(flipped),
			sorted_points(mirrored_x(base_pts)))
	# K4: without this, the line above would also pass on a polygon that is
	# symmetric under the flip, where mirrored and unmirrored are the same set.
	check("K4  the two shapes really do differ, so C7 is not comparing a"
			+ " polygon with itself", sorted_points(plain) != sorted_points(flipped))


func _init() -> void:
	var layer := make_layer()
	check_constants()
	check_flip_needs_no_authoring(layer)
	check_shared_tiledata(layer)
	check_authored_alternative(layer)

	var terrain_layer := check_terrain_ignores_flips()
	check_repaint_drops_manual_flip(terrain_layer)
	check_controls()
	await check_physics_is_mirrored()

	print("")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)
