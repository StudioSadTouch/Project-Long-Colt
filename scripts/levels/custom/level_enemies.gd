class_name LevelEnemies
extends Node3D
## The New Ottoman enemies a custom level places (CustomArena adds this node as "LevelEnemies"
## on every peer, so its NetEnemies child has the same RPC path everywhere).
## Host: once the navmesh is baked, the enemy markers are grouped into squads (markers within
## CLUSTER_RADIUS of each other, at most SQUAD_MAX each), and each squad is an Orta holding its
## ground: it fights whoever comes near and reports contact to the rest of the squad. A squad
## wiped out comes back respawn_time seconds later (0 = never), once nobody is close enough to
## watch it appear. LAN clients see copies (NetEnemies), as in Horde.
## Not used under Horde rules: Horde brings its own waves.

const CLUSTER_RADIUS := 14.0
const SQUAD_MAX := 10
const CORPSE_TIME := 8.0
## A wiped-out squad waits until no defender is this close to its post.
const RESPAWN_CLEARANCE := 18.0

## [{"type": EnemyType, "xform": Transform3D}] (CustomArena, before _ready).
var markers: Array[Dictionary] = []
var respawn_time: float = 60.0
var net_match: Node
var spawn_manager: SpawnManager
var net_enemies: NetEnemies
## Host: [{"members": [marker...], "orta": Orta, "wiped_at": float}]
var squads: Array[Dictionary] = []

var _host: bool = true
var _clock: float = 0.0


func _ready() -> void:
	net_enemies = NetEnemies.new()
	net_enemies.name = "Enemies"
	add_child(net_enemies)
	_host = multiplayer.is_server()
	set_physics_process(false)
	if not _host or markers.is_empty():
		return
	if net_match != null and not (net_match.get(&"lag_extra") as Callable).is_valid():
		net_match.set(&"lag_extra", net_enemies.lag_bodies)
	var nav: ArenaNavigation = null
	if spawn_manager != null:
		nav = spawn_manager.get_node_or_null(spawn_manager.navigation_path) as ArenaNavigation
	if nav != null and not nav.is_baked:
		await nav.baked
	else:
		await get_tree().physics_frame
	if not is_inside_tree():
		return
	for group in cluster(markers, CLUSTER_RADIUS, SQUAD_MAX):
		var squad := {"members": group, "orta": null, "wiped_at": -1.0}
		squads.append(squad)
		_spawn_squad(squad)
	set_physics_process(true)


## Host: bring back wiped-out squads.
func _physics_process(delta: float) -> void:
	_clock += delta
	if respawn_time <= 0.0:
		return
	for squad in squads:
		var orta := squad.orta as Orta
		var alive := is_instance_valid(orta) and not orta.living().is_empty()
		if alive:
			continue
		if float(squad.wiped_at) < 0.0:
			squad.wiped_at = _clock
		elif _clock - float(squad.wiped_at) >= respawn_time and not _watched(squad):
			if is_instance_valid(orta):
				orta.queue_free()
			_spawn_squad(squad)


## Every living enemy this level spawned (host).
func living() -> Array[Enemy]:
	var out: Array[Enemy] = []
	for squad in squads:
		var orta := squad.orta as Orta
		if is_instance_valid(orta):
			out.append_array(orta.living())
	return out


func _spawn_squad(squad: Dictionary) -> void:
	var members: Array = squad.members
	var first: Transform3D = members[0].xform
	var orta := Orta.new()
	orta.name = "LevelOrta%d" % squads.find(squad)
	orta.assault = false
	if spawn_manager != null:
		orta.difficulty = spawn_manager.difficulty
	add_child(orta, true)
	orta.global_transform = Transform3D(first.basis.orthonormalized(), first.origin)
	for marker: Dictionary in members:
		var xform: Transform3D = marker.xform
		xform.basis = xform.basis.orthonormalized()
		xform.origin += Vector3.UP * 0.1
		var e := orta.spawn(marker.type, xform)
		e.died.connect(_on_died)
		net_enemies.register(e)
	squad.orta = orta
	squad.wiped_at = -1.0


func _on_died(bot: Bot, _killer: Node, _info: Dictionary) -> void:
	var corpse := bot.get_instance_id()
	get_tree().create_timer(CORPSE_TIME, false).timeout.connect(_clear_corpse.bind(corpse))


func _clear_corpse(id: int) -> void:
	var e := instance_from_id(id) as Enemy
	if is_instance_valid(e) and e.dead:
		e.queue_free()


func _watched(squad: Dictionary) -> bool:
	if spawn_manager == null:
		return false
	var post: Vector3 = (squad.members[0].xform as Transform3D).origin
	for body in spawn_manager.get_players() as Array:
		if is_instance_valid(body) and (body as Node3D).global_position.distance_to(post) < RESPAWN_CLEARANCE:
			return true
	for bot in spawn_manager.bots:
		if is_instance_valid(bot) and bot.global_position.distance_to(post) < RESPAWN_CLEARANCE:
			return true
	return false


## Markers grouped by proximity (single linkage within radius), each group at most max_size.
static func cluster(points: Array[Dictionary], radius: float, max_size: int) -> Array[Array]:
	var left: Array[Dictionary] = points.duplicate()
	var out: Array[Array] = []
	while not left.is_empty():
		var group: Array = [left.pop_front()]
		var i := 0
		while i < group.size() and group.size() < max_size:
			var from: Vector3 = (group[i].xform as Transform3D).origin
			var j := 0
			while j < left.size() and group.size() < max_size:
				if (left[j].xform as Transform3D).origin.distance_to(from) <= radius:
					group.append(left.pop_at(j))
				else:
					j += 1
			i += 1
		out.append(group)
	return out
