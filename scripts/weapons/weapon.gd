class_name Weapon
extends Node3D
## Shared hitscan weapon. Driven by WeaponHolder; tuning lives in a WeaponData resource.
## Targets take damage through a duck-typed take_damage(amount: float, info: Dictionary).
## Hit zones come from collider groups: "hitbox_head_unarmored" (face, neck),
## "hitbox_head_armored" (helmet), and legacy "hitbox_head", treated as armored. Anything
## else is body. Zone colliders forward to the nearest ancestor that has take_damage.
## info carries hit_zone (HitZone), hit_zone_name, and headshot (true for both head zones).
## Audio and VFX: connect to fired, dry_fired, reload_started, melee_swung, hit_confirmed.

signal ammo_changed(magazine: int, reserve: int)
signal fired
signal dry_fired
signal reload_started
signal reload_finished
signal zoom_changed(zoomed: bool)
signal melee_swung
signal hit_confirmed(target: Object, info: Dictionary)

enum HitZone { BODY, HEAD_ARMORED, HEAD_UNARMORED }

const HIT_MASK := 1 | 4
## How far past a non-unarmored hit to probe for an overlapping unarmored collider.
const ZONE_PROBE := 0.05
const ZONE_NAMES := ["body", "head_armored", "head_unarmored"]
## Shared hit-marker palette for HUD and damage numbers.
const ZONE_COLORS := [Color(1.0, 0.3, 0.25), Color(1.0, 0.72, 0.15), Color(1.0, 0.3, 1.0)]

@export var data: WeaponData

var magazine: int = 0
var reserve: int = 0
var zoomed: bool = false
var reloading: bool = false
## Set by WeaponHolder.
var camera: Camera3D
var player: CharacterBody3D

var _cooldown: float = 0.0
var _equip_left: float = 0.0
var _reload_left: float = 0.0
var _melee_left: float = 0.0
var _trigger_buffer_left: float = 0.0
var _bloom: float = 0.0
var _recoil: Vector2 = Vector2.ZERO


func _ready() -> void:
	if data == null:
		push_error("%s has no WeaponData" % name)
		set_physics_process(false)
		return
	magazine = data.magazine_size
	reserve = data.reserve_start


func equip() -> void:
	visible = true
	_equip_left = data.equip_time
	reloading = false
	set_zoom(false)
	ammo_changed.emit(magazine, reserve)


func holster() -> void:
	visible = false
	reloading = false
	_trigger_buffer_left = 0.0
	set_zoom(false)
	_clear_recoil()


## pressed: trigger went down this frame. held: trigger is down.
func trigger(pressed: bool, held: bool) -> void:
	if data.fire_mode == WeaponData.FireMode.AUTO:
		if held:
			_try_fire()
		return
	if pressed:
		_trigger_buffer_left = data.trigger_buffer
		_try_fire()


func secondary_pressed() -> void:
	match data.secondary:
		WeaponData.Secondary.ZOOM:
			if not reloading:
				set_zoom(not zoomed)
		WeaponData.Secondary.ALT:
			_alt_fire()


func reload() -> void:
	if reloading or magazine >= data.magazine_size or reserve <= 0:
		return
	reloading = true
	_reload_left = data.reload_time
	set_zoom(false)
	reload_started.emit()


func melee() -> void:
	if _melee_left > 0.0 or camera == null:
		return
	_melee_left = data.melee_cooldown
	# Melee cancels a reload, Halo style.
	reloading = false
	set_zoom(false)
	_cooldown = maxf(_cooldown, 0.25)
	melee_swung.emit()
	_melee()


func set_zoom(on: bool) -> void:
	if on == zoomed:
		return
	zoomed = on
	zoom_changed.emit(zoomed)


## Current cone half-angle in degrees, for the crosshair.
func get_spread() -> float:
	var spread := data.spread_base + _bloom
	if player != null and not player.is_on_floor():
		spread += data.spread_air_add
	if zoomed:
		spread *= data.zoom_spread_multiplier
	return spread


func is_ready_to_fire() -> bool:
	return _cooldown <= 0.0 and _equip_left <= 0.0 and not reloading


func _physics_process(delta: float) -> void:
	if not visible:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	_equip_left = maxf(_equip_left - delta, 0.0)
	_melee_left = maxf(_melee_left - delta, 0.0)
	_bloom = maxf(_bloom - data.bloom_recovery * delta, 0.0)
	if reloading:
		_reload_left -= delta
		if _reload_left <= 0.0:
			_finish_reload()
	if _trigger_buffer_left > 0.0:
		_trigger_buffer_left -= delta
		_try_fire()
	_update_recoil(delta)


func _try_fire() -> void:
	if not is_ready_to_fire() or camera == null:
		return
	_trigger_buffer_left = 0.0
	if magazine <= 0:
		_cooldown = 1.0 / data.fire_rate
		dry_fired.emit()
		reload()
		return
	magazine -= 1
	_cooldown = 1.0 / data.fire_rate
	_fire_ray(_spread_direction(get_spread()))
	_bloom = minf(_bloom + data.bloom_per_shot, data.spread_max - data.spread_base)
	_kick()
	fired.emit()
	ammo_changed.emit(magazine, reserve)


## Override for weapons with an alternate fire mode.
func _alt_fire() -> void:
	pass


## Override for weapon-specific melee. Default: short ray with a lunge toward a target in reach.
func _melee() -> void:
	var forward := -camera.global_transform.basis.z
	var hit := _raycast(forward, data.melee_lunge_range)
	if hit.is_empty():
		return
	var target := _damage_receiver(hit.collider)
	if target == null:
		return
	var distance: float = camera.global_position.distance_to(hit.position)
	if distance > data.melee_range and player != null:
		var flat := Vector3(forward.x, 0.0, forward.z).normalized()
		player.velocity.x = flat.x * data.melee_lunge_speed
		player.velocity.z = flat.z * data.melee_lunge_speed
	var info := _hit_info(hit, forward, HitZone.BODY)
	info["melee"] = true
	target.take_damage(data.melee_damage, info)
	hit_confirmed.emit(target, info)


func _fire_ray(direction: Vector3) -> void:
	var hit := _raycast(direction, data.max_range)
	if hit.is_empty():
		return
	var target := _damage_receiver(hit.collider)
	if target == null:
		return
	var zone := _resolve_zone(hit, direction, target)
	var distance: float = camera.global_position.distance_to(hit.position)
	var amount := data.damage * _falloff(distance)
	match zone:
		HitZone.HEAD_ARMORED:
			amount *= data.headshot_armored_multiplier
		HitZone.HEAD_UNARMORED:
			amount *= data.headshot_unarmored_multiplier
	var info := _hit_info(hit, direction, zone)
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
## (from inside shapes too) for an unarmored collider on the same target.
func _resolve_zone(hit: Dictionary, direction: Vector3, target: Object) -> HitZone:
	var zone := zone_of(hit.collider)
	if zone == HitZone.HEAD_UNARMORED:
		return zone
	var origin: Vector3 = hit.position
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * ZONE_PROBE, HIT_MASK
	)
	query.hit_from_inside = true
	var exclude: Array[RID] = [(hit.collider as CollisionObject3D).get_rid()]
	if player != null:
		exclude.append(player.get_rid())
	query.exclude = exclude
	var probe := get_world_3d().direct_space_state.intersect_ray(query)
	if probe.is_empty() or zone_of(probe.collider) != HitZone.HEAD_UNARMORED:
		return zone
	if _damage_receiver(probe.collider) != target:
		return zone
	hit.collider = probe.collider
	return HitZone.HEAD_UNARMORED


func _raycast(direction: Vector3, distance: float) -> Dictionary:
	var origin := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * distance, HIT_MASK)
	if player != null:
		query.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)


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
		"source": player,
	}


func _falloff(distance: float) -> float:
	if distance <= data.falloff_start:
		return 1.0
	var t := clampf(inverse_lerp(data.falloff_start, data.falloff_end, distance), 0.0, 1.0)
	return lerpf(1.0, data.min_damage_multiplier, t)


func _spread_direction(spread_degrees: float) -> Vector3:
	var basis := camera.global_transform.basis
	# sqrt keeps the distribution even across the cone's area.
	var radius := tan(deg_to_rad(spread_degrees)) * sqrt(randf())
	var angle := randf() * TAU
	var local := Vector3(cos(angle) * radius, sin(angle) * radius, -1.0)
	return (basis * local).normalized()


func _finish_reload() -> void:
	reloading = false
	var taken := mini(data.magazine_size - magazine, reserve)
	magazine += taken
	reserve -= taken
	reload_finished.emit()
	ammo_changed.emit(magazine, reserve)


func _kick() -> void:
	_recoil.x += deg_to_rad(data.recoil_pitch)
	_recoil.y += deg_to_rad(randf_range(-data.recoil_yaw, data.recoil_yaw))


func _update_recoil(delta: float) -> void:
	if camera == null:
		return
	_recoil = _recoil.lerp(Vector2.ZERO, 1.0 - exp(-data.recoil_recovery * delta))
	camera.rotation.x = _recoil.x
	camera.rotation.y = _recoil.y


func _clear_recoil() -> void:
	_recoil = Vector2.ZERO
	if camera != null:
		camera.rotation = Vector3.ZERO
