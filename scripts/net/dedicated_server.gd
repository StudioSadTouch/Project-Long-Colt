class_name DedicatedServer
extends Node
## Headless dedicated server. Net adds it (as Net/DedicatedServer) when the game is launched
## with `--server`; it reads the config, opens the server with no local player, and runs the
## match rotation for whoever joins. Launch (Linux build; docs/net/servers.md, tools/server/):
##   "Project Long Colt.x86_64" --headless -- --server --server-config /srv/longcolt/server.cfg
## Without --server-config it uses user://server.cfg, writing the example there first.
##
## Lifecycle (logged to stdout with a [Server] prefix, for `docker logs`):
##   IDLE          nobody connected: an empty scene, nothing simulated.
##   COUNTDOWN     someone joined: start_delay seconds, then the current rotation entry.
##   MATCH         the arena runs. Ends at the mode's own win, or at the entry's time limit
##                 (NetMatch.end_match with whoever leads).
##   INTERMISSION  the game-over screen for next_delay seconds, then the next entry (looping).
## Everyone leaving at any point drops back to IDLE; the next joiner starts a fresh countdown.
## Bot count and difficulty come from the config (set on Settings in memory, never saved).

enum Phase { IDLE, COUNTDOWN, MATCH, INTERMISSION }

const ARG := "--server"
const CONFIG_ARG := "--server-config"
const DEFAULT_CONFIG := "user://server.cfg"
const IDLE_SCENE := "res://scenes/net/server_idle.tscn"
const PHASE_NAMES := ["IDLE", "COUNTDOWN", "MATCH", "INTERMISSION"]

var config: ServerConfig
var phase: Phase = Phase.IDLE
## Rotation index of the current (or next) match.
var index: int = 0
var time_left: float = 0.0
var match_time: float = 0.0
var config_path: String = DEFAULT_CONFIG

var _net_match: Node
var _match_scene_id: int = 0


## True when the game was launched as a dedicated server.
static func requested() -> bool:
	return OS.get_cmdline_user_args().has(ARG) or OS.get_cmdline_args().has(ARG)


## The --server-config path (`--server-config path` or `--server-config=path`).
static func requested_config() -> String:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	for i in args.size():
		var arg := args[i]
		if arg.begins_with(CONFIG_ARG + "="):
			return arg.substr(CONFIG_ARG.length() + 1)
		if arg == CONFIG_ARG and i + 1 < args.size():
			return args[i + 1]
	return DEFAULT_CONFIG


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start.call_deferred()


func _start() -> void:
	config_path = requested_config()
	if not FileAccess.file_exists(config_path):
		var file := FileAccess.open(config_path, FileAccess.WRITE)
		if file != null:
			file.store_string(ServerConfig.EXAMPLE)
			file.close()
			_log("no config at %s: wrote the example there (edit it and restart)" % config_path)
	config = ServerConfig.load_file(config_path)
	for warning in config.warnings:
		_log("config: %s" % warning)
	var settings := get_node(^"/root/Settings")
	settings.set(&"bot_count", config.bot_count)
	settings.set(&"bot_difficulty", config.bot_difficulty)
	var net := get_parent()
	var err: int = net.call(&"host_dedicated", config)
	if err != OK:
		_log("could not open UDP port %d: %s" % [config.port, error_string(err)])
		get_tree().quit(1)
		return
	var upnp: NetUpnp = net.get(&"upnp")
	if upnp != null:
		upnp.changed.connect(func(_s: NetUpnp.State, text: String) -> void:
			if text != "":
				_log(text))
	_log(
		(
			"'%s' listening on UDP %d%s, %d match(es) in the rotation"
			% [
				config.server_name,
				config.port,
				" (password)" if config.password != "" else "",
				config.rotation.size(),
			]
		)
	)
	_to_idle()


func _process(delta: float) -> void:
	if config == null:
		return
	var humans := _humans()
	match phase:
		Phase.IDLE:
			if humans > 0:
				phase = Phase.COUNTDOWN
				time_left = config.start_delay
				_log("starting in %.0f s: %s" % [time_left, _describe(index)])
		Phase.COUNTDOWN:
			if humans == 0:
				_to_idle()
				return
			time_left -= delta
			if time_left <= 0.0:
				_start_match()
		Phase.MATCH:
			if humans == 0:
				_log("everyone left: back to idle")
				_to_idle()
				return
			_find_net_match()
			match_time += delta
			var limit: float = config.rotation[index].time_limit
			if limit > 0.0 and match_time >= limit and _net_match != null:
				_log("time limit reached")
				_net_match.call(&"end_match", _leader(), _net_match.get(&"scores"))
		Phase.INTERMISSION:
			if humans == 0:
				_to_idle()
				return
			time_left -= delta
			if time_left <= 0.0:
				index = (index + 1) % config.rotation.size()
				_start_match()


func get_phase_name() -> String:
	return PHASE_NAMES[phase]


func _start_match() -> void:
	var entry: Dictionary = config.rotation[index]
	var net := get_parent()
	net.set(&"map_id", entry.map)
	net.set(&"mode_id", entry.mode)
	net.set(&"rules_id", entry.rules)
	phase = Phase.MATCH
	match_time = 0.0
	_net_match = null
	_match_scene_id = 0
	_log("match %d/%d: %s" % [index + 1, config.rotation.size(), _describe(index)])
	net.call(&"start_match")


## The arena's NetMatch once the new scene is in (start_match loads it deferred).
func _find_net_match() -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.get_instance_id() == _match_scene_id:
		return
	var net_match := scene.get_node_or_null(^"NetMatch")
	if net_match == null:
		return
	_match_scene_id = scene.get_instance_id()
	_net_match = net_match
	net_match.connect(&"game_over", _on_game_over)


func _on_game_over(winner: String, _scores: Dictionary) -> void:
	if phase != Phase.MATCH:
		return
	_log("game over: %s wins. Next in %.0f s: %s" % [
		winner, config.next_delay, _describe((index + 1) % config.rotation.size())
	])
	phase = Phase.INTERMISSION
	time_left = config.next_delay


func _to_idle() -> void:
	phase = Phase.IDLE
	_net_match = null
	_match_scene_id = 0
	get_parent().set(&"match_running", false)
	get_tree().change_scene_to_file.call_deferred(IDLE_SCENE)


func _humans() -> int:
	var players: Dictionary = get_parent().get(&"players")
	return players.size()


## Who leads when a time limit ends the match: captures (CTF), team kills (team modes), the
## defenders (Horde, still standing), else the top fragger.
func _leader() -> String:
	if _net_match == null:
		return "Nobody"
	var rules: String = get_parent().get(&"rules_id")
	if GameModes.is_horde(rules):
		return "The defenders"
	var ctf := _net_match.get_node_or_null(^"Ctf") as CtfMatch
	if ctf != null:
		return _best_team(ctf.captures)
	var scores: Dictionary = _net_match.get(&"scores")
	if GameMode.is_team(get_parent().get(&"mode_id")):
		return _best_team(GameMode.team_totals(scores))
	var best := "Nobody"
	var best_kills := -1
	for who: String in scores:
		var kills := int(scores[who].get("kills", 0))
		if kills > best_kills:
			best_kills = kills
			best = who
	return best


static func _best_team(totals: Dictionary) -> String:
	var best := -1
	var best_score := -1
	var tied := false
	for team: int in totals:
		var score := int(totals[team])
		if score > best_score:
			best_score = score
			best = team
			tied = false
		elif score == best_score:
			tied = true
	if best < 0 or tied:
		return "Nobody (draw)"
	return GameMode.team_name(best)


func _describe(i: int) -> String:
	var entry: Dictionary = config.rotation[i]
	var limit := ""
	var seconds := float(entry.time_limit)
	if seconds >= 60.0:
		limit = ", %.0f min" % (seconds / 60.0)
	elif seconds > 0.0:
		limit = ", %.0f s" % seconds
	return "%s - %s - %s%s" % [
		MapList.name_of(entry.map), GameMode.name_of(entry.mode), GameModes.name_of(entry.rules),
		limit
	]


func _log(text: String) -> void:
	print("[Server %s] %s" % [Time.get_time_string_from_system(), text])
