class_name Weapon
extends Node3D
## Shared hitscan weapon. Driven by WeaponHolder; tuning lives in a WeaponData resource.
## Targets take damage through a duck-typed take_damage(amount: float, info: Dictionary).
## amount is base damage after falloff. Zone and shield multipliers ride in info
## (zone_multiplier, shield_multiplier, bleedthrough) for HealthShield to apply.
## Damageables WITHOUT a HealthShield must apply info.zone_multiplier themselves, or they lose
## the headshot bonus (and should honor shield_multiplier/bleedthrough if they model shields).
## Hit zones come from collider groups: "hitbox_head_unarmored" (face, neck),
## "hitbox_head_armored" (helmet), and legacy "hitbox_head", treated as armored. Anything
## else is body. Shots, the zone probe and the melee sweep hit PhysicsBody3Ds on World (1),
## Enemy (3) or Hitbox (6), and Area3Ds only on Hitbox (6), so triggers, pickups and water
## don't absorb bullets. Put hitbox Areas on layer 6 only.
## Zone colliders forward to the nearest ancestor that has take_damage.
## info carries hit_zone (HitZone), hit_zone_name, and headshot (true for both head zones).
## Audio and VFX: connect to fired, dry_fired, reload_started, melee_started, hit_confirmed.
## Melee animation contract: melee_started(weapon, time_to_hit) fires the frame the swing begins
## (before any reload is cancelled); melee_hit(target, info) fires on the damage tick, the same
## frame take_damage is called; melee_whiffed(weapon) fires on a miss or a lunge that times out
## (or is interrupted by holstering). melee_swung is a legacy alias emitted with melee_started.
## melee_hit_surface(position, normal, collider, info) fires INSTEAD of melee_whiffed when the
## swing connects with non-damageable World geometry within melee_range (in reach, or on lunge
## arrival). time_to_hit is 0 for an in-reach target or wall, the lunge time for a lunge, and
## -1 for a swing with nothing in reach (a pure whiff: animators use their default windup).
## AI / bot hooks (all optional; defaults keep player behaviour):
##   hit_mask_override  int, -1 = HIT_MASK (World, Enemy, Hitbox). Bots shooting the player use
##                      e.g. Weapon.HIT_MASK | Weapon.LAYER_PLAYER. Applies to shots, the zone
##                      probe and the melee sweep.
##   aim_source         Node3D whose global transform is the ray origin and -Z aim direction,
##                      the spread basis and the melee sweep origin. null = the player camera.
##   exclude_bodies     CollisionObject3Ds never hit (the shooter's own body and hitboxes).
##                      The Player, when set, is always excluded.
##   shooter            Node reported as info.source (defaults to player).
##   aim_assist         set by WeaponHolder for the human player only; null is fine.
## A Weapon works without a Player: lunge, recoil-to-view and zoom FOV are holder/player-side
## and simply don't happen. The Player itself is damageable by these rays: it is on layer 2
## (LAYER_PLAYER) with take_damage on the root, and has no zone groups, so hits count as BODY.
## Subclass hooks: _can_fire, _consume_ammo, _emit_shots, _on_trigger_released, _alt_fire, _melee.

signal ammo_changed(magazine: int, reserve: int)
signal fired
signal trigger_released
signal dry_fired
signal reload_started
signal reload_finished
## Ammo transferred at the mag-insert beat (data.reload_insert_fraction of reload_time).
signal reload_inserted
## A reload in progress was interrupted (melee, holster, re-equip). No ammo moved if it fired
## before reload_inserted.
signal reload_cancelled
signal zoom_changed(zoomed: bool)
signal fire_mode_changed(mode: int)
## Legacy alias, emitted right after melee_started.
signal melee_swung
## Swing began. time_to_hit: seconds until the expected damage tick (0 for an in-reach swing,
## a wall in reach, the expected lunge arrival for a lunge, -1 for a whiff with nothing in reach).
signal melee_started(weapon: Weapon, time_to_hit: float)
## Melee damage landed this frame.
signal melee_hit(target: Node, info: Dictionary)
## Swing hit nothing, or a lunge ended without contact.
signal melee_whiffed(weapon: Weapon)
## Swing hit World geometry with no damageable in front of it. info: melee, surface (the
## collider's "surface" metadata, else its physics material's resource_name, else ""),
## weapon, source, direction.
signal melee_hit_surface(position: Vector3, normal: Vector3, collider: Object, info: Dictionary)
signal hit_confirmed(target: Object, info: Dictionary)

enum HitZone { BODY, HEAD_ARMORED, HEAD_UNARMORED }

const LAYER_HITBOX := 1 << 5
const HIT_MASK := 1 | 4 | LAYER_HITBOX
const LAYER_PLAYER := 1 << 1
## Non-hitbox Areas a single ray may skip before giving up.
const MAX_AREA_SKIPS := 8
## The visor probe only upgrades shots within ~45 degrees of straight into the face:
## dot(shot_dir, -face_forward) must exceed this. Face forward is the unarmored collider's -Z.
const ZONE_PROBE_MIN_FACING := 0.7
## How far past a non-unarmored hit to probe for an overlapping unarmored collider.
const ZONE_PROBE := 0.05
const ZONE_NAMES := ["body", "head_armored", "head_unarmored"]
## Shared hit-marker palette for HUD and damage numbers.
const ZONE_COLORS := [Color(1.0, 0.3, 0.25), Color(1.0, 0.72, 0.15), Color(1.0, 0.3, 1.0)]

## Max shots one physics tick may fire, so a long hitch can't dump a magazine.
const MAX_SHOTS_PER_TICK := 4
const MELEE_RADIUS := 0.3

@export var data: WeaponData

var magazine: int = 0
var reserve: int = 0
var zoomed: bool = false
var reloading: bool = false
## True when the current reload started from an empty magazine (empty vs tactical reload).
var reload_empty: bool = false
## Current fire mode; differs from data.fire_mode while a TOGGLE_MODE alt mode is active.
var fire_mode: int = WeaponData.FireMode.SEMI
var alt_mode: bool = false
## Set by WeaponHolder.
var camera: Camera3D
var player: Player
## Set by WeaponHolder; null = no bullet bend.
var aim_assist: AimAssist
## AI hooks, see the header.
var hit_mask_override: int = -1
var aim_source: Node3D
var exclude_bodies: Array[CollisionObject3D] = []
var shooter: Node

var _cooldown: float = 0.0
var _equip_left: float = 0.0
var _reload_left: float = 0.0
## Set once the current reload has transferred ammo, so it can never refill twice.
var _reload_refilled: bool = false
var _melee_target: Object = null
var _melee_time_to_hit: float = 0.0
## Nearest World blocker from the last _melee_sweep ({} = none): position, normal, collider.
var _melee_surface: Dictionary = {}
var _melee_cast: ShapeCast3D
var _trigger_buffer_left: float = 0.0
var _trigger_held: bool = false
var _burst_left: int = 0
var _bloom: float = 0.0
var _recoil: Vector2 = Vector2.ZERO


func _ready() -> void:
	if data == null:
		push_error("%s has no WeaponData" % name)
		set_physics_process(false)
		return
	magazine = data.magazine_size
	_melee_cast = ShapeCast3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = MELEE_RADIUS
	_melee_cast.shape = sphere
	_melee_cast.enabled = false
	_melee_cast.top_level = true
	_melee_cast.collision_mask = HIT_MASK
	_melee_cast.collide_with_areas = true
	add_child(_melee_cast)
	reserve = mini(data.reserve_start, data.reserve_max)
	fire_mode = data.fire_mode


func equip() -> void:
	visible = true
	if data == null:
		return
	_equip_left = data.equip_time
	_cancel_reload()
	set_zoom(false)
	ammo_changed.emit(magazine, reserve)
	fire_mode_changed.emit(fire_mode)


func holster() -> void:
	visible = false
	_cancel_reload()
	_trigger_buffer_left = 0.0
	_burst_left = 0
	if _melee_target != null:
		_melee_target = null
		melee_whiffed.emit(self)
	if player != null:
		player.cancel_lunge()
	release_trigger()
	set_zoom(false)
	_clear_recoil()


## pressed: trigger went down this frame. held: trigger is down.
func trigger(pressed: bool, held: bool) -> void:
	if data == null:
		return
	_trigger_held = held
	if fire_mode == WeaponData.FireMode.AUTO:
		var shots := 0
		while held and shots < MAX_SHOTS_PER_TICK and _try_fire():
			shots += 1
		return
	if pressed:
		_trigger_buffer_left = data.trigger_buffer
		_fire_press()


## Trigger came up. Burst and charge weapons hook _on_trigger_released.
func release_trigger() -> void:
	if not _trigger_held:
		return
	_trigger_held = false
	trigger_released.emit()
	_on_trigger_released()


## Adds to reserve, capped at reserve_max. Returns how much was taken.
func add_ammo(amount: int) -> int:
	if data == null or amount <= 0:
		return 0
	var taken := mini(amount, data.reserve_max - reserve)
	if taken <= 0:
		return 0
	reserve += taken
	ammo_changed.emit(magazine, reserve)
	return taken


func secondary_pressed() -> void:
	if data == null:
		return
	match data.secondary:
		WeaponData.Secondary.ZOOM:
			if not reloading:
				set_zoom(not zoomed)  # set_zoom refuses zoom in a disallowed mode
		WeaponData.Secondary.ALT:
			_alt_fire()
		WeaponData.Secondary.TOGGLE_MODE:
			toggle_fire_mode()


## action_fire_select. Only weapons with data.fire_select (or a TOGGLE_MODE secondary).
func fire_select() -> void:
	if data == null:
		return
	if data.fire_select or data.secondary == WeaponData.Secondary.TOGGLE_MODE:
		toggle_fire_mode()


## Switch between data.fire_mode and data.alt_fire_mode. Not mid-burst.
func toggle_fire_mode() -> void:
	if data == null or _burst_left > 0:
		return
	alt_mode = not alt_mode
	fire_mode = data.alt_fire_mode if alt_mode else data.fire_mode
	_trigger_buffer_left = 0.0
	release_trigger()
	if zoomed and not can_zoom():
		set_zoom(false)
	fire_mode_changed.emit(fire_mode)


## Zoom is allowed in the current fire mode.
func can_zoom() -> bool:
	if data == null or data.secondary != WeaponData.Secondary.ZOOM:
		return false
	return data.zoom_only_in_mode < 0 or fire_mode == data.zoom_only_in_mode


## FOV while zoomed, given the unzoomed base FOV in degrees.
func get_zoom_fov(base_fov: float) -> float:
	if data == null:
		return base_fov
	if data.zoom_magnification > 0.0:
		var half := deg_to_rad(base_fov * 0.5)
		return rad_to_deg(2.0 * atan(tan(half) / data.zoom_magnification))
	return data.zoom_fov


func get_fire_mode_name() -> String:
	return WeaponData.FireMode.keys()[fire_mode]


func reload() -> void:
	if (
		data == null
		or reloading
		or _burst_left > 0
		or magazine >= data.magazine_size
		or reserve <= 0
	):
		return
	reloading = true
	reload_empty = magazine <= 0
	_reload_refilled = false
	_reload_left = data.reload_time
	set_zoom(false)
	reload_started.emit()


## Cooldown is owned by WeaponHolder so switching weapons can't skip it.
## Timing (unchanged from a5e85f3): an in-reach hit lands the same frame (0 s); a lunge lands
## on arrival, (distance - melee_range) / melee_lunge_speed, within a lunge window of that
## + 0.1 s; firing is blocked for 0.25 s; the holder's cooldown is data.melee_cooldown.
func melee() -> void:
	if data == null or _aim() == null:
		return
	# Plan first (read-only sweep) so melee_started can report time_to_hit before any state
	# changes, including the reload cancel.
	var hit := _melee_sweep(data.melee_lunge_range)
	_melee_time_to_hit = _melee_time_for(hit)
	melee_started.emit(self, _melee_time_to_hit)
	melee_swung.emit()
	# Melee cancels a reload and any burst in progress, Halo style.
	_cancel_reload()
	_burst_left = 0
	set_zoom(false)
	_cooldown = maxf(_cooldown, 0.25)
	_melee(hit)


## Seconds from the last melee_started to its expected damage tick.
func get_melee_time_to_hit() -> float:
	return _melee_time_to_hit


func _melee_time_for(hit: Dictionary) -> float:
	if hit.is_empty():
		return 0.0 if _surface_in_reach() else -1.0
	if player == null:
		return 0.0
	var distance: float = _aim().global_position.distance_to(hit.position)
	if distance <= data.melee_range:
		return 0.0
	return (distance - data.melee_range) / data.melee_lunge_speed


func set_zoom(on: bool) -> void:
	if on == zoomed or (on and not can_zoom()):
		return
	zoomed = on
	zoom_changed.emit(zoomed)


## Current cone half-angle in degrees, for the crosshair.
func get_spread() -> float:
	if data == null:
		return 0.0
	var spread := data.spread_base + _bloom
	if player != null and not player.is_on_floor():
		spread += data.spread_air_add
	if zoomed:
		spread *= data.zoom_spread_multiplier
	if alt_mode:
		spread *= data.alt_spread_multiplier
	return spread


func is_ready_to_fire() -> bool:
	return data != null and _cooldown <= 0.0 and _equip_left <= 0.0 and not reloading


func _physics_process(delta: float) -> void:
	if not visible or data == null:
		return
	# Carry at most one tick of remainder so fire rate holds at any tick rate without
	# banking shots while idle.
	_cooldown = maxf(_cooldown - delta, -delta)
	_equip_left = maxf(_equip_left - delta, 0.0)
	_tick_melee()
	_bloom = maxf(_bloom - data.bloom_recovery * delta, 0.0)
	if reloading:
		_reload_left -= delta
		var insert_left := data.reload_time * (1.0 - data.reload_insert_fraction)
		if not _reload_refilled and _reload_left <= insert_left:
			_insert_magazine()
		if _reload_left <= 0.0:
			_finish_reload()
	if _burst_left > 0:
		_continue_burst()
	elif _trigger_buffer_left > 0.0:
		_trigger_buffer_left -= delta
		_fire_press()
	_update_recoil(delta)


## One press: a single semi shot, or the start of a burst.
func _fire_press() -> void:
	if fire_mode != WeaponData.FireMode.BURST:
		_try_fire()
		return
	if _burst_left > 0 or not _can_fire():
		return
	_trigger_buffer_left = 0.0
	_burst_left = maxi(data.burst_count, 1)
	_continue_burst()


## Fires due burst rounds. Spacing rides the same cooldown accumulator as other modes, so it
## holds at any tick rate. An empty magazine ends the burst early.
func _continue_burst() -> void:
	var shots := 0
	while _burst_left > 0 and shots < MAX_SHOTS_PER_TICK and _can_fire():
		var last := _burst_left == 1
		var interval := data.burst_cooldown if last else data.burst_interval
		shots += 1
		if not _try_fire(interval):
			_burst_left = 0
			return
		_burst_left -= 1


## Returns true if a shot went out. interval < 0 means 1 / fire_rate.
func _try_fire(interval: float = -1.0) -> bool:
	if not _can_fire():
		return false
	if interval < 0.0:
		interval = 1.0 / data.fire_rate
	_trigger_buffer_left = 0.0
	_cooldown += interval
	if not _consume_ammo():
		_cooldown = maxf(_cooldown, interval)
		dry_fired.emit()
		# End any burst first so the mid-burst reload guard doesn't block the auto-reload.
		_burst_left = 0
		reload()
		return false
	_emit_shots()
	var bloom_add := data.bloom_per_shot * (data.alt_bloom_multiplier if alt_mode else 1.0)
	_bloom = minf(_bloom + bloom_add, data.spread_max - data.spread_base)
	_kick()
	fired.emit()
	ammo_changed.emit(magazine, reserve)
	return true


## Override to add charge, heat, or battery gates.
func _can_fire() -> bool:
	return is_ready_to_fire() and _aim() != null


## Override for batteries or multi-round shots. Return false when empty.
func _consume_ammo() -> bool:
	if magazine <= 0:
		return false
	magazine -= 1
	return true


## Override for pellets or bursts. Default: one hitscan ray through the spread cone.
func _emit_shots() -> void:
	_fire_ray(_assisted_direction(_spread_direction(get_spread())))


## Bullet bend: only rays that wouldn't already hit something damageable get bent.
func _assisted_direction(direction: Vector3) -> Vector3:
	if aim_assist == null:
		return direction
	var hit := _raycast(direction, data.max_range)
	if not hit.is_empty() and _damage_receiver(hit.collider) != null:
		return direction
	return aim_assist.bend(direction, data)


## Override for burst and charge weapons.
func _on_trigger_released() -> void:
	pass


## Override for weapons with an alternate fire mode.
func _alt_fire() -> void:
	pass


## Override for weapon-specific melee. hit is the sweep out to melee_lunge_range ({} = none).
## Default: a target in melee_range is hit now; a farther one starts a player lunge and is hit
## on arrival. Overrides must emit melee_hit / melee_whiffed (see _apply_melee).
func _melee(hit: Dictionary) -> void:
	_melee_target = null
	if hit.is_empty():
		_whiff_or_surface()
		return
	var distance: float = _aim().global_position.distance_to(hit.position)
	if distance <= data.melee_range:
		_apply_melee(hit)
	elif player != null:
		var forward := -_aim().global_transform.basis.z
		var duration := (distance - data.melee_range) / data.melee_lunge_speed + 0.1
		player.start_lunge(forward, data.melee_lunge_speed, duration)
		_melee_target = hit.target
	else:
		melee_whiffed.emit(self)


func _tick_melee() -> void:
	if _melee_target == null:
		return
	if not is_instance_valid(_melee_target) or player == null:
		_melee_target = null
		melee_whiffed.emit(self)
		return
	var hit := _melee_sweep(data.melee_range)
	if not hit.is_empty() and hit.target == _melee_target:
		player.cancel_lunge()
		_melee_target = null
		_apply_melee(hit)
	elif not player.is_lunging():
		_melee_target = null
		_whiff_or_surface()


## Nearest damageable hit along the camera's forward within distance, or {}. Also used on
## lunge arrival, so a wall that appears mid-lunge still blocks.
func _melee_sweep(distance: float) -> Dictionary:
	_melee_cast.global_transform = _aim().global_transform
	_melee_cast.target_position = Vector3(0.0, 0.0, -distance)
	_melee_cast.collision_mask = get_hit_mask()
	_melee_cast.clear_exceptions()
	for rid in _excluded_rids():
		_melee_cast.add_exception_rid(rid)
	_melee_cast.force_shapecast_update()
	var best := {}
	var best_distance := INF
	# The nearest non-damageable solid blocks, so melee can't reach through walls.
	var block_distance := INF
	_melee_surface = {}
	for i in _melee_cast.get_collision_count():
		var collider := _melee_cast.get_collider(i)
		if _is_ignored_area(collider):
			continue
		var point := _melee_cast.get_collision_point(i)
		var d := _aim().global_position.distance_to(point)
		if _damage_receiver(collider) == null and d < block_distance:
			block_distance = d
			_melee_surface = {
				"collider": collider,
				"position": point,
				"normal": _melee_cast.get_collision_normal(i),
				"distance": d,
			}
	for i in _melee_cast.get_collision_count():
		var collider := _melee_cast.get_collider(i)
		if _is_ignored_area(collider):
			continue
		var target := _damage_receiver(collider)
		if target == null:
			continue
		var point := _melee_cast.get_collision_point(i)
		var d := _aim().global_position.distance_to(point)
		if d < best_distance and d <= block_distance:
			best_distance = d
			best = {
				"target": target,
				"collider": collider,
				"position": point,
				"normal": _melee_cast.get_collision_normal(i),
			}
	return best


## Last sweep's blocker is World geometry (a body on layer 1) within melee_range.
func _surface_in_reach() -> bool:
	if _melee_surface.is_empty() or data == null:
		return false
	var body := _melee_surface.collider as PhysicsBody3D
	if body == null or not is_instance_valid(body) or (body.collision_layer & 1) == 0:
		return false
	return _melee_surface.distance <= data.melee_range


func _whiff_or_surface() -> void:
	if not _surface_in_reach():
		melee_whiffed.emit(self)
		return
	var collider: Object = _melee_surface.collider
	var info := {
		"melee": true,
		"surface": _surface_hint(collider),
		"direction": -_aim().global_transform.basis.z,
		"weapon": data.display_name,
		"source": shooter if shooter != null else player,
	}
	melee_hit_surface.emit(_melee_surface.position, _melee_surface.normal, collider, info)


static func _surface_hint(collider: Object) -> String:
	if collider == null:
		return ""
	if collider.has_meta(&"surface"):
		return str(collider.get_meta(&"surface"))
	var material: PhysicsMaterial = null
	if collider is StaticBody3D:
		material = (collider as StaticBody3D).physics_material_override
	elif collider is RigidBody3D:
		material = (collider as RigidBody3D).physics_material_override
	return material.resource_name if material != null else ""


func _apply_melee(hit: Dictionary) -> void:
	var forward := -_aim().global_transform.basis.z
	var info := _hit_info(hit, forward, HitZone.BODY)
	info["melee"] = true
	info["zone_multiplier"] = 1.0
	info["shield_multiplier"] = data.melee_shield_damage_multiplier
	info["bleedthrough"] = data.melee_bleedthrough
	hit.target.take_damage(data.melee_damage, info)
	melee_hit.emit(hit.target as Node, info)
	hit_confirmed.emit(hit.target, info)


func _fire_ray(direction: Vector3) -> void:
	var hit := _raycast(direction, data.max_range)
	if hit.is_empty():
		return
	var target := _damage_receiver(hit.collider)
	if target == null:
		return
	var zone := _resolve_zone(hit, direction, target)
	var distance: float = _aim().global_position.distance_to(hit.position)
	var amount := data.damage * _falloff(distance)
	var zone_multiplier := 1.0
	match zone:
		HitZone.HEAD_ARMORED:
			zone_multiplier = data.headshot_armored_multiplier
		HitZone.HEAD_UNARMORED:
			zone_multiplier = data.headshot_unarmored_multiplier
	var info := _hit_info(hit, direction, zone)
	info["zone_multiplier"] = zone_multiplier
	info["shield_multiplier"] = data.shield_damage_multiplier
	info["bleedthrough"] = data.bleedthrough
	target.take_damage(amount, info)
	hit_confirmed.emit(target, info)


static func zone_of(collider: Object) -> HitZone:
	var node := collider as Node
	if node == null:
		return HitZone.BODY
	if node.is_in_group("hitbox_head_unarmored"):
		return HitZone.HEAD_UNARMORED
	if node.is_in_group("hitbox_head_armored") or node.is_in_group("hitbox_head"):
		return HitZone.HEAD_ARMORED
	return HitZone.BODY


static func zone_color(zone: int) -> Color:
	return ZONE_COLORS[clampi(zone, 0, ZONE_COLORS.size() - 1)]


## Unarmored wins over overlap: if the first hit isn't unarmored, probe a few cm further
## (from inside shapes too) for an unarmored collider on the same target, but only for shots
## roughly head-on to that collider's face (its -Z).
func _resolve_zone(hit: Dictionary, direction: Vector3, target: Object) -> HitZone:
	var zone := zone_of(hit.collider)
	if zone == HitZone.HEAD_UNARMORED:
		return zone
	var origin: Vector3 = hit.position
	var exclude: Array[RID] = [(hit.collider as CollisionObject3D).get_rid()]
	var probe := _cast_ray(origin, origin + direction * ZONE_PROBE, exclude, true)
	if probe.is_empty() or zone_of(probe.collider) != HitZone.HEAD_UNARMORED:
		return zone
	if _damage_receiver(probe.collider) != target:
		return zone
	# Steep shots skimming the helmet edge or neck must not get upgraded.
	var face_forward := -(probe.collider as Node3D).global_basis.z
	if direction.dot(-face_forward) <= ZONE_PROBE_MIN_FACING:
		return zone
	hit.collider = probe.collider
	return HitZone.HEAD_UNARMORED


func _raycast(direction: Vector3, distance: float) -> Dictionary:
	var origin := _aim().global_position
	return _cast_ray(origin, origin + direction * distance, [], false)


## Ray against HIT_MASK that passes through Areas not on the Hitbox layer.
func _cast_ray(from: Vector3, to: Vector3, exclude: Array[RID], from_inside: bool) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, get_hit_mask())
	query.collide_with_areas = true
	query.hit_from_inside = from_inside
	var skip: Array[RID] = exclude.duplicate()
	skip.append_array(_excluded_rids())
	var space := get_world_3d().direct_space_state
	for _i in MAX_AREA_SKIPS:
		query.exclude = skip
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not _is_ignored_area(hit.collider):
			return hit
		skip.append(hit.rid)
	return {}


func get_hit_mask() -> int:
	return hit_mask_override if hit_mask_override >= 0 else HIT_MASK


## Ray origin and aim basis: aim_source if set, else the player camera.
func _aim() -> Node3D:
	if is_instance_valid(aim_source):
		return aim_source
	return camera


func _excluded_rids() -> Array[RID]:
	var rids: Array[RID] = []
	if player != null:
		rids.append(player.get_rid())
	for body in exclude_bodies:
		if is_instance_valid(body):
			rids.append(body.get_rid())
	return rids


static func _is_ignored_area(collider: Object) -> bool:
	var area := collider as Area3D
	return area != null and (area.collision_layer & LAYER_HITBOX) == 0


func _damage_receiver(collider: Object) -> Object:
	var node := collider as Node
	while node != null:
		if node.has_method("take_damage"):
			return node
		node = node.get_parent()
	return null


func _hit_info(hit: Dictionary, direction: Vector3, zone: HitZone) -> Dictionary:
	return {
		"position": hit.position,
		"normal": hit.normal,
		"direction": direction,
		"hit_zone": zone,
		"hit_zone_name": ZONE_NAMES[zone],
		"headshot": zone != HitZone.BODY,
		"weapon": data.display_name,
		"source": shooter if shooter != null else player,
	}


func _falloff(distance: float) -> float:
	var start := data.falloff_start
	var end := data.falloff_end
	var floor_mult := data.min_damage_multiplier
	if alt_mode and data.alt_falloff_start >= 0.0 and data.alt_falloff_end > data.alt_falloff_start:
		start = data.alt_falloff_start
		end = data.alt_falloff_end
	if alt_mode and data.alt_min_damage_multiplier >= 0.0:
		floor_mult = data.alt_min_damage_multiplier
	if distance <= start:
		return 1.0
	var t := clampf(inverse_lerp(start, end, distance), 0.0, 1.0)
	return lerpf(1.0, floor_mult, t)


func _spread_direction(spread_degrees: float) -> Vector3:
	var basis := _aim().global_transform.basis
	# sqrt keeps the distribution even across the cone's area.
	var radius := tan(deg_to_rad(spread_degrees)) * sqrt(randf())
	var angle := randf() * TAU
	var local := Vector3(cos(angle) * radius, sin(angle) * radius, -1.0)
	return (basis * local).normalized()


func _finish_reload() -> void:
	if not _reload_refilled:
		_insert_magazine()
	reloading = false
	reload_finished.emit()


## The mag-insert beat: moves ammo from reserve once per reload.
func _insert_magazine() -> void:
	if _reload_refilled:
		return
	_reload_refilled = true
	var taken := mini(data.magazine_size - magazine, reserve)
	magazine += taken
	reserve -= taken
	reload_inserted.emit()
	ammo_changed.emit(magazine, reserve)


## Stops a reload in progress. Ammo already inserted stays; otherwise nothing moves.
func _cancel_reload() -> void:
	if not reloading:
		return
	reloading = false
	_reload_refilled = false
	reload_cancelled.emit()


## Additive view kick in degrees (pitch up), recovered like recoil. Used by reload animations.
func add_view_kick(pitch_deg: float) -> void:
	_recoil.x += deg_to_rad(pitch_deg)


func _kick() -> void:
	_recoil.x += deg_to_rad(data.recoil_pitch)
	_recoil.y += deg_to_rad(randf_range(-data.recoil_yaw, data.recoil_yaw))


func _update_recoil(delta: float) -> void:
	_recoil = _recoil.lerp(Vector2.ZERO, 1.0 - exp(-data.recoil_recovery * delta))


## Current recoil as a (pitch, yaw) view offset in radians. The player applies it.
func get_recoil() -> Vector2:
	return _recoil


func _clear_recoil() -> void:
	_recoil = Vector2.ZERO
