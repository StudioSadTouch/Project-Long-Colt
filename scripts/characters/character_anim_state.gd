class_name CharacterAnimState
extends RefCounted
## Everything a third-person character animation needs, and nothing it doesn't. This is the
## netcode contract: the authority fills it from the body (player, bot, dummy), replicates it,
## and every peer feeds it to CharacterAnimDriver.apply_state(). Never derived from input.
## One-shots are sequence counters (wrap at 256): the driver fires when a counter changes, so
## dropped or repeated snapshots and late joiners don't double-play or miss an action.

enum WeaponType { NONE, RIFLE, PISTOL }
enum Action { NONE, RELOAD, RELOAD_EMPTY, MELEE, SWITCH }
## Side the hit came FROM, relative to the body (front = shot in the chest, falls backward).
enum HitDir { FRONT, BACK, LEFT, RIGHT }

const SEQ_WRAP := 256

## World-space velocity, m/s.
var velocity: Vector3 = Vector3.ZERO
## Body facing, radians (rotation.y).
var yaw: float = 0.0
## Head/aim pitch, radians (head.rotation.x, + is up).
var aim_pitch: float = 0.0
var on_floor: bool = true
var crouched: bool = false
var sliding: bool = false
var dead: bool = false
var weapon_type: int = WeaponType.NONE
## +1 per shot.
var fire_seq: int = 0
## +1 per reload start, melee start or weapon switch; `action` says which.
var action_seq: int = 0
var action: int = Action.NONE
## Seconds the action should take (reload_time, melee_cooldown, equip_time).
var action_duration: float = 0.0
## +1 when an action is cancelled without a new one (holster, etc.).
var action_cancel_seq: int = 0
## +1 per death; death_dir picks the clip.
var death_seq: int = 0
var death_dir: int = HitDir.FRONT
## World-space death impulse for a future client-local ragdoll (zero = none). Not used by the
## canned deaths; replicated so every peer can toss its local ragdoll the same way.
var death_impulse: Vector3 = Vector3.ZERO
## +1 per damage taken while alive; flinch_dir picks the additive clip.
var flinch_seq: int = 0
var flinch_dir: int = HitDir.FRONT
## Weapon on the back/thigh (the inactive slot), for the holstered prop. WeaponType.
var holster_type: int = WeaponType.NONE


## Increments a sequence counter with wrap.
static func bump(seq: int) -> int:
	return (seq + 1) % SEQ_WRAP


## Maps WeaponData.anim_type (&"rifle", &"pistol", &"smg", ...) to an animation class.
## Anything that isn't a pistol is held like the rifle; empty means no weapon.
static func weapon_type_from_anim_type(anim_type: StringName) -> int:
	match anim_type:
		&"":
			return WeaponType.NONE
		&"pistol", &"sidearm", &"magnum":
			return WeaponType.PISTOL
		&"none", &"unarmed":
			return WeaponType.NONE
	return WeaponType.RIFLE


## Which side a world-space hit direction (shooter -> victim) came from, for a body facing
## `body_yaw`. Godot forward is -Z, so a hit from the front travels along the body's +Z.
static func hit_dir_from_world(dir: Vector3, body_yaw: float) -> int:
	var local := Basis(Vector3.UP, body_yaw).inverse() * dir
	if absf(local.z) >= absf(local.x):
		return HitDir.FRONT if local.z >= 0.0 else HitDir.BACK
	return HitDir.LEFT if local.x >= 0.0 else HitDir.RIGHT


func to_dict() -> Dictionary:
	return {
		"v": velocity,
		"y": yaw,
		"p": aim_pitch,
		"f": on_floor,
		"c": crouched,
		"s": sliding,
		"d": dead,
		"w": weapon_type,
		"fs": fire_seq,
		"as": action_seq,
		"a": action,
		"ad": action_duration,
		"acs": action_cancel_seq,
		"ds": death_seq,
		"dd": death_dir,
		"di": death_impulse,
		"fl": flinch_seq,
		"fd": flinch_dir,
		"h": holster_type,
	}


static func from_dict(data: Dictionary) -> CharacterAnimState:
	var s := CharacterAnimState.new()
	s.velocity = data.get("v", Vector3.ZERO)
	s.yaw = data.get("y", 0.0)
	s.aim_pitch = data.get("p", 0.0)
	s.on_floor = data.get("f", true)
	s.crouched = data.get("c", false)
	s.sliding = data.get("s", false)
	s.dead = data.get("d", false)
	s.weapon_type = data.get("w", WeaponType.NONE)
	s.fire_seq = data.get("fs", 0)
	s.action_seq = data.get("as", 0)
	s.action = data.get("a", Action.NONE)
	s.action_duration = data.get("ad", 0.0)
	s.action_cancel_seq = data.get("acs", 0)
	s.death_seq = data.get("ds", 0)
	s.death_dir = data.get("dd", HitDir.FRONT)
	s.death_impulse = data.get("di", Vector3.ZERO)
	s.flinch_seq = data.get("fl", 0)
	s.flinch_dir = data.get("fd", HitDir.FRONT)
	s.holster_type = data.get("h", WeaponType.NONE)
	return s
