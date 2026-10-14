class_name SpawnManager
extends Node
## Arena mode: spawns bot_count bots once the navmesh is baked, respawns them after
## respawn_delay at the spawn point farthest from (and out of sight of) living enemies, keeps a
## kill / death tally (stdout kill feed + a debug Label; LC Programmer owns the real HUD), and
## moves the player to a safe spawn after player.gd's placeholder instant respawn.
## FFA by default (every bot on its own team, player on team 0). Values marked ~ are
## approximate Halo 2 defaults.

signal score_changed(scores: Dictionary)

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

var bots: Array[Bot] = []
## display name -> {"kills": int, "deaths": int, "suicides": int}
var scores: Dictionary = {}

var _player: Player
var _events: ArenaEvents
var _spawns: Array[Node3D] = []
var _label: Label
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
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
		_player.set_meta(&"display_name", "Player")
		_score_entry("Player")
		var hs := _player.get_node_or_null(^"HealthShield") as HealthShield
		if hs != null:
			hs.died.connect(_on_player_died)
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


## Player.gd resets its HealthShield inside `died`, before the killing hit's hit_confirmed;
## resolve credit after the frame's signals have run.
func _on_player_died() -> void:
	_resolve_player_death.call_deferred()


func _resolve_player_death() -> void:
	if _player == null:
		return
	var killer: Node = _events.recent_attacker(_player) if _events != null else null
	var info: Dictionary = (
		_events.recent_hit_info(_player) if _events != null and killer != null else {}
	)
	_record_kill(killer, _player, info)
	# player.gd already put the player back at its scene spawn; move to a safe one instead.
	var spawn := _pick_spawn(_player)
	_player.global_position = spawn.origin
	_player.rotation.y = spawn.basis.get_euler().y
	_player.velocity = Vector3.ZERO


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
			print("[Arena] %s wins with %d kills. Scores reset." % [killer_name, entry.kills])
			_print_scores()
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
