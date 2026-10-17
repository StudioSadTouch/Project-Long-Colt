class_name ThirdPersonCamera
extends Node
## Over-the-shoulder view for the LOCAL Player ("ThirdPersonCamera" in player.tscn). Settings:
## Settings.third_person / Settings.left_shoulder (menu and pause Settings pages), or in a match
## action_camera_view (T) toggles first / third person and action_camera_shoulder (B) swaps
## the shoulder. Both keys save the choice.
##
## Why a second camera instead of moving the Player's Camera3D: everything that aims reads that
## camera (weapon rays, AimAssist, grenades, the host's shot-origin check, the netcode). It stays
## at the eyes, untouched; this camera only changes what you SEE, so aiming, hit registration
## and the network are the same in both views.
##
## Crosshair: the camera sits behind and beside the head, so its screen centre would not point
## where the eye ray hits. Each frame it casts the eye ray and turns to look at that point
## ("convergence"), so the crosshair is always over what your shots hit. The distance is
## smoothed so the view doesn't snap when the ray crosses a wall edge.
##
## Walls: a sphere sweep from the eyes pulls the camera in front of anything behind you; it
## springs back out slowly. Closer than hide_body_distance the camera would be inside your own
## helmet, so your body is hidden again.
##
## Falls back to first person: while zoomed (scopes stay first person), and in a vehicle (the
## Humvee owns the cameras then). The viewmodel is hidden while this view is live, and your
## shots draw tracers from the third-person gun (NetFx, as remote players see them).

@export var enabled: bool = false:
	set(value):
		enabled = value
		if not enabled and is_inside_tree():
			_release_view()
@export var left_shoulder: bool = false
@export_group("Placement")
## Behind the eyes, metres.
@export var distance: float = 2.8
## Beside the eyes (toward the chosen shoulder), metres.
@export var side_offset: float = 0.8
## Above the eyes (world up), metres.
@export var height: float = 0.3
## Shoulder swap blend rate (1/s).
@export var side_smoothing: float = 9.0
@export_group("Collision")
@export var collision_radius: float = 0.22
## Camera pull-in snaps; easing back out after a wall runs at this rate (1/s).
@export var return_smoothing: float = 5.0
## Closer than this to the eyes the camera is inside the helmet: hide our own body.
@export var hide_body_distance: float = 0.75
@export_group("Aim")
## Nearest convergence distance, metres (a wall at your nose would swing the view wildly).
@export var min_converge: float = 3.0
@export var max_converge: float = 300.0
## Convergence smoothing rate (1/s). 0 = snap.
@export var converge_smoothing: float = 14.0

var camera: Camera3D

var _player: Player
var _eye: Camera3D
var _holder: WeaponHolder
var _weapon: Weapon
var _hand: Node3D
var _side: float = 1.0
var _arm: float = -1.0
var _converge: float = 30.0
var _exclude: Array[RID] = []
var _hid_viewmodel: bool = false
## ray_fired results this frame: one NetFx tracer batch per frame (shotgun pellets).
var _shot_tos: PackedVector3Array = PackedVector3Array()
var _shot_hits: PackedByteArray = PackedByteArray()


func _ready() -> void:
	_player = get_parent() as Player
	# Player's own @onready `camera` isn't set until after its children are ready.
	_eye = _player.get_node_or_null(^"Head/Camera3D") as Camera3D if _player != null else null
	if _player == null or _eye == null or _player.net_puppet:
		set_process(false)
		set_process_unhandled_input(false)
		return
	# After the Player and its children have moved this frame.
	process_priority = 100
	_holder = _player.get_node_or_null(^"Head/Camera3D/WeaponHolder") as WeaponHolder
	var settings := _settings()
	if settings != null:
		settings.connect(&"changed", _read_settings)
		_read_settings()
	_side = -1.0 if left_shoulder else 1.0


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return  # a menu is open
	if event.is_action_pressed(&"action_camera_view"):
		_store(not enabled, left_shoulder)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"action_camera_shoulder") and enabled:
		_store(enabled, not left_shoulder)
		get_viewport().set_input_as_handled()


## True while the over-the-shoulder camera is the one you are looking through.
func is_active() -> bool:
	return camera != null and camera.current


func _process(delta: float) -> void:
	_track_weapon()
	if not _wants_view():
		_release_view()
		return
	if camera == null:
		_make_camera()
	# Take over only from our own eye camera: a Humvee or spectator camera keeps the view.
	if not camera.current:
		if not _eye.current:
			return
		camera.make_current()
		_arm = -1.0
	_set_viewmodel_hidden(true)
	_place(delta)
	_flush_shots()


func _wants_view() -> bool:
	if not enabled or _player.mounted_vehicle != null:
		return false
	return _weapon == null or not _weapon.zoomed


## Back to the first-person camera and viewmodel.
func _release_view() -> void:
	_shot_tos.clear()
	_shot_hits.clear()
	if camera != null and camera.current and _eye != null:
		_eye.make_current()
	_set_viewmodel_hidden(false)


func _make_camera() -> void:
	camera = Camera3D.new()
	camera.name = "View"
	camera.top_level = true
	camera.near = 0.15
	camera.far = minf(_eye.far, 600.0) if _eye != null and _eye.far > 0.0 else 600.0
	add_child(camera)
	_exclude.clear()
	for body in _player.get_own_colliders():
		_exclude.append(body.get_rid())


func _place(delta: float) -> void:
	var aim := _eye.global_transform.orthonormalized()
	var right := aim.basis.x
	var back := aim.basis.z
	var target_side := -1.0 if left_shoulder else 1.0
	_side = lerpf(_side, target_side, 1.0 - exp(-side_smoothing * delta))
	var shoulder := aim.origin + Vector3.UP * height + right * side_offset * _side
	var desired := shoulder + back * distance
	# Two sweeps: eyes -> shoulder, then shoulder -> behind (a wall beside you, then behind you).
	var space := _player.get_world_3d().direct_space_state
	var side_frac := _sweep(space, aim.origin, shoulder)
	var pivot := aim.origin.lerp(shoulder, side_frac)
	var back_frac := _sweep(space, pivot, pivot + back * distance)
	var arm := distance * back_frac
	if _arm < 0.0 or arm < _arm:
		_arm = arm  # pull in at once, never through the wall
	else:
		_arm = lerpf(_arm, arm, 1.0 - exp(-return_smoothing * delta))
	var position := pivot + back * _arm
	if _arm >= distance - 0.001 and side_frac >= 0.999:
		position = desired
	# Convergence: look at what the eye ray hits.
	var forward := -aim.basis.z
	var reach := max_converge
	var query := PhysicsRayQueryParameters3D.create(
		aim.origin, aim.origin + forward * max_converge, Weapon.HIT_MASK, _exclude
	)
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		reach = aim.origin.distance_to(hit.position)
	reach = clampf(reach, min_converge, max_converge)
	if converge_smoothing <= 0.0:
		_converge = reach
	else:
		_converge = lerpf(_converge, reach, 1.0 - exp(-converge_smoothing * delta))
	var focus := aim.origin + forward * _converge
	var look := focus - position
	if look.length_squared() < 0.0001:
		look = forward
	camera.global_transform = Transform3D(Basis.looking_at(look, aim.basis.y), position)
	camera.fov = _eye.fov
	var mask := _eye.cull_mask
	if position.distance_to(aim.origin) > hide_body_distance:
		mask |= Player.HIDDEN_BODY_LAYER
	camera.cull_mask = mask


## Fraction (0..1) of from -> to a sphere of collision_radius travels before touching World.
func _sweep(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> float:
	var motion := to - from
	if motion.length_squared() < 0.000001:
		return 1.0
	var shape := SphereShape3D.new()
	shape.radius = collision_radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, from)
	params.motion = motion
	params.collision_mask = 1
	params.exclude = _exclude
	var result := space.cast_motion(params)
	return result[0] if result.size() > 0 else 1.0


## The first-person gun would float in front of the third-person camera. holder.visible only
## hides it (Weapon logic is gated on weapon.visible, never on the holder).
## Only undoes its own hide, so anything else that hides the holder keeps it hidden.
func _set_viewmodel_hidden(hidden: bool) -> void:
	if _holder == null or hidden == _hid_viewmodel:
		return
	_hid_viewmodel = hidden
	_holder.visible = not hidden


func _track_weapon() -> void:
	var active := _holder.get_active() if _holder != null else null
	if active == _weapon:
		return
	if is_instance_valid(_weapon) and _weapon.ray_fired.is_connected(_on_ray_fired):
		_weapon.ray_fired.disconnect(_on_ray_fired)
	_weapon = active
	if _weapon != null:
		_weapon.ray_fired.connect(_on_ray_fired)


func _on_ray_fired(_from: Vector3, to: Vector3, hit: Dictionary) -> void:
	if not is_active():
		return
	_shot_tos.append(to)
	_shot_hits.append(0 if hit.is_empty() else 1)


## Tracers from the third-person gun (the hand), since the viewmodel's flash is hidden.
func _flush_shots() -> void:
	if _shot_tos.is_empty():
		return
	if _hand == null or not is_instance_valid(_hand):
		_hand = _player.find_child("WeaponAttach_R", true, false) as Node3D
	var from := _hand.global_position if _hand != null else _eye.global_position
	NetFx.spawn_shots(_player.get_parent(), from, _shot_tos, _shot_hits)
	_shot_tos.clear()
	_shot_hits.clear()


func _settings() -> Node:
	return get_node_or_null(^"/root/Settings")


func _read_settings() -> void:
	var settings := _settings()
	if settings == null:
		return
	enabled = bool(settings.get(&"third_person"))
	left_shoulder = bool(settings.get(&"left_shoulder"))


func _store(third: bool, left: bool) -> void:
	enabled = third
	left_shoulder = left
	var settings := _settings()
	if settings == null:
		return
	settings.set(&"third_person", third)
	settings.set(&"left_shoulder", left)
	settings.call(&"save_settings")
