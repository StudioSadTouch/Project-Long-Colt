extends SceneTree
## Ivory Tower greybox checks: every spawn and pickup stands on a floor with headroom, the
## elevator (L0 -> L2) and the Dark Room vents (L1 -> L2) carry a player above the 9 m floor,
## and the baked navmesh reaches every roam point from the plaza (lift links included). Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/ivory_tower_self_test.gd

const LEVEL := "res://scenes/levels/ivory_tower.tscn"
const ARENA := "res://scenes/main/arena_ivory_tower.tscn"
const L2 := 9.0
const BAKE_TIMEOUT := 90.0

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _check_level()
	await _check_navigation()
	if _failed:
		print("ivory_tower_self_test: FAILED")
		quit(1)
	else:
		print("ivory_tower_self_test: all passed")
		quit(0)


func _check_level() -> void:
	var level := (load(LEVEL) as PackedScene).instantiate() as Node3D
	root.add_child(level)
	for i in 3:
		await physics_frame
	var space := root.get_world_3d().direct_space_state
	var spawns := level.get_node(^"Spawns").get_children()
	_expect(spawns.size() == 26, "26 spawn markers (got %d)" % spawns.size())
	for s: Node3D in spawns:
		_check_standable(space, s.global_position, "spawn %s" % s.name)
	# pickups live in the arena scene; check them against this level's geometry
	var arena := (load(ARENA) as PackedScene).instantiate()
	for n in arena.get_children():
		if n is Node3D and n.get("weapon_scene") != null:
			_check_standable(space, (n as Node3D).position, "pickup %s" % n.name)
	arena.free()

	_expect(await _ride(Vector3(0, 0.1, -34)) > L2 + 0.3, "elevator lifts L0 -> above L2")
	_expect(await _ride(Vector3(-27.5, 4.6, -20)) > L2 + 0.3, "vent 0 lifts L1 -> above L2")
	_expect(await _ride(Vector3(-27.5, 4.6, -8)) > L2 + 0.3, "vent 1 lifts L1 -> above L2")
	level.queue_free()
	await process_frame


## Floor within 0.4 m below p, and 2.2 m of clear headroom above it.
func _check_standable(space: PhysicsDirectSpaceState3D, p: Vector3, what: String) -> void:
	var down := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.5, p + Vector3.DOWN * 0.4, 1)
	var hit := space.intersect_ray(down)
	_expect(not hit.is_empty(), "%s has a floor under it at %s" % [what, p])
	if hit.is_empty():
		return
	var floor_y: float = (hit.position as Vector3).y
	var up := PhysicsRayQueryParameters3D.create(
		Vector3(p.x, floor_y + 0.05, p.z), Vector3(p.x, floor_y + 2.2, p.z), 1
	)
	_expect(space.intersect_ray(up).is_empty(), "%s has 2.2 m headroom" % what)


## Drops a fresh player at p and returns the highest y it reaches in 2.5 s.
func _ride(p: Vector3) -> float:
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Node3D
	player.set(&"auto_respawn", false)
	player.position = p
	root.add_child(player)
	var top := p.y
	for _i in 150:
		await physics_frame
		top = maxf(top, player.global_position.y)
	print("  ..   ride from %s peaked at y %.2f" % [p, top])
	player.queue_free()
	await process_frame
	return top


func _check_navigation() -> void:
	var arena := (load(ARENA) as PackedScene).instantiate()
	root.add_child(arena)
	var nav: Node = arena.get_node(^"Navigation")
	var start := Time.get_ticks_msec()
	while not nav.get(&"is_baked") and Time.get_ticks_msec() - start < BAKE_TIMEOUT * 1000.0:
		await process_frame
	_expect(nav.get(&"is_baked"), "navmesh baked")
	# The region syncs into the map on a later server iteration; until then queries return zero.
	var map := (arena as Node3D).get_world_3d().navigation_map
	var probe := Vector3(4, 0, 4)
	var from := Vector3.ZERO
	for _i in 300:
		await physics_frame
		from = NavigationServer3D.map_get_closest_point(map, probe)
		if from.distance_to(probe) < 1.0:
			break
	_expect(from.distance_to(probe) < 1.0, "nav map synced (plaza probe %s)" % from)
	for p: Node3D in arena.get_node(^"NavPoints").get_children():
		var goal := p.global_position
		var path := NavigationServer3D.map_get_path(map, from, goal, true)
		var end := path[path.size() - 1] if path.size() > 0 else from
		var off := end.distance_to(goal)
		_expect(off < 1.0, "plaza -> %s reachable (path ends %.1f m off)" % [p.name, off])
	arena.queue_free()
	await process_frame


func _expect(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		_failed = true
