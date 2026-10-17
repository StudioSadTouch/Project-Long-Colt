class_name CtfMatch
extends Node
## Capture the Flag (GameModes objective "ctf"). NetMatch adds it as "Ctf" on every peer, so
## its RPC path matches everywhere. Red vs Blue, first to capture_limit captures wins; kills
## don't end the match (SpawnManager.kill_win is off).
##
## Rules (host only; clients mirror the synced state):
##   take     an enemy touches a flag at home or on the ground: it rides on their back
##   drop     the carrier dies (or leaves): the flag falls where they were. RETURN_TIME later it
##            goes home on its own; a flag that fell off the map goes home at once
##   return   a defender touches their own dropped flag: home at once
##   capture  a carrier touches their own base while their own flag is home: +1 capture, the
##            enemy flag goes home. Carriers keep their weapons.
## Bases: FLAG_Red* / FLAG_Blue* nodes in the arena if a map has them, else the team spawn
## nearest the centre of that team's spawns. A map with no team spawns (Lockout) gets the two
## free-for-all spawns farthest apart, and every other spawn goes to the nearer base
## (SpawnManager.team_spawn_override), so each team spawns at its own end.
##
## Netcode: the host sends [captures, flag states, carrier net ids, positions] to every client
## on every change and once a second (late joiners), plus feed / banner text. A carried flag
## is drawn on its carrier on every peer (net id -> NetMatch.entities).
## Bots: BotBrain asks goal_for(bot) (attack, carry home, escort, return, defend).
## HUD: CtfHud (local player only): score, flag markers, carrier prompt.

signal changed

enum FlagState { HOME, CARRIED, DROPPED }

const GROUP := &"ctf"
const PICKUP_RADIUS := 1.6
const PICKUP_HEIGHT := 2.4
const CAPTURE_RADIUS := 2.4
const RETURN_TIME := 25.0
const SYNC_INTERVAL := 1.0
## Below this (relative to the base) a dropped flag is off the map: it goes home.
const LOST_DEPTH := 25.0
const STATE_NAMES := ["HOME", "CARRIED", "DROPPED"]

var capture_limit: int = 3
## The parent NetMatch, untyped for the same reason as _net() (NetMatch names Net).
var net_match: Node
var spawn_manager: SpawnManager
## Team id -> captures.
var captures: Dictionary = {}
## Team id -> {team, state, home, pos, carrier (Node3D or null), drop_left, visual}
var flags: Dictionary = {}

var _host: bool = true
var _over: bool = false
var _dirty: bool = true
var _sync_left: float = 0.0
var _visuals: Node3D
var _hud: CtfHud


static func create(limit: int) -> CtfMatch:
	var ctf := CtfMatch.new()
	ctf.name = "Ctf"
	ctf.capture_limit = limit
	return ctf


static func find(tree: SceneTree) -> CtfMatch:
	return tree.get_first_node_in_group(GROUP) as CtfMatch if tree != null else null


func _ready() -> void:
	add_to_group(GROUP)
	net_match = get_parent()
	_host = multiplayer.is_server()
	if net_match != null and &"spawn_manager" in net_match:
		spawn_manager = net_match.get(&"spawn_manager") as SpawnManager
		net_match.game_over.connect(func(_w: String, _s: Dictionary) -> void: _over = true)
		changed.connect(_refresh_board)
	if spawn_manager != null:
		spawn_manager.kill_win = false
		spawn_manager.objective_name = "Capture the Flag (to %d)" % capture_limit
	_visuals = Node3D.new()
	_visuals.name = "Flags"
	add_child(_visuals)
	var bases := _find_bases()
	for team: int in GameMode.TEAMS:
		captures[team] = 0
		var home: Vector3 = bases.get(team, Vector3.ZERO)
		flags[team] = {
			"team": team,
			"state": FlagState.HOME,
			"home": home,
			"pos": home,
			"carrier": null,
			"drop_left": 0.0,
			"visual": _make_flag(team),
		}
		_make_base(team, home)
	if net_match != null and net_match.local_player != null and DisplayServer.get_name() != "headless":
		_hud = CtfHud.new()
		_hud.ctf = self
		_hud.player = net_match.local_player
		add_child(_hud)


func _physics_process(delta: float) -> void:
	if _host and not _over:
		_host_tick(delta)


func _process(_delta: float) -> void:
	for flag: Dictionary in flags.values():
		_place_visual(flag)


func _refresh_board() -> void:
	var ui := net_match.get_node_or_null(^"MatchUI")  # untyped: MatchUI names NetMatch
	if ui != null:
		ui.call(&"refresh_scores")


# ------------------------------------------------------------------ queries


func other_team(team: int) -> int:
	return GameMode.TEAM_BLUE if team == GameMode.TEAM_RED else GameMode.TEAM_RED


func flag_of(team: int) -> Dictionary:
	return flags.get(team, {})


## The flag `body` carries ({} if none).
func carried_by(body: Node) -> Dictionary:
	for flag: Dictionary in flags.values():
		if flag.state == FlagState.CARRIED and flag.carrier == body and body != null:
			return flag
	return {}


## World position of a flag right now (on its carrier when carried).
func flag_position(flag: Dictionary) -> Vector3:
	var carrier: Variant = flag.carrier
	if flag.state == FlagState.CARRIED and is_instance_valid(carrier):
		return (carrier as Node3D).global_position
	return flag.pos


## Bot objective: {"pos": Vector3, "carrier": bool, "guard": bool} or {} (just fight / roam).
## Roles are fixed per bot: a third defend, the rest attack.
func goal_for(bot: Node3D) -> Dictionary:
	var team := ArenaEvents.team_of(bot)
	if not GameMode.is_team_id(team) or _over:
		return {}
	var own: Dictionary = flags[team]
	var enemy: Dictionary = flags[other_team(team)]
	if enemy.state == FlagState.CARRIED and enemy.carrier == bot:
		return {"pos": own.home, "carrier": true}
	var defender := _is_defender(bot)
	var to_own := bot.global_position.distance_to(flag_position(own))
	var to_enemy := bot.global_position.distance_to(flag_position(enemy))
	if own.state == FlagState.DROPPED and (defender or to_own < to_enemy):
		return {"pos": own.pos}
	if own.state == FlagState.CARRIED and (defender or to_own < 25.0):
		return {"pos": flag_position(own)}  # run the thief down
	if defender:
		return {"pos": own.home, "guard": true}
	if enemy.state == FlagState.CARRIED:
		return {"pos": flag_position(enemy)}  # escort the teammate carrying it
	return {"pos": enemy.pos}


func _is_defender(bot: Node) -> bool:
	return hash(str(bot.name)) % 3 == 0


# ------------------------------------------------------------------ host rules


func _host_tick(delta: float) -> void:
	for flag: Dictionary in flags.values():
		match flag.state:
			FlagState.CARRIED:
				var carrier: Variant = flag.carrier
				if not is_instance_valid(carrier) or not ArenaEvents.is_alive(carrier):
					_drop(flag)
				else:
					flag.pos = (carrier as Node3D).global_position
			FlagState.DROPPED:
				flag.drop_left -= delta
				if flag.drop_left <= 0.0:
					_return(flag, null)
	for body in _combatants():
		var team := ArenaEvents.team_of(body)
		if not GameMode.is_team_id(team):
			continue
		var own: Dictionary = flags[team]
		var enemy: Dictionary = flags[other_team(team)]
		if enemy.state != FlagState.CARRIED and _touching(body, enemy.pos, PICKUP_RADIUS):
			_take(enemy, body)
		if own.state == FlagState.DROPPED and _touching(body, own.pos, PICKUP_RADIUS):
			_return(own, body)
		var carrying: bool = enemy.state == FlagState.CARRIED and enemy.carrier == body
		if carrying and own.state == FlagState.HOME and _touching(body, own.home, CAPTURE_RADIUS):
			_capture(enemy, body)
			if _over:
				break
	_sync_left -= delta
	if _dirty or _sync_left <= 0.0:
		_sync_left = SYNC_INTERVAL
		_dirty = false
		_send_state()


func _combatants() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for group: StringName in [&"player", &"bot"]:
		for node in get_tree().get_nodes_in_group(group):
			var body := node as Node3D
			if body != null and not out.has(body) and ArenaEvents.is_alive(body):
				out.append(body)
	return out


func _touching(body: Node3D, point: Vector3, radius: float) -> bool:
	var d := body.global_position - point
	return Vector2(d.x, d.z).length() <= radius and absf(d.y) <= PICKUP_HEIGHT


func _take(flag: Dictionary, body: Node3D) -> void:
	flag.state = FlagState.CARRIED
	flag.carrier = body
	flag.pos = body.global_position
	_dirty = true
	_announce("%s took the %s flag" % [_name(body), _team_word(flag.team)], "")


func _drop(flag: Dictionary) -> void:
	var at: Vector3 = flag.pos
	flag.carrier = null
	var floor_at := _floor_below(at)
	if floor_at == Vector3.INF or floor_at.y < flag.home.y - LOST_DEPTH:
		_return(flag, null)
		return
	flag.state = FlagState.DROPPED
	flag.pos = floor_at
	flag.drop_left = RETURN_TIME
	_dirty = true
	_announce("The %s flag was dropped" % _team_word(flag.team), "")


func _return(flag: Dictionary, by: Node3D) -> void:
	flag.state = FlagState.HOME
	flag.carrier = null
	flag.pos = flag.home
	_dirty = true
	if by != null:
		_announce("%s returned the %s flag" % [_name(by), _team_word(flag.team)], "")
	else:
		_announce("The %s flag returned" % _team_word(flag.team), "")


func _capture(flag: Dictionary, body: Node3D) -> void:
	var team := ArenaEvents.team_of(body)
	captures[team] = int(captures[team]) + 1
	flag.state = FlagState.HOME
	flag.carrier = null
	flag.pos = flag.home
	_dirty = true
	if spawn_manager != null:
		spawn_manager.add_objective_score(body, "caps")
	var team_name := GameMode.team_name(team)
	_announce(
		"%s captured the %s flag (%d / %d)"
		% [_name(body), _team_word(flag.team), captures[team], capture_limit],
		"%s scores!" % team_name
	)
	if int(captures[team]) < capture_limit:
		return
	_send_state()
	if spawn_manager != null:
		spawn_manager.declare_winner(team_name)
	if net_match == null or not _online():
		# Offline plays on: SpawnManager reset the scores, the flags start over.
		for t: int in captures:
			captures[t] = 0
		for f: Dictionary in flags.values():
			f.state = FlagState.HOME
			f.carrier = null
			f.pos = f.home
		_dirty = true
	else:
		_over = true


## Floor under a point (World layer), or Vector3.INF if nothing within LOST_DEPTH.
func _floor_below(at: Vector3) -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		at + Vector3.UP * 1.0, at + Vector3.DOWN * LOST_DEPTH, 1
	)
	var hit := space.intersect_ray(query)
	return hit.position if not hit.is_empty() else Vector3.INF


func _name(body: Node) -> String:
	if body is Bot:
		return (body as Bot).display_name
	return str(body.get_meta(&"display_name", body.name))


func _team_word(team: int) -> String:
	return "Red" if team == GameMode.TEAM_RED else "Blue"


# ------------------------------------------------------------------ sync and events


## The Net autoload, looked up at runtime: naming it here would make every script that names
## CtfMatch (BotBrain, MatchUI) fail to compile in --script test runs, where autoloads aren't
## identifiers yet.
func _net() -> Node:
	return get_node_or_null(^"/root/Net")


func _online() -> bool:
	var net := _net()
	return net != null and bool(net.call(&"is_online"))


## Client peer ids to send to (never the host, 1).
func _peers() -> Array:
	var net := _net()
	var out: Array = []
	if net != null:
		for peer: int in (net.get(&"players") as Dictionary):
			if peer != 1:
				out.append(peer)
	return out


func _announce(text: String, banner: String) -> void:
	_show_event(text, banner)
	if net_match == null or not _online() or not _host:
		return
	for peer: int in _peers():
		_rpc_event.rpc_id(peer, text, banner)


func _show_event(text: String, banner: String) -> void:
	print("[CTF] ", text)
	changed.emit()
	if net_match == null:
		return
	net_match.kill_feed.emit(text)
	var ui := net_match.get_node_or_null(^"MatchUI")
	if ui != null and banner != "":
		ui.call(&"show_banner", banner)


func _state_payload() -> Array:
	var out: Array = [captures.get(GameMode.TEAM_RED, 0), captures.get(GameMode.TEAM_BLUE, 0)]
	for team: int in GameMode.TEAMS:
		var flag: Dictionary = flags[team]
		var carrier_id := 0
		var carrier: Variant = flag.carrier
		if flag.state == FlagState.CARRIED and is_instance_valid(carrier):
			carrier_id = int((carrier as Node).get_meta(&"net_id", 0))
		out.append_array([int(flag.state), carrier_id, flag.pos])
	return out


func _send_state() -> void:
	changed.emit()
	if net_match == null or not _online():
		return
	var payload := _state_payload()
	for peer: int in _peers():
		_rpc_state.rpc_id(peer, payload)


@rpc("authority", "call_remote", "reliable")
func _rpc_state(payload: Array) -> void:
	if payload.size() < 2 + 3 * GameMode.TEAMS.size():
		return
	captures[GameMode.TEAM_RED] = int(payload[0])
	captures[GameMode.TEAM_BLUE] = int(payload[1])
	var i := 2
	for team: int in GameMode.TEAMS:
		var flag: Dictionary = flags[team]
		flag.state = int(payload[i])
		var carrier_id := int(payload[i + 1])
		flag.pos = payload[i + 2]
		flag.carrier = null
		if flag.state == FlagState.CARRIED and net_match != null:
			var body: Variant = net_match.entities.get(carrier_id)
			if is_instance_valid(body):
				flag.carrier = body
		i += 3
	changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_event(text: String, banner: String) -> void:
	_show_event(text, banner)


# ------------------------------------------------------------------ bases


## Team id -> base position. Also hands SpawnManager per-team spawns on maps without team
## spawn markers.
func _find_bases() -> Dictionary:
	var arena := get_parent().get_parent() if get_parent() != null else null
	var bases := {}
	if arena == null:
		return bases
	for node in arena.find_children("FLAG_*", "Node3D", true, false):
		var flag_name := str(node.name)
		for team: int in GameMode.TEAMS:
			if flag_name.begins_with("FLAG_" + _team_word(team)) and not bases.has(team):
				bases[team] = (node as Node3D).global_position
	if bases.size() == GameMode.TEAMS.size():
		return bases
	var spawns := _spawn_markers(arena)
	var by_team := {}
	var free: Array[Node3D] = []
	for spawn in spawns:
		var assigned := false
		for team: int in GameMode.SPAWN_PREFIX:
			if str(spawn.name).begins_with(str(GameMode.SPAWN_PREFIX[team])):
				if not by_team.has(team):
					by_team[team] = [] as Array[Node3D]
				(by_team[team] as Array[Node3D]).append(spawn)
				assigned = true
		if not assigned:
			free.append(spawn)
	if by_team.size() == GameMode.TEAMS.size():
		for team: int in GameMode.TEAMS:
			if not bases.has(team):
				bases[team] = _central(by_team[team])
		return bases
	# No team spawns: the farthest-apart pair of spawns are the bases (Red the first in name
	# order, so every peer agrees), and the rest split by distance.
	free.sort_custom(func(a: Node3D, b: Node3D) -> bool: return str(a.name) < str(b.name))
	if free.size() < 2:
		return bases
	var best := [free[0], free[1]]
	var best_d := -1.0
	for i in free.size():
		for j in range(i + 1, free.size()):
			var d := _flat(free[i].global_position - free[j].global_position)
			if d > best_d:
				best_d = d
				best = [free[i], free[j]]
	bases[GameMode.TEAM_RED] = (best[0] as Node3D).global_position
	bases[GameMode.TEAM_BLUE] = (best[1] as Node3D).global_position
	var split := {GameMode.TEAM_RED: [] as Array[Node3D], GameMode.TEAM_BLUE: [] as Array[Node3D]}
	for spawn in free:
		var red := _flat(spawn.global_position - bases[GameMode.TEAM_RED])
		var blue := _flat(spawn.global_position - bases[GameMode.TEAM_BLUE])
		(split[GameMode.TEAM_RED if red <= blue else GameMode.TEAM_BLUE] as Array[Node3D]).append(spawn)
	if spawn_manager != null:
		spawn_manager.team_spawn_override = split
	return bases


func _spawn_markers(arena: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var roots: Array[NodePath] = [^"Spawns"]
	if spawn_manager != null:
		roots = spawn_manager.spawn_roots
	for path in roots:
		var root := spawn_manager.get_node_or_null(path) if spawn_manager != null else null
		if root == null:
			continue
		for child in root.get_children():
			if child is Node3D:
				out.append(child as Node3D)
	if out.is_empty():
		for node in arena.find_children("SPAWN_*", "Node3D", true, false):
			out.append(node as Node3D)
	return out


## The spawn nearest the centre of a group (a real, standable spot).
static func _central(spawns: Array) -> Vector3:
	var centre := Vector3.ZERO
	for s: Node3D in spawns:
		centre += s.global_position
	centre /= maxf(spawns.size(), 1)
	var best: Node3D = spawns[0]
	for s: Node3D in spawns:
		if _flat(s.global_position - centre) < _flat(best.global_position - centre):
			best = s
	return best.global_position


static func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


# ------------------------------------------------------------------ visuals


func _make_flag(team: int) -> Node3D:
	var root := Node3D.new()
	root.name = "%sFlag" % _team_word(team)
	_visuals.add_child(root)
	var color := GameMode.team_color(team)
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.03
	pole_mesh.height = 2.3
	pole.mesh = pole_mesh
	pole.material_override = _mat(Color(0.75, 0.76, 0.78), Color.BLACK)
	pole.position = Vector3(0, 1.15, 0)
	root.add_child(pole)
	var cloth := MeshInstance3D.new()
	var cloth_mesh := BoxMesh.new()
	cloth_mesh.size = Vector3(0.03, 0.55, 0.9)
	cloth.mesh = cloth_mesh
	cloth.material_override = _mat(color.lightened(0.15), color)
	cloth.position = Vector3(0, 1.98, 0.47)
	root.add_child(cloth)
	var light := OmniLight3D.new()
	light.light_color = color.lightened(0.3)
	light.light_energy = 1.2
	light.omni_range = 4.0
	light.position = Vector3(0, 1.8, 0)
	root.add_child(light)
	return root


func _make_base(team: int, home: Vector3) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "%sBase" % _team_word(team)
	var torus := TorusMesh.new()
	torus.inner_radius = CAPTURE_RADIUS - 0.18
	torus.outer_radius = CAPTURE_RADIUS
	torus.rings = 48
	torus.ring_segments = 6
	ring.mesh = torus
	var color := GameMode.team_color(team)
	ring.material_override = _mat(color.lightened(0.2), color.lightened(0.1))
	ring.scale = Vector3(1.0, 0.25, 1.0)
	_visuals.add_child(ring)
	ring.global_position = home + Vector3.UP * 0.05


func _place_visual(flag: Dictionary) -> void:
	var visual := flag.visual as Node3D
	if visual == null:
		return
	var carrier: Variant = flag.carrier
	if flag.state == FlagState.CARRIED and is_instance_valid(carrier):
		var body := carrier as Node3D
		# Over the back, leaning back a little.
		var back := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-18.0)), Vector3(0.2, 0.85, 0.32))
		visual.global_transform = Transform3D(Basis(Vector3.UP, body.global_rotation.y), body.global_position) * back
		# Your own flag on your back would fill the first-person view: draw it only for the
		# third-person camera (Player.HIDDEN_BODY_LAYER, like your body).
		_set_layers(visual, Player.HIDDEN_BODY_LAYER if body == _local_player() else 1)
	else:
		visual.global_transform = Transform3D(Basis.IDENTITY, flag.pos)
		_set_layers(visual, 1)


func _local_player() -> Node:
	return net_match.local_player if net_match != null else null


static func _set_layers(root: Node3D, layers: int) -> void:
	for child in root.get_children():
		var geo := child as GeometryInstance3D
		if geo != null and geo.layers != layers:
			geo.layers = layers


static func _mat(albedo: Color, emission: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = 0.6
	if emission != Color.BLACK:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = 1.5
	return mat
