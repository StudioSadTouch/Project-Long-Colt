class_name Humvee
extends CharacterBody3D
## Open-top humvee for the big maps. Local -Z is forward, +X is right (forward × up).
## Steer right decreases rotation.y, so -Z turns toward world +X.
## Two seats. The driver (left, Seat) drives with the move actions and looks around from
## their own camera. The gunner (GunnerSeat, child of GunYaw) aims and fires the roof
## minigun. Look uses the same rotate_y / rotate_x signs as Player. The hull is the
## collision box; the meshes are built from that same frame in _build. Offline / bot
## arena only: the body is not replicated.

const MAX_SPEED := 16.0
const REVERSE_SPEED := 6.0
const ACCEL := 10.0
const BRAKE := 16.0
const STEER_RATE := 1.25
const GUN_PITCH_MIN := -0.22
const GUN_PITCH_MAX := 0.95
const ROUND_DAMAGE := 8.0
const ROUND_RANGE := 90.0
const FIRE_INTERVAL := 0.05
const SPINUP := 0.28
const HULL_HEALTH := 700.0
const HIT_MASK := 1 | 4 | (1 << 5) | (1 << 1)
## Bot movement bodies sit on this layer (see Bot.BOT_BODY_LAYER) so the hull can hit them.
## Players already use layer 2. Neither weapons nor on-foot players mask this bit.
const BOT_BODY_LAYER := 128
## Splatter only once the hull is well above a player's 7.5 m/s run. Reverse tops out at 6.
const SPLATTER_SPEED := 10.0
## Someone whose center is in front of this, and inside the hull's half-width, is in the lane.
const HEAD_ON_AHEAD := 1.6
const HEAD_ON_LATERAL := 1.15

var hull: float = HULL_HEALTH
var wrecked: bool = false

var _driver: Player = null
var _gunner: Player = null
## Occupant whose eyes the one viewport uses. The other occupant's body stays visible.
var _view: Player = null
var _overlapping: Array[Player] = []
var _speed: float = 0.0
var _spin: float = 0.0
var _trigger: float = 0.0
var _cooldown: float = 0.0
## Hull-relative look for the driver. The seat basis is the zero. Positive yaw turns
## their -Z toward the hull's -X. Positive pitch looks up.
var _driver_yaw: float = 0.0
var _driver_pitch: float = 0.0
var _saved_masks: Dictionary = {}
var _gun_camera: Camera3D = null
var _barrels: Node3D = null
var _tracer: MeshInstance3D = null
var _prompt: Label3D = null
var _shot: AudioStreamPlayer3D = null
var _shot_skips: int = 0
## Driver colliders stay excepted until this physics frame, so the hull's next
## move cannot be shoved by a capsule that is still at the seat.
var _held_out: Array[CollisionObject3D] = []
var _held_until: int = 0


func _ready() -> void:
	if get_node_or_null(^"Visual") == null:
		_build()
	_gun_camera = get_node(^"GunYaw/GunPitch/Camera3D") as Camera3D
	_barrels = get_node(^"GunYaw/GunPitch/Barrels") as Node3D
	_tracer = get_node(^"Tracer") as MeshInstance3D
	_prompt = get_node(^"Prompt") as Label3D
	_shot = get_node(^"Shot") as AudioStreamPlayer3D
	var stream: AudioStream = load("res://assets/audio/weapons/standard_issue_rifle_fire.wav") as AudioStream
	if stream != null:
		_shot.stream = stream
		_shot.volume_db = -10.0
	motion_mode = MOTION_MODE_GROUNDED
	floor_constant_speed = true
	floor_block_on_wall = true
	collision_mask = 1 | 2 | BOT_BODY_LAYER


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_drop_held_out()
	_update_prompt()
	if wrecked or _driver == null:
		_speed = move_toward(_speed, 0.0, BRAKE * delta)
	else:
		_drive(delta)
	if not wrecked and _gunner != null:
		_aim_gun(delta)
	else:
		_trigger = 0.0
		_spin = move_toward(_spin, 0.0, 40.0 * delta)
		if _barrels != null:
			_barrels.rotate_z(_spin * delta)
	var fwd := _planar_forward()
	if is_on_floor():
		# Horizontal only. A constant downward stick sinks the box into the slab
		# under Jolt while is_on_floor stays true. floor_snap_length holds ramps.
		velocity = Vector3(fwd.x * _speed, 0.0, fwd.z * _speed)
	else:
		velocity.x = fwd.x * _speed
		velocity.z = fwd.z * _speed
		velocity.y -= float(ProjectSettings.get_setting("physics/3d/default_gravity")) * delta
	move_and_slide()
	_splatter()
	var traveled := Vector3(velocity.x, 0.0, velocity.z)
	_speed = traveled.dot(fwd)
	if _driver != null:
		_snap_driver()
	if _gunner != null:
		_snap_gunner()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not event.is_action_pressed("action_interact"):
		return
	if DisplayServer.get_name() != "headless" and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var boarder := _boarder()
	if boarder != null:
		var seat := seat_for(boarder)
		if seat != "" and enter(boarder, seat):
			get_viewport().set_input_as_handled()
		return
	if _view != null:
		exit_vehicle(_view)
		get_viewport().set_input_as_handled()


## Mouse delta from `who`, same signs as Player._apply_look. The gunner turns the
## minigun. The driver turns in the seat and does not move the gun.
func add_look(who: Player, relative: Vector2, sensitivity: float) -> void:
	add_aim_for(who, -relative.x * sensitivity, -relative.y * sensitivity)


## Radians from `who`. Positive yaw is counter-clockwise from above.
func add_aim_for(who: Player, yaw: float, pitch: float) -> void:
	if who == _gunner:
		add_aim_radians(yaw, pitch)
		return
	if who != _driver:
		return
	_driver_yaw = wrapf(_driver_yaw + yaw, -PI, PI)
	var limit := deg_to_rad(Player.PITCH_LIMIT)
	_driver_pitch = clampf(_driver_pitch + pitch, -limit, limit)


## Radians, in the hull's frame. Positive yaw turns the gun's -Z toward local -X
## (world -X only while the hull's yaw is 0). Positive pitch looks up.
func add_aim_radians(yaw: float, pitch: float) -> void:
	var gun_yaw := get_node(^"GunYaw") as Node3D
	var gun_pitch := get_node(^"GunYaw/GunPitch") as Node3D
	gun_yaw.rotate_y(yaw)
	gun_pitch.rotation.x = clampf(gun_pitch.rotation.x + pitch, GUN_PITCH_MIN, GUN_PITCH_MAX)


## `seat_name` is "driver" (default, left seat) or "gunner" (the turret).
func enter(player: Player, seat_name: String = "driver") -> bool:
	if wrecked or player == null or player.dead or player.net_puppet:
		return false
	if player.mounted_vehicle != null:
		return false
	var as_gunner := seat_name == "gunner"
	if as_gunner:
		if _gunner != null:
			return false
	elif _driver != null:
		return false
	if as_gunner:
		_gunner = player
	else:
		_driver = player
		_driver_yaw = 0.0
		_driver_pitch = 0.0
	player.mounted_vehicle = self
	player.velocity = Vector3.ZERO
	_saved_masks[player] = player.collision_mask
	player.collision_mask = 0
	# Mask includes the player layer so a driven hull stops on infantry. Seated
	# bodies stay excepted, or a seat capsule would pin the truck.
	for body in player.get_own_colliders():
		add_collision_exception_with(body)
		_held_out.erase(body)
	if not player.died.is_connected(_on_occupant_died):
		player.died.connect(_on_occupant_died)
	if _view == null:
		_view = player
	if as_gunner:
		_snap_gunner()
	else:
		_snap_driver()
	_refresh_presence()
	return true


## Which free seat `player` would take from where they stand. Empty when neither is free.
## The closer marker wins. A taken preferred seat falls through to the other one.
func seat_for(player: Player) -> String:
	if wrecked or player == null or player.dead or player.net_puppet:
		return ""
	if player == _driver or player == _gunner or player.mounted_vehicle != null:
		return ""
	var driver_free := _driver == null
	var gunner_free := _gunner == null
	if not driver_free and not gunner_free:
		return ""
	var prefer := "driver"
	var driver_seat := get_node_or_null(^"Seat") as Node3D
	var gunner_seat := get_node_or_null(^"GunYaw/GunnerSeat") as Node3D
	if driver_seat != null and gunner_seat != null:
		var at := player.global_position
		if at.distance_squared_to(gunner_seat.global_position) < at.distance_squared_to(driver_seat.global_position):
			prefer = "gunner"
	if prefer == "driver" and driver_free:
		return "driver"
	if prefer == "gunner" and gunner_free:
		return "gunner"
	if driver_free:
		return "driver"
	return "gunner" if gunner_free else ""


## Place `who` outside. No argument drops the driver, matching the one-seat call.
func exit_vehicle(who: Player = null) -> void:
	if who == null:
		who = _driver
	_release_occupant(who, true)


## Drop the mount without moving the player (respawn / death already place them).
## No argument drops both seats.
func force_exit(who: Player = null) -> void:
	if who == null:
		_release_occupant(_driver, false)
		_release_occupant(_gunner, false)
		return
	_release_occupant(who, false)


func take_damage(amount: float, info: Dictionary) -> void:
	if wrecked or amount <= 0.0:
		return
	hull -= amount
	if hull <= 0.0:
		_wreck(info)


## One minigun round along the barrel, from the muzzle marker toward its -Z.
func fire_once() -> Dictionary:
	var muzzle := get_node(^"GunYaw/GunPitch/Muzzle") as Node3D
	var origin := muzzle.global_position
	var direction := -muzzle.global_transform.basis.z
	var to := origin + direction * ROUND_RANGE
	var query := PhysicsRayQueryParameters3D.create(origin, to, HIT_MASK)
	query.collide_with_areas = true
	var skip := _shot_excludes()
	query.exclude = skip
	var space := get_world_3d().direct_space_state
	var hit: Dictionary = {}
	for _i in 8:
		hit = space.intersect_ray(query)
		if hit.is_empty():
			break
		var collider := hit.collider as Node
		var area := hit.collider as Area3D
		var passthrough := collider != null and collider.is_in_group(Weapon.PASSTHROUGH_GROUP)
		var ignored_area := area != null and (area.collision_layer & (1 << 5)) == 0
		if not passthrough and not ignored_area:
			break
		skip.append(hit.rid)
		query.exclude = skip
	var end := to
	if not hit.is_empty():
		end = hit.position
		_apply_hit(hit, direction)
	_show_tracer(origin, end)
	return hit


func _drive(delta: float) -> void:
	var throttle := (
		Input.get_action_strength("action_move_forward")
		- Input.get_action_strength("action_move_back")
	)
	var steer := (
		Input.get_action_strength("action_move_right")
		- Input.get_action_strength("action_move_left")
	)
	var target := 0.0
	if throttle > 0.0:
		target = throttle * MAX_SPEED
	elif throttle < 0.0:
		target = throttle * REVERSE_SPEED
	var rate := ACCEL
	if absf(target) < absf(_speed) or target * _speed < 0.0:
		rate = BRAKE
	_speed = move_toward(_speed, target, rate * delta)
	var speed_scale := clampf(absf(_speed) / 3.0, 0.2, 1.0)
	speed_scale *= 1.0 - 0.4 * clampf(absf(_speed) / MAX_SPEED, 0.0, 1.0)
	rotation.y -= steer * STEER_RATE * speed_scale * delta


func _aim_gun(delta: float) -> void:
	var firing := Input.is_action_pressed("action_fire")
	if firing:
		_trigger = minf(_trigger + delta, SPINUP)
		_spin = move_toward(_spin, 30.0, 80.0 * delta)
	else:
		_trigger = 0.0
		_spin = move_toward(_spin, 0.0, 40.0 * delta)
	_barrels.rotate_z(_spin * delta)
	if _trigger < SPINUP:
		_cooldown = 0.0
		return
	_cooldown -= delta
	while _cooldown <= 0.0:
		_cooldown += FIRE_INTERVAL
		fire_once()
		_shot_skips += 1
		if _shot.stream != null and _shot_skips % 4 == 0:
			_shot.play()


func _apply_hit(hit: Dictionary, direction: Vector3) -> void:
	var collider := hit.collider as Node
	var node: Node = collider
	while node != null and not node.has_method(&"take_damage"):
		node = node.get_parent()
	if node == null or node == self:
		return
	var zone := 1.0
	if collider != null and collider.is_in_group("hitbox_head_unarmored"):
		zone = 2.0
	elif collider != null and (
		collider.is_in_group("hitbox_head_armored") or collider.is_in_group("hitbox_head")
	):
		zone = 1.5
	var info := {
		"position": hit.position,
		"normal": hit.normal,
		"direction": direction,
		"dir": direction,
		"source": _gunner if _gunner != null else self,
		"zone_multiplier": zone,
		"weapon": "minigun",
	}
	node.call(&"take_damage", ROUND_DAMAGE, info)


func _shot_excludes() -> Array[RID]:
	var skip: Array[RID] = [get_rid()]
	for who in [_driver, _gunner]:
		if who == null:
			continue
		for body in who.get_own_colliders():
			skip.append(body.get_rid())
	return skip


func _show_tracer(origin: Vector3, end: Vector3) -> void:
	var span := end - origin
	var length := span.length()
	if length < 0.05:
		_tracer.visible = false
		return
	_tracer.visible = true
	_tracer.global_position = origin + span * 0.5
	_tracer.look_at(end, Vector3.UP)
	_tracer.scale = Vector3(1.0, 1.0, length)


func _wreck(_info: Dictionary) -> void:
	wrecked = true
	hull = 0.0
	var driver := _driver
	var gunner := _gunner
	_release_occupant(driver, true)
	_release_occupant(gunner, true)
	for who in [driver, gunner]:
		if who != null and is_instance_valid(who) and not who.dead:
			who.take_damage(80.0, {"source": self, "direction": Vector3.UP, "dir": Vector3.UP, "bleedthrough": true})
	var visual := get_node(^"Visual") as Node3D
	for child in visual.find_children("", "MeshInstance3D", true, false):
		var mesh_node := child as MeshInstance3D
		if mesh_node.material_override == null:
			continue
		var copy := mesh_node.material_override.duplicate() as StandardMaterial3D
		copy.albedo_color = copy.albedo_color.darkened(0.65)
		mesh_node.material_override = copy
	_prompt.visible = false


func _release_occupant(who: Player, place: bool) -> void:
	if who == null or (who != _driver and who != _gunner):
		return
	var was_gunner := who == _gunner
	if who.died.is_connected(_on_occupant_died):
		who.died.disconnect(_on_occupant_died)
	var mask := int(_saved_masks.get(who, 1 | 4))
	_saved_masks.erase(who)
	if who == _driver:
		_driver = null
		_driver_yaw = 0.0
		_driver_pitch = 0.0
	else:
		_gunner = null
		_trigger = 0.0
	if _view == who:
		_view = _driver if _driver != null else _gunner
	who.mounted_vehicle = null
	who.collision_mask = mask
	if not who.net_puppet:
		PlayerColor.set_first_person_hidden(who, true)
	if place and is_instance_valid(who):
		var exit_point := get_node(^"GunnerExit" if was_gunner else ^"ExitPoint") as Node3D
		who.global_transform = exit_point.global_transform
		who.velocity = Vector3.ZERO
		_sync_colliders(who)
	if who.camera != null:
		who.camera.current = _view == null
	# The physics body can still be at the seat for the hull's next move.
	for body in who.get_own_colliders():
		if not _held_out.has(body):
			_held_out.append(body)
	_held_until = Engine.get_physics_frames() + 2
	_refresh_presence()


func _snap_driver() -> void:
	if _driver == null:
		return
	var seat := get_node(^"Seat") as Node3D
	# Seat basis, then a world-up yaw, so a ramp tilt stays and look-left is still
	# counter-clockwise from above. Head pitch is the driver's, not the gun's.
	var basis := seat.global_transform.basis.rotated(Vector3.UP, _driver_yaw)
	_driver.global_transform = Transform3D(basis, seat.global_position)
	_driver.head.rotation.x = _driver_pitch
	_driver.velocity = Vector3.ZERO
	_sync_colliders(_driver)


func _snap_gunner() -> void:
	if _gunner == null:
		return
	var seat := get_node(^"GunYaw/GunnerSeat") as Node3D
	_gunner.global_transform = seat.global_transform
	_gunner.head.rotation.x = 0.0
	_gunner.velocity = Vector3.ZERO
	_sync_colliders(_gunner)


func _sync_colliders(who: Player) -> void:
	for body in who.get_own_colliders():
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)
		PhysicsServer3D.body_set_state(body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)


## Gun camera only while the gunner is the one looking. The other body is drawn.
func _refresh_presence() -> void:
	if _view != null and _view != _driver and _view != _gunner:
		_view = null
	if _view == null:
		_view = _driver if _driver != null else _gunner
	var gun_view := _view == _gunner and _gunner != null
	if _gun_camera != null:
		_gun_camera.current = gun_view
		if gun_view and _gunner.camera != null:
			_gun_camera.cull_mask = _gunner.camera.cull_mask
	if _driver != null and _driver.camera != null:
		_driver.camera.current = _view == _driver
		PlayerColor.set_first_person_hidden(_driver, _view == _driver)
	if _gunner != null and _gunner.camera != null:
		_gunner.camera.current = false
		PlayerColor.set_first_person_hidden(_gunner, gun_view)


func _drop_held_out() -> void:
	if _held_out.is_empty() or Engine.get_physics_frames() < _held_until:
		return
	for body in _held_out:
		if is_instance_valid(body):
			remove_collision_exception_with(body)
	_held_out.clear()


func _on_occupant_died(player: Node, _killer: Variant, _info: Dictionary) -> void:
	_release_occupant(player as Player, false)


func _on_body_entered(body: Node3D) -> void:
	var player := body as Player
	if player != null and not _overlapping.has(player):
		_overlapping.append(player)


func _on_body_exited(body: Node3D) -> void:
	var player := body as Player
	if player != null:
		_overlapping.erase(player)


func _boarder() -> Player:
	var best: Player = null
	var best_d := INF
	for body in _overlapping:
		if not is_instance_valid(body) or body.dead:
			continue
		if body == _driver or body == _gunner or body.mounted_vehicle != null:
			continue
		var dist := body.global_position.distance_squared_to(global_position)
		if dist < best_d:
			best = body
			best_d = dist
	return best


func _update_prompt() -> void:
	var i := _overlapping.size() - 1
	while i >= 0:
		if not is_instance_valid(_overlapping[i]):
			_overlapping.remove_at(i)
		i -= 1
	var seat := ""
	var boarder := _boarder()
	if boarder != null:
		seat = seat_for(boarder)
	_prompt.visible = seat != ""
	if seat == "driver":
		_prompt.text = "E  DRIVE"
	elif seat == "gunner":
		_prompt.text = "E  GUN"


## High speed only. The face in the direction of travel kills; a side contact breaks shields.
func _splatter() -> void:
	if wrecked or absf(_speed) < SPLATTER_SPEED:
		return
	var travel := _planar_forward()
	if _speed < 0.0:
		travel = -travel
	var kills: Array[Node] = []
	var glances: Array[Node] = []
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		var victim := _character_hit(hit.get_collider() as Node)
		if victim == null:
			continue
		if _is_head_on(travel, victim as Node3D):
			if not kills.has(victim):
				kills.append(victim)
		elif not glances.has(victim):
			glances.append(victim)
	for victim in kills:
		_run_over(victim, travel)
	for victim in glances:
		if not kills.has(victim):
			_strip_shield(victim, travel)


func _is_head_on(travel: Vector3, victim: Node3D) -> bool:
	# In the lane and in front of the bumper: the front runs them over. Outside that
	# width the flank only clips them, even when the corner normal points partly back.
	var to_victim := victim.global_position - global_position
	to_victim.y = 0.0
	var ahead := to_victim.dot(travel)
	var lateral := absf(to_victim.dot(travel.cross(Vector3.UP)))
	return ahead >= HEAD_ON_AHEAD and lateral <= HEAD_ON_LATERAL


func _character_hit(node: Node) -> Node:
	var current := node
	while current != null:
		if current == self:
			return null
		if (current is Player or current is Bot) and current != _driver and current != _gunner and current.get("dead") != true:
			return current
		current = current.get_parent()
	return null


func _run_over(victim: Node, travel: Vector3) -> void:
	victim.call(&"take_damage", 10000.0, _impact_info(travel, true))


func _strip_shield(victim: Node, travel: Vector3) -> void:
	var hs: Node = victim.get(&"health_shield") as Node
	if hs == null or float(hs.get(&"shield")) <= 0.0:
		return
	victim.call(&"take_damage", float(hs.get(&"shield")), _impact_info(travel, false))


func _impact_info(travel: Vector3, bleed: bool) -> Dictionary:
	return {
		"source": _driver if _driver != null else self,
		"direction": travel,
		"dir": travel,
		"bleedthrough": bleed,
		"weapon": "humvee",
	}


func _planar_forward() -> Vector3:
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3(0.0, 0.0, -1.0)
	return fwd.normalized()


func _build() -> void:
	var visual := Node3D.new()
	visual.name = "Visual"
	add_child(visual)
	var olive := Color(0.33, 0.36, 0.27)
	var dark := Color(0.14, 0.15, 0.13)
	var metal := Color(0.28, 0.3, 0.32)
	# Chassis sits on the wheels. Cabin is open: sides and a windshield, no roof.
	_box(visual, "Chassis", Vector3(0.0, 0.62, 0.05), Vector3(1.7, 0.38, 3.5), olive)
	_box(visual, "Hood", Vector3(0.0, 0.95, -1.35), Vector3(1.65, 0.22, 1.25), olive)
	_box(visual, "Bed", Vector3(0.0, 0.78, 1.45), Vector3(1.7, 0.16, 1.15), dark)
	_box(visual, "Bumper", Vector3(0.0, 0.55, -2.15), Vector3(1.9, 0.22, 0.18), dark)
	_box(visual, "SillL", Vector3(-0.95, 1.05, 0.15), Vector3(0.1, 0.48, 2.15), olive)
	_box(visual, "SillR", Vector3(0.95, 1.05, 0.15), Vector3(0.1, 0.48, 2.15), olive)
	_box(visual, "Tailgate", Vector3(0.0, 1.05, 1.95), Vector3(1.7, 0.42, 0.08), olive)
	_box(visual, "Glass", Vector3(0.0, 1.48, -0.78), Vector3(1.5, 0.42, 0.04), Color(0.55, 0.72, 0.78, 0.4))
	_box(visual, "PillarL", Vector3(-0.78, 1.42, -0.78), Vector3(0.08, 0.55, 0.08), dark)
	_box(visual, "PillarR", Vector3(0.78, 1.42, -0.78), Vector3(0.08, 0.55, 0.08), dark)
	# Roll cage over the open cabin.
	_box(visual, "CageFL", Vector3(-0.82, 1.55, -0.45), Vector3(0.07, 0.9, 0.07), dark)
	_box(visual, "CageFR", Vector3(0.82, 1.55, -0.45), Vector3(0.07, 0.9, 0.07), dark)
	_box(visual, "CageRL", Vector3(-0.82, 1.55, 0.95), Vector3(0.07, 0.9, 0.07), dark)
	_box(visual, "CageRR", Vector3(0.82, 1.55, 0.95), Vector3(0.07, 0.9, 0.07), dark)
	_box(visual, "CageTopL", Vector3(-0.82, 2.0, 0.25), Vector3(0.07, 0.07, 1.5), dark)
	_box(visual, "CageTopR", Vector3(0.82, 2.0, 0.25), Vector3(0.07, 0.07, 1.5), dark)
	_box(visual, "CageTopF", Vector3(0.0, 2.0, -0.45), Vector3(1.7, 0.07, 0.07), dark)
	_box(visual, "CageTopB", Vector3(0.0, 2.0, 0.95), Vector3(1.7, 0.07, 0.07), dark)
	_wheel(visual, "WheelFL", Vector3(-0.98, 0.42, -1.35))
	_wheel(visual, "WheelFR", Vector3(0.98, 0.42, -1.35))
	_wheel(visual, "WheelRL", Vector3(-0.98, 0.42, 1.4))
	_wheel(visual, "WheelRR", Vector3(0.98, 0.42, 1.4))
	# Ring and minigun. Barrels point -Z. Muzzle is ahead of Breech on that axis.
	var ring := CylinderMesh.new()
	ring.top_radius = 0.58
	ring.bottom_radius = 0.58
	ring.height = 0.06
	var ring_node := MeshInstance3D.new()
	ring_node.name = "GunRing"
	ring_node.mesh = ring
	ring_node.position = Vector3(0.0, 1.78, 0.4)
	ring_node.material_override = _mat(metal)
	visual.add_child(ring_node)
	var gun_yaw := Node3D.new()
	gun_yaw.name = "GunYaw"
	gun_yaw.position = Vector3(0.0, 1.86, 0.4)
	add_child(gun_yaw)
	var gun_pitch := Node3D.new()
	gun_pitch.name = "GunPitch"
	gun_yaw.add_child(gun_pitch)
	_box(gun_pitch, "Receiver", Vector3(0.0, 0.0, -0.05), Vector3(0.16, 0.14, 0.42), metal)
	_box(gun_pitch, "AmmoBox", Vector3(-0.2, -0.02, 0.05), Vector3(0.22, 0.18, 0.32), dark)
	var barrels := Node3D.new()
	barrels.name = "Barrels"
	barrels.position = Vector3(0.0, 0.02, -0.25)
	gun_pitch.add_child(barrels)
	for i in 6:
		var angle := float(i) * TAU / 6.0
		var barrel := CylinderMesh.new()
		barrel.top_radius = 0.018
		barrel.bottom_radius = 0.018
		barrel.height = 0.85
		var barrel_node := MeshInstance3D.new()
		barrel_node.mesh = barrel
		barrel_node.position = Vector3(cos(angle) * 0.05, sin(angle) * 0.05, -0.42)
		barrel_node.rotation.x = -PI * 0.5
		barrel_node.material_override = _mat(metal)
		barrels.add_child(barrel_node)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 0.22, 0.55)
	camera.fov = 75.0
	camera.near = 0.15
	camera.far = 600.0
	camera.current = false
	camera.cull_mask &= ~(1 << 1)
	gun_pitch.add_child(camera)
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.02, -1.15)
	gun_pitch.add_child(muzzle)
	var breech := Marker3D.new()
	breech.name = "Breech"
	breech.position = Vector3(0.0, 0.02, -0.15)
	gun_pitch.add_child(breech)
	var seat := Marker3D.new()
	seat.name = "Seat"
	# Driver sits left (-X). Origin is the feet, so the eye (Player head) clears the cage.
	seat.position = Vector3(-0.42, 0.15, 0.15)
	add_child(seat)
	var gunner_seat := Marker3D.new()
	gunner_seat.name = "GunnerSeat"
	# Child of GunYaw: identity faces the gun's -Z. Feet sit behind the ring
	# (GunYaw is at y=1.86, z=0.4, so this is hull (0, 0.15, 0.85) at gun yaw 0).
	gunner_seat.position = Vector3(0.0, -1.71, 0.45)
	gun_yaw.add_child(gunner_seat)
	var exit_point := Marker3D.new()
	exit_point.name = "ExitPoint"
	exit_point.position = Vector3(1.85, 0.05, 0.3)
	add_child(exit_point)
	var gunner_exit := Marker3D.new()
	gunner_exit.name = "GunnerExit"
	gunner_exit.position = Vector3(-1.85, 0.05, 0.85)
	add_child(gunner_exit)
	# Skis at 30° so a ramp contact stays under floor_max_angle (50°). A vertical
	# nose reports a wall normal and stops on Headlong's slopes.
	var hull_shape := CollisionShape3D.new()
	var wedge := ConvexPolygonShape3D.new()
	var half_x := 1.08
	wedge.points = PackedVector3Array([
		Vector3(-half_x, 0.0, -1.4), Vector3(half_x, 0.0, -1.4),
		Vector3(-half_x, 0.0, 1.4), Vector3(half_x, 0.0, 1.4),
		Vector3(-half_x, 0.55, -2.35), Vector3(half_x, 0.55, -2.35),
		Vector3(-half_x, 0.55, 2.3), Vector3(half_x, 0.55, 2.3),
		Vector3(-half_x, 1.05, -2.15), Vector3(half_x, 1.05, -2.15),
		Vector3(-half_x, 1.05, 2.1), Vector3(half_x, 1.05, 2.1),
	])
	hull_shape.shape = wedge
	add_child(hull_shape)
	var area := Area3D.new()
	area.name = "Interact"
	area.collision_layer = 0
	area.collision_mask = 2
	var area_shape := CollisionShape3D.new()
	var area_box := BoxShape3D.new()
	area_box.size = Vector3(3.6, 2.6, 6.4)
	area_shape.shape = area_box
	area_shape.position = Vector3(0.0, 1.2, 0.05)
	area.add_child(area_shape)
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	add_child(area)
	var prompt := Label3D.new()
	prompt.name = "Prompt"
	prompt.text = "E"
	prompt.font_size = 72
	prompt.position = Vector3(0.0, 2.75, 0.2)
	prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	prompt.modulate = Color(0.9, 0.92, 0.75)
	prompt.outline_size = 8
	prompt.no_depth_test = true
	prompt.visible = false
	add_child(prompt)
	var tracer := MeshInstance3D.new()
	tracer.name = "Tracer"
	var tracer_mesh := BoxMesh.new()
	tracer_mesh.size = Vector3(0.025, 0.025, 1.0)
	tracer.mesh = tracer_mesh
	tracer.material_override = _mat(Color(1.0, 0.82, 0.35))
	tracer.visible = false
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tracer)
	var shot := AudioStreamPlayer3D.new()
	shot.name = "Shot"
	shot.unit_size = 8.0
	add_child(shot)


func _box(parent: Node3D, node_name: String, at: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = at
	node.material_override = _mat(color)
	parent.add_child(node)


func _wheel(parent: Node3D, node_name: String, at: Vector3) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.42
	mesh.bottom_radius = 0.42
	mesh.height = 0.3
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = at
	node.rotation.z = PI * 0.5
	node.material_override = _mat(Color(0.07, 0.07, 0.07))
	parent.add_child(node)


func _mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82
	if color.a < 0.99:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat
