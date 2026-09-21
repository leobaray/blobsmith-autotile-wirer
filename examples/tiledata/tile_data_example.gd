extends Node

# tile_data_example.gd — reading the ground under a position, and an A* grid
# from the tiles. Drop it on any node, point `layer` at your TileMapLayer, and
# call the functions from your player or enemy script. Works with every TileSet
# in this pack, and with yours if it declares the same layers (ground,
# move_cost, walkable, damage, footstep). Godot 4.3 or newer.
#
# verify_tiledata_pack.gd runs this file on a moved, 3x-scaled layer and checks
# ground_at() on every cell and build_astar()'s path against its own.
#
# MIT. Part of the free Blobsmith tile-data pack —
# https://github.com/leobaray/blobsmith-autotile-wirer

@export var layer: TileMapLayer

# The TileData under a WORLD position, or null on an empty cell.
# to_local() first: local_to_map() takes the layer's own coordinates, and a
# layer that was moved or scaled puts global_position in the wrong cell.
func tile_data_at(global_pos: Vector2) -> TileData:
	var cell := layer.local_to_map(layer.to_local(global_pos))
	return layer.get_cell_tile_data(cell)

func ground_at(global_pos: Vector2) -> String:
	var td := tile_data_at(global_pos)
	if td == null:
		return ""
	return td.get_custom_data("ground")

# Speed multiplier and damage for a body standing at `global_pos` — e.g. in a
# CharacterBody2D:
#   var step := ground.step_at(global_position)
#   velocity = input_dir * SPEED * step.speed
#   if step.damage > 0: take_damage(step.damage)   # once per step, not per frame
func step_at(global_pos: Vector2) -> Dictionary:
	var td := tile_data_at(global_pos)
	if td == null:
		return {"speed": 1.0, "damage": 0, "footstep": "", "walkable": false}
	return {
		"speed": 1.0 / float(td.get_custom_data("move_cost")),
		"damage": int(td.get_custom_data("damage")),
		"footstep": String(td.get_custom_data("footstep")),
		"walkable": bool(td.get_custom_data("walkable")),
	}

# An AStarGrid2D whose costs come from the tiles: walkable = false -> solid,
# move_cost -> weight. Call it again after the map is repainted or grows —
# the grid is a copy, and changing its region wipes every point.
func build_astar() -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = layer.get_used_rect()
	grid.cell_size = Vector2(layer.tile_set.tile_size)
	# the default (ALWAYS) cuts diagonally between two solid cells that touch at
	# a corner; NEVER keeps the path on the cells a body can actually cross
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()   # region, cell_size and mode first: update() resets the points
	for y in range(grid.region.position.y, grid.region.end.y):
		for x in range(grid.region.position.x, grid.region.end.x):
			var cell := Vector2i(x, y)
			var td := layer.get_cell_tile_data(cell)
			if td == null:
				grid.set_point_solid(cell, true)   # nothing painted here
				continue
			grid.set_point_solid(cell, not td.get_custom_data("walkable"))
			grid.set_point_weight_scale(cell, td.get_custom_data("move_cost"))
	return grid

# World positions to walk through, from one world position to another.
func path_between(grid: AStarGrid2D, from_global: Vector2, to_global: Vector2) -> PackedVector2Array:
	var a := layer.local_to_map(layer.to_local(from_global))
	var b := layer.local_to_map(layer.to_local(to_global))
	var out := PackedVector2Array()
	for cell in grid.get_id_path(a, b):
		out.append(layer.to_global(layer.map_to_local(cell)))
	return out
