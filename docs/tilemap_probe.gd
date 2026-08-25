# The script under test. It is written the way a 2022 project is written — it
# `extends TileMap` and passes a layer index to everything — and it is fed to
# docs/scan_tilemap_script.js untouched by hand. Whatever that scanner writes is
# what Godot 4.7 runs; if the port is wrong, the digest below stops matching.
#
# Every call here is one the scanner rewrites on its own, on purpose: a fixture
# with a hand-finished line in it would be proving the hand, not the tool.
extends TileMap

func digest() -> String:
	var parts: Array[String] = []
	parts.append("name0=" + str(get_layer_name(0)))
	parts.append("name1=" + str(get_layer_name(1)))
	parts.append("name2=" + str(get_layer_name(2)))
	parts.append("enabled2=" + str(is_layer_enabled(2)))
	parts.append("modulate1=" + _color(get_layer_modulate(1)))
	parts.append("ysort1=" + str(is_layer_y_sort_enabled(1)))
	parts.append("ysortorigin1=" + str(get_layer_y_sort_origin(1)))
	parts.append("z1=" + str(get_layer_z_index(1)))
	parts.append("nav2=" + str(is_layer_navigation_enabled(2)))
	parts.append(_cells(0))
	parts.append(_cells(1))
	parts.append(_cells(2))
	return "|".join(parts)

# `str(Color)` is not stable across engines — 4.2 prints (1, 0.5, ...) and 4.7
# prints (1.0, 0.5, ...) for the same colour. The digest has to compare the scene,
# not the engine's printf, so the components are formatted here.
func _color(c: Color) -> String:
	return "%.4f/%.4f/%.4f/%.4f" % [c.r, c.g, c.b, c.a]

func _cells(layer: int) -> String:
	# One branch per layer index, because the whole point is that the index is a
	# literal at every call site: that is what lets a text tool know which node a
	# call means. A loop over layers would be exactly the case the scanner refuses
	# to guess about, and it says so.
	var cells: Array = []
	if layer == 0:
		cells = get_used_cells(0)
	elif layer == 1:
		cells = get_used_cells(1)
	else:
		cells = get_used_cells(2)
	cells.sort_custom(func(a, b): return [a.y, a.x] < [b.y, b.x])
	var out: Array[String] = []
	for c in cells:
		var sid := 0
		var atlas := Vector2i.ZERO
		var alt := 0
		if layer == 0:
			sid = get_cell_source_id(0, c)
			atlas = get_cell_atlas_coords(0, c)
			alt = get_cell_alternative_tile(0, c)
		elif layer == 1:
			sid = get_cell_source_id(1, c)
			atlas = get_cell_atlas_coords(1, c)
			alt = get_cell_alternative_tile(1, c)
		else:
			sid = get_cell_source_id(2, c)
			atlas = get_cell_atlas_coords(2, c)
			alt = get_cell_alternative_tile(2, c)
		out.append("%s:%d:%s:%d" % [str(c), sid, str(atlas), alt])
	return "L%d[%s]" % [layer, ",".join(out)]
