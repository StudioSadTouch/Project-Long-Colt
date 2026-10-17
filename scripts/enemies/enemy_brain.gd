class_name EnemyBrain
extends BotBrain
## BotBrain plus the New Ottoman encounter grammar. Perception, the aim model, weapons, melee
## and navigation are BotBrain's; this adds orders from the Orta (squad) and per-role habits:
##   HOLD       stay on a post (a leash of POST_LEASH m), fight from there. Janissary gunline.
##   ADVANCE    Azab screen: push to volley range in a loose line, volley, hold.
##   PEEL       Azab withdrawal to a flank post, then hold there.
##   FLANK      Akinji raider: run wide to a flank point, harass, withdraw under pressure, then
##              circle back from another angle (asks the Orta for a new point).
##   OVERWATCH  Akinji marksman: take the perch and stay; scope glint before every shot.
##   CHARGE     the break: blade out, close and cut. Also what an EXPOSED Janissary does.
##   ROUT       officer down: run from the threat, fire only when cornered.
## With no Orta an enemy behaves as its role's default order (HOLD at its spawn point).

enum Order { HOLD, ADVANCE, PEEL, FLANK, OVERWATCH, CHARGE, ROUT }

const ORDER_NAMES := ["HOLD", "ADVANCE", "PEEL", "FLANK", "OVERWATCH", "CHARGE", "ROUT"]
const POST_LEASH := 4.0
## The marksman's perch is small: he shifts, he doesn't wander.
const PERCH_LEASH := 1.2
## Azab volley range and line spacing. Okcu advancing with the line stop farther back.
const VOLLEY_RANGE := 15.0
const LOB_RANGE := 24.0
const LINE_SPACING := 2.5
## Raider withdrawal triggers: health lost inside PRESSURE_WINDOW, or a target this close.
const PRESSURE_FRACTION := 0.3
const PRESSURE_WINDOW := 2.0
const PRESSURE_DISTANCE := 7.0
const WITHDRAW_TIME := 3.0
const HARASS_TIME := 6.0
## Seconds between the marksman's glint and the shot it warns of.
const GLINT_LEAD := 0.55
const ROUT_FIRE_DISTANCE := 6.0
const ROUT_DISTANCE := 22.0
## Squadmates' hurtboxes (Enemy layer) and head hitboxes: what the friendly-fire check sees.
const FRIEND_MASK := 4 | 32

var order: Order = Order.HOLD
## Post for HOLD / PEEL / OVERWATCH (world position), and where to face there.
var post: Vector3 = Vector3.INF
var post_facing: Vector3 = Vector3.ZERO
## Slot in the Azab line (-n..n), spreads the advance laterally.
var line_slot: float = 0.0
## Flank point for FLANK.
var flank_point: Vector3 = Vector3.INF
var orta: Orta

var _enemy: Enemy
var _raid_phase: StringName = &"flank"
var _raid_left: float = 0.0
var _recent_damage: Array[Vector2] = []  # (time, amount)
var _glint_fire_at: float = INF
var _rout_goal: Vector3 = Vector3.INF
var _own: Array[RID] = []
var _aim_at: Vector3 = Vector3.INF


func _ready() -> void:
	super()
	_enemy = get_parent() as Enemy
	if _enemy == null:
		return
	if not _enemy.is_node_ready():
		await _enemy.ready
	if post == Vector3.INF:
		post = _enemy.global_position
		post_facing = -_enemy.global_transform.basis.z
	if order == Order.HOLD:
		order = default_order(_enemy.enemy_type)
	if _enemy.armor_stages != null:
		_enemy.armor_stages.stage_changed.connect(_on_stage_changed)


static func default_order(t: EnemyType) -> Order:
	match t.role:
		EnemyType.Role.RAIDER:
			return Order.FLANK
		EnemyType.Role.MARKSMAN:
			return Order.OVERWATCH
		_:
			return Order.HOLD


func get_state_name() -> String:
	return "%s/%s" % [STATE_NAMES[state], ORDER_NAMES[order]]


## Orders come from the Orta. Re-issuing the same order is a no-op.
func set_order(next: Order, at: Vector3 = Vector3.INF) -> void:
	if _bot.dead:
		return
	if next == order and at == Vector3.INF:
		return
	order = next
	_has_goal = false
	match next:
		Order.HOLD, Order.PEEL, Order.OVERWATCH:
			if at != Vector3.INF:
				post = at
		Order.FLANK:
			flank_point = at
			_raid_phase = &"flank"
		Order.CHARGE:
			_draw_blade()
		Order.ROUT:
			_rout_goal = Vector3.INF


## Shared contact from the Orta: a squadmate saw or was hit by `node` at `pos`. force (a
## hunt): `node` becomes the target even if we had another, and we go looking unless engaged.
func alert(node: Node3D, pos: Vector3, force: bool = false) -> void:
	if _bot.dead or node == null or not is_instance_valid(node):
		return
	_remember(node, pos, false)
	if target == null or force:
		target = node
		if _first_shot_at == INF or not is_finite(_first_shot_at):
			_on_new_target(node)
	if state == State.PATROL or (force and state != State.ENGAGE):
		_set_search(pos)


func is_engaged() -> bool:
	return state == State.ENGAGE or state == State.RETREAT


# ------------------------------------------------------------------ overrides


## Halo campaign AI doesn't shop for guns: enemies keep their issue weapons.
func _choose_pickup(_radius: float) -> bool:
	return false


func _choose_weapon(dist: float) -> void:
	if order == Order.CHARGE or _exposed():
		_draw_blade()
		return
	super(dist)


func _do_patrol() -> Vector3:
	var goal := _order_goal()
	if goal == Vector3.INF:
		return Vector3.ZERO
	_set_goal(goal)
	if _arrived() and order == Order.FLANK and orta != null and orta.contact_pos != Vector3.INF:
		# Reached the flank with nobody in sight: work round to the next angle.
		flank_point = orta.next_flank_point(_enemy)
		return Vector3.ZERO
	if _arrived():
		if post_facing != Vector3.ZERO and order != Order.ROUT:
			var face := _slerp_dir(_bot.get_look_direction(), post_facing, 0.1)
			_bot.set_aim(Vector3(face.x, 0.0, face.z))
		return Vector3.ZERO
	return _move_along_path(1.0 if order == Order.ROUT or order == Order.FLANK else 0.7)


## Posted units don't wander off to look for the player: they watch from the post.
func _do_search(delta: float) -> Vector3:
	if order in [Order.HOLD, Order.OVERWATCH, Order.PEEL, Order.ROUT]:
		var entry := _target_entry()
		var back := _do_patrol()
		if back == Vector3.ZERO and not entry.is_empty():
			var to: Vector3 = entry.pos - _bot.global_position
			_bot.set_aim(Vector3(to.x, 0.0, to.z))
		return back
	return super(delta)


func _do_engage(delta: float) -> Vector3:
	var entry := _target_entry()
	if entry.is_empty():
		return Vector3.ZERO
	var weapon := _bot.get_active()
	if weapon != null and weapon.data != null and weapon.data.melee_primary:
		return super(delta)
	match order:
		Order.ADVANCE:
			return _engage_advance(delta)
		Order.FLANK:
			return _engage_flank(delta)
		Order.ROUT:
			return _engage_rout()
		Order.CHARGE:
			return super(delta)
		_:
			if _exposed():
				return super(delta)
			return _engage_posted(delta)


func _prefer_high_arc() -> bool:
	return _enemy != null and _enemy.enemy_type.role == EnemyType.Role.GRENADIER


func _fire_allowed(weapon: BotWeapon, dist: float) -> bool:
	if order == Order.ROUT and dist >= ROUT_FIRE_DISTANCE:
		return false
	if _enemy == null:
		return true
	if not _line_clear():
		return false
	var role := _enemy.enemy_type.role
	if role == EnemyType.Role.MARKSMAN:
		return _glint_gate(weapon)
	if role in [EnemyType.Role.LINE, EnemyType.Role.GRENADIER, EnemyType.Role.SQUAD_LEADER]:
		# The Azab line fires in volleys on the Orta's beat (always, without one).
		return orta == null or orta.volley_open()
	return true


## Shoot at what we can see: the chosen point if it's in plain view, else the head, else the
## face (a defender peeking over a deck edge or a railing), else the chosen point anyway.
## Remembered for _line_clear.
func _aim_point(eye: Vector3, points: Dictionary, chosen: Vector3) -> Vector3:
	_aim_at = chosen
	if not _has_los(eye, chosen):
		for key: String in ["head", "face"]:
			if points.has(key) and _has_los(eye, points[key]):
				_aim_at = points[key]
				break
	return _aim_at


## Hold fire unless the line to the aim point is clear: no level geometry in the way (the
## arena aim model would empty a magazine into a railing at a target it only half sees) and
## no squadmate (Halo AI won't shoot through its own). Lobbed shots arc over, so they only
## check for squadmates.
func _line_clear() -> bool:
	if _aim_at == Vector3.INF:
		return true
	var eye := _bot.get_eye_position()
	var to := _aim_at - (_aim_at - eye).normalized() * 0.3
	var weapon := _bot.get_active()
	var lob := weapon != null and weapon.data != null and weapon.data.projectile_gravity > 0.0
	var mask := FRIEND_MASK if lob else FRIEND_MASK | LOS_MASK
	var query := PhysicsRayQueryParameters3D.create(eye, to, mask)
	query.exclude = _own_rids()
	var hit := _bot.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var body := hit.collider as Node
	while body != null and body != target and not (body is Bot or body is Player or body.has_method(&"take_damage")):
		body = body.get_parent()
	if body == null:
		return false  # level geometry
	return body == target or ArenaEvents.is_hostile(_bot, body)


func _own_rids() -> Array[RID]:
	if _own.is_empty():
		for body in _bot.get_own_colliders():
			_own.append(body.get_rid())
	return _own


# ------------------------------------------------------------------ order behaviours


## Fight from the post: BotBrain's strafing, held on a leash and never off a ledge (BotBrain
## would path toward a far target; a posted unit stays put instead).
func _engage_posted(delta: float) -> Vector3:
	var wish := super._do_engage(delta)
	if post == Vector3.INF:
		return wish
	var leash := PERCH_LEASH if order == Order.OVERWATCH else POST_LEASH
	var to_post := post - _bot.global_position
	to_post.y = 0.0
	if to_post.length() > leash + 1.0:
		_set_goal(post)
		return _move_along_path(1.0)
	_has_goal = false
	if wish.length_squared() < 0.0001:
		return Vector3.ZERO
	var next := _bot.global_position + wish.normalized()
	if Vector2(next.x - post.x, next.z - post.z).length() > leash:
		return Vector3.ZERO
	if not _walkable(wish.normalized()):
		return Vector3.ZERO
	return wish


## Azab screen: walk to volley range in a loose line, then stand and volley.
func _engage_advance(delta: float) -> Vector3:
	var dist := _target_distance()
	if dist <= _melee_reach() or dist < 5.0:
		return super._do_engage(delta)  # too close: melee / back off as the bot would
	var from_target := _bot.global_position - target.global_position
	from_target.y = 0.0
	if from_target.length_squared() < 0.01:
		from_target = Vector3.BACK
	var away := from_target.normalized()
	var lateral := away.cross(Vector3.UP)
	var stand_off := VOLLEY_RANGE
	if _enemy != null and _enemy.enemy_type.role == EnemyType.Role.GRENADIER:
		stand_off = LOB_RANGE
	var spot := target.global_position + away * stand_off + lateral * line_slot * LINE_SPACING
	if dist > stand_off + 3.0:
		_set_goal(spot)
		return _move_along_path(0.75)
	# In range: hold the line; a little crouch-and-rise between volleys.
	if orta != null and not orta.volley_open() and _rng.randf() < 0.6 * delta:
		_crouch_left = _rng.randf_range(0.4, 0.9)
	return Vector3.ZERO


## Akinji raider: flank -> harass -> withdraw -> (new flank point) -> ...
func _engage_flank(delta: float) -> Vector3:
	_raid_left -= delta
	match _raid_phase:
		&"flank":
			if flank_point == Vector3.INF:
				_raid_phase = &"harass"
				_raid_left = HARASS_TIME
				return super._do_engage(delta)
			_set_goal(flank_point)
			if _arrived():
				_raid_phase = &"harass"
				_raid_left = HARASS_TIME
				return Vector3.ZERO
			return _move_along_path(1.0)
		&"withdraw":
			if _raid_left <= 0.0 or (_has_goal and _arrived()):
				_circle_back()
				return Vector3.ZERO
			return _move_along_path(1.0)
		_:
			if _under_pressure():
				_start_withdraw()
				return _move_along_path(1.0)
			if _raid_left <= 0.0:
				_circle_back()
			return super._do_engage(delta)


func _engage_rout() -> Vector3:
	if _rout_goal == Vector3.INF or (_has_goal and _arrived()):
		_rout_goal = _pick_rout_goal()
		if _rout_goal == Vector3.INF:
			return Vector3.ZERO
		_has_goal = false
	_set_goal(_rout_goal)
	_crouch_left = 0.0
	return _move_along_path(1.0)


func _order_goal() -> Vector3:
	match order:
		Order.FLANK:
			return flank_point if flank_point != Vector3.INF else post
		Order.ROUT:
			if _rout_goal == Vector3.INF:
				_rout_goal = _pick_rout_goal()
			return _rout_goal
		Order.ADVANCE, Order.CHARGE:
			# Pushing with no one in sight: head for the squad's last contact.
			if orta != null and orta.contact_pos != Vector3.INF:
				return orta.contact_pos
			return post
		_:
			return post


# ------------------------------------------------------------------ raider helpers


func _under_pressure() -> bool:
	var dist := _target_distance()
	if dist < PRESSURE_DISTANCE:
		return true
	var lost := 0.0
	for d in _recent_damage:
		if _now - d.x <= PRESSURE_WINDOW:
			lost += d.y
	var pool := _bot.health_shield.max_health + _bot.health_shield.max_shield
	return lost >= pool * PRESSURE_FRACTION


func _start_withdraw() -> void:
	_raid_phase = &"withdraw"
	_raid_left = WITHDRAW_TIME
	_has_goal = false
	var threat := target if target != null and is_instance_valid(target) else _threat
	var cover := _find_cover(threat) if threat != null and is_instance_valid(threat) else Vector3.INF
	if cover == Vector3.INF:
		cover = _away_point(threat, 10.0)
	if cover != Vector3.INF:
		_set_goal(cover)


func _circle_back() -> void:
	_has_goal = false
	_raid_phase = &"flank"
	flank_point = orta.next_flank_point(_enemy) if orta != null else Vector3.INF


# ------------------------------------------------------------------ marksman / blade / rout


## One glint, a beat, then the shot. The window after the beat lets the paced SEMI press land.
func _glint_gate(weapon: BotWeapon) -> bool:
	if _glint_fire_at < INF and _now >= _glint_fire_at + 0.3:
		_glint_fire_at = INF
	if _glint_fire_at == INF:
		if weapon == null or not weapon.is_ready_to_fire() or _now < _first_shot_at:
			return false
		_glint_fire_at = _now + GLINT_LEAD
		_enemy.get_rig().glint(GLINT_LEAD + 0.2)
		return false
	return _now >= _glint_fire_at


func _draw_blade() -> void:
	var active := _bot.get_active()
	if active != null and active.data != null and active.data.melee_primary:
		return
	var other := _bot.get_other()
	if other != null and other.data != null and other.data.melee_primary:
		_release_trigger()
		_bot.switch_weapon()


func _exposed() -> bool:
	if _enemy == null or _enemy.armor_stages == null:
		return false
	return _enemy.get_stage() == ArmorStages.Stage.EXPOSED


func _pick_rout_goal() -> Vector3:
	if orta != null:
		var fallback := orta.fallback_point(_enemy)
		if fallback != Vector3.INF:
			return fallback
	var threat := target if target != null and is_instance_valid(target) else _threat
	return _away_point(threat, ROUT_DISTANCE)


## Navmesh point `distance` m from the threat, on our side of it.
func _away_point(threat: Node3D, distance: float) -> Vector3:
	var origin := _bot.global_position
	var away := Vector3.BACK
	if threat != null and is_instance_valid(threat):
		away = origin - threat.global_position
		away.y = 0.0
		away = away.normalized() if away.length_squared() > 0.01 else Vector3.BACK
	var want := origin + away * distance
	var map := _bot.get_world_3d().navigation_map
	var p := NavigationServer3D.map_get_closest_point(map, want)
	# No navmesh yet (closest point is the origin): head that way anyway.
	return p if p != Vector3.ZERO else want


# ------------------------------------------------------------------ events


func _on_damaged(amount: float, info: Dictionary) -> void:
	super(amount, info)
	_recent_damage.append(Vector2(_now, amount))
	while _recent_damage.size() > 8:
		_recent_damage.pop_front()
	var source: Variant = info.get("source")
	if orta != null and is_instance_valid(source) and source is Node3D:
		orta.report_contact(_enemy, source as Node3D, (source as Node3D).global_position)


func _on_stage_changed(stage: ArmorStages.Stage) -> void:
	if stage == ArmorStages.Stage.EXPOSED:
		# Brutal once the armour is off: blade out, close for melee.
		_draw_blade()
		if order in [Order.HOLD, Order.OVERWATCH, Order.PEEL]:
			order = Order.CHARGE
