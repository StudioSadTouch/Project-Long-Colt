class_name CustomArena
extends Node3D
## The match scene for a custom level (scenes/main/arena_custom.tscn), the counterpart of the
## built-in arena_*.tscn files: it builds the same nodes they have, from the level data, as it
## enters the tree (before any child is ready, so NetMatch and SpawnManager find everything):
##   WorldEnvironment, Sun   the level's settings
##   ArenaEvents
##   Level                   Ground, every object (LevelBuilder, match mode), Spawns/ (the
##                           spawn markers, for SpawnManager), flags and roam points
##   KillFloor               below the level's kill height
##   Player                  at a spawn
##   Navigation              baked from Level (ArenaNavigation)
##   NetMatch, SpawnManager
##   LevelEnemies            the placed enemies, as squads (not under Horde rules; in a match
##                           only if the level allows it, always in a playtest)
## The level comes from CustomLevels.data_for(Net.map_id): the editor's playtest, a level the
## host sent, or the saved file. A level with no spawn markers gets FALLBACK_SPAWNS around the
## origin; a level with no roam points gets one per spawn (bots need somewhere to go).

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const BOT_SCENE := "res://scenes/ai/bot.tscn"
const DIFFICULTY := "res://resources/ai/bot_difficulty_normal.tres"
const EVENTS_SCRIPT := "res://scripts/ai/arena_events.gd"
const NAV_SCRIPT := "res://scripts/ai/arena_navigation.gd"
const NET_MATCH_SCRIPT := "res://scripts/net/net_match.gd"
const SPAWNS_SCRIPT := "res://scripts/ai/spawn_manager.gd"
const FALLBACK_SPAWNS := 6

var level: Dictionary = {}
var level_root: Node3D
var player: Player
var spawn_manager: SpawnManager
var level_enemies: LevelEnemies

var _built: bool = false
var _playtest: bool = false


func _enter_tree() -> void:
	if _built:
		return
	_built = true
	var net := get_node_or_null(^"/root/Net")
	var map_id := str(net.get(&"map_id")) if net != null else CustomLevels.PLAYTEST_ID
	var rules := str(net.get(&"rules_id")) if net != null else GameModes.DEFAULT_ID
	level = CustomLevels.data_for(map_id)
	if level.is_empty():
		push_error("CustomArena: no level for map '%s'" % map_id)
		level = LevelData.new_level("Missing level")
	name = "ArenaCustom"
	build(level, rules, CustomLevels.playtest_active and map_id == CustomLevels.PLAYTEST_ID)


## Builds the arena's nodes for `data` under `rules` (GameModes id).
func build(data: Dictionary, rules: String, playtest: bool) -> void:
	var settings := LevelData.settings_of(data)
	LevelWorld.add_environment(self, settings)
	var events := Node.new()
	events.name = "ArenaEvents"
	events.set_script(load(EVENTS_SCRIPT))
	add_child(events)

	level_root = Node3D.new()
	level_root.name = "Level"
	add_child(level_root)
	LevelWorld.add_ground(level_root, settings)
	var spawns := Node3D.new()
	spawns.name = "Spawns"
	level_root.add_child(spawns)
	var enemy_markers: Array[Dictionary] = []
	var roam_count := 0
	for entry: Dictionary in data.get("objects", []):
		var node := LevelBuilder.build(entry, false)
		if node == null:
			continue
		var scale := node.scale
		node.transform = LevelData.transform_of(entry)
		node.scale = scale
		if node.has_meta(&"enemy_type"):
			var type := load(str(node.get_meta(&"enemy_type"))) as EnemyType
			if type != null:
				enemy_markers.append({"type": type, "xform": node.transform})
			node.free()
			continue
		if node.is_in_group(&"ai_roam_point"):
			roam_count += 1
		var is_spawn := str(node.name).begins_with("SPAWN_")
		(spawns if is_spawn else level_root).add_child(node, true)
	if spawns.get_child_count() == 0:
		_add_fallback_spawns(spawns)
	if roam_count == 0:
		for spawn in spawns.get_children():
			var roam := Marker3D.new()
			roam.name = "Roam_%s" % spawn.name
			roam.add_to_group(&"ai_roam_point", true)
			roam.set_meta(&"weight", 1.0)
			roam.transform = (spawn as Node3D).transform
			level_root.add_child(roam, true)
	LevelWorld.add_kill_floor(self, settings)

	player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
	player.name = "Player"
	var first := spawns.get_child(0) as Node3D
	player.transform = Transform3D(Basis(Vector3.UP, first.rotation.y), first.position + Vector3.UP * 0.05)
	add_child(player)

	var nav := NavigationRegion3D.new()
	nav.name = "Navigation"
	nav.set_script(load(NAV_SCRIPT))
	nav.set(&"geometry_root", ^"../Level")
	add_child(nav)

	var net_match := Node.new()
	net_match.name = "NetMatch"
	net_match.set_script(load(NET_MATCH_SCRIPT))
	add_child(net_match)

	var manager := Node.new()
	manager.set_script(load(SPAWNS_SCRIPT))
	spawn_manager = manager as SpawnManager
	spawn_manager.name = "SpawnManager"
	spawn_manager.bot_scene = load(BOT_SCENE) as PackedScene
	spawn_manager.difficulty = load(DIFFICULTY) as BotDifficulty
	spawn_manager.bot_count = 3
	spawn_manager.spawn_roots = [^"../Level/Spawns"]
	add_child(spawn_manager)
	_playtest = playtest

	var wants_enemies := playtest or bool(settings.enemies_in_matches)
	if not enemy_markers.is_empty() and wants_enemies and not GameModes.is_horde(rules):
		level_enemies = LevelEnemies.new()
		level_enemies.name = "LevelEnemies"
		level_enemies.markers = enemy_markers
		level_enemies.respawn_time = float(settings.get("enemy_respawn", 60.0))
		level_enemies.net_match = net_match
		level_enemies.spawn_manager = spawn_manager
		add_child(level_enemies)

	var graph: Array = data.get("event_graph", [])
	if not graph.is_empty():
		var event_mgr := EventManager.new()
		event_mgr.connections = graph
		event_mgr.bind_graph(self)


## Playtest: the bot count the editor asked for. Children are ready by now: NetMatch has set
## the menu's count, and SpawnManager only spawns after the navmesh bake, so this lands in time.
func _ready() -> void:
	if not _playtest or spawn_manager == null:
		return
	var net := get_node_or_null(^"/root/Net")
	var rules := str(net.get(&"rules_id")) if net != null else GameModes.DEFAULT_ID
	spawn_manager.bot_count = CustomLevels.playtest_bots if GameModes.allows_bots(rules) else 0
	if CustomLevels.playtest_start is Transform3D and not spawn_manager.is_team_mode():
		player.global_transform = CustomLevels.playtest_start


func _add_fallback_spawns(spawns: Node3D) -> void:
	for i in FALLBACK_SPAWNS:
		var angle := TAU * i / FALLBACK_SPAWNS
		var marker := Marker3D.new()
		marker.name = "SPAWN_FFA_fallback%d" % i
		marker.position = Vector3(cos(angle), 0.0, sin(angle)) * 6.0
		marker.rotation.y = PI * 0.5 - angle  # facing the middle
		spawns.add_child(marker)
