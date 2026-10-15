extends Node
## Autoload `Settings`: player profile and options, persisted in user://settings.cfg, plus the
## launch request the main menu hands to the arena (mode, difficulty, bot fill).
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

var player_name: String = "Spartan"
var primary_color: Color = PlayerColor.default_color()
var mouse_sensitivity_scale: float = 1.0
var stick_sensitivity_scale: float = 1.0
var mouse_aim_assist: bool = true
## <= 0 = keep the Player scene's fov.
var fov: float = -1.0
var last_join_ip: String = "127.0.0.1"
var bot_difficulty: String = "Normal"
var host_bot_fill: bool = true


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	player_name = sanitize_name(str(cfg.get_value("profile", "name", player_name)))
	var html := str(cfg.get_value("profile", "color", primary_color.to_html(false)))
	primary_color = Color.from_string(html, primary_color)
	mouse_sensitivity_scale = float(cfg.get_value("controls", "mouse_scale", 1.0))
	stick_sensitivity_scale = float(cfg.get_value("controls", "stick_scale", 1.0))
	mouse_aim_assist = bool(cfg.get_value("controls", "mouse_aim_assist", true))
	fov = float(cfg.get_value("video", "fov", -1.0))
	last_join_ip = str(cfg.get_value("net", "last_ip", last_join_ip))
	var diff := str(cfg.get_value("game", "bot_difficulty", bot_difficulty))
	bot_difficulty = diff if DIFFICULTY_PATHS.has(diff) else "Normal"
	host_bot_fill = bool(cfg.get_value("game", "bot_fill", true))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("profile", "name", player_name)
	cfg.set_value("profile", "color", primary_color.to_html(false))
	cfg.set_value("controls", "mouse_scale", mouse_sensitivity_scale)
	cfg.set_value("controls", "stick_scale", stick_sensitivity_scale)
	cfg.set_value("controls", "mouse_aim_assist", mouse_aim_assist)
	cfg.set_value("video", "fov", fov)
	cfg.set_value("net", "last_ip", last_join_ip)
	cfg.set_value("game", "bot_difficulty", bot_difficulty)
	cfg.set_value("game", "bot_fill", host_bot_fill)
	var err := cfg.save(PATH)
	if err != OK:
		push_warning("Settings: could not save %s (%s)" % [PATH, error_string(err)])
	changed.emit()


static func sanitize_name(raw: String) -> String:
	var clean := raw.strip_edges().replace("\n", " ").replace("\t", " ")
	clean = clean.substr(0, NAME_MAX)
	return clean if clean != "" else "Spartan"


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
