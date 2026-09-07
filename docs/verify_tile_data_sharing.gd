extends SceneTree
##
## Reproduces every claim in docs/why-one-cell-changed-every-cell.md against a
## real engine.
##
## Standalone: builds its own TileSet in memory, needs no project assets.
##
##     godot --headless --script verify_tile_data_sharing.gd
##
## Optionally point it at your own TileSet to see the sharing on your tiles:
##
##     godot --headless --script verify_tile_data_sharing.gd -- res://your.tres
##
## Prints PASS/FAIL per check; exit code 0 only if all pass.
##
## Why this file exists next to verify_tile_transforms.gd: that one proves a
## flipped cell does not get its own TileData. This one proves the wider rule
## that fact is a special case of — TileData belongs to the TileSet, never to
## the cell — and measures how far a runtime write to it travels: across cells,
## across TileMapLayers, and into the file ResourceSaver writes.
##
## NOT covered here, deliberately: TileMapLayer._tile_data_runtime_update().
## Headless it never fired in our runs (0 calls after both
## notify_runtime_tile_data_update() and update_internals()), so this script
## makes no claim about it. See the doc for what that hook is for.
##
## Also measured here (S20-S22): there is no private copy of a TileData to
## take. TileData extends Object, not Resource, and has no duplicate() at all.
## Calling one raises "Nonexistent function" — and because a runtime error in
## a SceneTree _init never reaches quit(), the process then sits there. That
## looks like a hang and is not one: a nonexistent call on a plain Node hangs
## the same way. The engine is not stuck in duplicate(); the script died
## before it could quit.

const SRC_ID := 7

var failures := 0
var checks := 0


func check(name: String, cond: bool) -> void:
	checks += 1
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		failures += 1


func check_eq(name: String, got: Variant, want: Variant) -> void:
	checks += 1
	var ok: bool = got == want
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


## A 2x2 atlas under source id 7, with one custom data layer and one physics
## layer — the two places a runtime write usually lands.
func make_tileset() -> TileSet:
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
	return ts


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	print("engine: %s" % Engine.get_version_info().string)
	print("")

	if not ClassDB.class_exists("TileMapLayer"):
		print("SKIP  TileMapLayer does not exist on this build (it landed in 4.3).")
		print("      The same sharing rule holds for TileMap, but this script")
		print("      does not test the pre-4.3 path.")
		quit(0)
		return

	var ts := make_tileset()
	var src: TileSetAtlasSource = ts.get_source(SRC_ID)

	var layer = ClassDB.instantiate("TileMapLayer")  # untyped on purpose: naming
	# the class directly is a parse error on 4.2, which has no TileMapLayer
	layer.set("tile_set", ts)
	root.add_child(layer)

	# Four cells. A and B are the same tile in two places. C is a different
	# tile. D is the same tile as A, placed flipped — the transform bits ride
	# in the alternative field, which is why D is the interesting one.
	layer.set_cell(Vector2i(0, 0), SRC_ID, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(5, 5), SRC_ID, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(9, 9), SRC_ID, Vector2i(1, 0), 0)
	layer.set_cell(Vector2i(3, 3), SRC_ID, Vector2i(0, 0), 4096)  # TRANSFORM_FLIP_H

	var a: TileData = layer.get_cell_tile_data(Vector2i(0, 0))
	var b: TileData = layer.get_cell_tile_data(Vector2i(5, 5))
	var c: TileData = layer.get_cell_tile_data(Vector2i(9, 9))
	var d: TileData = layer.get_cell_tile_data(Vector2i(3, 3))
	var owned: TileData = src.get_tile_data(Vector2i(0, 0), 0)

	print("-- what get_cell_tile_data() hands you")
	check("S1  two cells of the same tile are ONE TileData object",
		a.get_instance_id() == b.get_instance_id())
	check("S2  that object is the TileSet's own TileData, not a per-cell copy",
		a.get_instance_id() == owned.get_instance_id())
	check("S3  a cell of a different atlas tile is a different object",
		a.get_instance_id() != c.get_instance_id())
	check("S4  a FLIPPED cell resolves to the same object as the unflipped one",
		a.get_instance_id() == d.get_instance_id())

	print("")
	print("-- how far one runtime write travels")
	a.set_custom_data("label", "written-via-A")
	check_eq("S5  the other cell of that tile reads it",
		b.get_custom_data("label"), "written-via-A")
	check_eq("S6  the TileSet itself reads it",
		owned.get_custom_data("label"), "written-via-A")
	check_eq("S7  the flipped cell reads it",
		d.get_custom_data("label"), "written-via-A")
	check_eq("S8  a cell of a DIFFERENT tile does not (blast radius is the tile)",
		c.get_custom_data("label"), null)

	var other = ClassDB.instantiate("TileMapLayer")
	other.set("tile_set", ts)
	root.add_child(other)
	other.set_cell(Vector2i(0, 0), SRC_ID, Vector2i(0, 0), 0)
	var f: TileData = other.get_cell_tile_data(Vector2i(0, 0))
	check("S9  a cell in a DIFFERENT TileMapLayer is the same object",
		a.get_instance_id() == f.get_instance_id())
	check_eq("S10  ...and reads the write too",
		f.get_custom_data("label"), "written-via-A")

	a.add_collision_polygon(0)
	check_eq("S11  collision polygons are shared the same way",
		b.get_collision_polygons_count(0), 1)

	print("")
	print("-- the write is not confined to this run")
	var path := "user://verify_tile_data_sharing_out.tres"
	var err := ResourceSaver.save(ts, path)
	check_eq("S12  the TileSet saves without error", err, OK)
	var txt := FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	check("S13  the saved file contains the runtime write",
		txt.find("written-via-A") != -1)

	print("")
	print("-- the real per-tile escape hatch, and what it costs")
	var alt := src.create_alternative_tile(Vector2i(0, 0))
	var altd: TileData = src.get_tile_data(Vector2i(0, 0), alt)
	check("S14  create_alternative_tile() gives a DIFFERENT TileData object",
		a.get_instance_id() != altd.get_instance_id())
	check_eq("S15  the alternative does NOT inherit custom data",
		altd.get_custom_data("label"), null)
	check_eq("S16  ...nor terrain_set", altd.terrain_set, -1)
	check_eq("S17  ...nor terrain", altd.terrain, -1)
	check_eq("S18  ...nor collision polygons", altd.get_collision_polygons_count(0), 0)
	check_eq("S19  ...nor z_index", altd.z_index, 0)

	print("")
	print("-- there is no private copy to take")
	check_eq("S20  TileData's parent class is Object",
		ClassDB.get_parent_class("TileData"), "Object")
	check("S21  TileData does NOT inherit Resource",
		not ClassDB.is_parent_class("TileData", "Resource"))
	check("S22  TileData has no duplicate() method",
		not owned.has_method("duplicate"))

	if not args.is_empty():
		print("")
		print("-- your own TileSet: %s" % args[0])
		verify_user_tileset(args[0])

	print("")
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


## Shows the same sharing on the caller's real tileset: finds the first atlas
## source with at least two tiles and reports whether two reads of one tile
## come back as one object.
func verify_user_tileset(res_path: String) -> void:
	var ts := ResourceLoader.load(res_path) as TileSet
	if ts == null:
		print("      could not load a TileSet from %s" % res_path)
		failures += 1
		return
	for i in range(ts.get_source_count()):
		var sid := ts.get_source_id(i)
		var src := ts.get_source(sid) as TileSetAtlasSource
		if src == null or src.get_tiles_count() < 1:
			continue
		var coords := src.get_tile_id(0)
		var one := src.get_tile_data(coords, 0)
		var two := src.get_tile_data(coords, 0)
		check("source %d tile %s: two reads are one object" % [sid, coords],
			one.get_instance_id() == two.get_instance_id())
		return
	print("      no atlas source with tiles found; nothing to check")
