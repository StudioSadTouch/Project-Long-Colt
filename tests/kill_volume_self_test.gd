extends SceneTree
## A fall kills once. Respawning onto a floor outside the volume must not kill again.
## A later fall of that new life must kill once. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/kill_volume_self_test.gd

var _deaths: int = 0
var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(30, 5, 0)
	floor_body.collision_layer = 1
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(20, 1, 20)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)

	var volume := Area3D.new()
	volume.position = Vector3(0, -10, 0)
	volume.collision_layer = 16
	volume.collision_mask = 6
	volume.monitorable = false
	volume.set_script(load("res://scripts/levels/kill_volume.gd"))
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 2, 200)
	shape.shape = box
	volume.add_child(shape)
	root.add_child(volume)

	var player: Node = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	player.set(&"auto_respawn", false)
	player.position = Vector3(0, 12, 0)
	root.add_child(player)
	player.connect(&"died", _on_died)

	var fell := false
	for _i in 200:
		await physics_frame
		if bool(player.call(&"is_dead")):
			fell = true
			break
	_expect(fell and _deaths == 1, "first fall deaths=%d" % _deaths)
	print("[test] after fall frame ", Engine.get_physics_frames(), " y ", player.position.y, " deaths ", _deaths)

	# Deferred collision disable flushes over the next idle frames. Respawn after that,
	# the way SpawnManager does a few seconds later, onto the floor (top at y=5.5).
	for _i in 5:
		await physics_frame
	var deaths_at_respawn := _deaths
	player.call(&"respawn_at", Transform3D(Basis(), Vector3(30, 5.5, 0)))
	print(
		"[test] respawned frame ", Engine.get_physics_frames(),
		" dead ", player.call(&"is_dead"),
		" y ", player.position.y,
		" deaths ", _deaths
	)
	for _i in 20:
		await physics_frame
		if _deaths != deaths_at_respawn:
			print(
				"[test] extra death frame ", Engine.get_physics_frames(),
				" y ", player.position.y,
				" dead ", player.call(&"is_dead")
			)
			break
	_expect(_deaths == deaths_at_respawn, "safe respawn deaths=%d" % _deaths)
	_expect(not bool(player.call(&"is_dead")), "alive after safe respawn")
	_expect(player.position.y > 5.0, "stood on the spawn floor y=%s" % player.position.y)

	# A new life placed in the slab still dies. The next safe respawn must not chain.
	player.call(&"respawn_at", Transform3D(Basis(), Vector3(0, -10, 0)))
	for _i in 10:
		await physics_frame
		if _deaths != deaths_at_respawn:
			break
	_expect(_deaths == deaths_at_respawn + 1, "respawn inside the volume deaths=%d" % _deaths)
	deaths_at_respawn = _deaths
	# Let the death's deferred collision disable flush before the next respawn.
	for _i in 5:
		await physics_frame
	player.call(&"respawn_at", Transform3D(Basis(), Vector3(30, 5.5, 0)))
	for _i in 20:
		await physics_frame
	_expect(_deaths == deaths_at_respawn, "respawn after a pit death deaths=%d" % _deaths)
	_expect(not bool(player.call(&"is_dead")), "alive after leaving the pit")

	# New life can still die by falling in.
	player.position = Vector3(0, 12, 0)
	player.set(&"velocity", Vector3.ZERO)
	for _i in 200:
		await physics_frame
		if bool(player.call(&"is_dead")):
			break
	_expect(_deaths == deaths_at_respawn + 1, "second fall deaths=%d" % _deaths)

	if _failed:
		quit(1)
		return
	print("KILL_VOLUME_SELF_TEST PASS")
	quit(0)


func _on_died(_a: Variant, _b: Variant, _c: Variant) -> void:
	_deaths += 1
	print("[test] died #", _deaths, " frame ", Engine.get_physics_frames())


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)
