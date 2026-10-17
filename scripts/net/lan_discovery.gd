class_name LanDiscovery
extends Node
## LAN server discovery over UDP broadcast (owned by the Net autoload).
## Host: start_beacon() broadcasts a small JSON beacon to BROADCAST_ADDRESS:port about once a
## second. Browser: start_listening() binds port and keeps a server list, pruning entries not
## heard from for SERVER_TIMEOUT seconds. Beacon fields: game, v (protocol), name, map,
## players, max, port (the ENet game port). Only beacons with game == Net.GAME_TAG are listed.

signal servers_changed(servers: Array)

const BROADCAST_ADDRESS := "255.255.255.255"
const BEACON_INTERVAL := 1.0
const SERVER_TIMEOUT := 3.5
const MAX_PACKETS_PER_FRAME := 32

var port: int = 7778
var game_tag: String = "PLC"
var protocol: int = 1
## Host: returns the beacon Dictionary (name, map, players, max, port).
var beacon_provider: Callable

var _beacon: PacketPeerUDP
var _beacon_left: float = 0.0
var _listener: PacketPeerUDP
## "ip:port" -> {"ip", "port", "name", "map", "players", "max", "seen"}
var _servers: Dictionary = {}


func start_beacon(provider: Callable) -> void:
	stop_beacon()
	beacon_provider = provider
	_beacon = PacketPeerUDP.new()
	_beacon.set_broadcast_enabled(true)
	var err := _beacon.set_dest_address(BROADCAST_ADDRESS, port)
	if err != OK:
		push_warning("LanDiscovery: beacon disabled (%s)" % error_string(err))
		_beacon = null
		return
	_beacon_left = 0.0


func stop_beacon() -> void:
	if _beacon != null:
		_beacon.close()
	_beacon = null


func is_listening() -> bool:
	return _listener != null


## Returns OK, or an error when the port is taken (e.g. a second game on this machine).
func start_listening() -> Error:
	if _listener != null:
		return OK
	_listener = PacketPeerUDP.new()
	var err := _listener.bind(port, "*")
	if err != OK:
		push_warning("LanDiscovery: cannot listen on %d (%s)" % [port, error_string(err)])
		_listener = null
	return err


func stop_listening() -> void:
	if _listener != null:
		_listener.close()
	_listener = null
	if not _servers.is_empty():
		_servers.clear()
		servers_changed.emit(get_servers())


## Known servers, newest first, as Dictionaries (see _servers).
func get_servers() -> Array:
	var out := _servers.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.seen > b.seen)
	return out


func _process(delta: float) -> void:
	_tick_beacon(delta)
	_poll_listener()


func _tick_beacon(delta: float) -> void:
	if _beacon == null or not beacon_provider.is_valid():
		return
	_beacon_left -= delta
	if _beacon_left > 0.0:
		return
	_beacon_left = BEACON_INTERVAL
	var info: Dictionary = beacon_provider.call()
	info["game"] = game_tag
	info["v"] = protocol
	_beacon.put_packet(JSON.stringify(info).to_utf8_buffer())


func _poll_listener() -> void:
	if _listener == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var dirty := false
	for _i in MAX_PACKETS_PER_FRAME:
		if _listener.get_available_packet_count() <= 0:
			break
		var bytes := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var entry := _parse(bytes, ip, now)
		if entry.is_empty():
			continue
		var key := "%s:%d" % [ip, entry.port]
		dirty = dirty or not _servers.has(key) or _servers[key].players != entry.players
		_servers[key] = entry
	for key: String in _servers.keys():
		if now - float(_servers[key].seen) > SERVER_TIMEOUT:
			_servers.erase(key)
			dirty = true
	if dirty:
		servers_changed.emit(get_servers())


func _parse(bytes: PackedByteArray, ip: String, now: float) -> Dictionary:
	if bytes.size() > 1024 or ip == "":
		return {}
	var data: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not data is Dictionary:
		return {}
	var info: Dictionary = data
	if str(info.get("game", "")) != game_tag or int(info.get("port", 0)) <= 0:
		return {}
	return {
		"ip": ip,
		"port": int(info.get("port", 0)),
		"name": str(info.get("name", "?")).substr(0, 32),
		"map": str(info.get("map", "?")).substr(0, 72),
		"players": int(info.get("players", 0)),
		"max": int(info.get("max", 0)),
		"version_ok": int(info.get("v", -1)) == protocol,
		"bot_refill": bool(info.get("refill", false)),
		"seen": now,
	}
