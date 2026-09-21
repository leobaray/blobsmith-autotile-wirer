extends SceneTree

# check_tileset_navigation.gd — point it at YOUR TileSet, not ours.
#
#   godot --headless --script check_tileset_navigation.gd -- res://tiles/my_tiles.tres
#   godot --headless --script check_tileset_navigation.gd -- res://tiles/a.tres res://tiles/b.tres
#
# Exit 0 = nothing found. Exit 1 = at least one FAULT. Exit 2 = usage / nothing
# to check.
#
# A tile counts as a WALL when it carries a collision polygon on a physics layer
# whose collision_layer is not 0, and as a FLOOR otherwise. It reports the ways a
# top-down TileSet ends up painted while a NavigationAgent2D does not move, or
# walks through walls, in the order they bite:
#
#   NO-NAVIGATION-LAYER  the TileSet has no navigation layer at all. Every
#                        navigation polygon you draw has nowhere to live.
#   NAV-LAYERS-ZERO      a navigation layer exists but its layers bitmask is 0:
#                        the regions are built on no layer and no agent's
#                        navigation_layers can ever match them.
#   FLOOR-NO-POLYGON     a floor tile carries no navigation polygon. Painted, it
#                        is a hole in the mesh: the path stops short of it and
#                        comes back SHORTER, not empty. Usually the tiles added
#                        after you drew the first ones.
#   POLYGON-EMPTY        a navigation polygon with outlines or vertices but no
#                        polygons — the resource exists and builds nothing.
#   POLYGON-OFFSET       a vertex lies outside the centred cell (-w/2,-h/2)..
#                        (w/2,h/2): the polygon was authored from (0,0) to
#                        (w,h), and the walkable surface sits half a tile
#                        down-right of the art, over the neighbour cell.
#   WALL-HAS-NAV         a wall tile carries a navigation polygon: agents are
#                        routed straight through the thing they collide with.
#
# MIT. Part of the free Blobsmith walkable-floor navigation pack —
# https://github.com/leobaray/blobsmith-autotile-wirer

var faults := 0
var tiles_seen := 0

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
	var nav_layers := ts.get_navigation_layers_count()
	print("TILESET %s  tile_size=%s  navigation_layers=%d  physics_layers=%d  sources=%d"
		% [p, str(ts.tile_size), nav_layers, ts.get_physics_layers_count(), ts.get_source_count()])
	if nav_layers == 0:
		fault("NO-NAVIGATION-LAYER", "%s has no navigation layer — no tile in it can ever be walkable" % p)
		return
	for l in range(nav_layers):
		if ts.get_navigation_layer_layers(l) == 0:
			fault("NAV-LAYERS-ZERO", "%s navigation layer %d has layers = 0 — its regions are on no layer" % [p, l])
	var live_physics: Array[int] = []
	for l in range(ts.get_physics_layers_count()):
		if ts.get_physics_layer_collision_layer(l) != 0:
			live_physics.append(l)
	var hx := ts.tile_size.x * 0.5
	var hy := ts.tile_size.y * 0.5
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
				var is_wall := false
				for l in live_physics:
					if td.get_collision_polygons_count(l) > 0:
						is_wall = true
				var any_nav := false
				for l in range(nav_layers):
					var np := td.get_navigation_polygon(l)
					if np == null:
						continue
					if np.get_polygon_count() == 0:
						if np.get_outline_count() > 0 or np.get_vertices().size() > 0:
							fault("POLYGON-EMPTY", "%s tile %s navigation layer %d: the polygon has outlines/vertices but no polygons — it builds nothing" % [p, str(coords), l])
						continue
					any_nav = true
					for v in np.get_vertices():
						if absf(v.x) > hx + 0.001 or absf(v.y) > hy + 0.001:
							fault("POLYGON-OFFSET", "%s tile %s navigation layer %d: vertex %s is outside the centred cell (%s..%s) — authored from (0,0), it sits half a tile down-right"
								% [p, str(coords), l, str(v), str(Vector2(-hx, -hy)), str(Vector2(hx, hy))])
							break
				if is_wall and any_nav:
					fault("WALL-HAS-NAV", "%s tile %s has collision AND a navigation polygon — agents are routed through it" % [p, str(coords)])
				elif not is_wall and not any_nav:
					fault("FLOOR-NO-POLYGON", "%s tile %s has no navigation polygon and no collision — painted, it is a hole in the mesh" % [p, str(coords)])

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: godot --headless --script check_tileset_navigation.gd -- res://path/to/tileset.tres [more...]")
		quit(2)
		return
	for p in args:
		check(p)
	if faults == 0:
		print("NAVIGATION-CHECK OK  %d tiles, 0 faults" % tiles_seen)
	else:
		print("NAVIGATION-CHECK %d FAULTS  over %d tiles" % [faults, tiles_seen])
	quit(1 if faults > 0 else 0)
