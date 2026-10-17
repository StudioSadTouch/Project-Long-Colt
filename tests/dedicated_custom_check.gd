extends SceneTree
## Dedicated server on a custom (Level Editor) level from its levels_dir, end to end. Not a
## *_self_test (it needs the server running). Start the server, then this:
##   flatpak run org.godotengine.Godot --headless --path "<project>" -- --server --server-config res://tests/fixtures/dedicated_custom.cfg
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/dedicated_custom_check.gd
## Prints "DEDICATED_CUSTOM_CHECK PASS" or "... FAIL". Checks: this client has no file for the
## level; the server's rotation map is custom:fixture_arena; the match starts and the level
## arrives with it; the custom arena loads with the fixture's walls and centre block; the bot
## spawns; we stand on the level's ground.

const PORT := 7796
const MAP := "custom:fixture_arena"
const ARENA_WAIT := 40.0

var _failed: bool = false
var _net: Node


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_net = root.get_node("Net")
	root.get_node("Settings").set(&"player_name", "Tester")
	_expect(not CustomLevels.exists(MAP), "client: no file for the level")
	await _frames(30)
	var err: int = _net.call(&"join", "localhost", PORT)
	_expect(err == OK, "client: connecting")
	var arena := await _arena()
	if arena != null:
		_expect(str(_net.get(&"map_id")) == MAP, "session map is the custom level")
		_expect(CustomLevels.cache.has(MAP), "the server sent the level")
		_expect(arena is CustomArena, "custom arena loaded")
		var geometry := arena.find_children("*", "LevelGeometry", true, false)
		# 4 walls, block, ramp, plus the settings' ground slab.
		_expect(geometry.size() == 7, "walls, block, ramp and ground (got %d)" % geometry.size())
		var bots := 0
		for i in 60 * 20:
			var roster: Dictionary = arena.get_node("NetMatch").get(&"roster")
			bots = 0
			for id: int in roster:
				bots += 1 if int(roster[id].get("kind", -1)) == 1 else 0
			if bots >= 1:
				break
			await _frames(1)
		_expect(bots >= 1, "the server's bot is in the match (%d)" % bots)
		await _frames(60)
		var player := arena.get_node_or_null(^"Player") as Player
		_expect(player != null and player.global_position.y > -1.0, "standing in the level")
	_net.call(&"leave")
	await _frames(30)
	print("DEDICATED_CUSTOM_CHECK %s" % ("FAIL" if _failed else "PASS"))
	quit(1 if _failed else 0)


func _arena() -> Node:
	for i in int(ARENA_WAIT * 60):
		await _frames(1)
		var scene := current_scene
		if scene != null and scene.get_node_or_null(^"NetMatch") != null:
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
