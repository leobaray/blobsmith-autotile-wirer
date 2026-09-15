extends SceneTree
##
## Reproduces every claim in docs/why-my-tiles-cast-no-shadow.md against a real
## engine.
##
## Standalone: builds its own TileSets, TileMapLayers and PointLight2D in memory,
## needs no project assets. Run through verify_tile_occlusion.sh, which builds
## the empty project this script expects and gives it a real GL context.
##
## Every scene is the same row: a grey floor 96x48, a PointLight2D at (8,24), one
## 16 px occluder tile at cell (3,1), i.e. x 48..64, y 16..32. A pixel reads
## "lit" when the light added to the floor, "dark" when it did not.
##
## Prints PASS/FAIL per check and a final "TILE OCCLUSION:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

const FLOOR := 0.25

var failures := 0
var vp: SubViewport
var light: PointLight2D
var layer: TileMapLayer


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = typeof(got) == typeof(want) and got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))
	if not ok:
		failures += 1


func light_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 256
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t


func square(offset := Vector2.ZERO) -> OccluderPolygon2D:
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-8, -8) + offset, Vector2(8, -8) + offset, Vector2(8, 8) + offset, Vector2(-8, 8) + offset])
	return poly


# Puts `poly` on occlusion layer 0 of the tile, with whichever API the engine
# has. 4.4 added several occluders per layer and deprecated set_occluder().
func put_occluder(td: TileData, poly: OccluderPolygon2D, legacy := false) -> void:
	if td.has_method("set_occluder_polygons_count") and not legacy:
		td.set_occluder_polygons_count(0, 1)
		td.set_occluder_polygon(0, 0, poly)
	else:
		td.set_occluder(0, poly)


# opts: shadow (bool, default true), texture (bool, default true),
# occlusion_layer (bool, default true), occ_mask, shadow_mask, poly_offset,
# legacy_api, tile_color (default transparent), node_occluder (a LightOccluder2D
# node instead of the tile).
func scene(opts := {}) -> void:
	if vp:
		vp.queue_free()
	vp = SubViewport.new()
	vp.size = Vector2i(96, 48)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color(FLOOR, FLOOR, FLOOR)
	bg.size = Vector2(96, 48)
	if opts.has("floor_mask"):
		bg.light_mask = opts.floor_mask
	vp.add_child(bg)

	light = PointLight2D.new()
	light.position = Vector2(8, 24)
	if opts.get("texture", true):
		light.texture = light_texture()
	light.shadow_enabled = opts.get("shadow", true)
	if opts.has("shadow_mask"):
		light.shadow_item_cull_mask = opts.shadow_mask
	vp.add_child(light)

	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	if opts.get("occlusion_layer", true):
		ts.add_occlusion_layer()
		if opts.has("occ_mask"):
			ts.set_occlusion_layer_light_mask(0, opts.occ_mask)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(opts.get("tile_color", Color(0, 0, 0, 0)))
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(Vector2i(0, 0))
	ts.add_source(src)
	if opts.get("occlusion_layer", true) and not opts.get("node_occluder", false):
		put_occluder(src.get_tile_data(Vector2i(0, 0), 0), square(opts.get("poly_offset", Vector2.ZERO)), opts.get("legacy_api", false))

	layer = TileMapLayer.new()
	layer.tile_set = ts
	vp.add_child(layer)
	layer.set_cell(Vector2i(3, 1), 0, Vector2i(0, 0))

	if opts.get("node_occluder", false):
		var occ := LightOccluder2D.new()
		occ.occluder = square()
		occ.position = Vector2(56, 24)
		if opts.has("occ_mask"):
			occ.occluder_light_mask = opts.occ_mask
		vp.add_child(occ)


func lit(img: Image, x: int, y: int) -> String:
	return "lit" if img.get_pixel(x, y).r > FLOOR + 0.05 else "dark"


# "front/behind" — a pixel between light and tile, and one past the tile.
func shot(front := Vector2i(30, 24), behind := Vector2i(80, 24)) -> String:
	for i in 4:
		await process_frame
	var img := vp.get_texture().get_image()
	return lit(img, front.x, front.y) + "/" + lit(img, behind.x, behind.y)


func brightness(at: Vector2i) -> float:
	for i in 4:
		await process_frame
	return snappedf(vp.get_texture().get_image().get_pixel(at.x, at.y).r, 0.01)


func _initialize() -> void:
	var v := Engine.get_version_info()
	var minor: int = v.minor
	print("Godot Engine v" + v.string)

	# K1: the control scene. A LightOccluder2D node, the thing every tutorial
	# starts with, shadows the floor past it — so "dark" is measurable here.
	scene({"node_occluder": true})
	check_eq("K1 control: a LightOccluder2D node shadows the floor behind it", await shot(), "lit/dark")

	# S1: the whole setup done right casts the same shadow from a tile.
	scene()
	check_eq("S1 occlusion layer + polygon on the tile + shadow_enabled light: shadow behind the tile", await shot(), "lit/dark")

	# S2: shadow_enabled is off by default, and then nothing casts, tile or node.
	check_eq("S2 PointLight2D.shadow_enabled defaults to false", PointLight2D.new().shadow_enabled, false)
	scene({"shadow": false})
	check_eq("S2 same scene, shadow_enabled = false: no shadow", await shot(), "lit/lit")
	scene({"shadow": false, "node_occluder": true})
	check_eq("S2 ... and a LightOccluder2D node casts none either", await shot(), "lit/lit")

	# S3: a PointLight2D with no texture lights nothing.
	scene({"texture": false})
	check_eq("S3 PointLight2D without a texture: nothing lit, before or behind", await shot(), "dark/dark")

	# L1: an occluder cannot be added without an occlusion layer.
	scene({"occlusion_layer": false})
	check_eq("L1 TileSet with no occlusion layer: no shadow", await shot(), "lit/lit")
	check_eq("L1 ... a new TileSet has 0 occlusion layers", TileSet.new().get_occlusion_layers_count(), 0)

	# M1: the occlusion layer's light_mask has to share a bit with the light's
	# shadow_item_cull_mask. Both default to 1.
	var ts := TileSet.new()
	ts.add_occlusion_layer()
	check_eq("M1 occlusion layer light_mask defaults to 1", ts.get_occlusion_layer_light_mask(0), 1)
	check_eq("M1 PointLight2D.shadow_item_cull_mask defaults to 1", PointLight2D.new().shadow_item_cull_mask, 1)
	scene({"occ_mask": 2})
	check_eq("M1 occlusion light_mask 2, light shadow mask 1: no shadow", await shot(), "lit/lit")
	scene({"shadow_mask": 2})
	check_eq("M1 occlusion light_mask 1, light shadow mask 2: no shadow", await shot(), "lit/lit")
	scene({"occ_mask": 3, "shadow_mask": 2, "floor_mask": 3})
	check_eq("M2 control: occlusion mask 3, shadow mask 2, floor light_mask 3: shadow", await shot(), "lit/dark")
	scene({"occ_mask": 3, "shadow_mask": 2, "node_occluder": true, "floor_mask": 3})
	check_eq("M2 ... same with a LightOccluder2D node (occluder_light_mask 3)", await shot(), "lit/dark")

	# M3: 4.4+ also needs the RECEIVING item's light_mask to share a bit with
	# shadow_item_cull_mask. Floor light_mask 1, shadow mask 2: 4.3 shadows it,
	# 4.4+ leaves it lit. Same for a node occluder.
	scene({"occ_mask": 3, "shadow_mask": 2, "floor_mask": 1})
	check_eq("M3 floor light_mask 1, shadow mask 2 (occluder 3): shadow only on 4.3", await shot(), "lit/dark" if minor < 4 else "lit/lit")
	scene({"occ_mask": 3, "shadow_mask": 2, "floor_mask": 1, "node_occluder": true})
	check_eq("M3 ... same with a LightOccluder2D node", await shot(), "lit/dark" if minor < 4 else "lit/lit")

	# P1: polygon points are relative to the tile's CENTER. Drawn from the top-left
	# corner (0..16), the occluder sits half a tile down-right. Row y=18 passes
	# through the real tile but above the shifted polygon.
	scene()
	check_eq("P1 centered polygon (-8..8) shadows the row y=18 behind the tile", await shot(Vector2i(30, 18), Vector2i(80, 18)), "lit/dark")
	scene({"poly_offset": Vector2(8, 8)})
	check_eq("P1 polygon drawn 0..16: the same row is lit, the shadow moved half a tile", await shot(Vector2i(30, 18), Vector2i(80, 18)), "lit/lit")

	# A1: API by version.
	var td := TileData.new()
	check_eq("A1 TileData.set_occluder() exists", td.has_method("set_occluder"), true)
	check_eq("A1 TileData.set_occluder_polygon(layer, index, polygon) exists", td.has_method("set_occluder_polygon"), minor >= 4)
	if minor >= 4:
		scene({"legacy_api": true})
		check_eq("A2 4.4+: the deprecated set_occluder(0, polygon) still casts", await shot(), "lit/dark")

	# O1: TileMapLayer.occlusion_enabled — 4.4+.
	var probe_layer := TileMapLayer.new()
	check_eq("O1 TileMapLayer has occlusion_enabled", "occlusion_enabled" in probe_layer, minor >= 4)
	if minor >= 4:
		check_eq("O1 occlusion_enabled defaults to true", probe_layer.get("occlusion_enabled"), true)
		scene()
		layer.set("occlusion_enabled", false)
		check_eq("O1 occlusion_enabled = false: no shadow", await shot(), "lit/lit")
		layer.set("occlusion_enabled", true)
		check_eq("O2 back to true at runtime: shadow again", await shot(), "lit/dark")
	probe_layer.free()

	# T1: an opaque tile under its own occluder is not lit by that light, it is
	# drawn in its own shadow. Measured at the tile's center.
	scene({"tile_color": Color(0.5, 0.5, 0.5), "shadow": false})
	var no_shadow := await brightness(Vector2i(56, 24))
	scene({"tile_color": Color(0.5, 0.5, 0.5)})
	var with_shadow := await brightness(Vector2i(56, 24))
	check_eq("T1 opaque tile, light without shadows: tile brighter than its texture (lit)", no_shadow > 0.55, true)
	check_eq("T1 same tile under its own occluder: drawn at its texture value 0.5 (not lit)", with_shadow, 0.5)
	print("INFO  T1 tile center brightness: no shadow %s, own occluder %s" % [no_shadow, with_shadow])

	if failures == 0:
		print("TILE OCCLUSION: ALL PASS")
	else:
		print("TILE OCCLUSION: %d FAIL" % failures)
	quit(0 if failures == 0 else 1)
