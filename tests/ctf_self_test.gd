extends SceneTree
## Capture the Flag (CtfMatch) on the real Lockout arena, offline: bases at the two far ends
## (Lockout has no team spawns, so its spawns are split between them), take, capture, the
## "own flag must be home" rule, drop on death, the return timer, return by touch, the win at
## capture_limit (offline: scores reset and play goes on), kills never winning, the state
## payload round trip, the menu rule that CTF needs teams, and bots taking a flag on their own.
## Settings are changed in memory only, never saved. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/ctf_self_test.gd

const ARENA := "res://scenes/main/arena_lockout.tscn"
const RED := GameMode.TEAM_RED
const BLUE := GameMode.TEAM_BLUE
## CtfMatch.FlagState (the class isn't referenced here: in --script mode its Net autoload
## isn't a compile-time identifier yet, so it is loaded at runtime with the arena).
const HOME := 0
const CARRIED := 1
const DROPPED := 2

var _failed: bool = false
var _net: Node
var _settings: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_net = root.get_node("Net")
	_settings = root.get_node("Settings")
	_test_rules_need_teams()
	await _test_rules()
	await _test_bots()
	_net.set(&"match_running", false)
	if _failed:
		print("CTF_SELF_TEST FAIL")
		quit(1)
		return
	print("CTF_SELF_TEST PASS")
	quit(0)


func _test_rules_need_teams() -> void:
	_expect(GameModes.is_ctf("ctf") and GameModes.needs_teams("ctf"), "CTF is a teams objective")
	_expect(GameModes.fit_mode("ctf", "ffa") == GameModes.TEAM_FALLBACK, "CTF turns FFA into teams")
	_expect(GameModes.fit_mode("ctf", "team_slayer") == "team_slayer", "CTF keeps a team count")
	_expect(GameModes.fit_mode("slayer", "ffa") == "ffa", "Slayer keeps FFA")


func _load_arena(bots: int) -> Node:
	_net.set(&"rules_id", "ctf")
	_net.set(&"mode_id", "team_4v4")
	_net.set(&"match_running", true)
	_settings.set(&"bot_count", bots)
	var arena := (load(ARENA) as PackedScene).instantiate()
	root.add_child(arena)
	await _frames(10)
	return arena


func _test_rules() -> void:
	var arena := await _load_arena(0)
	var ctf: Node = arena.get_node_or_null("NetMatch/Ctf")
	_expect(ctf != null, "NetMatch added the Ctf node")
	if ctf == null:
		arena.queue_free()
		return
	var spawns := arena.get_node("SpawnManager") as SpawnManager
	_expect(not spawns.kill_win, "kills don't win in CTF")
	var red_home: Vector3 = ctf.flag_of(RED).home
	var blue_home: Vector3 = ctf.flag_of(BLUE).home
	var captures: Dictionary = ctf.captures
	_expect(red_home.distance_to(blue_home) > 25.0, "bases far apart (%.1f m)" % red_home.distance_to(blue_home))
	var split: Dictionary = spawns.team_spawn_override
	_expect(
		split.has(RED) and split.has(BLUE) and not (split[RED] as Array).is_empty()
		and not (split[BLUE] as Array).is_empty(),
		"Lockout's spawns split between the bases"
	)
	var player := arena.get_node("Player") as Player
	_expect(ArenaEvents.team_of(player) == RED, "local player is Red")
	var to_red := player.global_position.distance_to(red_home)
	var to_blue := player.global_position.distance_to(blue_home)
	_expect(to_red < to_blue, "player spawned on the Red side (%.0f vs %.0f m)" % [to_red, to_blue])
	var wins := []
	spawns.match_won.connect(func(w: String, _s: Dictionary) -> void: wins.append(w))

	# Take the enemy flag, carry it home, capture.
	_teleport(player, blue_home)
	await _frames(3)
	var blue: Dictionary = ctf.flag_of(BLUE)
	_expect(blue.state == CARRIED and blue.carrier == player, "touching the enemy flag takes it")
	_expect(not ctf.carried_by(player).is_empty(), "carried_by finds it")
	_teleport(player, red_home)
	await _frames(3)
	_expect(int(ctf.captures[RED]) == 1, "carrying it home captures (%d)" % int(ctf.captures[RED]))
	_expect(blue.state == HOME, "the captured flag goes home")
	var entry: Dictionary = spawns.scores.get(str(player.get_meta(&"display_name", "Player")), {})
	_expect(int(entry.get("caps", 0)) == 1, "the capture is on the scoreboard")

	# No capture while our own flag is away.
	_teleport(player, blue_home)
	await _frames(3)
	var red: Dictionary = ctf.flag_of(RED)
	red.state = DROPPED
	red.pos = red_home + Vector3(3, 0, 0)
	red.drop_left = 60.0
	_teleport(player, red_home)
	await _frames(3)
	_expect(int(ctf.captures[RED]) == 1, "no capture while our own flag is away")
	# Touching our own dropped flag returns it; then the capture counts.
	_teleport(player, red.pos)
	await _frames(3)
	_expect(red.state == HOME, "touching our dropped flag returns it")
	_teleport(player, red_home)
	await _frames(3)
	_expect(int(ctf.captures[RED]) == 2, "capture once our flag is home (%d)" % int(ctf.captures[RED]))

	# Drop on death, then the return timer.
	_teleport(player, blue_home)
	await _frames(3)
	var drop_at := player.global_position
	player.take_damage(500.0, {"bleedthrough": true})
	await _frames(3)
	_expect(blue.state == DROPPED, "the carrier's death drops the flag")
	_expect((blue.pos as Vector3).distance_to(drop_at) < 2.5, "dropped where they died")
	var payload: Array = ctf._state_payload()
	blue.drop_left = 0.05
	await _frames(6)
	_expect(blue.state == HOME, "a dropped flag returns on its own")
	# The client side of the sync rebuilds the same state from the payload.
	ctf._rpc_state(payload)
	_expect(blue.state == DROPPED and int(ctf.captures[RED]) == 2, "state payload round trip")
	blue.state = HOME
	blue.pos = blue_home

	# Third capture wins; offline the scores reset and play goes on.
	player.respawn_at(Transform3D(Basis.IDENTITY, blue_home + Vector3(0, 0.2, 0)))
	await _frames(3)
	_teleport(player, red_home)
	await _frames(3)
	_expect(wins == ["Red Team"], "the third capture wins (%s)" % [wins])
	_expect(int(ctf.captures[RED]) == 0 and int(ctf.captures[BLUE]) == 0, "offline: captures reset")
	_expect((ctf.flag_of(BLUE) as Dictionary).state == HOME, "offline: flags start over")
	arena.queue_free()
	await _frames(3)


## Four bots, the player out of the way: the bots go and take a flag on their own (they stop
## to fight on the way, so this allows a few cross-map trips).
func _test_bots() -> void:
	var arena := await _load_arena(4)
	var ctf: Node = arena.get_node_or_null("NetMatch/Ctf")
	var player := arena.get_node("Player") as Player
	player.process_mode = Node.PROCESS_MODE_DISABLED  # out of the way: bots vs bots
	player.global_position = Vector3(0, -200, 0)
	var taken := [false]
	var goals := {}
	for i in 150 * 60:
		await physics_frame
		for flag: Dictionary in (ctf.flags as Dictionary).values():
			if flag.state != HOME:
				taken[0] = true
		if i == 120:
			for bot in get_nodes_in_group(&"bot"):
				goals[str(bot.name)] = ctf.goal_for(bot)
		if taken[0]:
			break
	var with_goal := 0
	for g: Dictionary in goals.values():
		if not g.is_empty():
			with_goal += 1
	_expect(goals.size() == 4 and with_goal == 4, "every bot has a CTF goal (%d / %d)" % [with_goal, goals.size()])
	_expect(taken[0], "bots take a flag within 150 s")
	arena.queue_free()
	await _frames(3)


func _teleport(player: Player, at: Vector3) -> void:
	player.global_position = at + Vector3(0, 0.2, 0)
	player.velocity = Vector3.ZERO


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
