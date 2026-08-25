# The engine can say `set_layer_z_index` is gone. It cannot say what to write
# instead — that part of docs/tilemap-script-scan-core.js is OUR claim. This makes
# the claim falsifiable in the cheapest possible way: every replacement the
# scanner names has to actually EXIST on TileMapLayer in this binary, inherited
# members included, and the three renamed enum constants have to still carry the
# values TileMap gave them.
#
#   godot --headless --path <proj> --script check_tilemap_replacements.gd -- \
#       --targets='clear_layer|call|clear;set_layer_z_index|prop|z_index;...' \
#       --enums='VISIBILITY_MODE_DEFAULT|DEBUG_VISIBILITY_MODE_DEFAULT;...'
#
# The lists come out of the core file itself, so a replacement added there without
# a real member behind it fails here. Driven by docs/verify_tilemap_script_api.sh.
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

func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""

func _has_property(cls: String, prop: String) -> bool:
	for p in ClassDB.class_get_property_list(cls, false):
		if p["name"] == prop:
			return true
	return false

func _init() -> void:
	if not ClassDB.class_exists("TileMapLayer"):
		print("SKIP  this engine has no TileMapLayer")
		quit(0)
		return

	for entry in _arg("--targets=").split(";", false):
		var bits := entry.split("|")
		if bits.size() != 3:
			continue
		var who: String = bits[0]
		var kind: String = bits[1]
		var target: String = bits[2]
		if kind == "call":
			_ck("%s -> TileMapLayer.%s()" % [who, target],
				ClassDB.class_has_method("TileMapLayer", target, false),
				"no such method" if not ClassDB.class_has_method("TileMapLayer", target, false) else "")
		else:
			_ck("%s -> TileMapLayer.%s" % [who, target],
				_has_property("TileMapLayer", target),
				"no such property" if not _has_property("TileMapLayer", target) else "")

	for entry in _arg("--enums=").split(";", false):
		var bits := entry.split("|")
		if bits.size() != 2:
			continue
		var from_name: String = bits[0]
		var to_name: String = bits[1]
		var has_new := ClassDB.class_has_integer_constant("TileMapLayer", to_name)
		_ck("TileMapLayer.%s exists" % to_name, has_new)
		if has_new and ClassDB.class_has_integer_constant("TileMap", from_name):
			var a := ClassDB.class_get_integer_constant("TileMap", from_name)
			var b := ClassDB.class_get_integer_constant("TileMapLayer", to_name)
			_ck("%s == %s" % [from_name, to_name], a == b, "%d vs %d" % [a, b])

	# The scanner tells people the wrapper is a Node2D and that the layers hang
	# under it. If TileMapLayer ever stops being a Node2D, that advice is wrong.
	_ck("TileMapLayer is a Node2D", ClassDB.is_parent_class("TileMapLayer", "Node2D"))
	# And TileMap not being removed is why a stale `is TileMap` still compiles —
	# the scanner says so, so it has to be true.
	_ck("TileMap still exists in this engine", ClassDB.class_exists("TileMap"))

	print("REPLACEMENTS: %d checks, %d failures" % [checks, failures])
	if failures == 0:
		print("REPLACEMENTS VERIFY: ALL PASS")
	quit(1 if failures > 0 else 0)
