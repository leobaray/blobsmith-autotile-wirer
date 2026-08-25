# Loads res://scripted.tscn, instantiates it, and prints what the script on the
# TileMap node reports. Runs unchanged on both sides of the port: it never names
# TileMap or TileMapLayer, so the only thing that differs between the 4.2 run and
# the 4.7 run is the scene and the script — which is exactly what is on trial.
extends SceneTree

func _init() -> void:
	var packed := load("res://scripted.tscn")
	if packed == null:
		print("PROBE FAIL  scripted.tscn did not load")
		quit(1)
		return
	var inst = packed.instantiate()
	root.add_child(inst)
	var node = inst.get_node_or_null("TileMap")
	if node == null:
		print("PROBE FAIL  no node named TileMap in the instantiated scene")
		quit(1)
		return
	if not node.has_method("digest"):
		print("PROBE FAIL  the node has no digest() — the script did not survive")
		quit(1)
		return
	print("DIGEST ", node.digest())
	quit(0)
