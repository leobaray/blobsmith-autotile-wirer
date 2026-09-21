extends SceneTree

# check_tileset_occluders.gd — point it at YOUR TileSet or YOUR scene, not ours.
#
#   godot --headless --script check_tileset_occluders.gd -- res://tiles/my_tiles.tres
#   godot --headless --script check_tileset_occluders.gd -- res://levels/level_1.tscn
#   godot --headless --script check_tileset_occluders.gd -- --for-4.3 res://tiles/a.tres
#
# Exit 0 = nothing found. Exit 1 = at least one FAULT. Exit 2 = usage / nothing
# to check.
#
# A TileSet (.tres / .res) is checked for the ways its tiles end up casting no
# shadow. A tile counts as a WALL when it carries a collision polygon on a
# physics layer whose collision_layer is not 0.
#
#   NO-OCCLUSION-LAYER   the TileSet has no occlusion layer at all. Every
#                        occluder you draw has nowhere to live.
#   LIGHT-MASK-ZERO      an occlusion layer's light_mask is 0: its occluders
#                        match no light's shadow_item_cull_mask, ever.
#   NO-OCCLUDERS         occlusion layers exist but not one tile carries an
#                        occluder polygon on any of them.
#   WALL-NO-OCCLUDER     a wall tile (collision) carries no occluder: light goes
#                        through the thing the player bumps into. Usually the
#                        tiles added after you drew the first ones.
#   POLYGON-DEGENERATE   an occluder polygon with fewer than 3 points or zero
#                        area: the resource exists and encloses nothing.
#   POLYGON-OFFSET       a vertex lies outside the centred cell (-w/2,-h/2)..
#                        (w/2,h/2): the polygon was authored from (0,0) to (w,h)
#                        and the shadow starts half a tile down-right of the art.
#   FORMAT-4.4           (only with --for-4.3) the file stores an occluder under
#                        the key Godot 4.4+ writes, occlusion_layer_N/polygon_M/
#                        polygon. Godot 4.3 loads that tile with NO occluder and
#                        prints nothing. Without --for-4.3 this is a NOTE line.
#
# A scene (.tscn / .scn) is instantiated and every Light2D in it is checked
# against every TileMapLayer whose TileSet carries at least one occluder:
#
#   LIGHT-SHADOW-OFF     the light's shadow_enabled is false — the default.
#   LIGHT-NO-TEXTURE     a PointLight2D with no texture lights nothing at all.
#   MASK-MISMATCH        shadows on, but no occlusion layer's light_mask shares a
#                        bit with the light's shadow_item_cull_mask.
#   OCCLUSION-DISABLED   (4.4+) the TileMapLayer's occlusion_enabled is false.
#   RECEIVER-MASK        (4.4+) the TileMapLayer's own light_mask shares no bit
#                        with the light's shadow_item_cull_mask: since 4.4 the
#                        item RECEIVING the shadow is filtered too, and the
#                        floor painted on that layer is lit but never shadowed.
#                        4.3 shadows it, so on 4.3 this is not reported.
#
# MIT. Part of the free Blobsmith light-occluder pack —
# https://github.com/leobaray/blobsmith-autotile-wirer

var faults := 0
var tiles_seen := 0
var lights_seen := 0
var for_43 := false

func fault(code: String, what: String) -> void:
	faults += 1
	print("FAULT %s  %s" % [code, what])

func minor() -> int:
	return int(Engine.get_version_info().minor)

# every occluder polygon of a tile on one layer, with whichever API the engine has
func occluders_of(td: TileData, layer: int) -> Array:
	var out := []
	if td.has_method("get_occluder_polygons_count"):
		for i in range(int(td.call("get_occluder_polygons_count", layer))):
			var p: OccluderPolygon2D = td.call("get_occluder_polygon", layer, i)
			if p != null:
				out.append(p)
	else:
		var p: OccluderPolygon2D = td.get_occluder(layer)
		if p != null:
			out.append(p)
	return out

func area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(pts.size()):
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

func tileset_has_occluder(ts: TileSet) -> bool:
	for si in range(ts.get_source_count()):
		var src := ts.get_source(ts.get_source_id(si)) as TileSetAtlasSource
		if src == null:
			continue
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			for alt in range(src.get_alternative_tiles_count(coords)):
				var td := src.get_tile_data(coords, src.get_alternative_tile_id(coords, alt))
				for l in range(ts.get_occlusion_layers_count()):
					if td != null and not occluders_of(td, l).is_empty():
						return true
	return false

func check_tileset(p: String, ts: TileSet) -> void:
	var occ_layers := ts.get_occlusion_layers_count()
	var faults_before := faults
	print("TILESET %s  tile_size=%s  occlusion_layers=%d  physics_layers=%d  sources=%d"
		% [p, str(ts.tile_size), occ_layers, ts.get_physics_layers_count(), ts.get_source_count()])
	# the file itself: which key the occluders are stored under
	var text := FileAccess.get_file_as_string(p) if p.ends_with(".tres") else ""
	var re := RegEx.new()
	re.compile("(?m)^\\d+:\\d+/\\d+/occlusion_layer_\\d+/polygon_\\d+/polygon = ")
	var new_keys := re.search_all(text).size()
	if new_keys > 0:
		if for_43:
			fault("FORMAT-4.4", "%s stores %d occluder(s) under occlusion_layer_N/polygon_M/polygon — Godot 4.3 loads those tiles with no occluder and prints nothing" % [p, new_keys])
		else:
			print("NOTE FORMAT-4.4  %s stores %d occluder(s) under the 4.4+ key; Godot 4.3 would load them as no occluder (pass --for-4.3 to make this a fault)" % [p, new_keys])
	if occ_layers == 0:
		fault("NO-OCCLUSION-LAYER", "%s has no occlusion layer — no tile in it can ever cast a shadow" % p)
		return
	for l in range(occ_layers):
		if ts.get_occlusion_layer_light_mask(l) == 0:
			fault("LIGHT-MASK-ZERO", "%s occlusion layer %d has light_mask = 0 — no light's shadow_item_cull_mask can match it" % [p, l])
	var live_physics: Array[int] = []
	for l in range(ts.get_physics_layers_count()):
		if ts.get_physics_layer_collision_layer(l) != 0:
			live_physics.append(l)
	var hx := ts.tile_size.x * 0.5
	var hy := ts.tile_size.y * 0.5
	var with_occ := 0
	for si in range(ts.get_source_count()):
		var src := ts.get_source(ts.get_source_id(si)) as TileSetAtlasSource
		if src == null:
			continue
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			for alt in range(src.get_alternative_tiles_count(coords)):
				var td := src.get_tile_data(coords, src.get_alternative_tile_id(coords, alt))
				if td == null:
					continue
				tiles_seen += 1
				var is_wall := false
				for l in live_physics:
					if td.get_collision_polygons_count(l) > 0:
						is_wall = true
				var usable := 0
				for l in range(occ_layers):
					for poly in occluders_of(td, l):
						var pts: PackedVector2Array = poly.polygon
						if pts.size() < 3 or area(pts) < 0.001:
							fault("POLYGON-DEGENERATE", "%s tile %s occlusion layer %d: the occluder has %d point(s), area %.2f — it encloses no area" % [p, str(coords), l, pts.size(), area(pts)])
							continue
						usable += 1
						for v in pts:
							if absf(v.x) > hx + 0.001 or absf(v.y) > hy + 0.001:
								fault("POLYGON-OFFSET", "%s tile %s occlusion layer %d: vertex %s is outside the centred cell (%s..%s) — authored from (0,0), the shadow sits half a tile down-right"
									% [p, str(coords), l, str(v), str(Vector2(-hx, -hy)), str(Vector2(hx, hy))])
								break
				if usable > 0:
					with_occ += 1
				elif is_wall:
					fault("WALL-NO-OCCLUDER", "%s tile %s has collision and no occluder — light goes straight through it" % [p, str(coords)])
	if with_occ == 0 and faults == faults_before:
		fault("NO-OCCLUDERS", "%s has %d occlusion layer(s) and not one tile carries an occluder polygon" % [p, occ_layers])

func walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		walk(c, out)

func check_scene(p: String, ps: PackedScene) -> void:
	var inst := ps.instantiate()
	var nodes := []
	walk(inst, nodes)
	var layers := []
	var lights := []
	for n in nodes:
		if n is TileMapLayer and (n as TileMapLayer).tile_set != null and tileset_has_occluder((n as TileMapLayer).tile_set):
			layers.append(n)
		elif n is Light2D:
			lights.append(n)
	print("SCENE %s  occluding TileMapLayers=%d  lights=%d" % [p, layers.size(), lights.size()])
	for l in layers:
		var tml := l as TileMapLayer
		if "occlusion_enabled" in tml and tml.get("occlusion_enabled") == false:
			fault("OCCLUSION-DISABLED", "%s layer '%s' has occlusion_enabled = false — it casts no shadow" % [p, tml.name])
	for lt in lights:
		lights_seen += 1
		var light := lt as Light2D
		if light is PointLight2D and (light as PointLight2D).texture == null:
			fault("LIGHT-NO-TEXTURE", "%s light '%s' is a PointLight2D with no texture — it lights nothing" % [p, light.name])
		if layers.is_empty():
			continue
		if not light.shadow_enabled:
			fault("LIGHT-SHADOW-OFF", "%s light '%s' has shadow_enabled = false (the default) — no tile casts a shadow from it" % [p, light.name])
			continue
		for l in layers:
			var tml := l as TileMapLayer
			var ts := tml.tile_set
			var hit := false
			for k in range(ts.get_occlusion_layers_count()):
				if ts.get_occlusion_layer_light_mask(k) & light.shadow_item_cull_mask:
					hit = true
			if not hit:
				fault("MASK-MISMATCH", "%s light '%s' shadow_item_cull_mask = %d shares no bit with any occlusion layer light_mask of layer '%s' — its walls cast nothing from this light"
					% [p, light.name, light.shadow_item_cull_mask, tml.name])
			if minor() >= 4 and (tml.light_mask & light.shadow_item_cull_mask) == 0:
				fault("RECEIVER-MASK", "%s layer '%s' light_mask = %d shares no bit with light '%s' shadow_item_cull_mask = %d — on 4.4+ the floor on it is lit but never shadowed"
					% [p, tml.name, tml.light_mask, light.name, light.shadow_item_cull_mask])
	inst.free()

func check(p: String) -> void:
	var res: Resource = load(p)
	if res is TileSet:
		check_tileset(p, res)
	elif res is PackedScene:
		check_scene(p, res)
	else:
		print("ERROR  %s did not load as a TileSet or a scene" % p)
		faults += 1

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var paths := []
	for a in args:
		if a == "--for-4.3":
			for_43 = true
		else:
			paths.append(a)
	if paths.is_empty():
		print("usage: godot --headless --script check_tileset_occluders.gd -- [--for-4.3] res://path/to/tileset.tres|scene.tscn [more...]")
		quit(2)
		return
	for p in paths:
		check(p)
	if faults == 0:
		print("OCCLUDER-CHECK OK  %d tiles, %d lights, 0 faults" % [tiles_seen, lights_seen])
	else:
		print("OCCLUDER-CHECK %d FAULTS  over %d tiles, %d lights" % [faults, tiles_seen, lights_seen])
	quit(1 if faults > 0 else 0)
