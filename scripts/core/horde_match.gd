class_name HordeMatch
extends Node
## Horde (GameModes objective "horde"): co-op survival against waves of New Ottoman enemies,
## Firefight style. NetMatch adds it as "Horde" on every peer.
##
## LAN (protocol 11): the host runs everything below. Clients mirror it: the enemies through
## NetEnemies (child "Enemies": visual copies, see that class), and the match state (wave,
## phase, countdown, lives, enemies left, hunt, who is down) through _rpc_state, sent twice a
## second and on every change, plus banners and the enemy kill feed. Every human and bot is on
## SpawnManager.PLAYER_TEAM (NetMatch puts remote humans there in Horde).
##
## Flow: the navmesh bakes, a short countdown, then waves from HordeWaves. Each squad of a wave
## is an Orta in assault mode, spawned around the map spawn point farthest from (and out of
## sight of) the defenders, with shared contact on the nearest defender so it comes looking.
## A wave ends when its last enemy dies; INTERMISSION seconds later the next one starts.
## Squads that would push the living count past HordeWaves.MAX_ALIVE wait for room.
##
## Defenders: the player(s) and the Bot Arena bots, all on SpawnManager.PLAYER_TEAM
## (SpawnManager.coop_team). Lives are shared: every player death spends one to respawn; at 0
## a dead player stays down (SpawnManager.respawn_gate) until a round bonus brings them back.
## Every round (HordeWaves.ROUND_LENGTH waves) ends with +LIVES_PER_ROUND lives. Between
## waves everyone is resupplied (reserves, batteries, grenades). Bots respawn for free.
## Game over: every player down with no lives left (NetMatch.end_match, "The Porte" wins).
##
## Stall breaker: once a wave is down to HUNT_REMAINING enemies, or has run HUNT_AFTER
## seconds, every HUNT_INTERVAL the survivors hunt the nearest defender (Orta.hunt), and the
## HUD marks them.
## Score: kills and HordeWaves points per kill go to the killer's scoreboard row.

signal wave_started(wave: int)
signal wave_cleared(wave: int)
signal lives_changed(lives: int)

## WAITING: for the navmesh. STARTING: the countdown to wave 1.
enum Phase { WAITING, STARTING, INTERMISSION, WAVE, OVER }

const GROUP := &"horde"
const TYPES := "res://resources/enemies/new_ottoman/%s.tres"
const START_LIVES := 7
const LIVES_PER_ROUND := 3
const MAX_LIVES := 12
## Seconds from the navmesh bake to wave 1, and between waves.
const FIRST_DELAY := 8.0
const INTERMISSION := 12.0
const HUNT_REMAINING := 3
const HUNT_AFTER := 75.0
const HUNT_INTERVAL := 6.0
## Firefight-style: every squad is told where the nearest defender is this often, so a wave
## always comes looking (it still has to see you before it shoots).
const CONTACT_INTERVAL := 4.0
## Dead enemies (their weapons already dropped) are cleared after this.
const CORPSE_TIME := 8.0
## Squad members stand in rings this far apart around their spawn point.
const SQUAD_SPACING := 1.8
## Squad spawns this close to another squad of the same wave are penalised.
const SQUAD_SEPARATION := 10.0
const LOS_MASK := 1
## Host: seconds between state syncs to clients, and between checks for newly joined players.
const SYNC_INTERVAL := 0.5
const PLAYER_POLL := 1.0

var net_match: Node
var spawn_manager: SpawnManager
var phase: Phase = Phase.WAITING
var wave: int = 0
var lives: int = START_LIVES
## Seconds left in the countdown before the next wave (STARTING / INTERMISSION).
var time_left: float = 0.0
var wave_time: float = 0.0
## Host: the living enemies. Client: the living copies (NetEnemies keeps it).
var enemies: Array[Enemy] = []
var ortas: Array[Orta] = []
var net_enemies: NetEnemies

var _host: bool = true
var _pending: Array = []  # squads (Array[String]) waiting for room
var _used_spawns: Array[Vector3] = []
var _down: Dictionary = {}  # Player -> true: dead, no life to respawn with
var _hunt_left: float = 0.0
var _contact_left: float = 0.0
var _types: Dictionary = {}
var _hud: HordeHud
var _hooked: Dictionary = {}  # Player -> true: died connected
var _sync_left: float = 0.0
var _poll_left: float = 0.0
# Client mirror of the host's state.
var _client_left: int = 0
var _client_hunting: bool = false
var _down_names: PackedStringArray = PackedStringArray()


static func create() -> HordeMatch:
	var horde := HordeMatch.new()
	horde.name = "Horde"
	return horde


static func find(tree: SceneTree) -> HordeMatch:
	return tree.get_first_node_in_group(GROUP) as HordeMatch if tree != null else null


func _ready() -> void:
	add_to_group(GROUP)
	net_match = get_parent()
	_host = multiplayer.is_server()
	if net_match != null and &"spawn_manager" in net_match:
		spawn_manager = net_match.get(&"spawn_manager") as SpawnManager
	net_enemies = NetEnemies.new()
	net_enemies.name = "Enemies"
	add_child(net_enemies)
	var player: Player = net_match.get(&"local_player") if net_match != null else null
	if player != null and DisplayServer.get_name() != "headless":
		_hud = HordeHud.new()
		_hud.horde = self
		_hud.player = player
		add_child(_hud)
	if not _host:
		return  # a client mirrors (_physics_process ticks the countdown between syncs)
	if spawn_manager == null:
		set_physics_process(false)
		return
	spawn_manager.kill_win = false
	spawn_manager.objective_name = "Horde"
	spawn_manager.coop_team = SpawnManager.PLAYER_TEAM
	spawn_manager.respawn_gate = _may_respawn
	if net_match.get(&"lag_extra") is Callable:
		net_match.set(&"lag_extra", net_enemies.lag_bodies)
	set_physics_process(false)
	var nav := spawn_manager.get_node_or_null(spawn_manager.navigation_path) as ArenaNavigation
	if nav != null and not nav.is_baked:
		await nav.baked
	else:
		await get_tree().physics_frame
	if not is_inside_tree():
		return
	_hook_players()
	phase = Phase.STARTING
	time_left = FIRST_DELAY
	_banner("Horde: hold out")
	sync_state()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	if not _host:
		if phase == Phase.STARTING or phase == Phase.INTERMISSION:
			time_left = maxf(time_left - delta, 0.0)
		return
	_sync_left -= delta
	if _sync_left <= 0.0:
		_sync_left = SYNC_INTERVAL
		sync_state()
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = PLAYER_POLL
		_hook_players()
	match phase:
		Phase.STARTING, Phase.INTERMISSION:
			time_left -= delta
			if time_left <= 0.0:
				start_wave(wave + 1)
		Phase.WAVE:
			wave_time += delta
			_prune()
			_spawn_pending()
			if enemies.is_empty() and _pending.is_empty():
				_clear_wave()
				return
			_contact_left -= delta
			if _contact_left <= 0.0:
				_contact_left = CONTACT_INTERVAL
				_share_contact()
			_hunt_left -= delta
			var late := enemies.size() <= HUNT_REMAINING or wave_time > HUNT_AFTER
			if late and _hunt_left <= 0.0:
				_hunt_left = HUNT_INTERVAL
				_hunt()


# ------------------------------------------------------------------ queries


func is_hunting() -> bool:
	if not _host:
		return _client_hunting
	return phase == Phase.WAVE and (enemies.size() <= HUNT_REMAINING or wave_time > HUNT_AFTER)


func enemies_left() -> int:
	if not _host:
		return _client_left
	var queued := 0
	for squad: Array in _pending:
		queued += squad.size()
	return enemies.size() + queued


func wave_name() -> String:
	return str(HordeWaves.wave(wave).name) if wave > 0 else ""


func is_down(player: Player) -> bool:
	if not _host:
		return _down_names.has(_score_name(player))
	return _down.has(player)


## From NetMatch's scores, which every peer has (the host's SpawnManager rows, synced).
func points_of(node: Node) -> int:
	if node == null or net_match == null:
		return 0
	var scores: Dictionary = net_match.get(&"scores")
	var entry: Dictionary = scores.get(_score_name(node), {})
	return int(entry.get("points", 0))


## A combatant's scoreboard name (SpawnManager._name_of's rule).
static func _score_name(node: Node) -> String:
	if node is Bot:
		return (node as Bot).display_name
	return str(node.get_meta(&"display_name", node.name)) if node != null else ""


## The display name behind a net id: an enemy's (kill feed), or "".
func name_of_net_id(id: int) -> String:
	return net_enemies.name_of(id) if net_enemies != null else ""


## Living defenders: players and the co-op bots.
func defenders() -> Array[Node3D]:
	var out: Array[Node3D] = []
	if spawn_manager == null:
		return out
	for p in spawn_manager.get_players():
		if ArenaEvents.is_alive(p):
			out.append(p)
	for b in spawn_manager.bots:
		if is_instance_valid(b) and not b.dead:
			out.append(b)
	return out


# ------------------------------------------------------------------ waves


func start_wave(number: int) -> void:
	wave = number
	phase = Phase.WAVE
	wave_time = 0.0
	_hunt_left = 0.0
	_used_spawns.clear()
	var info := HordeWaves.wave(wave)
	_pending = info.squads.duplicate(true)
	_banner("Wave %d: %s" % [wave, info.name])
	_spawn_pending()
	wave_started.emit(wave)
	sync_state()


func _spawn_pending() -> void:
	while not _pending.is_empty():
		var squad: Array = _pending[0]
		if not enemies.is_empty() and enemies.size() + squad.size() > HordeWaves.MAX_ALIVE:
			return
		_pending.pop_front()
		_spawn_squad(squad)


func _spawn_squad(ids: Array) -> Orta:
	var arena := net_match.get_parent() as Node3D
	var origin := _squad_origin()
	_used_spawns.append(origin)
	var target := _nearest_defender(origin)
	var facing := Vector3.FORWARD
	if target != null:
		facing = target.global_position - origin
		facing.y = 0.0
	facing = facing.normalized() if facing.length_squared() > 0.01 else Vector3.FORWARD
	var basis := Basis.looking_at(facing, Vector3.UP)
	var orta := Orta.new()
	orta.name = "HordeOrta%d_%d" % [wave, ortas.size()]
	orta.assault = true
	orta.difficulty = spawn_manager.difficulty
	arena.add_child(orta)
	orta.global_transform = Transform3D(basis, origin)
	for i in ids.size():
		var type := _type(str(ids[i]))
		if type == null:
			continue
		var e := orta.spawn(type, Transform3D(basis, _ring_point(origin, i)))
		e.died.connect(_on_enemy_died)
		enemies.append(e)
		net_enemies.register(e)
	ortas.append(orta)
	if target != null:
		orta.report_contact(null, target, target.global_position)
	return orta


func _clear_wave() -> void:
	wave_cleared.emit(wave)
	var text := "Wave %d cleared" % wave
	if HordeWaves.is_round_end(wave):
		lives = mini(lives + LIVES_PER_ROUND, MAX_LIVES)
		lives_changed.emit(lives)
		text = "Round %d complete: +%d lives" % [HordeWaves.round_of(wave), LIVES_PER_ROUND]
	_banner(text)
	_resupply()
	_revive_down()
	for orta in ortas:
		if is_instance_valid(orta):
			orta.queue_free()
	ortas.clear()
	phase = Phase.INTERMISSION
	time_left = INTERMISSION
	sync_state()


func _hunt() -> void:
	for orta in ortas:
		if not is_instance_valid(orta) or orta.living().is_empty():
			continue
		var target := _nearest_defender(orta.living()[0].global_position)
		if target != null:
			orta.hunt(target)


func _share_contact() -> void:
	for orta in ortas:
		if not is_instance_valid(orta) or orta.living().is_empty():
			continue
		var target := _nearest_defender(orta.living()[0].global_position)
		if target != null:
			orta.report_contact(null, target, target.global_position)


func _prune() -> void:
	for i in range(enemies.size() - 1, -1, -1):
		if not is_instance_valid(enemies[i]) or enemies[i].dead:
			enemies.remove_at(i)


# ------------------------------------------------------------------ deaths, lives, scoring


func _on_enemy_died(bot: Bot, killer: Node, info: Dictionary) -> void:
	var e := bot as Enemy
	enemies.erase(e)
	if e == null:
		return
	var points := HordeWaves.points_for(e.enemy_type.id)
	var credited := (
		is_instance_valid(killer)
		and killer != e
		and not killer.is_in_group(SpawnManager.THREAT_GROUP)
	)
	if credited:
		spawn_manager.add_objective_score(killer, "kills", 1)
		spawn_manager.add_objective_score(killer, "points", points)
		var text := ""
		if info.get("assassination", false):
			text = "%s assassinated %s" % [spawn_manager._name_of(killer), e.display_name]
		else:
			var how := str(info.get("weapon", ""))
			if info.get("melee", false):
				how += " melee"
			elif info.get("headshot", false):
				how += " headshot"
			text = "%s killed %s (%s)" % [spawn_manager._name_of(killer), e.display_name, how]
		_feed(text.replace(" ()", ""))
	var corpse := e.get_instance_id()
	get_tree().create_timer(CORPSE_TIME, false).timeout.connect(_clear_corpse.bind(corpse))


## By instance id: the corpse may already be gone (arena unloaded, Play Again).
func _clear_corpse(id: int) -> void:
	var e := instance_from_id(id) as Enemy
	if is_instance_valid(e) and e.dead:
		e.queue_free()  # NetEnemies despawns the copies as it leaves the tree


func _on_player_died(player: Player, _killer: Node, _info: Dictionary) -> void:
	if phase == Phase.OVER:
		return
	if lives > 0:
		lives -= 1
		lives_changed.emit(lives)
	else:
		_down[player] = true
		_banner("%s is down" % spawn_manager._name_of(player))
	_check_game_over()
	sync_state()


## SpawnManager.respawn_gate: a player with no life left stays down.
func _may_respawn(player: Player) -> bool:
	return not _down.has(player) and phase != Phase.OVER


func _revive_down() -> void:
	for player: Variant in _down.keys():
		if lives <= 0:
			break
		_down.erase(player)
		if is_instance_valid(player):
			lives -= 1
			spawn_manager.respawn_now(player as Player)
	lives_changed.emit(lives)
	sync_state()


func _check_game_over() -> void:
	var players := spawn_manager.get_players()
	if players.is_empty():
		return
	for p in players:
		if not _down.has(p):
			return
	phase = Phase.OVER
	set_physics_process(false)
	sync_state()
	var survived := maxi(wave - 1, 0)
	_banner("Survived %d wave%s" % [survived, "" if survived == 1 else "s"])
	if net_match.has_method(&"end_match"):
		net_match.call(&"end_match", "The Porte", spawn_manager.scores)


## Reserves, batteries and grenades back to full for every defender.
func _resupply() -> void:
	for body in defenders():
		var carrier: Node = body
		if body is Player:
			carrier = (body as Player).get_weapon_holder()
		if carrier != null and carrier.has_method(&"get_weapons"):
			for weapon: Weapon in carrier.call(&"get_weapons"):
				GameRules._refill(weapon)
		var thrower := body.get_node_or_null(^"GrenadeThrower") as GrenadeThrower
		if thrower != null:
			for i in thrower.counts.size():
				thrower.add(i, thrower.max_count)


# ------------------------------------------------------------------ placement


## The map spawn point farthest from every defender, out of their sight, and clear of this
## wave's other squads.
func _squad_origin() -> Vector3:
	var space := get_viewport().world_3d.direct_space_state
	var guards := defenders()
	var best := Vector3.ZERO
	var best_score := -INF
	for spawn in spawn_manager.get_spawn_points():
		var p := spawn.global_position
		var nearest := 80.0
		var score := 0.0
		for g in guards:
			nearest = minf(nearest, p.distance_to(g.global_position))
			var query := PhysicsRayQueryParameters3D.create(
				ArenaEvents.eye_of(g), p + Vector3.UP * 1.5, LOS_MASK
			)
			if space.intersect_ray(query).is_empty():
				score -= 25.0
		for used in _used_spawns:
			if p.distance_to(used) < SQUAD_SEPARATION:
				score -= 40.0
		score += nearest + randf() * 4.0
		if score > best_score:
			best_score = score
			best = p
	return best


## Member i's spot: the spawn point itself, then rings of 8 around it, snapped to the navmesh.
func _ring_point(origin: Vector3, i: int) -> Vector3:
	var p := origin
	if i > 0:
		var ring := (i - 1) / 8 + 1
		var angle := TAU * float((i - 1) % 8) / 8.0 + ring * 0.4
		p = origin + Vector3(cos(angle), 0.0, sin(angle)) * SQUAD_SPACING * ring
	var map := get_viewport().world_3d.navigation_map
	var snapped := NavigationServer3D.map_get_closest_point(map, p)
	if snapped != Vector3.ZERO and snapped.distance_to(p) < 3.0:
		p = snapped
	return p + Vector3.UP * 0.1


func _nearest_defender(from: Vector3) -> Node3D:
	var best: Node3D = null
	for d in defenders():
		if best == null or d.global_position.distance_to(from) < best.global_position.distance_to(from):
			best = d
	return best


func _type(id: String) -> EnemyType:
	if not _types.has(id):
		_types[id] = load(TYPES % id) as EnemyType
	return _types[id]


## Host: players connect their deaths here (the local one at start, remote ones as they join).
func _hook_players() -> void:
	for p in spawn_manager.get_players():
		if not _hooked.has(p):
			_hooked[p] = true
			p.died.connect(_on_player_died)


func _banner(text: String) -> void:
	_show_banner(text)
	if _host:
		for peer: int in _peers():
			_rpc_banner.rpc_id(peer, text)


func _show_banner(text: String) -> void:
	print("[Horde] %s" % text)
	var ui := net_match.get_node_or_null(^"MatchUI") if net_match != null else null
	if ui != null and ui.has_method(&"show_banner"):
		ui.call(&"show_banner", text)


func _feed(text: String) -> void:
	if net_match != null and net_match.has_signal(&"kill_feed"):
		net_match.emit_signal(&"kill_feed", text)
	for peer: int in _peers():
		_rpc_feed.rpc_id(peer, text)


# ------------------------------------------------------------------ LAN mirror


## Clients that are in the arena (they said hello to NetEnemies).
func _peers() -> Array:
	return net_enemies.peers() if net_enemies != null else []


## Host: the match state to one client (peer > 0) or every client in the arena.
func sync_state(peer: int = 0) -> void:
	if not _host or net_enemies == null:
		return
	var down := PackedStringArray()
	for p: Variant in _down:
		if is_instance_valid(p):
			down.append(_score_name(p))
	var targets: Array = [peer] if peer > 0 else _peers()
	for target: int in targets:
		_rpc_state.rpc_id(
			target, wave, int(phase), lives, time_left, enemies_left(), is_hunting(), down
		)


@rpc("authority", "call_remote", "reliable")
func _rpc_state(
	new_wave: int,
	new_phase: int,
	new_lives: int,
	new_time_left: float,
	left: int,
	hunting: bool,
	down: PackedStringArray
) -> void:
	wave = new_wave
	phase = clampi(new_phase, 0, Phase.OVER) as Phase
	lives = new_lives
	time_left = new_time_left
	_client_left = left
	_client_hunting = hunting
	_down_names = down


@rpc("authority", "call_remote", "reliable")
func _rpc_banner(text: String) -> void:
	_show_banner(text)


@rpc("authority", "call_remote", "reliable")
func _rpc_feed(text: String) -> void:
	if net_match != null and net_match.has_signal(&"kill_feed"):
		net_match.emit_signal(&"kill_feed", text)
