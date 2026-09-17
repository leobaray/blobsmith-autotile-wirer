extends CharacterBody2D
## Side-view player for platformer_demo.tscn. Godot 4.3 to 4.7.
##
## Uses only the built-in actions, so there is nothing to set up in the Input Map:
##   ui_left / ui_right   walk
##   ui_accept            jump (only from the floor)
##   ui_down + ui_accept  drop through the one-way platform you are standing on
##
## The one-way platforms are on their own TileSet physics layer (collision bit 2),
## the ground on bit 1, and this body's collision_mask is 3 (both). Dropping
## through clears bit 2 from the mask for drop_frames physics frames, then puts it
## back. A one-way tile only lets a body through once it is deeper into it than
## one_way_margin, so the bit has to stay off for a few frames, not one. See
## docs/why-you-cannot-drop-through-the-one-way-tile.md in the repo.

@export var speed: float = 120.0
@export var jump_velocity: float = -360.0
@export var gravity: float = 980.0
## collision bit of the one-way platforms (TileSet physics layer 1 = bit 2)
@export_range(1, 32) var platform_bit: int = 2
## physics frames with platform_bit cleared when dropping through
@export var drop_frames: int = 6

var _drop_left: int = 0


func _physics_process(delta: float) -> void:
	# restore the platform bit once the drop has had its frames
	if _drop_left > 0:
		_drop_left -= 1
		if _drop_left == 0:
			set_collision_mask_value(platform_bit, true)

	if not is_on_floor():
		velocity.y += gravity * delta

	velocity.x = Input.get_axis("ui_left", "ui_right") * speed

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		if Input.is_action_pressed("ui_down") and standing_on_platform():
			drop_through()
		else:
			velocity.y = jump_velocity

	move_and_slide()


## True when the floor under the body is on the platform collision bit.
func standing_on_platform() -> bool:
	for i in get_slide_collision_count():
		var c: KinematicCollision2D = get_slide_collision(i)
		if c.get_normal().y > -0.7:
			continue   # a wall or a ceiling, not the floor
		var layer: int = PhysicsServer2D.body_get_collision_layer(c.get_collider_rid())
		if layer & (1 << (platform_bit - 1)):
			return true
	return false


func drop_through() -> void:
	set_collision_mask_value(platform_bit, false)
	_drop_left = drop_frames
