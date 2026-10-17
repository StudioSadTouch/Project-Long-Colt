extends SceneTree
## Rocket launcher (the old DER slot, resources/weapons/directed_energy_rifle.tres): a shot is a
## travelling Rocket, not a hitscan beam; direct hits kill, splash falls off, walls block, the
## shooter is skipped in flight but hurt by a close blast, and visual-only copies deal nothing.
## Real Player bodies (70 shield / 45 health). Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/rocket_self_test.gd

const PLAYER := preload("res://scenes/player/player.tscn")
const LAUNCHER := preload("res://scenes/weapons/directed_energy_rifle.tscn")
const DATA := preload("res://resources/weapons/directed_energy_rifle.tres")

var _failed: bool = false
var _world: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))  # floor
	_add_box(Vector3(100, 1.5, -10), Vector3(6, 3, 0.5))  # wall at z = -10 in the x = 100 lane
	await _settle()

	_test_data()
	await _test_direct_hit()
	await _test_splash_falloff()
	await _test_wall_blocks()
	await _test_self_damage()
	await _test_visual_copy()

	if _failed:
		print("ROCKET_SELF_TEST FAIL")
		quit(1)
		return
	print("ROCKET_SELF_TEST PASS")
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


## A launcher held by `by`, aimed from its eye at `at`.
func _launcher(by: Player, at: Vector3) -> Weapon:
	var aim := Node3D.new()
	_world.add_child(aim)
	aim.global_position = by.get_eye_position()
	aim.look_at(at, Vector3.UP)
	var weapon := LAUNCHER.instantiate() as Weapon
	weapon.aim_source = aim
	weapon.shooter = by
	weapon.exclude_bodies = by.get_own_colliders()
	weapon.hit_mask_override = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
	_world.add_child(weapon)
	return weapon


func _rockets() -> Array[Rocket]:
	var out: Array[Rocket] = []
	# Rockets go under the current scene, which is the tree root in --script mode.
	for node in _world.get_children() + root.get_children():
		if node is Rocket:
			out.append(node as Rocket)
	return out


func _wait_for_blasts(frames: int = 120) -> void:
	for _i in frames:
		await physics_frame
		if _rockets().is_empty():
			return


func _test_data() -> void:
	_check(DATA.display_name == "Rocket Launcher", "renamed to Rocket Launcher")
	_check(DATA.projectile_speed > 0.0 and DATA.blast != null, "fires projectiles with a blast")
	_check(not DATA.battery and DATA.heat_per_shot <= 0.0, "no battery, no heat")
	_check(DATA.fire_mode == WeaponData.FireMode.SEMI, "semi-auto")
	_check(DATA.alt_fire_mode != WeaponData.FireMode.CHARGE or not DATA.fire_select, "no charge shot")
	_check(DATA.magazine_size == 2, "2 rockets in the tube")


## 20 m shot: nothing lands on the fire tick (no beam), the rocket is in flight, then it kills.
func _test_direct_hit() -> void:
	var shooter := _spawn_player(Vector3(0, 0, 0))
	var victim := _spawn_player(Vector3(0, 0, -20))
	await _settle()
	var weapon := _launcher(shooter, victim.global_position + Vector3.UP * 0.9)
	await _settle(2)
	var rays: Array = []
	weapon.ray_fired.connect(func(_f: Vector3, _t: Vector3, hit: Dictionary) -> void: rays.append(hit))
	weapon.trigger(true, true)
	weapon.trigger(false, false)
	_check(weapon.magazine == DATA.magazine_size - 1, "a shot spends one rocket")
	_check(rays.size() == 1 and (rays[0] as Dictionary).is_empty(), "the shot reports no ray hit")
	_check(_rockets().size() == 1, "a rocket is in flight")
	_check(is_equal_approx(victim.health_shield.shield, 70.0), "no instant damage (not hitscan)")
	await physics_frame
	_check(is_equal_approx(victim.health_shield.shield, 70.0), "still flying after one tick")
	await _wait_for_blasts()
	_check(victim.dead, "a direct hit kills a full shield")
	_check(victim.last_damage_info.get("source") == shooter, "kill credited to the shooter")
	_check(str(victim.last_damage_info.get("weapon", "")) == "Rocket Launcher", "kill feed name")
	_check(not shooter.dead and is_equal_approx(shooter.health_shield.shield, 70.0), "the shooter is untouched at 20 m")
	for node: Node in [shooter, victim, weapon, weapon.aim_source]:
		node.queue_free()
	await _settle(2)


func _test_splash_falloff() -> void:
	var close := _spawn_player(Vector3(40, 0, 0))
	var mid := _spawn_player(Vector3(60, 0, 0))
	var far := _spawn_player(Vector3(80, 0, 0))
	await _settle()
	var space := _world.get_world_3d().direct_space_state
	Grenade.apply_blast(space, close.global_position + Vector3(2.5, 0.9, 0), DATA.blast, null)
	var dealt := Grenade.apply_blast(space, mid.global_position + Vector3(4.5, 0.9, 0), DATA.blast, null)
	var none := Grenade.apply_blast(space, far.global_position + Vector3(6.5, 0.9, 0), DATA.blast, null)
	_check(close.dead, "2.5 m splash kills")
	_check(not mid.dead and dealt.has(mid) and dealt[mid] > 0.0, "4.5 m splash wounds only (%s)" % [dealt.get(mid)])
	_check(not none.has(far), "nothing past the 6 m blast radius")
	for p in [close, mid, far]:
		p.queue_free()
	await _settle(2)


## A wall between shooter and target: the rocket goes off on the wall, the target is fine.
func _test_wall_blocks() -> void:
	var shooter := _spawn_player(Vector3(100, 0, 0))
	var hidden := _spawn_player(Vector3(100, 0, -14))
	await _settle()
	var weapon := _launcher(shooter, hidden.global_position + Vector3.UP * 0.9)
	await _settle(2)
	weapon.trigger(true, true)
	weapon.trigger(false, false)
	await _wait_for_blasts()
	_check(is_equal_approx(hidden.health_shield.shield, 70.0), "a wall stops the rocket (no beam through)")
	for node: Node in [shooter, hidden, weapon, weapon.aim_source]:
		node.queue_free()
	await _settle(2)


## Firing into the floor at your feet hurts you (Halo rules).
func _test_self_damage() -> void:
	var shooter := _spawn_player(Vector3(140, 0, 0))
	await _settle()
	var weapon := _launcher(shooter, shooter.global_position + Vector3(0, 0, -1.5))
	await _settle(2)
	weapon.trigger(true, true)
	weapon.trigger(false, false)
	await _wait_for_blasts()
	_check(shooter.dead or shooter.health_shield.shield < 70.0, "a rocket at your own feet hurts you")
	for node: Node in [shooter, weapon, weapon.aim_source]:
		node.queue_free()
	await _settle(2)


## A net client's copy (own shot or a remote one): same flight, no damage.
func _test_visual_copy() -> void:
	var victim := _spawn_player(Vector3(180, 0, -10))
	await _settle()
	var from := Vector3(180, 1.0, 0)
	var rocket := Rocket.spawn(_world, DATA, from, (victim.global_position + Vector3.UP * 0.9 - from).normalized(), null, [], false)
	var state := {"boom": false}
	rocket.exploded.connect(func(_r: Rocket, _at: Vector3) -> void: state.boom = true)
	await _wait_for_blasts()
	_check(state.boom, "the visual copy still explodes")
	_check(is_equal_approx(victim.health_shield.shield, 70.0), "the visual copy deals no damage")
	victim.queue_free()
	await _settle(2)


func _check(ok: bool, what: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		_failed = true
