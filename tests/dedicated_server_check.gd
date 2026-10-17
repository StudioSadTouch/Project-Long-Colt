extends SceneTree
## Dedicated server, end to end: the real `--server` launch plus a client process on this
## machine. Not a *_self_test (it needs the server running). Start the server, then this:
##   flatpak run org.godotengine.Godot --headless --path "<project>" -- --server --server-config res://tests/fixtures/dedicated_test.cfg
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/dedicated_server_check.gd
## Prints "DEDICATED_SERVER_CHECK PASS" or "... FAIL"; the runner then checks the server's log
## (it idles once the client leaves) and stops it.
## Checks: no password and a wrong password are refused with the right reason; the right one
## joins by host NAME ("localhost"); the session carries the server's name; the server is no
## player (not in the registry, no roster entry, no body in the arena); the match starts by
## itself with a bot; the time limit ends it with a game-over; the rotation loads the next map.

const PORT := 7793
const PASSWORD := "letmein"

var _failed: bool = false
var _net: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_net = root.get_node("Net")
	root.get_node("Settings").set(&"player_name", "Tester")
	await _frames(30)
	await _expect_refused("", "Password required")
	await _expect_refused("nope", "Wrong password")
	await _play()
	_net.call(&"leave")
	await _frames(30)
	print("DEDICATED_SERVER_CHECK %s" % ("FAIL" if _failed else "PASS"))
	quit(1 if _failed else 0)


func _expect_refused(password: String, reason: String) -> void:
	var got := [""]
	var on_fail := func(r: String) -> void: got[0] = r
	_net.join_failed.connect(on_fail)
	_net.call(&"join", "localhost", PORT, password)
	for i in 60 * 10:
		if got[0] != "":
			break
		await _frames(1)
	_net.join_failed.disconnect(on_fail)
	_expect(got[0] == reason, "password '%s' refused: %s" % [password, got[0]])
	_net.call(&"leave")
	await _frames(20)


func _play() -> void:
	var joined := [false]
	_net.joined.connect(func() -> void: joined[0] = true, CONNECT_ONE_SHOT)
	_net.call(&"join", "localhost", PORT, PASSWORD)
	for i in 60 * 10:
		if joined[0]:
			break
		await _frames(1)
	_expect(joined[0], "joined by host name with the password")
	if not joined[0]:
		return
	var players: Dictionary = _net.get(&"players")
	_expect(_net.get(&"server_name") == "Test Server", "the session carries the server's name")
	_expect(not players.has(1) and players.size() == 1, "the server is not a player (%s)" % [players.keys()])
	var arena := await _arena(-1)
	if arena == null:
		return
	var first_map: String = _net.get(&"map_id")
	_expect(first_map == "range", "the rotation's first map (%s)" % first_map)
	var net_match := arena.get_node("NetMatch")
	await _frames(60 * 4)
	var roster: Dictionary = net_match.get(&"roster")
	var bots := 0
	for id: int in roster:
		bots += 1 if int(roster[id].get("kind", -1)) == 1 else 0
	_expect(not roster.has(1), "no roster entry for the server")
	_expect(bots >= 1, "the server filled a slot with a bot (%d)" % bots)
	var puppets := arena.find_children("NetPlayer_1", "", true, false)
	_expect(puppets.is_empty(), "no body for the server in the arena")
	var player := net_match.get(&"local_player") as Player
	_expect(player != null and not player.dead, "I'm in the match")
	var over := [""]
	net_match.game_over.connect(func(winner: String, _s: Dictionary) -> void: over[0] = winner)
	for i in 60 * 35:
		if over[0] != "":
			break
		await _frames(1)
	_expect(over[0] != "", "the time limit ends the match (winner: %s)" % over[0])
	var next := await _arena(arena.get_instance_id())
	_expect(next != null and _net.get(&"map_id") == "lockout", "the rotation loads the next map (%s)" % _net.get(&"map_id"))


## The arena once it's loaded (a different scene from `previous` when given).
func _arena(previous: int) -> Node:
	for i in 60 * 30:
		await _frames(1)
		var scene := current_scene
		if scene != null and scene.get_instance_id() != previous and scene.get_node_or_null(^"NetMatch") != null:
			await _frames(10)
			return scene
	_expect(false, "arena loaded")
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
