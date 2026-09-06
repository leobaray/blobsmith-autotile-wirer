extends SceneTree
##
## Reproduces every claim in docs/merging-two-tilesets.md against a real engine.
##
## Standalone: builds its own TileSets in memory, needs no project assets.
##
##     godot --headless --script verify_tileset_merge.gd
##
## Prints PASS/FAIL per check; exit code 0 only if all pass.
##
## Why this file exists: the advice repeated for years — call
## `add_source(other.get_source(id))` — is destructive, and the obvious repair
## for it, `duplicate(true)`, is destructive in a quieter way. Every index a
## TileData carries (terrain set, terrain, custom data layer, physics layer)
## is meaningful only inside the TileSet that owns it. Carrying the index into
## a second TileSet keeps the number and swaps the meaning, and the engine
## reports nothing: the tile paints the wrong terrain, or reads its neighbour's
## custom data, with no error, no warning, and no visible difference until you
## paint. Every failure a merge can produce is a silent one, which is exactly
## why it needs assertions rather than a description.

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


## A TileSet with `n_terrain_sets` terrain sets (one terrain each, named
## "<tag>_<i>"), one string custom data layer named `layer_name`, and a single
## 1x1 atlas under source id 3 whose tile sits on the LAST terrain set.
##
## The tile's custom data is set AFTER add_source on purpose: TileData reaches
## its layer names through the TileSet that owns the source, so set_custom_data
## by name on a source that is not in a TileSet yet fails with
## `Parameter "tile_set" is null` — the first trap of doing this in a script.
func make_ts(tag: String, n_terrain_sets: int, layer_name: String,
		n_physics_layers: int = 1) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	for i in n_physics_layers:
		ts.add_physics_layer()
		# A distinct mask per layer, so a tile that lands on the wrong index is
		# telling a different collision story, not the same one.
		ts.set_physics_layer_collision_layer(i, 1 << i)
	for i in n_terrain_sets:
		ts.add_terrain_set()
		ts.set_terrain_set_mode(i, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
		ts.add_terrain(i)
		ts.set_terrain_name(i, 0, tag + "_" + str(i))
	if layer_name != "":
		ts.add_custom_data_layer()
		ts.set_custom_data_layer_name(0, layer_name)
		ts.set_custom_data_layer_type(0, TYPE_STRING)

	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(
			Image.create(32, 32, false, Image.FORMAT_RGBA8))
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src, SRC_ID)

	var td := src.get_tile_data(Vector2i(0, 0), 0)
	if n_terrain_sets > 0:
		td.terrain_set = n_terrain_sets - 1
		td.terrain = 0
		td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)
	if layer_name != "":
		td.set_custom_data(layer_name, "from-" + tag)
	if n_physics_layers > 0:
		# One square polygon on the LAST physics layer.
		var last := n_physics_layers - 1
		td.add_collision_polygon(last)
		td.set_collision_polygon_points(last, 0, PackedVector2Array([
				Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	return ts


func tile_of(ts: TileSet, id: int) -> TileData:
	return (ts.get_source(id) as TileSetAtlasSource).get_tile_data(Vector2i(0, 0), 0)


## A1-A2: the one-liner everyone quotes MOVES the source. The donor TileSet is
## left empty, and if anything saves it in that state the tiles are gone from
## the file too.
func check_add_source_is_a_move() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")
	b.add_source(a.get_source(SRC_ID))
	check_eq("A1  add_source(other.get_source(id)) leaves the DONOR empty",
			a.get_source_count(), 0)
	check_eq("A2  ... and the receiver holds both", b.get_source_count(), 2)


## B1-B2: duplicate(true) is the repair for A1: the donor keeps its source.
func check_duplicate_is_a_copy() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")
	b.add_source(a.get_source(SRC_ID).duplicate(true))
	check_eq("B1  add_source(src.duplicate(true)) leaves the donor intact",
			a.get_source_count(), 1)
	check_eq("B2  ... and the receiver still gets its copy", b.get_source_count(), 2)


## C1-C2: source ids do NOT survive the move, and asking for a taken one is not
## an error you can see — add_source returns -1 and adds nothing. A loop that
## copies sources under their original ids drops every colliding source in
## silence; a loop that lets the engine choose renumbers them, and every
## TileMapLayer already painted stores the OLD id per cell.
func check_source_ids_are_not_preserved() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")
	var got := b.add_source(a.get_source(SRC_ID).duplicate(true), SRC_ID)
	check_eq("C1  add_source(copy, id) with a taken id returns -1", got, -1)
	check_eq("C2  ... and adds nothing at all", b.get_source_count(), 1)

	var c := make_ts("stone", 1, "kind_c")
	var auto := c.add_source(a.get_source(SRC_ID).duplicate(true))
	check("C3  letting the engine choose gives a DIFFERENT id than the source had"
			+ " (%d, was %d)" % [auto, SRC_ID], auto != SRC_ID)


## D1-D3: the silent one. Both TileSets have a terrain set 0; the copied tile
## keeps the NUMBER 0 and therefore paints the receiver's terrain, which is a
## different terrain with a different name. No error, no warning.
func check_terrain_index_changes_meaning() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")
	var id := b.add_source(a.get_source(SRC_ID).duplicate(true))
	var td := tile_of(b, id)
	check_eq("D1  the copied tile still says terrain_set 0 / terrain 0",
			[td.terrain_set, td.terrain], [0, 0])
	check_eq("D2  ... which in the DONOR was named", a.get_terrain_name(0, 0), "grass_0")
	check_eq("D3  ... and in the RECEIVER is a different terrain entirely",
			b.get_terrain_name(0, 0), "water_0")


## E1-E3: when the donor's terrain set index does not exist in the receiver,
## the index is still kept, now dangling. The peering bit reads back as -1:
## the terrain wiring the merge was supposed to preserve is gone, and the only
## trace is an out-of-bounds error the engine prints when something asks.
func check_dangling_terrain_set() -> void:
	var a := make_ts("grass", 2, "kind_a")   # tile sits on terrain set 1
	var b := make_ts("water", 1, "kind_b")   # receiver has only terrain set 0
	var id := b.add_source(a.get_source(SRC_ID).duplicate(true))
	var td := tile_of(b, id)
	check_eq("E1  the copied tile keeps terrain_set 1", td.terrain_set, 1)
	check_eq("E2  ... but the receiver has only 1 terrain set, so index 1 is"
			+ " out of bounds", b.get_terrain_sets_count(), 1)
	check_eq("E3  ... and the peering bit reads back as -1: terrain lost",
			td.get_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE), -1)


## F1-F2: custom data travels by layer INDEX, not by name. The value written
## under the donor's layer 0 comes back under the receiver's layer 0, which is
## a different layer with a different name — and, when the types differ, a
## different type.
func check_custom_data_travels_by_index() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")
	var id := b.add_source(a.get_source(SRC_ID).duplicate(true))
	var td := tile_of(b, id)
	check_eq("F1  the copy's layer-0 value is the donor's value",
			td.get_custom_data_by_layer_id(0), "from-grass")
	check_eq("F2  ... now answering to the RECEIVER's layer name",
			b.get_custom_data_layer_name(0), "kind_b")


## G1-G2: the control. Remapping the indices by NAME before the copy is what
## the merge has to do, and after it the tile paints the terrain it was drawn
## for. Without this check, D-F would only prove that something is broken, not
## that anything fixes it.
func check_remap_by_name_is_the_fix() -> void:
	var a := make_ts("grass", 1, "kind_a")
	var b := make_ts("water", 1, "kind_b")

	# Give the receiver the donor's terrain and layer, by name.
	b.add_terrain_set()
	var new_set := b.get_terrain_sets_count() - 1
	b.set_terrain_set_mode(new_set, a.get_terrain_set_mode(0))
	b.add_terrain(new_set)
	b.set_terrain_name(new_set, 0, a.get_terrain_name(0, 0))
	b.add_custom_data_layer()
	var new_layer := b.get_custom_data_layers_count() - 1
	b.set_custom_data_layer_name(new_layer, a.get_custom_data_layer_name(0))
	b.set_custom_data_layer_type(new_layer, a.get_custom_data_layer_type(0))

	var id := b.add_source(a.get_source(SRC_ID).duplicate(true))
	var td := tile_of(b, id)
	# Read the donor's values BEFORE overwriting, then rewrite them at the
	# receiver's indices. This is the whole of "merging by hand", in code.
	var donor_value: Variant = tile_of(a, SRC_ID).get_custom_data_by_layer_id(0)
	td.terrain_set = new_set
	td.terrain = 0
	td.set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_RIGHT_SIDE, 0)
	td.set_custom_data_by_layer_id(new_layer, donor_value)
	td.set_custom_data_by_layer_id(0, null)

	check_eq("G1  after remapping, the tile paints the terrain it was drawn for",
			b.get_terrain_name(td.terrain_set, td.terrain), "grass_0")
	check_eq("G2  ... and its custom data sits under the donor's layer name",
			[b.get_custom_data_layer_name(new_layer),
			td.get_custom_data_by_layer_id(new_layer)], ["kind_a", "from-grass"])


## H1-H3: physics layers are positional too, and the failure is the same shape.
## The donor's tile carries a collision polygon on physics layer 1; the
## receiver has only physics layer 0, so the polygon comes across attached to
## an index that does not exist there and stops being collision at all.
func check_physics_layer_index_travels() -> void:
	var a := make_ts("grass", 1, "kind_a", 2)   # polygon on physics layer 1
	var b := make_ts("water", 1, "kind_b", 1)   # receiver has only layer 0
	var id := b.add_source(a.get_source(SRC_ID).duplicate(true))
	var td := tile_of(b, id)
	check_eq("H1  the donor's tile has its polygon on physics layer 1",
			tile_of(a, SRC_ID).get_collision_polygons_count(1), 1)
	check_eq("H2  the receiver has a single physics layer",
			b.get_physics_layers_count(), 1)
	check_eq("H3  ... so under the receiver, layer 0 has no polygon: the"
			+ " collision did not come across", td.get_collision_polygons_count(0), 0)


## I1-I2: the masks differ per layer, so H3 is not comparing a layer with an
## identical twin — landing on the wrong physics index is a different
## collision story, not a harmless renumbering.
func check_physics_layers_are_distinguishable() -> void:
	var a := make_ts("grass", 1, "kind_a", 2)
	check_eq("I1  donor physics layer 0 mask", a.get_physics_layer_collision_layer(0), 1)
	check_eq("I2  donor physics layer 1 mask", a.get_physics_layer_collision_layer(1), 2)


func _init() -> void:
	print("engine: " + Engine.get_version_info().string)
	print("")
	check_add_source_is_a_move()
	check_duplicate_is_a_copy()
	check_source_ids_are_not_preserved()
	check_terrain_index_changes_meaning()
	check_dangling_terrain_set()
	check_custom_data_travels_by_index()
	check_remap_by_name_is_the_fix()
	check_physics_layer_index_travels()
	check_physics_layers_are_distinguishable()

	print("")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % failures)
	quit(1 if failures > 0 else 0)
