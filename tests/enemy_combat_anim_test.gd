extends SceneTree
## Verification test:
## 1. Enemy detects and shoots directly at Player, dealing bullet damage (verifying _line_clear & _first_shot_at).
## 2. Enemy with melee primary (Yatagan/Kilij) charges, lunges, and deals melee damage to Player.
## 3. EnemyRig animates head pitch tracking, recoil, melee swing, and damage flinch.

const ENEMY_SCENE := "res://scenes/enemies/enemy.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const YATAGAN := "res://resources/weapons/new_ottoman/yatagan.tres"
const TUFEK := "res://resources/weapons/new_ottoman/tufek.tres"
const NEFER := "res://resources/enemies/new_ottoman/nefer.tres"
const AZAB := "res://resources/enemies/new_ottoman/azab.tres"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := _make_floor()
	await _test_gunfire_at_player()
	await _test_melee_at_player()
	await _test_rig_animations()
	floor_body.queue_free()
	await _frames(2)
	if _failed:
		print("ENEMY_COMBAT_ANIM_TEST FAIL")
		quit(1)
		return
	print("ENEMY_COMBAT_ANIM_TEST PASS")
	quit(0)


func _test_gunfire_at_player() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, -7.0)
	root.add_child(player)
	
	var azab_type := load(AZAB) as EnemyType
	var enemy := (load(ENEMY_SCENE) as PackedScene).instantiate() as Enemy
	enemy.enemy_type = azab_type
	enemy.position = Vector3(0, 0.05, 0)
	root.add_child(enemy)
	await _frames(5)
	
	var brain := enemy.get_node("Brain") as EnemyBrain
	brain.alert(player, player.global_position, true)
	
	var initial_shield: float = player.health_shield.shield
	var damaged := false
	for i in 180:
		await physics_frame
		if player.health_shield.shield < initial_shield or player.health_shield.health < player.health_shield.max_health:
			damaged = true
			break
	
	_expect(damaged, "Azab with rifle shoots directly at Player and deals damage (shield: %.1f -> %.1f)" % [initial_shield, player.health_shield.shield])
	_expect(brain.target == player, "Enemy targeted Player")
	_expect(brain._line_clear(), "Enemy _line_clear() is true against Player")
	
	player.queue_free()
	enemy.queue_free()
	await _frames(3)


func _test_melee_at_player() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, -2.5)
	root.add_child(player)
	
	var nefer_type := load(NEFER) as EnemyType
	var enemy := (load(ENEMY_SCENE) as PackedScene).instantiate() as Enemy
	enemy.enemy_type = nefer_type
	enemy.position = Vector3(0, 0.05, 0)
	root.add_child(enemy)
	await _frames(5)
	
	# Draw blade and alert
	var brain := enemy.get_node("Brain") as EnemyBrain
	brain.set_order(EnemyBrain.Order.CHARGE)
	brain.alert(player, player.global_position, true)
	
	var melee_result := {"hit": false}
	player.damaged.connect(func(_amount: float, info: Dictionary) -> void:
		if info.get("melee", false):
			melee_result.hit = true
	)
	
	for i in 120:
		await physics_frame
		if melee_result.hit:
			break
	
	_expect(melee_result.hit, "Nefer lunges and deals melee damage with blade to Player")
	
	player.queue_free()
	enemy.queue_free()
	await _frames(3)


func _test_rig_animations() -> void:
	var azab_type := load(AZAB) as EnemyType
	var enemy := (load(ENEMY_SCENE) as PackedScene).instantiate() as Enemy
	enemy.enemy_type = azab_type
	enemy.position = Vector3(0, 0.05, 0)
	root.add_child(enemy)
	await _frames(5)
	
	var rig := enemy.get_rig()
	_expect(rig != null, "EnemyRig instantiated")
	
	# Test head pitch tracking via set_aim (pause brain so patrol doesn't reset aim pitch to 0)
	enemy.get_node("Brain").set_physics_process(false)
	enemy.set_aim(Vector3(0, 1.0, -1.0))  # Aiming 45 degrees up
	await _frames(25)
	_expect(rig._head != null, "Rig has _head node")
	_expect(rig._head.rotation.x > deg_to_rad(15.0), "Rig _head tracks head look pitch (head rot: %.2f rad)" % rig._head.rotation.x)
	
	# Test weapon recoil on arms
	var initial_arm_pitch: float = rig._arm_pitch
	rig._on_weapon_fired()
	_expect(rig._recoil_pitch > 0.05, "Recoil pitch triggered on shot")
	await _frames(30)
	_expect(rig._recoil_pitch < 0.02, "Recoil recovers smoothly")
	
	# Test melee swing animation
	rig._on_melee_swung()
	_expect(rig._melee_swing_t >= 0.0, "Melee swing animation started")
	await _frames(10)
	_expect(rig._melee_swing_t > 0.0, "Melee swing animating")
	await _frames(30)
	_expect(rig._melee_swing_t < 0.0, "Melee swing completed and returned to rest")
	
	# Test damage flinch
	rig._on_damaged(40.0, {"shield_dealt": 0.0})
	_expect(rig._flinch_t > 0.1, "Damage flinch triggered even with zero shield")
	await _frames(20)
	_expect(rig._flinch_t <= 0.0, "Damage flinch recovered")
	
	enemy.queue_free()
	await _frames(3)


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = Vector3(0, -0.5, 0)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
