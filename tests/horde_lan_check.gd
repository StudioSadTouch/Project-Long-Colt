extends SceneTree
## Horde over LAN, end to end, as two real processes on this machine (localhost ENet). Not a
## *_self_test: it needs both roles running at once. Run the host first, then the client:
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/horde_lan_check.gd -- host
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/horde_lan_check.gd -- client
## Each prints "HORDE_LAN_<ROLE> PASS" or "... FAIL" and exits.
## Host: hosts Horde on Lockout with no bots (they would race the client for kills), starts the match once the client joins, skips
## the countdown, keeps the client's puppet out of harm, and after the client has shot, kills
## the rest of the wave credited to the client.
## Client: the wave's enemies appear as copies (no Brain, net_copy) and move; the match state
## and banner arrive; its own shots at a copy damage the host's real enemy (the copy's vitals
## drop); points reach its scoreboard row; dead copies die and are despawned.

const PORT := 7791
const ARENA_WAIT := 30.0

var _failed: bool = false
var _role: String = "host"
var _net: Node
var _settings: Node


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	_role = args[0] if not args.is_empty() else "host"
	call_deferred("_run")


func _run() -> void:
	_net = root.get_node("Net")
	_settings = root.get_node("Settings")
	_settings.set(&"bot_difficulty", "Normal")
	if _role == "client":
		await _client()
	else:
		await _host()
	_net.call(&"leave")
	var tag := "HORDE_LAN_%s" % _role.to_upper()
	print("%s %s" % [tag, "FAIL" if _failed else "PASS"])
	quit(1 if _failed else 0)


# ------------------------------------------------------------------ host


func _host() -> void:
	_settings.set(&"bot_count", 0)
	_settings.set(&"player_name", "Host")
	var err: int = _net.call(&"host", PORT, true, false, "lockout", "ffa", "horde")
	_expect(err == OK, "host: server up")
	var players: Dictionary = _net.get(&"players")
	for i in 60 * 20:
		if players.size() >= 2:
			break
		await _frames(1)
	_expect(players.size() >= 2, "host: the client registered")
	_net.call(&"start_match")
	var arena := await _arena()
	if arena == null:
		return
	var horde := arena.get_node("NetMatch/Horde") as HordeMatch
	for i in 60 * 20:
		if horde.phase == HordeMatch.Phase.STARTING:
			break
		await _frames(1)
	horde.time_left = 0.2
	for i in 60 * 10:
		if horde.phase == HordeMatch.Phase.WAVE:
			break
		await _frames(1)
	_expect(horde.phase == HordeMatch.Phase.WAVE, "host: wave 1 started")
	var net_match := arena.get_node("NetMatch")
	var puppet: Player = null
	for i in 60 * 10:  # the client's ready may land a retry later
		for p in (arena.get_node("SpawnManager") as SpawnManager).get_players():
			if p != net_match.get(&"local_player"):
				puppet = p
		if puppet != null:
			break
		await _frames(1)
	_expect(puppet != null, "host: the client's puppet is registered")
	_expect(
		puppet != null and int(puppet.get_meta(&"team", -1)) == SpawnManager.PLAYER_TEAM,
		"host: the client is on the defenders' team"
	)
	# The client is tested, not killed: keep the host's copy of it alive, and the host away.
	var host_player := net_match.get(&"local_player") as Player
	host_player.get_node("HealthShield").set(&"max_shield", 100000.0)
	host_player.get_node("HealthShield").call(&"reset")
	if puppet != null:
		puppet.get_node("HealthShield").set(&"max_shield", 100000.0)
		puppet.get_node("HealthShield").call(&"reset")
	# One enemy stands still in front of the client (brain off) so it has a clear shot.
	var dummy: Enemy = horde.enemies[0]
	(dummy.get_node("Brain") as Node).process_mode = Node.PROCESS_MODE_DISABLED
	dummy.move_wish = Vector3.ZERO
	if puppet != null:
		var ahead := -puppet.global_transform.basis.z
		ahead.y = 0.0
		# Snapped to the navmesh near the client, so it doesn't land past a ledge and fall.
		var want := puppet.global_position + ahead.normalized() * 5.0
		var map := arena.get_viewport().world_3d.navigation_map
		var spot := NavigationServer3D.map_get_closest_point(map, want)
		if spot == Vector3.ZERO or spot.distance_to(puppet.global_position) > 8.0:
			spot = NavigationServer3D.map_get_closest_point(map, puppet.global_position + Vector3(2, 0, 2))
		dummy.global_position = spot + Vector3.UP * 0.1
	var shots := [0, 0]
	net_match.remote_shot.connect(
		func(_id: int, _f: Vector3, _t: PackedVector3Array, hits: PackedByteArray) -> void:
			shots[0] += 1
			shots[1] += hits.count(1) if hits.size() > 0 else 0
	)
	var hurt_by_client := [0.0]
	for e in horde.enemies:
		e.damaged.connect(
			func(a: float, info: Dictionary) -> void:
				if info.get("source") == puppet:
					hurt_by_client[0] += a
		)
	for i in 60 * 30:
		if hurt_by_client[0] > 0.0:
			break
		await _frames(1)
	print("  host: accepted client shots %d (hits %s), dummy at %.1f m from puppet, dummy dead %s" % [shots[0], shots[1], dummy.global_position.distance_to(puppet.global_position) if puppet else -1.0, dummy.dead])
	_expect(hurt_by_client[0] > 0.0, "host: the client's shots hit a real enemy (%.0f)" % hurt_by_client[0])
	await _frames(120)  # let the hurt enemy's vitals reach the client before the wave dies
	# The parked enemy fires three shots at the client, so it must hear enemy gunfire.
	var gun := dummy.get_active()
	for i in 3:
		if puppet == null or dummy.dead or gun == null:
			break
		dummy.set_aim(puppet.get_aim_points().get("body", puppet.global_position) - dummy.get_eye_position())
		gun.trigger(true, true)
		gun.release_trigger()
		await _frames(40)
	for e in horde.enemies.duplicate():
		if is_instance_valid(e) and not e.dead:
			e.take_damage(5000.0, {"source": puppet, "bleedthrough": true})
	# Corpses clear after CORPSE_TIME; stay up until the client has checked and left.
	for i in 60 * 40:
		if players.size() < 2:
			break
		await _frames(1)


# ------------------------------------------------------------------ client


func _client() -> void:
	_settings.set(&"player_name", "Client")
	await _frames(60)
	var err: int = _net.call(&"join", "127.0.0.1", PORT)
	_expect(err == OK, "client: connecting")
	var arena := await _arena()
	if arena == null:
		return
	var horde := arena.get_node_or_null("NetMatch/Horde") as HordeMatch
	_expect(horde != null, "client: Horde node mirrored")
	if horde == null:
		return
	var banners := []
	var ui := arena.get_node("NetMatch/MatchUI")
	var feed := []
	arena.get_node("NetMatch").kill_feed.connect(func(t: String) -> void: feed.append(t))
	for i in 60 * 30:
		if horde.enemies.size() >= 5 and horde.phase == HordeMatch.Phase.WAVE:
			break
		await _frames(1)
	_expect(horde.enemies.size() >= 5, "client: the wave's enemies appear (%d)" % horde.enemies.size())
	_expect(horde.phase == HordeMatch.Phase.WAVE and horde.wave == 1, "client: wave 1 state arrived")
	_expect(horde.enemies_left() >= 5, "client: enemies left mirrored (%d)" % horde.enemies_left())
	if horde.enemies.is_empty():
		return
	var copy: Enemy = horde.enemies[0]
	_expect(copy.net_copy and copy.get_node_or_null(^"Brain") == null, "client: copies don't think")
	# Copies never fire here: CombatFeedback plays their gunfire from the host's shot FX. Each
	# enemy shot FX (net id >= NetEnemies.ID_BASE) must bring a 3D voice in the same frame.
	var voice_frames := {}
	node_added.connect(
		func(node: Node) -> void:
			if node is AudioStreamPlayer3D and (node as AudioStreamPlayer3D).stream != null:
				voice_frames[Engine.get_physics_frames()] = true
	)
	var enemy_fx: Array[int] = []
	arena.get_node("NetMatch").remote_shot.connect(
		func(id: int, _f: Vector3, _t: PackedVector3Array, _h: PackedByteArray) -> void:
			if id >= NetEnemies.ID_BASE:
				enemy_fx.append(Engine.get_physics_frames())
	)
	var start := {}
	for e in horde.enemies:
		start[e] = e.global_position
	await _frames(60 * 4)
	var moved := 0
	for e in horde.enemies:
		if is_instance_valid(e) and e.global_position.distance_to(start.get(e, e.global_position)) > 1.0:
			moved += 1
	_expect(moved > 0, "client: copies move with the host (%d)" % moved)
	# Shoot the nearest copy: walk the local player up to it and fire until the host says it
	# was hurt (its vitals drop in the snapshots).
	var player := arena.get_node("NetMatch").get(&"local_player") as Player
	# The host parks one enemy ~6 m in front of us; wait until its copy is there.
	var target: Enemy = null
	for i in 60 * 10:
		var nearest := 12.0
		for e in horde.enemies:
			var d := e.global_position.distance_to(player.global_position) if is_instance_valid(e) else INF
			if not e.dead and d < nearest:
				nearest = d
				target = e
		if target != null:
			break
		await _frames(1)
	_expect(target != null, "client: the parked enemy's copy is in front of me")
	if target == null:
		return
	var before := {}
	for e in horde.enemies:
		before[e] = e.health_shield.shield + e.health_shield.health
	var weapon := player.get_weapon_holder().get_active()
	print("  client: target %s at %.1f m, weapon %s" % [target.name, target.global_position.distance_to(player.global_position), weapon.data.display_name if weapon else "none"])
	var hit := false
	var fired := [0, {}]
	if weapon != null:
		weapon.fired.connect(func() -> void: fired[0] += 1)
		weapon.hit_confirmed.connect(func(t: Object, _i: Dictionary) -> void: fired[1][str(t.name) if t is Node else "?"] = true)
	for i in 60 * 20:
		await _frames(1)
		if not is_instance_valid(target) or target.dead:
			break
		var aim: Vector3 = target.get_aim_points().get("body", target.global_position + Vector3.UP)
		var to := aim - player.camera.global_position
		player.rotation.y = atan2(-to.x, -to.z)
		player.head.rotation.x = asin(clampf(to.normalized().y, -1.0, 1.0))
		if i % 6 == 0 and weapon != null:
			weapon.trigger(true, true)
			weapon.release_trigger()
			if weapon.magazine <= 0:
				weapon.reload()
		for e: Enemy in before:
			if is_instance_valid(e) and e.health_shield.shield + e.health_shield.health < float(before[e]) - 0.5:
				hit = true
		if hit:
			break
	print("  client: fired %d, local hits on %s, me dead %s" % [fired[0], fired[1].keys(), player.dead])
	_expect(hit, "client: shooting hurts the host's enemy (its copy's vitals drop)")
	for i in 60 * 15:
		if horde.points_of(player) > 0 and horde.enemies.is_empty():
			break
		await _frames(1)
	_expect(horde.points_of(player) > 0, "client: points reach my row (%d)" % horde.points_of(player))
	_expect(horde.enemies.is_empty(), "client: dead copies leave the living list")
	_expect(feed.any(func(t: String) -> bool: return t.begins_with("Client killed")), "client: kill feed (%s)" % [feed.slice(0, 3)])
	var left := 99
	for i in 60 * 12:
		left = 0
		for node in arena.find_children("NetEnemy_*", "", false, false):
			left += 1 if (node as Enemy).dead else 0
		if left == 0:
			break
		await _frames(1)
	_expect(left == 0, "client: corpses despawn (%d dead copies left)" % left)
	_expect(ui != null, "client: match UI present")
	var voiced := enemy_fx.filter(func(f: int) -> bool: return voice_frames.has(f)).size()
	_expect(
		enemy_fx.size() >= 3 and voiced >= enemy_fx.size() * 0.7,
		"client: enemy gunfire is heard (%d of %d enemy shots)" % [voiced, enemy_fx.size()]
	)


# ------------------------------------------------------------------ helpers


func _arena() -> Node:
	for i in int(ARENA_WAIT * 60):
		await _frames(1)
		var scene := current_scene
		if scene != null and scene.get_node_or_null(^"NetMatch") != null:
			await _frames(10)
			return scene
	_expect(false, "%s: arena loaded" % _role)
	return null


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
