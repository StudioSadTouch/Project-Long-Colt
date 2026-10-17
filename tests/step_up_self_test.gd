extends SceneTree
## Step-up must climb lips the capsule would otherwise catch on, and must not mount a wall.
## Run: flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/step_up_self_test.gd

const SPEED := 7.5
const RADIUS := 0.408

var _player: CharacterBody3D
var _failed: bool = false
var _blocks: Array[StaticBody3D] = []
## Highest grounded point reached during the last _walk.
var _high: Vector3 = Vector3.ZERO


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_player = (load("res://scenes/player/player.tscn") as PackedScene).instantiate()
	_player.position = Vector3(0, 0.2, 0)
	root.add_child(_player)
	_player.set_physics_process(false)
	await _settle_on(_floor_box(Vector3(0, -0.5, 0), Vector3(80, 1, 40)))
	await _check_flat()
	await _check_lip(0.05)
	await _check_lip(0.1)
	await _check_lip(0.2)
	await _check_lip(0.35)
	await _check_wall(0.55)
	await _check_mesh_lip(0.28)
	await _check_stairs()
	await _check_coplanar_seam()
	await _check_ramp()
	await _check_trimesh_floor()
	await _check_trimesh_wedge()
	await _check_diagonal_lip()
	await _check_trimesh_curb()
	await _check_thin_lip()
	await _check_tucked_ramp()
	await _check_overhead_bar()
	await _check_thin_wall()
	await _check_low_ceiling()
	await _check_no_step_while_jumping()
	await _check_step_down()
	await _check_mesh_ledge()
	_clear()
	if _failed:
		print("STEP_UP_SELF_TEST FAIL")
		quit(1)
	else:
		print("STEP_UP_SELF_TEST PASS")
		quit(0)


func _floor_box(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	_blocks.append(body)
	return body


func _clear() -> void:
	for body in _blocks:
		if is_instance_valid(body):
			body.queue_free()
	_blocks.clear()


func _settle_on(floor_body: StaticBody3D) -> void:
	var top := floor_body.position.y + _box_half(floor_body).y
	_player.global_position = Vector3(floor_body.position.x, top + 0.05, floor_body.position.z)
	_player.velocity = Vector3(0, -2.0, 0)
	for _i in 12:
		StepUp.move_and_slide(_player, 0.0, false, false)
		await physics_frame
	_player.velocity = Vector3.ZERO


func _box_half(body: StaticBody3D) -> Vector3:
	var shape := body.get_child(0) as CollisionShape3D
	return (shape.shape as BoxShape3D).size * 0.5


## Walk +X the way Player._physics_process drives StepUp. Speed accelerates from the current
## velocity (ground_accel); forcing full speed every frame hides a lip that kills the live player.
func _walk(frames: int, speed: float = SPEED) -> Vector3:
	var delta := _player.get_physics_process_delta_time()
	var gravity: float = _player.gravity
	var accel: float = _player.ground_accel
	_high = _player.global_position
	for _i in frames:
		var on_floor := _player.is_on_floor()
		var y: float = _player.velocity.y
		if on_floor and y < 0.0:
			y = 0.0
		elif not on_floor:
			y -= gravity * delta * 0.5
		var horizontal := Vector3(_player.velocity.x, 0.0, _player.velocity.z)
		horizontal = horizontal.move_toward(Vector3(speed, 0.0, 0.0), accel * delta)
		_player.velocity = Vector3(horizontal.x, y, horizontal.z)
		StepUp.move_and_slide(_player, _player.step_height, on_floor, false)
		if not on_floor and not _player.is_on_floor():
			_player.velocity.y -= gravity * delta * 0.5
		if _player.is_on_floor() and _player.global_position.y >= _high.y:
			_high = _player.global_position
		await physics_frame
	return _player.global_position


func _check_flat() -> void:
	var start := _player.global_position
	var end := await _walk(30)
	_expect(end.x - start.x > 3.0, "flat floor: walked, dx=%.2f" % (end.x - start.x))
	_expect(absf(end.y - start.y) < 0.05, "flat floor: no hop, dy=%.3f" % (end.y - start.y))
	_expect(_player.is_on_floor(), "flat floor: stays grounded")


## A box lip whose front face is 1.2 m ahead of the player. `climb` means the feet should end on it.
func _check_lip(height: float) -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 1.2
	_floor_box(Vector3(face + 3.0, height * 0.5, 0), Vector3(6.0, height, 8.0))
	var end := await _walk(50)
	var on_top := absf(end.y - height) < 0.08 and end.x > face + 0.15
	_expect(on_top, "lip %.2f m: climbed (pos=%s)" % [height, end])
	_expect(_player.is_on_floor(), "lip %.2f m: grounded on top" % height)


func _check_wall(height: float) -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 1.2
	_floor_box(Vector3(face + 1.0, height * 0.5, 0), Vector3(2.0, height, 8.0))
	var end := await _walk(40)
	_expect(end.x < face - 0.05, "wall %.2f m: did not mount (x=%.2f face=%.2f)" % [height, end.x, face])
	_expect(end.y < 0.12, "wall %.2f m: feet stayed down (y=%.2f)" % [height, end.y])


## A concave box, which is how the greybox maps collide. The corner normal is not a floor.
func _check_mesh_lip(height: float) -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 1.2
	_mesh_box(Vector3(face + 3.0, height * 0.5, 0), Vector3(6.0, height, 8.0))
	var end := await _walk(50)
	var on_top := absf(end.y - height) < 0.08 and end.x > face + 0.15
	_expect(on_top, "mesh lip %.2f m: climbed (pos=%s)" % [height, end])
	_expect(_player.is_on_floor(), "mesh lip %.2f m: grounded on top" % height)


func _mesh_box(center: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var p := [
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
		center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
	]
	var quads := [[4, 5, 6, 7], [0, 3, 2, 1], [0, 1, 5, 4], [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
	var faces := PackedVector3Array()
	for q in quads:
		faces.append(p[q[0]])
		faces.append(p[q[1]])
		faces.append(p[q[2]])
		faces.append(p[q[0]])
		faces.append(p[q[2]])
		faces.append(p[q[3]])
	_add_trimesh(faces)


func _check_stairs() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(30, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 0.6
	# Four 0.25 m risers on 0.45 m treads, plus a landing. Solids meet at the riser and do not overlap.
	for i in 4:
		var top := 0.25 * float(i + 1)
		var depth := 0.45
		var x_front := face + depth * float(i)
		_floor_box(Vector3(x_front + depth * 0.5, (top - 1.0) * 0.5, 0), Vector3(depth, top + 1.0, 6.0))
	_floor_box(Vector3(face + 1.8 + 3.0, 0.0, 0), Vector3(6.0, 2.0, 6.0))
	await _walk(80)
	_expect(_high.y > 0.9, "stairs: reached the landing grounded (high=%s)" % _high)


func _check_coplanar_seam() -> void:
	_clear()
	# Two floor slabs whose tops meet at y=0. The shared edge is a classic capsule snag.
	var left := _floor_box(Vector3(-4, -0.5, 0), Vector3(8, 1, 16))
	_floor_box(Vector3(4.01, -0.5, 0), Vector3(8, 1, 16))
	await _settle_on(left)
	_player.global_position.x = -1.0
	var end := await _walk(40)
	_expect(end.x > 2.5, "coplanar seam: crossed the joint (x=%.2f)" % end.x)
	_expect(absf(end.y) < 0.08, "coplanar seam: stayed on the floor (y=%.3f)" % end.y)


func _check_ramp() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(24, 1, 16))
	await _settle_on(floor_body)
	# 27° wedge, the Lockout ramp angle. The toe is flush with the floor; the far end is 1.5 m up.
	var toe := _player.global_position.x + 0.6
	var rise := 1.5
	var run := rise / tan(deg_to_rad(27.0))
	_add_trimesh(_wedge_faces(toe, toe + run, rise))
	await _walk(80)
	_expect(_high.y > 0.6, "ramp: walked up the slope (high=%s)" % _high)


func _check_trimesh_floor() -> void:
	_clear()
	# A tiled concave floor. Capsules snag on interior triangle edges of one mesh.
	var faces := PackedVector3Array()
	var x0 := -2.0
	var x1 := 14.0
	var z0 := -4.0
	var z1 := 4.0
	var cell := 0.5
	var x := x0
	while x < x1 - 0.001:
		var z := z0
		while z < z1 - 0.001:
			var ax := Vector3(x, 0, z)
			var bx := Vector3(x + cell, 0, z)
			var cx := Vector3(x + cell, 0, z + cell)
			var dx := Vector3(x, 0, z + cell)
			faces.append_array([ax, bx, cx, ax, cx, dx])
			z += cell
		x += cell
	_add_trimesh(faces)
	_player.global_position = Vector3(0, 0.2, 0)
	_player.velocity = Vector3.ZERO
	for _i in 12:
		StepUp.move_and_slide(_player, 0.0, false, false)
		await physics_frame
	var end := await _walk(60)
	_expect(end.x > 6.0, "trimesh floor: crossed the tiles (x=%.2f y=%.3f)" % [end.x, end.y])
	_expect(_player.is_on_floor(), "trimesh floor: stayed grounded")


func _check_trimesh_wedge() -> void:
	_clear()
	# Flat tiles, then a 32° slope tucked into them the way the greybox ramps join floors.
	var faces := PackedVector3Array()
	var toe := 2.0
	var x := -2.0
	while x < toe - 0.001:
		faces.append_array([
			Vector3(x, 0, -3), Vector3(x + 0.5, 0, -3), Vector3(x + 0.5, 0, 3),
			Vector3(x, 0, -3), Vector3(x + 0.5, 0, 3), Vector3(x, 0, 3),
		])
		x += 0.5
	var rise := 1.6
	var run := rise / tan(deg_to_rad(32.0))
	faces.append_array(_wedge_faces(toe - 0.15, toe + run, rise))
	_add_trimesh(faces)
	_player.global_position = Vector3(0, 0.2, 0)
	_player.velocity = Vector3.ZERO
	for _i in 12:
		StepUp.move_and_slide(_player, 0.0, false, false)
		await physics_frame
	await _walk(70)
	_expect(_high.y > 0.5, "trimesh wedge: left the flat floor onto the slope (high=%s)" % _high)


## Approach a 0.15 m lip from 40° off its normal. The contact is a corner, not a flat face.
func _check_diagonal_lip() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(30, 1, 30))
	await _settle_on(floor_body)
	var height := 0.15
	_floor_box(Vector3(3.5, height * 0.5, 3.5), Vector3(6.0, height, 6.0))
	for _i in 45:
		var on_floor := _player.is_on_floor()
		var y := 0.0 if on_floor else _player.velocity.y
		_player.velocity = Vector3(SPEED * 0.7, y, SPEED * 0.7)
		if on_floor and _player.velocity.y < 0.0:
			_player.velocity.y = 0.0
		StepUp.move_and_slide(_player, _player.step_height, on_floor, false)
		await physics_frame
	var end := _player.global_position
	_expect(end.y > height - 0.05, "diagonal lip: climbed (pos=%s)" % end)
	_expect(_player.is_on_floor(), "diagonal lip: grounded")


## One concave mesh: flat floor plus a 0.12 m curb. The shared edge is what catches a capsule.
func _check_trimesh_curb() -> void:
	_clear()
	var faces := PackedVector3Array()
	var curb_x := 1.6
	var curb_h := 0.12
	# Floor y=0 from x=-2 to the curb, then the curb top, in 0.5 m tiles.
	var x := -2.0
	while x < curb_x - 0.001:
		var nx := minf(x + 0.5, curb_x)
		faces.append_array([
			Vector3(x, 0, -3), Vector3(nx, 0, -3), Vector3(nx, 0, 3),
			Vector3(x, 0, -3), Vector3(nx, 0, 3), Vector3(x, 0, 3),
		])
		x = nx
	# Vertical riser.
	faces.append_array([
		Vector3(curb_x, 0, -3), Vector3(curb_x, curb_h, -3), Vector3(curb_x, curb_h, 3),
		Vector3(curb_x, 0, -3), Vector3(curb_x, curb_h, 3), Vector3(curb_x, 0, 3),
	])
	x = curb_x
	while x < curb_x + 6.0 - 0.001:
		var nx := minf(x + 0.5, curb_x + 6.0)
		faces.append_array([
			Vector3(x, curb_h, -3), Vector3(nx, curb_h, -3), Vector3(nx, curb_h, 3),
			Vector3(x, curb_h, -3), Vector3(nx, curb_h, 3), Vector3(x, curb_h, 3),
		])
		x = nx
	# Give the curb some underside so the hull is closed enough for Jolt.
	faces.append_array([
		Vector3(curb_x, 0, -3), Vector3(curb_x + 6.0, 0, 3), Vector3(curb_x + 6.0, 0, -3),
		Vector3(curb_x, 0, -3), Vector3(curb_x, 0, 3), Vector3(curb_x + 6.0, 0, 3),
	])
	_add_trimesh(faces)
	_player.global_position = Vector3(0, 0.3, 0)
	_player.velocity = Vector3(0, -4, 0)
	for _i in 20:
		var on_floor := _player.is_on_floor()
		if not on_floor:
			_player.velocity.y -= _player.gravity * _player.get_physics_process_delta_time()
		StepUp.move_and_slide(_player, 0.0, on_floor, false)
		await physics_frame
	var end := await _walk(50)
	_expect(end.y > curb_h - 0.04 and end.x > curb_x + 0.3, "trimesh curb: climbed the edge (pos=%s)" % end)
	_expect(_player.is_on_floor(), "trimesh curb: grounded on top")


func _add_trimesh(faces: PackedVector3Array) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var mesh := ConcavePolygonShape3D.new()
	mesh.data = faces
	shape.shape = mesh
	body.add_child(shape)
	root.add_child(body)
	_blocks.append(body)


## Wedge along +X: toe at y=0, far end at `rise`. Solid down to y=-1 so it does not hover.
func _wedge_faces(x0: float, x1: float, rise: float) -> PackedVector3Array:
	var z0 := -3.0
	var z1 := 3.0
	var y0 := 0.0
	var y1 := rise
	var bot := -1.0
	return PackedVector3Array([
		Vector3(x0, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1),
		Vector3(x0, y0, z0), Vector3(x1, y1, z1), Vector3(x0, y0, z1),
		Vector3(x0, bot, z0), Vector3(x0, bot, z1), Vector3(x1, bot, z1),
		Vector3(x0, bot, z0), Vector3(x1, bot, z1), Vector3(x1, bot, z0),
		Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, bot, z1),
		Vector3(x0, y0, z0), Vector3(x0, bot, z1), Vector3(x0, bot, z0),
		Vector3(x1, y1, z0), Vector3(x1, bot, z1), Vector3(x1, y1, z1),
		Vector3(x1, y1, z0), Vector3(x1, bot, z0), Vector3(x1, bot, z1),
		Vector3(x0, y0, z0), Vector3(x0, bot, z0), Vector3(x1, bot, z0),
		Vector3(x0, y0, z0), Vector3(x1, bot, z0), Vector3(x1, y1, z0),
		Vector3(x0, y0, z1), Vector3(x1, y1, z1), Vector3(x1, bot, z1),
		Vector3(x0, y0, z1), Vector3(x1, bot, z1), Vector3(x0, bot, z1),
	])


## A lip thinner than the capsule. Standing on its top overlaps the riser, so the step has to
## cross it and land on the floor beyond instead of hitching on the edge.
func _check_thin_lip() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 1.0
	_mesh_box(Vector3(face + 0.125, 0.1, 0), Vector3(0.25, 0.2, 8.0))
	var end := await _walk(50)
	_expect(end.x > face + 1.0, "thin lip: crossed it (x=%.2f face=%.2f)" % [end.x, face])
	_expect(end.y < 0.1, "thin lip: back on the floor (y=%.2f)" % end.y)
	_expect(_player.is_on_floor(), "thin lip: stayed grounded")


## Greybox ramp(): the slab is 0.3 m over-long and 0.4 m thick, so its high end tucks under the
## next floor. The capsule must still reach that floor.
func _check_tucked_ramp() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(30, 1, 16))
	await _settle_on(floor_body)
	var rise := 1.2
	var run := rise / tan(deg_to_rad(32.0))
	var toe := _player.global_position.x + 1.0
	var end_x := toe + run
	var a := Vector3(toe, 0.0, 0.0)
	var b := Vector3(end_x, rise, 0.0)
	var delta := b - a
	var horiz := Vector2(delta.x, delta.z).length()
	var length := delta.length() + 0.3
	var yaw := atan2(-delta.x, -delta.z)
	var pitch := atan2(delta.y, horiz)
	var fwd := delta.normalized()
	var side := fwd.cross(Vector3.UP).normalized()
	var normal := side.cross(fwd).normalized()
	var mid := (a + b) * 0.5 - normal * 0.2
	_mesh_oriented(mid, Vector3(6.0, 0.4, length), pitch, yaw)
	_floor_box(Vector3(end_x + 4.0, rise - 0.25, 0), Vector3(8.0, 0.5, 8.0))
	var end := await _walk(90)
	# The ramp crest can sit above the landing, so the highest point is not the furthest.
	_expect(end.y > rise - 0.25, "tucked ramp: ended on the upper floor (end=%s)" % end)
	_expect(end.x > end_x + 1.0, "tucked ramp: walked onto the floor (x=%.2f end_x=%.2f)" % [end.x, end_x])


## A 0.3 m bar that only clips the top of the head. The body has to walk under it.
func _check_overhead_bar() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + 1.2
	_floor_box(Vector3(face + 0.15, 2.22, 0), Vector3(0.3, 0.4, 6.0))
	var end := await _walk(40)
	_expect(end.x > face + 1.0, "overhead bar: walked under it (x=%.2f face=%.2f)" % [end.x, face])
	_expect(end.y < 0.1, "overhead bar: stayed on the floor (y=%.2f)" % end.y)
	_expect(_player.is_on_floor(), "overhead bar: stayed grounded")


## A thin wall that reaches the chest. It must stay solid.
func _check_thin_wall() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(40, 1, 16))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 1.0
	_floor_box(Vector3(face + 0.15, 0.75, 0), Vector3(0.3, 1.5, 6.0))
	var end := await _walk(30)
	_expect(end.x < face + 0.05, "thin wall: did not pass through (x=%.2f face=%.2f)" % [end.x, face])
	_expect(end.y < 0.1, "thin wall: feet stayed down (y=%.2f)" % end.y)


func _mesh_oriented(center: Vector3, size: Vector3, pitch: float, yaw: float) -> void:
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var h := size * 0.5
	var corners: Array[Vector3] = [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z),
		Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var p: Array[Vector3] = []
	for corner in corners:
		p.append(center + basis * corner)
	var quads := [[4, 5, 6, 7], [0, 3, 2, 1], [0, 1, 5, 4], [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
	var faces := PackedVector3Array()
	for q in quads:
		faces.append(p[q[0]])
		faces.append(p[q[1]])
		faces.append(p[q[2]])
		faces.append(p[q[0]])
		faces.append(p[q[2]])
		faces.append(p[q[3]])
	_add_trimesh(faces)


func _check_low_ceiling() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(30, 1, 12))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 0.8
	_floor_box(Vector3(face + 2.0, 0.1, 0), Vector3(4.0, 0.2, 6.0))
	# Standing body is 2.1 m. This ceiling clears the floor and blocks a 0.2 m step.
	_floor_box(Vector3(face + 2.0, 2.15 + 0.25, 0), Vector3(6.0, 0.5, 6.0))
	var end := await _walk(40)
	_expect(end.y < 0.1, "low ceiling: did not step into the ceiling (y=%.2f)" % end.y)
	_expect(end.x < face + 0.05, "low ceiling: stopped at the lip (x=%.2f face=%.2f)" % [end.x, face])


func _check_no_step_while_jumping() -> void:
	_clear()
	var floor_body := _floor_box(Vector3(0, -0.5, 0), Vector3(30, 1, 12))
	await _settle_on(floor_body)
	var face := _player.global_position.x + RADIUS + 0.3
	_floor_box(Vector3(face + 1.5, 0.1, 0), Vector3(3.0, 0.2, 6.0))
	var on_floor := _player.is_on_floor()
	_player.velocity = Vector3(SPEED, 6.0, 0.0)
	StepUp.move_and_slide(_player, _player.step_height, on_floor, true)
	await physics_frame
	_expect(_player.global_position.y < 0.15, "jump: did not snap onto the lip (y=%.2f)" % _player.global_position.y)


## A trimesh platform edge. The vertical face of the slab pins a capsule; the step must still leave it.
func _check_mesh_ledge() -> void:
	_clear()
	# Top at y=0.2. The lower floor top is y=0, so the drop is inside step_height.
	_mesh_box(Vector3(0, 0.0, 0), Vector3(4.0, 0.4, 6.0))
	_floor_box(Vector3(6.0, -0.5, 0), Vector3(8.0, 1.0, 8.0))
	_player.global_position = Vector3(0, 0.5, 0)
	_player.velocity = Vector3(0, -2, 0)
	for _i in 12:
		StepUp.move_and_slide(_player, 0.0, false, false)
		await physics_frame
	var end := await _walk(50)
	_expect(end.x > 3.0 and end.y < 0.12, "mesh ledge: walked off onto the lower floor (pos=%s)" % end)
	_expect(_player.is_on_floor(), "mesh ledge: stayed grounded")


func _check_step_down() -> void:
	_clear()
	var platform := _floor_box(Vector3(0, -0.35, 0), Vector3(6, 1, 8))
	_floor_box(Vector3(6, -0.5, 0), Vector3(10, 1, 8))
	await _settle_on(platform)
	# Platform top is 0.15. The lower floor top is 0. Drop is 0.15, inside step_height.
	var end := await _walk(40)
	_expect(end.x > 4.0, "step-down: left the platform (x=%.2f)" % end.x)
	_expect(end.y < 0.08, "step-down: landed on the lower floor (y=%.2f)" % end.y)
	_expect(_player.is_on_floor(), "step-down: stayed grounded")


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
