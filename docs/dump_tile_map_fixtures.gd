extends SceneTree
##
## Emits tile_map_data fixtures produced by a REAL TileMapLayer, so a decoder
## written outside the engine can be judged against the engine instead of
## against our own prose.
##
## verify_tile_map_data.gd proves the doc matches Godot 4.7. This script exists
## because /godot-tile-map-data/ ships a JavaScript decoder to strangers, and a
## JS port of a correct spec can still be wrong: the spec is read by a human in
## the middle. Here the engine paints, erases and reloads; whatever bytes come
## out, plus whatever the engine then reads back from them, becomes the fixture
## the JS decoder has to reproduce exactly.
##
##     godot --headless --script dump_tile_map_fixtures.gd
##     # writes docs/tile-map-data-fixtures.json, exit 0
##
## Some cases feed the engine deliberately bad buffers, so ERROR lines from
## set_tile_map_data_from_array are expected output, not failures.

const HEADER_SIZE := 2
const RECORD_SIZE := 12
const EMPTY_SOURCE := 0xFFFF

const OUT_PATH := "res://tile-map-data-fixtures.json"

var fixtures: Array = []


## Same TileSet the doc's examples assume: atlas source id 7, 2x2 tiles,
## alternative 5 on tile (0,0).
func make_layer() -> TileMapLayer:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))

	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)

	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	for y in range(2):
		for x in range(2):
			src.create_tile(Vector2i(x, y))
	src.create_alternative_tile(Vector2i(0, 0), 5)
	ts.add_source(src, 7)

	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	return layer


func put_cell(buf: PackedByteArray, index: int, coords: Vector2i,
		source_id: int, atlas: Vector2i, alternative: int) -> void:
	var o := HEADER_SIZE + index * RECORD_SIZE
	buf.encode_s16(o + 0, coords.x)
	buf.encode_s16(o + 2, coords.y)
	buf.encode_u16(o + 4, source_id)
	buf.encode_u16(o + 6, atlas.x)
	buf.encode_u16(o + 8, atlas.y)
	buf.encode_u16(o + 10, alternative)


func make_buffer(cell_count: int) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(HEADER_SIZE + cell_count * RECORD_SIZE)
	buf.encode_u16(0, 0)
	return buf


## What the engine says is on the map, in a form JSON can carry.
## Sorted by coordinate: record order is insertion order (documented), and the
## decoder under test is not being asked to reproduce that here.
func read_back(layer: TileMapLayer) -> Array:
	var cells := layer.get_used_cells()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y if a.y != b.y else a.x < b.x)
	var out: Array = []
	for c in cells:
		# get_cell_alternative_tile() sign-extends: mask back to the 16 bits
		# that were actually serialized before splitting id from flags.
		var raw: int = layer.get_cell_alternative_tile(c) & 0xFFFF
		var atlas: Vector2i = layer.get_cell_atlas_coords(c)
		out.append({
			"x": c.x, "y": c.y,
			"source_id": layer.get_cell_source_id(c),
			"atlas_x": atlas.x, "atlas_y": atlas.y,
			"alternative": raw & 0x0FFF,
			"flip_h": (raw & 0x1000) != 0,
			"flip_v": (raw & 0x2000) != 0,
			"transpose": (raw & 0x4000) != 0,
		})
	return out


## One fixture: the bytes, and what a fresh engine layer reads out of them.
## `refused` records the header>0 case, where the assignment is a no-op and the
## layer keeps whatever it had — which is why the probe layer is pre-painted.
func record(name: String, note: String, data: PackedByteArray, prepaint: bool = false) -> void:
	var probe := make_layer()
	if prepaint:
		probe.set_cell(Vector2i(9, 9), 7, Vector2i(1, 1), 0)
	probe.tile_map_data = data
	var bytes: Array = []
	for b in data:
		bytes.append(b)
	fixtures.append({
		"name": name,
		"note": note,
		"bytes": bytes,
		"engine_cells": read_back(probe),
		"prepainted": prepaint,
	})
	probe.queue_free()


func _initialize() -> void:
	# 1. The doc's worked example, painted by the engine rather than written by
	#    hand — so the bytes printed on the page are the engine's own, flip bit
	#    included, and not a transcription anybody has to be trusted about.
	var layer := make_layer()
	layer.set_cell(Vector2i(1, 2), 7, Vector2i(1, 1), 0)
	layer.set_cell(Vector2i(2, 2), 7, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_FLIP_H)
	layer.set_cell(Vector2i(-1, -1), 7, Vector2i(0, 0), 0)
	record("painted_three", "the doc's worked example: three cells, one flipped, one at negative coords",
		layer.tile_map_data)

	# 2. Alternative id and all three transform flags in one field.
	var flags := make_buffer(4)
	put_cell(flags, 0, Vector2i(0, 0), 7, Vector2i(0, 0), 5)
	put_cell(flags, 1, Vector2i(1, 0), 7, Vector2i(0, 0), 5 | 0x1000)
	put_cell(flags, 2, Vector2i(2, 0), 7, Vector2i(0, 0), 5 | 0x2000 | 0x4000)
	put_cell(flags, 3, Vector2i(3, 0), 7, Vector2i(0, 0), 5 | 0x1000 | 0x2000 | 0x4000)
	record("transform_flags", "alternative 5 with every combination of the flag bits", flags)

	# 3. erase_cell() leaves a 12-byte tombstone behind.
	var erased := make_layer()
	erased.set_cell(Vector2i(1, 1), 7, Vector2i(0, 0), 0)
	erased.set_cell(Vector2i(2, 2), 7, Vector2i(1, 0), 0)
	erased.erase_cell(Vector2i(1, 1))
	record("tombstone", "two cells painted, the first erased — the record stays",
		erased.tile_map_data)

	# 4. A layer painted and fully cleared: all tombstones, no cells.
	var cleared := make_layer()
	cleared.set_cell(Vector2i(0, 0), 7, Vector2i(0, 0), 0)
	cleared.set_cell(Vector2i(1, 0), 7, Vector2i(1, 0), 0)
	cleared.erase_cell(Vector2i(0, 0))
	cleared.erase_cell(Vector2i(1, 0))
	record("all_tombstones", "every cell erased — the buffer does not shrink",
		cleared.tile_map_data)

	# 5. Two records for the same coordinate: the last one wins.
	var dup := make_buffer(2)
	put_cell(dup, 0, Vector2i(4, 4), 7, Vector2i(0, 0), 0)
	put_cell(dup, 1, Vector2i(4, 4), 7, Vector2i(1, 1), 5)
	record("duplicate_coords", "same coordinate twice in one buffer", dup)

	# 6. A tombstone record that lands on a coordinate an earlier record painted.
	var dup_erase := make_buffer(2)
	put_cell(dup_erase, 0, Vector2i(5, 5), 7, Vector2i(0, 0), 0)
	put_cell(dup_erase, 1, Vector2i(5, 5), EMPTY_SOURCE, Vector2i(0xFFFF, 0xFFFF), 0xFFFF)
	record("tombstone_over_painted", "a tombstone record after a painted one at the same coordinate",
		dup_erase)

	# 7. The int16 extremes, both of which round-trip.
	var extremes := make_buffer(2)
	put_cell(extremes, 0, Vector2i(-32768, -32768), 7, Vector2i(0, 0), 0)
	put_cell(extremes, 1, Vector2i(32767, 32767), 7, Vector2i(1, 1), 0)
	record("int16_extremes", "the corners of the usable coordinate range", extremes)

	# 8. A coordinate outside int16, encoded the way serialization encodes it.
	var wrapped := make_buffer(1)
	put_cell(wrapped, 0, Vector2i(40000, -40000), 7, Vector2i(0, 0), 0)
	record("wrapped_coords", "set_cell(40000, -40000) as it survives serialization", wrapped)

	# 9. Empty layer: an empty array, not a lone header.
	record("empty_layer", "a layer with nothing painted", PackedByteArray())

	# 10. Trailing partial record — complete records load, the stub is dropped.
	var truncated := make_buffer(2)
	put_cell(truncated, 0, Vector2i(0, 0), 7, Vector2i(0, 0), 0)
	put_cell(truncated, 1, Vector2i(1, 0), 7, Vector2i(1, 0), 0)
	truncated.resize(truncated.size() - 5)
	record("truncated_record", "(len - 2) % 12 != 0 — the engine keeps the whole records",
		truncated)

	# 11. Unsupported format in the header — the assignment is refused outright
	#     and the layer keeps its previous contents (hence prepaint).
	var bad_header := make_buffer(1)
	put_cell(bad_header, 0, Vector2i(0, 0), 7, Vector2i(0, 0), 0)
	bad_header.encode_u16(0, 1)
	record("bad_header", "format 1 — refused, the layer keeps what it had before",
		bad_header, true)

	# 12. A buffer of two bytes and nothing else.
	record("header_only", "a lone 2-byte header with no records", make_buffer(0))

	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("cannot write " + OUT_PATH)
		quit(1)
		return
	f.store_string(JSON.stringify({
		"engine": Engine.get_version_info()["string"],
		"generator": "docs/dump_tile_map_fixtures.gd",
		"fixtures": fixtures,
	}, "  "))
	f.close()
	print("wrote %d fixtures to %s" % [fixtures.size(), OUT_PATH])
	quit(0)
