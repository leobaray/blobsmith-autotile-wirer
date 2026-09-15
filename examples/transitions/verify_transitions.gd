extends SceneTree

# Runs every claim in examples/transitions/README.md against a real Godot 4
# binary. Use verify_transitions.sh; it builds a throwaway project around this
# folder so nothing is written into yours.
#
# The claim that matters: grass painted with Connect over sand leaves no cell
# empty and no seam — every pair of touching cells agrees on every shared side
# and corner. "Agrees" is read from the engine's own TileData, not from pixels.

var failures := 0
var selftest := OS.get_environment("LG_SELFTEST") == "1"

func check(id: String, text: String, cond: bool) -> void:
	if selftest and id == "T6":
		cond = not cond
	print(("PASS  " if cond else "FAIL  ") + id + " " + text)
	if not cond:
		failures += 1

func note(id: String, text: String) -> void:
	print("NOTE  " + id + " " + text)

const W := 14
const H := 11
# a lake of grass in a sand field: straight edges, a 1-cell peninsula, a 1-cell
# hole, a lone island, and two blobs touching only at a corner
const GRASS := [
	"..............",
	"..####........",
	"..#####.......",
	"..##.###......",
	"..######......",
	"....##........",
	"........#.....",
	"..........##..",
	".........###..",
	"........#.....",
	"..............",
]

# [offset to the neighbour, my bit toward it, its bit toward me]
const PAIRS := [
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[Vector2i(1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(-1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
	# a side neighbour shares two corners with me as well
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(1, 0), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
	[Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
]

const ALL_BITS := [
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
]

# paints the field and returns [empty cells, disagreeing pairs, grass cells not grass, sand cells not sand]
func paint(ts: TileSet) -> Array:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	var all: Array[Vector2i] = []
	var grass: Array[Vector2i] = []
	for y in range(H):
		for x in range(W):
			all.append(Vector2i(x, y))
			if GRASS[y][x] == "#":
				grass.append(Vector2i(x, y))
	layer.set_cells_terrain_connect(all, 0, 1, false)
	layer.set_cells_terrain_connect(grass, 0, 0, false)
	var empty := 0
	var bad := 0
	var grass_wrong := 0
	var sand_wrong := 0
	for c in all:
		var td := layer.get_cell_tile_data(c)
		if td == null:
			empty += 1
			continue
		var want := 0 if GRASS[c.y][c.x] == "#" else 1
		if td.terrain != want:
			if want == 0:
				grass_wrong += 1
			else:
				sand_wrong += 1
		for p in PAIRS:
			var n: Vector2i = c + p[0]
			if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
				continue
			var nd := layer.get_cell_tile_data(n)
			if nd != null and td.get_terrain_peering_bit(p[1]) != nd.get_terrain_peering_bit(p[2]):
				bad += 1
	layer.queue_free()
	root.remove_child(layer)
	return [empty, bad, grass_wrong, sand_wrong]

func _initialize() -> void:
	print("Godot " + Engine.get_version_info()["string"])
	var f := FileAccess.open("res://transitions/manifest.json", FileAccess.READ)
	if f == null:
		print("TRANSITIONS: manifest.json missing")
		quit(3)
		return
	for entry in JSON.parse_string(f.get_as_text()):
		var base: String = entry["base"]
		var ts: TileSet = load("res://transitions/%s.tres" % base)
		if ts == null:
			check("T1", "%s loads" % base, false)
			continue
		var src := ts.get_source(0) as TileSetAtlasSource
		check("T1", "%s loads with its texture next to it (%dx%d)" % [base, src.texture.get_width(), src.texture.get_height()],
			src.texture != null and src.texture.get_width() == int(entry["sheet_w"]))
		check("T2", "%s has 48 tiles in one atlas" % base, src.get_tiles_count() == 48)
		check("T3", "%s has ONE terrain set, Match Corners and Sides, with two terrains Grass=0 and Sand=1" % base,
			ts.get_terrain_sets_count() == 1 and ts.get_terrain_set_mode(0) == TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES
			and ts.get_terrains_count(0) == 2 and ts.get_terrain_name(0, 0) == "Grass" and ts.get_terrain_name(0, 1) == "Sand")
		var polys := 0
		for i in range(src.get_tiles_count()):
			if src.get_tile_data(src.get_tile_id(i), 0).get_collision_polygons_count(0) == 1:
				polys += 1
		check("T4", "%s: 48/48 tiles carry a collision polygon (got %d)" % [base, polys], polys == 48)

		var r := paint(ts)
		check("T5", "%s: sand field + grass lake, %d cells, 0 left empty (got %d)" % [base, W * H, r[0]], r[0] == 0)
		check("T6", "%s: every touching pair agrees on every shared side and corner (disagreements: %d)" % [base, r[1]], r[1] == 0)
		check("T7", "%s: every cell painted Grass is a Grass tile and every cell painted Sand is a Sand tile (wrong: %d grass, %d sand)" % [base, r[2], r[3]],
			r[2] == 0 and r[3] == 0)

		# control: the same sheet with every Sand bit erased is what a
		# "terrain against empty" set looks like. Painted over sand, it must show
		# the seams the two-terrain set exists to remove.
		var ctl: TileSet = ts.duplicate(true)
		var csrc := ctl.get_source(0) as TileSetAtlasSource
		for i in range(47):
			var td := csrc.get_tile_data(csrc.get_tile_id(i), 0)
			for b in ALL_BITS:
				if td.get_terrain_peering_bit(b) == 1:
					td.set_terrain_peering_bit(b, -1)
		var cr := paint(ctl)
		note("C1", "%s control (Sand bits erased): empty %d, disagreements %d, wrong grass %d, wrong sand %d" % [base, cr[0], cr[1], cr[2], cr[3]])
		check("T8", "%s: with the Sand bits erased the same paint is NOT clean" % base, cr[0] + cr[1] + cr[2] + cr[3] > 0)

	print("TRANSITIONS: " + ("ALL PASS" if failures == 0 else "%d FAIL" % failures))
	quit(1 if failures > 0 else 0)
