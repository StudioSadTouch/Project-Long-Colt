extends Node
## Autoload `Net`: LAN session over Godot high-level multiplayer (ENetMultiplayerPeer).
## Owns the peer, the player registry (peer id -> name, color) synced to every peer, LAN
## discovery (LanDiscovery) and match loading. In-match traffic (state, fire, damage, pickups,
## scores) lives on NetMatch in the arena scene. Architecture: docs/net/netcode.md.
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
const MAX_PLAYERS := 4
## Bump on any change to the RPC set or wire formats (here or in NetMatch).
const PROTOCOL := 5
const GAME_TAG := "PLC"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const CONNECT_TIMEOUT := 8.0

var mode: Mode = Mode.OFFLINE
## peer id -> {"name": String, "color": String (html), "visor": String (html)}. Host-authoritative.
var players: Dictionary = {}
## Host: fill empty slots (of MAX_PLAYERS) with bots.
var bot_fill: bool = true
## Host: a human leaving mid-match is replaced by a bot (independent of bot_fill).
var bot_refill: bool = false
var match_running: bool = false
## Map of the current session (MapList id). Host-authoritative: the host sets it (set_map) and
## sends it with the player registry and with every match load.
var map_id: String = MapList.DEFAULT_ID
## Why the last session ended (shown by the main menu).
var last_end_reason: String = ""
var discovery: LanDiscovery

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
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


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
## map "" = the menu's last pick (Settings.map_id).
func start_offline(map: String = "") -> void:
	leave()
	map_id = MapList.sanitize(map if map != "" else Settings.map_id)
	match_running = true
	_load_scene(MapList.arena_of(map_id))


func host(
	port: int = DEFAULT_PORT,
	fill_bots: bool = true,
	refill_bots: bool = false,
	map: String = ""
) -> Error:
	leave()
	map_id = MapList.sanitize(map if map != "" else Settings.map_id)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	bot_fill = fill_bots
	bot_refill = refill_bots
	players = {1: _my_info()}
	discovery.stop_listening()
	discovery.start_beacon(_beacon_info.bind(port))
	players_changed.emit()
	hosting_started.emit()
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	leave()
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


## Host: load the arena on every peer (also used for Play Again).
func start_match() -> void:
	if mode != Mode.HOST:
		return
	match_running = true
	for peer_id: int in players:
		if peer_id != 1:
			_rpc_load_match.rpc_id(peer_id, map_id)
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
	if mode == Mode.HOST:
		players[1] = _my_info()
		_broadcast_players()
	elif mode == Mode.CLIENT and players.has(my_id()):
		var info := _my_info()
		_rpc_update_info.rpc_id(1, info.name, info.color, info.visor)


# ------------------------------------------------------------------ multiplayer callbacks


func _on_peer_connected(_peer_id: int) -> void:
	pass  # Clients register themselves (_rpc_register) once connected.


func _on_peer_disconnected(peer_id: int) -> void:
	if mode == Mode.HOST and players.erase(peer_id):
		_broadcast_players()


func _on_connected_to_server() -> void:
	var info := _my_info()
	_rpc_register.rpc_id(1, info.name, info.color, PROTOCOL, info.visor)


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

## Client -> host: join request. visor_html is last (with a default) so a PROTOCOL 3 client's
## 3-argument call still arrives and gets the version-mismatch rejection.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_register(
	player_name: String, color_html: String, protocol: int, visor_html: String = ""
) -> void:
	if mode != Mode.HOST:
		return
	var sender := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_rpc_rejected.rpc_id(sender, "Version mismatch (host %d, you %d)" % [PROTOCOL, protocol])
		_kick_later(sender)
		return
	if players.size() >= MAX_PLAYERS:
		_rpc_rejected.rpc_id(sender, "Game is full")
		_kick_later(sender)
		return
	players[sender] = {
		"name": _unique_name(Settings.sanitize_name(player_name), sender),
		"color": _clean_color(color_html),
		"visor": _clean_color(visor_html, PlayerColor.default_visor()),
	}
	_broadcast_players()
	if match_running:
		_rpc_load_match.rpc_id(sender, map_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_update_info(player_name: String, color_html: String, visor_html: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if mode != Mode.HOST or not players.has(sender):
		return
	players[sender] = {
		"name": _unique_name(Settings.sanitize_name(player_name), sender),
		"color": _clean_color(color_html),
		"visor": _clean_color(visor_html, PlayerColor.default_visor()),
	}
	_broadcast_players()


@rpc("authority", "call_remote", "reliable")
func _rpc_players(registry: Dictionary, map: String) -> void:
	var first := not players.has(my_id())
	players = registry
	map_id = MapList.sanitize(map)
	players_changed.emit()
	if first and players.has(my_id()):
		_connect_left = 0.0
		joined.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	_fail_join(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_load_match(map: String) -> void:
	map_id = MapList.sanitize(map)
	match_running = true
	_load_scene(MapList.arena_of(map_id))


# ------------------------------------------------------------------ helpers


func _broadcast_players() -> void:
	for peer_id: int in players:
		if peer_id != 1:
			_rpc_players.rpc_id(peer_id, players, map_id)
	players_changed.emit()


func _kick_later(peer_id: int) -> void:
	# Give the rejection RPC a moment to go out.
	await get_tree().create_timer(0.5).timeout
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer != null and mode == Mode.HOST:
		peer.disconnect_peer(peer_id)


func _my_info() -> Dictionary:
	return {
		"name": Settings.player_name,
		"color": Settings.primary_color.to_html(false),
		"visor": Settings.visor_color.to_html(false),
	}


func _beacon_info(port: int) -> Dictionary:
	return {
		"name": name_of(1),
		"map": MapList.name_of(map_id),
		"players": players.size(),
		"max": MAX_PLAYERS,
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
