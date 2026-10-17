extends SceneTree
## Game modes on Kamino, offline (the Bot Arena path: Net.match_running + Net.mode_id, as
## Net.start_offline sets them). Checks:
##   FFA          8 players (7 bots), every bot on its own team, everyone on SPAWN_FFA_* markers.
##   4v4          8 players (7 bots), 4 Red v 4 Blue, each side on its own base's markers.
##   Team Slayer  16 players (15 bots), 8 Red v 8 Blue counting the player, each side on its own
##                base's markers, team armor colour, no aim assist onto teammates, team score and
##                win at score_limit, betrayal -1, late-joiner rebalancing (pick_team_for_human /
##                remove_bot(team)), and bots actually crossing the platforms.
##   Bot count    a chosen count below the cap is what spawns (Lockout, 2 bots, not 7).
## Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/game_mode_self_test.gd

const BAKE_TIMEOUT := 90.0
const MAP := "kamino"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_registry()
	await _check_chosen_bot_count()
	await _check_ffa()
	await _check_team_4v4()
	await _check_team_slayer()
	var net := root.get_node(^"Net")
	net.set(&"match_running", false)
	if _failed:
		print("game_mode_self_test: FAILED")
		quit(1)
	else:
		print("game_mode_self_test: all passed")
		quit(0)


func _check_registry() -> void:
	_expect(GameMode.max_players("ffa") == 8, "FFA is 8 players")
	_expect(GameMode.max_players("team_4v4") == 8, "Team Slayer 4v4 is 8 players")
	_expect(GameMode.max_players("team_slayer") == 16, "Team Slayer is 16 players (8v8)")
	_expect(GameMode.is_team("team_4v4") and GameMode.is_team("team_slayer"), "team modes")
	_expect(not GameMode.is_team("ffa"), "FFA is not a team mode")
	_expect(GameMode.score_limit("team_4v4") == 50, "4v4 score limit is 50")
	_expect(
		GameMode.index_of("ffa") == 0
		and GameMode.index_of("team_4v4") == 1
		and GameMode.index_of("team_slayer") == 2,
		"player counts are FFA, 4v4, 8v8"
	)
	_expect(GameMode.sanitize("nope") == GameMode.DEFAULT_ID, "unknown mode falls back")
	_expect(GameMode.MAX_PLAYERS_ANY >= 16, "server sized for the largest mode")
	var settings := root.get_node(^"Settings")
	settings.set(&"bot_count", 3)
	_expect(int(settings.call(&"bot_count_for", 7)) == 3, "bot count keeps a request under the cap")
	_expect(int(settings.call(&"bot_count_for", 1)) == 1, "bot count clamps to the empty seats")
	_expect(int(settings.call(&"bot_count_for", 0)) == 0, "bot count is zero when there are no seats")
	settings.set(&"bot_count", 99)
	_expect(int(settings.call(&"bot_count_for", 15)) == 15, "bot count clamps to the largest mode")
	settings.set(&"bot_count", GameMode.MAX_PLAYERS_ANY - 1)
	var totals := GameMode.team_totals({
		"a": {"kills": 3, "team": GameMode.TEAM_RED},
		"b": {"kills": 2, "team": GameMode.TEAM_RED},
		"c": {"kills": 4, "team": GameMode.TEAM_BLUE},
		"d": {"kills": 9, "team": -1},
	})
	_expect(totals[GameMode.TEAM_RED] == 5 and totals[GameMode.TEAM_BLUE] == 4, "team totals sum members")


## Instantiates an arena as Bot Arena would for `mode`, waits for the bake and the bots.
func _load_arena(mode: String, map: String = MAP) -> Node:
	var net := root.get_node(^"Net")
	net.set(&"mode_id", mode)
	net.set(&"map_id", map)
	net.set(&"match_running", true)
	var arena := (load(MapList.arena_of(map)) as PackedScene).instantiate()
	root.add_child(arena)
	var nav: Node = arena.get_node(^"Navigation")
	var start := Time.get_ticks_msec()
	while not nav.get(&"is_baked") and Time.get_ticks_msec() - start < BAKE_TIMEOUT * 1000.0:
		await process_frame
	_expect(nav.get(&"is_baked"), "%s: navmesh baked" % mode)
	# Return on the first frame the bots exist, so they are still on their spawn markers.
	var spawns: SpawnManager = arena.get_node(^"SpawnManager")
	for i in 120:
		if spawns.bots.size() >= spawns.bot_count:
			break
		await process_frame
	return arena


func _markers(arena: Node, prefix: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for child in arena.get_node(^"Kamino/Spawns").get_children():
		if str(child.name).begins_with(prefix):
			out.append((child as Node3D).global_position)
	return out


func _near_any(p: Vector3, points: Array[Vector3]) -> bool:
	for q in points:
		if Vector2(p.x - q.x, p.z - q.z).length() < 2.0 and absf(p.y - q.y) < 1.5:
			return true
	return false


## Lockout's scene default is 3 bots and a full FFA would be 7. The menu's number wins.
func _check_chosen_bot_count() -> void:
	var settings := root.get_node(^"Settings")
	settings.set(&"bot_count", 2)
	var arena := await _load_arena("ffa", "lockout")
	var spawns: SpawnManager = arena.get_node(^"SpawnManager")
	_expect(spawns.bot_count == 2, "chosen count is written onto the spawner (got %d)" % spawns.bot_count)
	_expect(spawns.bots.size() == 2, "chosen count spawns 2 bots, not a full FFA (got %d)" % spawns.bots.size())
	settings.set(&"bot_count", GameMode.MAX_PLAYERS_ANY - 1)
	arena.queue_free()
	await process_frame


func _check_ffa() -> void:
	var arena := await _load_arena("ffa")
	var spawns: SpawnManager = arena.get_node(^"SpawnManager")
	_expect(spawns.score_limit == 25, "ffa: score limit 25")
	_expect(spawns.bots.size() == 7, "ffa: 7 bots + player = 8 (got %d)" % spawns.bots.size())
	var teams := {}
	var on_ffa := true
	var ffa_points := _markers(arena, "SPAWN_FFA")
	for bot in spawns.bots:
		teams[bot.team] = true
		on_ffa = on_ffa and _near_any(bot.global_position, ffa_points)
	teams[ArenaEvents.team_of(arena.get_node(^"Player"))] = true
	_expect(teams.size() == 8, "ffa: every combatant on its own team")
	_expect(on_ffa, "ffa: bots spawned on SPAWN_FFA markers")
	arena.queue_free()
	await process_frame


func _check_team_4v4() -> void:
	var arena := await _load_arena("team_4v4")
	var spawns: SpawnManager = arena.get_node(^"SpawnManager")
	var player: Player = arena.get_node(^"Player")
	_expect(spawns.score_limit == 50, "4v4: score limit 50")
	_expect(spawns.bots.size() == 7, "4v4: 7 bots + player = 8 (got %d)" % spawns.bots.size())
	_expect(ArenaEvents.team_of(player) == GameMode.TEAM_RED, "4v4: local player is Red")
	var counts := {GameMode.TEAM_RED: 1, GameMode.TEAM_BLUE: 0}
	var red_ok := true
	var blue_ok := true
	var red_points := _markers(arena, "SPAWN_Red")
	var blue_points := _markers(arena, "SPAWN_Blue")
	for bot in spawns.bots:
		counts[bot.team] = int(counts.get(bot.team, 0)) + 1
		if bot.team == GameMode.TEAM_RED:
			red_ok = red_ok and _near_any(bot.global_position, red_points)
		else:
			blue_ok = blue_ok and _near_any(bot.global_position, blue_points)
	_expect(
		counts[GameMode.TEAM_RED] == 4 and counts[GameMode.TEAM_BLUE] == 4,
		"4v4: 4v4 (%s)" % counts
	)
	_expect(red_ok and blue_ok, "4v4: each team spawned at its own base")
	_expect(_near_any(player.global_position, red_points), "4v4: player starts at a Red spawn")
	arena.queue_free()
	await process_frame


func _check_team_slayer() -> void:
	var arena := await _load_arena("team_slayer")
	var spawns: SpawnManager = arena.get_node(^"SpawnManager")
	var player: Player = arena.get_node(^"Player")
	_expect(spawns.score_limit == 50, "team: score limit 50")
	_expect(spawns.bots.size() == 15, "team: 15 bots + player = 16 (got %d)" % spawns.bots.size())
	_expect(ArenaEvents.team_of(player) == GameMode.TEAM_RED, "team: local player is Red")
	var counts := {GameMode.TEAM_RED: 1, GameMode.TEAM_BLUE: 0}
	var red_ok := true
	var blue_ok := true
	var red_points := _markers(arena, "SPAWN_Red")
	var blue_points := _markers(arena, "SPAWN_Blue")
	for bot in spawns.bots:
		counts[bot.team] = int(counts.get(bot.team, 0)) + 1
		if bot.team == GameMode.TEAM_RED:
			red_ok = red_ok and _near_any(bot.global_position, red_points)
		else:
			blue_ok = blue_ok and _near_any(bot.global_position, blue_points)
	_expect(counts[GameMode.TEAM_RED] == 8 and counts[GameMode.TEAM_BLUE] == 8, "team: 8v8 (%s)" % counts)
	_expect(red_ok and blue_ok, "team: each team spawned at its own base")
	_expect(_near_any(player.global_position, red_points), "team: player starts at a Red spawn")
	var red_bots: Array[Bot] = []
	var blue_bots: Array[Bot] = []
	for bot in spawns.bots:
		(red_bots if bot.team == GameMode.TEAM_RED else blue_bots).append(bot)
	_expect(not ArenaEvents.is_hostile(red_bots[0], player), "team: Red bot is friendly to the player")
	_expect(ArenaEvents.is_hostile(blue_bots[0], player), "team: Blue bot is hostile to the player")
	var assist: Node = player.find_child("AimAssist", true, false)
	if assist != null and assist.has_method(&"_is_teammate"):
		_expect(assist.call(&"_is_teammate", red_bots[0]), "team: aim assist skips a Red bot")
		_expect(not assist.call(&"_is_teammate", blue_bots[0]), "team: aim assist keeps a Blue bot")
	else:
		_expect(false, "team: player has an AimAssist")

	# Bots should leave the bases and cross bridges within a few seconds.
	var start_pos := {}
	for bot in spawns.bots:
		start_pos[bot] = bot.global_position
	for i in 60 * 8:
		await physics_frame
	var moved := 0
	var alive := 0
	for bot in spawns.bots:
		if is_instance_valid(bot) and not bot.is_dead():
			alive += 1
			if bot.global_position.distance_to(start_pos[bot]) > 6.0:
				moved += 1
	print("  ..   team: %d / %d living bots moved > 6 m in 8 s" % [moved, alive])
	_expect(moved >= 8, "team: most bots travel across the map")

	# Scoring: team totals, betrayal, the win.
	var won := []
	spawns.match_won.connect(func(w: String, _s: Dictionary) -> void: won.append(w))
	spawns.scores.clear()
	spawns.score_limit = 3
	spawns._record_kill(red_bots[1], red_bots[2], {"weapon": "test"})
	var red_total: int = GameMode.team_totals(spawns.scores)[GameMode.TEAM_RED]
	_expect(red_total == -1, "team: betrayal costs the team a kill (got %d)" % red_total)
	for i in 4:
		spawns._record_kill(red_bots[1], blue_bots[i], {"weapon": "test"})
	_expect(won.size() == 1 and won[0] == "Red Team", "team: Red Team wins at the limit (%s)" % [won])

	# Late joiner: goes to the team with fewer humans (Blue), and a Blue bot leaves for them.
	_expect(spawns.pick_team_for_human() == GameMode.TEAM_BLUE, "team: a joining human goes Blue")
	var before := blue_bots.size()
	_expect(spawns.remove_bot(GameMode.TEAM_BLUE), "team: removed a Blue bot")
	var blue_after := 0
	for bot in spawns.bots:
		blue_after += 1 if is_instance_valid(bot) and bot.team == GameMode.TEAM_BLUE else 0
	_expect(blue_after == before - 1, "team: Blue bot count dropped by one")
	arena.queue_free()
	await process_frame


func _expect(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		_failed = true
