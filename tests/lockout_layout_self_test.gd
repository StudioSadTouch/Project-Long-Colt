extends SceneTree
## Lockout greybox (tools/lockout/build_lockout_greybox.py): every roam point is reachable on foot
## from Top Mid (no nav links), spawns and pickups stand on floor with headroom, the arena's nav
## links touch the navmesh, and a real Player rides the lift into the upper lift room and clears
## the north and west gap jumps the Bungie design doc describes. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/lockout_layout_self_test.gd

const LEVEL := preload("res://scenes/levels/lockout.tscn")
const ARENA := preload("res://scenes/main/arena_lockout.tscn")
const PLAYER := preload("res://scenes/player/player.tscn")
const BAKE_TIMEOUT := 90.0
## Mirrors build_lockout_greybox.py: MCC pixels -> metres.
const PX_M := 0.12
const TOP := 4.5
const TOPLIFT := 5.0

var _failed: bool = false
var _world: Node3D
var _level: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_level = LEVEL.instantiate()
	_world.add_child(_level)
	var nav := ArenaNavigation.new()
	_world.add_child(nav)
	nav.geometry_root = nav.get_path_to(_level)
	# _ready already ran with the default path; bake again now that geometry_root is right.
	nav.call(&"_ready")
	var waited := 0.0
	while not nav.is_baked and waited < BAKE_TIMEOUT:
		await process_frame
		waited += 1.0 / 60.0
	_check(nav.is_baked, "navmesh baked (%d polygons)" % (nav.navigation_mesh.get_polygon_count() if nav.is_baked else 0))
	for _i in 4:
		await physics_frame

	var arena := ARENA.instantiate()
	_check_reachability(arena)
	_check_links(arena)
	_check_pickups(arena)
	arena.free()
	_check_spawns()

	await _test_lift()
	await _test_jump("north gap up", _px(280, 362, TOP), 0.0, func(p: Vector3) -> bool: return p.z < _z(325) + 0.15,
		func(p: Vector3) -> bool: return p.z < _z(281) and absf(p.y - TOPLIFT) < 0.2)
	await _test_jump("north gap down", _px(280, 240, TOPLIFT), 180.0, func(p: Vector3) -> bool: return p.z > _z(279) - 0.15,
		func(p: Vector3) -> bool: return p.z > _z(325) and absf(p.y - TOP) < 0.2)
	await _test_jump("west gap to BR2", _px(250, 400, TOP), 90.0, func(p: Vector3) -> bool: return p.x < _x(212) + 0.15,
		func(p: Vector3) -> bool: return p.x < _x(166) and absf(p.y - TOP) < 0.2)
	await _test_jump("west gap to Top Mid", _px(120, 400, TOP), -90.0, func(p: Vector3) -> bool: return p.x > _x(165) - 0.15,
		func(p: Vector3) -> bool: return p.x > _x(213) and absf(p.y - TOP) < 0.2)

	if _failed:
		print("LOCKOUT_LAYOUT_SELF_TEST FAIL")
		quit(1)
		return
	print("LOCKOUT_LAYOUT_SELF_TEST PASS")
	quit(0)


func _x(px: float) -> float:
	return (px - 279.0) * PX_M


func _z(py: float) -> float:
	return (py - 390.0) * PX_M


func _px(px: float, py: float, y: float) -> Vector3:
	return Vector3(_x(px), y, _z(py))


func _map() -> RID:
	return _world.get_world_3d().navigation_map


func _check_reachability(arena: Node) -> void:
	var points := arena.get_node(^"NavPoints").get_children()
	_check(points.size() >= 15, "%d roam points" % points.size())
	var from := NavigationServer3D.map_get_closest_point(_map(), (arena.get_node(^"NavPoints/TopMid") as Node3D).position)
	for point: Node3D in points:
		var target := point.position
		var snapped := NavigationServer3D.map_get_closest_point(_map(), target)
		var on_mesh := snapped.distance_to(target) < 0.6
		var path := NavigationServer3D.map_get_path(_map(), from, snapped, true, 1)
		var reached := path.size() > 0 and path[path.size() - 1].distance_to(snapped) < 0.6
		_check(on_mesh and reached, "walk Top Mid -> %s (snap %.2f m, path %d pts)" % [point.name, snapped.distance_to(target), path.size()])


func _check_links(arena: Node) -> void:
	for link: NavigationLink3D in arena.get_node(^"Navigation").get_children():
		for end: Vector3 in [link.start_position, link.end_position]:
			var d := NavigationServer3D.map_get_closest_point(_map(), end).distance_to(end)
			_check(d < 0.8, "%s end %s on the navmesh (%.2f m)" % [link.name, end, d])


func _floor_below(at: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 1.0, 1)
	var hit := _world.get_world_3d().direct_space_state.intersect_ray(q)
	return INF if hit.is_empty() else at.y - (hit.position as Vector3).y


func _check_pickups(arena: Node) -> void:
	var n := 0
	for child in arena.get_children():
		if child.name.contains("_") and child.get("weapon_scene") != null:
			n += 1
			var gap := _floor_below((child as Node3D).position)
			_check(absf(gap) < 0.1, "pickup %s on the floor (%.2f m)" % [child.name, gap])
	_check(n >= 8, "%d pickups" % n)


func _check_spawns() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 2.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = capsule
	q.collision_mask = 1
	var spawns := _level.get_node(^"Spawns").get_children()
	_check(spawns.size() >= 12, "%d spawns" % spawns.size())
	for spawn: Node3D in spawns:
		var gap := _floor_below(spawn.global_position)
		q.transform = Transform3D(Basis(), spawn.global_position + Vector3.UP * 1.1)
		var blocked := _world.get_world_3d().direct_space_state.intersect_shape(q, 1).size() > 0
		_check(gap < 0.2 and not blocked, "spawn %s: floor %.2f m below, clear=%s" % [spawn.name, gap, not blocked])


func _spawn_player(at: Vector3, yaw_deg: float) -> Player:
	var player := PLAYER.instantiate() as Player
	player.auto_respawn = false
	_world.add_child(player)
	player.global_position = at + Vector3.UP * 0.05
	player.rotation = Vector3(0, deg_to_rad(yaw_deg), 0)
	for _i in 10:
		await physics_frame
	return player


func _press(player: Player, action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	player._unhandled_input(event)
	Input.action_press(action)


func _release_all() -> void:
	for action in ["action_move_forward", "action_move_back", "action_jump"]:
		Input.action_release(action)


## Stand on the lift pad (facing north), ride up past the upper floor, then walk south onto it.
func _test_lift() -> void:
	var player := await _spawn_player(_px(280, 160, 0.0), 0.0)
	var top := player.global_position.y
	var frames := 0
	while frames < 240 and not (player.velocity.y < 0.0 and player.global_position.y > TOPLIFT + 0.5):
		await physics_frame
		top = maxf(top, player.global_position.y)
		frames += 1
	_check(top > TOPLIFT + 1.0, "lift carries the player above the upper floor (apex %.2f m)" % top)
	Input.action_press("action_move_back")
	for _i in 90:
		await physics_frame
	_release_all()
	for _i in 30:
		await physics_frame
	var p := player.global_position
	_check(player.is_on_floor() and absf(p.y - TOPLIFT) < 0.2, "lands in the upper lift room (pos %s)" % p)
	player.queue_free()
	await physics_frame


## Run at the edge, jump when take_off(pos) says so, and check where the player lands.
func _test_jump(what: String, start: Vector3, yaw_deg: float, take_off: Callable, landed_ok: Callable) -> void:
	var player := await _spawn_player(start, yaw_deg)
	Input.action_press("action_move_forward")
	var jumped := false
	var airborne := false
	var frames := 0
	while frames < 400:
		await physics_frame
		frames += 1
		if not jumped and take_off.call(player.global_position):
			_press(player, "action_jump")
			jumped = true
		elif jumped and not player.is_on_floor():
			airborne = true
		elif airborne and player.is_on_floor():
			break
	_release_all()
	var p := player.global_position
	_check(jumped and landed_ok.call(p), "%s: lands at %s" % [what, p])
	player.queue_free()
	await physics_frame


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed = true
