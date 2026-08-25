@tool
class_name BlobsmithWirerCore
extends RefCounted
## Turns a 47-blob (or 16 sides-only) tilesheet into a fully wired Godot 4
## TileSet: terrain set, peering bits on every tile, optional collisions.
##
## Sheet layout: 8 columns, tiles in ascending canonical-mask order — the
## layout produced by Blobsmith (https://blobsmith.itch.io/blobsmith) and
## documented in the README. Bit layout: N=1 NE=2 E=4 SE=8 S=16 SW=32 W=64 NW=128.

const SHEET_COLS := 8

const _BIT_TO_NEIGHBOR := {
	1: TileSet.CELL_NEIGHBOR_TOP_SIDE,
	2: TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	4: TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	8: TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	16: TileSet.CELL_NEIGHBOR_BOTTOM_SIDE,
	32: TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	64: TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	128: TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
}

## A corner neighbor only matters when both adjacent sides are present.
static func canonical_mask(mask: int) -> int:
	var m := mask & 0b01010101
	if mask & 2 and mask & 1 and mask & 4: m |= 2      # NE needs N+E
	if mask & 8 and mask & 16 and mask & 4: m |= 8     # SE needs S+E
	if mask & 32 and mask & 16 and mask & 64: m |= 32  # SW needs S+W
	if mask & 128 and mask & 1 and mask & 64: m |= 128 # NW needs N+W
	return m

## The 47 canonical blob masks, ascending.
static func blob47() -> Array[int]:
	var seen := {}
	for m in 256:
		seen[canonical_mask(m)] = true
	var out: Array[int] = []
	out.assign(seen.keys())
	out.sort()
	return out

## 16 sides-only masks (N/E/S/W combinations), ascending in the shared bit layout.
static func blob16() -> Array[int]:
	var out: Array[int] = []
	for m in 16:
		var v := 0
		if m & 1: v |= 1
		if m & 2: v |= 4
		if m & 4: v |= 16
		if m & 8: v |= 64
		out.append(v)
	out.sort()
	return out

static func sheet_pos(index: int) -> Vector2i:
	return Vector2i(index % SHEET_COLS, index / SHEET_COLS)

## Detects mode from image dimensions. Returns { tile_size, sides_only } or
## an empty Dictionary when the sheet doesn't match a known layout.
static func detect_layout(width: int, height: int) -> Dictionary:
	if width % SHEET_COLS != 0:
		return {}
	var t := width / SHEET_COLS
	if t < 2:
		return {}
	if height == 6 * t:   # ceil(47/8) rows
		return { "tile_size": t, "sides_only": false }
	if height == 2 * t:   # 16 tiles / 8 cols
		return { "tile_size": t, "sides_only": true }
	return {}

## Known tile counts a sheet that ISN'T in Blobsmith layout usually has.
const _KNOWN_COUNTS := [6, 9, 16, 47, 48, 256]

## Names what a sheet probably is from its pixel size alone, for the case where
## `detect_layout` said no. Dimensions are all we have here: the wirer never
## reads pixels to guess.
##
## A sheet often has more than one honest reading — 256x256 is 4x4 tiles at
## 64px AND 16x16 tiles at 16px. The largest tile size wins (2px "tiles" divide
## almost anything), and any second reading is named in the hint instead of
## being hidden.
##
## Returns { kind, tile_size, cols, rows, hint } — `kind` is one of
## "base6", "minimal9", "wang16", "blob47", "full256", "grid", "unknown".
## `tile_size` is 0 and `cols`/`rows` are 0 when nothing divides the sheet.
static func classify_sheet(width: int, height: int) -> Dictionary:
	if width <= 0 or height <= 0:
		return { "kind": "unknown", "tile_size": 0, "cols": 0, "rows": 0,
			"hint": "empty image." }

	var readings: Array[Vector3i] = []   # (tile_size, cols, rows), largest tile first
	var fallback_t := 0
	var t := mini(width, height)
	while t >= 2:
		if width % t == 0 and height % t == 0:
			var cols := width / t
			var rows := height / t
			if cols * rows in _KNOWN_COUNTS:
				readings.append(Vector3i(t, cols, rows))
			if fallback_t == 0 and t >= 8:
				fallback_t = t
		t -= 1

	if readings.is_empty():
		if fallback_t == 0:
			return { "kind": "unknown", "tile_size": 0, "cols": 0, "rows": 0,
				"hint": "no square tile size of 8px or more divides %dx%d evenly. Sheets with a margin or separation between tiles are not read by this wirer." % [width, height] }
		var fc := width / fallback_t
		var fr := height / fallback_t
		return { "kind": "grid", "tile_size": fallback_t, "cols": fc, "rows": fr,
			"hint": "%dx%d tiles at %dpx (%d in all). Blobsmith layout is 8 columns: 8x6 for 47-blob, 8x2 for 16 sides-only." % [fc, fr, fallback_t, fc * fr] }

	var pick := readings[0]
	var best_t := pick.x
	var cols := pick.y
	var rows := pick.z
	var count := cols * rows
	var kind := "grid"
	var hint := ""
	match count:
		6:
			kind = "base6"
			hint = "6 tiles at %dpx (%dx%d). That is Blobsmith's INPUT, not a wired sheet: Blobsmith draws the full 47-tile sheet from exactly 6 base tiles." % [best_t, cols, rows]
		9:
			kind = "minimal9"
			hint = "9 tiles at %dpx (%dx%d) — the 3x3-minimal layout Godot 3 autotile used. Godot 4 terrains need 47 tiles (corners and sides) or 16 (sides only)." % [best_t, cols, rows]
		16:
			kind = "wang16"
			hint = "16 tiles at %dpx (%dx%d). This wirer reads 16-tile sheets as 8 columns by 2 rows — re-arrange to 8x2 and pick the 16-tile mode." % [best_t, cols, rows]
		47, 48:
			kind = "blob47"
			hint = "%d slots at %dpx (%dx%d) — the 47-blob count, in the wrong arrangement. This wirer reads 8 columns by 6 rows." % [count, best_t, cols, rows]
		256:
			kind = "full256"
			hint = "256 tiles at %dpx (%dx%d). Only 47 of the 256 neighbourhoods are distinct — see docs/why-47-tiles-not-256.md in this repo." % [best_t, cols, rows]
	if readings.size() > 1:
		var alt := readings[1]
		hint += " It also reads as %dx%d tiles at %dpx (%d in all)." % [
			alt.y, alt.z, alt.x, alt.y * alt.z]
	return { "kind": kind, "tile_size": best_t, "cols": cols, "rows": rows, "hint": hint }


## Builds the wired TileSet. `texture` must be sized for the chosen layout.
static func build_tileset(texture: Texture2D, tile_size: int, sides_only: bool,
		collision: bool, terrain_name: String) -> TileSet:
	var masks := blob16() if sides_only else blob47()
	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)
	ts.add_terrain_set(0)
	ts.set_terrain_set_mode(0,
		TileSet.TERRAIN_MODE_MATCH_SIDES if sides_only else TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	ts.add_terrain(0)
	ts.set_terrain_name(0, 0, terrain_name if terrain_name != "" else "Terrain")
	ts.set_terrain_color(0, 0, Color(0.35, 0.55, 0.25))
	if collision:
		ts.add_physics_layer(0)
		ts.set_physics_layer_collision_layer(0, 1)
		ts.set_physics_layer_collision_mask(0, 1)

	var src := TileSetAtlasSource.new()
	src.texture = texture
	src.texture_region_size = Vector2i(tile_size, tile_size)
	# add the source BEFORE touching TileData: physics/terrain layers only
	# propagate to tiles once the source belongs to the TileSet
	ts.add_source(src, 0)

	var half := tile_size / 2.0
	for i in masks.size():
		var mask := masks[i]
		var pos := sheet_pos(i)
		src.create_tile(pos)
		var td := src.get_tile_data(pos, 0)
		td.terrain_set = 0
		td.terrain = 0
		for bit in _BIT_TO_NEIGHBOR:
			if sides_only and (bit == 2 or bit == 8 or bit == 32 or bit == 128):
				continue
			if mask & bit:
				td.set_terrain_peering_bit(_BIT_TO_NEIGHBOR[bit], 0)
		if collision:
			td.add_collision_polygon(0)
			td.set_collision_polygon_points(0, 0, PackedVector2Array([
				Vector2(-half, -half), Vector2(half, -half),
				Vector2(half, half), Vector2(-half, half),
			]))

	return ts

## Convenience: builds from a texture and saves the .tres next to it.
## Returns the saved path ("" on failure).
static func wire_and_save(texture_path: String, tile_size: int, sides_only: bool,
		collision: bool, terrain_name: String) -> String:
	var texture: Texture2D = load(texture_path)
	if texture == null:
		push_error("Blobsmith Wirer: could not load texture at %s" % texture_path)
		return ""
	var ts := build_tileset(texture, tile_size, sides_only, collision, terrain_name)
	var out_path := texture_path.get_basename() + "_tileset.tres"
	var err := ResourceSaver.save(ts, out_path)
	if err != OK:
		push_error("Blobsmith Wirer: save failed (%d) for %s" % [err, out_path])
		return ""
	return out_path
