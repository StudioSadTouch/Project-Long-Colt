extends SceneTree
## A Level Editor custom level over LAN, end to end, as two real processes on this machine (localhost
## ENet). Not a *_self_test: it needs both roles running at once. Run the host first, then the
## client:
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/custom_map_lan_check.gd -- host
##   flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/custom_map_lan_check.gd -- client
## Each prints "CUSTOM_LAN_<ROLE> PASS" or "... FAIL" and exits.
## Host: saves a level into a folder only it reads (LevelData.add_dir), so the client can't load
## it from disk; hosts Slayer on it with the level's placed enemies on; starts the match once the
## client joins; checks the arena and the enemies; waits for the client to finish.
## Client: has no file for the level; joins; the host's level arrives (CustomLevels.cache), the
## custom arena loads with the same objects, its player stands on the level's floor, and the
## placed enemies appear as copies.

const PORT := 7795
const ARENA_WAIT := 30.0
const LEVEL_NAME := "lan_check_level"
const HOST_DIR := "user://custom_lan_check_host/"

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
	_settings.set(&"bot_count", 0)
	if _role == "client":
		await _client()
	else:
		await _host()
	_net.call(&"leave")
	var tag := "CUSTOM_LAN_%s" % _role.to_upper()
	print("%s %s" % [tag, "FAIL" if _failed else "PASS"])
	quit(1 if _failed else 0)


static func level() -> Dictionary:
	var data := LevelData.new_level(LEVEL_NAME)
	data.settings.enemies_in_matches = true
	data.settings.enemy_respawn = 0.0
	data.settings.ground = false
	var objects: Array = [
		{"catalog_id": "geo_floor", "pos": [0, -0.2, 0], "size": [40, 0.2, 40]},
		{"catalog_id": "geo_wall", "pos": [0, 0, -6], "size": [8, 3, 0.4]},
		{"catalog_id": "geo_stairs", "pos": [6, 0, 4]},
		{"catalog_id": "spawn_ffa", "pos": [0, 0, 10]},
		{"catalog_id": "spawn_ffa", "pos": [4, 0, 10]},
		{"catalog_id": "weapon:res://scenes/weapons/combat_shotgun.tscn", "pos": [-3, 0, 6]},
		{"catalog_id": "enemy:nefer", "pos": [-6, 0, -14]},
		{"catalog_id": "enemy:nefer", "pos": [-3, 0, -14]},
	]
	var uid := 1
	for entry: Dictionary in objects:
		entry["uid"] = uid
		uid += 1
	data.objects = objects
	data.next_uid = uid
	return data


# ------------------------------------------------------------------ host


func _host() -> void:
	DirAccess.make_dir_recursive_absolute(HOST_DIR)
	var file := FileAccess.open(HOST_DIR + LEVEL_NAME + LevelData.EXTENSION, FileAccess.WRITE)
	file.store_string(JSON.stringify(level()))
	file.close()
	LevelData.add_dir(HOST_DIR)
	var map_id := CustomLevels.map_id(LEVEL_NAME)
	_expect(MapList.has(map_id), "host: the level is a map")
	_settings.set(&"player_name", "Host")
	var err: int = _net.call(&"host", PORT, false, false, map_id, "ffa", "slayer")
	_expect(err == OK, "host: server up")
	_expect(str(_net.get(&"map_id")) == map_id, "host: session on the custom map")
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
	_expect(arena is CustomArena, "host: custom arena loaded")
	var enemies := arena.get_node_or_null(^"LevelEnemies") as LevelEnemies
	_expect(enemies != null, "host: placed enemies node")
	for i in 60 * 15:
		if enemies != null and enemies.living().size() >= 2:
			break
		await _frames(1)
	_expect(enemies != null and enemies.living().size() == 2, "host: 2 placed enemies spawned")
	# Keep everyone alive while the client looks around (enemies would end it early).
	for e in enemies.living() if enemies != null else []:
		e.process_mode = Node.PROCESS_MODE_DISABLED
	for i in 60 * 25:
		if (_net.get(&"players") as Dictionary).size() < 2:
			break
		await _frames(1)
	DirAccess.remove_absolute(HOST_DIR + LEVEL_NAME + LevelData.EXTENSION)
	DirAccess.remove_absolute(HOST_DIR)


# ------------------------------------------------------------------ client


func _client() -> void:
	_settings.set(&"player_name", "Client")
	var map_id := CustomLevels.map_id(LEVEL_NAME)
	_expect(LevelData.path_of(LEVEL_NAME) == "", "client: has no file for the level")
	await _frames(60)
	var err: int = _net.call(&"join", "127.0.0.1", PORT)
	_expect(err == OK, "client: connecting")
	var arena := await _arena()
	if arena == null:
		return
	_expect(str(_net.get(&"map_id")) == map_id, "client: session map is the custom level")
	_expect(CustomLevels.cache.has(map_id), "client: the host's level arrived")
	_expect(arena is CustomArena, "client: custom arena loaded")
	var geometry := arena.find_children("*", "LevelGeometry", true, false)
	_expect(geometry.size() == 3, "client: the level's 3 geometry pieces (got %d)" % geometry.size())
	var pickups := arena.find_children("*", "WeaponPickup", true, false)
	_expect(pickups.size() == 1, "client: the shotgun pickup")
	var copies: Dictionary = {}
	for i in 60 * 15:
		var net_enemies := arena.get_node_or_null(^"LevelEnemies/Enemies") as NetEnemies
		if net_enemies != null:
			copies = net_enemies.copies
		if copies.size() >= 2:
			break
		await _frames(1)
	_expect(copies.size() == 2, "client: the placed enemies appear as copies (%d)" % copies.size())
	await _frames(90)
	var player := arena.get_node_or_null(^"Player") as Player
	_expect(player != null and player.is_on_floor(), "client: standing on the level's floor")
	_expect(player != null and player.global_position.y > -1.0, "client: not falling (y %.2f)" % (player.global_position.y if player else 0.0))


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
