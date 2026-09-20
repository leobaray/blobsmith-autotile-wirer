extends SceneTree

# check_tileset_collision.gd — point it at YOUR TileSet, not ours.
#
#   godot --headless --script check_tileset_collision.gd -- res://tiles/my_tiles.tres
#   godot --headless --script check_tileset_collision.gd -- res://tiles/a.tres res://tiles/b.tres
#
# Exit 0 = nothing found. Exit 1 = at least one FAULT. Exit 2 = usage / the
# resource did not load.
#
# It reports the four ways a TileSet ends up looking wired while nothing
# collides, in the order they bite:
#
#   NO-PHYSICS-LAYER  the TileSet has no physics layer at all. Every collision
#                     polygon you draw in the editor has nowhere to live.
#   LAYER-MASK-ZERO   a physics layer exists but its collision_layer is 0. The
#                     bodies are created and are on no layer, so nothing whose
#                     collision_mask you set will ever see them. This one is
#                     invisible in the editor.
#   TILE-NO-POLYGON   a tile in the atlas carries no collision polygon on a
#                     layer. Usually the tiles added after you drew the first
#                     ones — the editor does not copy the shape forward.
#   POLYGON-DEGENERATE a polygon with fewer than 3 points, or zero area. The
#                     editor lets you click two points and move on.
#
# MIT. Part of the free Blobsmith solid-collision pack —
# https://github.com/leobaray/blobsmith-autotile-wirer

var faults := 0
var tiles_seen := 0

func poly_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in range(pts.size()):
		var p := pts[i]
		var q := pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) * 0.5

func fault(code: String, what: String) -> void:
	faults += 1
	print("FAULT %s  %s" % [code, what])

func check(p: String) -> void:
	var res: Resource = load(p)
	if res == null or not (res is TileSet):
		print("ERROR  %s did not load as a TileSet" % p)
		faults += 1
		return
	var ts: TileSet = res
	var layers := ts.get_physics_layers_count()
	print("TILESET %s  tile_size=%s  physics_layers=%d  sources=%d"
		% [p, str(ts.tile_size), layers, ts.get_source_count()])
	if layers == 0:
		fault("NO-PHYSICS-LAYER", "%s has no physics layer — no tile in it can ever collide" % p)
		return
	var live: Array[int] = []
	for l in range(layers):
		var mask := ts.get_physics_layer_collision_layer(l)
		if mask == 0:
			fault("LAYER-MASK-ZERO", "%s physics layer %d has collision_layer = 0 — its bodies are on no layer" % [p, l])
		else:
			live.append(l)
	for si in range(ts.get_source_count()):
		var src := ts.get_source(ts.get_source_id(si)) as TileSetAtlasSource
		if src == null:
			continue
		for i in range(src.get_tiles_count()):
			var coords := src.get_tile_id(i)
			for alt in range(src.get_alternative_tiles_count(coords)):
				var td := src.get_tile_data(coords, src.get_alternative_tile_id(coords, alt))
				if td == null:
					continue
				tiles_seen += 1
				var total := 0
				for l in live:
					var n := td.get_collision_polygons_count(l)
					total += n
					for k in range(n):
						var pts := td.get_collision_polygon_points(l, k)
						if pts.size() < 3:
							fault("POLYGON-DEGENERATE", "%s tile %s polygon %d on layer %d has %d points" % [p, str(coords), k, l, pts.size()])
						elif poly_area(pts) <= 0.0:
							fault("POLYGON-DEGENERATE", "%s tile %s polygon %d on layer %d has zero area" % [p, str(coords), k, l])
				if total == 0 and not live.is_empty():
					fault("TILE-NO-POLYGON", "%s tile %s has no collision polygon on any live layer" % [p, str(coords)])

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: godot --headless --script check_tileset_collision.gd -- res://path/to/tileset.tres [more...]")
		quit(2)
		return
	for p in args:
		check(p)
	if faults == 0:
		print("COLLISION-CHECK OK  %d tiles, 0 faults" % tiles_seen)
	else:
		print("COLLISION-CHECK %d FAULTS  over %d tiles" % [faults, tiles_seen])
	quit(1 if faults > 0 else 0)
