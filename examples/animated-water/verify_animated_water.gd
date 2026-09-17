extends SceneTree
##
## Runs every claim in examples/animated-water/README.md against a real Godot 4
## binary. Use verify_animated_water.sh; it builds a throwaway project with this
## folder copied to res://animated-water/ so nothing is written into yours, and
## runs this script on a real GL context (xvfb-run) at --fixed-fps 60, so one
## rendered frame is exactly 1/60 s of engine time and a 0.2 s animation frame
## lasts 12 rendered frames. Which animation frame is on screen is read back from
## rendered pixels and matched against the atlas image.
##
## Every expected value was first printed by an exploratory pass (the NOTE lines)
## on 4.3, 4.4 and 4.7, and only then written down.
##
##   godot --rendering-driver opengl3 --fixed-fps 60 --path <proj> --script verify_animated_water.gd [-- --invert]
##
## --invert flips the expectation of W6 and W8 on purpose (4 FAILs: two checks,
## two tilesets), so a run that cannot fail is visible. Prints PASS/FAIL per check
## and a final "ANIMATED WATER:" line.

const DIR := "res://animated-water/"
const WATER := 0
const GRASS := 1

var failures := 0
var checks := 0
var invert := false
var manifest: Dictionary


func check(id: String, got: Variant, want: Variant, why: String) -> void:
	checks += 1
	if invert and (id == "W6" or id == "W8"):
		want = "deliberately wrong"
	var ok: bool = typeof(got) == typeof(want) and got == want
	if not ok:
		failures += 1
	print(("PASS " if ok else "FAIL ") + id + "  " + why + ("" if ok else "  (got %s, want %s)" % [var_to_str(got), var_to_str(want)]))


func note(id: String, text: String) -> void:
	print("NOTE %s %s" % [id, text])


# ---- the canonical 47-mask table, computed here, not read from the manifest -----
const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128
const BITS := [
	[N, Vector2i(0, -1), TileSet.CELL_NEIGHBOR_TOP_SIDE],
	[NE, Vector2i(1, -1), TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER],
	[E, Vector2i(1, 0), TileSet.CELL_NEIGHBOR_RIGHT_SIDE],
	[SE, Vector2i(1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER],
	[S, Vector2i(0, 1), TileSet.CELL_NEIGHBOR_BOTTOM_SIDE],
	[SW, Vector2i(-1, 1), TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER],
	[W, Vector2i(-1, 0), TileSet.CELL_NEIGHBOR_LEFT_SIDE],
	[NW, Vector2i(-1, -1), TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER],
]


func canonical(mask: int) -> int:
	var m := mask & 0b01010101
	if (mask & NE) and (mask & N) and (mask & E):
		m |= NE
	if (mask & SE) and (mask & S) and (mask & E):
		m |= SE
	if (mask & SW) and (mask & S) and (mask & W):
		m |= SW
	if (mask & NW) and (mask & N) and (mask & W):
		m |= NW
	return m


var blob47: Array = []   # ascending canonical masks
const GRASS_AT := Vector2i(28, 5)


func base_of(i: int) -> Vector2i:
	return Vector2i((i % 8) * 4, i / 8)


# ---- the paint test --------------------------------------------------------------
# a lake with a hole, a one-cell peninsula, a lone cell, two blobs touching only
# at a corner, a one-cell-wide channel
const SHAPE := [
	"................",
	"..#####.........",
	"..######........",
	"..##.###....#...",
	"..######........",
	"....##..........",
	"........#.......",
	"..........##....",
	".........###....",
	"........#.......",
	"..#########.....",
	"................",
]


func expected_at(c: Vector2i) -> Vector2i:
	if SHAPE[c.y][c.x] != "#":
		return GRASS_AT
	var m := 0
	for b in BITS:
		var n: Vector2i = c + b[1]
		if n.y >= 0 and n.y < SHAPE.size() and n.x >= 0 and n.x < SHAPE[0].length() and SHAPE[n.y][n.x] == "#":
			m |= b[0]
	return base_of(blob47.find(canonical(m)))


# paints the shape; returns [cells, empty cells, cells off the canonical table, water cells, distinct water tiles used, coords list]
func paint(ts: TileSet) -> Array:
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	var all: Array[Vector2i] = []
	var water: Array[Vector2i] = []
	for y in SHAPE.size():
		for x in SHAPE[0].length():
			all.append(Vector2i(x, y))
			if SHAPE[y][x] == "#":
				water.append(Vector2i(x, y))
	layer.set_cells_terrain_connect(all, 0, GRASS, false)
	layer.set_cells_terrain_connect(water, 0, WATER, false)
	var empty := 0
	var off := 0
	var distinct := {}
	var coords := []
	for c in all:
		if layer.get_cell_source_id(c) == -1:
			empty += 1
			continue
		var a := layer.get_cell_atlas_coords(c)
		coords.append(a)
		if a != expected_at(c):
			off += 1
		if SHAPE[c.y][c.x] == "#":
			distinct[a] = true
	layer.queue_free()
	root.remove_child(layer)
	return [all.size(), empty, off, water.size(), distinct.size(), coords]


# ---- the animation audit -----------------------------------------------------------
# returns [water tiles with the declared animation, grass tile still (frames 1), odd tiles]
func anim_audit(src: TileSetAtlasSource) -> Array:
	var an: Dictionary = manifest["animation"]
	var durs := []
	for d in an["frame_durations"]:
		durs.append(snappedf(float(d), 0.000001))
	var good := 0
	var odd := []
	for i in 47:
		var t := base_of(i)
		# durations are stored as 32-bit floats: 0.2 reads back as 0.20000000298,
		# so `== 0.2` is false (measured) — compared to 6 decimals instead
		var got := []
		for f in src.get_tile_animation_frames_count(t):
			got.append(snappedf(src.get_tile_animation_frame_duration(t, f), 0.000001))
		var td := src.get_tile_data(t, 0)
		if src.get_tile_animation_frames_count(t) == int(an["frames"]) and src.get_tile_animation_columns(t) == int(an["columns"]) \
				and got == durs and src.get_tile_animation_speed(t) == float(an["speed"]) \
				and src.get_tile_animation_mode(t) == TileSetAtlasSource.TILE_ANIMATION_MODE_DEFAULT \
				and src.get_tile_animation_separation(t) == Vector2i(0, 0) and td.terrain_set == 0 and td.terrain == WATER:
			good += 1
		else:
			odd.append(t)
	var gtd := src.get_tile_data(GRASS_AT, 0)
	var grass_still: bool = src.get_tile_animation_frames_count(GRASS_AT) == 1 and gtd.terrain_set == 0 and gtd.terrain == GRASS
	return [good, grass_still, odd]


# ---- rendered frames -----------------------------------------------------------------
# Renders the full-water tile (mask 255) and the lone-cell tile (mask 0) side by
# side for `n` frames; returns for each cell the atlas frame index shown on each
# rendered frame (-1: matches no frame of that tile).
func film(ts: TileSet, T: int, n: int) -> Array:
	var src := ts.get_source(0) as TileSetAtlasSource
	var atlas := src.texture.get_image()
	atlas.convert(Image.FORMAT_RGBA8)
	var tiles := [base_of(blob47.find(255)), base_of(blob47.find(0))]
	var frames := []
	for t in tiles:
		var fr := []
		for f in 4:
			fr.append(atlas.get_region(Rect2i((t.x + f) * T, t.y * T, T, T)))
		frames.append(fr)
	var vp := SubViewport.new()
	vp.size = Vector2i(2 * T, T)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	vp.add_child(layer)
	for k in 2:
		layer.set_cell(Vector2i(k, 0), 0, tiles[k])
	await process_frame
	await process_frame
	var seqs := [[], []]
	for i in n:
		await process_frame
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		for k in 2:
			var shot := img.get_region(Rect2i(k * T, 0, T, T))
			var idx := -1
			for f in 4:
				if shot.get_data() == frames[k][f].get_data():
					idx = f
					break
			seqs[k].append(idx)
	vp.queue_free()
	return seqs


# lengths of the runs of equal values, without the first and last run
func inner_runs(s: Array) -> Array:
	var runs := []
	var n := 1
	for i in range(1, s.size()):
		if s[i] == s[i - 1]:
			n += 1
		else:
			runs.append([s[i - 1], n])
			n = 1
	runs.append([s[s.size() - 1], n])
	return runs.slice(1, runs.size() - 1)


# [every rendered frame matched an atlas frame, frame order cycles 0-1-2-3, inner run lengths, the two cells in step, distinct frames seen]
func film_summary(seqs: Array) -> Array:
	var matched: bool = not seqs[0].has(-1) and not seqs[1].has(-1)
	var runs := inner_runs(seqs[0])
	var cyc := true
	for i in range(1, runs.size()):
		if runs[i][0] != (runs[i - 1][0] + 1) % 4:
			cyc = false
	var lens := []
	for r in runs:
		lens.append(r[1])
	var seen := {}
	for v in seqs[0]:
		seen[v] = true
	return [matched, cyc, lens, seqs[0] == seqs[1], seen.size()]


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--invert":
			invert = true
	print("Godot " + Engine.get_version_info()["string"])

	var mf := FileAccess.open(DIR + "manifest.json", FileAccess.READ)
	if mf == null:
		print("ANIMATED WATER: manifest.json missing")
		quit(3)
		return
	manifest = JSON.parse_string(mf.get_as_text())

	var seen := {}
	for m in 256:
		seen[canonical(m)] = true
	blob47 = seen.keys()
	blob47.sort()

	for entry in manifest["tilesets"]:
		var base: String = entry["base"]
		var T := int(entry["tile_size"])
		var ts: TileSet = load(DIR + base + ".tres")
		if ts == null:
			check("W3", false, true, "%s loads" % base)
			continue
		var src := ts.get_source(0) as TileSetAtlasSource

		check("W3", [ts.get_source_count(), src != null and src.texture != null, src.texture.get_width(), src.texture.get_height(), ts.tile_size],
			[1, true, int(entry["sheet_w"]), int(entry["sheet_h"]), Vector2i(T, T)],
			"%s loads with its PNG next to it: 1 atlas source, sheet %dx%d, tile size %d" % [base, int(entry["sheet_w"]), int(entry["sheet_h"]), T])

		var frame_tiles := 0
		var frame_owner_ok := 0
		for i in 47:
			var t := base_of(i)
			for f in range(1, 4):
				var fc := t + Vector2i(f, 0)
				if src.has_tile(fc):
					frame_tiles += 1
				if src.get_tile_at_coords(fc) == t:
					frame_owner_ok += 1
		note("W4", "%s get_tiles_count %d, frame cells that are tiles %d, frame cells owned by their base tile %d/141" % [base, src.get_tiles_count(), frame_tiles, frame_owner_ok])
		check("W4", [src.get_tiles_count(), frame_tiles, frame_owner_ok], [48, 0, 141],
			"%s: get_tiles_count() is 48 (47 water + 1 grass) — the 141 animation frame cells are not tiles (has_tile false) and get_tile_at_coords() on each returns its base tile" % base)

		check("W5", [ts.get_terrain_sets_count(), ts.get_terrain_set_mode(0), ts.get_terrains_count(0), ts.get_terrain_name(0, 0), ts.get_terrain_name(0, 1)],
			[1, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES, 2, "Water", "Grass"],
			"%s: one terrain set, Match Corners and Sides, terrain 0 Water, terrain 1 Grass" % base)

		var au := anim_audit(src)
		check("W6", [au[0], au[1], au[2]], [47, true, []],
			"%s: all 47 water tiles have animation_frames_count 4, animation_columns 4, frame durations %s, speed 1, mode DEFAULT, separation (0,0); the grass tile has 1 frame" % [base, str(manifest["animation"]["frame_durations"])])

		var table_ok := 0
		var mtable: Array = manifest["atlas"]["water_tiles"]
		for i in 47:
			var t := base_of(i)
			var td := src.get_tile_data(t, 0)
			var bits_ok := true
			for b in BITS:
				var want := WATER if (blob47[i] & b[0]) else GRASS
				if td.get_terrain_peering_bit(b[2]) != want:
					bits_ok = false
			var me: Dictionary = mtable[i]
			if bits_ok and int(me["mask"]) == blob47[i] and Vector2i(int(me["atlas"][0]), int(me["atlas"][1])) == t:
				table_ok += 1
		var gtd := src.get_tile_data(GRASS_AT, 0)
		var grass_bits := true
		for b in BITS:
			if gtd.get_terrain_peering_bit(b[2]) != GRASS:
				grass_bits = false
		check("W7", [table_ok, grass_bits], [47, true],
			"%s: tile i of the ascending canonical 47-mask table sits at (4*(i%%8), i/8) and its 8 peering bits are Water exactly where the mask has a neighbour, Grass elsewhere (the manifest says the same); the grass tile is Grass on all 8" % base)

		var p := paint(ts)
		note("W8", "%s paint: cells %d, empty %d, off-table %d, water %d, distinct water tiles %d" % [base, p[0], p[1], p[2], p[3], p[4]])
		check("W8", [p[1], p[2]], [0, 0],
			"%s: Connect paints Grass over a %d-cell field then Water over %d cells (hole, peninsula, lone cell, corner touch, channel): 0 cells empty, every cell's atlas coords are the canonical-table tile for its neighbourhood (%d distinct water tiles)" % [base, p[0], p[3], p[4]])

		# control: the same tileset with every tile cut to one frame
		var one: TileSet = ts.duplicate(true)
		var osrc := one.get_source(0) as TileSetAtlasSource
		for i in 47:
			osrc.set_tile_animation_frames_count(base_of(i), 1)
		var oau := anim_audit(osrc)
		var op := paint(one)
		note("W9", "%s one-frame control: audit good %d, odd %d; paint off-table %d, same coords as animated %s" % [base, oau[0], oau[2].size(), op[2], op[5] == p[5]])
		check("W9", [oau[0], oau[2].size(), op[5] == p[5]], [0, 47, true],
			"control: a copy with every tile cut to 1 frame fails the W6 audit on all 47 tiles, and paints the same atlas coords cell for cell (animation does not take part in terrain matching)")

		# control: the full-water tile loses one corner bit
		var broken: TileSet = ts.duplicate(true)
		var bsrc := broken.get_source(0) as TileSetAtlasSource
		bsrc.get_tile_data(base_of(blob47.find(255)), 0).set_terrain_peering_bit(TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER, GRASS)
		var bp := paint(broken)
		note("W10", "%s broken-bit control: empty %d, off-table %d" % [base, bp[1], bp[2]])
		check("W10", bp[1] + bp[2] > 0, true,
			"control: a copy whose full-water tile has its top-left corner bit set to Grass is caught by the W8 comparison (cells off the table)")

		var fs := film_summary(await film(ts, T, 60))
		note("W11", "%s rendered: matched %s, cycles %s, inner runs %s, cells in step %s, distinct %d" % [base, fs[0], fs[1], str(fs[2]), fs[3], fs[4]])
		check("W11", [fs[0], fs[1], fs[2].slice(0, 3), fs[3], fs[4]], [true, true, [12, 12, 12], true, 4],
			"%s rendered on screen: the full-water and lone-cell tiles show atlas frames 0, 1, 2, 3 in order, each for 12 rendered frames at 60 fps (0.2 s), both cells in step, every rendered frame pixel-equal to an atlas frame" % base)
		var cfs := film_summary(await film(one, T, 60))
		note("W12", "%s rendered one-frame control: matched %s, distinct %d, runs %s" % [base, cfs[0], cfs[4], str(cfs[2])])
		check("W12", [cfs[0], cfs[4]], [true, 1],
			"control: the one-frame copy renders frame 0 on all 60 frames (the W11 film sees 1 distinct frame)")

	# ---- the demo scene ----------------------------------------------------------
	var packed: PackedScene = load(DIR + "animated_water_demo.tscn")
	var demo_ok := [false, 0, 0, 0, -1]
	if packed != null:
		var scene := packed.instantiate()
		var pond := scene.get_node("Pond") as TileMapLayer
		var used := pond.get_used_cells()
		var water := 0
		var off := 0
		for c in used:
			var a := pond.get_cell_atlas_coords(c)
			if a != GRASS_AT:
				water += 1
			# expected tile from the painted neighbours themselves
			var want := GRASS_AT
			if a != GRASS_AT:
				var m := 0
				for b in BITS:
					var n: Vector2i = c + b[1]
					if pond.get_cell_source_id(n) != -1 and pond.get_cell_atlas_coords(n) != GRASS_AT:
						m |= b[0]
				want = base_of(blob47.find(canonical(m)))
			if a != want:
				off += 1
		demo_ok = [pond.tile_set != null and pond.tile_set.resource_path.ends_with("animated_water_16px.tres"), used.size(), water, off,
			(pond.tile_set.get_source(0) as TileSetAtlasSource).get_tile_animation_frames_count(base_of(0))]
		scene.free()
	var d: Dictionary = manifest["demo"]
	check("W13", demo_ok, [true, int(d["cells"]), int(d["water_cells"]), 0, 4],
		"animated_water_demo.tscn loads; its Pond layer uses animated_water_16px.tres (4-frame tiles) and holds %d painted cells, %d of them water, every water cell on the canonical-table tile for its painted neighbours" % [int(d["cells"]), int(d["water_cells"])])

	if failures == 0:
		print("ANIMATED WATER: ALL PASS (%d checks)" % checks)
	else:
		print("ANIMATED WATER: %d FAIL of %d checks" % [failures, checks])
	quit(1 if failures > 0 else 0)
