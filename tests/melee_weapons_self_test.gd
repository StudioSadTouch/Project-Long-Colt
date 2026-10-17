extends SceneTree
## Longsword and gravity hammer (WeaponData.melee_primary) on the real scenes: the trigger
## swings, the sword lunges and one-hits, never runs out (no ammo on the HUD), a second swing is
## locked out; the hammer smashes after its windup with falloff,
## through no walls, never hurting the swinger, and spends a charge per swing; the third-person
## prop shows the right mesh; a bot with a sword closes in and kills a player. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/melee_weapons_self_test.gd

const SWORD := "res://scenes/weapons/longsword.tscn"
const HAMMER := "res://scenes/weapons/gravity_hammer.tscn"
const DUMMY := "res://scenes/ai/target_dummy.tscn"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := _box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	await _test_sword()
	await _test_hammer()
	await _test_bot_sword()
	floor_body.queue_free()
	if _failed:
		print("MELEE_WEAPONS_SELF_TEST FAIL")
		quit(1)
		return
	print("MELEE_WEAPONS_SELF_TEST PASS")
	quit(0)


func _test_sword() -> void:
	var player := await _player_with(SWORD)
	var sword := player.get_weapon_holder().get_active()
	_expect(sword != null and sword.data.melee_primary, "sword equipped")
	var props := player.find_child("Prop_Sword", true, false) as Node3D
	_expect(props != null and props.visible, "third-person prop shows the sword")
	var dummy := _dummy(Vector3(0, 0, -5.5))
	await _frames(5)
	var swings := [0]
	sword.melee_started.connect(func(_w: Weapon, _t: float) -> void: swings[0] += 1)
	var start := player.global_position
	sword.trigger(true, true)
	sword.trigger(false, true)
	sword.release_trigger()
	await _frames(1)
	sword.trigger(true, true)  # inside the swing lock: refused
	sword.release_trigger()
	await _frames(40)
	_expect(swings[0] == 1, "one swing for two quick presses (%d)" % swings[0])
	var driver := player.find_child("CharacterAnimDriver", true, false) as CharacterAnimDriver
	var action: AnimationNodeAnimation = driver.get(&"_action_anim")
	var first := action.animation
	_expect(first in [&"melee_sword", &"melee_sword_b"], "third person: a sword swing (%s)" % first)
	_expect(player.global_position.distance_to(start) > 1.5, "the swing lunged in")
	_expect(_dead(dummy), "lunge from 5.5 m one-hits a full-shield target")
	_expect(sword.magazine == 1, "a steel blade never runs out (%d)" % sword.magazine)
	var hud := player.get_node("HUD")
	var ammo := hud.get_node("Ammo") as Label
	_expect(ammo.text == "", "no ammo counter on the HUD ('%s')" % ammo.text)
	# Twenty more swings: still swinging, alternating forehand / backhand.
	player.rotation.y = PI  # face away from everything
	var seen := {}
	for i in 20:
		await _frames(45)
		sword.trigger(true, true)
		sword.release_trigger()
		await _frames(2)
		seen[action.animation] = true
	_expect(seen.has(&"melee_sword") and seen.has(&"melee_sword_b"), "swings alternate (%s)" % [seen.keys()])
	await _frames(5)
	_expect(swings[0] == 21 and sword.magazine == 1, "21 swings, still full (%d)" % swings[0])
	dummy.queue_free()
	player.queue_free()
	await _frames(2)


func _test_hammer() -> void:
	var player := await _player_with(HAMMER)
	var hammer := player.get_weapon_holder().get_active()
	_expect(hammer != null and hammer.data.smash_radius > 0.0, "hammer equipped")
	var close := _dummy(Vector3(0.5, 0, -2.4))
	var far := _dummy(Vector3(-1.2, 0, -5.6))
	var shielded := _dummy(Vector3(3.6, 0, -2.4))
	_box(Vector3(2.4, 1.5, -2.4), Vector3(0.3, 3.0, 2.0))  # wall between the smash and `shielded`
	await _frames(5)
	var hp := player.health_shield.shield + player.health_shield.health
	var smashes := [0]
	hammer.smashed.connect(func(_c: Vector3) -> void: smashes[0] += 1)
	hammer.trigger(true, true)
	hammer.release_trigger()
	await _frames(5)
	_expect(smashes[0] == 0 and not _dead(close), "nothing lands during the windup")
	_expect(hammer.magazine == 9, "the swing spends a charge at once (%d)" % hammer.magazine)
	await _frames(20)
	_expect(smashes[0] == 1, "the smash goes off after smash_delay")
	_expect(_dead(close), "inner radius kills")
	var far_hs := far.get_node("HealthShield") as HealthShield
	var far_lost := 115.0 - (far_hs.shield + far_hs.health)
	_expect(far_lost > 5.0 and not _dead(far), "outer radius hurts less (%.1f)" % far_lost)
	var wall_hs := shielded.get_node("HealthShield") as HealthShield
	_expect(wall_hs.shield + wall_hs.health >= 114.9, "a wall blocks the smash")
	var hp_after := player.health_shield.shield + player.health_shield.health
	_expect(absf(hp_after - hp) < 0.01, "the swinger is never hurt")
	for n in [close, far, shielded, player]:
		n.queue_free()
	await _frames(2)


## A bot holding the sword sees a player 6 m away, lunges and kills.
func _test_bot_sword() -> void:
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, -6.0)
	root.add_child(player)
	player.rotation.y = PI
	var bot := (load("res://scenes/ai/bot.tscn") as PackedScene).instantiate() as Bot
	bot.starting_weapons = [load(SWORD) as PackedScene, load(HAMMER) as PackedScene]
	bot.team = 5
	root.add_child(bot)
	bot.respawn_at(Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 0)))
	var killed := [false]
	player.died.connect(func(_p: Player, _k: Node, _i: Dictionary) -> void: killed[0] = true)
	for i in 300:
		await _frames(1)
		if killed[0]:
			break
	_expect(bot.get_active() != null and bot.get_active().data.melee_primary, "bot holds a melee weapon")
	_expect(killed[0], "the bot closes in and kills the player with it")
	bot.queue_free()
	player.queue_free()
	await _frames(2)


func _player_with(scene_path: String) -> Player:
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 0)
	root.add_child(player)
	await _frames(5)
	var holder := player.get_weapon_holder()
	holder.give_weapon((load(scene_path) as PackedScene).instantiate() as Weapon)
	await _frames(60)  # equip
	return player


func _dummy(at: Vector3) -> Node3D:
	var dummy := (load(DUMMY) as PackedScene).instantiate() as Node3D
	root.add_child(dummy)
	dummy.global_position = at
	return dummy


func _dead(dummy: Node3D) -> bool:
	var core := dummy.get_node("DummyCore")
	return bool(core.get(&"dead"))


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
