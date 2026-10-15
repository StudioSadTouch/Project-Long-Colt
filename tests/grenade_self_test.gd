extends SceneTree
## Grenades: blast damage and falloff against real Player bodies (70 shield / 45 health), walls
## blocking, the frag fuse, a sticky sticking to (and riding on) a body, self-damage credit, and
## the thrower's counts / cooldown / auto-select. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/grenade_self_test.gd

const PLAYER := preload("res://scenes/player/player.tscn")
const FRAG := preload("res://resources/weapons/frag_grenade.tres")
const STICKY := preload("res://resources/weapons/sticky_grenade.tres")

var _failed: bool = false
var _world: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))  # floor
	_add_box(Vector3(40, 1.5, 0), Vector3(0.5, 3, 6))  # wall at x = 40
	await _settle()

	await _test_frag_blast()
	await _test_sticky_blast()
	await _test_falloff_and_wall()
	await _test_frag_fuse_and_self_damage()
	await _test_sticky_rides_body()
	await _test_thrower()

	if _failed:
		print("GRENADE_SELF_TEST FAIL")
		quit(1)
		return
	print("GRENADE_SELF_TEST PASS")
	quit(0)


func _add_box(pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)


func _spawn_player(pos: Vector3) -> Player:
	var player := PLAYER.instantiate() as Player
	player.auto_respawn = false
	_world.add_child(player)
	player.global_position = pos
	return player


func _settle(frames: int = 6) -> void:
	for _i in frames:
		await physics_frame


func _space() -> PhysicsDirectSpaceState3D:
	return _world.get_world_3d().direct_space_state


## A frag at the feet of a full-shield player: strips the shield and bleeds 30 into health.
func _test_frag_blast() -> void:
	var victim := _spawn_player(Vector3(0, 0, 0))
	await _settle()
	Grenade.apply_blast(_space(), victim.global_position + Vector3(0, 0.15, 0), FRAG, null)
	var hs := victim.health_shield
	_check(not victim.dead, "frag at the feet does not kill a full shield")
	_check(is_zero_approx(hs.shield), "frag strips the shield (shield %.1f)" % hs.shield)
	_check(absf(hs.health - 15.0) < 0.5, "frag bleeds 30 into health (health %.1f)" % hs.health)
	victim.queue_free()
	await _settle(2)


func _test_sticky_blast() -> void:
	var victim := _spawn_player(Vector3(10, 0, 0))
	await _settle()
	Grenade.apply_blast(_space(), victim.global_position + Vector3(0, 1.0, 0), STICKY, null)
	_check(victim.dead, "a sticky on the body kills a full shield")
	victim.queue_free()
	await _settle(2)


func _test_falloff_and_wall() -> void:
	var far := _spawn_player(Vector3(20, 0, 6.0))
	var mid := _spawn_player(Vector3(20, 0, -3.0))
	var hidden := _spawn_player(Vector3(41.0, 0, 0))
	await _settle()
	var at := Vector3(20, 0.15, 0)
	var dealt := Grenade.apply_blast(_space(), at, FRAG, null)
	_check(not dealt.has(far), "nothing past the blast radius")
	_check(dealt.has(mid) and dealt[mid] < FRAG.damage and dealt[mid] > 0.0, "partial damage mid-range (%s)" % [dealt.get(mid)])
	dealt = Grenade.apply_blast(_space(), Vector3(39.0, 0.15, 0), FRAG, null)
	_check(not dealt.has(hidden), "a wall blocks the blast")
	for p in [far, mid, hidden]:
		p.queue_free()
	await _settle(2)


func _test_frag_fuse_and_self_damage() -> void:
	var thrower := _spawn_player(Vector3(60, 0, 0))
	await _settle()
	var grenade := Grenade.spawn(_world, FRAG, thrower.global_position + Vector3(0, 0.3, 0), Vector3.ZERO, thrower)
	var state := {"boom": false}
	grenade.exploded.connect(func(_g: Grenade, _at: Vector3) -> void: state.boom = true)
	var frames := 0
	while not state.boom and frames < 400:
		await physics_frame
		frames += 1
	var seconds := frames / float(Engine.physics_ticks_per_second)
	_check(state.boom, "frag goes off on its fuse")
	_check(absf(seconds - FRAG.fuse_time) < 0.15, "fuse %.2f s (want %.2f)" % [seconds, FRAG.fuse_time])
	_check(thrower.health_shield.shield < 70.0, "the thrower is hurt by their own frag")
	var source: Variant = thrower.last_damage_info.get("source")
	_check(source == thrower, "self-damage is credited to the thrower")
	_check(str(thrower.last_damage_info.get("weapon", "")) == "Frag Grenade", "kill feed name")
	thrower.queue_free()
	await _settle(2)


func _test_sticky_rides_body() -> void:
	var target := _spawn_player(Vector3(80, 0, 0))
	await _settle()
	var from := target.global_position + Vector3(-4, 1.2, 0)
	var grenade := Grenade.spawn(_world, STICKY, from, Vector3(14, 0, 0), null)
	var frames := 0
	while is_instance_valid(grenade) and not grenade.stuck and frames < 60:
		await physics_frame
		frames += 1
	_check(is_instance_valid(grenade) and grenade.stuck, "sticky sticks to the body")
	if is_instance_valid(grenade) and grenade.stuck:
		_check(target.is_ancestor_of(grenade), "sticky is parented under the body")
		var offset := grenade.global_position - target.global_position
		target.global_position += Vector3(0, 0, 5)
		await _settle(2)
		var moved := grenade.global_position - target.global_position
		_check(moved.distance_to(offset) < 0.05, "sticky rides along when the body moves")
		var state := {"boom": false}
		grenade.exploded.connect(func(_g: Grenade, _at: Vector3) -> void: state.boom = true)
		frames = 0
		while not state.boom and frames < 300:
			await physics_frame
			frames += 1
		_check(state.boom and target.dead, "stuck sticky goes off and kills")
	target.queue_free()
	await _settle(2)


func _test_thrower() -> void:
	var player := _spawn_player(Vector3(100, 0, 0))
	await _settle()
	var grenades := player.get_node(^"GrenadeThrower") as GrenadeThrower
	_check(grenades.counts == [2, 2] and grenades.selected == 0, "spawns with 2 frags + 2 stickies on frag")
	var thrown: Array = []
	grenades.thrown.connect(func(g: Grenade, _t: int, _o: Vector3, _v: Vector3) -> void: thrown.append(g))
	_check(grenades.throw_selected(), "first throw")
	_check(not grenades.throw_selected(), "cooldown blocks an instant second throw")
	_check(grenades.counts[0] == 1 and thrown.size() == 1, "one frag spent, one grenade out")
	var g: Grenade = thrown[0]
	_check(g.data == FRAG and g.linear_velocity.length() > 10.0, "frag thrown forward fast")
	_check(g.global_position.distance_to(player.get_eye_position()) < 1.0, "released from the hand")
	await _settle(int(FRAG.throw_cooldown * Engine.physics_ticks_per_second) + 4)
	_check(grenades.throw_selected(), "throw again after the cooldown")
	_check(grenades.counts[0] == 0 and grenades.selected == 1, "out of frags: selection moves to sticky")
	grenades.cycle()
	_check(grenades.selected == 0, "switch cycles back to frag even when empty")
	_check(not grenades.throw_selected(), "no frags left to throw")
	grenades.reset()
	_check(grenades.counts == [2, 2], "reset on respawn refills")
	for node in thrown:
		if is_instance_valid(node):
			node.queue_free()
	player.queue_free()
	await _settle(2)


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed = true
