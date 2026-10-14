class_name AimAssist
extends Node
## Bungie-era aim assist for the player. Child of Player. Three parts, all scaled by strength():
##   Magnetism  while a target sits inside the assist cone, the view follows a fraction of the
##              target's angular motion (as seen from the camera). Not a lock: if you stop
##              tracking, it stops helping once the target leaves the cone.
##   Slowdown   look sensitivity is scaled down while a target is inside the assist cone.
##   Bend       hitscan rays that would miss are bent onto the nearest valid aim point within
##              data.aim_bend_angle, with line of sight; heads win only when inside the cone.
## Per-weapon values live in WeaponData (aim_*). Targets are nodes in group "aim_target"; they
## may implement get_aim_points() -> {"body": Vector3, "head": Vector3} (empty when dead).
## Device: full strength on controller (last input was InputEventJoypad*), off on mouse unless
## mouse_enabled. Note Phase 0 has no stick look yet, so on controller only bend and magnetism
## act until stick look lands; slowdown scales whatever look path uses Player._apply_look.

const TARGET_GROUP := &"aim_target"
## World only: hitboxes and bodies don't block line of sight to their own aim points.
const LOS_MASK := 1
## Fallback aim point height above a target's origin when it has no get_aim_points().
const BODY_FALLBACK_HEIGHT := 1.0
## Cap on magnetism correction per second (radians), so teleports or respawns can't snap aim.
const MAX_MAGNETISM_RATE := 3.0

## Multiplier on every assist when the last input came from a controller.
@export var controller_strength: float = 1.0
## Mouse players get no assist unless this is on.
@export var mouse_enabled: bool = false
## Multiplier when mouse_enabled and the last input came from mouse/keyboard.
@export var mouse_strength: float = 0.5

var using_controller: bool = false

var _player: Player
var _camera: Camera3D
var _holder: WeaponHolder
var _tracked: Node3D
var _last_dir: Vector3 = Vector3.ZERO


func _ready() -> void:
	_player = get_parent() as Player
	if _player == null:
		push_error("AimAssist must be a child of Player")
		set_physics_process(false)
		return
	_camera = _player.get_node_or_null("Head/Camera3D") as Camera3D
	_holder = _player.get_node_or_null("Head/Camera3D/WeaponHolder") as WeaponHolder


func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		using_controller = true
	elif event is InputEventJoypadMotion:
		# Same deadzone as stick look (Player.stick_deadzone); triggers count too.
		if absf((event as InputEventJoypadMotion).axis_value) > _player.stick_deadzone:
			using_controller = true
	elif event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey:
		using_controller = false


## 0..n multiplier for the current input device.
func strength() -> float:
	if using_controller:
		return controller_strength
	return mouse_strength if mouse_enabled else 0.0


func _physics_process(delta: float) -> void:
	var data := _active_data()
	var s := strength()
	if data == null or s <= 0.0 or data.aim_assist_cone <= 0.0 or _camera == null:
		_player.aim_slowdown_scale = 1.0
		_tracked = null
		return
	var forward := -_camera.global_transform.basis.z
	var best := _best_point(forward, data.aim_assist_cone, data.aim_assist_range, false)
	if best.is_empty():
		_player.aim_slowdown_scale = 1.0
		_tracked = null
		return
	_player.aim_slowdown_scale = lerpf(1.0, data.aim_slowdown, clampf(s, 0.0, 1.0))
	var dir: Vector3 = (best.point - _camera.global_position).normalized()
	if best.target == _tracked and data.aim_magnetism > 0.0:
		var d_yaw := wrapf(_yaw(dir) - _yaw(_last_dir), -PI, PI)
		var d_pitch := _pitch(dir) - _pitch(_last_dir)
		var limit := MAX_MAGNETISM_RATE * delta
		var k := data.aim_magnetism * s
		_player.add_aim_offset(clampf(d_yaw * k, -limit, limit), clampf(d_pitch * k, -limit, limit))
	_tracked = best.target
	_last_dir = dir


## Bullet bend. Returns direction unchanged when nothing valid is inside the bend cone.
func bend(direction: Vector3, data: WeaponData) -> Vector3:
	var s := strength()
	if data == null or s <= 0.0 or data.aim_bend_angle <= 0.0 or _camera == null:
		return direction
	var cone := data.aim_bend_angle * clampf(s, 0.0, 1.0)
	var best := _best_point(direction, cone, data.aim_assist_range, true)
	if best.is_empty():
		return direction
	return (best.point - _camera.global_position).normalized()


## Nearest aim point (by angle from direction) inside cone_deg and range with line of sight.
## prefer_head: a head point inside the cone beats that target's body point.
func _best_point(
	direction: Vector3, cone_deg: float, max_range: float, prefer_head: bool
) -> Dictionary:
	var origin := _camera.global_position
	var cone := deg_to_rad(cone_deg)
	var best := {}
	var best_angle := INF
	for node in get_tree().get_nodes_in_group(TARGET_GROUP):
		var target := node as Node3D
		if target == null or not target.is_visible_in_tree():
			continue
		var points := _aim_points(target)
		if points.is_empty():
			continue
		var candidates: Array[Vector3] = []
		if prefer_head and points.has("head"):
			candidates.append(points.head)
		candidates.append(points.body)
		for point in candidates:
			var offset := point - origin
			var distance := offset.length()
			if distance <= 0.01 or (max_range > 0.0 and distance > max_range):
				continue
			var angle := direction.angle_to(offset / distance)
			if angle > cone or angle >= best_angle or not _has_los(origin, point):
				continue
			best_angle = angle
			best = {"target": target, "point": point, "angle": angle}
			# Head inside the cone wins for this target; don't fall back to its body.
			break
	return best


func _aim_points(target: Node3D) -> Dictionary:
	if target.has_method("get_aim_points"):
		return target.get_aim_points()
	return {"body": target.global_position + Vector3.UP * BODY_FALLBACK_HEIGHT}


func _has_los(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, LOS_MASK, [_player.get_rid()])
	return _player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _active_data() -> WeaponData:
	if _holder == null:
		return null
	var weapon := _holder.get_active()
	return weapon.data if weapon != null else null


static func _yaw(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


static func _pitch(dir: Vector3) -> float:
	return asin(clampf(dir.y, -1.0, 1.0))
