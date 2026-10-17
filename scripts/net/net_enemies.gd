class_name NetEnemies
extends Node
## LAN replication of Horde's New Ottoman enemies (HordeMatch adds it as Horde/Enemies on every
## peer, so the RPC path matches everywhere), and of the enemies a custom level places
## (LevelEnemies/Enemies, same scheme). Enemies only think, shoot and take damage on the
## host. Each client holds a visual copy per enemy:
##   spawn     reliable: id, EnemyType id, position, yaw. The copy is an Enemy with its Brain
##             removed, physics off and Enemy.net_copy set (take_damage does nothing).
##   snapshot  SNAPSHOT_RATE Hz, unreliable: position, yaw, head pitch, plate / health (so the
##             copy's ArmorStages spalls on time), crouch, aiming and the active weapon slot.
##             Copies are drawn at NetMatch.render_tick(), the same delay as remote players.
##   died      reliable: the copy dies (falls, hum stops); no weapon drops, the host's drops
##             replicate as pickups through NetMatch.
##   despawn   reliable: the corpse is cleared.
## A client says hello when its copy of this node is ready; the host answers with every enemy
## still in the arena (late joiners). Enemy shots reach clients as NetMatch shot FX (tracers,
## lobbed shells) under the enemy's net id. Clients' shots at enemies resolve on the host
## against the real ones; NetMatch rewinds them with the players (lag_bodies).

const SNAPSHOT_RATE := 20.0
## Enemy net ids start here: clear of peer ids and the host's bot ids (negative).
const ID_BASE := 100000
const FLAG_CROUCH := 1
const FLAG_AIM := 2
const SLOT_SHIFT := 2
const ENEMY_SCENE := "res://scenes/enemies/enemy.tscn"
const TYPES := "res://resources/enemies/new_ottoman/%s.tres"
## Frames kept per copy for interpolation.
const BUFFER := 20
## Client: hello again this often until the host welcomes us (the host may still be loading).
const HELLO_RETRY := 1.0
## Every NetEnemies in the arena joins this group (NetMatch looks enemies up through it).
const GROUP := &"net_enemies"

var horde: HordeMatch
var net_match: Node

var _host: bool = true
var _online: bool = false
var _next_id: int = 1
## Host: Enemy -> id.
var _ids: Dictionary = {}
## Host: peers whose copy of this node said hello.
var _peers: Dictionary = {}
## Client: id -> Enemy copy, id -> frames [[tick, pos, yaw, pitch]].
var copies: Dictionary = {}
var _frames: Dictionary = {}
var _snap_left: float = 0.0
var _welcomed: bool = false
var _hello_left: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	horde = get_parent() as HordeMatch
	net_match = horde.net_match if horde != null else get_parent().get(&"net_match") as Node
	# Not Net.is_online(): autoloads aren't compile-time names in --script tests.
	var peer := multiplayer.multiplayer_peer
	_online = peer != null and not peer is OfflineMultiplayerPeer
	_host = multiplayer.is_server()
	set_physics_process(_online)


func _say_hello() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer != null and not peer is OfflineMultiplayerPeer:
		_rpc_hello.rpc_id(1)


# ------------------------------------------------------------------ host


## Host: a new enemy. Gives it a net id, sends it to every client and its shots out as FX.
func register(e: Enemy) -> void:
	if not _online or not _host or _ids.has(e):
		return
	var id := ID_BASE + _next_id
	_next_id += 1
	_ids[e] = id
	e.set_meta(&"net_id", id)
	for weapon: Variant in e.slots:  # untyped: a slot may be empty
		var watch := net_match != null and net_match.has_method(&"watch_shots")
		if is_instance_valid(weapon) and watch:
			net_match.call(&"watch_shots", id, weapon)
	e.died.connect(_on_died.bind(id))
	# Any way off the host's tree (corpse timer, the wave's squad freed, the arena unloading)
	# despawns the copies.
	e.tree_exiting.connect(forget.bind(e), CONNECT_ONE_SHOT)
	for peer: int in peers():
		_send_spawn(peer, e, id)


## Host: the enemy is leaving (its corpse cleared, or freed with its squad).
func forget(e: Enemy) -> void:
	if not _ids.has(e):
		return
	var id: int = _ids[e]
	_ids.erase(e)
	for peer: int in peers():
		_rpc_despawn.rpc_id(peer, id)


## Host: peers whose copy of this node is ready (said hello) and still connected.
func peers() -> Array:
	var connected := multiplayer.get_peers()
	for peer: int in _peers.keys():
		if not connected.has(peer):
			_peers.erase(peer)
	return _peers.keys()


## Host: every live enemy body, for NetMatch's lag compensation.
func lag_bodies() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for e: Variant in _ids.keys():  # untyped: may be freed
		if is_instance_valid(e) and not (e as Enemy).dead:
			out.append(e)
	return out


## The enemy (host) or copy (client) behind a net id, or null.
func body_of(id: int) -> Node3D:
	var copy: Variant = copies.get(id)
	if is_instance_valid(copy):
		return copy as Node3D
	for e: Variant in _ids:
		if is_instance_valid(e) and int(_ids[e]) == id:
			return e as Node3D
	return null


## The display name behind a net id (kill feed), or "".
func name_of(id: int) -> String:
	if _host:
		for e: Variant in _ids:
			if int(_ids[e]) == id and is_instance_valid(e):
				return (e as Enemy).display_name
	var copy: Variant = copies.get(id)
	return (copy as Enemy).display_name if is_instance_valid(copy) else ""


func _send_spawn(peer: int, e: Enemy, id: int) -> void:
	if not is_instance_valid(e):
		return
	var yaw := e.global_rotation.y  # world yaw: host enemies sit under rotated Ortas
	_rpc_spawn.rpc_id(peer, id, String(e.enemy_type.id), e.global_position, yaw, e.dead)


func _on_died(_bot: Bot, _killer: Node, _info: Dictionary, id: int) -> void:
	for peer: int in peers():
		_rpc_died.rpc_id(peer, id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello() -> void:
	if not _host:
		return
	var peer := multiplayer.get_remote_sender_id()
	if _peers.has(peer):
		_rpc_welcome.rpc_id(peer)  # a retry crossed our welcome: just confirm again
		return
	_peers[peer] = true
	for e: Variant in _ids:  # untyped: may be freed
		if is_instance_valid(e):
			_send_spawn(peer, e, int(_ids[e]))
	if horde != null:
		horde.sync_state(peer)
	_rpc_welcome.rpc_id(peer)


@rpc("authority", "call_remote", "reliable")
func _rpc_welcome() -> void:
	_welcomed = true


func _physics_process(delta: float) -> void:
	if _host:
		_snap_left -= delta
		if _snap_left <= 0.0:
			_snap_left += 1.0 / SNAPSHOT_RATE
			_send_snapshot()
	else:
		if not _welcomed:
			_hello_left -= delta
			if _hello_left <= 0.0:
				_hello_left = HELLO_RETRY
				_say_hello()
		_interpolate()


func _send_snapshot() -> void:
	if _peers.is_empty():
		return
	var entries: Array = []
	for value: Variant in _ids.keys():  # untyped: may be freed
		if not is_instance_valid(value):
			_ids.erase(value)
			continue
		var e: Enemy = value
		if e.dead:
			continue
		var flags := FLAG_CROUCH if e.crouched else 0
		var brain := e.get_node_or_null(^"Brain") as BotBrain
		if brain != null and brain.state in [BotBrain.State.ENGAGE, BotBrain.State.RETREAT]:
			flags |= FLAG_AIM
		flags |= e.active_index << SLOT_SHIFT
		var hs := e.health_shield
		entries.append(
			[
				int(_ids[e]),
				e.global_position,
				e.global_rotation.y,
				e.head.rotation.x,
				Vector2(hs.shield, hs.health),
				flags,
			]
		)
	var tick := Engine.get_physics_frames()
	for peer: int in peers():
		_rpc_snapshot.rpc_id(peer, tick, entries)


# ------------------------------------------------------------------ client


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn(id: int, type_id: String, pos: Vector3, yaw: float, dead: bool) -> void:
	if copies.has(id):
		return
	var type := load(TYPES % type_id) as EnemyType
	var scene := load(ENEMY_SCENE) as PackedScene
	if type == null or scene == null:
		return
	var e := scene.instantiate() as Enemy
	e.enemy_type = type
	e.net_copy = true
	e.name = "NetEnemy_%d" % id
	e.set_meta(&"net_id", id)
	# A copy never thinks: no Brain, so nothing reacts to gunfire or paths anywhere.
	var brain := e.get_node_or_null(^"Brain")
	if brain != null:
		e.remove_child(brain)
		brain.free()
	e.transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	var arena := net_match.get_parent() if net_match != null else get_tree().current_scene
	arena.add_child(e)
	e.set_physics_process(false)
	copies[id] = e
	_frames[id] = []
	if dead:
		e.health_shield.force_death()
	_refresh_list()


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(tick: int, entries: Array) -> void:
	for entry: Array in entries:
		if entry.size() < 6:
			continue
		var id: int = entry[0]
		var copy: Variant = copies.get(id)
		if not is_instance_valid(copy):
			continue
		var e: Enemy = copy
		if e.dead:
			continue
		var frames: Array = _frames.get(id, [])
		frames.append([tick, entry[1], entry[2], entry[3]])
		while frames.size() > BUFFER:
			frames.pop_front()
		_frames[id] = frames
		var vitals: Vector2 = entry[4]
		e.health_shield.apply_network_state(vitals.x, vitals.y)
		var flags: int = entry[5]
		e.crouched = (flags & FLAG_CROUCH) != 0
		e.net_aiming = (flags & FLAG_AIM) != 0
		var slot := (flags >> SLOT_SHIFT) & 1
		if slot != e.active_index and slot < e.slots.size() and e.slots[slot] != null:
			e.switch_weapon()


@rpc("authority", "call_remote", "reliable")
func _rpc_died(id: int) -> void:
	var copy: Variant = copies.get(id)
	if is_instance_valid(copy) and not (copy as Enemy).dead:
		(copy as Enemy).health_shield.force_death()
	_refresh_list()


@rpc("authority", "call_remote", "reliable")
func _rpc_despawn(id: int) -> void:
	var copy: Variant = copies.get(id)
	copies.erase(id)
	_frames.erase(id)
	if is_instance_valid(copy):
		(copy as Node).queue_free()
	_refresh_list()


## Places every copy where the host had it NetMatch.INTERP_DELAY ago.
func _interpolate() -> void:
	if net_match == null or not net_match.has_method(&"render_tick"):
		return
	var render: float = net_match.call(&"render_tick")
	for id: int in copies:
		var copy: Variant = copies[id]
		if not is_instance_valid(copy) or (copy as Enemy).dead:
			continue
		var frames: Array = _frames.get(id, [])
		if frames.is_empty():
			continue
		var e: Enemy = copy
		var a: Array = frames[0]
		var b: Array = frames[-1]
		for i in range(frames.size() - 1):
			if float(frames[i + 1][0]) >= render:
				a = frames[i]
				b = frames[i + 1]
				break
		var span := float(b[0]) - float(a[0])
		var t := clampf((render - float(a[0])) / span, 0.0, 1.0) if span > 0.0 else 1.0
		e.global_position = (a[1] as Vector3).lerp(b[1], t)
		e.global_rotation = Vector3(0.0, lerp_angle(float(a[2]), float(b[2]), t), 0.0)
		e.head.rotation.x = lerpf(float(a[3]), float(b[3]), t)
		# The rig's walk cycle and coat flare read velocity.
		var seconds := span / float(Engine.physics_ticks_per_second)
		var moved := (b[1] as Vector3) - (a[1] as Vector3)
		e.velocity = moved / seconds if seconds > 0.0 else Vector3.ZERO


## Client: HordeMatch.enemies mirrors the living copies (HUD markers).
func _refresh_list() -> void:
	if horde == null:
		return
	horde.enemies.clear()
	for copy: Variant in copies.values():
		if is_instance_valid(copy) and not (copy as Enemy).dead:
			horde.enemies.append(copy)
