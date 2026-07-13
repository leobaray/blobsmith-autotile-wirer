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
