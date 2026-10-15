# gdlint: disable=max-returns
class_name BotBrain
extends Node
## Bot decision making: a small state machine with perception, a Halo-style aim model and
## nav-link traversal. Child of a Bot named "Brain". Runs before the Bot each physics tick
## (process_physics_priority -10) and writes the Bot's inputs.
##
## States: PATROL (roam points), SEARCH (last known / heard position), ENGAGE, RETREAT
## (break line of sight while the shield recharges), SEEK_PICKUP (weapons / ammo).
## Targets: every living hostile in groups "player" and "bot" (FFA: bots fight each other too;
## ArenaEvents.is_hostile compares team fields, so team modes only need team assignment).
## See docs/ai/arena_ai_spec.md for the aim model and the difficulty tunables.

enum State { PATROL, SEARCH, ENGAGE, RETREAT, SEEK_PICKUP }

const STATE_NAMES := ["PATROL", "SEARCH", "ENGAGE", "RETREAT", "PICKUP"]
const THINK_INTERVAL := 0.1
const LOS_MASK := 1
const MEMORY_TIME := 4.0
## A target lost longer than this costs a fresh reaction delay when reacquired.
const REACQUIRE_GRACE := 1.0
## Sensed without looking (footsteps, bumping).
const CLOSE_AWARENESS := 3.0
const ROAM_GROUP := &"ai_roam_point"
const REPATH_DISTANCE := 1.0
const ARRIVE_DISTANCE := 1.2
const SEARCH_LOOK_TIME := 1.5
const LINK_TIMEOUT := 4.0
## Jump at a link's lip when this close to it along the link direction.
const LIP_TRIGGER := 0.3
const STUCK_TIME := 1.2
const STUCK_DISTANCE := 0.4
## Preferred engagement bands (m). Rifle: AUTO up close, BURST (past burst_switch_range,
## 16-25 m by preset) at mid range, inside its 15-40 m falloff. Pistol: long range, where it has
## no falloff until 35 m and the rifle has lost most of its damage.
const RANGE_RIFLE := Vector2(6.0, 24.0)
const RANGE_PISTOL := Vector2(12.0, 40.0)
## Rifle below this distance, pistol above, with +/- WEAPON_SWITCH_HYSTERESIS so a bot near
## the split doesn't swap back and forth: holding the rifle it switches past 31 m, holding the
## pistol it switches back under 25 m.
const WEAPON_SPLIT := 28.0
const WEAPON_SWITCH_HYSTERESIS := 3.0
const CORNERED_DISTANCE := 5.0
const COVER_SEARCH_RADIUS := 25.0
const PICKUP_SEEK_RADIUS := 40.0
const OPPORTUNISTIC_PICKUP_RADIUS := 8.0
const BURST_HYSTERESIS := 3.0
const ZOOM_RANGE := 25.0
const LOW_AMMO_FRACTION := 0.25

var state: State = State.PATROL
var target: Node3D

var _bot: Bot
var _diff: BotDifficulty
var _events: ArenaEvents
var _rng := RandomNumberGenerator.new()
var _now: float = 0.0
var _think_left: float = 0.0
## Node instance id -> {"node", "pos", "seen_at", "visible", "acquired_at"}
var _memory: Dictionary = {}
# aim
var _track_dir: Vector3 = Vector3.FORWARD
var _err: Vector2 = Vector2.ZERO
var _err_goal: Vector2 = Vector2.ZERO
var _err_mag: float = 0.0
var _err_resample_left: float = 0.0
var _first_shot_at: float = INF
var _aim_head: bool = false
var _target_was_shielded: bool = true
var _last_lateral_sign: float = 0.0
# fire
var _spray_left: float = 0.0
var _pause_left: float = 0.0
var _next_press_at: float = 0.0
var _press_held: bool = false
# movement
var _goal: Vector3 = Vector3.ZERO
var _has_goal: bool = false
var _repath_flip: float = 0.01
var _strafe_dir: float = 1.0
var _strafe_left: float = 0.0
var _crouch_left: float = 0.0
var _roam_point: Node3D
var _recent_roams: Array[Node3D] = []
var _search_look_left: float = 0.0
var _retreat_rolled: bool = false
var _threat: Node3D
var _pickup: WeaponPickup
var _link: Dictionary = {}
var _stuck_origin: Vector3 = Vector3.ZERO
var _stuck_time: float = 0.0
var _stuck_jumped: bool = false


func _ready() -> void:
	_bot = get_parent() as Bot
	if _bot == null:
		push_error("BotBrain must be a child of a Bot")
		set_physics_process(false)
		return
	process_physics_priority = -10
	set_physics_process(false)
	# Children are ready before their parent: wait for the Bot's @onready nodes.
	if not _bot.is_node_ready():
		await _bot.ready
	set_physics_process(true)
	_rng.randomize()
	_diff = _bot.difficulty if _bot.difficulty != null else BotDifficulty.new()
	_bot.damaged.connect(_on_damaged)
	_bot.respawned.connect(func(_b: Bot) -> void: reset())
	_bot.health_shield.shield_broken.connect(_on_shield_broken)
	_bot.health_shield.shield_full.connect(_on_shield_full)
	_bot.health_shield.shield_damaged.connect(_on_shield_damaged)
	_bot.nav_agent.link_reached.connect(_on_link_reached)
	_events = ArenaEvents.find(get_tree())
	if _events != null:
		_events.gunfire.connect(_on_gunfire)
	reset()


func get_state_name() -> String:
	return STATE_NAMES[state]


func reset() -> void:
	state = State.PATROL
	target = null
	_threat = null
	_pickup = null
	_memory.clear()
	_link = {}
	_has_goal = false
	_roam_point = null
	_retreat_rolled = false
	_first_shot_at = INF
	_track_dir = _bot.get_look_direction()
	_release_trigger()
	_stuck_origin = _bot.global_position
	_stuck_time = 0.0


func _physics_process(delta: float) -> void:
	if _bot.dead:
		_release_trigger()
		return
	_now += delta
	_think_left -= delta
	if _think_left <= 0.0:
		_think_left = THINK_INTERVAL
		_perceive()
		_think()
	var wish := Vector3.ZERO
	match state:
		State.PATROL:
			wish = _do_patrol()
		State.SEARCH:
			wish = _do_search(delta)
		State.ENGAGE:
			wish = _do_engage(delta)
		State.RETREAT:
			wish = _do_retreat()
		State.SEEK_PICKUP:
			wish = _do_seek_pickup()
	_bot.want_crouch = _crouch_left > 0.0 and state == State.ENGAGE
	_crouch_left = maxf(_crouch_left - delta, 0.0)
	_bot.move_wish = wish
	if _target_visible() and (state == State.ENGAGE or state == State.RETREAT):
		_aim_at_target(delta)
	else:
		_release_trigger()
		_look_along(wish, delta)
	_check_stuck(delta, wish)


# ------------------------------------------------------------------ perception


func _candidates() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for group: StringName in [&"player", &"bot"]:
		for node in get_tree().get_nodes_in_group(group):
			var n := node as Node3D
			if (
				n != null
				and n != _bot
				and ArenaEvents.is_hostile(_bot, n)
				and ArenaEvents.is_alive(n)
			):
				out.append(n)
	return out


func _perceive() -> void:
	var eye := _bot.get_eye_position()
	var forward := _bot.get_look_direction()
	var half_fov := deg_to_rad(_diff.fov_deg * 0.5)
	for key in _memory.keys():
		var entry: Dictionary = _memory[key]
		entry.visible = false
		if not is_instance_valid(entry.node) or not ArenaEvents.is_alive(entry.node):
			_memory.erase(key)
	for c in _candidates():
		var points := ArenaEvents.aim_points_of(c)
		if points.is_empty():
			continue
		var body: Vector3 = points.body
		var to := body - eye
		var dist := to.length()
		if dist > _diff.sight_range or dist < 0.01:
			continue
		var in_fov := dist <= CLOSE_AWARENESS or forward.angle_to(to / dist) <= half_fov
		if not in_fov:
			continue
		var seen := _has_los(eye, body) or (points.has("head") and _has_los(eye, points.head))
		if seen:
			_remember(c, c.global_position, true)


func _remember(node: Node3D, pos: Vector3, seen: bool) -> void:
	var id := node.get_instance_id()
	var entry: Dictionary = _memory.get(id, {})
	if entry.is_empty():
		entry = {"node": node, "pos": pos, "seen_at": -INF, "visible": false, "acquired_at": -INF}
		_memory[id] = entry
	entry.pos = pos
	if seen:
		if _now - float(entry.seen_at) > REACQUIRE_GRACE:
			entry.acquired_at = _now
		entry.seen_at = _now
		entry.visible = true


func _has_los(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, LOS_MASK)
	return _bot.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _target_visible() -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var entry: Dictionary = _memory.get(target.get_instance_id(), {})
	return not entry.is_empty() and entry.visible


func _target_entry() -> Dictionary:
	if target == null or not is_instance_valid(target):
		return {}
	return _memory.get(target.get_instance_id(), {})


# ------------------------------------------------------------------ decisions


func _think() -> void:
	_pick_target()
	var weapon := _bot.get_active()
	var out_of_ammo := _all_ammo() <= 0
	var low_ammo := out_of_ammo or _ammo_fraction() < LOW_AMMO_FRACTION
	var visible := _target_visible()
	var dist := _target_distance()
	if state == State.RETREAT:
		var shield_ok := (
			_bot.health_shield.shield
			>= _bot.health_shield.max_shield * _diff.reengage_shield_fraction
		)
		var cornered := visible and dist < CORNERED_DISTANCE
		if shield_ok or cornered or _threat == null or not is_instance_valid(_threat):
			_retreat_rolled = false
			state = State.ENGAGE if visible else State.PATROL
		else:
			return
	if out_of_ammo and not (visible and dist <= _melee_reach()):
		if _choose_pickup(PICKUP_SEEK_RADIUS):
			state = State.SEEK_PICKUP
			return
	if visible:
		if state != State.ENGAGE:
			_on_engage_start()
		state = State.ENGAGE
		_choose_weapon(dist)
		return
	if low_ammo and _choose_pickup(PICKUP_SEEK_RADIUS):
		state = State.SEEK_PICKUP
		return
	var entry := _target_entry()
	if not entry.is_empty() and _now - float(entry.seen_at) < MEMORY_TIME:
		_set_search(entry.pos)
		return
	if state == State.SEEK_PICKUP and _pickup != null and _bot.wants_pickup(_pickup):
		return
	if state == State.SEARCH and _has_goal:
		return
	if _choose_pickup(OPPORTUNISTIC_PICKUP_RADIUS):
		state = State.SEEK_PICKUP
		return
	if weapon != null and weapon.magazine * 2 < weapon.data.magazine_size and weapon.reserve > 0:
		weapon.reload()  # Halo bots reload out of combat
	if state != State.PATROL:
		state = State.PATROL
		_roam_point = null


func _pick_target() -> void:
	var best: Node3D = null
	var best_score := INF
	var eye := _bot.get_eye_position()
	for entry: Dictionary in _memory.values():
		if not entry.visible:
			continue
		var node: Node3D = entry.node
		var score := eye.distance_to(node.global_position)
		if node == target:
			score -= 5.0
		if node == _threat:
			score -= 8.0
		if score < best_score:
			best_score = score
			best = node
	if best != null:
		if best != target:
			_on_new_target(best)
		target = best
	elif target != null and (not is_instance_valid(target) or not ArenaEvents.is_alive(target)):
		target = null


func _on_new_target(node: Node3D) -> void:
	var entry: Dictionary = _memory.get(node.get_instance_id(), {})
	var acquired: float = entry.get("acquired_at", _now)
	var jitter := _rng.randf_range(-_diff.reaction_jitter, _diff.reaction_jitter)
	_first_shot_at = maxf(acquired, _now - 0.05) + _diff.reaction_time * (1.0 + jitter)
	_err_mag = _diff.aim_error_deg
	_err_resample_left = 0.0
	_aim_head = false
	_target_was_shielded = true


func _on_engage_start() -> void:
	_strafe_left = 0.0
	# A full first spray (0 would fire one round, then a full pause).
	_spray_left = _diff.spray_time
	_pause_left = 0.0
	_has_goal = false
	_pickup = null
	var entry := _target_entry()
	if not entry.is_empty() and float(entry.acquired_at) >= _now - THINK_INTERVAL * 1.5:
		_on_new_target(target)


func _set_search(pos: Vector3) -> void:
	if state != State.SEARCH or not _has_goal or _goal.distance_to(pos) > 3.0:
		_search_look_left = SEARCH_LOOK_TIME
	state = State.SEARCH
	_set_goal(pos)


func _choose_pickup(radius: float) -> bool:
	if _events == null:
		return false
	var best: WeaponPickup = null
	var best_d := radius
	for p in _events.get_pickups():
		if not _bot.wants_pickup(p):
			continue
		var d := _bot.global_position.distance_to(p.global_position)
		# Prefer pickups that solve the actual problem: ammo for what we carry, or a new gun.
		if _bot.find_weapon(p.get_weapon_id()) == null and _all_ammo() > 0:
			d *= 1.5
		if d < best_d:
			best_d = d
			best = p
	_pickup = best
	return best != null


func _choose_weapon(dist: float) -> void:
	var active := _bot.get_active()
	var other := _bot.get_other()
	if other == null or _bot.is_lunging():
		return
	var a := _weapon_score(active, dist, true)
	var b := _weapon_score(other, dist, false)
	if active != null and active.magazine <= 0 and active.reserve > 0 and other.magazine > 0:
		# Halo: switching beats reloading under fire, for skilled players.
		if _rng.randf() < _diff.weapon_switch_skill:
			b += 3.0
	if b > a + 1.0:
		_release_trigger()
		_bot.switch_weapon()


## `held`: the active weapon gets the hysteresis margin, so switching needs a clear reason.
func _weapon_score(w: BotWeapon, dist: float, held: bool) -> float:
	if w == null or w.data == null or _bot.total_ammo(w) <= 0:
		return -100.0
	var auto := w.data.fire_mode == WeaponData.FireMode.AUTO
	var split := WEAPON_SPLIT
	if held:
		split += WEAPON_SWITCH_HYSTERESIS if auto else -WEAPON_SWITCH_HYSTERESIS
	if auto:
		return 2.0 if dist < split else -0.5
	return 2.0 if dist >= split else 0.5


# ------------------------------------------------------------------ states


func _do_patrol() -> Vector3:
	if _roam_point == null or not is_instance_valid(_roam_point) or _arrived():
		_roam_point = _pick_roam_point()
		if _roam_point == null:
			return Vector3.ZERO
		_set_goal(_roam_point.global_position)
	return _move_along_path(0.85)


func _do_search(delta: float) -> Vector3:
	if not _arrived():
		return _move_along_path(1.0)
	_search_look_left -= delta
	# Look around: sweep yaw while standing at the last known spot.
	var dir := _bot.get_look_direction().rotated(Vector3.UP, 2.5 * delta)
	_bot.set_aim(Vector3(dir.x, 0.0, dir.z))
	if _search_look_left <= 0.0:
		_has_goal = false
		state = State.PATROL
		_roam_point = null
	return Vector3.ZERO


func _do_seek_pickup() -> Vector3:
	if _pickup == null or not _bot.wants_pickup(_pickup):
		_pickup = null
		state = State.PATROL
		return Vector3.ZERO
	_set_goal(_pickup.global_position)
	if _bot.try_take_pickup(_pickup):
		_pickup = null
		state = State.PATROL
		return Vector3.ZERO
	return _move_along_path(1.0)


func _do_retreat() -> Vector3:
	if not _has_goal or _arrived():
		return Vector3.ZERO
	return _move_along_path(1.0)


func _do_engage(delta: float) -> Vector3:
	var entry := _target_entry()
	if entry.is_empty():
		return Vector3.ZERO
	var weapon := _bot.get_active()
	var dist := _target_distance()
	if not entry.visible:
		_set_goal(entry.pos)
		return _move_along_path(1.0)
	_has_goal = false
	_link = {}
	# Melee: always on a shield-down target in reach; otherwise by eagerness, or when dry.
	var reach := _melee_reach()
	if weapon != null and dist <= reach and _now >= _first_shot_at and _bot.is_melee_ready():
		var shield_down := not _target_shielded()
		var dry := weapon.magazine <= 0
		if shield_down or dry or _rng.randf() < _diff.melee_eagerness * delta:
			var points := ArenaEvents.aim_points_of(target)
			if not points.is_empty() and _bot.try_melee(target, points.body):
				_release_trigger()
	# Range keeping, scaled by aggression.
	var band := RANGE_RIFLE
	if weapon != null and weapon.data != null and weapon.data.fire_mode != WeaponData.FireMode.AUTO:
		band = RANGE_PISTOL
	var to_target := target.global_position - _bot.global_position
	to_target.y = 0.0
	var fwd := to_target.normalized() if to_target.length_squared() > 0.01 else Vector3.FORWARD
	var lateral := fwd.cross(Vector3.UP)
	var push := 0.0
	var max_range := band.y * (1.0 - 0.4 * _diff.aggression)
	if dist > max_range:
		push = 1.0
	elif dist < band.x and _diff.aggression < 0.5:
		push = -0.7
	elif not _target_shielded() and _diff.aggression >= 0.5:
		push = 0.8  # smell blood: close for the finish or the melee
	# ADAD strafe legs.
	_strafe_left -= delta
	if _strafe_left <= 0.0:
		_strafe_left = _rng.randf_range(_diff.strafe_min_time, _diff.strafe_max_time)
		if _rng.randf() < _diff.strafe_frequency:
			_strafe_dir = -_strafe_dir
		elif _rng.randf() < 0.15:
			_strafe_left *= 0.5
			_strafe_dir = 0.0 if _strafe_dir != 0.0 else 1.0
	if _rng.randf() < _diff.crouch_chance * delta:
		_crouch_left = _rng.randf_range(0.2, 0.6)
	if _bot.is_on_floor() and _rng.randf() < _diff.jump_chance * delta:
		_bot.request_jump()
	var wish := lateral * _strafe_dir + fwd * push
	if push > 0.5 and dist > max_range + 4.0:
		# Far away: path there instead of beelining into walls or off ledges.
		_set_goal(target.global_position)
		return _move_along_path(1.0)
	if wish.length_squared() > 0.0001 and not _walkable(wish.normalized()):
		_strafe_dir = -_strafe_dir
		wish = lateral * _strafe_dir + fwd * maxf(push, 0.0)
		if not _walkable(wish.normalized()):
			wish = Vector3.ZERO
	return wish.limit_length(1.0)


# ------------------------------------------------------------------ aim and fire


func _aim_at_target(delta: float) -> void:
	var weapon := _bot.get_active()
	var eye := _bot.get_eye_position()
	var points := ArenaEvents.aim_points_of(target)
	if points.is_empty():
		_release_trigger()
		return
	# Head only once the shield is down (zone multipliers only touch health).
	var shielded := _target_shielded()
	if _target_was_shielded and not shielded:
		_aim_head = _rng.randf() < _diff.headshot_bias
	_target_was_shielded = shielded
	var point: Vector3 = points.body
	if _aim_head and not _bot.is_lunging():
		if (
			points.has("face")
			and weapon != null
			and weapon.data != null
			and weapon.data.headshot_unarmored_multiplier > weapon.data.headshot_armored_multiplier
		):
			point = points.face
		elif points.has("head"):
			point = points.head
	# Lead cancels part of the tracking lag (hitscan: no ballistic lead).
	var vel := ArenaEvents.velocity_of(target)
	point += vel * _diff.tracking_lag * _diff.lead_skill
	var desired := (point - eye).normalized()
	# Strafe reversals throw the aim off again (the reason ADAD works on bots).
	var lateral_speed := vel.dot(desired.cross(Vector3.UP).normalized())
	var lateral_sign := signf(lateral_speed) if absf(lateral_speed) > 3.0 else 0.0
	if lateral_sign != 0.0 and _last_lateral_sign != 0.0 and lateral_sign != _last_lateral_sign:
		_err_mag = minf(
			_diff.aim_error_deg, _err_mag + _diff.aim_error_deg * _diff.strafe_error_bump
		)
	if lateral_sign != 0.0:
		_last_lateral_sign = lateral_sign
	# Tracking lag with a turn-rate cap.
	var alpha := 1.0 - exp(-delta / maxf(_diff.tracking_lag, 0.01))
	var next := _slerp_dir(_track_dir, desired, alpha)
	var step := _track_dir.angle_to(next)
	var max_step := deg_to_rad(_diff.max_turn_rate_deg) * delta
	if step > max_step and step > 0.0:
		next = _slerp_dir(_track_dir, next, max_step / step)
	_track_dir = next
	# Converging error, resampled a few times a second so it wanders instead of sticking.
	_err_mag = maxf(_diff.min_error_deg, _err_mag * exp(-_diff.convergence * delta))
	_err_resample_left -= delta
	if _err_resample_left <= 0.0:
		_err_resample_left = _rng.randf_range(0.2, 0.35)
		var r := deg_to_rad(_err_mag) * sqrt(_rng.randf())
		var a := _rng.randf() * TAU
		_err_goal = Vector2(cos(a) * r, sin(a) * r)
	_err = _err.lerp(_err_goal, 1.0 - exp(-8.0 * delta))
	_bot.set_aim(_apply_error(_track_dir, _err))
	if state == State.RETREAT and _rng.randf() < 0.5:
		_release_trigger()
		return
	_fire(weapon, desired, eye.distance_to(point), delta)


func _fire(weapon: BotWeapon, desired: Vector3, dist: float, delta: float) -> void:
	if weapon == null or weapon.data == null or _bot.is_lunging():
		_release_trigger()
		return
	if weapon.magazine <= 0:
		_release_trigger()
		if weapon.reserve > 0:
			weapon.reload()
		return
	_manage_modes(weapon, dist)
	if _now < _first_shot_at:
		_release_trigger()
		return
	var tolerance := atan(0.45 / maxf(dist, 0.5)) + deg_to_rad(_diff.fire_tolerance_deg)
	if _track_dir.angle_to(desired) > tolerance:
		_release_trigger()
		return
	if weapon.fire_mode == WeaponData.FireMode.AUTO:
		var range_scale := clampf(15.0 / maxf(dist, 1.0), 0.3, 1.0)
		if _pause_left > 0.0:
			_pause_left -= delta
			_release_trigger()
			return
		weapon.trigger(not _press_held, true)
		_press_held = true
		_spray_left -= delta
		if _spray_left <= 0.0:
			_spray_left = _diff.spray_time * range_scale * _rng.randf_range(0.7, 1.3)
			_pause_left = _diff.burst_pause / range_scale * _rng.randf_range(0.8, 1.2)
		return
	# SEMI / BURST: discrete presses at a paced cadence.
	if _press_held:
		_release_trigger()
		return
	if _now < _next_press_at or not weapon.is_ready_to_fire():
		return
	var cycle := 1.0 / maxf(weapon.data.fire_rate, 0.1)
	if weapon.fire_mode == WeaponData.FireMode.BURST:
		cycle = (
			weapon.data.burst_interval * maxi(weapon.data.burst_count - 1, 0)
			+ weapon.data.burst_cooldown
		)
	_next_press_at = _now + cycle / maxf(_diff.semi_cadence, 0.1)
	weapon.trigger(true, true)
	_press_held = true


## Rifle AUTO <-> BURST by range, pistol zoom.
func _manage_modes(weapon: BotWeapon, dist: float) -> void:
	var data := weapon.data
	var can_burst := (
		data.fire_mode == WeaponData.FireMode.AUTO
		and data.alt_fire_mode == WeaponData.FireMode.BURST
	)
	if can_burst:
		var want_alt := (
			dist > _diff.burst_switch_range + (0.0 if weapon.alt_mode else BURST_HYSTERESIS)
		)
		if not weapon.alt_mode and want_alt or weapon.alt_mode and dist < _diff.burst_switch_range:
			weapon.toggle_fire_mode()
			_press_held = false
	if data.secondary == WeaponData.Secondary.ZOOM:
		var want_zoom := _diff.uses_zoom and dist > ZOOM_RANGE and not weapon.reloading
		if want_zoom != weapon.zoomed:
			weapon.set_zoom(want_zoom)


func _release_trigger() -> void:
	if _press_held:
		var weapon := _bot.get_active()
		if weapon != null:
			weapon.release_trigger()
	_press_held = false


func _look_along(wish: Vector3, delta: float) -> void:
	var flat := Vector3(wish.x, 0.0, wish.z)
	var desired := _bot.get_look_direction()
	if not _link.is_empty():
		var exit: Vector3 = _link.exit
		var to_exit := exit - _bot.global_position
		flat = Vector3(to_exit.x, 0.0, to_exit.z)
	if flat.length_squared() > 0.01:
		desired = flat.normalized()
	elif state == State.SEARCH:
		return
	var next := _slerp_dir(_bot.get_look_direction(), desired, 1.0 - exp(-6.0 * delta))
	_track_dir = next
	_bot.set_aim(next)


static func _slerp_dir(from: Vector3, to: Vector3, t: float) -> Vector3:
	if from.is_equal_approx(to) or from.length_squared() < 0.0001:
		return to.normalized()
	if from.dot(to) < -0.999:
		from = (from + Vector3.UP * 0.01).normalized()
	return from.slerp(to, clampf(t, 0.0, 1.0)).normalized()


static func _apply_error(dir: Vector3, err: Vector2) -> Vector3:
	var right := dir.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	return dir.rotated(Vector3.UP, err.x).rotated(right, err.y).normalized()


# ------------------------------------------------------------------ helpers


func _target_distance() -> float:
	var entry := _target_entry()
	if entry.is_empty():
		return INF
	return _bot.get_eye_position().distance_to(entry.pos)


func _target_shielded() -> bool:
	if target == null:
		return true
	var hs := target.get_node_or_null(^"HealthShield") as HealthShield
	return hs == null or hs.is_shield_up()


func _melee_reach() -> float:
	var weapon := _bot.get_active()
	return weapon.data.melee_lunge_range if weapon != null and weapon.data != null else 0.0


func _all_ammo() -> int:
	var total := 0
	for w in _bot.slots:
		total += _bot.total_ammo(w)
	return total


func _ammo_fraction() -> float:
	var have := 0.0
	var cap := 0.0
	for w in _bot.slots:
		if w != null and w.data != null:
			have += w.magazine + w.reserve
			cap += w.data.magazine_size + w.data.reserve_max
	return have / cap if cap > 0.0 else 0.0


## Ground ahead (no ledge drop > 1 m) and no wall at chest height.
func _walkable(dir: Vector3) -> bool:
	var space := _bot.get_world_3d().direct_space_state
	var origin := _bot.global_position
	var chest := origin + Vector3.UP * 1.0
	var wall := PhysicsRayQueryParameters3D.create(chest, chest + dir * 1.0, LOS_MASK)
	if not space.intersect_ray(wall).is_empty():
		return false
	var probe := origin + dir * 1.0 + Vector3.UP * 0.5
	var down := PhysicsRayQueryParameters3D.create(probe, probe + Vector3.DOWN * 1.6, LOS_MASK)
	return not space.intersect_ray(down).is_empty()


func _pick_roam_point() -> Node3D:
	var points := get_tree().get_nodes_in_group(ROAM_GROUP)
	if points.is_empty():
		return null
	var total := 0.0
	var weights: Array[float] = []
	for node in points:
		var p := node as Node3D
		var w := float(p.get_meta(&"weight", 1.0))
		var d := _bot.global_position.distance_to(p.global_position)
		if d < 6.0 or _recent_roams.has(p):
			w *= 0.1
		elif d > 10.0 and d < 30.0:
			w *= 1.5
		weights.append(w)
		total += w
	var roll := _rng.randf() * total
	for i in points.size():
		roll -= weights[i]
		if roll <= 0.0:
			var chosen := points[i] as Node3D
			_recent_roams.append(chosen)
			if _recent_roams.size() > 3:
				_recent_roams.pop_front()
			return chosen
	return points.back() as Node3D


# ------------------------------------------------------------------ navigation


func _set_goal(pos: Vector3) -> void:
	if _has_goal and _goal.distance_to(pos) < REPATH_DISTANCE:
		return
	_goal = pos
	_has_goal = true
	_bot.nav_agent.target_position = pos


func _force_repath() -> void:
	if not _has_goal:
		return
	# Re-submitting an identical target may not trigger a path query; nudge it.
	_repath_flip = -_repath_flip
	_bot.nav_agent.target_position = _goal + Vector3(_repath_flip, 0.0, 0.0)


func _arrived() -> bool:
	if not _has_goal:
		return true
	var to := _goal - _bot.global_position
	return Vector2(to.x, to.z).length() < ARRIVE_DISTANCE and absf(to.y) < 2.0


func _move_along_path(speed_scale: float) -> Vector3:
	if not _link.is_empty():
		return _follow_link()
	if not _has_goal:
		return Vector3.ZERO
	var agent := _bot.nav_agent
	if agent.is_navigation_finished():
		if _arrived():
			return Vector3.ZERO
		var to_goal := _goal - _bot.global_position
		return Vector3(to_goal.x, 0.0, to_goal.z).limit_length(1.0) * speed_scale
	var next := agent.get_next_path_position()
	var to := next - _bot.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return Vector3.ZERO
	return to.normalized() * speed_scale


func _on_link_reached(details: Dictionary) -> void:
	var link := details.get("owner") as NavigationLink3D
	var entry: Vector3 = details.get("link_entry_position", _bot.global_position)
	var exit: Vector3 = details.get("link_exit_position", _bot.global_position)
	var kind := "drop"
	var lip := entry
	var release_y := 0.0
	if link != null:
		kind = str(link.get_meta(&"traversal", "drop"))
		lip = link.to_global(link.get_meta(&"lip", link.start_position))
		release_y = float(link.get_meta(&"release_y", 0.0))
	_link = {
		"kind": kind,
		"entry": entry,
		"exit": exit,
		"lip": lip,
		"release_y": release_y,
		"t": 0.0,
		"jumped": false,
	}


func _follow_link() -> Vector3:
	_link.t = float(_link.t) + get_physics_process_delta_time()
	var pos := _bot.global_position
	var entry: Vector3 = _link.entry
	var exit: Vector3 = _link.exit
	var to_exit := Vector3(exit.x - pos.x, 0.0, exit.z - pos.z)
	var landed := _bot.is_on_floor() and absf(pos.y - exit.y) < 0.8 and to_exit.length() < 1.5
	if landed or float(_link.t) > LINK_TIMEOUT:
		_link = {}
		_force_repath()
		return Vector3.ZERO
	var dir := to_exit.normalized() if to_exit.length_squared() > 0.0001 else Vector3.ZERO
	match str(_link.kind):
		"lift":
			# Hold over the pad until the lift has carried us above the deck, then step off.
			if pos.y < float(_link.release_y):
				var to_entry := Vector3(entry.x - pos.x, 0.0, entry.z - pos.z)
				return to_entry.limit_length(1.0)
			return dir
		"jump":
			if not _link.jumped:
				var lip: Vector3 = _link.lip
				var along := Vector3(lip.x - pos.x, 0.0, lip.z - pos.z).dot(dir)
				# At the lip, or already running off it (coyote time still allows the jump).
				if along <= LIP_TRIGGER or not _bot.is_on_floor():
					_bot.request_jump()
					_link.jumped = true
			return dir
		_:
			return dir


func _check_stuck(delta: float, wish: Vector3) -> void:
	if wish.length_squared() < 0.04 or state == State.ENGAGE or not _link.is_empty():
		_stuck_origin = _bot.global_position
		_stuck_time = 0.0
		_stuck_jumped = false
		return
	_stuck_time += delta
	if _bot.global_position.distance_to(_stuck_origin) > STUCK_DISTANCE:
		_stuck_origin = _bot.global_position
		_stuck_time = 0.0
		_stuck_jumped = false
		return
	if _stuck_time > STUCK_TIME and not _stuck_jumped:
		_bot.request_jump()
		_stuck_jumped = true
	elif _stuck_time > STUCK_TIME * 2.5:
		_stuck_time = 0.0
		_stuck_jumped = false
		_has_goal = false
		_roam_point = null
		if state != State.ENGAGE:
			state = State.PATROL


# ------------------------------------------------------------------ events


func _on_damaged(_amount: float, info: Dictionary) -> void:
	var source := info.get("source") as Node3D
	if source == null or not is_instance_valid(source) or not ArenaEvents.is_hostile(_bot, source):
		return
	_threat = source
	# Damage reveals the attacker's position (not a sighting: no reaction-delay skip).
	_remember(source, source.global_position, false)
	if state == State.PATROL or state == State.SEEK_PICKUP or state == State.SEARCH:
		if target == null:
			target = source
		_set_search(source.global_position)
		# Turn toward the shot right away.
		var to := source.global_position - _bot.global_position
		_bot.set_aim(Vector3(to.x, 0.0, to.z))


func _on_gunfire(source: Node3D, position: Vector3) -> void:
	if source == _bot or not ArenaEvents.is_hostile(_bot, source) or _bot.dead:
		return
	if _bot.global_position.distance_to(position) > _diff.hearing_radius:
		return
	_remember(source, position, false)
	if state == State.PATROL:
		_set_search(position)


func _on_shield_damaged(_amount: float) -> void:
	var hs := _bot.health_shield
	if hs.shield <= hs.max_shield * _diff.retreat_threshold and hs.shield > 0.0:
		_consider_retreat()


func _on_shield_broken() -> void:
	_consider_retreat()


## One retreat roll per shield pop: a full recharge re-arms it.
func _on_shield_full() -> void:
	_retreat_rolled = false


func _consider_retreat() -> void:
	if _retreat_rolled or state == State.RETREAT or _bot.dead:
		return
	_retreat_rolled = true
	if _rng.randf() >= _diff.retreat_chance:
		return
	var threat := _threat if _threat != null and is_instance_valid(_threat) else target
	if threat == null or not is_instance_valid(threat):
		return
	var cover := _find_cover(threat)
	if cover == Vector3.INF:
		return
	_threat = threat
	state = State.RETREAT
	_has_goal = false
	_set_goal(cover)


## Nearest navmesh point with no line of sight from the threat's eye, or Vector3.INF.
func _find_cover(threat: Node3D) -> Vector3:
	var map := _bot.get_world_3d().navigation_map
	var threat_eye := ArenaEvents.eye_of(threat)
	var origin := _bot.global_position
	var candidates: Array[Vector3] = []
	for node in get_tree().get_nodes_in_group(ROAM_GROUP):
		candidates.append((node as Node3D).global_position)
	for ring: float in [5.0, 9.0]:
		for i in 8:
			var a := TAU * i / 8.0
			candidates.append(origin + Vector3(cos(a), 0.0, sin(a)) * ring)
	var best := Vector3.INF
	var best_d := COVER_SEARCH_RADIUS
	for c in candidates:
		var p := NavigationServer3D.map_get_closest_point(map, c)
		var d := origin.distance_to(p)
		if d > best_d or p.distance_to(threat.global_position) < 6.0:
			continue
		if _has_los(threat_eye, p + Vector3.UP * 1.4):
			continue
		best_d = d
		best = p
	return best
