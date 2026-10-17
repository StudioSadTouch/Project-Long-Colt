extends SceneTree
## Automated self-test verifying melee knockback, explosion knockback,
## back assassination geometry, one-hit lethal damage, death feedback, and
## death_back / death_crouch_back animation triggering.
##
## Run:
## flatpak run org.godotengine.Godot --headless --path . -s tests/assassination_self_test.gd

const PLAYER := preload("res://scenes/player/player.tscn")
const RIFLE_SCENE := preload("res://scenes/weapons/standard_issue_rifle.tscn")

var _failed: bool = false
var _world: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_world = Node3D.new()
	_world.name = "World"
	root.add_child(_world)
	_add_floor(Vector3(0, -0.5, 0), Vector3(100, 1, 100))
	await _settle()

	_test_assassination_geometry()
	_test_knockback_math()
	await _test_front_melee_damage()
	await _test_back_assassination_kill_and_anim(false)
	await _test_back_assassination_kill_and_anim(true)

	if _world != null and is_instance_valid(_world):
		_world.queue_free()

	if _failed:
		print("ASSASSINATION_SELF_TEST FAIL")
		quit(1)
		return
	print("ASSASSINATION_SELF_TEST PASS")
	quit(0)


func _test_assassination_geometry() -> void:
	var victim := Node3D.new()
	var attacker := Node3D.new()
	_world.add_child(victim)
	_world.add_child(attacker)

	# Victim at origin facing -Z (Godot forward, yaw 0)
	victim.position = Vector3.ZERO
	victim.rotation = Vector3.ZERO

	# Case 1: Attacker directly behind victim (z = +1.5), facing -Z (same direction)
	attacker.position = Vector3(0, 0, 1.5)
	attacker.rotation = Vector3.ZERO
	var fwd := Vector3(0, 0, -1)
	_expect(
		Weapon.is_back_assassination(attacker, victim, fwd),
		"geometry: attacker behind facing same direction is back assassination"
	)

	# Case 2: Attacker in front of victim (z = -1.5), facing +Z
	attacker.position = Vector3(0, 0, -1.5)
	attacker.rotation = Vector3(0, PI, 0)
	var fwd_front := Vector3(0, 0, 1)
	_expect(
		not Weapon.is_back_assassination(attacker, victim, fwd_front),
		"geometry: frontal attack is NOT back assassination"
	)

	# Case 3: Attacker behind victim (z = +1.5), but facing +Z (away from victim)
	attacker.position = Vector3(0, 0, 1.5)
	attacker.rotation = Vector3(0, PI, 0)
	var fwd_away := Vector3(0, 0, 1)
	_expect(
		not Weapon.is_back_assassination(attacker, victim, fwd_away),
		"geometry: attacker facing away is NOT back assassination"
	)

	# Case 4: Attacker to the side (x = +2.0)
	attacker.position = Vector3(2.0, 0, 0)
	attacker.rotation = Vector3.ZERO
	_expect(
		not Weapon.is_back_assassination(attacker, victim, fwd),
		"geometry: side attack is NOT back assassination"
	)

	attacker.queue_free()
	victim.queue_free()


func _test_knockback_math() -> void:
	var melee_impulse := Knockback.melee(Vector3(0, 0, -1))
	_expect(melee_impulse.z < -1.0, "knockback: melee imparts forward impulse (%.2f)" % melee_impulse.z)
	_expect(melee_impulse.y > 0.5, "knockback: melee has vertical hop (%.2f)" % melee_impulse.y)

	var blast_impulse := Knockback.blast(Vector3(1, 0, 0), 60.0, 80.0)
	_expect(blast_impulse.x > 5.0, "knockback: blast imparts outward impulse (%.2f)" % blast_impulse.x)
	_expect(blast_impulse.y > 1.0, "knockback: blast lifts target (%.2f)" % blast_impulse.y)


func _test_front_melee_damage() -> void:
	var victim := _spawn_player(Vector3(0, 0.05, 0))
	var attacker := _spawn_player(Vector3(0, 0.05, -1.2))
	# Victim facing -Z, attacker facing +Z (front-to-front)
	victim.rotation = Vector3.ZERO
	attacker.rotation = Vector3(0, PI, 0)
	await _settle()

	var weapon: Weapon = attacker.get_active_weapon()
	_expect(weapon != null, "front melee: attacker has weapon")
	var initial_shield := victim.health_shield.shield
	var initial_health := victim.health_shield.health
	_expect(initial_shield >= 70.0 and initial_health >= 45.0, "front melee: victim at full HP")

	# Simulate melee swing connecting from the front
	var hit := {
		"target": victim,
		"collider": victim,
		"position": victim.global_position,
		"normal": Vector3(0, 0, -1)
	}
	weapon._apply_melee(hit)
	await _frames(2)

	_expect(not victim.dead, "front melee: victim survives front melee")
	_expect(victim.health_shield.shield < initial_shield, "front melee: shields absorbed hit")
	_expect(victim.health_shield.health == initial_health, "front melee: health undamaged")

	attacker.queue_free()
	victim.queue_free()
	await _settle()


func _test_back_assassination_kill_and_anim(crouched: bool) -> void:
	if crouched:
		Input.action_press(&"action_crouch")
	var victim := _spawn_player(Vector3(10, 0.05, 0))
	var attacker := _spawn_player(Vector3(10, 0.05, 1.2))
	# Both facing -Z (attacker is behind victim, striking into victim's back)
	victim.rotation = Vector3.ZERO
	attacker.rotation = Vector3.ZERO
	await _frames(25)

	var weapon: Weapon = attacker.get_active_weapon()
	_expect(weapon != null, "assassination: attacker has weapon")

	var signal_data := {"received": false, "victim": null, "attacker": null}
	weapon.assassinated.connect(func(v: Node, a: Node) -> void:
		signal_data["received"] = true
		signal_data["victim"] = v
		signal_data["attacker"] = a
	)

	var hit := {
		"target": victim,
		"collider": victim,
		"position": victim.global_position,
		"normal": Vector3(0, 0, 1)
	}
	weapon._apply_melee(hit)
	await _frames(4)

	_expect(signal_data["received"], "assassination: assassinated signal emitted")
	_expect(signal_data["victim"] == victim, "assassination: victim matched in signal")
	_expect(signal_data["attacker"] == attacker, "assassination: attacker matched in signal")
	_expect(victim.dead, "assassination: one-hit lethal kill through full shield + health")

	var last_info: Dictionary = victim.last_damage_info
	_expect(bool(last_info.get("assassination", false)), "assassination: info has assassination=true")
	_expect(bool(last_info.get("backstab", false)), "assassination: info has backstab=true")
	_expect(str(last_info.get("hit_zone_name", "")) == "assassination", "assassination: hit_zone_name is assassination")

	var anim_source: CharacterAnimSource = victim.get_node("PlayerModel/CharacterAnimSource") as CharacterAnimSource
	var death_dir: int = anim_source.state.death_dir
	_expect(death_dir == CharacterAnimState.HitDir.BACK, "assassination: death_dir is HitDir.BACK (%d)" % death_dir)

	var driver: CharacterAnimDriver = victim.get_node("PlayerModel/CharacterAnimDriver") as CharacterAnimDriver
	var expected_clip := "death_crouch_back" if crouched else "death_back"
	var actual_clip: String = str(driver._death_anim.animation)
	_expect(actual_clip == expected_clip, "assassination: animation is %s (got %s)" % [expected_clip, actual_clip])

	if crouched:
		Input.action_release(&"action_crouch")
	attacker.queue_free()
	victim.queue_free()
	await _settle()


func _spawn_player(pos: Vector3) -> Player:
	var player := PLAYER.instantiate() as Player
	player.auto_respawn = false
	player.position = pos
	_world.add_child(player)
	return player


func _add_floor(pos: Vector3, size: Vector3) -> void:
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


func _settle() -> void:
	await _frames(10)


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
