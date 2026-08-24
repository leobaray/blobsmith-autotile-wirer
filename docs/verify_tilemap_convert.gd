# Proves docs/convert_tilemap_to_tilemaplayer.js against a real Godot binary.
#
# Driven by docs/verify_tilemap_convert.sh, which builds the "before" scene with
# docs/make_tilemap_fixture.gd first:
#
#   --headless --script verify_tilemap_convert.gd -- --keys=a,b,c
#       loads legacy.tscn and converted.tscn, and makes the ENGINE read both back
#       cell by cell. Nothing here trusts the converter's own report: every claim
#       is a comparison between what a TileMap says and what the TileMapLayer
#       nodes say. --keys is the converter's per-layer key table, checked against
#       the property list of THIS engine so a future Godot that adds a ninth
#       per-layer key fails here instead of losing it silently.
#
# Exit 0 only if every check passes.
extends SceneTree

var failures := 0
var checks := 0

func _ck(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if ok:
		print("PASS  ", name, ("  " + detail) if detail else "")
	else:
		failures += 1
		print("FAIL  ", name, "  ", detail)

func _eq(name: String, got, want) -> void:
	_ck(name, got == want, "got %s, want %s" % [str(got), str(want)])

func _init() -> void:
	var keys := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--keys="):
			keys = a.substr(7)
	_verify(keys)
	quit(1 if failures > 0 else 0)

# --- the comparison -------------------------------------------------------------

func _layer_keys_of_engine() -> Array:
	var probe := TileMap.new()
	var out := []
	for p in probe.get_property_list():
		var n := String(p.name)
		if n.begins_with("layer_0/"):
			out.append(n.substr(8))
	probe.free()
	return out

func _cells_of_tilemap(tm: TileMap, layer: int) -> Dictionary:
	var out := {}
	for c in tm.get_used_cells(layer):
		out[c] = [tm.get_cell_source_id(layer, c), tm.get_cell_atlas_coords(layer, c),
			tm.get_cell_alternative_tile(layer, c)]
	return out

func _cells_of_layer(l: TileMapLayer) -> Dictionary:
	var out := {}
	for c in l.get_used_cells():
		out[c] = [l.get_cell_source_id(c), l.get_cell_atlas_coords(c), l.get_cell_alternative_tile(c)]
	return out

func _compare_map(tm: TileMap, wrapper: Node, tag: String) -> void:
	_ck("%s: wrapper is a Node2D" % tag, wrapper is Node2D and not (wrapper is TileMap),
		"got %s" % wrapper.get_class())
	var layers := []
	for child in wrapper.get_children():
		if child is TileMapLayer:
			layers.append(child)
	_eq("%s: layer node count" % tag, layers.size(), tm.get_layers_count())
	if layers.size() != tm.get_layers_count():
		return

	for i in tm.get_layers_count():
		var l: TileMapLayer = layers[i]
		var t := "%s/%s" % [tag, tm.get_layer_name(i)]
		_eq("%s: node name" % t, l.name, StringName(tm.get_layer_name(i)))
		_eq("%s: enabled" % t, l.enabled, tm.is_layer_enabled(i))
		_eq("%s: modulate" % t, l.modulate, tm.get_layer_modulate(i))
		_eq("%s: y_sort_enabled" % t, l.y_sort_enabled, tm.is_layer_y_sort_enabled(i))
		_eq("%s: y_sort_origin" % t, l.y_sort_origin, tm.get_layer_y_sort_origin(i))
		_eq("%s: z_index" % t, l.z_index, tm.get_layer_z_index(i))
		_eq("%s: navigation_enabled" % t, l.navigation_enabled, tm.is_layer_navigation_enabled(i))
		# Not object identity: legacy.tscn and converted.tscn are two files, so each
		# one loads its own copy of the embedded TileSet. What has to hold is that
		# every extracted layer points at ONE TileSet — the map's — and that it is
		# the same tileset by content.
		_eq("%s: shares one tile_set with the other layers" % t, l.tile_set, layers[0].tile_set)
		_ck("%s: tile_set is not null" % t, l.tile_set != null)
		if l.tile_set != null:
			_eq("%s: tile_set tile_size" % t, l.tile_set.tile_size, tm.tile_set.tile_size)
			_eq("%s: tile_set source count" % t,
				l.tile_set.get_source_count(), tm.tile_set.get_source_count())
			var got_ids := []
			var want_ids := []
			for s in l.tile_set.get_source_count():
				got_ids.append(l.tile_set.get_source_id(s))
			for s in tm.tile_set.get_source_count():
				want_ids.append(tm.tile_set.get_source_id(s))
			_eq("%s: tile_set source ids" % t, got_ids, want_ids)
		_eq("%s: rendering_quadrant_size" % t, l.rendering_quadrant_size, tm.rendering_quadrant_size)
		_eq("%s: use_kinematic_bodies <- collision_animatable" % t,
			l.use_kinematic_bodies, tm.collision_animatable)
		_eq("%s: collision_visibility_mode" % t,
			int(l.collision_visibility_mode), int(tm.collision_visibility_mode))
		_eq("%s: navigation_visibility_mode" % t,
			int(l.navigation_visibility_mode), int(tm.navigation_visibility_mode))

		var want := _cells_of_tilemap(tm, i)
		var got := _cells_of_layer(l)
		_eq("%s: used cell count" % t, got.size(), want.size())
		var mismatched := []
		for c in want:
			if not got.has(c):
				mismatched.append("%s missing" % str(c))
			elif got[c] != want[c]:
				mismatched.append("%s: %s != %s" % [str(c), str(got[c]), str(want[c])])
		for c in got:
			if not want.has(c):
				mismatched.append("%s is extra" % str(c))
		_ck("%s: every cell identical (source, atlas, alternative)" % t,
			mismatched.is_empty(), ", ".join(mismatched.slice(0, 4)))

func _verify(keys_csv: String) -> void:
	var engine_keys := _layer_keys_of_engine()
	var converter_keys := []
	for k in keys_csv.split(",", false):
		converter_keys.append(k.strip_edges())
	var missing := []
	for k in engine_keys:
		if not converter_keys.has(k):
			missing.append(k)
	_ck("converter covers every per-layer key this engine writes", missing.is_empty(),
		"engine=%s converter=%s missing=%s" % [str(engine_keys), str(converter_keys), str(missing)])

	var legacy_scene: PackedScene = load("res://legacy.tscn")
	var converted_scene: PackedScene = load("res://converted.tscn")
	_ck("both scenes load", legacy_scene != null and converted_scene != null)
	if legacy_scene == null or converted_scene == null:
		return
	var legacy := legacy_scene.instantiate()
	var converted := converted_scene.instantiate()

	_ck("converted scene has no TileMap left", _count_class(converted, "TileMap") == 0,
		"found %d" % _count_class(converted, "TileMap"))
	_eq("converted scene root name", converted.name, legacy.name)

	var tm: TileMap = legacy.get_node("TileMap")
	_compare_map(tm, converted.get_node("TileMap"), "TileMap")
	var tm2: TileMap = legacy.get_node("Level/Background")
	_compare_map(tm2, converted.get_node("Level/Background"), "Level/Background")

	# The node that was already a child of the TileMap keeps its path AND its
	# transform. This is what breaks in a naive conversion and what silently
	# breaks every $Path in every script.
	var pin := converted.get_node_or_null("TileMap/SpawnPoint")
	_ck("child node path survives (TileMap/SpawnPoint)", pin != null)
	if pin != null:
		_eq("child node position", pin.position, legacy.get_node("TileMap/SpawnPoint").position)
	_eq("wrapper keeps the TileMap's transform",
		converted.get_node("TileMap").position, tm.position)

	# The bytes we wrote are bytes the engine agrees with: let it re-save the
	# converted scene from its own in-memory state and read that back.
	var ps := PackedScene.new()
	ps.pack(converted)
	var err := ResourceSaver.save(ps, "res://resaved.tscn")
	_ck("converted scene re-saves", err == OK, "err=%d" % err)
	var resaved_scene: PackedScene = load("res://resaved.tscn")
	if resaved_scene != null:
		var resaved := resaved_scene.instantiate()
		_compare_map(tm, resaved.get_node("TileMap"), "resaved TileMap")
		_compare_map(tm2, resaved.get_node("Level/Background"), "resaved Level/Background")

	print("")
	print("TILEMAP CONVERT VERIFY: %d checks, %d failed" % [checks, failures])
	if failures == 0:
		print("TILEMAP CONVERT VERIFY: ALL PASS")

func _count_class(node: Node, cls: String) -> int:
	var n := 1 if node.get_class() == cls else 0
	for c in node.get_children():
		n += _count_class(c, cls)
	return n
