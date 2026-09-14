extends SceneTree
##
## Reproduces every claim in docs/why-my-animated-tile-does-not-animate.md
## against a real engine.
##
## Standalone: builds its own TileSets and TileMapLayers in memory, needs no
## project assets. Run through verify_tile_animation.sh, which gives it a real GL
## context and --fixed-fps 60, so one rendered frame is exactly 1/60 s of engine
## time and an animation frame of 0.1 s lasts exactly 6 rendered frames. Which
## frame is showing is read back from rendered pixels.
##
## Prints PASS/FAIL per check and a final "TILE ANIMATION:" line; the shell
## wrapper gates on that line, because a GDScript parse error still exits 0.
##
## LG_ANIMPROBE=occupied|speed0 runs one scenario and quits, so the wrapper can
## count the ERROR lines each one prints.
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

# Atlas cells are painted in these colours; the sampled pixel is named by them.
const PAINT := {"R": Color(1, 0, 0), "G": Color(0, 1, 0), "B": Color(0, 0, 1), "Y": Color(1, 1, 0)}
const A := Vector2i(0, 0)

var failures := 0
var vp: SubViewport


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


# cells: {Vector2i atlas coord: "R"|"G"|"B"|"Y"}; one 16 px region each.
func source(cells: Dictionary, size := Vector2i(4, 2)) -> TileSetAtlasSource:
	var img := Image.create(size.x * 16, size.y * 16, false, Image.FORMAT_RGBA8)
	for c in cells:
		img.fill_rect(Rect2i(c.x * 16, c.y * 16, 16, 16), PAINT[cells[c]])
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(16, 16)
	src.create_tile(A)
	return src


# A fresh SubViewport, `width` cells wide, every cell painted with tile A.
func layer_of(src: TileSetAtlasSource, width := 1) -> TileMapLayer:
	if vp:
		vp.queue_free()
	vp = SubViewport.new()
	vp.size = Vector2i(16 * width, 16)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(16, 16)
	ts.add_source(src)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	vp.add_child(layer)
	for x in width:
		layer.set_cell(Vector2i(x, 0), 0, A)
	return layer


func name_of(c: Color) -> String:
	if c.a < 0.01:
		return "-"
	for n in PAINT:
		var p: Color = PAINT[n]
		if absf(c.r - p.r) < 0.1 and absf(c.g - p.g) < 0.1 and absf(c.b - p.b) < 0.1:
			return n
	return "?"


# One rendered frame; returns what each of the first `width` cells shows.
func shot(width := 1) -> String:
	await process_frame
	var img := vp.get_texture().get_image()
	var s := ""
	for x in width:
		s += name_of(img.get_pixel(x * 16 + 8, 8))
	return s


# `n` frames of cell 0, as a string like "RRRRRRGGGGGG...".
func film(n: int) -> String:
	await process_frame  # let a just-built viewport render once
	await process_frame
	var s := ""
	for i in n:
		s += await shot()
	return s


# Lengths of the runs of equal letters, without the first and last run (those
# are cut by where the film starts and stops).
func inner_runs(s: String) -> Array:
	var runs := []
	var n := 1
	for i in range(1, s.length()):
		if s[i] == s[i - 1]:
			n += 1
		else:
			runs.append([s[i - 1], n])
			n = 1
	runs.append([s[s.length() - 1], n])
	return runs.slice(1, runs.size() - 1)


func run_lengths(s: String) -> Array:
	return inner_runs(s).map(func(r): return r[1])


func letters(s: String) -> String:
	var out := ""
	for r in inner_runs(s):
		out += r[0]
	return out


func probe(mode: String) -> void:
	var src := source({A: "R", Vector2i(1, 0): "G"})
	if mode == "occupied":
		src.create_tile(Vector2i(1, 0))
		src.set_tile_animation_frames_count(A, 2)
	if mode == "speed0":
		src.set_tile_animation_speed(A, 0.0)
	print("ANIMPROBE DONE")
	quit(0)


func _initialize() -> void:
	var p := OS.get_environment("LG_ANIMPROBE")
	if p != "":
		probe(p)
		return

	var src: TileSetAtlasSource
	var L: TileMapLayer
	var s: String

	# --- control: a tile with one frame never changes ---------------------------
	src = source({A: "R", Vector2i(1, 0): "G"})
	L = layer_of(src)
	s = await film(40)
	check_eq("K1 control: a tile with no animation shows R on all 40 frames", s, "R".repeat(40))

	# --- defaults ----------------------------------------------------------------
	check_eq("A1 new tile: frames_count 1, columns 0, speed 1.0, frame duration 1.0 s, mode DEFAULT, separation (0,0)",
		[src.get_tile_animation_frames_count(A), src.get_tile_animation_columns(A), src.get_tile_animation_speed(A),
			src.get_tile_animation_frame_duration(A, 0), src.get_tile_animation_mode(A), src.get_tile_animation_separation(A)],
		[1, 0, 1.0, 1.0, TileSetAtlasSource.TILE_ANIMATION_MODE_DEFAULT, Vector2i(0, 0)])

	# --- frames are laid out to the right, one second each ---------------------------
	src = source({A: "R", Vector2i(1, 0): "G"})
	src.set_tile_animation_frames_count(A, 2)
	check_eq("A2 frames_count 2: accepted", src.get_tile_animation_frames_count(A), 2)
	L = layer_of(src)
	s = await film(200)
	check_eq("A2 ... frame 1 is read from atlas (1,0), to the RIGHT of the tile (film alternates R and G)", letters(s).substr(0, 2) in ["RG", "GR"], true)
	# 60 steps of 1/60 s add up to a hair under 1.0 in floating point, so a
	# boundary can land one frame late: measured [61, 60] on 4.3, 4.4 and 4.7.
	check_eq("A2 ... each frame lasts 60 rendered frames (+-1) at 60 fps = the 1.0 s default",
		run_lengths(s).slice(0, 2).all(func(n): return n >= 59 and n <= 61), true)

	check_eq("A3 atlas (1,0) is NOT a tile: has_tile() false", src.has_tile(Vector2i(1, 0)), false)
	check_eq("A3 ... get_tile_at_coords((1,0)) returns the animated tile (0,0)", src.get_tile_at_coords(Vector2i(1, 0)), A)
	L.set_cell(Vector2i(0, 0), 0, Vector2i(1, 0))
	check_eq("A3 ... set_cell(c, 0, (1,0)) stores a cell whose tile data is null", L.get_cell_tile_data(Vector2i(0, 0)), null)
	check_eq("A3 ... and draws nothing", await film(3), "---")

	# --- the frame cells must be free -----------------------------------------------
	src = source({A: "R", Vector2i(1, 0): "G", Vector2i(0, 1): "B"})
	src.create_tile(Vector2i(1, 0))
	src.set_tile_animation_frames_count(A, 2)
	check_eq("A4 (1,0) already a tile: frames_count 2 is REFUSED, stays 1", src.get_tile_animation_frames_count(A), 1)
	src.set_tile_animation_columns(A, 1)
	src.set_tile_animation_frames_count(A, 2)
	check_eq("A4 ... columns = 1 first, then frames_count 2: accepted", src.get_tile_animation_frames_count(A), 2)
	src.set_tile_animation_frame_duration(A, 0, 0.1)
	src.set_tile_animation_frame_duration(A, 1, 0.1)
	L = layer_of(src)
	s = await film(40)
	check_eq("A4 ... and frame 1 now comes from (0,1), BELOW the tile (film alternates R and B)", letters(s).substr(0, 2) in ["RB", "BR"], true)

	# --- separation skips atlas cells between frames ---------------------------------
	src = source({A: "R", Vector2i(1, 0): "Y", Vector2i(2, 0): "G"})
	src.set_tile_animation_separation(A, Vector2i(1, 0))
	src.set_tile_animation_frames_count(A, 2)
	src.set_tile_animation_frame_duration(A, 0, 0.1)
	src.set_tile_animation_frame_duration(A, 1, 0.1)
	L = layer_of(src)
	s = await film(40)
	check_eq("A5 separation (1,0): frame 1 comes from (2,0) — G, never the Y at (1,0)", [letters(s).substr(0, 2) in ["RG", "GR"], s.contains("Y")], [true, false])

	# --- per-frame duration and speed -------------------------------------------------
	src = source({A: "R", Vector2i(1, 0): "G"})
	src.set_tile_animation_frames_count(A, 2)
	src.set_tile_animation_frame_duration(A, 0, 0.1)
	src.set_tile_animation_frame_duration(A, 1, 0.3)
	L = layer_of(src)
	s = await film(90)
	var r := inner_runs(s)
	check_eq("A6 frame durations 0.1 s and 0.3 s: R lasts 6 frames, G lasts 18",
		[r.filter(func(x): return x[0] == "R")[0][1], r.filter(func(x): return x[0] == "G")[0][1]], [6, 18])
	src.set_tile_animation_speed(A, 2.0)
	s = await film(60)
	r = inner_runs(s)
	check_eq("A7 speed 2.0 on the same tile: R lasts 3 frames, G lasts 9",
		[r.filter(func(x): return x[0] == "R")[0][1], r.filter(func(x): return x[0] == "G")[0][1]], [3, 9])
	src.set_tile_animation_speed(A, 0.0)
	check_eq("A7 speed 0.0 is REFUSED: speed stays 2.0 (no pausing a tile through speed)", src.get_tile_animation_speed(A), 2.0)

	# --- every cell shares one clock --------------------------------------------------
	src = source({A: "R", Vector2i(1, 0): "G"})
	src.set_tile_animation_frames_count(A, 2)
	src.set_tile_animation_frame_duration(A, 0, 0.1)
	src.set_tile_animation_frame_duration(A, 1, 0.1)
	L = layer_of(src, 8)
	L.erase_cell(Vector2i(7, 0))
	await film(9)  # 9 frames later: mid-way through a frame
	L.set_cell(Vector2i(7, 0), 0, A)
	var in_step := true
	var shots := []
	for i in 30:
		var row: String = await shot(8)
		shots.append(row)
		if row != row[0].repeat(8):
			in_step = false
	check_eq("A8 mode DEFAULT: 8 cells show the same frame on all 30 frames, including one placed 9 frames late", in_step, true)
	check_eq("A8 ... (and they did animate meanwhile)", shots.has("RRRRRRRR") and shots.has("GGGGGGGG"), true)

	src.set_tile_animation_mode(A, TileSetAtlasSource.TILE_ANIMATION_MODE_RANDOM_START_TIMES)
	await process_frame
	var mixed := false
	for i in 30:
		var row: String = await shot(8)
		if row.contains("R") and row.contains("G"):
			mixed = true
	check_eq("A9 mode RANDOM_START_TIMES: the same 8 cells show different frames on the same rendered frame", mixed, true)
	src.set_tile_animation_mode(A, TileSetAtlasSource.TILE_ANIMATION_MODE_DEFAULT)

	# --- what does and does not stop it ----------------------------------------------
	L = layer_of(src)
	paused = true
	s = await film(40)
	paused = false
	check_eq("A10 get_tree().paused = true: the tile KEEPS animating (6-frame runs)", run_lengths(s).slice(0, 3), [6, 6, 6])

	L.process_mode = Node.PROCESS_MODE_DISABLED
	s = await film(40)
	L.process_mode = Node.PROCESS_MODE_INHERIT
	check_eq("A10 layer process_mode DISABLED: KEEPS animating too", run_lengths(s).slice(0, 3), [6, 6, 6])

	Engine.time_scale = 0.0
	await process_frame
	s = await film(40)
	check_eq("A11 Engine.time_scale = 0: FROZEN on one frame for 40 frames", s, s[0].repeat(40))
	Engine.time_scale = 0.5
	s = await film(60)
	Engine.time_scale = 1.0
	check_eq("A11 Engine.time_scale = 0.5: frames last 12 rendered frames instead of 6", run_lengths(s).slice(0, 3), [12, 12, 12])

	src.set_tile_animation_frames_count(A, 1)
	s = await film(40)
	check_eq("A12 frames_count back to 1 at runtime: every cell stops on frame 0 (R)", s, "R".repeat(40))

	print("TILE ANIMATION: " + ("ALL PASS" if failures == 0 else "%d FAIL" % failures))
	quit(0 if failures == 0 else 1)
