extends Node
## Autoload `Net`: online sessions over Godot high-level multiplayer (ENetMultiplayerPeer).
## Owns the peer, the player registry (peer id -> name, color) synced to every peer, LAN
## discovery (LanDiscovery), UPnP port forwarding (NetUpnp) and match loading. In-match
## traffic (state, fire, damage, pickups, scores) lives on NetMatch in the arena scene.
## Architecture: docs/net/netcode.md; servers: docs/net/servers.md.
##
## Three ways to be online:
##   listen host   a player hosts from the menu (host()) and plays as peer 1. With UPnP on, the
##                 router forwards the port so players on the internet can join.
##   dedicated     the game launched with `-- --server` (DedicatedServer, host_dedicated()):
##                 peer 1 is the server itself, not a player; it runs a match rotation.
##   client        join() by address: an IP or a domain, any port, an optional password.
##
## Offline (Bot Arena, or running the arena scene directly) the multiplayer peer is the
## default OfflineMultiplayerPeer: unique id 1, is_server() true, so every host-only code path
## runs unchanged and no RPC is ever sent.

signal players_changed
signal hosting_started
## Connected and registered with the host.
signal joined
signal join_failed(reason: String)
## Left a session for any reason other than leave() (host quit, kicked, connection lost).
signal session_ended(reason: String)
signal servers_changed(servers: Array)

enum Mode { OFFLINE, HOST, CLIENT }

const DEFAULT_PORT := 7777
const DISCOVERY_PORT := 7778
## ENet client slots: the biggest mode's cap minus the host. The current mode's cap
## (max_players()) is enforced at registration.
const MAX_CLIENTS := GameMode.MAX_PLAYERS_ANY - 1
## Bump on any change to the RPC set or wire formats (here or in NetMatch).
## 7: player-count mode and rules id on _rpc_players / _rpc_load_match; shot fx carries the
## weapon id so rockets replicate.
## 8: CharacterAnimState gains weapon_model / holster_model ("wm" / "hm") and Action.THROW.
## 9: _rpc_damaged carries a knockback impulse (Vector3).
## 10: longsword / gravity hammer (new weapon ids, WeaponModel SWORD / HAMMER) and the CTF
## rules id with its flag-state RPCs on NetMatch/Ctf.
## 11: Horde over LAN (NetMatch/Horde state, banner and feed RPCs; NetMatch/Horde/Enemies
## spawn, snapshot, death and despawn).
## 12: dedicated servers and passwords: _rpc_register carries a password, _rpc_players the
## server name (the host's name, or the dedicated server's).
## 13: CharacterAnimState.WeaponModel gains the New Ottoman weapons (TUFEK .. YATAGAN), so a
## player carrying one shows its own third-person mesh.
## 14: shoulder accent colour on _rpc_register / _rpc_update_info and in the player info.
## 15: grenade pickups: _rpc_pickup_state carries a grenade count for GrenadePickups and
## _rpc_drop has a grenade form ([key, "grenade:" + GrenadeData path, position, count]).
## 16: custom (Level Editor) levels: map ids "custom:<name>"; the host sends the level (_rpc_level,
## compressed JSON) to each client before _rpc_load_match. Custom levels' placed enemies
## replicate like Horde's (LevelEnemies/Enemies, a NetEnemies).
## 17: Hospitaller armor loadout ("armor", ArmorLoadout string) on _rpc_register /
## _rpc_update_info and in the player info.
const PROTOCOL := 17
## Largest custom level a client accepts from a host (uncompressed JSON).
const MAX_LEVEL_BYTES := 4 * 1024 * 1024
const GAME_TAG := "PLC"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const CONNECT_TIMEOUT := 8.0

var mode: Mode = Mode.OFFLINE
## peer id -> {"name": String, "color", "visor", "accent": String (html), "armor": String
## (ArmorLoadout)}. Host-authoritative.
var players: Dictionary = {}
## Host: spawn Settings.bot_count bots, capped by the empty slots. Off spawns none.
var bot_fill: bool = true
## Host: a human leaving mid-match is replaced by a bot, up to Settings.bot_count
## (independent of bot_fill).
var bot_refill: bool = false
var match_running: bool = false
## Map of the current session (MapList id). Host-authoritative: the host sets it (set_map) and
## sends it with the player registry and with every match load.
var map_id: String = MapList.DEFAULT_ID
## Player-count / team setup of the current session (GameMode id). Host-authoritative.
var mode_id: String = GameMode.DEFAULT_ID
## Rules variant of the current session (GameModes id: Slayer / SWAT). Host-authoritative.
var rules_id: String = GameModes.DEFAULT_ID
## Why the last session ended (shown by the main menu).
var last_end_reason: String = ""
var discovery: LanDiscovery
var upnp: NetUpnp
## A dedicated server: peer 1 is the server, not a player (no entry in `players`).
var dedicated: bool = false
## The session's name: the dedicated server's, or the listen host's player name. Clients get it
## with the registry.
var server_name: String = ""

## Host: "" = open; otherwise joiners must send this.
var _password: String = ""
## Client: the password to send when the connection opens.
var _join_password: String = ""

var _connect_left: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	discovery = LanDiscovery.new()
	discovery.name = "LanDiscovery"
	discovery.port = DISCOVERY_PORT
	discovery.game_tag = GAME_TAG
	discovery.protocol = PROTOCOL
	add_child(discovery)
	discovery.servers_changed.connect(servers_changed.emit)
	upnp = NetUpnp.new()
	upnp.name = "Upnp"
	add_child(upnp)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if DedicatedServer.requested():
		var server := DedicatedServer.new()
		server.name = "DedicatedServer"
		add_child(server)


func _process(delta: float) -> void:
	if mode != Mode.CLIENT or _connect_left <= 0.0:
		return
	_connect_left -= delta
	if _connect_left <= 0.0 and not players.has(multiplayer.get_unique_id()):
		_fail_join("Timed out connecting to host")


func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func is_client() -> bool:
	return mode == Mode.CLIENT


func is_dedicated() -> bool:
	return mode == Mode.HOST and dedicated


## Host: the session needs a password.
func has_password() -> bool:
	return _password != ""


## Player cap (humans + bots) of the current mode.
func max_players() -> int:
	return GameMode.max_players(mode_id)


func my_id() -> int:
	return multiplayer.get_unique_id()


func name_of(peer_id: int) -> String:
	return str(players.get(peer_id, {}).get("name", "Player %d" % peer_id))


func visor_of(peer_id: int) -> Color:
	var html := str(players.get(peer_id, {}).get("visor", ""))
	return Color.from_string(html, PlayerColor.default_visor())


func color_of(peer_id: int) -> Color:
	var html := str(players.get(peer_id, {}).get("color", ""))
	return Color.from_string(html, PlayerColor.default_color())


# ------------------------------------------------------------------ session control


## Bot Arena: no peer, straight to the arena (difficulty comes from Settings).
## map / game_mode / rules "" = the menu's last pick.
func start_offline(map: String = "", game_mode: String = "", rules: String = "") -> void:
	leave()
	map_id = MapList.sanitize(map if map != "" else Settings.map_id)
	mode_id = GameMode.sanitize(game_mode if game_mode != "" else Settings.mode_id)
	rules_id = GameModes.sanitize(rules if rules != "" else Settings.rules_id)
	mode_id = GameModes.fit_mode(rules_id, mode_id)
	match_running = true
	_load_scene(MapList.arena_of(map_id))


## Listen server: this player hosts and plays as peer 1. open_upnp asks the router to forward
## the port (internet play); upnp.changed reports how that went.
func host(
	port: int = DEFAULT_PORT,
	fill_bots: bool = true,
	refill_bots: bool = false,
	map: String = "",
	game_mode: String = "",
	rules: String = "",
	open_upnp: bool = false,
	password: String = ""
) -> Error:
	leave()
	map_id = MapList.sanitize(map if map != "" else Settings.map_id)
	mode_id = GameMode.sanitize(game_mode if game_mode != "" else Settings.mode_id)
	rules_id = GameModes.sanitize(rules if rules != "" else Settings.rules_id)
	if not GameModes.allows_online(rules_id):
		rules_id = GameModes.DEFAULT_ID  # offline-only rules (Horde) can't be hosted
	mode_id = GameModes.fit_mode(rules_id, mode_id)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	bot_fill = fill_bots
	bot_refill = refill_bots
	_password = password
	players = {1: _my_info()}
	server_name = name_of(1)
	discovery.stop_listening()
	discovery.start_beacon(_beacon_info.bind(port))
	if open_upnp:
		upnp.open(port)
	players_changed.emit()
	hosting_started.emit()
	return OK


## Dedicated server (DedicatedServer): host with no local player. The first rotation entry is
## the session's map / mode / rules until DedicatedServer starts a match.
func host_dedicated(config: ServerConfig) -> Error:
	leave()
	var first: Dictionary = config.rotation[0]
	map_id = first.map
	mode_id = first.mode
	rules_id = first.rules
	var peer := ENetMultiplayerPeer.new()
	# Every slot is a player: the server takes none.
	var err := peer.create_server(config.port, GameMode.MAX_PLAYERS_ANY)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	dedicated = true
	bot_fill = config.bot_fill
	bot_refill = config.bot_fill
	_password = config.password
	server_name = config.server_name
	players = {}
	discovery.stop_listening()
	if config.lan_beacon:
		discovery.start_beacon(_beacon_info.bind(config.port))
	if config.upnp:
		upnp.open(config.port)
	players_changed.emit()
	hosting_started.emit()
	return OK


## address: an IP or a domain name (ENet resolves it). password: "" for an open server.
func join(address: String, port: int = DEFAULT_PORT, password: String = "") -> Error:
	leave()
	_join_password = password
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	_connect_left = CONNECT_TIMEOUT
	return OK


## Closes any session and returns to offline. Safe to call any time.
func leave() -> void:
	discovery.stop_beacon()
	if upnp != null:
		upnp.close()
	dedicated = false
	_password = ""
	server_name = ""
	if mode != Mode.OFFLINE:
		var peer := multiplayer.multiplayer_peer
		if peer != null and not peer is OfflineMultiplayerPeer:
			peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	mode = Mode.OFFLINE
	players.clear()
	match_running = false
	_connect_left = 0.0


## Host, in the lobby: pick the map. Clients see it with the next registry broadcast and the
## LAN beacon advertises it from the next ping.
func set_map(map: String) -> void:
	if mode != Mode.HOST or match_running:
		return
	map_id = MapList.sanitize(map)
	_broadcast_players()


## Host, in the lobby: pick the player count. Refused (false) when the lobby already holds
## more humans than the new mode allows.
func set_mode(game_mode: String) -> bool:
	if mode != Mode.HOST or match_running:
		return false
	var wanted := GameMode.sanitize(game_mode)
	if players.size() > GameMode.max_players(wanted):
		return false
	mode_id = wanted
	# Free-for-all can't play teams-only rules (CTF): back to the default rules.
	if GameModes.fit_mode(rules_id, mode_id) != mode_id:
		rules_id = GameModes.DEFAULT_ID
	_broadcast_players()
	return true


## Host, in the lobby: pick the rules (Slayer / SWAT / CTF). Teams-only rules move a
## free-for-all lobby to GameModes.TEAM_FALLBACK (same seat count).
func set_rules(rules: String) -> void:
	if mode != Mode.HOST or match_running:
		return
	rules_id = GameModes.sanitize(rules)
	if not GameModes.allows_online(rules_id):
		rules_id = GameModes.DEFAULT_ID
	mode_id = GameModes.fit_mode(rules_id, mode_id)
	_broadcast_players()


## Host: load the arena on every peer (also used for Play Again).
func start_match() -> void:
	if mode != Mode.HOST:
		return
	match_running = true
	for peer_id: int in players:
		if peer_id != 1:
			_send_level(peer_id)
			_rpc_load_match.rpc_id(peer_id, map_id, mode_id, rules_id)
	_load_scene(MapList.arena_of(map_id))


## Leave the session (if any) and show the main menu.
func return_to_menu(reason: String = "") -> void:
	if reason != "":
		last_end_reason = reason
	leave()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_load_scene(MENU_SCENE)


## Re-send our name and color (after the menu changes them).
func update_my_info() -> void:
	if mode == Mode.HOST and not dedicated:
		players[1] = _my_info()
		server_name = name_of(1)
		_broadcast_players()
	elif mode == Mode.CLIENT and players.has(my_id()):
		var info := _my_info()
		_rpc_update_info.rpc_id(1, info.name, info.color, info.visor, info.accent, info.armor)


# ------------------------------------------------------------------ multiplayer callbacks


func _on_peer_connected(_peer_id: int) -> void:
	pass  # Clients register themselves (_rpc_register) once connected.


func _on_peer_disconnected(peer_id: int) -> void:
	if mode == Mode.HOST and players.has(peer_id):
		if dedicated:
			print("[Server] %s left" % name_of(peer_id))
		players.erase(peer_id)
		_broadcast_players()


func _on_connected_to_server() -> void:
	var info := _my_info()
	_rpc_register.rpc_id(
		1, info.name, info.color, PROTOCOL, info.visor, _join_password, info.accent, info.armor
	)


func _on_connection_failed() -> void:
	_fail_join("Could not connect to host")


func _on_server_disconnected() -> void:
	var reason := "Connection to host lost"
	var in_match := match_running
	leave()
	last_end_reason = reason
	session_ended.emit(reason)
	if in_match:
		return_to_menu(reason)


func _fail_join(reason: String) -> void:
	leave()
	last_end_reason = reason
	join_failed.emit(reason)


# ------------------------------------------------------------------ RPCs

## Client -> host: join request. visor_html, password, accent_html and armor come last (with
## defaults) so an older client's shorter call still arrives and gets the version-mismatch
## rejection.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_register(
	player_name: String,
	color_html: String,
	protocol: int,
	visor_html: String = "",
	password: String = "",
	accent_html: String = "",
	armor: String = ""
) -> void:
	if mode != Mode.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_rpc_rejected.rpc_id(sender, "Version mismatch (host %d, you %d)" % [PROTOCOL, protocol])
		_kick_later(sender)
		return
	if _password != "" and password != _password:
		_rpc_rejected.rpc_id(sender, "Wrong password" if password != "" else "Password required")
		_kick_later(sender)
		return
	if players.size() >= max_players():
		_rpc_rejected.rpc_id(sender, "Game is full")
		_kick_later(sender)
		return
	players[sender] = {
		"name": _unique_name(Settings.sanitize_name(player_name), sender),
		"color": _clean_color(color_html),
		"visor": _clean_color(visor_html, PlayerColor.default_visor()),
		"accent": _clean_color(accent_html, PlayerColor.default_accent()),
		"armor": ArmorLoadout.encode(ArmorLoadout.decode(armor)),
	}
	if dedicated:
		print("[Server] %s joined (%d/%d)" % [name_of(sender), players.size(), max_players()])
	_broadcast_players()
	if match_running:
		_send_level(sender)
		_rpc_load_match.rpc_id(sender, map_id, mode_id, rules_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_update_info(
	player_name: String,
	color_html: String,
	visor_html: String,
	accent_html: String,
	armor: String = ""
) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if mode != Mode.HOST or not players.has(sender):
		return
	players[sender] = {
		"name": _unique_name(Settings.sanitize_name(player_name), sender),
		"color": _clean_color(color_html),
		"visor": _clean_color(visor_html, PlayerColor.default_visor()),
		"accent": _clean_color(accent_html, PlayerColor.default_accent()),
		"armor": ArmorLoadout.encode(ArmorLoadout.decode(armor)),
	}
	_broadcast_players()


@rpc("authority", "call_remote", "reliable")
func _rpc_players(
	registry: Dictionary, map: String, game_mode: String, rules: String, session: String = ""
) -> void:
	var first := not players.has(my_id())
	players = registry
	server_name = session
	map_id = _clean_map(map)
	mode_id = GameMode.sanitize(game_mode)
	rules_id = GameModes.sanitize(rules)
	players_changed.emit()
	if first and players.has(my_id()):
		_connect_left = 0.0
		joined.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	_fail_join(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_load_match(map: String, game_mode: String, rules: String) -> void:
	map_id = _clean_map(map)
	mode_id = GameMode.sanitize(game_mode)
	rules_id = GameModes.sanitize(rules)
	if CustomLevels.is_custom(map_id) and not MapList.has(map_id):
		return_to_menu("The host's level '%s' didn't arrive" % MapList.name_of(map_id))
		return
	match_running = true
	_load_scene(MapList.arena_of(map_id))


## Host -> client, before _rpc_load_match: the custom level the match is on (ZSTD-compressed
## level JSON; `size` = uncompressed bytes). Ordered with the load (same reliable channel).
@rpc("authority", "call_remote", "reliable")
func _rpc_level(map: String, data: PackedByteArray, size: int) -> void:
	if not CustomLevels.is_custom(map) or size <= 0 or size > MAX_LEVEL_BYTES:
		return
	var text := data.decompress(size, FileAccess.COMPRESSION_ZSTD).get_string_from_utf8()
	if not CustomLevels.store_download(map, text):
		push_warning("Net: the host's level '%s' could not be read" % map)


# ------------------------------------------------------------------ helpers


## A map id from the wire: a custom level's id is kept even before we have the level (the
## host sends it just before the match loads); anything else must be a known map.
static func _clean_map(map: String) -> String:
	return map if CustomLevels.is_custom(map) else MapList.sanitize(map)


## Host: sends the session's custom level to peer_id (nothing for a built-in map).
func _send_level(peer_id: int) -> void:
	if not CustomLevels.is_custom(map_id):
		return
	var text := CustomLevels.text_for(map_id)
	if text == "":
		push_warning("Net: custom level '%s' has no data to send" % map_id)
		return
	var raw := text.to_utf8_buffer()
	_rpc_level.rpc_id(peer_id, map_id, raw.compress(FileAccess.COMPRESSION_ZSTD), raw.size())


func _broadcast_players() -> void:
	for peer_id: int in players:
		if peer_id != 1:
			_rpc_players.rpc_id(peer_id, players, map_id, mode_id, rules_id, server_name)
	players_changed.emit()


func _kick_later(peer_id: int) -> void:
	# Give the rejection RPC a moment to go out.
	await get_tree().create_timer(0.5).timeout
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	# A refused client usually leaves on its own first.
	if peer != null and mode == Mode.HOST and multiplayer.get_peers().has(peer_id):
		peer.disconnect_peer(peer_id)


func _my_info() -> Dictionary:
	return {
		"name": Settings.player_name,
		"color": Settings.primary_color.to_html(false),
		"visor": Settings.visor_color.to_html(false),
		"accent": Settings.accent_color.to_html(false),
		"armor": ArmorLoadout.encode(Settings.armor_loadout),
	}


func _beacon_info(port: int) -> Dictionary:
	return {
		"name": server_name if server_name != "" else name_of(1),
		"map": "%s - %s / %s" % [
			GameModes.name_of(rules_id), GameMode.name_of(mode_id), MapList.name_of(map_id)
		],
		"players": players.size(),
		"max": max_players(),
		"port": port,
		"refill": bot_refill,
	}


func _unique_name(wanted: String, peer_id: int) -> String:
	var taken: Array[String] = []
	for other: int in players:
		if other != peer_id:
			taken.append(name_of(other))
	var candidate := wanted
	var n := 2
	while taken.has(candidate):
		candidate = "%s (%d)" % [wanted, n]
		n += 1
	return candidate


static func _clean_color(html: String, fallback: Color = PlayerColor.default_color()) -> String:
	var color := Color.from_string(html, fallback)
	color.a = 1.0
	return color.to_html(false)


func _load_scene(path: String) -> void:
	get_tree().change_scene_to_file.call_deferred(path)
