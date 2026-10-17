class_name Orta
extends Node3D
## One orta (Janissary company) and its attached Azabs and Akinji: the board's encounter
## grammar as a squad coordinator. Members are Enemy children (placed in the scene, or added
## with spawn()). Optional Marker3D children under "Points" steer it; names are prefixes:
##   Peel*      flank posts the Azabs withdraw to (PEEL)
##   Flank*     points the Akinji raiders run to (FLANK), cycled when they circle back
##   Perch*     the marksman's overwatch perch
##   Platform*  Janissary posts on the command platform
##   Fallback*  where routed Azabs run
## Phases (docs/enemies/new_ottoman.md):
##   IDLE    nobody has contact; everyone holds their post.
##   SCREEN  first contact: the Azabs and the Bolukbasi push and volley (advance horn);
##           the Janissaries hold the platform; the marksman takes the perch.
##   PEEL    after Azab losses (or SCREEN_TIME): the Azabs fall back to the flanks (withdraw
##           horn), uncovering the Janissary gunline; the Akinji raiders run to flank.
##   BREAK   the Corbaci is dead: the Azabs rout, surviving Janissaries draw blades and charge
##           (cymbal). Losing the Bolukbasi routs the Azabs early, without the charge.
## Cues are short one-shot signals, never music: the game's own soundtrack plays over matches.
## assault (Horde): no command platform to hold, so on SCREEN the Janissaries advance in the
## line too and the raiders flank at once. hunt() sends every survivor at a target (Horde's
## stall breaker for the last few of a wave).

signal phase_changed(phase: Phase)
## Every sound cue (NewOttomanSounds names) as it plays, for subtitles / tests.
signal cue(name: StringName)

enum Phase { IDLE, SCREEN, PEEL, BREAK }

const PHASE_NAMES := ["IDLE", "SCREEN", "PEEL", "BREAK"]
const POLL_INTERVAL := 0.25
## PEEL once this fraction of the Azab line is down, or SCREEN has run this long.
const PEEL_LOSSES := 0.34
const SCREEN_TIME := 25.0
## Volley beat: the line fires together for VOLLEY_ON of every VOLLEY_PERIOD seconds.
const VOLLEY_PERIOD := 3.0
const VOLLEY_ON := 1.5
## Flank points generated around the contact when no Flank* markers exist.
const FLANK_RADIUS := 14.0
## Horn and cymbal sit under the game's music and gunfire: signals, not a soundtrack.
const CUE_VOLUME_DB := -10.0

@export var difficulty: BotDifficulty
@export var auto_alert_on_damage: bool = true
## Horde: everyone pushes from the first contact (see the class comment).
@export var assault: bool = false

var phase: Phase = Phase.IDLE
var members: Array[Enemy] = []
var contact: Node3D
var contact_pos: Vector3 = Vector3.INF

var _since_phase: float = 0.0
var _poll_left: float = 0.0
var _line_start: int = 0
var _flank_index: int = 0
var _azabs_routed: bool = false


## Adds an enemy of `type` at the world transform `xform` (its type is set before it enters
## the tree, so Enemy._ready sees it).
func spawn(type: EnemyType, xform: Transform3D, scene: PackedScene = null) -> Enemy:
	var packed := scene if scene != null else load("res://scenes/enemies/enemy.tscn") as PackedScene
	var e := packed.instantiate() as Enemy
	e.enemy_type = type
	if difficulty != null:
		e.difficulty = difficulty
	e.name = "%s%d" % [String(type.id).to_pascal_case(), get_child_count()]
	e.transform = global_transform.affine_inverse() * xform if is_inside_tree() else xform
	add_child(e)
	return e


func _ready() -> void:
	child_entered_tree.connect(_on_child_entered)
	for child in get_children():
		_on_child_entered(child)


func _on_child_entered(child: Node) -> void:
	var e := child as Enemy
	if e == null or members.has(e):
		return
	members.append(e)
	e.died.connect(_on_member_died)
	if e.is_node_ready():
		_adopt(e)
	else:
		# Deferred: the EnemyBrain sets its own defaults on the same ready signal; go after it.
		e.ready.connect(_adopt.bind(e), CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _adopt(e: Enemy) -> void:
	var brain := brain_of(e)
	if brain == null:
		return
	brain.orta = self
	match e.enemy_type.role:
		EnemyType.Role.MARKSMAN:
			var perch := _marker_near(&"Perch", e.global_position)
			if perch != Vector3.INF:
				brain.post = perch
		EnemyType.Role.HEAVY, EnemyType.Role.COMMANDER:
			var spot := _free_marker(&"Platform", e)
			if spot != Vector3.INF:
				brain.post = spot
	match phase:
		Phase.IDLE:
			if e.enemy_type.role == EnemyType.Role.RAIDER and not assault:
				brain.set_order(EnemyBrain.Order.HOLD)
			elif assault:
				if _in_line(e):
					brain.set_order(EnemyBrain.Order.ADVANCE)
				elif e.enemy_type.role == EnemyType.Role.RAIDER:
					brain.set_order(EnemyBrain.Order.FLANK, next_flank_point(e))
				elif e.enemy_type.role == EnemyType.Role.MARKSMAN:
					brain.set_order(EnemyBrain.Order.OVERWATCH)
		Phase.SCREEN:
			if _in_line(e):
				brain.set_order(EnemyBrain.Order.ADVANCE)
			elif e.enemy_type.role == EnemyType.Role.RAIDER:
				if assault:
					brain.set_order(EnemyBrain.Order.FLANK, next_flank_point(e))
				else:
					brain.set_order(EnemyBrain.Order.HOLD)
			elif e.enemy_type.role == EnemyType.Role.MARKSMAN:
				brain.set_order(EnemyBrain.Order.OVERWATCH)
		Phase.PEEL:
			if _is_azab(e) and not _azabs_routed:
				brain.set_order(EnemyBrain.Order.PEEL, _peel_post(e))
			elif e.enemy_type.role == EnemyType.Role.RAIDER:
				brain.set_order(EnemyBrain.Order.FLANK, next_flank_point(e))
			elif e.enemy_type.role == EnemyType.Role.MARKSMAN:
				brain.set_order(EnemyBrain.Order.OVERWATCH)
		Phase.BREAK:
			if _is_janissary(e):
				brain.set_order(EnemyBrain.Order.CHARGE)
			elif _is_azab(e):
				brain.set_order(EnemyBrain.Order.ROUT)
	if contact != null:
		brain.alert(contact, contact_pos)
	_assign_line_slots()


static func brain_of(e: Enemy) -> EnemyBrain:
	return e.get_node_or_null(^"Brain") as EnemyBrain if e != null else null


func living(filter: Callable = Callable()) -> Array[Enemy]:
	var out: Array[Enemy] = []
	for e in members:
		if is_instance_valid(e) and not e.dead and (not filter.is_valid() or filter.call(e)):
			out.append(e)
	return out


func volley_open() -> bool:
	if phase == Phase.IDLE:
		return true
	return fmod(_since_phase + float(_line_start), VOLLEY_PERIOD) < VOLLEY_ON


func get_phase_name() -> String:
	return PHASE_NAMES[phase]


# ------------------------------------------------------------------ contact


## A member saw or was hit by `node`: everyone learns where it is; the first contact starts
## the SCREEN.
func report_contact(_from: Enemy, node: Node3D, pos: Vector3) -> void:
	if node == null or not is_instance_valid(node) or not ArenaEvents.is_alive(node):
		return
	contact = node
	contact_pos = pos
	for e in living():
		var brain := brain_of(e)
		if brain != null and brain.target == null:
			brain.alert(node, pos)
	if phase == Phase.IDLE:
		_set_phase(Phase.SCREEN)


func _physics_process(delta: float) -> void:
	_since_phase += delta
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = POLL_INTERVAL
	for e in living():
		var brain := brain_of(e)
		if brain != null and brain.is_engaged() and brain.target != null:
			report_contact(e, brain.target, brain.target.global_position)
			break
	if phase == Phase.SCREEN and (_line_losses() >= PEEL_LOSSES or _since_phase > SCREEN_TIME):
		_set_phase(Phase.PEEL)


func _line_losses() -> float:
	var total := 0
	var down := 0
	for e in members:
		if not is_instance_valid(e):
			continue
		if e.enemy_type.corps == EnemyType.Corps.AZAB:
			total += 1
			if e.dead:
				down += 1
	return float(down) / float(total) if total > 0 else 1.0


# ------------------------------------------------------------------ phases


func _set_phase(next: Phase) -> void:
	if next == phase:
		return
	phase = next
	_since_phase = 0.0
	match next:
		Phase.SCREEN:
			_play(&"horn_advance", _officer_or_centre(EnemyType.Role.SQUAD_LEADER))
			# The line and its Bolukbasi push; the Okcu lob from where they stand, behind it.
			for e in living(_in_line):
				brain_of(e).set_order(EnemyBrain.Order.ADVANCE)
			if assault:
				for e in living(_is_role.bind(EnemyType.Role.RAIDER)):
					brain_of(e).set_order(EnemyBrain.Order.FLANK, next_flank_point(e))
			for e in living(_is_role.bind(EnemyType.Role.MARKSMAN)):
				brain_of(e).set_order(EnemyBrain.Order.OVERWATCH)
		Phase.PEEL:
			_play(&"horn_withdraw", _officer_or_centre(EnemyType.Role.SQUAD_LEADER))
			if not _azabs_routed:
				for e in living(_is_azab):
					brain_of(e).set_order(EnemyBrain.Order.PEEL, _peel_post(e))
			for e in living(_is_role.bind(EnemyType.Role.RAIDER)):
				brain_of(e).set_order(EnemyBrain.Order.FLANK, next_flank_point(e))
		Phase.BREAK:
			_play(&"cymbal", global_position)
			_rout_azabs()
			for e in living(_is_janissary):
				brain_of(e).set_order(EnemyBrain.Order.CHARGE)
	phase_changed.emit(next)


## Every survivor goes after `node`: Janissaries charge, raiders flank it, everyone else
## (routed Azabs included: they rally) advances on it.
func hunt(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	report_contact(null, node, node.global_position)
	for e in living():
		var brain := brain_of(e)
		if brain == null:
			continue
		brain.alert(node, node.global_position, true)
		match e.enemy_type.corps:
			EnemyType.Corps.JANISSARY:
				brain.set_order(EnemyBrain.Order.CHARGE)
			EnemyType.Corps.AKINJI:
				brain.set_order(EnemyBrain.Order.FLANK, node.global_position)
			_:
				brain.set_order(EnemyBrain.Order.ADVANCE)


func _on_member_died(bot: Bot, killer: Node, _info: Dictionary) -> void:
	var e := bot as Enemy
	if e == null:
		return
	if killer is Node3D and ArenaEvents.is_alive(killer):
		report_contact(e, killer as Node3D, (killer as Node3D).global_position)
	match e.enemy_type.role:
		EnemyType.Role.COMMANDER:
			_set_phase(Phase.BREAK)
		EnemyType.Role.SQUAD_LEADER:
			# Kill the Bolukbasi and the squad falls back.
			_play(&"horn_withdraw", e.global_position)
			_rout_azabs()


func _rout_azabs() -> void:
	_azabs_routed = true
	for a in living(_is_azab):
		brain_of(a).set_order(EnemyBrain.Order.ROUT)


func _play(name_: StringName, at: Vector3) -> void:
	cue.emit(name_)
	NewOttomanSounds.play_at(self, name_, at, CUE_VOLUME_DB)


func _officer_or_centre(role: EnemyType.Role) -> Vector3:
	for e in living(_is_role.bind(role)):
		return e.global_position
	return global_position


# ------------------------------------------------------------------ points


## Next flank point for a raider: the Flank* markers in turn (skipping the one it's at), or a
## point FLANK_RADIUS m from the contact, alternating sides of the orta -> contact line.
func next_flank_point(e: Enemy) -> Vector3:
	var markers := _markers(&"Flank")
	if not markers.is_empty():
		for i in markers.size():
			_flank_index = (_flank_index + 1) % markers.size()
			var p := markers[_flank_index]
			if p.distance_to(e.global_position) > 4.0:
				return p
		return markers[_flank_index]
	if contact_pos == Vector3.INF:
		return Vector3.INF
	var to_contact := contact_pos - global_position
	to_contact.y = 0.0
	to_contact = to_contact.normalized() if to_contact.length_squared() > 0.01 else Vector3.FORWARD
	_flank_index += 1
	var side := 1.0 if _flank_index % 2 == 0 else -1.0
	var want := contact_pos + to_contact.cross(Vector3.UP) * side * FLANK_RADIUS
	var map := get_world_3d().navigation_map
	var p := NavigationServer3D.map_get_closest_point(map, want)
	return p if p != Vector3.ZERO else want


## The Peel* marker on this Azab's side of the line (nearest), or a point 8 m out to its side.
func _peel_post(e: Enemy) -> Vector3:
	var near := _marker_near(&"Peel", e.global_position)
	if near != Vector3.INF:
		return near
	var brain := brain_of(e)
	var side := signf(brain.line_slot) if brain.line_slot != 0.0 else 1.0
	return e.global_position + global_transform.basis.x * side * 8.0 + global_transform.basis.z * 6.0


## Nearest Fallback* marker to the enemy that is farther from the contact than it is.
func fallback_point(e: Enemy) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for p in _markers(&"Fallback"):
		var toward_contact := (
			contact_pos != Vector3.INF
			and p.distance_to(contact_pos) < e.global_position.distance_to(contact_pos)
		)
		if toward_contact:
			continue
		var d := p.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


func _markers(prefix: StringName) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var root := get_node_or_null(^"Points")
	if root == null:
		return out
	for child in root.get_children():
		if child is Node3D and String(child.name).begins_with(prefix):
			out.append((child as Node3D).global_position)
	return out


func _marker_near(prefix: StringName, at: Vector3) -> Vector3:
	var best := Vector3.INF
	for p in _markers(prefix):
		if best == Vector3.INF or p.distance_to(at) < best.distance_to(at):
			best = p
	return best


## Nearest Platform* marker no other Janissary has taken.
func _free_marker(prefix: StringName, e: Enemy) -> Vector3:
	var taken: Array[Vector3] = []
	for other in members:
		if other != e and is_instance_valid(other) and brain_of(other) != null:
			taken.append(brain_of(other).post)
	var best := Vector3.INF
	for p in _markers(prefix):
		if taken.has(p):
			continue
		if best == Vector3.INF or p.distance_to(e.global_position) < best.distance_to(e.global_position):
			best = p
	return best


## Spread the Azab line: slots -n..n by position across the orta's facing. The Bolukbasi
## keeps slot 0 (the centre, behind the line as it forms up).
func _assign_line_slots() -> void:
	var line := living(
		func(e: Enemy) -> bool:
			return e.enemy_type.role == EnemyType.Role.LINE or (assault and _is_janissary(e))
	)
	var right := global_transform.basis.x
	line.sort_custom(func(a: Enemy, b: Enemy) -> bool:
		return a.global_position.dot(right) < b.global_position.dot(right))
	for i in line.size():
		var brain := brain_of(line[i])
		if brain != null:
			brain.line_slot = float(i) - float(line.size() - 1) * 0.5


static func _is_azab(e: Enemy) -> bool:
	return e.enemy_type.corps == EnemyType.Corps.AZAB


func _in_line(e: Enemy) -> bool:
	var role := e.enemy_type.role
	var heavy := e.enemy_type.corps == EnemyType.Corps.JANISSARY
	if assault and (heavy or role == EnemyType.Role.GRENADIER):
		return true
	return role == EnemyType.Role.LINE or role == EnemyType.Role.SQUAD_LEADER


static func _is_janissary(e: Enemy) -> bool:
	return e.enemy_type.corps == EnemyType.Corps.JANISSARY


static func _is_role(e: Enemy, role: EnemyType.Role) -> bool:
	return e.enemy_type.role == role
