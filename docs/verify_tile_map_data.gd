extends SceneTree
##
## Reproduces every claim in docs/tile-map-data-format.md against a real engine.
##
## Standalone: builds its own TileSet in memory, needs no project assets.
##
##     godot --headless --script verify_tile_map_data.gd
##
## Prints PASS/FAIL per check; exit code 0 only if all pass. Some checks
## deliberately feed the engine bad buffers, so ERROR lines from
## set_tile_map_data_from_array are expected output, not failures.

const HEADER_SIZE := 2
const RECORD_SIZE := 12
const EMPTY_SOURCE := 0xFFFF

const FLIP_H := 0x1000
const FLIP_V := 0x2000
const TRANSPOSE := 0x4000

# The worked example from the doc: three cells in one buffer.
const EXAMPLE_HEX := "0000010002000700010001000000020002000700000000000010ffffffff0700000000000000"

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


## A TileSet with one atlas source under id 7, four tiles, plus alternative 5
## on tile (0,0) — the shape the doc's examples assume.
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


## Little-endian record writer — the encoder the doc describes.
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
	buf.encode_u16(0, 0)  # TILE_MAP_LAYER_DATA_FORMAT_0
	return buf


func _initialize() -> void:
	print("--- layout ---")
	layout()
	print("--- worked example (docs/tile-map-data-format.md) ---")
	worked_example()
	print("--- transform flags ---")
	transform_flags()
	print("--- erased cells ---")
	erased_cells()
	print("--- int16 coordinate range ---")
	coordinate_range()
	print("--- rejected buffers ---")
	rejected_buffers()

	print("")
	if failures == 0:
		print("TILE_MAP_DATA VERIFY: ALL PASS")
		quit(0)
	else:
		print("TILE_MAP_DATA VERIFY: %d FAILED" % failures)
		quit(1)


func layout() -> void:
	var layer := make_layer()
	layer.set_cell(Vector2i(0, 0), 7, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(1, 0), 7, Vector2i(1, 0), 0)
	layer.set_cell(Vector2i(0, 1), 7, Vector2i(0, 1), 5)
	var data := layer.tile_map_data

	check_eq("3 cells -> 2 + 3*12 bytes", data.size(), HEADER_SIZE + 3 * RECORD_SIZE)
	check_eq("(len - 2) % 12 == 0", (data.size() - HEADER_SIZE) % RECORD_SIZE, 0)
	check_eq("header is format 0", data.decode_u16(0), 0)

	# Fields at the documented offsets, for the (0,1) cell with alternative 5.
	var o := HEADER_SIZE + 2 * RECORD_SIZE
	check_eq("+0 coords.x (int16)", data.decode_s16(o + 0), 0)
	check_eq("+2 coords.y (int16)", data.decode_s16(o + 2), 1)
	check_eq("+4 source_id (uint16)", data.decode_u16(o + 4), 7)
	check_eq("+6 atlas.x (uint16)", data.decode_u16(o + 6), 0)
	check_eq("+8 atlas.y (uint16)", data.decode_u16(o + 8), 1)
	check_eq("+10 alternative (uint16)", data.decode_u16(o + 10), 5)


func worked_example() -> void:
	# Build the doc's example by hand from the spec alone...
	var buf := make_buffer(3)
	put_cell(buf, 0, Vector2i(1, 2), 7, Vector2i(1, 1), 0)
	put_cell(buf, 1, Vector2i(2, 2), 7, Vector2i(0, 0), FLIP_H)
	put_cell(buf, 2, Vector2i(-1, -1), 7, Vector2i(0, 0), 0)
	check_eq("hand-encoded bytes match the doc", buf.hex_encode(), EXAMPLE_HEX)

	# ...and prove the engine reads it as the doc's table says.
	var layer := make_layer()
	layer.tile_map_data = buf
	check_eq("cell (1,2) source", layer.get_cell_source_id(Vector2i(1, 2)), 7)
	check_eq("cell (1,2) atlas", layer.get_cell_atlas_coords(Vector2i(1, 2)), Vector2i(1, 1))
	check_eq("cell (2,2) flipped h", layer.is_cell_flipped_h(Vector2i(2, 2)), true)
	check_eq("cell (-1,-1) source (negative coords)",
		layer.get_cell_source_id(Vector2i(-1, -1)), 7)
	check_eq("exactly 3 used cells", layer.get_used_cells().size(), 3)

	# Round-trip through a saved scene: same bytes back out.
	layer.name = "Example"
	var packed := PackedScene.new()
	packed.pack(layer)
	var path := "user://tile_map_data_example.tscn"
	check_eq("scene saves", ResourceSaver.save(packed, path), OK)
	var reloaded := (load(path) as PackedScene).instantiate() as TileMapLayer
	check_eq("bytes survive save + reload", reloaded.tile_map_data.hex_encode(), EXAMPLE_HEX)
	reloaded.free()


func transform_flags() -> void:
	var layer := make_layer()
	layer.set_cell(Vector2i(0, 0), 7, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_FLIP_H)
	layer.set_cell(Vector2i(1, 0), 7, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_FLIP_V)
	layer.set_cell(Vector2i(2, 0), 7, Vector2i(0, 0), TileSetAtlasSource.TRANSFORM_TRANSPOSE)
	var data := layer.tile_map_data

	check_eq("FLIP_H == 0x1000", TileSetAtlasSource.TRANSFORM_FLIP_H, FLIP_H)
	check_eq("FLIP_V == 0x2000", TileSetAtlasSource.TRANSFORM_FLIP_V, FLIP_V)
	check_eq("TRANSPOSE == 0x4000", TileSetAtlasSource.TRANSFORM_TRANSPOSE, TRANSPOSE)
	check_eq("flip_h lands in the alternative field",
		data.decode_u16(HEADER_SIZE + 0 * RECORD_SIZE + 10), FLIP_H)
	check_eq("flip_v lands in the alternative field",
		data.decode_u16(HEADER_SIZE + 1 * RECORD_SIZE + 10), FLIP_V)
	check_eq("transpose lands in the alternative field",
		data.decode_u16(HEADER_SIZE + 2 * RECORD_SIZE + 10), TRANSPOSE)

	# An alternative id coexists with all three flags in one 16-bit field.
	var mixed := make_layer()
	var buf := make_buffer(1)
	put_cell(buf, 0, Vector2i(0, 0), 7, Vector2i(0, 0), 5 | FLIP_H | FLIP_V | TRANSPOSE)
	mixed.tile_map_data = buf
	check_eq("alternative id survives alongside flags",
		mixed.get_cell_alternative_tile(Vector2i(0, 0)) & 0x0FFF, 5)
	check_eq("mixed: flipped h", mixed.is_cell_flipped_h(Vector2i(0, 0)), true)
	check_eq("mixed: flipped v", mixed.is_cell_flipped_v(Vector2i(0, 0)), true)
	check_eq("mixed: transposed", mixed.is_cell_transposed(Vector2i(0, 0)), true)


func erased_cells() -> void:
	var layer := make_layer()
	layer.set_cell(Vector2i(1, 1), 7, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(2, 2), 7, Vector2i(1, 0), 0)
	var before := layer.tile_map_data.size()
	layer.erase_cell(Vector2i(1, 1))
	var after := layer.tile_map_data

	check_eq("erasing does not shrink the buffer", after.size(), before)
	check_eq("erased record keeps its coordinates",
		Vector2i(after.decode_s16(HEADER_SIZE), after.decode_s16(HEADER_SIZE + 2)), Vector2i(1, 1))
	check_eq("erased record has source_id 0xFFFF",
		after.decode_u16(HEADER_SIZE + 4), EMPTY_SOURCE)
	check_eq("only one cell is actually used", layer.get_used_cells(), [Vector2i(2, 2)] as Array[Vector2i])

	# The tombstone reaches disk, so third-party parsers must skip it.
	layer.name = "Erased"
	var packed := PackedScene.new()
	packed.pack(layer)
	var path := "user://tile_map_data_erased.tscn"
	ResourceSaver.save(packed, path)
	var reloaded := (load(path) as PackedScene).instantiate() as TileMapLayer
	check_eq("tombstone survives save + reload", reloaded.tile_map_data.size(), before)
	check_eq("reloaded layer still has one cell", reloaded.get_used_cells().size(), 1)
	reloaded.free()

	# Re-encoding after a real edit does compact it.
	layer.set_cell(Vector2i(3, 3), 7, Vector2i(0, 0), 0)
	layer.erase_cell(Vector2i(3, 3))
	check("buffer never compacts on its own", layer.tile_map_data.size() >= before)


func coordinate_range() -> void:
	var layer := make_layer()
	layer.set_cell(Vector2i(40000, -40000), 7, Vector2i(0, 0), 0)
	check_eq("in memory the cell keeps its real coordinates",
		layer.get_cell_source_id(Vector2i(40000, -40000)), 7)

	var data := layer.tile_map_data
	check_eq("serialized x wraps to int16", data.decode_s16(HEADER_SIZE + 0), -25536)
	check_eq("serialized y wraps to int16", data.decode_s16(HEADER_SIZE + 2), 25536)

	var reloaded := make_layer()
	reloaded.tile_map_data = data
	check_eq("after a round-trip the cell has MOVED",
		reloaded.get_used_cells(), [Vector2i(-25536, 25536)] as Array[Vector2i])
	check_eq("nothing at the original coordinates",
		reloaded.get_cell_source_id(Vector2i(40000, -40000)), -1)

	# The extremes of the range are exact.
	var edge := make_layer()
	edge.set_cell(Vector2i(32767, -32768), 7, Vector2i(1, 0), 0)
	var edge_data := edge.tile_map_data
	var back := make_layer()
	back.tile_map_data = edge_data
	check_eq("32767 / -32768 round-trip exactly",
		back.get_used_cells(), [Vector2i(32767, -32768)] as Array[Vector2i])


func rejected_buffers() -> void:
	# Header above TILE_MAP_LAYER_DATA_FORMAT_0: the whole buffer is refused and
	# the layer keeps whatever it had — the assignment is a no-op, not a clear.
	var future := make_buffer(1)
	put_cell(future, 0, Vector2i(4, 4), 7, Vector2i(0, 0), 0)
	future.encode_u16(0, 1)
	var a := make_layer()
	a.set_cell(Vector2i(9, 9), 7, Vector2i(0, 0), 0)
	a.tile_map_data = future
	check_eq("unknown format: nothing from the new buffer is applied",
		a.get_cell_source_id(Vector2i(4, 4)), -1)
	check_eq("unknown format: previous content is untouched",
		a.get_used_cells(), [Vector2i(9, 9)] as Array[Vector2i])

	# Trailing bytes: complains, keeps the whole records it did read.
	var ragged := make_buffer(1)
	put_cell(ragged, 0, Vector2i(4, 4), 7, Vector2i(0, 0), 0)
	ragged.resize(ragged.size() + 5)
	var b := make_layer()
	b.tile_map_data = ragged
	check_eq("trailing bytes: complete records still load",
		b.get_used_cells(), [Vector2i(4, 4)] as Array[Vector2i])

	# Truncated final record: same rule, the partial record is dropped.
	var cut := make_buffer(2)
	put_cell(cut, 0, Vector2i(5, 5), 7, Vector2i(0, 0), 0)
	put_cell(cut, 1, Vector2i(6, 6), 7, Vector2i(0, 0), 0)
	cut.resize(cut.size() - 3)
	var c := make_layer()
	c.tile_map_data = cut
	check_eq("truncated record is dropped, earlier ones kept",
		c.get_used_cells(), [Vector2i(5, 5)] as Array[Vector2i])

	# Two records for one coordinate: the last one wins.
	var dup := make_buffer(2)
	put_cell(dup, 0, Vector2i(0, 0), 7, Vector2i(0, 0), 0)
	put_cell(dup, 1, Vector2i(0, 0), 7, Vector2i(1, 1), 0)
	var d := make_layer()
	d.tile_map_data = dup
	check_eq("duplicate coordinate: last record wins",
		d.get_cell_atlas_coords(Vector2i(0, 0)), Vector2i(1, 1))
	check_eq("duplicate coordinate collapses to one record",
		d.tile_map_data.size(), HEADER_SIZE + RECORD_SIZE)
