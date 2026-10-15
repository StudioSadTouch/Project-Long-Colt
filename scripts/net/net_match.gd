class_name NetMatch
extends Node
## In-match networking for the arena (one node, "NetMatch", before SpawnManager in
## arena_lockout.tscn so its _ready runs first). Every in-match RPC goes through this node, so
## its path (/root/ArenaLockout/NetMatch) matches on all peers. Architecture, message list and
## tuning: docs/net/netcode.md.
##
## Offline (Bot Arena, or the arena run straight from the editor) nothing here touches gameplay:
## no RPCs, no puppets, no validation. When the match was started from the main menu it applies
## Settings (look, FOV, aim assist, name, colour, bot difficulty) to the local player and the
## SpawnManager, and MatchUI adds the pause menu, scoreboard and win banner.
##
## Online the host is the authority for damage, deaths, respawns (SpawnManager), pickups,
## scores and the win. Entities are ids: peer id for humans, -n for the host's bots. Each client
## predicts its own movement and shooting; the host validates and re-casts every shot
## (NetWeapon.replay, with NetLag rewind). Remote bodies on every peer are Player puppets
## (net_puppet), interpolated INTERP_DELAY behind the newest snapshot.

signal remote_shot(entity_id: int, from: Vector3, tos: PackedVector3Array, hits: PackedByteArray)
signal kill_feed(text: String)
signal scores_changed(scores: Dictionary)
signal game_over(winner: String, scores: Dictionary)

const PUPPET_SCENE := "res://scenes/player/player.tscn"
const SNAPSHOT_RATE := 30.0
const INTERP_DELAY := 0.1
const PICKUP_POLL := 0.2
const ROSTER_POLL := 0.5
const LOADOUT_POLL := 0.2
## Client reconciliation: errors above SNAP_DISTANCE snap, smaller ones blend at SMOOTH_RATE.
const SNAP_DISTANCE := 1.0
const SMOOTH_RATE := 12.0
const HUMAN_TEAM_BASE := 100
const PICKUP_REACH := 3.0
const KIND_HUMAN := 0
const KIND_BOT := 1

@export var spawn_manager_path: NodePath = ^"../SpawnManager"
@export var player_path: NodePath = ^"../Player"

var local_player: Player
var spawn_manager: SpawnManager
## id -> Node3D: the local player, puppets and (host) bots.
var entities: Dictionary = {}
## id -> {"name", "color", "kind"}; host-authored.
var roster: Dictionary = {}
var scores: Dictionary = {}
var is_game_over: bool = false

var _online: bool = false
var _host: bool = true
var _client_anim: Dictionary = {}
var _buffers: Dictionary = {}
var _shots: Dictionary = {}
var _bot_ids: Dictionary = {}
var _next_bot: int = 1
var _pickups: NetPickups
var _net_host: NetHost
var _teleport_seq: int = 0
var _correction: Vector3 = Vector3.ZERO
var _tick_offset: float = 0.0
var _have_offset: bool = false
var _snap_left: float = 0.0
var _pickup_left: float = 0.0
var _roster_left: float = 0.0
var _loadout_left: float = 0.0
var _last_pickups: Dictionary = {}
var _roster_sig: String = ""
var _overheated: Dictionary = {}
var _ui: MatchUI


func _ready() -> void:
	_online = Net.is_online()
	_host = multiplayer.is_server()
	local_player = get_node_or_null(player_path) as Player
	spawn_manager = get_node_or_null(spawn_manager_path) as SpawnManager
	_ui = MatchUI.new()
	_ui.name = "MatchUI"
	_ui.net_match = self
	add_child(_ui)
	if spawn_manager != null:
		spawn_manager.score_changed.connect(_on_scores)
		spawn_manager.match_won.connect(_on_match_won)
	if local_player == null:
		return
	_setup_local()
	if not _online:
		_setup_offline()
		return
	var proxy := Node3D.new()
	proxy.name = "AimProxy"
	proxy.top_level = true
	add_child(proxy)
	_net_host = NetHost.new(proxy)
	_pickups = NetPickups.new(get_parent())
	get_tree().node_added.connect(_on_node_added)
	_scan_pickups.call_deferred()
	Net.players_changed.connect(_on_players_changed)
	if _host:
		_setup_host()
	else:
		_setup_client()


func _setup_local() -> void:
	if Net.match_running:
		Settings.apply_to_player(local_player)
		local_player.set_primary_color(Settings.primary_color)
	if not _online:
		# Offline from the menu: our name on the scoreboard. Run directly: untouched.
		if Net.match_running:
			local_player.set_meta(&"display_name", Settings.player_name)
		return
	var my_id := Net.my_id()
	local_player.set_meta(&"display_name", Net.name_of(my_id))
	local_player.set_meta(&"net_id", my_id)
	entities[my_id] = local_player


func _setup_offline() -> void:
	if spawn_manager != null and Net.match_running:
		spawn_manager.difficulty = Settings.get_difficulty()


func _setup_host() -> void:
	roster[1] = {
		"name": Net.name_of(1), "color": Net.players.get(1, {}).get("color", ""), "kind": 0
	}
	_hook_authority(1, local_player)
	_watch_local_weapons(local_player)
	if spawn_manager != null:
		spawn_manager.end_on_win = true
		var humans := Net.players.size()
		spawn_manager.bot_count = maxi(Net.MAX_PLAYERS - humans, 0) if Net.bot_fill else 0
		spawn_manager.difficulty = Settings.get_difficulty()


func _setup_client() -> void:
	local_player.net_damage_authority = false
	local_player.auto_respawn = false
	var holder := local_player.get_weapon_holder()
	if holder != null:
		holder.drop_weapons_on_death = false
		holder.pickup_request_hook = _request_pickup
	_watch_local_weapons(local_player)
	local_player.died.connect(_on_local_died_client)
	_rpc_client_ready.rpc_id(1)


# ------------------------------------------------------------------ per-tick


func _physics_process(delta: float) -> void:
	if not _online:
		return
	var tick := Engine.get_physics_frames()
	if _host:
		_host_tick(delta, tick)
	else:
		_client_tick(delta)


func _host_tick(delta: float, tick: int) -> void:
	_refresh_bots()
	var bodies: Array[Node3D] = []
	for id: int in entities:
		var body: Variant = entities[id]  # may be freed: check before any typed assignment
		if is_instance_valid(body):
			bodies.append(body)
	_net_host.lag.record(bodies, tick)
	_snap_left -= delta
	if _snap_left <= 0.0:
		_snap_left += 1.0 / SNAPSHOT_RATE
		_send_snapshot(tick)
	_pickup_left -= delta
	if _pickup_left <= 0.0:
		_pickup_left = PICKUP_POLL
		_send_pickup_state()
	_loadout_left -= delta
	if _loadout_left <= 0.0:
		_loadout_left = LOADOUT_POLL
		_poll_loadouts()
	_roster_left -= delta
	if _roster_left <= 0.0:
		_roster_left = ROSTER_POLL
		_broadcast_roster()


func _client_tick(delta: float) -> void:
	_apply_correction(delta)
	if not local_player.dead:
		_send_state()
	var render := _host_tick_now() - INTERP_DELAY * Engine.physics_ticks_per_second
	for id: int in _buffers:
		var body := _player(id)
		if body != null and not body.dead:
			_interpolate(body, _buffers[id], render)


func _host_tick_now() -> float:
	return Engine.get_physics_frames() + _tick_offset


# ------------------------------------------------------------------ entities


## entities[id] as a live Player, or null. The value may be freed, so it is checked as a
## Variant before the cast (casting a freed object errors).
func _player(id: int) -> Player:
	var value: Variant = entities.get(id)
	if not is_instance_valid(value):
		return null
	return value as Player


func _make_puppet(id: int, info: Dictionary, host_side: bool) -> Player:
	var scene := load(PUPPET_SCENE) as PackedScene
	var puppet := scene.instantiate() as Player
	puppet.name = ("NetBot_%d" % -id) if id < 0 else ("NetPlayer_%d" % id)
	puppet.net_puppet = true
	puppet.net_damage_authority = host_side
	puppet.auto_respawn = false
	var holder := puppet.get_weapon_holder()
	if holder != null:
		holder.use_aim_assist = false
		holder.drop_weapons_on_death = host_side
	puppet.set_meta(&"display_name", str(info.get("name", "Player")))
	puppet.set_meta(&"net_id", id)
	get_parent().add_child(puppet)
	puppet.set_primary_color(
		Color.from_string(str(info.get("color", "")), PlayerColor.default_color())
	)
	entities[id] = puppet
	NetAnim.make_remote(puppet)
	return puppet


func _remove_entity(id: int) -> void:
	var body: Variant = entities.get(id)
	entities.erase(id)
	_buffers.erase(id)
	_net_host.remote.erase(id)
	_client_anim.erase(id)
	if body is Player and is_instance_valid(body) and body != local_player:
		if _host and spawn_manager != null:
			spawn_manager.unregister_player(body)
		(body as Node).queue_free()


## Host: death, damage and respawn of a body the host simulates go out to every peer.
func _hook_authority(id: int, body: Node3D) -> void:
	if body.has_meta(&"net_hooked"):
		return
	body.set_meta(&"net_hooked", true)
	body.connect(&"died", _on_authority_died)
	body.connect(&"damaged", _on_authority_damaged.bind(id))
	body.connect(&"respawned", _on_authority_respawned)


func _id_of(node: Variant) -> int:
	if node is Node and is_instance_valid(node):
		return int((node as Node).get_meta(&"net_id", 0))
	return 0


## Host: give new bots ids and hook them; drop freed ones.
func _refresh_bots() -> void:
	if spawn_manager == null:
		return
	for value in spawn_manager.bots:  # untyped: may hold a freed bot
		if not is_instance_valid(value) or _bot_ids.has(value):
			continue
		var bot: Bot = value
		var id := -_next_bot
		_next_bot += 1
		_bot_ids[bot] = id
		bot.set_meta(&"net_id", id)
		entities[id] = bot
		roster[id] = {"name": bot.display_name, "color": _bot_color(id), "kind": KIND_BOT}
		bot.set_primary_color(Color.from_string(_bot_color(id), PlayerColor.default_color()))
		_hook_authority(id, bot)
		for weapon: Weapon in bot.slots:
			_watch_fx_weapon(id, weapon)
		bot.weapon_changed.connect(func(w: BotWeapon) -> void: _watch_fx_weapon(id, w))
	for bot: Variant in _bot_ids.keys():
		if not is_instance_valid(bot):
			var id: int = _bot_ids[bot]
			_bot_ids.erase(bot)
			entities.erase(id)
			roster.erase(id)
			_client_anim.erase(id)


static func _bot_color(id: int) -> String:
	var preset: Dictionary = PlayerColor.PRESETS[absi(id) % PlayerColor.PRESETS.size()]
	return (preset.color as Color).to_html(false)


# ------------------------------------------------------------------ weapons (local side)


## Client: every local weapon's shots go to the host. Host: its own shots go out as FX.
func _watch_local_weapons(player: Player) -> void:
	var holder := player.get_weapon_holder()
	if holder == null:
		return
	var hook := func(_w: Weapon) -> void: _rewatch_local()
	holder.active_weapon_changed.connect(hook)
	_rewatch_local()


func _rewatch_local() -> void:
	var holder := local_player.get_weapon_holder()
	if holder == null:
		return
	for weapon in holder.get_weapons():
		weapon.hit_mask_override = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
		if _shots.has(weapon.get_instance_id()):
			continue
		var shot := NetShot.new(weapon)
		_shots[weapon.get_instance_id()] = shot
		shot.captured.connect(_on_local_shot)
		if not _host:
			weapon.melee_started.connect(_on_local_melee)


## Host: bots' shots become FX on the clients.
func _watch_fx_weapon(id: int, weapon: Weapon) -> void:
	if weapon == null or _shots.has(weapon.get_instance_id()):
		return
	var shot := NetShot.new(weapon)
	_shots[weapon.get_instance_id()] = shot
	shot.captured.connect(
		func(r: Array, tos: PackedVector3Array, hits: PackedByteArray) -> void:
			_broadcast_fx(id, r[NetShot.REQ_ORIGIN], tos, hits, 0)
	)


func _on_local_shot(request: Array, tos: PackedVector3Array, hits: PackedByteArray) -> void:
	if _host:
		_broadcast_fx(1, request[NetShot.REQ_ORIGIN], tos, hits, 0)
		return
	var render := roundi(_host_tick_now() - INTERP_DELAY * Engine.physics_ticks_per_second)
	_rpc_fire.rpc_id(1, render, request)


func _on_local_melee(_weapon: Weapon, _time_to_hit: float) -> void:
	_rpc_melee.rpc_id(1)


func _broadcast_fx(
	id: int, from: Vector3, tos: PackedVector3Array, hits: PackedByteArray, skip: int
) -> void:
	for peer: int in Net.players:
		if peer != 1 and peer != skip and peer != id:
			_rpc_shot_fx.rpc_id(peer, id, from, tos, hits)


# ------------------------------------------------------------------ client -> host


func _send_state() -> void:
	var player := local_player
	var flags := NetHost.FLAG_CROUCH if player.crouched else 0
	var weapon := player.get_active_weapon()
	if weapon != null:
		flags |= NetHost.FLAG_RELOADING if weapon.reloading else 0
		flags |= NetHost.FLAG_ZOOMED if weapon.zoomed else 0
	var holder := player.get_weapon_holder()
	var anim := NetAnim.capture(player)
	_rpc_state.rpc_id(
		1,
		_teleport_seq,
		player.global_position,
		player.rotation.y,
		player.head.rotation.x,
		flags,
		holder.active_index if holder != null else 0,
		anim,
		NetWeapon.state_of(weapon)
	)


func _request_pickup(pickup: WeaponPickup) -> void:
	var key := _pickups.key_of(pickup) if _pickups != null else ""
	if key != "":
		_rpc_pickup.rpc_id(1, key)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_ready() -> void:
	if not _host:
		return
	var peer := multiplayer.get_remote_sender_id()
	if not Net.players.has(peer) or entities.has(peer):
		return
	var info: Dictionary = Net.players[peer]
	roster[peer] = {
		"name": info.get("name", ""), "color": info.get("color", ""), "kind": KIND_HUMAN
	}
	var humans := 0
	for id: int in roster:
		humans += 1 if int(roster[id].kind) == KIND_HUMAN else 0
	if spawn_manager != null and humans + spawn_manager.bots.size() > Net.MAX_PLAYERS:
		spawn_manager.remove_bot()
		_refresh_bots()
	_broadcast_roster(true)
	_rpc_scores.rpc_id(peer, scores)
	_rpc_pickup_state.rpc_id(peer, _pickups.state())
	for message: Array in _pickups.drops():
		_rpc_drop.rpc_id(peer, message)
	var puppet := _make_puppet(peer, roster[peer], true)
	_net_host.add_client(peer)
	_hook_authority(peer, puppet)
	if spawn_manager != null:
		spawn_manager.register_player(puppet, HUMAN_TEAM_BASE + peer)
	# Everyone else's current pose and life, so the newcomer's puppets aren't stuck at origin.
	for id: int in entities:
		var body: Variant = entities[id]  # may be freed: check before any typed assignment
		if (
			id != peer
			and is_instance_valid(body)
			and body.has_method(&"is_dead")
			and body.call(&"is_dead")
		):
			_rpc_died.rpc_id(peer, id, 0, "", false, false, -1)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_state(
	seq: int,
	pos: Vector3,
	yaw: float,
	pitch: float,
	flags: int,
	slot: int,
	anim: Array,
	wstate: PackedFloat32Array
) -> void:
	var peer := multiplayer.get_remote_sender_id()
	var puppet := _player(peer)
	if not _host or puppet == null or not _net_host.has_client(peer) or puppet.dead:
		return
	if seq != int(_net_host.remote[peer].seq):
		return
	var allowed := _net_host.accept_state(peer, puppet, pos, yaw, pitch, flags)
	if allowed.distance_to(pos) > NetHost.MOVE_SLACK:
		_rpc_correct.rpc_id(peer, allowed, seq)
	_net_host.accept_inputs(peer, puppet, flags, slot, wstate)
	_remote_weapon_fx(peer, puppet, wstate)
	_client_anim[peer] = anim
	NetAnim.apply(puppet, anim, yaw, pitch)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_fire(render_tick: int, request: Array) -> void:
	var peer := multiplayer.get_remote_sender_id()
	var puppet := _player(peer)
	if not _host or puppet == null or not _net_host.has_client(peer) or puppet.dead:
		return
	var result := _net_host.fire(peer, puppet, render_tick, request)
	if not result.ok:
		return
	NetFx.spawn_shots(get_parent(), result.from, result.tos, result.hits)
	remote_shot.emit(peer, result.from, result.tos, result.hits)
	_broadcast_fx(peer, result.from, result.tos, result.hits, peer)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_melee() -> void:
	var peer := multiplayer.get_remote_sender_id()
	var puppet := _player(peer)
	if _host and puppet != null and _net_host.has_client(peer) and not puppet.dead:
		_net_host.melee(peer, puppet)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_pickup(key: String) -> void:
	var peer := multiplayer.get_remote_sender_id()
	var puppet := _player(peer)
	if not _host or puppet == null or puppet.dead:
		return
	var node := _pickups.find(key)
	if node == null or node.global_position.distance_to(puppet.global_position) > PICKUP_REACH:
		return
	var carrier := puppet.get_pickup_carrier()
	if carrier != null and node.has_method(&"try_pickup"):
		node.call(&"try_pickup", carrier)
	_poll_loadouts()


# ------------------------------------------------------------------ host -> clients


func _send_snapshot(tick: int) -> void:
	var entries: Array = []
	for id: int in entities:
		var value: Variant = entities[id]  # may be freed: check before the typed assignment
		if not is_instance_valid(value):
			continue
		var body: Node3D = value
		var head := body.get_node_or_null(^"Head") as Node3D
		var pitch := head.rotation.x if head != null else 0.0
		var health := body.get(&"health_shield") as HealthShield
		var vitals := Vector2(health.shield, health.health) if health != null else Vector2.ZERO
		var anim: Array = (
			NetAnim.override_life(_client_anim[id], body)
			if _client_anim.has(id)
			else NetAnim.capture(body)
		)
		var weapon := NetAnim.active_weapon_of(body)
		entries.append(
			[
				id,
				body.global_position,
				body.rotation.y,
				pitch,
				vitals,
				anim,
				NetWeapon.state_of(weapon)
			]
		)
	for peer: int in Net.players:
		if peer != 1:
			_rpc_snapshot.rpc_id(peer, tick, entries)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(tick: int, entries: Array) -> void:
	var observed := float(tick - Engine.get_physics_frames())
	if not _have_offset or observed > _tick_offset:
		_tick_offset = observed
		_have_offset = true
	else:
		_tick_offset = lerpf(_tick_offset, observed, 0.02)
	for entry: Array in entries:
		if entry.size() < 7:
			continue
		var id: int = entry[0]
		var value: Variant = entities.get(id)  # may be freed: check before the typed assignment
		if value == null or not is_instance_valid(value):
			continue
		var body: Node3D = value
		var vitals: Vector2 = entry[4]
		var health := body.get(&"health_shield") as HealthShield
		if health != null and not health.dead:
			health.apply_network_state(vitals.x, vitals.y)
		if body == local_player:
			continue
		var anim: Variant = entry[5]  # untyped RPC data: NetAnim.decode validates it
		var crouched := NetAnim.crouched_of(anim)
		var frames: Array = _buffers.get(id, [])
		frames.append([tick, entry[1], entry[2], entry[3], crouched])
		while frames.size() > 20:
			frames.pop_front()
		_buffers[id] = frames
		NetAnim.apply(body, anim, float(entry[2]), float(entry[3]))
		_remote_weapon_fx(id, body, entry[6])


func _interpolate(body: Player, frames: Array, render: float) -> void:
	if frames.is_empty():
		return
	var a: Array = frames[0]
	var b: Array = frames[-1]
	for i in range(frames.size() - 1):
		if float(frames[i + 1][0]) >= render:
			a = frames[i]
			b = frames[i + 1]
			break
	var span := float(b[0]) - float(a[0])
	var t := clampf((render - float(a[0])) / span, 0.0, 1.0) if span > 0.0 else 1.0
	var pos: Vector3 = (a[1] as Vector3).lerp(b[1], t)
	var yaw := lerp_angle(float(a[2]), float(b[2]), t)
	var pitch := lerpf(float(a[3]), float(b[3]), t)
	body.apply_net_pose(pos, yaw, pitch, bool(b[4]))


## Charge glow and overheat vent for bodies whose weapons this peer doesn't simulate.
func _remote_weapon_fx(id: int, body: Node3D, wstate: PackedFloat32Array) -> void:
	if wstate.size() != NetWeapon.STATE_KEYS.size() or body == local_player:
		return
	var head := body.get_node_or_null(^"Head") as Node3D
	if head == null:
		return
	var eye := head.global_position
	var forward := -head.global_basis.z
	NetFx.set_charge(body, eye, forward, wstate[3] > 0.5, wstate[4])
	var hot := wstate[2] > 0.5
	if hot and not _overheated.get(id, false):
		NetFx.vent(get_parent(), eye + forward * NetFx.MUZZLE_OFFSET)
	_overheated[id] = hot


@rpc("authority", "call_remote", "reliable")
func _rpc_correct(pos: Vector3, seq: int) -> void:
	if seq != _teleport_seq or local_player.dead:
		return
	var error := pos - local_player.global_position
	if error.length() > SNAP_DISTANCE:
		local_player.global_position = pos
		local_player.absorb_view_offset(error.y)
		_correction = Vector3.ZERO
	else:
		_correction = error


func _apply_correction(delta: float) -> void:
	if _correction.length_squared() < 0.000001:
		return
	var step := _correction * minf(SMOOTH_RATE * delta, 1.0)
	_correction -= step
	local_player.global_position += step
	local_player.absorb_view_offset(step.y)


@rpc("authority", "call_remote", "reliable")
func _rpc_shot_fx(id: int, from: Vector3, tos: PackedVector3Array, hits: PackedByteArray) -> void:
	NetFx.spawn_shots(get_parent(), from, tos, hits)
	remote_shot.emit(id, from, tos, hits)


## Host: roster to every client (only when changed unless force).
func _broadcast_roster(force: bool = false) -> void:
	var sig := var_to_str(roster)
	if sig == _roster_sig and not force:
		return
	_roster_sig = sig
	for peer: int in Net.players:
		if peer != 1:
			_rpc_roster.rpc_id(peer, roster)


@rpc("authority", "call_remote", "reliable")
func _rpc_roster(new_roster: Dictionary) -> void:
	roster = new_roster
	var me := Net.my_id()
	for id: int in roster:
		if id != me and not entities.has(id):
			_make_puppet(id, roster[id], false)
	for id: int in entities.keys():
		if id != me and not roster.has(id):
			_remove_entity(id)


func _on_players_changed() -> void:
	if not _host:
		return
	var left := 0
	for id: int in roster.keys():
		if id > 1 and not Net.players.has(id):
			left += 1 if int(roster[id].kind) == KIND_HUMAN else 0
			roster.erase(id)
			_remove_entity(id)
	if Net.bot_refill and left > 0:
		_refill_bots(left)


## Host, "refill empty slots with bots" on: one bot per human who left, up to MAX_PLAYERS.
## Off (the default), a leaver's slot stays empty for the next joiner.
func _refill_bots(count: int) -> void:
	if spawn_manager == null:
		return
	var humans := 0
	for id: int in roster:
		humans += 1 if int(roster[id].kind) == KIND_HUMAN else 0
	var alive := 0
	for bot in spawn_manager.bots:
		alive += 1 if is_instance_valid(bot) else 0
	for i in mini(count, Net.MAX_PLAYERS - humans - alive):
		spawn_manager.add_bot()
	_refresh_bots()
	_broadcast_roster(true)


func _poll_loadouts() -> void:
	for peer: int in _net_host.remote:
		var puppet := _player(peer)
		if puppet == null:
			continue
		var change := _net_host.poll_loadout(peer, puppet)
		if change.has("loadout"):
			_rpc_loadout.rpc_id(peer, change.loadout[0], change.loadout[1])
		for gain: Array in change.get("ammo", []):
			_rpc_ammo.rpc_id(peer, gain[0], gain[1])


@rpc("authority", "call_remote", "reliable")
func _rpc_loadout(entries: Array, active: int) -> void:
	var holder := local_player.get_weapon_holder()
	if holder == null:
		return
	var current: Array[String] = []
	for weapon in holder.slots:
		current.append(NetWeapon.id_of(weapon) if weapon != null else "")
	var wanted: Array[String] = []
	for entry: Dictionary in entries:
		wanted.append(str(entry.get("id", "")))
		if entry.has("scene"):
			entry["scene"] = NetWeapon.scene_of(str(entry.scene))
	# Same id kept by apply_loadout: a battery weapon still takes the host's charge (swap).
	for i in mini(entries.size(), holder.slots.size()):
		var kept := holder.slots[i]
		if kept != null and current[i] == wanted[i] and NetWeapon.is_battery(kept.data):
			kept.magazine = int(entries[i].get("magazine", kept.magazine))
			kept.ammo_changed.emit(kept.magazine, kept.reserve)
	if current == wanted:
		return
	holder.apply_loadout(entries, active)
	# Heat / vent time of a picked-up heat weapon, after apply_loadout's fresh instance _ready.
	for i in mini(entries.size(), holder.slots.size()):
		var entry: Dictionary = entries[i]
		if holder.slots[i] != null and current.find(str(entry.get("id", ""))) < 0:
			NetWeapon.apply_heat(holder.slots[i], entry.get("heat_state", {}))
	_rewatch_local()


@rpc("authority", "call_remote", "reliable")
func _rpc_ammo(weapon_id: String, amount: int) -> void:
	var holder := local_player.get_weapon_holder()
	var weapon := holder.find_weapon(weapon_id) if holder != null else null
	if weapon != null:
		weapon.add_ammo(amount)


# ------------------------------------------------------------------ life and death


func _on_authority_died(body: Node3D, killer: Node, info: Dictionary) -> void:
	var id := _id_of(body)
	# Death dir / impulse for the animation come from each body's CharacterAnimSource (died).
	var dir: Vector3 = info.get("dir", Player.damage_direction(body, info))
	var killer_id := _id_of(killer)
	var weapon_name := str(info.get("weapon", ""))
	var headshot := bool(info.get("headshot", false))
	var melee := bool(info.get("melee", false))
	var text := _feed_for(
		id, killer_id, weapon_name, headshot, melee, info.get("kill_volume", false)
	)
	kill_feed.emit(text)
	for peer: int in Net.players:
		if peer != 1:
			_rpc_feed.rpc_id(peer, text)
	for peer: int in Net.players:
		if peer != 1:
			_rpc_died.rpc_id(peer, id, killer_id, weapon_name, headshot, melee, _quant_dir(dir))


@rpc("authority", "call_remote", "reliable")
func _rpc_died(
	id: int, killer_id: int, weapon_name: String, headshot: bool, melee: bool, dir_q: int
) -> void:
	var body := _player(id)
	if body == null or body.dead:
		return
	var dir := _unquant_dir(dir_q)
	var info := {
		"weapon": weapon_name, "headshot": headshot, "melee": melee, "dir": dir, "direction": dir
	}
	var killer: Variant = entities.get(killer_id)
	if killer is Node and is_instance_valid(killer):
		info["source"] = killer
	body.net_force_death(info)


func _on_local_died_client(_player: Player, _killer: Node, _info: Dictionary) -> void:
	_correction = Vector3.ZERO


func _on_authority_damaged(amount: float, info: Dictionary, id: int) -> void:
	var dir: Vector3 = info.get("dir", Vector3.ZERO)
	for peer: int in Net.players:
		if peer != 1:
			_rpc_damaged.rpc_id(peer, id, amount, _quant_dir(dir))


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_damaged(id: int, amount: float, dir_q: int) -> void:
	var body := _player(id)
	if body != null and not body.dead:
		var dir := _unquant_dir(dir_q)
		body.damaged.emit(amount, {"dir": dir, "direction": dir, "net": true})


func _on_authority_respawned(body: Node3D) -> void:
	var id := _id_of(body)
	NetAnim.reset(body)
	var seq := _net_host.on_respawn(id) if _net_host.has_client(id) else 0
	for peer: int in Net.players:
		if peer != 1:
			_rpc_respawned.rpc_id(peer, id, body.global_position, body.rotation.y, seq)


@rpc("authority", "call_remote", "reliable")
func _rpc_respawned(id: int, pos: Vector3, yaw: float, seq: int) -> void:
	var body := _player(id)
	if body == null:
		return
	if body == local_player:
		_teleport_seq = seq
		_correction = Vector3.ZERO
	_buffers.erase(id)
	body.respawn_at(Transform3D(Basis(Vector3.UP, yaw), pos))
	NetAnim.reset(body)


## Dir as yaw byte | pitch byte << 8, -1 for none.
static func _quant_dir(dir: Vector3) -> int:
	if dir.length_squared() < 0.0001:
		return -1
	var d := dir.normalized()
	var yaw := wrapi(roundi(atan2(d.x, d.z) / TAU * 256.0), 0, 256)
	var pitch := clampi(roundi(asin(clampf(d.y, -1.0, 1.0)) / PI * 254.0) + 127, 0, 254)
	return yaw | (pitch << 8)


static func _unquant_dir(q: int) -> Vector3:
	if q < 0:
		return Vector3.ZERO
	var yaw := float(q & 0xff) / 256.0 * TAU
	var pitch := (float((q >> 8) & 0xff) - 127.0) / 254.0 * PI
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


# ------------------------------------------------------------------ pickups


func _scan_pickups() -> void:
	if _pickups != null:
		_pickups.scan()


func _on_node_added(node: Node) -> void:
	if not _host or not node is WeaponPickup or not (node as WeaponPickup).dropped:
		return
	_announce_drop.call_deferred(node)


func _announce_drop(pickup: WeaponPickup) -> void:
	if not is_instance_valid(pickup) or pickup.has_meta(&"net_key"):
		return
	var message := _pickups.register_drop(pickup)
	if message.is_empty():
		return
	for peer: int in Net.players:
		if peer != 1:
			_rpc_drop.rpc_id(peer, message)


func _send_pickup_state() -> void:
	var state := _pickups.state()
	if state == _last_pickups:
		return
	_last_pickups = state
	for peer: int in Net.players:
		if peer != 1:
			_rpc_pickup_state.rpc_id(peer, state)


@rpc("authority", "call_remote", "reliable")
func _rpc_pickup_state(state: Dictionary) -> void:
	if _pickups != null:
		_pickups.apply_state(state)


@rpc("authority", "call_remote", "reliable")
func _rpc_drop(message: Array) -> void:
	if _pickups != null:
		_pickups.spawn_drop(message)


# ------------------------------------------------------------------ scores and the end


func _on_scores(new_scores: Dictionary) -> void:
	scores = new_scores.duplicate(true)
	scores_changed.emit(scores)
	if _online and _host:
		for peer: int in Net.players:
			if peer != 1:
				_rpc_scores.rpc_id(peer, scores)


@rpc("authority", "call_remote", "reliable")
func _rpc_scores(new_scores: Dictionary) -> void:
	scores = new_scores
	scores_changed.emit(scores)


@rpc("authority", "call_remote", "reliable")
func _rpc_feed(text: String) -> void:
	kill_feed.emit(text)


func _feed_for(
	id: int, killer_id: int, weapon_name: String, headshot: bool, melee: bool, fell: bool
) -> String:
	var victim := _name_for(id)
	var text := "%s died" % victim
	if fell:
		text = "%s fell" % victim
	elif killer_id != 0 and killer_id != id:
		var how := weapon_name
		if melee:
			how += " melee"
		elif headshot:
			how += " headshot"
		text = "%s killed %s (%s)" % [_name_for(killer_id), victim, how.strip_edges()]
	return text


func _name_for(id: int) -> String:
	var info: Dictionary = roster.get(id, {})
	if info.has("name"):
		return str(info.name)
	var body: Variant = entities.get(id)
	if body is Node and is_instance_valid(body):
		return str((body as Node).get_meta(&"display_name", (body as Node).name))
	return "?"


func _on_match_won(winner: String, final_scores: Dictionary) -> void:
	if not _online:
		_ui.show_banner("%s wins!" % winner)
		return
	is_game_over = true
	game_over.emit(winner, final_scores)
	for peer: int in Net.players:
		if peer != 1:
			_rpc_game_over.rpc_id(peer, winner, final_scores)


@rpc("authority", "call_remote", "reliable")
func _rpc_game_over(winner: String, final_scores: Dictionary) -> void:
	is_game_over = true
	scores = final_scores
	game_over.emit(winner, final_scores)
