class_name ServerConfig
extends RefCounted
## Dedicated server settings, read from an INI-style file (Godot ConfigFile). Example: EXAMPLE
## below, also written to tools/server/server.cfg.example; DedicatedServer writes it to the
## config path when the file doesn't exist yet. Unknown map / mode / rules ids are reported in
## `warnings` and fall back to the defaults, so a typo never stops the server.
##   [server]   name, port, password ("" = open), levels_dir (a folder of custom levels:
##              rotation maps "custom:<file name>"), upnp (forward the port through the router),
##              lan_beacon (also list it on the LAN), start_delay (seconds from the first
##              player joining to the first match), next_delay (seconds of game over before the
##              next match)
##   [bots]     fill (fill empty slots with bots), count, difficulty (Easy / Normal / Heroic /
##              Legendary)
##   [match_*]  one section per rotation entry, played in name order: map (MapList id), mode
##              (GameMode id: player count / teams), rules (GameModes id), time_limit_minutes
##              (0 = until the mode's own win)

const EXAMPLE := """; Project Long Colt dedicated server. Run the Linux build headless:
;   "Project Long Colt.x86_64" --headless -- --server --server-config /path/to/server.cfg
; Players join with the server's address (IP or domain) and port, e.g. longcolt.example.com:7777.
; Forward UDP <port> on your router (or set upnp=true) to let players in from the internet.

[server]
name="Long Colt Server"
port=7777
password=""
upnp=false
lan_beacon=true
start_delay=10.0
next_delay=15.0
; Custom levels (Level Editor .json files) for the rotation, as map="custom:<file name>".
; Players don't need them: the server sends each level when its match starts.
levels_dir=""

[bots]
fill=true
count=3
difficulty="Normal"

; The rotation: one [match_N] per match, played in order, then it loops.
; maps: lockout, headlong, ivory_tower, zanzibar, kamino, range, custom:<level file name>
; modes: ffa, team_4v4, team_slayer      rules: slayer, swat, ctf, horde, range
[match_1]
map="lockout"
mode="ffa"
rules="slayer"
time_limit_minutes=15.0

[match_2]
map="zanzibar"
mode="team_4v4"
rules="ctf"
time_limit_minutes=20.0

[match_3]
map="headlong"
mode="ffa"
rules="horde"
time_limit_minutes=0.0
"""

## Settings.DIFFICULTIES, repeated: autoloads aren't compile-time names in --script tests.
const DIFFICULTIES: Array[String] = ["Easy", "Normal", "Heroic", "Legendary"]

var server_name: String = "Long Colt Server"
var port: int = 7777
var password: String = ""
var upnp: bool = false
var lan_beacon: bool = true
var start_delay: float = 10.0
var next_delay: float = 15.0
var bot_fill: bool = true
var bot_count: int = 3
var bot_difficulty: String = "Normal"
## Extra folder of custom levels (Level Editor .json files) the rotation can name as custom:<name>.
var levels_dir: String = ""
## [{"map", "mode", "rules", "time_limit"}] (time_limit in seconds, 0 = none).
var rotation: Array[Dictionary] = []
var warnings: Array[String] = []


static func load_file(path: String) -> ServerConfig:
	var cfg := ConfigFile.new()
	var config := ServerConfig.new()
	var err := cfg.load(path)
	if err != OK:
		config.warnings.append("Could not read %s (%s): using defaults" % [path, error_string(err)])
		config._default_rotation()
		return config
	config._read(cfg)
	return config


static func parse_text(text: String) -> ServerConfig:
	var cfg := ConfigFile.new()
	var config := ServerConfig.new()
	var err := cfg.parse(text)
	if err != OK:
		config.warnings.append("Could not parse the config (%s): using defaults" % error_string(err))
		config._default_rotation()
		return config
	config._read(cfg)
	return config


func _read(cfg: ConfigFile) -> void:
	levels_dir = str(cfg.get_value("server", "levels_dir", levels_dir)).strip_edges()
	if levels_dir != "":
		# Before the rotation is read, so its custom:<name> maps are known.
		if DirAccess.dir_exists_absolute(levels_dir):
			LevelData.add_dir(levels_dir)
		else:
			warnings.append("levels_dir '%s' does not exist" % levels_dir)
	server_name = str(cfg.get_value("server", "name", server_name)).strip_edges().left(40)
	if server_name == "":
		server_name = "Long Colt Server"
	port = int(cfg.get_value("server", "port", port))
	if port < NetAddress.PORT_MIN or port > NetAddress.PORT_MAX:
		warnings.append("port %d is out of range: using 7777" % port)
		port = 7777
	password = str(cfg.get_value("server", "password", password))
	upnp = bool(cfg.get_value("server", "upnp", upnp))
	lan_beacon = bool(cfg.get_value("server", "lan_beacon", lan_beacon))
	start_delay = maxf(float(cfg.get_value("server", "start_delay", start_delay)), 0.0)
	next_delay = maxf(float(cfg.get_value("server", "next_delay", next_delay)), 0.0)
	bot_fill = bool(cfg.get_value("bots", "fill", bot_fill))
	var count := int(cfg.get_value("bots", "count", bot_count))
	bot_count = clampi(count, 0, GameMode.MAX_PLAYERS_ANY - 1)
	if bot_count != count:
		warnings.append("bots.count %d is out of range: using %d" % [count, bot_count])
	var difficulty := str(cfg.get_value("bots", "difficulty", bot_difficulty))
	if DIFFICULTIES.has(difficulty):
		bot_difficulty = difficulty
	else:
		warnings.append("bots.difficulty '%s' is unknown: using Normal" % difficulty)
	var raw_sections: Array = Array(cfg.get_sections())
	var sections: Array = raw_sections.filter(func(s: String) -> bool: return s.begins_with("match"))
	sections.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for section: String in sections:
		rotation.append(_read_match(cfg, section))
	if rotation.is_empty():
		warnings.append("no [match_N] sections: playing Lockout, Free for All, Slayer")
		_default_rotation()


func _read_match(cfg: ConfigFile, section: String) -> Dictionary:
	var map := str(cfg.get_value(section, "map", MapList.DEFAULT_ID))
	var mode := str(cfg.get_value(section, "mode", GameMode.DEFAULT_ID))
	var rules := str(cfg.get_value(section, "rules", GameModes.DEFAULT_ID))
	if not MapList.has(map):
		warnings.append("[%s] map '%s' is unknown: using %s" % [section, map, MapList.DEFAULT_ID])
	if not GameMode.has(mode):
		warnings.append("[%s] mode '%s' is unknown: using %s" % [section, mode, GameMode.DEFAULT_ID])
	if not GameModes.has(rules):
		warnings.append("[%s] rules '%s' is unknown: using %s" % [section, rules, GameModes.DEFAULT_ID])
	rules = GameModes.sanitize(rules)
	if not GameModes.allows_online(rules):
		warnings.append(
			"[%s] rules '%s' are offline only: using %s" % [section, rules, GameModes.DEFAULT_ID]
		)
		rules = GameModes.DEFAULT_ID
	var fitted := GameModes.fit_mode(rules, GameMode.sanitize(mode))
	if fitted != GameMode.sanitize(mode):
		warnings.append("[%s] %s needs teams: playing %s" % [section, rules, fitted])
	var minutes := maxf(float(cfg.get_value(section, "time_limit_minutes", 0.0)), 0.0)
	return {
		"map": MapList.sanitize(map),
		"mode": fitted,
		"rules": rules,
		"time_limit": minutes * 60.0,
	}


func _default_rotation() -> void:
	rotation = [
		{
			"map": MapList.DEFAULT_ID,
			"mode": GameMode.DEFAULT_ID,
			"rules": GameModes.DEFAULT_ID,
			"time_limit": 0.0,
		}
	]
