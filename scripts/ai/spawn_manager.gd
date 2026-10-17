class_name SpawnManager
extends Node
## Arena mode: spawns bot_count bots once the navmesh is baked, respawns them after
## respawn_delay at the spawn point farthest from (and out of sight of) living enemies, keeps a
## kill / death tally (stdout kill feed + a debug Label; LC Programmer owns the real HUD), and
## places the player at a safe spawn. Values marked ~ are approximate Halo 2 defaults.
##
## Game mode (mode_id, a GameMode id; NetMatch calls apply_mode before our _ready):
##   FFA          every bot on its own team, the local player on team 0, remote humans on
##                NetMatch.HUMAN_TEAM_BASE + peer. Spawns on SPAWN_FFA_* markers if the map has them.
##   team modes   Red vs Blue (GameMode.TEAM_RED / TEAM_BLUE). The local player is on local_team,
##                new bots and humans join the smaller team, armor is forced to the team colour,
##                spawns come from the team's SPAWN_Red_* / SPAWN_Blue_* markers, and the first
##                TEAM to score_limit kills (sum of its members, betrayals -1) wins.
## A map without the named markers spawns everyone everywhere (Lockout).
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
## Hostiles that aren't combatants of ours (Horde's New Ottomans): spawns keep away from them,
## and they never get a scoreboard row when they kill someone.
const THREAT_GROUP := &"spawn_threat"

@export var bot_scene: PackedScene
@export_range(0, 15) var bot_count: int = 3
@export var difficulty: BotDifficulty
## GameMode id. Set it with apply_mode (also sets score_limit).
@export var mode_id: String = GameMode.DEFAULT_ID
## Team modes: the local player's team.
@export var local_team: int = GameMode.TEAM_RED
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
## false: kills never end the match (objective modes: CtfMatch calls declare_winner).
@export var kill_win: bool = true
## Objective modes: the mode's name for the debug label (set with kill_win).
var objective_name: String = ""
## Co-op (Horde): >= 0 puts every bot on this team (the player's), instead of FFA's own teams.
var coop_team: int = -1
## Optional fn(player) -> bool asked before a player respawns (Horde's shared lives). False:
## the player stays down until someone calls respawn_now(player).
var respawn_gate: Callable = Callable()

## Team id -> Array[Node3D] of spawns for maps without SPAWN_Red_* / SPAWN_Blue_* markers
## (CtfMatch splits the free-for-all spawns between the two bases). Markers win when present.
var team_spawn_override: Dictionary = {}

var bots: Array[Bot] = []
## Extra (remote, networked) players registered with register_player.
var players: Array[Player] = []
## display name -> {"kills": int, "deaths": int, "suicides": int, "team": int}
var scores: Dictionary = {}

var _player: Player
var _events: ArenaEvents
var _spawns: Array[Node3D] = []
## Team id -> Array[Node3D] of SPAWN_Red_* / SPAWN_Blue_*; FFA -> SPAWN_FFA_*.
var _team_spawns: Dictionary = {}
var _ffa_spawns: Array[Node3D] = []
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
				_add_spawn(child)
	if _spawns.is_empty():
		push_error("SpawnManager: no spawn points")
	_player = get_node_or_null(player_path) as Player
	if _player != null:
		_player.set_meta(&"team", local_team if is_team_mode() else PLAYER_TEAM)
		_apply_team_look(_player)
		if not _player.has_meta(&"display_name"):
			_player.set_meta(&"display_name", "Player")
		_score_entry_of(_player)
		_hook_player(_player)
		if is_team_mode():
			# Start on our own side, not wherever the scene placed the Player.
			_player.respawn_at(_pick_spawn(_player))
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


## Mode rules from GameMode (call before _ready, or before the match starts).
func apply_mode(id: String) -> void:
	mode_id = GameMode.sanitize(id)
	score_limit = GameMode.score_limit(mode_id)


func is_team_mode() -> bool:
	return GameMode.is_team(mode_id)


## Team modes: the team a new human should join (fewest humans, then fewest members, then Red).
func pick_team_for_human() -> int:
	var humans := {}
	var total := _team_counts()
	for team in GameMode.TEAMS:
		humans[team] = 0
	for node: Node3D in _combatants():
		var team := ArenaEvents.team_of(node)
		if not node is Bot and humans.has(team):
			humans[team] += 1
	var best := GameMode.TEAM_RED
	for team in GameMode.TEAMS:
		if (
			humans[team] < humans[best]
			or (humans[team] == humans[best] and total[team] < total[best])
		):
			best = team
	return best


## Team modes: team id -> member count (local player, remote players and bots).
func _team_counts() -> Dictionary:
	var counts := {}
	for team in GameMode.TEAMS:
		counts[team] = 0
	for node: Node3D in _combatants():
		var team := ArenaEvents.team_of(node)
		if counts.has(team):
			counts[team] += 1
	return counts


func _smallest_team() -> int:
	var counts := _team_counts()
	var best := GameMode.TEAM_RED
	for team in GameMode.TEAMS:
		if counts[team] < counts[best]:
			best = team
	return best


## Team modes: armor primary = team colour (Halo). FFA leaves everyone's own colour.
func _apply_team_look(node: Node) -> void:
	if not is_team_mode() or node == null:
		return
	var team := ArenaEvents.team_of(node)
	if GameMode.is_team_id(team) and node.has_method(&"set_primary_color"):
		node.call(&"set_primary_color", GameMode.team_color(team))


func _add_spawn(spawn: Node3D) -> void:
	_spawns.append(spawn)
	var spawn_name := str(spawn.name)
	if spawn_name.begins_with(GameMode.FFA_SPAWN_PREFIX):
		_ffa_spawns.append(spawn)
		return
	for team: int in GameMode.SPAWN_PREFIX:
		if spawn_name.begins_with(str(GameMode.SPAWN_PREFIX[team])):
			if not _team_spawns.has(team):
				_team_spawns[team] = [] as Array[Node3D]
			(_team_spawns[team] as Array[Node3D]).append(spawn)


## Spawn points `who` may use under the current mode (all of them when the map has no
## markers for it).
func _spawns_for(who: Node) -> Array[Node3D]:
	if is_team_mode():
		var team := ArenaEvents.team_of(who)
		var own: Array[Node3D] = _team_spawns.get(team, [] as Array[Node3D])
		if own.is_empty():
			own = team_spawn_override.get(team, [] as Array[Node3D])
		if not own.is_empty():
			return own
	elif not _ffa_spawns.is_empty():
		return _ffa_spawns
	return _spawns


func _spawn_bot(index: int, team: int = -1) -> void:
	if bot_scene == null:
		push_error("SpawnManager: bot_scene not set")
		return
	var bot := bot_scene.instantiate() as Bot
	bot.name = "Bot%d" % (index + 1)
	bot.display_name = "Bot %d" % (index + 1)
	if is_team_mode():
		bot.team = team if GameMode.is_team_id(team) else _smallest_team()
	elif coop_team >= 0:
		bot.team = coop_team
	else:
		bot.team = index + 1
	if difficulty != null:
		bot.difficulty = difficulty
	var spawn := _pick_spawn(bot)
	get_parent().add_child(bot)
	_apply_team_look(bot)
	bot.respawn_at(spawn)
	bot.died.connect(_on_bot_died)
	bots.append(bot)
	_score_entry_of(bot)
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
	for node in get_tree().get_nodes_in_group(THREAT_GROUP):
		var threat := node as Node3D
		if threat != null and ArenaEvents.is_hostile(who, threat) and ArenaEvents.is_alive(threat):
			enemies.append(threat)
	var best: Node3D = null
	var best_score := -INF
	var space := get_viewport().world_3d.direct_space_state
	for spawn in _spawns_for(who):
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


## Net: a remote player (meta display_name set; team = its own FFA team, or its Red / Blue
## team in team modes, from pick_team_for_human). Spawns it now.
func register_player(player: Player, team: int) -> void:
	if player == null or players.has(player):
		return
	players.append(player)
	player.set_meta(&"team", team)
	_apply_team_look(player)
	_score_entry_of(player)
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
## the first free "Bot N", on `team` (team modes; -1 = the smaller team). Host only; returns
## false on a client or without a bot scene.
func add_bot(team: int = -1) -> bool:
	if not multiplayer.is_server() or bot_scene == null:
		return false
	var taken := {}
	for bot in bots:
		if is_instance_valid(bot):
			taken[bot.display_name] = true
	var index := 0
	while taken.has("Bot %d" % (index + 1)):
		index += 1
	_spawn_bot(index, team)
	_refresh_label()
	return true


## Net: removes the newest bot (a late joiner takes its slot), of `team` when given and that
## team has one. Returns false if none left.
func remove_bot(team: int = -1) -> bool:
	if team >= 0:
		for i in range(bots.size() - 1, -1, -1):
			var candidate: Variant = bots[i]  # untyped: may be freed
			if is_instance_valid(candidate) and (candidate as Bot).team == team:
				bots.remove_at(i)
				scores.erase((candidate as Bot).display_name)
				(candidate as Bot).queue_free()
				score_changed.emit(scores)
				_refresh_label()
				return true
	while not bots.is_empty():
		var bot: Variant = bots.pop_back()  # untyped: may be freed
		if is_instance_valid(bot):
			scores.erase((bot as Bot).display_name)
			(bot as Bot).queue_free()
			score_changed.emit(scores)
			_refresh_label()
			return true
	return false


func _on_player_died(player: Player, killer: Node, info: Dictionary) -> void:
	_record_kill(killer, player, info)


func _on_player_respawn_requested(player: Player) -> void:
	if not is_instance_valid(player):
		return
	if respawn_gate.is_valid() and not bool(respawn_gate.call(player)):
		return
	player.respawn_at(_pick_spawn(player))


## Respawns a player now at a safe spawn (Horde: a downed player gets a life back).
func respawn_now(player: Player) -> void:
	if is_instance_valid(player):
		player.respawn_at(_pick_spawn(player))


## The safe spawn transform for `who` (also used by Horde to place enemy squads far away).
func pick_spawn_for(who: Node) -> Transform3D:
	return _pick_spawn(who)


## Every spawn point on the map.
func get_spawn_points() -> Array[Node3D]:
	return _spawns.duplicate()


## The local player and registered remote players.
func get_players() -> Array[Player]:
	var out: Array[Player] = []
	if is_instance_valid(_player):
		out.append(_player)
	for p in players:
		if is_instance_valid(p):
			out.append(p)
	return out


func _record_kill(killer: Node, victim: Node, info: Dictionary) -> void:
	var victim_name := _name_of(victim)
	_score_entry_of(victim).deaths += 1
	var how := str(info.get("weapon", ""))
	if info.get("melee", false):
		how += " melee"
	elif info.get("headshot", false):
		how += " headshot"
	if is_instance_valid(killer) and killer.is_in_group(THREAT_GROUP):
		# Killed by a Horde enemy: a death, no scoreboard row for the enemy.
		print("[Arena] %s killed %s (%s)" % [_name_of(killer), victim_name, how.strip_edges()])
		if _events != null:
			_events.kill.emit(killer, victim, info)
		score_changed.emit(scores)
		_refresh_label()
		return
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
		var entry := _score_entry_of(killer)
		if ArenaEvents.is_hostile(killer, victim):
			entry.kills += 1
		else:
			entry.kills -= 1  # betrayal
		print("[Arena] %s killed %s (%s)" % [killer_name, victim_name, how.strip_edges()])
		if _events != null:
			_events.kill.emit(killer, victim, info)
		var winner := killer_name
		var total := int(entry.kills)
		if is_team_mode():
			var team := ArenaEvents.team_of(killer)
			winner = GameMode.team_name(team)
			total = int(GameMode.team_totals(scores).get(team, 0))
		if kill_win and total >= score_limit:
			var tail := "" if end_on_win else " Scores reset."
			print("[Arena] %s wins with %d kills.%s" % [winner, total, tail])
			_print_scores()
			match_won.emit(winner, scores.duplicate(true))
			if not end_on_win:
				for key: String in scores:
					var keep_team: int = scores[key].get("team", -1)
					scores[key] = {"kills": 0, "deaths": 0, "suicides": 0, "team": keep_team}
	score_changed.emit(scores)
	_refresh_label()


## Objective modes: +amount on `key` (e.g. "caps") in node's score entry (synced like kills).
func add_objective_score(node: Node, key: String, amount: int = 1) -> void:
	if node == null:
		return
	var entry := _score_entry_of(node)
	entry[key] = int(entry.get(key, 0)) + amount
	score_changed.emit(scores)
	_refresh_label()


## Objective modes: the match is won (match_won, as a kill-limit win). Offline (no end_on_win)
## the scores reset and play goes on.
func declare_winner(winner: String) -> void:
	print("[Arena] %s wins.%s" % [winner, "" if end_on_win else " Scores reset."])
	_print_scores()
	match_won.emit(winner, scores.duplicate(true))
	if not end_on_win:
		for key: String in scores:
			var keep_team: int = scores[key].get("team", -1)
			scores[key] = {"kills": 0, "deaths": 0, "suicides": 0, "team": keep_team}
		score_changed.emit(scores)
		_refresh_label()


func _name_of(node: Node) -> String:
	if node is Bot:
		return (node as Bot).display_name
	return str(node.get_meta(&"display_name", node.name))


func _score_entry(who: String) -> Dictionary:
	if not scores.has(who):
		scores[who] = {"kills": 0, "deaths": 0, "suicides": 0, "team": -1}
	return scores[who]


## Score entry of a combatant, tagged with its team (team modes; -1 in FFA) for the UI.
func _score_entry_of(node: Node) -> Dictionary:
	var entry := _score_entry(_name_of(node))
	entry.team = ArenaEvents.team_of(node) if is_team_mode() else -1
	return entry


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
		(
			"%s  %s  (to %d)"
			% [
				GameMode.name_of(mode_id).to_upper(),
				difficulty.preset_name if difficulty else "",
				score_limit
			]
		)
	]
	if not kill_win:
		# Objective mode: kills don't decide it (CtfMatch shows the captures).
		lines[0] = "%s  %s" % [objective_name.to_upper(), difficulty.preset_name if difficulty else ""]
	if is_team_mode():
		var totals := GameMode.team_totals(scores)
		for team in GameMode.TEAMS:
			lines.append("%s  %d" % [GameMode.team_name(team).to_upper(), totals.get(team, 0)])
	var names := scores.keys()
	names.sort_custom(
		func(a: Variant, b: Variant) -> bool: return scores[a].kills > scores[b].kills
	)
	for who in names:
		var s: Dictionary = scores[who]
		lines.append("%s   K %d   D %d" % [who, s.kills, s.deaths])
	_label.text = "\n".join(lines)
