extends SceneTree
## Horde (HordeMatch, HordeWaves) on the real Lockout arena, offline: the mode is registered and
## hostable on LAN; waves follow the board's grammar and grow each round; the bots fight on your
## side; a wave spawns far from the defenders and comes looking; kills score points; clearing
## a wave resupplies and starts the countdown; the last few enemies get hunted; enemy kills
## leave no scoreboard rows; shared lives run out into game over. Settings changed in memory
## only. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/horde_self_test.gd

const ARENA := "res://scenes/main/arena_lockout.tscn"

var _failed: bool = false
var _net: Node
var _settings: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_net = root.get_node("Net")
	_settings = root.get_node("Settings")
	_test_registry()
	_test_waves()
	await _test_match()
	_net.set(&"match_running", false)
	if _failed:
		print("HORDE_SELF_TEST FAIL")
		quit(1)
		return
	print("HORDE_SELF_TEST PASS")
	quit(0)


func _test_registry() -> void:
	_expect(GameModes.has("horde") and GameModes.is_horde("horde"), "Horde is registered")
	_expect(GameModes.allows_online("horde"), "Horde can be hosted on LAN")
	_expect(GameModes.ids(true).has("horde"), "LAN pickers list Horde")
	_expect(GameModes.allows_online("slayer") and GameModes.ids(true).has("ctf"), "other rules stay online")
	_expect(not GameModes.keeps_score("horde"), "kills don't end Horde")


func _test_waves() -> void:
	var ids := {}
	for n in range(1, 21):
		for squad: Array in HordeWaves.wave(n).squads:
			for id: String in squad:
				ids[id] = true
		_expect(HordeWaves.enemy_count(n) <= 30, "wave %d is a sane size (%d)" % [n, HordeWaves.enemy_count(n)])
	for id: String in ids:
		_expect(load("res://resources/enemies/new_ottoman/%s.tres" % id) is EnemyType, "%s is an EnemyType" % id)
	_expect(ids.size() == 10, "all ten ranks appear by wave 20 (%d)" % ids.size())
	_expect(HordeWaves.enemy_count(1) == 5, "wave 1: an Azab line and its Bolukbasi")
	_expect(_has(5, "corbaci"), "wave 5 is the full orta, Corbaci included")
	_expect(_has(10, "aga") and not _has(5, "aga"), "the Aga leads wave 10, not before")
	_expect(HordeWaves.enemy_count(6) > HordeWaves.enemy_count(1), "round 2 is bigger than round 1")
	_expect(HordeWaves.round_of(5) == 1 and HordeWaves.round_of(6) == 2, "rounds of five")
	_expect(HordeWaves.points_for(&"aga") > HordeWaves.points_for(&"azab"), "the Aga is worth more")


func _has(wave: int, id: String) -> bool:
	for squad: Array in HordeWaves.wave(wave).squads:
		if squad.has(id):
			return true
	return false


func _test_match() -> void:
	_net.set(&"rules_id", "horde")
	_net.set(&"mode_id", "ffa")
	_net.set(&"match_running", true)
	_settings.set(&"bot_count", 2)
	var arena := (load(ARENA) as PackedScene).instantiate()
	root.add_child(arena)
	current_scene = arena
	var horde := arena.get_node_or_null("NetMatch/Horde") as HordeMatch
	_expect(horde != null, "NetMatch added the Horde node")
	if horde == null:
		return
	var spawns := arena.get_node("SpawnManager") as SpawnManager
	var player := arena.get_node("Player") as Player
	_expect(not spawns.kill_win, "kills don't win in Horde")
	for i in 900:
		if horde.phase == HordeMatch.Phase.STARTING:
			break
		await _frames(1)
	_expect(horde.phase == HordeMatch.Phase.STARTING, "countdown starts once the navmesh bakes")
	await _frames(5)
	_expect(spawns.bots.size() == 2, "two allied bots")
	for bot in spawns.bots:
		_expect(not ArenaEvents.is_hostile(bot, player), "%s is on our side" % bot.display_name)
	_expect(horde.lives == HordeMatch.START_LIVES, "%d shared lives" % horde.lives)
	horde.time_left = 0.05
	await _frames(5)
	_expect(horde.phase == HordeMatch.Phase.WAVE and horde.wave == 1, "wave 1 starts")
	_expect(horde.enemies.size() == 5, "wave 1 spawned 5 enemies (%d)" % horde.enemies.size())
	var nearest := INF
	for e in horde.enemies:
		nearest = minf(nearest, e.global_position.distance_to(player.global_position))
		_expect(ArenaEvents.is_hostile(e, player) and ArenaEvents.is_hostile(e, spawns.bots[0]), "%s is hostile" % e.name)
	_expect(nearest > 12.0, "the wave spawns away from the player (%.1f m)" % nearest)
	# Let it play: the squad has contact, so it should come and fight.
	# Enemies are Halo-inaccurate, so hits are luck: measure how far each shot passes from the
	# shooter's target instead. (A squad's Orta is rotated to face the defenders; when Bot.set_aim
	# wrote world yaw into local rotation, shots went 10+ m wide while the AI "looked" on target.)
	var hurt := [false]
	var misses: Array[float] = []
	for e in horde.enemies:
		for w: BotWeapon in e.slots:
			if w != null:
				w.fired.connect(func() -> void: hurt[0] = true)
				w.ray_fired.connect(
					func(from: Vector3, to: Vector3, _hit: Dictionary) -> void:
						var brain := e.get_node_or_null("Brain") as EnemyBrain
						if brain == null or not is_instance_valid(brain.target):
							return
						var aim: Dictionary = ArenaEvents.aim_points_of(brain.target)
						if aim.is_empty():
							return
						var body: Vector3 = aim.body
						misses.append((body - from).cross((to - from).normalized()).length())
				)
	var enemy_hurt := [false]
	for e in horde.enemies:
		e.damaged.connect(func(_a: float, _i: Dictionary) -> void: enemy_hurt[0] = true)
	# You hear them: each enemy shot gets a CombatFeedback 3D voice with its gun's fire sound in
	# the same frame. (Enemy guns reuse the player guns' sounds, so the allied bots' rifles match
	# the stream too: matching shots to voices by frame is what tells them apart.)
	var enemy_sounds := {}
	var shot_frames: Array[int] = []
	for e in horde.enemies:
		for w: BotWeapon in e.slots:
			var s := WeaponAudio.fire_sound_of(w)
			if s != null:
				enemy_sounds[s] = true
				w.fired.connect(func() -> void: shot_frames.append(Engine.get_physics_frames()))
	var voice_frames := {}
	var on_added := func(node: Node) -> void:
		if node is AudioStreamPlayer3D and enemy_sounds.has((node as AudioStreamPlayer3D).stream):
			voice_frames[Engine.get_physics_frames()] = true
	node_added.connect(on_added)
	var engaged := false
	for i in 40 * 60:
		await _frames(1)
		for e in horde.enemies:
			if is_instance_valid(e) and (e.get_node("Brain") as EnemyBrain).is_engaged():
				engaged = true
		if engaged and hurt[0] and enemy_hurt[0] and misses.size() >= 6:
			break
	_expect(engaged, "the wave finds the defenders")
	_expect(hurt[0] and enemy_hurt[0], "enemies shoot and get shot (%s / %s)" % [hurt[0], enemy_hurt[0]])
	node_added.disconnect(on_added)
	var voiced := shot_frames.filter(func(f: int) -> bool: return voice_frames.has(f)).size()
	_expect(
		shot_frames.size() >= 3 and voiced >= shot_frames.size() * 0.7,
		"enemy gunfire is heard (%d of %d shots)" % [voiced, shot_frames.size()]
	)
	misses.sort()
	var median: float = misses[misses.size() / 2] if not misses.is_empty() else INF
	_expect(misses.size() >= 3 and median < 3.0, "enemy shots go at their target (median miss %.1f m over %d)" % [median, misses.size()])
	# Enemy kills never put the enemy on the scoreboard.
	if horde.enemies.size() > 0 and not player.get_node("HealthShield").dead:
		player.take_damage(1000.0, {"source": horde.enemies[0], "bleedthrough": true})
		await _frames(2)
		_expect(horde.lives == HordeMatch.START_LIVES - 1, "a player death spends a life (%d)" % horde.lives)
		for key: String in spawns.scores:
			_expect(not key.begins_with("Azab") and not key.begins_with("Bolukbasi"), "no enemy row (%s)" % key)
		await _frames(int((spawns.respawn_delay + 0.5) * 60))
		_expect(not player.get_node("HealthShield").dead, "the player respawned on a life")
	# Clear the rest: points go to the player.
	var weapon := player.get_weapon_holder().get_active()
	if weapon != null:
		weapon.reserve = 0
	var before := horde.points_of(player)
	var expected := 0
	for e in horde.enemies.duplicate():
		if is_instance_valid(e) and not e.dead:
			expected += HordeWaves.points_for(e.enemy_type.id)
			e.take_damage(5000.0, {"source": player, "bleedthrough": true})
	await _frames(5)
	_expect(horde.points_of(player) - before == expected, "kills score points (%d of %d)" % [horde.points_of(player) - before, expected])
	_expect(horde.phase == HordeMatch.Phase.INTERMISSION, "wave cleared: intermission")
	_expect(weapon == null or weapon.reserve == weapon.data.reserve_max, "everyone resupplied")
	# Stall breaker: wave 3 down to its last two, who then hunt.
	horde.start_wave(3)
	await _frames(5)
	var squad := horde.enemies.duplicate()
	for i in squad.size() - 2:
		(squad[i] as Enemy).take_damage(5000.0, {"source": player, "bleedthrough": true})
	await _frames(int(HordeMatch.HUNT_INTERVAL * 60) + 10)
	_expect(horde.is_hunting(), "the last few are hunted")
	for e in horde.enemies:
		var brain := e.get_node("Brain") as EnemyBrain
		_expect(brain.target != null and not ArenaEvents.is_hostile(brain.target, player), "%s hunts a defender" % e.enemy_type.id)
		_expect(brain.order in [EnemyBrain.Order.CHARGE, EnemyBrain.Order.ADVANCE, EnemyBrain.Order.FLANK], "%s pushes (%s)" % [e.enemy_type.id, EnemyBrain.ORDER_NAMES[brain.order]])
	# Out of lives: down, then game over.
	horde.lives = 0
	var over := [false]
	arena.get_node("NetMatch").game_over.connect(func(_w: String, _s: Dictionary) -> void: over[0] = true)
	if player.get_node("HealthShield").dead:
		await _frames(int((spawns.respawn_delay + 0.5) * 60))
	player.take_damage(1000.0, {"source": horde.enemies[0] if not horde.enemies.is_empty() else null, "bleedthrough": true})
	await _frames(3)
	_expect(horde.is_down(player), "no lives: the player stays down")
	_expect(horde.phase == HordeMatch.Phase.OVER and over[0], "last player down: game over")
	await _frames(int((spawns.respawn_delay + 0.5) * 60))
	_expect(player.get_node("HealthShield").dead, "no respawn after game over")
	arena.queue_free()
	await _frames(3)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
