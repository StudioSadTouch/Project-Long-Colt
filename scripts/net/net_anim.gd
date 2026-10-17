class_name NetAnim
extends RefCounted
## Third-person animation replication, per LC Animator's contract (e1cc52e):
## CharacterAnimSource fills a CharacterAnimState from a body; CharacterAnimDriver plays it.
##
## * Authority: the owning client for its player; the host for its own player and its bots.
##   Its source stays enabled, and capture() sends `state.to_dict()` as a value array in
##   KEYS order. That covers velocity, floor/crouch/slide/dead, weapon and holster type,
##   the fire/action/cancel/death/flinch counters, death dir and impulse, and action duration.
## * Yaw ("y") and aim pitch ("p") are not sent: they ride the snapshot pose.
## * Remote copies (every puppet, on the host and on clients): make_remote() disables the
##   source, and apply() calls driver.apply_state(CharacterAnimState.from_dict(...)).
## * Host: override_life() replaces a client's own death and flinch fields with the ones the
##   host's puppet source recorded from the authoritative died / damaged signals.
## * reset() (driver.reset_baseline) runs on spawn, respawn and late join. The next apply()
##   then sets the baseline without firing one-shots. A late joiner's first snapshot of a dead
##   body poses it dead, without replaying the death clip.
## Every value is type-coerced to the to_dict() default, so a malformed packet can't break
## from_dict's typed assignments.

const POSE_KEYS: Array[String] = ["y", "p"]

static var _defaults: Dictionary = {}
static var _keys: Array[String] = []


## to_dict() keys minus the pose ones, in a fixed order (both peers run the same script).
static func keys() -> Array[String]:
	if _keys.is_empty():
		_defaults = CharacterAnimState.new().to_dict()
		for key: Variant in _defaults:
			if not POSE_KEYS.has(str(key)):
				_keys.append(str(key))
	return _keys


static func source_of(body: Node) -> CharacterAnimSource:
	if body == null:
		return null
	var model := body.get_node_or_null(PlayerColor.MODEL_NODE)
	if model == null:
		return null
	for child in model.get_children():
		if child is CharacterAnimSource:
			return child
	return null


static func driver_of(body: Node) -> CharacterAnimDriver:
	var source := source_of(body)
	if source != null and source.driver != null:
		return source.driver
	var model := body.get_node_or_null(PlayerColor.MODEL_NODE) if body != null else null
	if model == null:
		return null
	for child in model.get_children():
		if child is CharacterAnimDriver:
			return child
	return null


## A body whose animation comes from the network: stop sampling it locally.
static func make_remote(body: Node) -> void:
	var source := source_of(body)
	if source != null:
		source.enabled = false
	reset(body)


## The authority's current state as a value array (empty without a source).
static func capture(body: Node) -> Array:
	var source := source_of(body)
	if source == null:
		return []
	return encode(source.state.to_dict())


static func encode(state: Dictionary) -> Array:
	var out: Array = []
	for key in keys():
		out.append(state.get(key, _defaults[key]))
	return out


## Value array -> to_dict() dictionary; {} if malformed. Types are coerced to the defaults.
static func decode(packed: Variant) -> Dictionary:
	var list := keys()
	if not packed is Array or (packed as Array).size() != list.size():
		return {}
	var values: Array = packed
	var out := {}
	for i in list.size():
		var fallback: Variant = _defaults[list[i]]
		out[list[i]] = type_convert(values[i], typeof(fallback))
	return out


## Host: a client's array with the death / flinch fields from the host puppet's own source.
static func override_life(packed: Variant, body: Node) -> Array:
	var state := decode(packed)
	var source := source_of(body)
	if state.is_empty() or source == null:
		return packed if packed is Array else []
	var host := source.state
	var dead := bool(body.call(&"is_dead")) if body.has_method(&"is_dead") else host.dead
	state["d"] = dead
	state["ds"] = host.death_seq
	state["dd"] = host.death_dir
	state["di"] = host.death_impulse
	state["fl"] = host.flinch_seq
	state["fd"] = host.flinch_dir
	return encode(state)


## Whether a packed state is crouched (for the snapshot interpolation buffer).
static func crouched_of(packed: Variant) -> bool:
	return bool(decode(packed).get("c", false))


## Remote copy: feed the driver. yaw / pitch from the snapshot pose.
static func apply(body: Node, packed: Variant, yaw: float, pitch: float) -> void:
	var driver := driver_of(body)
	if driver == null:
		return
	var state := decode(packed)
	if state.is_empty():
		return
	state["y"] = yaw
	state["p"] = pitch
	driver.apply_state(CharacterAnimState.from_dict(state))


## Spawn, respawn and late join: stale counters must not replay an old one-shot.
static func reset(body: Node) -> void:
	var source := source_of(body)
	if source != null:
		source.reset_baseline()
		return
	var driver := driver_of(body)
	if driver != null:
		driver.reset_baseline()


static func active_weapon_of(body: Node) -> Weapon:
	if body == null:
		return null
	if body.has_method(&"get_active_weapon"):
		return body.call(&"get_active_weapon") as Weapon
	if body.has_method(&"get_active"):
		return body.call(&"get_active") as Weapon
	return null
