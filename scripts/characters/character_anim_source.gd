class_name CharacterAnimSource
extends Node
## Fills a CharacterAnimState from a gameplay body (Player, Bot, dummy) without that body
## knowing about animation: it reads duck-typed getters and listens to existing signals,
## all behind has_method / has_signal / property checks. Then it hands the state to a
## CharacterAnimDriver each physics tick.
##
## Authority / local bodies: leave `enabled` on. Remote proxies: disable this node and call
## driver.apply_state(CharacterAnimState.from_dict(snapshot)) instead; `state` (or
## state.to_dict()) is what the authority replicates.
##
## Body contract, first match wins (all optional):
##   velocity             CharacterBody3D.velocity or a `velocity` property
##   on floor             is_on_floor()
##   yaw                  global_rotation.y of the body
##   aim pitch            get_aim_pitch(), else $Head.rotation.x
##   crouched             is_crouching(), else `crouched`
##   sliding              is_sliding(), else `sliding`
##   dead                 is_dead(), else `dead`, else DummyCore child's `dead`
##   active weapon        get_active_weapon(), get_weapon_holder().get_active(), get_active()
##   holstered weapon     get_other(), else the holder's other slot
##   signals              damaged(amount, info), died(..., info), respawned(...),
##                        active_weapon_changed / weapon_changed on body or holder
##   weapon signals       fired, reload_started, reload_cancelled, melee_started (else
##                        melee_swung); weapon.data: anim_type, reload_time, equip_time,
##                        melee_cooldown; weapon.magazine (0 at reload start = empty reload)
##   damage info          info.dir (world, shooter -> victim), info.impulse (optional)

## Emitted after state is refreshed each tick (before the driver gets it), for replication.
signal state_updated(state: CharacterAnimState)

## The gameplay body. Default: two levels up (Body/PlayerModel/CharacterAnimSource).
@export var body_path: NodePath = ^"../.."
@export var driver: CharacterAnimDriver
@export var enabled: bool = true
## Fallback switch duration when weapon data has no equip_time, seconds.
@export var default_switch_time: float = 0.35

var state := CharacterAnimState.new()

var _body: Node3D
var _weapon: Object
var _melee_frame: int = -1


func _ready() -> void:
	_body = get_node_or_null(body_path) as Node3D
	if _body == null:
		push_warning("%s: no body at %s" % [name, body_path])
		return
	_connect(_body, &"damaged", _on_damaged)
	_connect(_body, &"died", _on_died)
	_connect(_body, &"respawned", _on_respawned)
	_connect(_body, &"weapon_changed", _on_weapon_changed)
	_connect(_body, &"active_weapon_changed", _on_weapon_changed)
	var holder := _holder()
	if holder != null:
		_connect(holder, &"active_weapon_changed", _on_weapon_changed)
	# Weapons are often given after _ready; start on the next frame.
	_sync_weapon.call_deferred(false)
	if driver != null:
		driver.reset_baseline()


func _physics_process(_delta: float) -> void:
	if not enabled or _body == null:
		return
	_sample()
	state_updated.emit(state)
	if driver != null:
		driver.apply_state(state)


## Call on spawn, respawn and late join.
func reset_baseline() -> void:
	if driver != null:
		driver.reset_baseline()


func _sample() -> void:
	var vel: Variant = _body.get(&"velocity")
	state.velocity = vel if vel is Vector3 else Vector3.ZERO
	state.on_floor = _body.call(&"is_on_floor") if _body.has_method(&"is_on_floor") else true
	state.yaw = _body.global_rotation.y
	state.aim_pitch = _aim_pitch()
	state.crouched = _flag(&"is_crouching", &"crouched")
	state.sliding = _flag(&"is_sliding", &"sliding")
	var dead := _flag(&"is_dead", &"dead")
	if not dead:
		var core := _body.get_node_or_null(^"DummyCore")
		dead = core != null and core.get(&"dead") == true
	if dead != state.dead:
		if not _body.has_signal(&"died"):
			# No died signal to carry the hit direction: count the death here.
			if dead:
				state.death_seq = CharacterAnimState.bump(state.death_seq)
			state.dead = dead
		elif not dead:
			state.dead = false  # respawned without a respawned signal
	# Weapon changes not announced by a signal (pickups, loadout resets).
	if _active_weapon() != _weapon:
		_sync_weapon(true)
	state.holster_type = _type_of(_other_weapon())


func _aim_pitch() -> float:
	if _body.has_method(&"get_aim_pitch"):
		return _body.call(&"get_aim_pitch")
	var head := _body.get_node_or_null(^"Head") as Node3D
	return head.rotation.x if head != null else 0.0


func _flag(method: StringName, property: StringName) -> bool:
	if _body.has_method(method):
		return _body.call(method) == true
	return _body.get(property) == true


func _holder() -> Node:
	if _body.has_method(&"get_weapon_holder"):
		return _body.call(&"get_weapon_holder")
	return null


func _active_weapon() -> Object:
	if _body.has_method(&"get_active_weapon"):
		return _body.call(&"get_active_weapon")
	var holder := _holder()
	if holder != null and holder.has_method(&"get_active"):
		return holder.call(&"get_active")
	if _body.has_method(&"get_active"):
		return _body.call(&"get_active")
	return null


func _other_weapon() -> Object:
	if _body.has_method(&"get_other"):
		return _body.call(&"get_other")
	var holder := _holder()
	if holder == null:
		return null
	var slots: Variant = holder.get(&"slots")
	var index: Variant = holder.get(&"active_index")
	if slots is Array and index is int and (slots as Array).size() > 1:
		var arr := slots as Array
		var other: Variant = arr[(index + 1) % arr.size()]
		return other as Object
	return null


func _type_of(weapon: Object) -> int:
	if weapon == null or not is_instance_valid(weapon):
		return CharacterAnimState.WeaponType.NONE
	var data: Variant = weapon.get(&"data")
	if data is Object and data != null:
		var anim_type: Variant = (data as Object).get(&"anim_type")
		if anim_type is StringName or anim_type is String:
			return CharacterAnimState.weapon_type_from_anim_type(StringName(anim_type))
	# No anim_type yet: guess from the class name / resource path.
	var path := ""
	if data is Resource:
		path = (data as Resource).resource_path.to_lower()
	if "pistol" in path or "magnum" in path:
		return CharacterAnimState.WeaponType.PISTOL
	return CharacterAnimState.WeaponType.RIFLE


func _data_float(weapon: Object, field: StringName, fallback: float) -> float:
	if weapon == null:
		return fallback
	var data: Variant = weapon.get(&"data")
	if data is Object and data != null:
		var v: Variant = (data as Object).get(field)
		if v is float or v is int:
			return float(v)
	return fallback


func _sync_weapon(announce: bool) -> void:
	var weapon := _active_weapon()
	if weapon == _weapon:
		return
	if _weapon != null and is_instance_valid(_weapon):
		_disconnect_weapon(_weapon)
	_weapon = weapon
	state.weapon_type = _type_of(weapon)
	if weapon == null:
		return
	_connect(weapon, &"fired", _on_fired)
	_connect(weapon, &"reload_started", _on_reload_started)
	_connect(weapon, &"reload_cancelled", _on_reload_cancelled)
	if weapon.has_signal(&"melee_started"):
		_connect(weapon, &"melee_started", _on_melee_started)
	else:
		_connect(weapon, &"melee_swung", _on_melee_swung)
	if announce:
		var t := _data_float(weapon, &"equip_time", default_switch_time)
		_start_action(CharacterAnimState.Action.SWITCH, t)


func _disconnect_weapon(weapon: Object) -> void:
	for pair: Array in [
		[&"fired", _on_fired],
		[&"reload_started", _on_reload_started],
		[&"reload_cancelled", _on_reload_cancelled],
		[&"melee_started", _on_melee_started],
		[&"melee_swung", _on_melee_swung],
	]:
		var sig: StringName = pair[0]
		var cb: Callable = pair[1]
		if weapon.has_signal(sig) and weapon.is_connected(sig, cb):
			weapon.disconnect(sig, cb)


func _connect(target: Object, sig: StringName, cb: Callable) -> void:
	if target.has_signal(sig) and not target.is_connected(sig, cb):
		target.connect(sig, cb)


func _start_action(action: int, duration: float) -> void:
	state.action = action
	state.action_duration = duration
	state.action_seq = CharacterAnimState.bump(state.action_seq)


func _on_weapon_changed(_weapon_arg: Variant = null) -> void:
	_sync_weapon(true)


func _on_fired() -> void:
	state.fire_seq = CharacterAnimState.bump(state.fire_seq)


func _on_reload_started() -> void:
	var empty := false
	if _weapon != null:
		var mag: Variant = _weapon.get(&"magazine")
		empty = mag is int and mag == 0
	var action := (
		CharacterAnimState.Action.RELOAD_EMPTY if empty else CharacterAnimState.Action.RELOAD
	)
	_start_action(action, _data_float(_weapon, &"reload_time", 0.0))


func _on_reload_cancelled() -> void:
	# A melee cancels the reload after melee_started in the same frame; keep the melee.
	if Engine.get_physics_frames() == _melee_frame:
		return
	state.action_cancel_seq = CharacterAnimState.bump(state.action_cancel_seq)


func _on_melee_started(_weapon_arg: Variant = null, _time_to_hit: Variant = null) -> void:
	_melee_frame = Engine.get_physics_frames()
	_start_action(CharacterAnimState.Action.MELEE, _data_float(_weapon, &"melee_cooldown", 0.0))


func _on_melee_swung() -> void:
	_on_melee_started()


func _on_damaged(_amount: Variant = 0.0, info: Variant = {}) -> void:
	if state.dead or not info is Dictionary:
		return
	var dir: Variant = (info as Dictionary).get("dir")
	if not dir is Vector3 or (dir as Vector3).length_squared() < 1e-6:
		return
	state.flinch_dir = CharacterAnimState.hit_dir_from_world(dir, _body.global_rotation.y)
	state.flinch_seq = CharacterAnimState.bump(state.flinch_seq)


## died() differs per body: Player/Bot (self, killer, info), dummies (). Take any of them.
func _on_died(_a: Variant = null, _b: Variant = null, info: Variant = {}) -> void:
	var dir := Vector3.ZERO
	var impulse := Vector3.ZERO
	if info is Dictionary:
		var d: Variant = (info as Dictionary).get("dir")
		if d is Vector3:
			dir = d
		var i: Variant = (info as Dictionary).get("impulse")
		if i is Vector3:
			impulse = i
	state.death_dir = (
		CharacterAnimState.hit_dir_from_world(dir, _body.global_rotation.y)
		if dir.length_squared() > 1e-6
		else CharacterAnimState.HitDir.FRONT
	)
	state.death_impulse = impulse
	if not state.dead:
		state.dead = true
		state.death_seq = CharacterAnimState.bump(state.death_seq)


func _on_respawned(_a: Variant = null) -> void:
	state.dead = false
	state.action = CharacterAnimState.Action.NONE
	_sync_weapon(false)
	reset_baseline()
