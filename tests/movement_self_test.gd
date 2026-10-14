extends SceneTree
## Headless checks for the player frame, speeds, jump, air control, slide, and crouch.
## Run: flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/movement_self_test.gd

var _player
var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_world()
	await process_frame
	for _i in 15:
		await physics_frame
	_expect(_player.is_on_floor(), "player starts on the floor, on_floor=%s pos=%s" % [_player.is_on_floor(), _player.global_position])

	await _test_look()
	await _reset()
	await _test_cardinal_move()
	await _reset()
	await _test_yaw_moves_with_body()
	await _reset()
	await _test_crouch_height()
	await _reset()
	await _test_jump_height()
	await _reset()
	await _test_air_control()
	await _reset()
	await _test_slide_locks_direction()
	await _reset()
	await _test_ceiling_blocks_stand()

	if _failed:
		quit(1)
		return
	print("MOVEMENT_SELF_TEST PASS")
	quit(0)


func _build_world() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	floor_body.position = Vector3(0, -0.5, 0)
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(80, 1, 80)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)

	var ceiling := StaticBody3D.new()
	ceiling.name = "Ceiling"
	ceiling.collision_layer = 1
	ceiling.collision_mask = 0
	ceiling.position = Vector3(30, 1.5, 0)
	var ceiling_shape := CollisionShape3D.new()
	var ceiling_box := BoxShape3D.new()
	ceiling_box.size = Vector3(4, 0.5, 4)
	ceiling_shape.shape = ceiling_box
	ceiling.add_child(ceiling_shape)
	root.add_child(ceiling)

	_player = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	_player.position = Vector3(0, 0.05, 0)
	root.add_child(_player)


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)
	quit(1)


func _release_all() -> void:
	for action in ["action_move_forward", "action_move_back", "action_move_left", "action_move_right", "action_crouch", "action_jump"]:
		Input.action_release(action)


func _reset() -> void:
	_release_all()
	_player.velocity = Vector3.ZERO
	_player.rotation = Vector3.ZERO
	_player.sliding = false
	_player.crouched = false
	_player.get_node("Head").rotation = Vector3.ZERO
	_player.global_position = Vector3(0, 0.05, 0)
	for _i in 8:
		await physics_frame


func _look(relative: Vector2) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var motion := InputEventMouseMotion.new()
	motion.relative = relative
	var yaw_before: float = _player.rotation.y
	var pitch_before: float = _player.get_node("Head").rotation.x
	_player._unhandled_input(motion)
	var changed: bool = not is_equal_approx(_player.rotation.y, yaw_before) or not is_equal_approx(_player.get_node("Head").rotation.x, pitch_before)
	if not changed:
		# Headless leaves the mouse visible, so the captured-mouse guard ignores the event.
		_player._apply_look(relative)


func _press_action(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	_player._unhandled_input(event)
	Input.action_press(action)


func _test_look() -> void:
	_player.rotation = Vector3.ZERO
	_player.get_node("Head").rotation = Vector3.ZERO
	_look(Vector2(100, 0))
	var fwd: Vector3 = -_player.global_transform.basis.z
	_expect(fwd.x > 0.15 and fwd.z < -0.9, "mouse right looks toward +X, forward=%s" % fwd)
	_player.rotation = Vector3.ZERO
	_player.get_node("Head").rotation = Vector3.ZERO
	_look(Vector2(0, 100))
	var look: Vector3 = -_player.get_node("Head").global_transform.basis.z
	_expect(look.y < -0.15 and look.z < -0.9, "mouse down looks down, look=%s" % look)


func _test_cardinal_move() -> void:
	var origin: Vector3 = _player.global_position
	Input.action_press("action_move_right")
	for _i in 30:
		await physics_frame
	Input.action_release("action_move_right")
	var dx: float = _player.global_position.x - origin.x
	_expect(dx > 2.0, "D moves toward +X, dx=%s" % dx)

	_player.velocity = Vector3.ZERO
	await physics_frame
	origin = _player.global_position
	Input.action_press("action_move_forward")
	for _i in 30:
		await physics_frame
	Input.action_release("action_move_forward")
	var dz: float = _player.global_position.z - origin.z
	_expect(dz < -2.0, "W moves toward -Z, dz=%s" % dz)


func _test_yaw_moves_with_body() -> void:
	_look(Vector2(PI / 2.0 / _player.mouse_sensitivity, 0))
	var fwd: Vector3 = -_player.global_transform.basis.z
	_expect(fwd.x > 0.9, "yaw right faces +X, forward=%s" % fwd)
	var origin: Vector3 = _player.global_position
	Input.action_press("action_move_forward")
	for _i in 30:
		await physics_frame
	Input.action_release("action_move_forward")
	var delta: Vector3 = _player.global_position - origin
	_expect(delta.x > 2.0 and absf(delta.z) < 0.6, "W after yaw right moves toward +X, delta=%s" % delta)


func _test_crouch_height() -> void:
	var shape: CapsuleShape3D = _player.collision_shape.shape as CapsuleShape3D
	var stand_height: float = shape.height
	_press_action("action_crouch")
	await physics_frame
	_expect(shape.height < stand_height - 0.4, "crouch lowers the capsule, height=%s" % shape.height)
	_expect(_player.crouched and not _player.sliding, "standing crouch does not slide")
	Input.action_release("action_crouch")
	await physics_frame
	_expect(is_equal_approx(shape.height, stand_height), "release crouch restores the capsule, height=%s" % shape.height)


func _test_jump_height() -> void:
	var start_y: float = _player.global_position.y
	_press_action("action_jump")
	var peak: float = start_y
	for _i in 90:
		await physics_frame
		peak = maxf(peak, _player.global_position.y)
		if _player.is_on_floor() and _player.global_position.y <= start_y + 0.05 and _i > 5:
			break
	var rise: float = peak - start_y
	_expect(rise > _player.jump_height - 0.25 and rise < _player.jump_height + 0.25, "jump rise %s near %s" % [rise, _player.jump_height])


func _test_air_control() -> void:
	Input.action_press("action_move_forward")
	_press_action("action_jump")
	for _i in 8:
		await physics_frame
	Input.action_release("action_move_forward")
	Input.action_press("action_move_right")
	for _i in 20:
		await physics_frame
	Input.action_release("action_move_right")
	_expect(_player.velocity.x > 2.0 and _player.velocity.z < -3.0, "air steer keeps forward momentum, v=%s" % _player.velocity)


func _test_slide_locks_direction() -> void:
	Input.action_press("action_move_forward")
	for _i in 40:
		await physics_frame
	_press_action("action_crouch")
	await physics_frame
	_expect(_player.sliding, "crouch at speed starts a slide, speed=%s" % Vector3(_player.velocity.x, 0, _player.velocity.z).length())
	Input.action_release("action_move_forward")
	_look(Vector2(PI / 2.0 / _player.mouse_sensitivity, 0))
	Input.action_press("action_move_right")
	var origin: Vector3 = _player.global_position
	for _i in 12:
		await physics_frame
	Input.action_release("action_move_right")
	var delta: Vector3 = _player.global_position - origin
	_expect(delta.z < -0.8 and absf(delta.x) < 0.35, "slide stays on its start direction, delta=%s" % delta)


func _test_ceiling_blocks_stand() -> void:
	_release_all()
	_player.velocity = Vector3.ZERO
	_player.sliding = false
	_player.global_position = Vector3(30, 0.05, 0)
	for _i in 8:
		await physics_frame
	_press_action("action_crouch")
	await physics_frame
	Input.action_release("action_crouch")
	await physics_frame
	await physics_frame
	var shape: CapsuleShape3D = _player.collision_shape.shape as CapsuleShape3D
	_expect(_player.crouched and shape.height < 1.4, "ceiling keeps the player crouched, height=%s on_floor=%s" % [shape.height, _player.is_on_floor()])
