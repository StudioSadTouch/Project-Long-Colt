extends SceneTree
## Open-top humvee: -Z is forward, steer-right turns toward +X, the minigun
## hits what the barrel points at, the driver and gunner take different seats,
## and each exits on their own side.
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

	await _check_seats(humvee, player)

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


func _check_seats(humvee: Node3D, driver: Node3D) -> void:
	humvee.set(&"_speed", 0.0)
	(humvee as CharacterBody3D).velocity = Vector3.ZERO
	var gun_yaw := humvee.get_node(^"GunYaw") as Node3D
	var gun_pitch := humvee.get_node(^"GunYaw/GunPitch") as Node3D
	gun_yaw.rotation = Vector3.ZERO
	gun_pitch.rotation = Vector3.ZERO
	var driver_seat := humvee.get_node(^"Seat") as Node3D
	var gunner_seat := humvee.get_node(^"GunYaw/GunnerSeat") as Node3D
	var chooser := _victim(driver_seat.global_position - humvee.global_transform.basis.x * 2.0)
	for _i in 2:
		await physics_frame
	_check(str(humvee.call(&"seat_for", chooser)) == "driver", "the cab side offers the driver seat")
	chooser.global_position = gunner_seat.global_position + humvee.global_transform.basis.z * 2.0
	await physics_frame
	_check(str(humvee.call(&"seat_for", chooser)) == "gunner", "the bed side offers the gunner seat")
	chooser.queue_free()

	_check(humvee.call(&"enter", driver), "driver seat again")
	var gun_cam := humvee.get_node(^"GunYaw/GunPitch/Camera3D") as Camera3D
	_check(driver.get_node(^"Head/Camera3D").current and not gun_cam.current, "driver keeps their own camera")
	var driver_local := _hull_offset(humvee, driver)
	_check(driver_local.x < -0.2, "driver sits on the hull's left, offset=%s" % driver_local)
	var driver_fwd := -(driver as Node3D).global_transform.basis.z
	driver_fwd.y = 0.0
	var hull_fwd := -humvee.global_transform.basis.z
	hull_fwd.y = 0.0
	_check(driver_fwd.normalized().dot(hull_fwd.normalized()) > 0.9, "driver faces the hood")

	var muzzle := humvee.get_node(^"GunYaw/GunPitch/Muzzle") as Node3D
	var breech := humvee.get_node(^"GunYaw/GunPitch/Breech") as Node3D
	var aim := (muzzle.global_position - breech.global_position).normalized()
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
	Input.action_press("action_fire")
	for _i in 30:
		await physics_frame
	Input.action_release("action_fire")
	_check(
		target.taken == 0.0 and float(humvee.get(&"_trigger")) == 0.0,
		"the driver does not fire the minigun, damage=%s" % target.taken
	)

	var gun_yaw_before: float = gun_yaw.rotation.y
	humvee.call(&"add_look", driver, Vector2(-200.0, 0.0), 0.01)
	await physics_frame
	var looked := -(driver as Node3D).global_transform.basis.z
	looked.y = 0.0
	var hull_left := -humvee.global_transform.basis.x
	hull_left.y = 0.0
	_check(looked.normalized().dot(hull_left.normalized()) > 0.5, "driver look-left turns toward the hull's -X, forward=%s" % looked)
	_check(is_equal_approx(gun_yaw.rotation.y, gun_yaw_before), "driver look does not turn the gun")

	var gunner := _victim(Vector3(30.0, 0.1, 24.0))
	_check(humvee.call(&"enter", gunner, "gunner"), "gunner seat")
	_check(gunner.call(&"is_mounted") and driver.call(&"is_mounted"), "both seats filled")
	_check(driver.get_node(^"Head/Camera3D").current and not gun_cam.current, "a gunner does not steal the driver's camera")
	var gunner_local := _hull_offset(humvee, gunner)
	_check(gunner_local.z > driver_local.z + 0.3, "gunner sits behind the driver, gunner=%s driver=%s" % [gunner_local, driver_local])
	var gunner_fwd := -(gunner as Node3D).global_transform.basis.z
	gunner_fwd.y = 0.0
	var barrel := muzzle.global_position - breech.global_position
	barrel.y = 0.0
	_check(gunner_fwd.normalized().dot(barrel.normalized()) > 0.9, "gunner faces the barrel")
	var third := _victim(Vector3(32.0, 0.1, 24.0))
	_check(not humvee.call(&"enter", third), "both seats full")
	third.queue_free()

	var spun: float = gun_yaw.rotation.y
	humvee.call(&"add_look", gunner, Vector2(-100.0, 0.0), 0.01)
	_check(gun_yaw.rotation.y > spun + 0.5, "gunner look turns the gun %s -> %s" % [spun, gun_yaw.rotation.y])
	gun_yaw.rotation = Vector3.ZERO
	gun_pitch.rotation = Vector3.ZERO
	# The settled hull can point a level barrel into the floor. Aim up, the way a gunner would.
	humvee.call(&"add_aim_radians", 0.0, 0.35)
	target.queue_free()
	await physics_frame
	var gun_target := Target.new()
	gun_target.name = "GunTarget"
	gun_target.collision_layer = 1
	var gun_shape := CollisionShape3D.new()
	var gun_box := BoxShape3D.new()
	gun_box.size = Vector3(1.2, 1.2, 1.2)
	gun_shape.shape = gun_box
	gun_target.add_child(gun_shape)
	root.add_child(gun_target)
	var ray := -muzzle.global_transform.basis.z
	gun_target.global_position = muzzle.global_position + ray * 6.0
	await physics_frame
	var shot: Dictionary = humvee.call(&"fire_once")
	var hit_name := ""
	if shot.get("collider") is Node:
		hit_name = str((shot.get("collider") as Node).name)
	_check(
		gun_target.taken >= 8.0,
		"the gunner's barrel hits, damage=%s hit=%s ray=%s" % [gun_target.taken, hit_name, ray]
	)
	Input.action_press("action_fire")
	for _i in 24:
		await physics_frame
	Input.action_release("action_fire")
	_check(float(humvee.get(&"_trigger")) >= 0.28, "the gunner spins the minigun up, trigger=%s" % humvee.get(&"_trigger"))
	target = gun_target

	var before := humvee.global_position
	Input.action_press("action_move_forward")
	for _i in 20:
		await physics_frame
	Input.action_release("action_move_forward")
	var moved := humvee.global_position - before
	var fwd := -humvee.global_transform.basis.z
	fwd.y = 0.0
	_check(moved.dot(fwd.normalized()) > 0.2, "the driver still drives with a gunner aboard, moved=%s" % moved)

	humvee.call(&"exit_vehicle")
	for _i in 3:
		await physics_frame
	_check(not driver.call(&"is_mounted") and gunner.call(&"is_mounted"), "the driver can leave the gunner aboard")
	_check(gun_cam.current, "the gunner takes the view when the driver leaves")
	var driver_exit := _hull_offset(humvee, driver)
	_check(driver_exit.x > 1.2, "driver still exits on local +X, offset=%s" % driver_exit)

	humvee.call(&"exit_vehicle", gunner)
	for _i in 3:
		await physics_frame
	var gunner_exit := _hull_offset(humvee, gunner)
	_check(not gunner.call(&"is_mounted") and gunner_exit.x < -1.2, "gunner exits on local -X, offset=%s" % gunner_exit)
	gunner.queue_free()
	target.queue_free()

	var wrecker := _truck(Vector3(36.0, 0.05, 24.0))
	var wreck_driver := _victim(Vector3(36.0, 0.1, 30.0))
	var wreck_gunner := _victim(Vector3(36.0, 0.1, 32.0))
	for _i in 4:
		await physics_frame
	_check(wrecker.call(&"enter", wreck_driver), "wreck truck driver")
	_check(wrecker.call(&"enter", wreck_gunner, "gunner"), "wreck truck gunner")
	wrecker.call(&"take_damage", 10000.0, {})
	_check(
		bool(wrecker.get(&"wrecked")) and not wreck_driver.call(&"is_mounted") and not wreck_gunner.call(&"is_mounted"),
		"a wreck ejects the driver and the gunner"
	)
	_check(
		not bool(wreck_driver.get(&"dead")) and _shield(wreck_driver) <= 0.0 and _health(wreck_driver) < 40.0
		and not bool(wreck_gunner.get(&"dead")) and _shield(wreck_gunner) <= 0.0 and _health(wreck_gunner) < 40.0,
		"both take the wreck hit, driver shield=%s health=%s gunner shield=%s health=%s" % [
			_shield(wreck_driver), _health(wreck_driver), _shield(wreck_gunner), _health(wreck_gunner)
		]
	)
	wreck_driver.queue_free()
	wreck_gunner.queue_free()


func _hull_offset(humvee: Node3D, who: Node3D) -> Vector3:
	return humvee.global_transform.basis.inverse() * (who.global_position - humvee.global_position)


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
