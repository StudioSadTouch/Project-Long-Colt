extends Node
## Autoload `Settings`: player profile and options, persisted in user://settings.cfg, plus the
## launch request the main menu hands to the arena (map, player count, bot count, mode, difficulty, bot fill).
## Tuning stays in the scenes: sensitivities are MULTIPLIERS on the Player's exported values
## (1.0 = the scene's tuning) and FOV is only applied once the player has changed it.

signal changed

const PATH := "user://settings.cfg"
const DIFFICULTIES: Array[String] = ["Easy", "Normal", "Heroic", "Legendary"]
const DIFFICULTY_PATHS := {
	"Easy": "res://resources/ai/bot_difficulty_easy.tres",
	"Normal": "res://resources/ai/bot_difficulty_normal.tres",
	"Heroic": "res://resources/ai/bot_difficulty_heroic.tres",
	"Legendary": "res://resources/ai/bot_difficulty_legendary.tres",
}
const NAME_MAX := 16
const FOV_MIN := 60.0
const FOV_MAX := 110.0
## Recent servers kept for the Join list.
const RECENT_MAX := 8

var player_name: String = "Spartan"
var primary_color: Color = PlayerColor.default_color()
var visor_color: Color = PlayerColor.default_visor()
## Shoulder accent (left pauldron + helmet stripe).
var accent_color: Color = PlayerColor.default_accent()
var mouse_sensitivity_scale: float = 1.0
var stick_sensitivity_scale: float = 1.0
var mouse_aim_assist: bool = true
## <= 0 = keep the Player scene's fov.
var fov: float = -1.0
## GUI scaling factor (0.75x to 1.50x).
const GUI_SCALE_MIN := 0.75
const GUI_SCALE_MAX := 1.50
const GUI_SCALE_STEP := 0.05
var gui_scale: float = 1.0:
	set(val):
		gui_scale = clampf(val, GUI_SCALE_MIN, GUI_SCALE_MAX)
		apply_gui_scale()
## Over-the-shoulder camera (ThirdPersonCamera) instead of first person; which shoulder.
var third_person: bool = false
var left_shoulder: bool = false
## Exclusive fullscreen vs a window (F11 / action_fullscreen toggles it anywhere).
var fullscreen: bool = false
## Last address typed in Join ("host" or "host:port"; an IP or a domain).
var last_join_ip: String = "127.0.0.1"
## Join list: servers joined recently (newest first) and starred ones, as "host:port".
var recent_servers: Array[String] = []
var favorite_servers: Array[String] = []
## Listen host: the game port, and whether to ask the router to forward it (UPnP).
var host_port: int = 7777
var host_upnp: bool = false
var bot_difficulty: String = "Normal"
## Last map picked in the menu (MapList id); Bot Arena plays it and a new LAN host starts on it.
var map_id: String = MapList.DEFAULT_ID
## Last player-count / team setup (GameMode id): FFA, Team Slayer 4v4, or Team Slayer 8v8.
var mode_id: String = GameMode.DEFAULT_ID
## Last rules variant (GameModes id): Slayer or SWAT.
var rules_id: String = GameModes.DEFAULT_ID
## How many bots to spawn. A smaller mode uses fewer and does not lower this. Default fills 8v8.
var bot_count: int = GameMode.MAX_PLAYERS_ANY - 1
var host_bot_fill: bool = true
## Host: replace a human who leaves mid-match with a bot (Morgon: off unless the host opts in).
var host_bot_refill: bool = false
## Music bus level, 0..1. The Music autoload still ducks this during a live match.
var music_volume: float = 0.8


func _ready() -> void:
	load_settings()
	apply_music_volume()
	apply_display()
	apply_gui_scale()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"action_fullscreen"):
		fullscreen = not fullscreen
		apply_display()
		save_settings()
		get_viewport().set_input_as_handled()


## Window mode from `fullscreen` (no-op headless).
func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != want:
		DisplayServer.window_set_mode(want)


## Applies GUI content scale factor across the window.
func apply_gui_scale() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var win := get_window()
	if win != null:
		win.content_scale_factor = gui_scale


func load_settings() -> void:
	# Before any saved binding is applied, so "reset" always means project.godot.
	Keybinds.capture_defaults()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	player_name = sanitize_name(str(cfg.get_value("profile", "name", player_name)))
	var html := str(cfg.get_value("profile", "color", primary_color.to_html(false)))
	primary_color = Color.from_string(html, primary_color)
	var visor_html := str(cfg.get_value("profile", "visor", visor_color.to_html(false)))
	visor_color = Color.from_string(visor_html, visor_color)
	var accent_html := str(cfg.get_value("profile", "accent", accent_color.to_html(false)))
	accent_color = Color.from_string(accent_html, accent_color)
	mouse_sensitivity_scale = float(cfg.get_value("controls", "mouse_scale", 1.0))
	stick_sensitivity_scale = float(cfg.get_value("controls", "stick_scale", 1.0))
	mouse_aim_assist = bool(cfg.get_value("controls", "mouse_aim_assist", true))
	fov = float(cfg.get_value("video", "fov", -1.0))
	third_person = bool(cfg.get_value("video", "third_person", false))
	left_shoulder = bool(cfg.get_value("video", "left_shoulder", false))
	fullscreen = bool(cfg.get_value("video", "fullscreen", false))
	gui_scale = clampf(float(cfg.get_value("video", "gui_scale", 1.0)), GUI_SCALE_MIN, GUI_SCALE_MAX)
	apply_gui_scale()
	last_join_ip = str(cfg.get_value("net", "last_ip", last_join_ip))
	recent_servers = _string_list(cfg.get_value("net", "recent", []), RECENT_MAX)
	favorite_servers = _string_list(cfg.get_value("net", "favorites", []), 64)
	host_port = clampi(int(cfg.get_value("net", "host_port", host_port)), 1, 65535)
	host_upnp = bool(cfg.get_value("net", "host_upnp", host_upnp))
	var diff := str(cfg.get_value("game", "bot_difficulty", bot_difficulty))
	bot_difficulty = diff if DIFFICULTY_PATHS.has(diff) else "Normal"
	map_id = MapList.sanitize(str(cfg.get_value("game", "map", map_id)))
	mode_id = GameMode.sanitize(str(cfg.get_value("game", "mode", mode_id)))
	rules_id = GameModes.sanitize(str(cfg.get_value("game", "rules", rules_id)))
	bot_count = clampi(
		int(cfg.get_value("game", "bot_count", bot_count)), 0, GameMode.MAX_PLAYERS_ANY - 1
	)
	host_bot_fill = bool(cfg.get_value("game", "bot_fill", true))
	host_bot_refill = bool(cfg.get_value("game", "bot_refill", false))
	music_volume = clampf(float(cfg.get_value("audio", "music", music_volume)), 0.0, 1.0)
	var saved_binds := {}
	if cfg.has_section("keybinds"):
		for action: String in cfg.get_section_keys("keybinds"):
			saved_binds[action] = cfg.get_value("keybinds", action, [])
	Keybinds.apply(saved_binds)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "color", primary_color.to_html(false))
	cfg.set_value("profile", "visor", visor_color.to_html(false))
	cfg.set_value("profile", "accent", accent_color.to_html(false))
	cfg.set_value("controls", "mouse_scale", mouse_sensitivity_scale)
	cfg.set_value("controls", "stick_scale", stick_sensitivity_scale)
	cfg.set_value("controls", "mouse_aim_assist", mouse_aim_assist)
	cfg.set_value("video", "fov", fov)
	cfg.set_value("video", "third_person", third_person)
	cfg.set_value("video", "left_shoulder", left_shoulder)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("video", "gui_scale", gui_scale)
	cfg.set_value("net", "last_ip", last_join_ip)
	cfg.set_value("net", "recent", recent_servers)
	cfg.set_value("net", "favorites", favorite_servers)
	cfg.set_value("net", "host_port", host_port)
	cfg.set_value("net", "host_upnp", host_upnp)
	cfg.set_value("game", "bot_difficulty", bot_difficulty)
	cfg.set_value("game", "map", map_id)
	cfg.set_value("game", "mode", mode_id)
	cfg.set_value("game", "rules", rules_id)
	cfg.set_value("game", "bot_count", bot_count)
	cfg.set_value("game", "bot_fill", host_bot_fill)
	cfg.set_value("game", "bot_refill", host_bot_refill)
	cfg.set_value("audio", "music", music_volume)
	# Only bindings that differ from project.godot, so new defaults reach existing players.
	var binds := Keybinds.overrides()
	for action: String in binds:
		cfg.set_value("keybinds", action, binds[action])
	var err := cfg.save(PATH)
	if err != OK:
		push_warning("Settings: could not save %s (%s)" % [PATH, error_string(err)])
	changed.emit()


## User mix for the Music bus. 0 mutes. Match ducking is the player's own volume_db.
func apply_music_volume() -> void:
	var idx := AudioServer.get_bus_index(&"Music")
	if idx < 0:
		return
	var linear := clampf(music_volume, 0.0, 1.0)
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))


static func sanitize_name(raw: String) -> String:
	var clean := raw.strip_edges().replace("\n", " ").replace("\t", " ")
	clean = clean.substr(0, NAME_MAX)
	return clean if clean != "" else "Spartan"


## Bots that fit in `slots` empty seats. The saved number is a cap, so switching from 8v8
## back to FFA or 4v4 still restores a higher count.
## A server we just joined goes to the top of the recent list ("host:port").
func remember_server(address: String) -> void:
	recent_servers.erase(address)
	recent_servers.push_front(address)
	if recent_servers.size() > RECENT_MAX:
		recent_servers.resize(RECENT_MAX)


## Stars or unstars a server; returns whether it is now a favorite.
func toggle_favorite(address: String) -> bool:
	if favorite_servers.has(address):
		favorite_servers.erase(address)
		return false
	favorite_servers.append(address)
	return true


func is_favorite(address: String) -> bool:
	return favorite_servers.has(address)


static func _string_list(value: Variant, limit: int) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for item: Variant in value:
			var text := str(item).strip_edges()
			if text != "" and not out.has(text) and out.size() < limit:
				out.append(text)
	return out


func bot_count_for(slots: int) -> int:
	var asked := clampi(bot_count, 0, GameMode.MAX_PLAYERS_ANY - 1)
	return mini(asked, maxi(slots, 0))


func get_difficulty() -> BotDifficulty:
	var path: String = DIFFICULTY_PATHS.get(bot_difficulty, DIFFICULTY_PATHS["Normal"])
	return load(path) as BotDifficulty


## Applies options to a local Player (call once after it is ready). Base values are read from
## the player the first time and stored as meta, so re-applying never compounds.
func apply_to_player(player: Player) -> void:
	if player == null:
		return
	if not player.has_meta(&"base_mouse_sensitivity"):
		player.set_meta(&"base_mouse_sensitivity", player.mouse_sensitivity)
		player.set_meta(&"base_stick_yaw", player.stick_yaw_speed)
		player.set_meta(&"base_stick_pitch", player.stick_pitch_speed)
	player.mouse_sensitivity = (
		float(player.get_meta(&"base_mouse_sensitivity")) * mouse_sensitivity_scale
	)
	player.stick_yaw_speed = float(player.get_meta(&"base_stick_yaw")) * stick_sensitivity_scale
	player.stick_pitch_speed = (
		float(player.get_meta(&"base_stick_pitch")) * stick_sensitivity_scale
	)
	if fov > 0.0:
		player.fov = clampf(fov, FOV_MIN, FOV_MAX)
		if player.camera != null:
			player.camera.fov = player.fov
	var aim := player.get_node_or_null(^"AimAssist") as AimAssist
	if aim != null:
		aim.mouse_enabled = mouse_aim_assist
	var view := player.get_node_or_null(^"ThirdPersonCamera") as ThirdPersonCamera
	if view != null:
		view.enabled = third_person
		view.left_shoulder = left_shoulder
