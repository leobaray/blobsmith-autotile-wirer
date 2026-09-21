extends SceneTree

# check_tileset_custom_data.gd — point it at YOUR TileSet, not ours.
#
#   godot --headless --script check_tileset_custom_data.gd -- res://tiles/my_tiles.tres
#   godot --headless --script check_tileset_custom_data.gd -- res://tiles/a.tres res://tiles/b.tres --scripts res://
#
# Exit 0 = nothing found. Exit 1 = at least one FAULT. Exit 2 = usage / nothing
# to check.
#
# With --scripts DIR it also reads every .gd file under DIR (not .godot/) and
# collects the layer names your code passes, as a quoted literal, to the
# get/set custom data calls — then compares them with the layers the TileSets
# declare.
#
# FAULTS — the ways a TileSet's custom data reads back wrong without a word, in
# the order they bite:
#
#   NO-CUSTOM-DATA     the TileSet declares no custom data layer at all.
#   LAYER-NO-TYPE      a layer whose type is Nil — the type a layer added from
#                      code starts with. Every tile reads null from it.
#   LAYER-UNNAMED      a layer with an empty name: no name reaches it, only its
#                      id. (Godot refuses a second layer with a name already
#                      taken and leaves that one's name empty — this is how it
#                      happens.)
#   TYPE-MISMATCH      a tile's value is not of the layer's type. A value Godot
#                      cannot convert to the layer's type (a Vector2 in a String
#                      layer, "no" set from code on a bool layer and saved) loads
#                      as null, and the error surfaces later, somewhere else.
#                      A value it CAN convert is converted on load without a
#                      word: "7" set on a float layer comes back 7.0, and "abc"
#                      comes back 0.0 — the second one only DEFAULTS shows.
#   TILE-UNFILLED      a tile (or an alternative tile) where EVERY layer is at
#                      its type default ("", 0, 0.0, false) while other tiles in
#                      the same TileSet are filled in. That is the signature of a
#                      tile added after the layers were filled: it reads as a
#                      free (cost 0), unwalkable, nameless ground.
#   EMPTY-STRING       a String layer left "" on a tile that is otherwise filled
#                      in. A ground or sound name is never meant to be empty.
#   NAME-NOT-DECLARED  (--scripts) your code asks for a layer name that no
#                      TileSet checked declares: at run time that call returns
#                      null and prints "TileSet has no layer with name".
#
# NOTES — printed, not counted, because the value can be legitimate:
#
#   DEFAULTS           per layer, how many tiles sit at the type default. A 0
#                      damage or a false walkable is usually meant; a move_cost
#                      of 0.0 is a free cell AStarGrid2D accepts silently. The
#                      API cannot tell a written 0 from a value never written, so
#                      this list is the one to read.
#   NO-TERRAIN         a tile with no terrain in a TileSet that has terrain sets:
#                      the terrain painter never places it, so its data only ever
#                      reaches cells painted by hand (fine for decorations).
#   LAYER-NEVER-READ   (--scripts) a declared layer no script names.
#
# MIT. Part of the free Blobsmith tile-data pack —
# https://github.com/leobaray/blobsmith-autotile-wirer

var faults := 0
var tiles_seen := 0
var declared := {}      # layer name -> true, over every TileSet checked

func fault(code: String, what: String) -> void:
	faults += 1
	print("FAULT %s  %s" % [code, what])

func note(code: String, what: String) -> void:
	print("NOTE %s  %s" % [code, what])

# the value a tile reads for a layer of `type` it was never given
func default_of(type: int) -> Variant:
	match type:
		TYPE_STRING:
			return ""
		TYPE_STRING_NAME:
			return &""
		TYPE_BOOL:
			return false
		TYPE_INT:
			return 0
		TYPE_FLOAT:
			return 0.0
	return type_convert(null, type)

func is_default(v: Variant, type: int) -> bool:
	if type == TYPE_STRING or type == TYPE_STRING_NAME:
		return String(v) == ""
	return typeof(v) == type and v == default_of(type)

func type_ok(v: Variant, type: int) -> bool:
	if typeof(v) == type:
		return true
	# a String layer may hold a StringName and the other way round
	return (type == TYPE_STRING or type == TYPE_STRING_NAME) and (typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME)

func check(p: String) -> void:
	var res: Resource = load(p)
	if res == null or not (res is TileSet):
		print("ERROR  %s did not load as a TileSet" % p)
		faults += 1
		return
	var ts: TileSet = res
	var n_layers := ts.get_custom_data_layers_count()
	print("TILESET %s  tile_size=%s  custom_data_layers=%d  terrain_sets=%d  sources=%d"
		% [p, str(ts.tile_size), n_layers, ts.get_terrain_sets_count(), ts.get_source_count()])
	if n_layers == 0:
		fault("NO-CUSTOM-DATA", "%s declares no custom data layer — get_cell_tile_data() has nothing to give back" % p)
		return
	var typed: Array[int] = []
	for l in range(n_layers):
		var nm := ts.get_custom_data_layer_name(l)
		var ty := ts.get_custom_data_layer_type(l)
		if nm == "":
			fault("LAYER-UNNAMED", "%s custom data layer %d has no name — reachable only by id; a second layer given a name already taken is left unnamed" % [p, l])
		else:
			declared[nm] = true
		if ty == TYPE_NIL:
			fault("LAYER-NO-TYPE", "%s custom data layer %d '%s' has type Nil — every tile reads null" % [p, l, nm])
		else:
			typed.append(l)

	# gather every tile and alternative once
	var all_tiles: Array = []   # [label, TileData]
	for si in range(ts.get_source_count()):
		var sid := ts.get_source_id(si)
		var src := ts.get_source(sid) as TileSetAtlasSource
		if src == null:
			continue
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			for a in range(src.get_alternative_tiles_count(coords)):
				var alt := src.get_alternative_tile_id(coords, a)
				var td := src.get_tile_data(coords, alt)
				if td != null:
					all_tiles.append(["source %d tile %s%s" % [sid, str(coords), "" if alt == 0 else " alternative %d" % alt], td])
	tiles_seen += all_tiles.size()

	var filled_somewhere := false
	for t in all_tiles:
		for l in typed:
			if not is_default(t[1].get_custom_data_by_layer_id(l), ts.get_custom_data_layer_type(l)):
				filled_somewhere = true
	var at_default := {}
	for l in typed:
		at_default[l] = 0
	for t in all_tiles:
		var label: String = t[0]
		var td: TileData = t[1]
		var all_default := true
		var mismatched := false
		for l in typed:
			var ty := ts.get_custom_data_layer_type(l)
			var v: Variant = td.get_custom_data_by_layer_id(l)
			if not type_ok(v, ty):
				mismatched = true
				fault("TYPE-MISMATCH", "%s %s layer '%s' holds %s (type %s), not a %s"
					% [p, label, ts.get_custom_data_layer_name(l), var_to_str(v), type_string(typeof(v)), type_string(ty)])
				all_default = false
				continue
			if is_default(v, ty):
				at_default[l] += 1
			else:
				all_default = false
		if typed.size() > 0 and all_default and filled_somewhere:
			fault("TILE-UNFILLED", "%s %s has every custom data layer at its default while other tiles are filled — added after the layers, or a new alternative" % [p, label])
			continue
		if not mismatched:
			for l in typed:
				var ty := ts.get_custom_data_layer_type(l)
				if (ty == TYPE_STRING or ty == TYPE_STRING_NAME) and String(td.get_custom_data_by_layer_id(l)) == "":
					fault("EMPTY-STRING", "%s %s layer '%s' is an empty string" % [p, label, ts.get_custom_data_layer_name(l)])
		if ts.get_terrain_sets_count() > 0 and (td.terrain_set < 0 or td.terrain < 0):
			note("NO-TERRAIN", "%s %s has no terrain — the terrain painter never places it" % [p, label])
	for l in typed:
		var ty := ts.get_custom_data_layer_type(l)
		note("DEFAULTS", "%s layer '%s' (%s): %d of %d tiles at the default %s"
			% [p, ts.get_custom_data_layer_name(l), type_string(ty), at_default[l], all_tiles.size(), var_to_str(default_of(ty))])

# layer names used as a quoted literal in get/set custom data calls under `dir`
func scan_scripts(dir: String, into: Dictionary) -> void:
	var re := RegEx.new()
	re.compile("[gs]et_custom_data\\(\\s*&?[\"']([^\"']+)[\"']")
	var d := DirAccess.open(dir)
	if d == null:
		print("ERROR  --scripts %s is not a directory" % dir)
		faults += 1
		return
	d.list_dir_begin()
	var nm := d.get_next()
	while nm != "":
		var full := dir.path_join(nm)
		if d.current_is_dir():
			if not nm.begins_with("."):
				scan_scripts(full, into)
		elif nm.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(full)
			var lines := text.split("\n")
			for i in range(lines.size()):
				for m in re.search_all(lines[i]):
					var key := m.get_string(1)
					if not into.has(key):
						into[key] = []
					into[key].append("%s:%d" % [full, i + 1])
		nm = d.get_next()
	d.list_dir_end()

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var paths: Array[String] = []
	var scripts := ""
	var i := 0
	while i < args.size():
		if args[i] == "--scripts" and i + 1 < args.size():
			scripts = args[i + 1]
			i += 2
			continue
		paths.append(args[i])
		i += 1
	if paths.is_empty():
		print("usage: godot --headless --script check_tileset_custom_data.gd -- res://path/to/tileset.tres [more...] [--scripts res://]")
		quit(2)
		return
	for p in paths:
		check(p)
	if scripts != "":
		var used := {}
		scan_scripts(scripts, used)
		print("SCRIPTS %s  %d layer names used in code" % [scripts, used.size()])
		var names := used.keys()
		names.sort()
		for n in names:
			if not declared.has(n):
				fault("NAME-NOT-DECLARED", "'%s' (at %s) is not a layer of any TileSet checked — that call returns null and prints 'TileSet has no layer with name'"
					% [n, ", ".join(used[n])])
		var decl := declared.keys()
		decl.sort()
		for n in decl:
			if not used.has(n):
				note("LAYER-NEVER-READ", "layer '%s' is declared but no script under %s names it" % [n, scripts])
	if faults == 0:
		print("CUSTOM-DATA-CHECK OK  %d tiles, 0 faults" % tiles_seen)
	else:
		print("CUSTOM-DATA-CHECK %d FAULTS  over %d tiles" % [faults, tiles_seen])
	quit(1 if faults > 0 else 0)
