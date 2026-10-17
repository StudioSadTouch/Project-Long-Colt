class_name CharacterAnimState
extends RefCounted
## Everything a third-person character animation needs, and nothing it doesn't. This is the
## netcode contract: the authority fills it from the body (player, bot, dummy), replicates it,
## and every peer feeds it to CharacterAnimDriver.apply_state(). Never derived from input.
## One-shots are sequence counters (wrap at 256): the driver fires when a counter changes, so
## dropped or repeated snapshots and late joiners don't double-play or miss an action.

## Append, never reorder (synced as ints). SWORD / HAMMER: the melee weapons' own holds (side
## guard, port arms) and swings.
enum WeaponType { NONE, RIFLE, PISTOL, SWORD, HAMMER }
enum Action { NONE, RELOAD, RELOAD_EMPTY, MELEE, SWITCH, THROW }
## Which weapon mesh the third-person props show (the animation class above only picks the
## hold). Keyed by weapon scene file name, so bots and players resolve the same id.
## Append, never reorder (synced as ints). TUFEK .. YATAGAN: the New Ottoman issue weapons
## (scenes/weapons/new_ottoman), picked up from the enemies.
enum WeaponModel {
	NONE,
	RIFLE,
	PISTOL,
	CARBINE,
	SHOTGUN,
	ROCKET,
	SWORD,
	HAMMER,
	TUFEK,
	GLAIVE_RIFLE,
	HUMBARA,
	RAIDER_CARBINE,
	LONG_RIFLE,
	KILIJ,
	YATAGAN,
}
## Side the hit came FROM, relative to the body (front = shot in the chest, falls backward).
enum HitDir { FRONT, BACK, LEFT, RIGHT }

const SEQ_WRAP := 256
const MODEL_SCENES := {
	"standard_issue_rifle": WeaponModel.RIFLE,
	"service_pistol": WeaponModel.PISTOL,
	"marksman_carbine": WeaponModel.CARBINE,
	"combat_shotgun": WeaponModel.SHOTGUN,
	"directed_energy_rifle": WeaponModel.ROCKET,
	"longsword": WeaponModel.SWORD,
	"gravity_hammer": WeaponModel.HAMMER,
	"tufek": WeaponModel.TUFEK,
	"glaive_rifle": WeaponModel.GLAIVE_RIFLE,
	"humbara_launcher": WeaponModel.HUMBARA,
	"raider_carbine": WeaponModel.RAIDER_CARBINE,
	"long_rifle": WeaponModel.LONG_RIFLE,
	"kilij": WeaponModel.KILIJ,
	"yatagan": WeaponModel.YATAGAN,
}
## Additive fire clip per model; models without one use fire_<weapon class>.
const MODEL_FIRE := {
	WeaponModel.CARBINE: &"fire_carbine",
	WeaponModel.SHOTGUN: &"fire_shotgun",
	WeaponModel.ROCKET: &"fire_heavy",
	WeaponModel.TUFEK: &"fire_carbine",
	WeaponModel.LONG_RIFLE: &"fire_carbine",
	WeaponModel.HUMBARA: &"fire_heavy",
}

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
## +1 per reload start, melee start, weapon switch or grenade throw; `action` says which.
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
## WeaponModel of the weapon in hand / holstered (third-person prop mesh, fire clip).
var weapon_model: int = WeaponModel.NONE
var holster_model: int = WeaponModel.NONE


## Increments a sequence counter with wrap.
static func bump(seq: int) -> int:
	return (seq + 1) % SEQ_WRAP


## Maps WeaponData.anim_type (&"rifle", &"pistol", &"smg", ...) to an animation class.
## Anything else is held like the rifle; empty means no weapon. The longsword and the gravity
## hammer have their own classes (side guard / port arms, their own swings).
static func weapon_type_from_anim_type(anim_type: StringName) -> int:
	match anim_type:
		&"":
			return WeaponType.NONE
		&"pistol", &"sidearm", &"magnum":
			return WeaponType.PISTOL
		&"sword":
			return WeaponType.SWORD
		&"hammer":
			return WeaponType.HAMMER
		&"none", &"unarmed":
			return WeaponType.NONE
	return WeaponType.RIFLE


## WeaponModel for a weapon scene path (res://scenes/weapons/<name>.tscn); NONE if unknown.
static func model_from_scene(path: String) -> int:
	return MODEL_SCENES.get(path.get_file().get_basename(), WeaponModel.NONE)


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
		"wm": weapon_model,
		"hm": holster_model,
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
	s.weapon_model = data.get("wm", WeaponModel.NONE)
	s.holster_model = data.get("hm", WeaponModel.NONE)
	return s
