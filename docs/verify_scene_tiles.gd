extends SceneTree
##
## Reproduces every claim in docs/why-my-scene-tile-is-not-there.md against a
## real engine.
##
## Standalone: builds its own TileSets, PackedScenes and TileMapLayers in memory,
## needs no project assets. Scene tiles are nodes, not pixels, so this runs on
## the headless renderer. Run it through verify_scene_tiles.sh.
##
## Prints PASS/FAIL per check and a final "SCENE TILES:" line; the shell wrapper
## gates on that line, because a GDScript parse error still exits 0.
##
## LG_SCENEPROBE=bad runs only the three cells that point at no scene and quits,
## so the wrapper can count the ERROR lines they print.
## LG_SELFTEST=1 flips the expectation of K1, to prove the harness can fail.

const C := Vector2i(2, 1)

var failures := 0


func check_eq(name: String, got: Variant, want: Variant) -> void:
	var ok: bool = typeof(got) == typeof(want) and got == want
	if name.begins_with("K1 ") and OS.get_environment("LG_SELFTEST") == "1":
		ok = not ok
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  (got %s, want %s)" % [got, want]))
	if not ok:
		failures += 1


func scene(root_name: String, script_src := "") -> PackedScene:
	var n := Node2D.new()
	n.name = root_name
	if script_src != "":
		var s := GDScript.new()
		s.source_code = script_src
		s.reload()
		n.set_script(s)
	var ps := PackedScene.new()
	ps.pack(n)
	n.free()
	return ps


# A layer in the tree whose TileSet has one scenes-collection source (id 0).
func new_layer(shape := TileSet.TILE_SHAPE_SQUARE, size := Vector2i(16, 16)) -> TileMapLayer:
	var ts := TileSet.new()
	ts.tile_shape = shape
	ts.tile_size = size
	ts.add_source(TileSetScenesCollectionSource.new())
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	root.add_child(layer)
	return layer


func col(layer: TileMapLayer) -> TileSetScenesCollectionSource:
	return layer.tile_set.get_source(0)


func ids(layer: TileMapLayer) -> Array:
	var out := []
	for c in layer.get_children():
		out.append(c.get_instance_id())
	return out


func _initialize() -> void:
	if OS.get_environment("LG_SCENEPROBE") == "bad":
		var bl := new_layer()
		var bid := col(bl).create_scene_tile(scene("Chest"))
		await process_frame
		bl.set_cell(Vector2i(0, 0), 0, Vector2i(1, 0), bid)
		bl.set_cell(Vector2i(1, 0), 0, Vector2i(0, 0), 0)
		bl.set_cell(Vector2i(2, 0), 0, Vector2i(0, 0), 99)
		await process_frame
		await process_frame
		print("SCENEPROBE DONE children=%d used=%d" % [bl.get_child_count(), bl.get_used_cells().size()])
		quit(0)
		return

	print("Godot Engine v" + Engine.get_version_info().string)

	# --- ids and what the cell stores
	var layer := new_layer()
	var chest := col(layer).create_scene_tile(scene("Chest"))
	var door := col(layer).create_scene_tile(scene("Door"))
	check_eq("I1 first create_scene_tile() returns id 1, not 0", chest, 1)
	check_eq("I2 second create_scene_tile() returns id 2", door, 2)
	await process_frame
	var entered := []
	layer.child_entered_tree.connect(func(n: Node): entered.append(n.position))
	layer.set_cell(C, 0, Vector2i.ZERO, chest)
	check_eq("S1 right after set_cell the layer has 0 children", layer.get_child_count(), 0)
	check_eq("S2 ...and 0 counting internal children", layer.get_child_count(true), 0)
	check_eq("S3 the cell is already stored: get_used_cells() == [cell]", layer.get_used_cells(), [C])
	check_eq("S4 get_cell_source_id is the collection's source id", layer.get_cell_source_id(C), 0)
	check_eq("S5 get_cell_atlas_coords is (0, 0)", layer.get_cell_atlas_coords(C), Vector2i.ZERO)
	check_eq("S6 get_cell_alternative_tile is the SCENE id", layer.get_cell_alternative_tile(C), chest)
	check_eq("S7 get_cell_tile_data on a scene cell is null", layer.get_cell_tile_data(C) == null, true)
	layer.update_internals()
	check_eq("S8 update_internals() creates the node now", layer.get_child_count(), 1)
	var node := layer.get_child(0)
	check_eq("S9 child_entered_tree fired once, position already set", entered, [Vector2(40, 24)])
	check_eq("P1 node position == map_to_local(cell) (the cell centre)", node.position, layer.map_to_local(C))
	check_eq("P2 local_to_map(node.position) gives the cell back", layer.local_to_map(node.position), C)
	check_eq("P3 the node's owner is null", node.owner == null, true)
	check_eq("K1 control: the node is the scene's root, named Chest", String(node.name), "Chest")

	# --- deferred without update_internals, and _ready timing
	var l2 := new_layer()
	var ready_log := []
	var scripted := col(l2).create_scene_tile(scene("Scripted", "extends Node2D\nfunc _ready():\n\tadd_to_group('scene_tile_ready')\n"))
	await process_frame
	l2.set_cell(C, 0, Vector2i.ZERO, scripted)
	check_eq("D1 no update_internals: 0 children after set_cell", l2.get_child_count(), 0)
	check_eq("D2 _ready has not run after set_cell", get_nodes_in_group("scene_tile_ready").size(), 0)
	await process_frame
	check_eq("D3 one process_frame later: 1 child", l2.get_child_count(), 1)
	check_eq("D4 ...and its _ready has run", get_nodes_in_group("scene_tile_ready").size(), 1)
	l2.queue_free()

	# --- names
	var l3 := new_layer()
	var c3 := col(l3).create_scene_tile(scene("Chest"))
	for x in 3:
		l3.set_cell(Vector2i(x, 0), 0, Vector2i.ZERO, c3)
	await process_frame
	var names := []
	for n in l3.get_children():
		names.append(String(n.name))
	check_eq("N1 three copies: only the first is called Chest", names.count("Chest"), 1)
	check_eq("N2 the other two get generated @-names", names.filter(func(s): return s.begins_with("@")).size(), 2)

	# --- same values keep the node, erase is deferred
	var before := ids(layer)
	layer.set_cell(C, 0, Vector2i.ZERO, chest)
	await process_frame
	check_eq("R1 set_cell with the same values keeps the same instance", ids(layer), before)
	layer.set_cell(C, 0, Vector2i.ZERO, door)
	await process_frame
	check_eq("R2 set_cell with another scene id replaces the instance", layer.get_child_count() == 1 and ids(layer) != before, true)
	check_eq("R3 ...and the replacement is the Door scene", String(layer.get_child(0).name), "Door")
	layer.erase_cell(C)
	check_eq("E1 right after erase_cell the node is still a child", layer.get_child_count(), 1)
	await process_frame
	check_eq("E2 one frame later it is gone", layer.get_child_count(), 0)

	# --- cells that point at no scene
	layer.set_cell(Vector2i(0, 3), 0, Vector2i(1, 0), chest)
	layer.set_cell(Vector2i(1, 3), 0, Vector2i(0, 0), 0)
	layer.set_cell(Vector2i(2, 3), 0, Vector2i(0, 0), 99)
	await process_frame
	check_eq("B1 atlas (1,0) / scene id 0 / scene id 99 are all kept in get_used_cells()", layer.get_used_cells().size(), 3)
	check_eq("B2 ...and none of them creates a node", layer.get_child_count(), 0)
	for x in 3:
		layer.erase_cell(Vector2i(x, 3))

	# --- freeing the node yourself
	var l4 := new_layer()
	var c4 := col(l4).create_scene_tile(scene("Chest"))
	for x in 3:
		l4.set_cell(Vector2i(x, 0), 0, Vector2i.ZERO, c4)
	await process_frame
	var victim := l4.get_child(1)
	var vcell := l4.local_to_map(victim.position)
	victim.queue_free()
	await process_frame
	check_eq("F1 queue_free on the node: 2 children left", l4.get_child_count(), 2)
	check_eq("F2 ...but the cell is still in get_used_cells()", l4.get_used_cells().has(vcell), true)
	l4.set_cell(vcell, 0, Vector2i.ZERO, c4)
	await process_frame
	check_eq("F3 set_cell with the same values does NOT bring it back", l4.get_child_count(), 2)
	l4.erase_cell(vcell)
	l4.set_cell(vcell, 0, Vector2i.ZERO, c4)
	await process_frame
	check_eq("F4 erase_cell then set_cell does", l4.get_child_count(), 3)

	# --- the layer rebuilds its nodes (runtime state is lost)
	victim = l4.get_child(0)
	victim.set_meta("hp", 3)
	var old4 := ids(l4)
	l4.enabled = false
	await process_frame
	check_eq("L1 enabled = false frees every scene node", l4.get_child_count(), 0)
	l4.enabled = true
	await process_frame
	check_eq("L2 enabled = true makes new ones", l4.get_child_count(), 3)
	check_eq("L3 ...with new instance ids (state set on the old nodes is gone)", ids(l4).filter(func(i): return old4.has(i)).size(), 0)
	old4 = ids(l4)
	var extra := col(l4).create_scene_tile(scene("Barrel"))
	await process_frame
	check_eq("T1 adding a scene tile to the TileSet replaces every existing node", ids(l4).filter(func(i): return old4.has(i)).size(), 0)
	check_eq("T2 ...the count stays 3", l4.get_child_count(), 3)
	l4.set_cell(Vector2i(0, 5), 0, Vector2i.ZERO, extra)
	await process_frame
	col(l4).remove_scene_tile(c4)
	await process_frame
	check_eq("T3 remove_scene_tile: only the Barrel node is left", l4.get_child_count(), 1)
	check_eq("T4 ...while all 4 cells stay in get_used_cells()", l4.get_used_cells().size(), 4)

	# --- not saved with the scene
	var holder := Node.new()
	root.add_child(holder)
	var l5 := TileMapLayer.new()
	l5.name = "Layer"
	l5.tile_set = layer.tile_set
	holder.add_child(l5)
	l5.owner = holder
	l5.set_cell(C, 0, Vector2i.ZERO, chest)
	l5.update_internals()
	var packed := PackedScene.new()
	packed.pack(holder)
	var inst := packed.instantiate()
	check_eq("W1 packing the layer stores 0 scene nodes (owner null)", inst.get_node("Layer").get_child_count(), 0)
	check_eq("W2 ...but the cell itself is saved", (inst.get_node("Layer") as TileMapLayer).get_used_cells(), [C])
	root.add_child(inst)
	await process_frame
	check_eq("W3 the loaded layer creates the node again one frame later", inst.get_node("Layer").get_child_count(), 1)

	# --- outside the tree
	var off := TileMapLayer.new()
	off.tile_set = layer.tile_set
	off.set_cell(C, 0, Vector2i.ZERO, chest)
	off.update_internals()
	check_eq("O1 outside the tree update_internals() creates nothing", off.get_child_count(), 0)
	root.add_child(off)
	check_eq("O2 still nothing right after add_child", off.get_child_count(), 0)
	await process_frame
	check_eq("O3 one frame after entering the tree: 1 node", off.get_child_count(), 1)

	# --- isometric
	var iso := new_layer(TileSet.TILE_SHAPE_ISOMETRIC, Vector2i(64, 32))
	var ic := col(iso).create_scene_tile(scene("Iso"))
	iso.set_cell(Vector2i(1, 0), 0, Vector2i.ZERO, ic)
	await process_frame
	check_eq("P4 isometric 64x32: node at (96, 16) == map_to_local((1, 0))", [iso.get_child(0).position, iso.map_to_local(Vector2i(1, 0))], [Vector2(96, 16), Vector2(96, 16)])

	print("SCENE TILES: " + ("ALL PASS" if failures == 0 else "%d FAIL" % failures))
	quit(0 if failures == 0 else 1)
