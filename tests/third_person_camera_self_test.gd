extends SceneTree
## ThirdPersonCamera checks: takes the view only when enabled, sits behind the chosen shoulder,
## converges on what the eye ray hits, pulls in at walls, hides the viewmodel, goes back to
## first person while zoomed and when turned off. Never saves settings. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/third_person_camera_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_camera()
	if _failed:
		quit(1)
		return
	print("THIRD_PERSON_CAMERA_SELF_TEST PASS")
	quit(0)


func _test_camera() -> void:
	var floor_body := _box(Vector3(0, -0.5, 0), Vector3(80, 1, 80))
	# A wall 20 m ahead (the player faces -Z) for the convergence check.
	var target_wall := _box(Vector3(0, 2, -20), Vector3(20, 6, 1))
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 0)
	root.add_child(player)
	var view := player.get_node("ThirdPersonCamera") as ThirdPersonCamera
	var holder := player.get_weapon_holder()
	view.enabled = false
	view.left_shoulder = false
	await _frames(10)
	_expect(view != null and player.camera.current, "off: first-person camera is live")
	_expect(not view.is_active(), "off: third-person view is not live")

	view.enabled = true
	await _frames(40)
	_expect(view.is_active(), "on: third-person view is live")
	_expect(not holder.visible, "on: viewmodel hidden")
	var eye := player.camera.global_position
	var local := player.global_transform.affine_inverse() * view.camera.global_position
	_expect(local.x > 0.4, "right shoulder: camera to the right (x %.2f)" % local.x)
	_expect(local.z > 1.8, "camera behind the eyes (z %.2f)" % local.z)
	_expect(
		view.camera.cull_mask & Player.HIDDEN_BODY_LAYER != 0, "own body drawn in third person"
	)
	# Crosshair (screen centre) lands where the eye ray lands: on the wall at z = -19.5.
	var cam := view.camera.global_transform
	var ray_dir := -cam.basis.z
	var t := (-19.5 - cam.origin.z) / ray_dir.z
	var screen_hit := cam.origin + ray_dir * t
	var eye_hit := Vector3(eye.x, eye.y, -19.5)
	_expect(
		screen_hit.distance_to(eye_hit) < 0.15,
		"crosshair converges on the eye-ray hit (off by %.3f m)" % screen_hit.distance_to(eye_hit)
	)

	view.left_shoulder = true
	await _frames(60)
	local = player.global_transform.affine_inverse() * view.camera.global_position
	_expect(local.x < -0.4, "left shoulder: camera to the left (x %.2f)" % local.x)

	# A wall right behind: the camera comes in front of it.
	var back_wall := _box(Vector3(0, 2, 1.2), Vector3(20, 6, 0.4))
	await _frames(5)
	local = player.global_transform.affine_inverse() * view.camera.global_position
	_expect(local.z < 0.9, "wall behind pulls the camera in (z %.2f)" % local.z)
	back_wall.queue_free()
	await _frames(90)
	local = player.global_transform.affine_inverse() * view.camera.global_position
	_expect(local.z > 1.8, "camera eases back out after the wall (z %.2f)" % local.z)

	# Shots draw a tracer from the third-person gun.
	var before := _count_meshes()
	holder.get_active().ray_fired.emit(eye, eye + Vector3(0, 0, -19), {})
	await _frames(1)
	_expect(_count_meshes() > before, "third-person shot draws a tracer")

	# Zoom: back to first person (scopes), then third person again.
	var weapon := holder.get_active()
	weapon.zoomed = true
	await _frames(3)
	_expect(player.camera.current and holder.visible, "zoomed: first person with viewmodel")
	weapon.zoomed = false
	await _frames(3)
	_expect(view.is_active() and not holder.visible, "unzoomed: third person again")

	view.enabled = false
	await _frames(3)
	_expect(player.camera.current and holder.visible, "off again: first person with viewmodel")
	player.queue_free()
	floor_body.queue_free()
	target_wall.queue_free()
	await process_frame


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


func _count_meshes() -> int:
	var n := 0
	for child in root.get_children():
		if child is MeshInstance3D:
			n += 1
	return n


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)
