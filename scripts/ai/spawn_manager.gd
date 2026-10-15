class_name SpawnManager
extends Node
## Arena mode: spawns bot_count bots once the navmesh is baked, respawns them after
## respawn_delay at the spawn point farthest from (and out of sight of) living enemies, keeps a
## kill / death tally (stdout kill feed + a debug Label; LC Programmer owns the real HUD), and
## places the player at a safe spawn. FFA by default: the player plus bot_count bots (3, so a
## 4-player FFA), every bot on its own team, player on team 0. Values marked ~ are approximate
## Halo 2 defaults.
##
## Player respawn: SpawnManager owns it. _hook_player turns off player.gd's auto_respawn and
## sets its respawn_delay to ours; player.gd runs the one timer and emits respawn_requested,
## which SpawnManager answers with respawn_at(safe spawn). Kill credit is the killer argument of
## Player.died(player, killer, info).
##
## Networking (NetMatch, docs/net/netcode.md): runs on the host only (a net client returns at
## the top of _ready). Remote players join through register_player / unregister_player and are
## spawned, scored and respawned exactly like the local player. remove_bot() drops a bot when
## a late joiner takes its slot. match_won fires at score_limit; with end_on_win the scores are
## kept for the game-over screen instead of being reset (offline keeps the reset).

signal score_changed(scores: Dictionary)
## A combatant reached score_limit.
signal match_won(winner: String, scores: Dictionary)

const LOS_MASK := 1
const PLAYER_TEAM := 0

@export var bot_scene: PackedScene
@export_range(0, 15) var bot_count: int = 3
@export var difficulty: BotDifficulty
@export var free_for_all: bool = true
## ~Halo 2 default respawn time.
@export var respawn_delay: float = 5.0
## ~Halo 2 Slayer default.
@export var score_limit: int = 25
@export var player_path: NodePath = ^"../Player"
@export var navigation_path: NodePath = ^"../Navigation"
## Marker3D containers; every child is a spawn point.
@export var spawn_roots: Array[NodePath] = [^"../Lockout/Spawns", ^"../ArenaSpawns"]
@export var show_debug_label: bool = true
## Spawns closer than this to a living enemy are heavily penalized.
@export var min_enemy_distance: float = 8.0
## Net matches end at score_limit (NetMatch shows game over); false = print and reset (offline).
@export var end_on_win: bool = false

var bots: Array[Bot] = []
## Extra (remote, networked) players registered with register_player.
var players: Array[Player] = []
## display name -> {"kills": int, "deaths": int, "suicides": int}
var scores: Dictionary = {}

var _player: Player
var _events: ArenaEvents
var _spawns: Array[Node3D] = []
var _label: Label
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if not multiplayer.is_server():
		return
	_rng.randomize()
	_events = ArenaEvents.find(get_tree())
	for path in spawn_roots:
		var root := get_node_or_null(path)
		if root == null:
			continue
		for child in root.get_children():
			if child is Node3D:
				_spawns.append(child)
	if _spawns.is_empty():
		push_error("SpawnManager: no spawn points")
	_player = get_node_or_null(player_path) as Player
	if _player != null:
		_player.set_meta(&"team", PLAYER_TEAM)
		if not _player.has_meta(&"display_name"):
			_player.set_meta(&"display_name", "Player")
		_score_entry(_name_of(_player))
		_hook_player(_player)
		if _events != null:
			_events.track_player.call_deferred(_player)
	if show_debug_label:
		_build_label()
	var nav := get_node_or_null(navigation_path) as ArenaNavigation
	if nav != null and not nav.is_baked:
		await nav.baked
	else:
		await get_tree().physics_frame
	for i in bot_count:
		_spawn_bot(i)
	_refresh_label()


func _spawn_bot(index: int) -> void:
	if bot_scene == null:
		push_error("SpawnManager: bot_scene not set")
		return
	var bot := bot_scene.instantiate() as Bot
	bot.name = "Bot%d" % (index + 1)
	bot.display_name = "Bot %d" % (index + 1)
	bot.team = index + 1 if free_for_all else 1
	if difficulty != null:
		bot.difficulty = difficulty
	var spawn := _pick_spawn(bot)
	get_parent().add_child(bot)
	bot.respawn_at(spawn)
	bot.died.connect(_on_bot_died)
	bots.append(bot)
	_score_entry(bot.display_name)
	print(
		(
			"[Arena] %s joined (%s)"
			% [bot.display_name, bot.difficulty.preset_name if bot.difficulty else "default"]
		)
	)


# ------------------------------------------------------------------ spawning


## Best spawn for `who`: far from living enemies, never in their sight if avoidable.
func _pick_spawn(who: Node) -> Transform3D:
	var enemies: Array[Node3D] = []
	for candidate in _combatants():
		if (
			candidate != who
			and ArenaEvents.is_hostile(who, candidate)
			and ArenaEvents.is_alive(candidate)
		):
			enemies.append(candidate)
	var best: Node3D = null
	var best_score := -INF
	var space := get_viewport().world_3d.direct_space_state
	for spawn in _spawns:
		var p := spawn.global_position
		var nearest := 60.0
		var penalty := 0.0
		for e in enemies:
			var d := p.distance_to(e.global_position)
			nearest = minf(nearest, d)
			if d < min_enemy_distance:
				penalty += 50.0
			var query := PhysicsRayQueryParameters3D.create(
				ArenaEvents.eye_of(e), p + Vector3.UP * 1.5, LOS_MASK
			)
			if space.intersect_ray(query).is_empty():
				penalty += 30.0
		var score := nearest - penalty + _rng.randf() * 5.0
		if score > best_score:
			best_score = score
			best = spawn
	if best == null:
		return Transform3D.IDENTITY
	# Face the map centre (Top Mid) so spawns look into the action.
	var origin := best.global_position
	var look := Vector3(-origin.x, 0.0, -origin.z)
	if look.length_squared() < 0.01:
		look = Vector3.FORWARD
	return Transform3D(Basis.looking_at(look.normalized(), Vector3.UP), origin)


func _combatants() -> Array[Node3D]:
	var out: Array[Node3D] = []
	if _player != null:
		out.append(_player)
	for p in players:
		if is_instance_valid(p):
			out.append(p)
	for b in bots:
		if is_instance_valid(b):
			out.append(b)
	return out


# ------------------------------------------------------------------ deaths and scoring


func _on_bot_died(bot: Bot, killer: Node, info: Dictionary) -> void:
	_record_kill(killer, bot, info)
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn_bot.bind(bot))


func _respawn_bot(bot: Bot) -> void:
	if is_instance_valid(bot):
		bot.respawn_at(_pick_spawn(bot))


func _hook_player(player: Player) -> void:
	player.auto_respawn = false
	player.respawn_delay = respawn_delay
	player.died.connect(_on_player_died)
	player.respawn_requested.connect(_on_player_respawn_requested)


## Net: a remote player (meta display_name set; team = its own FFA team). Spawns it now.
func register_player(player: Player, team: int) -> void:
	if player == null or players.has(player):
		return
	players.append(player)
	player.set_meta(&"team", team)
	_score_entry(_name_of(player))
	_hook_player(player)
	if _events != null:
		_events.track_player(player)
	player.respawn_at(_pick_spawn(player))
	score_changed.emit(scores)
	_refresh_label()


func unregister_player(player: Player) -> void:
	if not players.has(player):
		return
	players.erase(player)
	if is_instance_valid(player):
		if player.died.is_connected(_on_player_died):
			player.died.disconnect(_on_player_died)
		if player.respawn_requested.is_connected(_on_player_respawn_requested):
			player.respawn_requested.disconnect(_on_player_respawn_requested)
		scores.erase(_name_of(player))
	score_changed.emit(scores)
	_refresh_label()


## Net host: spawns one more bot now (NetMatch's refill of a slot a human left), named after
## the first free "Bot N". Host only; returns false on a client or without a bot scene.
func add_bot() -> bool:
	if not multiplayer.is_server() or bot_scene == null:
		return false
	var taken := {}
	for bot in bots:
		if is_instance_valid(bot):
			taken[bot.display_name] = true
	var index := 0
	while taken.has("Bot %d" % (index + 1)):
		index += 1
	_spawn_bot(index)
	_refresh_label()
	return true


## Net: removes the newest bot (a late joiner takes its slot). Returns false if none left.
func remove_bot() -> bool:
	while not bots.is_empty():
		var bot: Bot = bots.pop_back()
		if is_instance_valid(bot):
			scores.erase(bot.display_name)
			bot.queue_free()
			score_changed.emit(scores)
			_refresh_label()
			return true
	return false


func _on_player_died(player: Player, killer: Node, info: Dictionary) -> void:
	_record_kill(killer, player, info)


func _on_player_respawn_requested(player: Player) -> void:
	if is_instance_valid(player):
		player.respawn_at(_pick_spawn(player))


func _record_kill(killer: Node, victim: Node, info: Dictionary) -> void:
	var victim_name := _name_of(victim)
	_score_entry(victim_name).deaths += 1
	var how := str(info.get("weapon", ""))
	if info.get("melee", false):
		how += " melee"
	elif info.get("headshot", false):
		how += " headshot"
	if killer == null or killer == victim or not is_instance_valid(killer):
		_score_entry(victim_name).suicides += 1
		print(
			(
				"[Arena] %s died%s"
				% [
					victim_name,
					" (fell)" if info.get("kill_volume", false) or killer == null else ""
				]
			)
		)
	else:
		var killer_name := _name_of(killer)
		var entry := _score_entry(killer_name)
		if ArenaEvents.is_hostile(killer, victim):
			entry.kills += 1
		else:
			entry.kills -= 1  # betrayal
		print("[Arena] %s killed %s (%s)" % [killer_name, victim_name, how.strip_edges()])
		if _events != null:
			_events.kill.emit(killer, victim, info)
		if entry.kills >= score_limit:
			var tail := "" if end_on_win else " Scores reset."
			print("[Arena] %s wins with %d kills.%s" % [killer_name, entry.kills, tail])
			_print_scores()
			match_won.emit(killer_name, scores.duplicate(true))
			if not end_on_win:
				for key in scores:
					scores[key] = {"kills": 0, "deaths": 0, "suicides": 0}
	score_changed.emit(scores)
	_refresh_label()


func _name_of(node: Node) -> String:
	if node is Bot:
		return (node as Bot).display_name
	return str(node.get_meta(&"display_name", node.name))


func _score_entry(who: String) -> Dictionary:
	if not scores.has(who):
		scores[who] = {"kills": 0, "deaths": 0, "suicides": 0}
	return scores[who]


func _print_scores() -> void:
	for who in scores:
		var s: Dictionary = scores[who]
		print("[Arena]   %-8s K %d  D %d" % [who, s.kills, s.deaths])


func _build_label() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	_label = Label.new()
	_label.position = Vector2(16, 16)
	_label.add_theme_font_size_override(&"font_size", 18)
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 6)
	layer.add_child(_label)
	add_child(layer)


func _refresh_label() -> void:
	if _label == null:
		return
	var lines: Array[String] = [
		"ARENA  %s  (to %d)" % [difficulty.preset_name if difficulty else "", score_limit]
	]
	var names := scores.keys()
	names.sort_custom(
		func(a: Variant, b: Variant) -> bool: return scores[a].kills > scores[b].kills
	)
	for who in names:
		var s: Dictionary = scores[who]
		lines.append("%s   K %d   D %d" % [who, s.kills, s.deaths])
	_label.text = "\n".join(lines)
