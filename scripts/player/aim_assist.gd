class_name AimAssist
extends Node
## Bungie-era aim assist for the player. Child of Player.
## Controller (scaled by controller_strength):
##   Magnetism  while a target sits inside the assist cone, the view follows a fraction of the
##              target's angular motion (as seen from the camera). Not a lock: if you stop
##              tracking, it stops helping once the target leaves the cone.
##   Slowdown   look sensitivity is scaled down while a target is inside the assist cone.
##   Bend       hitscan rays that would miss are bent within data.aim_bend_angle
##              (x aim_bend_auto_scale in AUTO) onto the aim point nearest the reticle, with
##              line of sight. HALO 2-STYLE BY MORGON'S CHOICE: candidates are body, helmet
##              ("head") and face/visor ("face") points, and the bent ray scores the zone it
##              actually hits, visor probe included, so a bend can land a face one-shot.
##              data.aim_bend_allow_head = false restores body-only bend scored as BODY.
##   Magnetism and slowdown use body points only.
## Mouse (modern-PC "very slight", on by default; mouse_enabled is the master toggle):
##   No magnetism and nothing ever moves the camera.
##   Slowdown   sensitivity x mouse_slowdown_scale, only while the reticle ray is actually on a
##              hitbox or aim_target collider (not merely inside a cone).
##   Bend       cone = data.aim_bend_angle x mouse_bend_scale.
## Set mouse_slowdown_scale = 1 or mouse_bend_scale = 0 to turn either part off.
## Per-weapon values live in WeaponData (aim_*). Targets are nodes in group "aim_target"; they
## may implement get_aim_points() -> {"body", "head", "face": Vector3} (empty when dead;
## only body is required).
## Device: full strength on controller (last input was InputEventJoypad*), off on mouse unless
## mouse_enabled. Slowdown scales both Player._apply_look (mouse) and _apply_stick_look (pad).

const TARGET_GROUP := &"aim_target"
## World only: hitboxes and bodies don't block line of sight to their own aim points.
const LOS_MASK := 1
## Fallback aim point height above a target's origin when it has no get_aim_points().
const BODY_FALLBACK_HEIGHT := 1.17
## Cap on magnetism correction per second (radians), so teleports or respawns can't snap aim.
const MAX_MAGNETISM_RATE := 3.0

## Multiplier on every assist when the last input came from a controller.
@export var controller_strength: float = 1.0
## Master toggle for all mouse assist.
@export var mouse_enabled: bool = true
## Sensitivity multiplier while the reticle is on a target (1 = off).
@export_range(0.0, 1.0) var mouse_slowdown_scale: float = 0.85
## Fraction of the weapon's aim_bend_angle used on mouse (0 = off).
@export_range(0.0, 1.0) var mouse_bend_scale: float = 0.3

var using_controller: bool = false
## Reticle ray is on a hitbox / aim_target collider this tick (both devices). HUD turns red.
var reticle_on_target: bool = false

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
		var dz := _player.stick_deadzone if _player != null else 0.2
		if absf((event as InputEventJoypadMotion).axis_value) > dz:
			using_controller = true
	elif event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey:
		using_controller = false


## 0..n multiplier for controller assist; 0 on mouse (mouse uses its own scales).
func strength() -> float:
	return controller_strength if using_controller else 0.0


## Bend cone multiplier for the current device (applied to data.aim_bend_angle).
func bend_scale() -> float:
	if using_controller:
		return clampf(controller_strength, 0.0, 1.0)
	return mouse_bend_scale if mouse_enabled else 0.0


func _physics_process(delta: float) -> void:
	if _player.is_dead() or _player.is_mounted():
		# The gun camera is not this rig's camera. Leave the minigun to the driver's look.
		reticle_on_target = false
		_player.aim_slowdown_scale = 1.0
		_tracked = null
		return
	var active := _active_data()
	reticle_on_target = active != null and _camera != null and _reticle_on_target(active)
	if not using_controller:
		_mouse_process()
		return
	var data := _active_data()
	var s := strength()
	if data == null or s <= 0.0 or data.aim_assist_cone <= 0.0 or _camera == null:
		_player.aim_slowdown_scale = 1.0
		_tracked = null
		return
	var forward := -_camera.global_transform.basis.z
	var best := _best_point(forward, data.aim_assist_cone, data.aim_assist_range)
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


## Mouse: slowdown only while the reticle ray is on a target; never touches the camera.
func _mouse_process() -> void:
	_tracked = null
	var data := _active_data()
	if not mouse_enabled or data == null or not reticle_on_target:
		_player.aim_slowdown_scale = 1.0
		return
	_player.aim_slowdown_scale = mouse_slowdown_scale


## True when the centre ray hits a Hitbox-layer collider or a node in an aim_target subtree.
func _reticle_on_target(data: WeaponData) -> bool:
	var weapon := _holder.get_active()
	var from := _camera.global_position
	var reach := data.aim_assist_range if data.aim_assist_range > 0.0 else data.max_range
	var to := from - _camera.global_transform.basis.z * reach
	var mask := weapon.get_hit_mask() if weapon != null else Weapon.HIT_MASK
	# The player's own capsule, Hurtbox and head hitboxes (the camera sits inside the helmet).
	var exclude: Array[RID] = []
	for body in _player.get_own_colliders():
		exclude.append(body.get_rid())
	var space := _player.get_world_3d().direct_space_state
	var collider: CollisionObject3D = null
	# Same rule as Weapon._cast_ray: areas only count on the Hitbox layer; passthrough skipped.
	for _i in 8:
		var query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
		query.collide_with_areas = true
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return false
		collider = hit.collider as CollisionObject3D
		if collider == null:
			return false
		if Weapon.is_ignored_collider(collider):
			exclude.append(hit.rid)
			collider = null
			continue
		break
	if collider == null:
		return false
	if collider.collision_layer & Weapon.LAYER_HITBOX:
		return true
	var node: Node = collider
	while node != null:
		if node.is_in_group(TARGET_GROUP):
			return true
		node = node.get_parent()
	return false


## Bullet bend. Returns direction unchanged when nothing valid is inside the bend cone.
## extra_scale: caller's per-mode multiplier (Weapon passes aim_bend_auto_scale in AUTO).
func bend(direction: Vector3, data: WeaponData, extra_scale: float = 1.0) -> Vector3:
	var s := bend_scale() * extra_scale
	if data == null or s <= 0.0 or data.aim_bend_angle <= 0.0 or _camera == null:
		return direction
	var cone := data.aim_bend_angle * s
	var best := _best_point(direction, cone, data.aim_assist_range, data.aim_bend_allow_head)
	if best.is_empty():
		return direction
	return (best.point - _camera.global_position).normalized()


## Aim point nearest direction (by angle) inside cone_deg and range with line of sight.
## allow_head adds each target's "head" and "face" points as candidates beside "body".
func _best_point(
	direction: Vector3, cone_deg: float, max_range: float, allow_head: bool = false
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
		var candidates: Array[Vector3] = [points.body]
		if allow_head:
			for key in ["head", "face"]:
				if points.has(key):
					candidates.append(points[key])
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
