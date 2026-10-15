class_name NetAnim
extends RefCounted
## Third-person animation replication for one body (player, puppet or bot), per LC Animator's
## CharacterAnimState contract (scripts/characters/character_anim_state.gd, animator-main).
## The authority for a body (the owning client for its player, the host for its own player and
## bots) keeps the one-shot counters here from the body's own signals and packs them with the
## body's getters into ANIM_BYTES bytes per snapshot. Yaw and aim pitch ride the snapshot pose.
## Receivers unpack into a CharacterAnimState dictionary (to_dict keys) and feed any
## descendant with apply_state() (CharacterAnimDriver). Everything is has_method / ResourceLoader
## guarded, so this runs unchanged on branches without the animator scaffold.
##
## Wire layout (10 bytes):
##   0..2  velocity x, y, z as int8, VELOCITY_STEP m/s per unit (clamped +-31.75 m/s)
##   3     flags: 1 on_floor, 2 crouched, 4 sliding, 8 dead; bits 4..7 weapon type index
##   4..7  fire_seq, action_seq, action_cancel_seq, death_seq (u8, wrap 256)
##   8     action (bits 0..3) | death_dir << 4
##   9     action_duration in DURATION_STEP s (0..5.1 s)

const ANIM_BYTES := 10
const VELOCITY_STEP := 0.25
const DURATION_STEP := 0.02
const SEQ_WRAP := 256
const STATE_SCRIPT := "res://scripts/characters/character_anim_state.gd"
## WeaponData.anim_type -> CharacterAnimState.WeaponType (same order as the driver's
## WEAPON_INPUTS). Unknown types fall back to rifle; extend both lists together.
const ANIM_TYPES: Array[StringName] = [&"none", &"rifle", &"pistol"]
## CharacterAnimState.Action / DeathDir values.
const ACTION_NONE := 0
const ACTION_RELOAD := 1
const ACTION_RELOAD_EMPTY := 2
const ACTION_MELEE := 3
const ACTION_SWITCH := 4
const DEATH_FORWARD := 0
const DEATH_BACK := 1
const DEATH_LEFT := 2
const DEATH_RIGHT := 3

var fire_seq: int = 0
var action_seq: int = 0
var action: int = ACTION_NONE
var action_duration: float = 0.0
var cancel_seq: int = 0
var death_seq: int = 0
var death_dir: int = DEATH_BACK

var _watched: Dictionary = {}


static func bump(seq: int) -> int:
	return (seq + 1) % SEQ_WRAP


## Count this weapon's shots, reloads, melees and cancels (idempotent per weapon).
func watch_weapon(weapon: Weapon) -> void:
	if weapon == null or _watched.has(weapon.get_instance_id()):
		return
	_watched[weapon.get_instance_id()] = true
	weapon.fired.connect(func() -> void: fire_seq = bump(fire_seq))
	weapon.reload_started.connect(_on_reload_started.bind(weapon))
	weapon.reload_cancelled.connect(func() -> void: cancel_seq = bump(cancel_seq))
	weapon.melee_started.connect(_on_melee_started)


## A switch (or a pickup that equips): SWITCH for the new weapon's equip time.
func note_switch(weapon: Weapon) -> void:
	watch_weapon(weapon)
	var duration := weapon.data.equip_time if weapon != null and weapon.data != null else 0.0
	_start_action(ACTION_SWITCH, duration)


## A death travelling along world_dir (attacker -> victim) relative to body's facing.
func note_death(body: Node3D, world_dir: Vector3) -> void:
	death_seq = bump(death_seq)
	death_dir = death_dir_of(body, world_dir)


func _on_reload_started(weapon: Weapon) -> void:
	var kind := ACTION_RELOAD_EMPTY if weapon.reload_empty else ACTION_RELOAD
	_start_action(kind, weapon.data.reload_time if weapon.data != null else 0.0)


func _on_melee_started(weapon: Weapon, _time_to_hit: float) -> void:
	_start_action(ACTION_MELEE, weapon.data.melee_cooldown if weapon.data != null else 0.0)


func _start_action(kind: int, duration: float) -> void:
	action_seq = bump(action_seq)
	action = kind
	action_duration = duration


## Direction the body falls: the hit's travel direction in the body's frame.
static func death_dir_of(body: Node3D, world_dir: Vector3) -> int:
	if body == null or world_dir.length_squared() < 0.0001:
		return DEATH_BACK
	var local := body.global_basis.inverse() * world_dir
	var forward := -local.z
	if absf(forward) >= absf(local.x):
		return DEATH_FORWARD if forward > 0.0 else DEATH_BACK
	return DEATH_RIGHT if local.x > 0.0 else DEATH_LEFT


static func anim_type_index(weapon: Weapon) -> int:
	if weapon == null or weapon.data == null:
		return 0
	# WeaponData.anim_type is LC Engineer's (main-guns); absent on origin/main -> rifle.
	if not (&"anim_type" in weapon.data):
		return 1
	var index := ANIM_TYPES.find(StringName(weapon.data.get(&"anim_type")))
	return index if index >= 0 else 1


static func active_weapon_of(body: Node) -> Weapon:
	if body == null:
		return null
	if body.has_method(&"get_active_weapon"):
		return body.call(&"get_active_weapon") as Weapon
	if body.has_method(&"get_active"):
		return body.call(&"get_active") as Weapon
	return null


## Packs body's current state plus the counters. velocity: the body's (or a puppet's reported).
func pack(body: Node3D, velocity: Vector3) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ANIM_BYTES)
	for i in 3:
		bytes.encode_s8(i, clampi(roundi(velocity[i] / VELOCITY_STEP), -127, 127))
	var flags := 0
	if body is CharacterBody3D and (body as CharacterBody3D).is_on_floor():
		flags |= 1
	if body.get(&"crouched") == true:
		flags |= 2
	if body.get(&"sliding") == true:
		flags |= 4
	if body.has_method(&"is_dead") and body.call(&"is_dead"):
		flags |= 8
	flags |= anim_type_index(active_weapon_of(body)) << 4
	bytes[3] = flags
	bytes[4] = fire_seq
	bytes[5] = action_seq
	bytes[6] = cancel_seq
	bytes[7] = death_seq
	bytes[8] = (action & 0x0f) | ((death_dir & 0x03) << 4)
	bytes[9] = clampi(roundi(action_duration / DURATION_STEP), 0, 255)
	return bytes


## Host: a client's packed state with this tracker's (authoritative) death fields.
func override_death(bytes: PackedByteArray, dead: bool) -> PackedByteArray:
	if bytes.size() != ANIM_BYTES:
		return bytes
	var out := bytes.duplicate()
	out[3] = (out[3] & ~8) | (8 if dead else 0)
	out[7] = death_seq
	out[8] = (out[8] & 0x0f) | ((death_dir & 0x03) << 4)
	return out


## CharacterAnimState.to_dict() keys. Empty for a malformed packet.
static func unpack(bytes: PackedByteArray, yaw: float, pitch: float) -> Dictionary:
	if bytes.size() != ANIM_BYTES:
		return {}
	var velocity := Vector3(bytes.decode_s8(0), bytes.decode_s8(1), bytes.decode_s8(2))
	var flags := bytes[3]
	return {
		"v": velocity * VELOCITY_STEP,
		"y": yaw,
		"p": pitch,
		"f": (flags & 1) != 0,
		"c": (flags & 2) != 0,
		"s": (flags & 4) != 0,
		"d": (flags & 8) != 0,
		"w": flags >> 4,
		"fs": bytes[4],
		"as": bytes[5],
		"acs": bytes[6],
		"ds": bytes[7],
		"a": bytes[8] & 0x0f,
		"dd": (bytes[8] >> 4) & 0x03,
		"ad": bytes[9] * DURATION_STEP,
	}


## The body's CharacterAnimDriver (any descendant with apply_state + reset_baseline), or null.
static func driver_of(body: Node) -> Node:
	if body == null:
		return null
	if body.has_meta(&"net_anim_driver"):
		var cached: Variant = body.get_meta(&"net_anim_driver")
		if cached is Node and is_instance_valid(cached):
			return cached
	for node in body.find_children("*", "Node", true, false):
		if node.has_method(&"apply_state") and node.has_method(&"reset_baseline"):
			body.set_meta(&"net_anim_driver", node)
			return node
	return null


## Feeds a driver if the body has one and the animator's state class exists on this branch.
static func apply(body: Node, state: Dictionary) -> void:
	var driver := driver_of(body)
	if driver == null or state.is_empty() or not ResourceLoader.exists(STATE_SCRIPT):
		return
	var script := load(STATE_SCRIPT) as Script
	if script == null:
		return
	driver.call(&"apply_state", script.call(&"from_dict", state))


## Spawn, respawn and late join: stale counters must not replay an old one-shot.
static func reset(body: Node) -> void:
	var driver := driver_of(body)
	if driver != null:
		driver.call(&"reset_baseline")
