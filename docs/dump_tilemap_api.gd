# Prints the ENGINE's own idea of what `TileMap` and `TileMapLayer` expose, as one
# JSON line, so the mapping table in docs/tilemap-to-tilemaplayer-script-api.md is
# derived from a binary instead of typed from the online docs.
#
#   godot --headless --path <project> --script dump_tilemap_api.gd
#       prints  APIDUMP {"version": "...", "classes": {...}}
#
# A class that does not exist in this engine is simply absent: 4.2 has no
# `TileMapLayer`, 4.7 has no `TileMap`. That absence is data, not an error — the
# whole point of the table is that no single engine can produce it alone.
#
# Driven by docs/verify_tilemap_script_api.sh.
extends SceneTree

func _method_list(cls: String) -> Array:
	var out := []
	for m in ClassDB.class_get_method_list(cls, true):
		var args := []
		for a in m["args"]:
			args.append({
				"name": a["name"],
				"type": type_string(a["type"]),
				"class": str(a.get("class_name", "")),
			})
		out.append({
			"name": m["name"],
			"args": args,
			"ret": type_string(m["return"]["type"]),
			"ret_class": str(m["return"].get("class_name", "")),
		})
	out.sort_custom(func(a, b): return a["name"] < b["name"])
	return out

func _property_list(cls: String) -> Array:
	var out := []
	for p in ClassDB.class_get_property_list(cls, true):
		# Category/group headers carry no storage and no editor slot; they are
		# inspector furniture, not properties a script can touch.
		if not (p["usage"] & PROPERTY_USAGE_STORAGE or p["usage"] & PROPERTY_USAGE_EDITOR):
			continue
		out.append({"name": p["name"], "type": type_string(p["type"])})
	out.sort_custom(func(a, b): return a["name"] < b["name"])
	return out

func _init() -> void:
	var classes := {}
	for cls in ["TileMap", "TileMapLayer"]:
		if not ClassDB.class_exists(cls):
			continue
		var signals := []
		for s in ClassDB.class_get_signal_list(cls, true):
			signals.append(s["name"])
		signals.sort()
		var constants := []
		for c in ClassDB.class_get_integer_constant_list(cls, true):
			constants.append({
				"name": c,
				"value": ClassDB.class_get_integer_constant(cls, c),
				"enum": ClassDB.class_get_integer_constant_enum(cls, c, true),
			})
		constants.sort_custom(func(a, b): return a["name"] < b["name"])
		classes[cls] = {
			"parent": ClassDB.get_parent_class(cls),
			"methods": _method_list(cls),
			"properties": _property_list(cls),
			"signals": signals,
			"constants": constants,
		}
	print("APIDUMP ", JSON.stringify({
		"version": "%d.%d" % [Engine.get_version_info()["major"], Engine.get_version_info()["minor"]],
		"classes": classes,
	}))
	quit()
