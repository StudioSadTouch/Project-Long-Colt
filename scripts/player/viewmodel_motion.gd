class_name ViewmodelMotion
extends Node
## Procedural first-person weapon motion, layered UNDER every weapon's own clips: it moves the
## WeaponHolder (the camera child that parents all viewmodels), while reload / melee / fire
## clips animate the weapon nodes inside it, so the two never fight over a transform.
## Child of a local Player ("ViewmodelMotion" in player.tscn). Does nothing for puppets.
##
## Layers, summed every frame:
##   bob        figure-eight walk/run bob, phase driven by distance walked (one step = half a
##              cycle, step_length metres), amplitude by speed; off in the air
##   sway       the gun lags behind mouse / stick look, and leans with strafe speed
##   air        rises a little while falling, sinks while going up
##   stance     crouch drops the gun in; slide rolls it over
##   breath     slow idle drift so a still view isn't frozen
##   equip      new weapon comes up from below over its equip_time
##   springs    one-shot kicks on a damped spring: fire (scaled by WeaponData.recoil_pitch),
##              landing (by impact speed), grenade throw (weapon dips out of the off hand's way)
## Zoom (WeaponHolder.get_zoom_blend) damps bob, sway and breath so scoped aim stays steady.

@export var holder_path: NodePath = ^"../Head/Camera3D/WeaponHolder"
## Global multiplier for every layer (0 = no procedural motion).
@export_range(0.0, 2.0) var intensity: float = 1.0
@export_group("Bob")
## Metres per step; a bob cycle is two steps (matches the third-person gait's 0.6 s cycle at
## run speed: 7.5 m/s * 0.3 s = 2.25 m).
@export var step_length: float = 2.25
## Horizontal speed (m/s) at which the bob reaches full amplitude.
@export var bob_full_speed: float = 7.5
@export var bob_side: float = 0.011
@export var bob_up: float = 0.007
@export var bob_roll_deg: float = 1.2
@export_group("Sway")
## Metres of lag per radian/second of look speed, and the clamp.
@export var sway_amount: float = 0.006
@export var sway_max: float = 0.03
@export var sway_rot_deg: float = 2.5
@export var sway_smoothing: float = 10.0
## Roll (deg) at full strafe speed, and the lean-back (m) at full forward speed.
@export var strafe_roll_deg: float = 2.5
@export var move_lag: float = 0.012
@export_group("Air and stance")
@export var air_rise_per_mps: float = 0.0016
@export var air_max: float = 0.025
@export var crouch_offset: Vector3 = Vector3(-0.008, -0.012, 0.01)
@export var slide_offset: Vector3 = Vector3(-0.02, -0.03, 0.02)
@export var slide_roll_deg: float = 9.0
@export var stance_smoothing: float = 9.0
@export_group("Equip")
## Pose the gun starts from on a switch (metres, degrees: pitched down and rolled in).
@export var equip_drop: Vector3 = Vector3(0.02, -0.22, 0.06)
@export var equip_rot_deg: Vector3 = Vector3(-40.0, 8.0, 18.0)
@export var default_equip_time: float = 0.4
@export_group("Kicks")
## Fire kick = base + per_recoil * WeaponData.recoil_pitch (rifle 0.45 ... shotgun 7).
@export var fire_back_base: float = 0.005
@export var fire_back_per_recoil: float = 0.003
@export var fire_pitch_base_deg: float = 0.8
@export var fire_pitch_per_recoil: float = 0.9
@export var land_dip_per_mps: float = 0.0035
@export var land_dip_max: float = 0.06
@export var throw_dip: Vector3 = Vector3(0.03, -0.09, 0.03)
@export var throw_roll_deg: float = 22.0
## Spring stiffness (1/s^2) and damping (1/s) of the kick springs.
@export var spring_stiffness: float = 260.0
@export var spring_damping: float = 22.0

var _player: Player
## Resolved here: Player's own @onready `head` isn't set until after its children are ready.
var _head: Node3D
var _holder: Node3D
var _weapon: Weapon
var _phase: float = 0.0
var _bob_weight: float = 0.0
var _sway: Vector2 = Vector2.ZERO
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0
var _stance: Vector3 = Vector3.ZERO
var _slide_roll: float = 0.0
var _air: float = 0.0
var _breath_time: float = 0.0
var _equip_left: float = 0.0
var _equip_time: float = 0.0
var _was_on_floor: bool = true
var _last_vertical: float = 0.0
## Kick springs: position (m) and rotation (rad, pitch/yaw/roll), each with a velocity.
var _kick_pos: Vector3 = Vector3.ZERO
var _kick_pos_vel: Vector3 = Vector3.ZERO
var _kick_rot: Vector3 = Vector3.ZERO
var _kick_rot_vel: Vector3 = Vector3.ZERO


func _ready() -> void:
	_player = get_parent() as Player
	_holder = get_node_or_null(holder_path) as Node3D
	_head = _player.get_node_or_null(^"Head") as Node3D if _player != null else null
	if _player == null or _holder == null or _head == null or _player.net_puppet:
		set_process(false)
		return
	if _holder.has_signal(&"active_weapon_changed"):
		_holder.connect(&"active_weapon_changed", _on_weapon_changed)
	var thrower := _player.get_node_or_null(^"GrenadeThrower")
	if thrower != null and thrower.has_signal(&"throw_started"):
		thrower.connect(&"throw_started", _on_throw_started)
	_player.respawned.connect(func(_p: Player) -> void: reset())
	_last_yaw = _player.rotation.y
	_last_pitch = _head.rotation.x
	_on_weapon_changed.call_deferred(null)


## Back to rest at once (respawn).
func reset() -> void:
	_phase = 0.0
	_bob_weight = 0.0
	_sway = Vector2.ZERO
	_stance = Vector3.ZERO
	_slide_roll = 0.0
	_air = 0.0
	_kick_pos = Vector3.ZERO
	_kick_pos_vel = Vector3.ZERO
	_kick_rot = Vector3.ZERO
	_kick_rot_vel = Vector3.ZERO
	_equip_left = 0.0
	if _player != null:
		_last_yaw = _player.rotation.y
		_last_pitch = _head.rotation.x
	if _holder != null:
		_holder.transform = Transform3D.IDENTITY


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if _player.dead or _player.is_mounted():
		_last_yaw = _player.rotation.y
		_last_pitch = _head.rotation.x
		return
	var xf := compute(delta)
	_holder.transform = xf


## One frame of motion: advances every layer and returns the holder transform.
func compute(delta: float) -> Transform3D:
	var vel := _player.velocity
	var local := _player.global_basis.inverse() * vel
	var horizontal := Vector2(local.x, local.z)
	var speed := horizontal.length()
	var on_floor := _player.is_on_floor()
	var zoom := _zoom_blend()
	var steady := 1.0 - 0.85 * zoom

	# Bob: phase from distance, weight eases with speed and floor contact.
	var bob_target := clampf(speed / bob_full_speed, 0.0, 1.0) if on_floor else 0.0
	if _player.sliding:
		bob_target = 0.0
	_bob_weight = lerpf(_bob_weight, bob_target, 1.0 - exp(-8.0 * delta))
	if on_floor and not _player.sliding:
		_phase = fposmod(_phase + PI * speed * delta / maxf(step_length, 0.1), TAU)
	var bob_w := _bob_weight * steady
	var pos := Vector3(
		sin(_phase) * bob_side * bob_w, -absf(cos(_phase)) * bob_up * bob_w * 2.0 + bob_up * bob_w, 0.0
	)
	var rot := Vector3(0.0, 0.0, deg_to_rad(sin(_phase) * bob_roll_deg) * bob_w)

	# Look sway: lag opposite the look velocity (smoothed), plus strafe roll and move lag.
	var yaw := _player.rotation.y
	var pitch := _head.rotation.x
	var look := Vector2(wrapf(yaw - _last_yaw, -PI, PI), pitch - _last_pitch) / delta
	_last_yaw = yaw
	_last_pitch = pitch
	var sway_target := (look * sway_amount).limit_length(sway_max) * steady
	_sway = _sway.lerp(sway_target, 1.0 - exp(-sway_smoothing * delta))
	pos += Vector3(_sway.x, -_sway.y, 0.0)
	rot += Vector3(
		_sway.y / maxf(sway_max, 0.001) * deg_to_rad(sway_rot_deg) * 0.5,
		_sway.x / maxf(sway_max, 0.001) * deg_to_rad(sway_rot_deg),
		0.0
	)
	var full := maxf(bob_full_speed, 0.1)
	rot.z += -clampf(local.x / full, -1.0, 1.0) * deg_to_rad(strafe_roll_deg) * steady
	pos.z += clampf(-local.z / full, -1.0, 1.0) * move_lag * steady

	# Air: rise while falling, sink while rising.
	var air_target := 0.0 if on_floor else clampf(-vel.y * air_rise_per_mps, -air_max, air_max)
	_air = lerpf(_air, air_target, 1.0 - exp(-6.0 * delta))
	pos.y += _air

	# Landing kick from the fall speed just before touching down.
	if on_floor and not _was_on_floor:
		var impact := maxf(-_last_vertical, 0.0)
		if impact > 2.0:
			_kick_pos_vel.y -= minf(impact * land_dip_per_mps, land_dip_max) * spring_damping
			_kick_rot_vel.x -= deg_to_rad(minf(impact * 0.5, 6.0)) * spring_damping
	_was_on_floor = on_floor
	_last_vertical = vel.y

	# Stance.
	var stance_target := Vector3.ZERO
	var roll_target := 0.0
	if _player.sliding:
		stance_target = slide_offset
		roll_target = deg_to_rad(slide_roll_deg)
	elif _player.crouched:
		stance_target = crouch_offset
	var k := 1.0 - exp(-stance_smoothing * delta)
	_stance = _stance.lerp(stance_target, k)
	_slide_roll = lerpf(_slide_roll, roll_target, k)
	pos += _stance
	rot.z += _slide_roll

	# Breath.
	_breath_time += delta
	pos.y += sin(_breath_time * 1.7) * 0.0018 * steady
	pos.x += sin(_breath_time * 0.85) * 0.0012 * steady
	rot.x += sin(_breath_time * 1.7 + 0.6) * deg_to_rad(0.25) * steady

	# Kick springs (semi-implicit Euler).
	_kick_pos_vel += (-spring_stiffness * _kick_pos - spring_damping * _kick_pos_vel) * delta
	_kick_pos += _kick_pos_vel * delta
	_kick_rot_vel += (-spring_stiffness * _kick_rot - spring_damping * _kick_rot_vel) * delta
	_kick_rot += _kick_rot_vel * delta
	pos += _kick_pos
	rot += _kick_rot

	# Equip raise: ease out from the drop pose.
	if _equip_left > 0.0:
		_equip_left = maxf(_equip_left - delta, 0.0)
		var u := 1.0 - _equip_left / maxf(_equip_time, 0.001)
		var e := 1.0 - pow(1.0 - u, 3.0)
		pos += equip_drop * (1.0 - e)
		rot += Vector3(
			deg_to_rad(equip_rot_deg.x), deg_to_rad(equip_rot_deg.y), deg_to_rad(equip_rot_deg.z)
		) * (1.0 - e)

	pos *= intensity
	rot *= intensity
	return Transform3D(Basis.from_euler(rot), pos)


func _zoom_blend() -> float:
	if _holder.has_method(&"get_zoom_blend"):
		return float(_holder.call(&"get_zoom_blend"))
	return 0.0


func _on_weapon_changed(_weapon_arg: Variant) -> void:
	if _weapon != null and is_instance_valid(_weapon) and _weapon.fired.is_connected(_on_fired):
		_weapon.fired.disconnect(_on_fired)
	_weapon = null
	if _holder.has_method(&"get_active"):
		_weapon = _holder.call(&"get_active") as Weapon
	if _weapon == null:
		return
	_weapon.fired.connect(_on_fired)
	var t := default_equip_time
	if _weapon.data != null and _weapon.data.equip_time > 0.0:
		t = _weapon.data.equip_time
	_equip_time = t
	_equip_left = t


func _on_fired() -> void:
	if _weapon == null or _weapon.data == null:
		return
	var recoil := clampf(_weapon.data.recoil_pitch, 0.2, 8.0)
	var zoom := _zoom_blend()
	var steady := 1.0 - 0.6 * zoom
	var back := fire_back_base + recoil * fire_back_per_recoil
	var lift := deg_to_rad(fire_pitch_base_deg + recoil * fire_pitch_per_recoil)
	_kick_pos_vel.z += back * spring_damping * steady
	_kick_rot_vel.x += lift * spring_damping * 0.5 * steady
	# A little random yaw so automatic fire doesn't punch in a straight line.
	_kick_rot_vel.y += deg_to_rad(randf_range(-0.4, 0.4) * recoil) * spring_damping * 0.3


func _on_throw_started(_type_index: int) -> void:
	_kick_pos_vel += throw_dip * spring_damping
	_kick_rot_vel.z -= deg_to_rad(throw_roll_deg) * spring_damping
	_kick_rot_vel.x -= deg_to_rad(10.0) * spring_damping
