extends SceneTree

# Engine gate for the free top-down dungeon pack.
#
# The README promises: paint floor, paint walls over it with Connect, and every
# wall cell gets a tile whose peering bits match its neighbours — and the front
# face shows on exactly the wall cells that have floor to their south. Both are
# asked of the engine here, not of the generator:
#
#   - a test room (corridors, pillars, 1-wide walls, thick blocks) is floored,
#     then its walls are painted with set_cells_terrain_connect; every wall cell
#     must carry the canonical 47-blob mask of its real neighbourhood, and every
#     floor cell must still be floor (painting walls must not eat the floor);
#   - a sweep paints all 47 neighbourhoods in isolation and demands each centre
#     lands on the tile of that mask, so all 47 tiles are reachable by painting;
#   - "has a face" is read from PIXELS: the imported texture is sampled and the
#     face-palette pixels of the tile the engine picked are counted. A face tile
#     is face palette in its whole lower half and nowhere else; any other tile
#     has none. The face must appear iff the cell to the south is floor;
#   - collision on wall cells only;
#   - painting the same walls one cell per call (the way editor strokes arrive)
#     gives the same tiles as one batch call.
#
# --invert flips the face expectation of one cell: the run must then exit 1.

var failures := 0
var checked := 0

func ck(id: String, cond: bool, what: String) -> void:
	checked += 1
	print(("PASS " if cond else "FAIL ") + id + "  " + what)
	if not cond:
		failures += 1

const ROOM := [
	"######################",
	"#....#.......#.......#",
	"#....#..##...#..#.#..#",
	"#.......##......#.#..#",
	"#....#.......#..###..#",
	"###.##########.......#",
	"#......#.............#",
	"#.##...#...#.#.#..####",
	"#.##.......#.#.#..#..#",
	"#......#...###.#.....#",
	"#..#...#.........##..#",
	"#......#.#.#.#...##..#",
	"#......#.............#",
	"######################",
]
const SWEEP_ORIGIN := Vector2i(0, 20)

# bit layout shared with the generator: N=1 NE=2 E=4 SE=8 S=16 SW=32 W=64 NW=128
const DIRS := [
	[1, Vector2i(0, -1), TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[2, Vector2i(1, -1), TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
	[4, Vector2i(1, 0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE],
	[8, Vector2i(1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER],
	[16, Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
	[32, Vector2i(-1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
	[64, Vector2i(-1, 0), TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[128, Vector2i(-1, -1), TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
]

func canonical(m: int) -> int:
	var c := m & 0b01010101
	if (m & 2) and (m & 1) and (m & 4): c |= 2
	if (m & 8) and (m & 16) and (m & 4): c |= 8
	if (m & 32) and (m & 16) and (m & 64): c |= 32
	if (m & 128) and (m & 1) and (m & 64): c |= 128
	return c

func all_masks() -> Array[int]:
	var seen := {}
	for m in range(256):
		seen[canonical(m)] = true
	var out: Array[int] = []
	for k in seen.keys():
		out.append(int(k))
	out.sort()
	return out

func tile_mask(td: TileData) -> int:
	var m := 0
	for d in DIRS:
		if td.get_terrain_peering_bit(d[2]) == 0:
			m |= int(d[0])
	return m

func neigh_mask(c: Vector2i, walls: Dictionary) -> int:
	var m := 0
	for d in DIRS:
		if walls.has(c + d[1]):
			m |= int(d[0])
	return canonical(m)

# floor cells and wall cells of the room + the 47-neighbourhood sweep
func build_map(masks: Array[int]) -> Dictionary:
	var floor_cells := {}
	var walls := {}
	var w: int = (ROOM[0] as String).length()
	# a one-cell floor margin: every wall then has either wall or floor to its south
	for y in range(-1, ROOM.size() + 1):
		for x in range(-1, w + 1):
			var ch := "."
			if y >= 0 and y < ROOM.size() and x >= 0 and x < w:
				ch = (ROOM[y] as String)[x]
			if ch == "#":
				walls[Vector2i(x, y)] = true
			else:
				floor_cells[Vector2i(x, y)] = true
	var centres := {}
	for i in range(masks.size()):
		var o := SWEEP_ORIGIN + Vector2i((i % 8) * 5, (i / 8) * 5)
		var ctr := o + Vector2i(2, 2)
		centres[ctr] = masks[i]
		var here := {ctr: true}
		for d in DIRS:
			if masks[i] & int(d[0]):
				here[ctr + d[1]] = true
		for y in range(5):
			for x in range(5):
				var c := o + Vector2i(x, y)
				if here.has(c):
					walls[c] = true
				else:
					floor_cells[c] = true
	return {"floor": floor_cells, "walls": walls, "centres": centres, "room_w": w}

func _initialize() -> void:
	var invert := "--invert" in OS.get_cmdline_user_args()
	var f := FileAccess.open("res://dungeon/manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL M0  manifest.json missing — pack was not staged")
		print("DUNGEON: 1 FAIL")
		quit(1)
		return
	var man: Variant = JSON.parse_string(f.get_as_text())
	if typeof(man) != TYPE_ARRAY or (man as Array).is_empty():
		print("FAIL M0  manifest.json did not parse into a non-empty array")
		print("DUNGEON: 1 FAIL")
		quit(1)
		return
	print("MANIFEST %d dungeon tilesets" % (man as Array).size())

	var masks := all_masks()
	var map := build_map(masks)
	var walls: Dictionary = map["walls"]
	var floors: Dictionary = map["floor"]
	var centres: Dictionary = map["centres"]
	var wall_list: Array[Vector2i] = []
	for c in walls.keys():
		wall_list.append(c)
	wall_list.sort()
	var room_walls := 0
	for c in wall_list:
		if c.y < SWEEP_ORIGIN.y:
			room_walls += 1

	for entry in man:
		var base: String = entry["base"]
		var T: int = int(entry["tile_size"])
		var floor_ac := Vector2i(int(entry["floor_atlas"][0]), int(entry["floor_atlas"][1]))
		var pal := {}
		for h in entry["face_palette"]:
			pal[(h as String).trim_prefix("#").to_lower()] = true

		var ts: TileSet = load("res://dungeon/%s.tres" % base)
		ck("D1", ts != null, "%s: tileset loads (relative texture path resolves)" % base)
		if ts == null:
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		ck("D2", src != null and src.texture != null and src.texture.get_width() == int(entry["sheet_w"])
			and src.texture.get_height() == int(entry["sheet_h"]),
			"%s: atlas texture is %dx%d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"])])
		if src == null or src.texture == null:
			continue
		ck("D3", src.get_tiles_count() == 48, "%s: 48 tiles in the atlas (47 wall + 1 floor)" % base)
		ck("D4", ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
			and ts.get_terrains_count(0) == 1 and ts.get_terrain_name(0, 0) == entry["terrain"],
			"%s: one terrain '%s', Match Corners and Sides" % [base, entry["terrain"]])
		ck("D5", ts.get_physics_layers_count() == 1 and ts.get_custom_data_layers_count() == 1
			and ts.get_custom_data_layer_name(0) == "wall_face" and ts.get_custom_data_layer_type(0) == TYPE_BOOL,
			"%s: one physics layer, custom data 'wall_face' (bool)" % base)

		# per-tile facts: mask, collision, custom data, and face pixels read from the texture
		var img := src.texture.get_image()
		var sq := PackedVector2Array([Vector2(-T / 2.0, -T / 2.0), Vector2(T / 2.0, -T / 2.0),
			Vector2(T / 2.0, T / 2.0), Vector2(-T / 2.0, T / 2.0)])
		var mask_of := {}        # atlas -> mask
		var face_of := {}        # atlas -> bool (pixels)
		var seen_masks := {}
		var poly_ok := 0
		var data_ok := 0
		var pix_ok := 0
		var wall_tiles := 0
		for i in range(src.get_tiles_count()):
			var ac := src.get_tile_id(i)
			var td := src.get_tile_data(ac, 0)
			var lower := 0
			var upper := 0
			for y in range(T):
				for x in range(T):
					if pal.has(img.get_pixel(ac.x * T + x, ac.y * T + y).to_html(false)):
						if y >= T / 2: lower += 1
						else: upper += 1
			var has_face := lower == T * T / 2 and upper == 0
			face_of[ac] = has_face
			if ac == floor_ac:
				ck("D6", td.terrain_set == -1 and td.get_collision_polygons_count(0) == 0 and lower + upper == 0,
					"%s: floor tile %s has no terrain, no collision, no face pixels" % [base, str(ac)])
				continue
			wall_tiles += 1
			var m := tile_mask(td)
			mask_of[ac] = m
			seen_masks[m] = true
			if td.get_collision_polygons_count(0) == 1 and td.get_collision_polygon_points(0, 0) == sq:
				poly_ok += 1
			var open_s := (m & 16) == 0
			if bool(td.get_custom_data("wall_face")) == open_s:
				data_ok += 1
			if (open_s and has_face) or (not open_s and lower + upper == 0):
				pix_ok += 1
		var all_canon := true
		for m in seen_masks.keys():
			if canonical(int(m)) != int(m):
				all_canon = false
		ck("D7", wall_tiles == 47 and seen_masks.size() == 47 and all_canon,
			"%s: the 47 wall tiles carry all 47 canonical peering combinations (got %d distinct)" % [base, seen_masks.size()])
		ck("D8", poly_ok == 47, "%s: 47/47 wall tiles carry the full-cell collision square (got %d)" % [base, poly_ok])
		ck("D9", data_ok == 47, "%s: 47/47 wall tiles have wall_face == (south side open) (got %d)" % [base, data_ok])
		ck("D10", pix_ok == 47,
			"%s: 47/47 wall tiles: face pixels fill the lower half iff the south side is open, none otherwise (got %d)" % [base, pix_ok])

		# --- paint: floor everywhere, then walls with Connect ------------------
		var layer := TileMapLayer.new()
		layer.tile_set = ts
		root.add_child(layer)
		for c in floors.keys():
			layer.set_cell(c, 0, floor_ac)
		for c in wall_list:
			layer.set_cell(c, 0, floor_ac)       # the walls go on top of a floored room
		layer.set_cells_terrain_connect(wall_list, 0, 0, false)

		var wall_painted := 0
		for c in wall_list:
			var td := layer.get_cell_tile_data(c)
			if td != null and td.terrain_set == 0 and td.terrain == 0:
				wall_painted += 1
		var floor_kept := 0
		for c in floors.keys():
			if layer.get_cell_source_id(c) == 0 and layer.get_cell_atlas_coords(c) == floor_ac:
				floor_kept += 1
		ck("D11", wall_painted == wall_list.size() and floor_kept == floors.size(),
			"%s: %d/%d wall cells got a wall tile, %d/%d floor cells are still floor" %
				[base, wall_painted, wall_list.size(), floor_kept, floors.size()])

		var matched := 0
		var first_bad := ""
		for c in wall_list:
			var ac := layer.get_cell_atlas_coords(c)
			if mask_of.has(ac) and int(mask_of[ac]) == neigh_mask(c, walls):
				matched += 1
			elif first_bad == "":
				first_bad = " first at %s: tile mask %s vs neighbours %d" % [str(c), str(mask_of.get(ac, "?")), neigh_mask(c, walls)]
		ck("D12", matched == wall_list.size(),
			"%s: every painted wall cell's tile bits match its neighbours: %d/%d%s" % [base, matched, wall_list.size(), first_bad])

		var picked := {}
		var sweep_ok := 0
		for ctr in centres.keys():
			var ac := layer.get_cell_atlas_coords(ctr)
			if mask_of.has(ac) and int(mask_of[ac]) == int(centres[ctr]):
				sweep_ok += 1
				picked[ac] = true
		ck("D13", sweep_ok == 47 and picked.size() == 47,
			"%s: sweep — each of the 47 neighbourhoods painted alone picks the tile of that mask (%d/47, %d distinct tiles)" %
				[base, sweep_ok, picked.size()])

		var face_ok := 0
		var faces := 0
		var room_faces := 0
		var bad_face := ""
		for c in wall_list:
			var want := floors.has(c + Vector2i(0, 1))
			if invert and c == wall_list[0]:
				want = not want                    # --invert: the gate must catch this
			var got: bool = face_of.get(layer.get_cell_atlas_coords(c), false)
			if got:
				faces += 1
				if c.y < SWEEP_ORIGIN.y:
					room_faces += 1
			if got == want:
				face_ok += 1
			elif bad_face == "":
				bad_face = " first at %s: face %s, floor to the south %s" % [str(c), str(got), str(want)]
		ck("D14", face_ok == wall_list.size(),
			"%s: the front face (read from pixels) shows exactly on wall cells with floor to the south: %d/%d (%d faces, %d in the room)%s" %
				[base, face_ok, wall_list.size(), faces, room_faces, bad_face])

		var col_ok := 0
		for c in wall_list:
			var td := layer.get_cell_tile_data(c)
			if td != null and td.get_collision_polygons_count(0) == 1:
				col_ok += 1
		for c in floors.keys():
			var td := layer.get_cell_tile_data(c)
			if td != null and td.get_collision_polygons_count(0) == 0:
				col_ok += 1
		ck("D15", col_ok == wall_list.size() + floors.size(),
			"%s: collision on wall cells only: %d/%d cells right" % [base, col_ok, wall_list.size() + floors.size()])

		# editor strokes arrive one cell at a time; the result must be the same
		var one := TileMapLayer.new()
		one.tile_set = ts
		root.add_child(one)
		for c in floors.keys():
			one.set_cell(c, 0, floor_ac)
		for c in wall_list:
			one.set_cell(c, 0, floor_ac)
		for c in wall_list:
			one.set_cells_terrain_connect([c], 0, 0, false)
		var same := 0
		for c in wall_list:
			if one.get_cell_atlas_coords(c) == layer.get_cell_atlas_coords(c):
				same += 1
		for c in floors.keys():
			if one.get_cell_atlas_coords(c) == floor_ac:
				same += 1
		ck("D16", same == wall_list.size() + floors.size(),
			"%s: painting the walls one cell per call gives the same map as one call: %d/%d cells" %
				[base, same, wall_list.size() + floors.size()])

		one.queue_free()
		root.remove_child(one)
		layer.queue_free()
		root.remove_child(layer)

	print("ROOM %d wall cells in the test room, %d in the 47-mask sweep" % [room_walls, wall_list.size() - room_walls])
	if failures == 0:
		print("DUNGEON %d/%d PASS" % [checked, checked])
	else:
		print("DUNGEON: %d FAIL of %d" % [failures, checked])
	quit(1 if failures > 0 else 0)
