extends SceneTree
## Open-top humvee: -Z is forward, steer-right turns toward +X, the minigun
## hits what the barrel points at, and exiting leaves the driver beside it.
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/humvee_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(80.0, 1.0, 80.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -0.5, 0.0)
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)

	var humvee: Node3D = (load("res://scenes/vehicles/humvee.tscn") as PackedScene).instantiate() as Node3D
	humvee.position = Vector3(0.0, 0.05, 0.0)
	root.add_child(humvee)

	var player: Node3D = (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node3D
	player.set(&"auto_respawn", false)
	player.position = Vector3(8.0, 0.1, 6.0)
	root.add_child(player)

	for _i in 5:
		await physics_frame
	_check((humvee as CharacterBody3D).is_on_floor() and absf(humvee.global_position.y) < 0.15, "hull rests on the floor, y=%s" % humvee.global_position.y)

	var muzzle: Node3D = humvee.get_node(^"GunYaw/GunPitch/Muzzle") as Node3D
	var breech: Node3D = humvee.get_node(^"GunYaw/GunPitch/Breech") as Node3D
	var barrel := muzzle.global_position - breech.global_position
	_check(barrel.z < -0.5 and absf(barrel.x) < 0.05, "barrel starts along -Z, got %s" % barrel)

	var entered: bool = humvee.call(&"enter", player)
	_check(entered, "enter")
	_check(player.call(&"is_mounted"), "driver is mounted")

	Input.action_press("action_move_forward")
	for _i in 50:
		await physics_frame
	Input.action_release("action_move_forward")
	var moved := humvee.global_position
	_check(moved.z < -1.0, "throttle moves toward -Z, z=%s" % moved.z)
	var travel := Vector3(moved.x, 0.0, moved.z).normalized()
	var fwd := -(humvee as Node3D).global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	_check(travel.dot(Vector3(0.0, 0.0, -1.0)) > 0.9, "displacement is -Z, dot=%s" % travel.dot(Vector3(0.0, 0.0, -1.0)))
	_check(fwd.dot(travel) > 0.9, "hull faces its travel, dot=%s" % fwd.dot(travel))

	for _i in 40:
		await physics_frame
	var yaw_before: float = (humvee as Node3D).rotation.y
	Input.action_press("action_move_right")
	for _i in 50:
		await physics_frame
	Input.action_release("action_move_right")
	var yaw_after: float = (humvee as Node3D).rotation.y
	var turned := -(humvee as Node3D).global_transform.basis.z
	turned.y = 0.0
	turned = turned.normalized()
	_check(yaw_after < yaw_before - 0.05, "steer right decreases yaw %s -> %s" % [yaw_before, yaw_after])
	_check(turned.x > 0.05, "steer right turns -Z toward +X, forward=%s" % turned)

	humvee.call(&"add_aim_radians", PI * 0.5, 0.0)
	barrel = muzzle.global_position - breech.global_position
	barrel.y = 0.0
	barrel = barrel.normalized()
	var hull_left := -humvee.global_transform.basis.x
	hull_left.y = 0.0
	hull_left = hull_left.normalized()
	_check(barrel.dot(hull_left) > 0.9, "gun yaw +90 aims along the hull's -X, barrel=%s left=%s" % [barrel, hull_left])
	humvee.call(&"add_aim_radians", -PI * 0.5, 0.0)
	humvee.call(&"add_aim_radians", 0.0, 0.4)
	barrel = (muzzle.global_position - breech.global_position).normalized()
	_check(barrel.y > 0.3, "positive pitch looks up, barrel=%s" % barrel)
	humvee.call(&"add_aim_radians", 0.0, -0.4)

	var aim := muzzle.global_position - breech.global_position
	aim = aim.normalized()
	var target := Target.new()
	target.collision_layer = 1
	var target_shape := CollisionShape3D.new()
	var target_box := BoxShape3D.new()
	target_box.size = Vector3(1.2, 1.2, 1.2)
	target_shape.shape = target_box
	target.add_child(target_shape)
	root.add_child(target)
	target.global_position = muzzle.global_position + aim * 6.0
	await physics_frame
	humvee.call(&"fire_once")
	await physics_frame
	_check(target.taken >= 8.0, "minigun hit the barrel target, damage=%s" % target.taken)

	humvee.call(&"exit_vehicle")
	for _i in 3:
		await physics_frame
	_check(not player.call(&"is_mounted"), "exit clears the mount")
	var exit_offset := humvee.global_transform.basis.inverse() * (player.global_position - humvee.global_position)
	_check(exit_offset.x > 1.2 and absf(humvee.global_position.y) < 0.15, "exit places the driver on local +X and the hull stays on the floor, offset=%s y=%s" % [exit_offset, humvee.global_position.y])
	_check(int(player.get(&"collision_mask")) == 5, "exit restores the player mask")

	humvee.call(&"take_damage", 10000.0, {})
	var wrecked: bool = humvee.get(&"wrecked")
	_check(wrecked, "hull destruction wrecks the humvee")
	var reentered: bool = humvee.call(&"enter", player)
	_check(not reentered, "a wreck cannot be entered")

	await _check_splatter(player)

	# 20° wedge, sharp lip, uphill toward -Z. Headlong's ramps stay under 32°.
	var ramp := StaticBody3D.new()
	ramp.collision_layer = 1
	var ramp_shape := CollisionShape3D.new()
	var wedge := ConvexPolygonShape3D.new()
	var rise := 12.0 * tan(deg_to_rad(20.0))
	wedge.points = PackedVector3Array([
		Vector3(-3.0, 0.0, 0.0), Vector3(3.0, 0.0, 0.0),
		Vector3(-3.0, 0.0, -12.0), Vector3(3.0, 0.0, -12.0),
		Vector3(-3.0, rise, -12.0), Vector3(3.0, rise, -12.0),
	])
	ramp_shape.shape = wedge
	ramp.add_child(ramp_shape)
	ramp.position = Vector3(20.0, 0.0, -2.0)
	root.add_child(ramp)
	var climber: Node3D = (load("res://scenes/vehicles/humvee.tscn") as PackedScene).instantiate() as Node3D
	climber.position = Vector3(20.0, 0.05, 2.0)
	root.add_child(climber)
	for _i in 8:
		await physics_frame
	var y0: float = climber.global_position.y
	_check(climber.call(&"enter", player), "enter the ramp truck")
	Input.action_press("action_move_forward")
	for _i in 90:
		await physics_frame
	Input.action_release("action_move_forward")
	_check(
		(climber as CharacterBody3D).is_on_floor() and climber.global_position.y > y0 + 0.6,
		"climbs a 20 degree ramp, y %s -> %s z=%s on_floor=%s" % [y0, climber.global_position.y, climber.global_position.z, (climber as CharacterBody3D).is_on_floor()]
	)

	if _failed:
		push_error("HUMVEE_SELF_TEST FAIL")
		quit(1)
		return
	print("HUMVEE_SELF_TEST PASS")
	quit(0)


func _check_splatter(driver: Node3D) -> void:
	# Far from the other trucks. Speed is set above the 10 m/s splatter gate.
	var head_truck := _truck(Vector3(-24.0, 0.05, 0.0))
	var head_victim := _victim(Vector3(-24.0, 0.1, -6.0))
	var side_truck := _truck(Vector3(-24.0, 0.05, -30.0))
	var slow_truck := _truck(Vector3(-24.0, 0.05, -50.0))
	var slow_victim := _victim(Vector3(-24.0, 0.1, -54.0))
	for _i in 5:
		await physics_frame

	_check(head_truck.call(&"enter", driver), "enter for a head-on hit")
	head_truck.set(&"_speed", 14.0)
	Input.action_press("action_move_forward")
	for _i in 40:
		await physics_frame
	Input.action_release("action_move_forward")
	head_truck.call(&"exit_vehicle")
	_check(bool(head_victim.get(&"dead")), "head-on at speed kills, dead=%s shield=%s" % [head_victim.get(&"dead"), _shield(head_victim)])

	_check(side_truck.call(&"enter", driver), "enter for a side hit")
	side_truck.set(&"_speed", 14.0)
	Input.action_press("action_move_forward")
	for _i in 3:
		await physics_frame
	# Ahead and off to the right, clear of the nose, so the flank is what arrives.
	var side_victim := _victim(
		side_truck.global_position
		+ side_truck.global_transform.basis.x * 1.35
		- side_truck.global_transform.basis.z * 3.5
	)
	for _i in 20:
		await physics_frame
	Input.action_release("action_move_forward")
	side_truck.call(&"exit_vehicle")
	var side_shield := _shield(side_victim)
	var side_health := _health(side_victim)
	_check(
		not bool(side_victim.get(&"dead")) and side_shield <= 0.0 and side_health > 40.0,
		"side hit at speed breaks shields only, dead=%s shield=%s health=%s" % [side_victim.get(&"dead"), side_shield, side_health]
	)

	var slow_shield_before := _shield(slow_victim)
	_check(slow_truck.call(&"enter", driver), "enter for a slow hit")
	slow_truck.set(&"_speed", 3.0)
	Input.action_press("action_move_forward")
	for _i in 25:
		await physics_frame
	Input.action_release("action_move_forward")
	slow_truck.call(&"exit_vehicle")
	_check(
		not bool(slow_victim.get(&"dead"))
		and is_equal_approx(_shield(slow_victim), slow_shield_before)
		and slow_truck.global_position.z < -50.6
		and slow_truck.global_position.z > -52.4,
		"a slow hit does no damage, dead=%s shield=%s truck_z=%s" % [slow_victim.get(&"dead"), _shield(slow_victim), slow_truck.global_position.z]
	)


func _truck(at: Vector3) -> Node3D:
	var body: Node3D = (load("res://scenes/vehicles/humvee.tscn") as PackedScene).instantiate() as Node3D
	body.position = at
	root.add_child(body)
	return body


func _victim(at: Vector3) -> Node3D:
	var body: Node3D = (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node3D
	body.set(&"auto_respawn", false)
	body.position = at
	root.add_child(body)
	return body


func _shield(body: Node) -> float:
	return float(body.get_node(^"HealthShield").get(&"shield"))


func _health(body: Node) -> float:
	return float(body.get_node(^"HealthShield").get(&"health"))


func _check(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)


class Target extends StaticBody3D:
	var taken: float = 0.0

	func take_damage(amount: float, _info: Dictionary) -> void:
		taken += amount
