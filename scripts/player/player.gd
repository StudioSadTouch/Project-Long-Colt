class_name Player
extends CharacterBody3D
## First-person body for the Phase 0 pad.
## Yaw lives on this node. Pitch lives on Head. Movement reads this body's -Z.

@export var stand_speed: float = 7.5
@export var crouch_speed: float = 3.2
@export var ground_accel: float = 70.0
@export var air_accel: float = 18.0
## How high the feet rise, in meters. Jump speed is derived from project gravity.
@export var jump_height: float = 2.2
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.12
@export var slide_min_speed: float = 6.0
@export var slide_speed: float = 9.2
@export var slide_duration: float = 0.5
@export var slide_decel: float = 10.0
@export var mouse_sensitivity: float = 0.0022
@export var eye_blend_speed: float = 12.0
@export var fov: float = 75.0

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.15
const CAPSULE_RADIUS := 0.35
const STAND_EYE := 1.62
const CROUCH_EYE := 0.95
const PITCH_LIMIT := 89.0

## Refreshed every physics tick from get_gravity() so Area3D overrides apply.
var gravity: float = 22.0
## Runtime multiplier on mouse_sensitivity, set by zoom. Settings change mouse_sensitivity.
var look_sensitivity_scale: float = 1.0
## Runtime multiplier from AimAssist slowdown (1.0 = none).
var aim_slowdown_scale: float = 1.0
## Camera pitch/yaw offset in radians (weapon recoil). Applied on top of aim, never baked in.
var view_kick: Vector2 = Vector2.ZERO
var crouched: bool = false
var sliding: bool = false

var _eye_height: float = STAND_EYE
var _landing_dip: float = 0.0
var _coyote_left: float = 0.0
var _jump_buffer_left: float = 0.0
var _crouch_edge: bool = false
var _slide_time_left: float = 0.0
var _slide_speed: float = 0.0
var _slide_dir: Vector3 = Vector3.ZERO
var _stand_probe: CapsuleShape3D
var _lunge_dir: Vector3 = Vector3.ZERO
var _lunge_speed: float = 0.0
var _lunge_left: float = 0.0
var _spawn_transform: Transform3D

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var health_shield: HealthShield = get_node_or_null("HealthShield")


func _ready() -> void:
	gravity = get_gravity().length()
	_spawn_transform = global_transform
	if health_shield != null:
		health_shield.died.connect(_on_died)
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	collision_layer = 2
	# World and Enemy. Projectiles and interactables do not block the body.
	collision_mask = 1 | 4
	_stand_probe = CapsuleShape3D.new()
	_stand_probe.radius = CAPSULE_RADIUS
	_stand_probe.height = STAND_HEIGHT - 0.06
	_eye_height = STAND_EYE
	_apply_capsule()
	camera.fov = fov
	camera.current = true
	add_to_group("player")
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("action_pause"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("action_jump"):
		_jump_buffer_left = jump_buffer_time
	if event.is_action_pressed("action_crouch"):
		_crouch_edge = true
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_look(event.relative)


func _physics_process(delta: float) -> void:
	gravity = get_gravity().length()
	var on_floor_before := is_on_floor()
	if on_floor_before:
		_coyote_left = coyote_time

	_update_stance()

	var wish := _wish_direction()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var slide_velocity := Vector3.ZERO
	if _lunge_left > 0.0:
		# A melee lunge owns horizontal motion until it times out or is cancelled on contact.
		_lunge_left -= delta
		sliding = false
		horizontal = _lunge_dir * _lunge_speed
		if _lunge_left <= 0.0:
			horizontal = horizontal.limit_length(stand_speed)
	elif sliding:
		slide_velocity = _tick_slide(delta)
		horizontal = Vector3(slide_velocity.x, 0.0, slide_velocity.z)
	elif on_floor_before:
		horizontal = _apply_ground(horizontal, wish, delta)
	else:
		horizontal = _apply_air(horizontal, wish, delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	var vertical_before := velocity.y
	var jumped := _consume_jump()
	# Airborne gravity is split into two half steps around the move (trapezoid rule),
	# so the jump apex matches jump_height at any physics tick rate.
	var airborne := jumped or not on_floor_before
	if jumped:
		velocity.y = sqrt(2.0 * gravity * jump_height)
		sliding = false
	elif airborne:
		pass
	elif sliding:
		# Follow the floor so slides run down and up ramps instead of launching off them.
		velocity.y = slide_velocity.y
	elif velocity.y < 0.0:
		velocity.y = 0.0
	if airborne:
		velocity.y -= gravity * delta * 0.5

	move_and_slide()

	if airborne and not is_on_floor():
		velocity.y -= gravity * delta * 0.5

	if jumped:
		_coyote_left = 0.0
	elif is_on_floor():
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)

	if not on_floor_before and is_on_floor():
		var impact := maxf(-vertical_before, 0.0)
		if impact > 6.0:
			_landing_dip = minf(impact * 0.008, 0.07)

	if sliding:
		var actual := Vector3(velocity.x, 0.0, velocity.z).length()
		if actual < _slide_speed * 0.35:
			sliding = false

	_update_head(delta)
	_jump_buffer_left = maxf(_jump_buffer_left - delta, 0.0)
	_crouch_edge = false


## Damage contract shared with enemies; HealthShield applies the shield and zone rules.
func take_damage(amount: float, info: Dictionary) -> void:
	if health_shield != null:
		health_shield.apply_damage(amount, info)


## Phase 0 placeholder death: instant respawn at the spawn point with full shield and health.
func _on_died() -> void:
	cancel_lunge()
	velocity = Vector3.ZERO
	global_transform = _spawn_transform
	health_shield.reset()


## Melee lunge: drive horizontal velocity along direction for up to duration seconds.
func start_lunge(direction: Vector3, speed: float, duration: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001 or duration <= 0.0:
		return
	_lunge_dir = flat.normalized()
	_lunge_speed = speed
	_lunge_left = duration


## Ends a lunge and clamps horizontal speed to run speed so jump + melee can't boost.
## No-op when not lunging.
func cancel_lunge() -> void:
	if _lunge_left <= 0.0:
		return
	_lunge_left = 0.0
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).limit_length(stand_speed)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func is_lunging() -> bool:
	return _lunge_left > 0.0


func _apply_look(relative: Vector2) -> void:
	# Probe: rotate_y(+) turns -Z toward world -X, and rotate_x(+) looks up.
	# Mouse right is +x and mouse down is +y, so both axes are negated.
	var sensitivity := mouse_sensitivity * look_sensitivity_scale * aim_slowdown_scale
	rotate_y(-relative.x * sensitivity)
	head.rotate_x(-relative.y * sensitivity)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))


## Aim nudge in radians (AimAssist magnetism): yaw on the body, pitch on Head, clamped.
func add_aim_offset(yaw: float, pitch: float) -> void:
	rotate_y(yaw)
	head.rotate_x(pitch)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))


func _wish_direction() -> Vector3:
	var input_forward := Input.get_action_strength("action_move_forward") - Input.get_action_strength("action_move_back")
	var input_right := Input.get_action_strength("action_move_right") - Input.get_action_strength("action_move_left")
	# Body -Z, flattened. Pitch on Head must not steer this vector.
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3.ZERO
	fwd = fwd.normalized()
	# forward × up = right. Facing -Z, right is +X.
	var right := fwd.cross(Vector3.UP)
	var wish := fwd * input_forward + right * input_right
	if wish.length_squared() < 0.0001:
		return Vector3.ZERO
	return wish.normalized()


func _apply_ground(horizontal: Vector3, wish: Vector3, delta: float) -> Vector3:
	var speed := crouch_speed if crouched else stand_speed
	return horizontal.move_toward(wish * speed, ground_accel * delta)


func _apply_air(horizontal: Vector3, wish: Vector3, delta: float) -> Vector3:
	if wish == Vector3.ZERO:
		return horizontal
	var along := horizontal.dot(wish)
	var add_speed := stand_speed - along
	if add_speed <= 0.0:
		return horizontal
	var accel_speed := minf(air_accel * delta, add_speed)
	return horizontal + wish * accel_speed


func _tick_slide(delta: float) -> Vector3:
	_slide_time_left -= delta
	_slide_speed = maxf(_slide_speed - slide_decel * delta, 0.0)
	if _slide_time_left <= 0.0 or _slide_speed <= crouch_speed:
		sliding = false
	# _slide_dir stays flat to lock heading; project it onto the floor each tick.
	var dir := _slide_dir
	if is_on_floor():
		dir = _slide_dir.slide(get_floor_normal()).normalized()
	return dir * _slide_speed


func _update_stance() -> void:
	var held := Input.is_action_pressed("action_crouch")
	var horizontal_speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if _crouch_edge and is_on_floor() and not sliding and horizontal_speed >= slide_min_speed:
		sliding = true
		_slide_time_left = slide_duration
		_slide_dir = Vector3(velocity.x, 0.0, velocity.z).normalized()
		_slide_speed = maxf(horizontal_speed, slide_speed)
	if held or sliding:
		crouched = true
	elif _can_stand():
		crouched = false
	_apply_capsule()


func _consume_jump() -> bool:
	if _jump_buffer_left <= 0.0:
		return false
	if not is_on_floor() and _coyote_left <= 0.0:
		return false
	_jump_buffer_left = 0.0
	_coyote_left = 0.0
	return true


func _can_stand() -> bool:
	if not crouched:
		return true
	var space := get_world_3d().direct_space_state
	var margin := 0.06
	var test_height := STAND_HEIGHT - margin
	var center := global_position + Vector3.UP * (margin + test_height * 0.5)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _stand_probe
	params.transform = Transform3D(global_transform.basis, center)
	params.collision_mask = collision_mask
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).is_empty()


func _apply_capsule() -> void:
	var height := CROUCH_HEIGHT if crouched else STAND_HEIGHT
	var shape := collision_shape.shape as CapsuleShape3D
	shape.radius = CAPSULE_RADIUS
	shape.height = height
	collision_shape.position = Vector3(0.0, height * 0.5, 0.0)


func _update_head(delta: float) -> void:
	var target := CROUCH_EYE if crouched else STAND_EYE
	_eye_height = move_toward(_eye_height, target, eye_blend_speed * delta)
	_landing_dip = move_toward(_landing_dip, 0.0, 0.45 * delta)
	head.position.y = _eye_height - _landing_dip
	camera.rotation = Vector3(view_kick.x, view_kick.y, 0.0)
