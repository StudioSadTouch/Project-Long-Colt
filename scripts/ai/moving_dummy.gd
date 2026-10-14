class_name MovingDummy
extends CharacterBody3D
## Moving greybox target. Same DummyCore / HealthShield / hitbox rig as TargetDummy; adds
## movement at player-like speeds. Facing never changes (front stays local -Z), only position.
##
## Patterns:
##   PATROL  walk between waypoints (offsets from the start position, world axes), looping.
##   STRAFE  ADAD along the local X axis; flips every strafe_duration +/- jitter.
##   SPARTAN random-length strafes (some stops) plus random jumps at player speed.
##   PATH    follow a Path3D's curve by distance, looping or ping-ponging.
## All movement is clamped to bounds_min / bounds_max (world X/Z) when bounds are set; hitting
## a bound flips the strafe direction. Deterministic for a given seed (0 = random each run).

enum Pattern { PATROL, STRAFE, SPARTAN, PATH }

## Player defaults (player.gd): stand_speed 7.5, ground_accel 70, air_accel 18, jump 2.2 m.
const PLAYER_SPEED := 7.5
const PLAYER_GROUND_ACCEL := 70.0
const PLAYER_AIR_ACCEL := 18.0
const PLAYER_JUMP_HEIGHT := 2.2
const WAYPOINT_REACH := 0.25

@export var pattern: Pattern = Pattern.STRAFE
@export var move_seed: int = 0
@export var ground_accel: float = PLAYER_GROUND_ACCEL
@export var air_accel: float = PLAYER_AIR_ACCEL
@export var jump_height: float = PLAYER_JUMP_HEIGHT

@export_group("Bounds")
## World-space X/Z rectangle the dummy must stay inside. Ignored if min >= max on an axis.
@export var bounds_min: Vector2 = Vector2.ZERO
@export var bounds_max: Vector2 = Vector2.ZERO

@export_group("Patrol")
@export var patrol_points: PackedVector3Array = PackedVector3Array([Vector3.ZERO])
@export var patrol_speed: float = 3.0
@export var patrol_pause: float = 0.5

@export_group("Strafe")
@export var strafe_speed: float = PLAYER_SPEED
@export var strafe_duration: float = 0.6
## Fraction of strafe_duration added or removed at random each leg (0.3 = +/-30%).
@export_range(0.0, 1.0) var strafe_jitter: float = 0.3

@export_group("Spartan")
@export var spartan_speed: float = PLAYER_SPEED
@export var spartan_min_leg: float = 0.2
@export var spartan_max_leg: float = 0.9
## Chance a leg is a brief stop instead of a strafe.
@export_range(0.0, 1.0) var spartan_stop_chance: float = 0.15
## Average jumps per second while grounded.
@export var spartan_jump_rate: float = 0.6

@export_group("Path")
@export var path: NodePath
@export var path_speed: float = 4.0
@export var path_ping_pong: bool = false

var _rng := RandomNumberGenerator.new()
var _start: Transform3D
var _dir: float = 1.0
var _leg_left: float = 0.0
var _wait_left: float = 0.0
var _point_index: int = 0
var _path_offset: float = 0.0
var _path_sign: float = 1.0
var _curve: Curve3D
var _path_node: Path3D

@onready var core: DummyCore = $DummyCore


func _ready() -> void:
	_start = global_transform
	_path_node = get_node_or_null(path) as Path3D
	if _path_node != null:
		_curve = _path_node.curve
	core.respawned.connect(_reset)
	_reset()


## Weapon contract. Shield/zone rules live in HealthShield via DummyCore.
func take_damage(amount: float, info: Dictionary) -> void:
	core.take_damage(amount, info)


func _reset() -> void:
	global_transform = _start
	velocity = Vector3.ZERO
	if move_seed != 0:
		_rng.seed = move_seed
	else:
		_rng.randomize()
	_dir = 1.0
	_leg_left = 0.0
	_wait_left = 0.0
	_point_index = 0
	_path_offset = 0.0
	_path_sign = 1.0


func _physics_process(delta: float) -> void:
	if core.dead:
		return
	var wish := Vector3.ZERO
	match pattern:
		Pattern.PATROL:
			wish = _patrol(delta)
		Pattern.STRAFE:
			wish = _strafe(delta)
		Pattern.SPARTAN:
			wish = _spartan(delta)
		Pattern.PATH:
			wish = _follow_path(delta)
	wish = _keep_in_bounds(wish, delta)
	var on_floor := is_on_floor()
	var accel := ground_accel if on_floor else air_accel
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).move_toward(wish, accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	var gravity := get_gravity()
	if on_floor:
		if velocity.y < 0.0:
			velocity.y = 0.0
	else:
		velocity += gravity * delta
	move_and_slide()
	_clamp_position()


func _strafe_axis() -> Vector3:
	var axis := _start.basis.x
	axis.y = 0.0
	return axis.normalized()


func _patrol(delta: float) -> Vector3:
	if patrol_points.is_empty():
		return Vector3.ZERO
	if _wait_left > 0.0:
		_wait_left -= delta
		return Vector3.ZERO
	var target := _start.origin + patrol_points[_point_index]
	var offset := target - global_position
	offset.y = 0.0
	if offset.length() <= WAYPOINT_REACH:
		_point_index = (_point_index + 1) % patrol_points.size()
		_wait_left = patrol_pause
		return Vector3.ZERO
	# Slow into the waypoint so accel doesn't overshoot it.
	var speed := minf(patrol_speed, offset.length() / maxf(delta, 0.001))
	return offset.normalized() * speed


func _strafe(delta: float) -> Vector3:
	_leg_left -= delta
	if _leg_left <= 0.0:
		_dir = -_dir
		var jitter := _rng.randf_range(-strafe_jitter, strafe_jitter)
		_leg_left = maxf(strafe_duration * (1.0 + jitter), 0.05)
	return _strafe_axis() * _dir * strafe_speed


func _spartan(delta: float) -> Vector3:
	_leg_left -= delta
	if _leg_left <= 0.0:
		_leg_left = _rng.randf_range(spartan_min_leg, spartan_max_leg)
		if _rng.randf() < spartan_stop_chance:
			_dir = 0.0
		else:
			_dir = -1.0 if _rng.randf() < 0.5 else 1.0
	if is_on_floor() and _rng.randf() < spartan_jump_rate * delta:
		velocity.y = sqrt(2.0 * get_gravity().length() * jump_height)
	return _strafe_axis() * _dir * spartan_speed


func _follow_path(delta: float) -> Vector3:
	if _curve == null or _curve.get_baked_length() <= 0.0:
		return Vector3.ZERO
	var length := _curve.get_baked_length()
	_path_offset += path_speed * delta * _path_sign
	if path_ping_pong:
		if _path_offset >= length or _path_offset <= 0.0:
			_path_sign = -_path_sign
			_path_offset = clampf(_path_offset, 0.0, length)
	else:
		_path_offset = fposmod(_path_offset, length)
	var target := _path_node.global_transform * _curve.sample_baked(_path_offset)
	var offset := target - global_position
	offset.y = 0.0
	# Steer toward the moving sample; cap at a bit over path_speed to catch up after hitches.
	return offset.limit_length(1.0) * path_speed * 1.25 if offset.length() > 0.05 else Vector3.ZERO


func _has_bounds() -> bool:
	return bounds_max.x > bounds_min.x and bounds_max.y > bounds_min.y


## Zero the wish component that would cross a bound next tick, flipping strafes back inward.
func _keep_in_bounds(wish: Vector3, delta: float) -> Vector3:
	if not _has_bounds():
		return wish
	var next := global_position + Vector3(velocity.x, 0.0, velocity.z) * delta * 4.0
	var out_x := (
		(next.x < bounds_min.x and wish.x < 0.0) or (next.x > bounds_max.x and wish.x > 0.0)
	)
	var out_z := (
		(next.z < bounds_min.y and wish.z < 0.0) or (next.z > bounds_max.y and wish.z > 0.0)
	)
	if not (out_x or out_z):
		return wish
	if pattern == Pattern.STRAFE or pattern == Pattern.SPARTAN:
		_dir = -_dir
		return -wish
	if out_x:
		wish.x = 0.0
	if out_z:
		wish.z = 0.0
	return wish


## Hard stop at the bounds in case accel or a jump carried it past.
func _clamp_position() -> void:
	if not _has_bounds():
		return
	var p := global_position
	var clamped_x := clampf(p.x, bounds_min.x, bounds_max.x)
	var clamped_z := clampf(p.z, bounds_min.y, bounds_max.y)
	if clamped_x != p.x:
		velocity.x = 0.0
	if clamped_z != p.z:
		velocity.z = 0.0
	global_position = Vector3(clamped_x, p.y, clamped_z)
