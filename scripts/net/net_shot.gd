class_name NetShot
extends RefCounted
## Client-side capture of one local weapon's shots for the host (NetMatch). Listens to
## Weapon.ray_fired (the only weapon.gd hook) and charge_released when present; every ray of one
## frame is one request (a trigger pull, a pellet blast, or up to MAX_SHOTS_PER_TICK burst
## rounds), sent once at the end of the frame via `captured`.
##
## Request layout (Array, see NetMatch._rpc_fire and docs/net/netcode.md):
##   [REQ_ID]      weapon id (WeaponData resource_path)
##   [REQ_ORIGIN]  aim origin (Vector3), [REQ_QUAT] aim basis (Quaternion)
##   [REQ_SEED]    PackedInt64Array: weapon.last_shot_seed after each round (`fired`) in this
##                 frame (bursts / AUTO can fire several per tick); empty without seeding
##   [REQ_SPREAD]  PackedFloat32Array: get_spread() at each round's first ray (degrees)
##   [REQ_CHARGED] charge_released(true) this frame
##   [REQ_ALT]     alt_mode, [REQ_ZOOM] zoomed
##   [REQ_DIRS]    every ray's final direction (spread and bend applied), [REQ_BENT] _bent per ray

## tos / hits: every ray's end point and hit flag (remote FX).
signal captured(request: Array, tos: PackedVector3Array, hits: PackedByteArray)

enum { REQ_ID, REQ_ORIGIN, REQ_QUAT, REQ_SEED, REQ_SPREAD, REQ_CHARGED, REQ_ALT, REQ_ZOOM }
const REQ_DIRS := 8
const REQ_BENT := 9
const REQ_SIZE := 10

var weapon: Weapon

var _pending: bool = false
var _origin: Vector3
var _quat: Quaternion
var _spreads := PackedFloat32Array()
var _seeds := PackedInt64Array()
var _round_open: bool = false
var _charged: bool = false
var _dirs := PackedVector3Array()
var _bent := PackedByteArray()
var _tos := PackedVector3Array()
var _hits := PackedByteArray()


## Wire types of every field (requests come from clients: never trust, never assign blindly).
static func is_well_formed(request: Array) -> bool:
	if request.size() != REQ_SIZE:
		return false
	var types := [
		TYPE_STRING,
		TYPE_VECTOR3,
		TYPE_QUATERNION,
		TYPE_PACKED_INT64_ARRAY,
		TYPE_PACKED_FLOAT32_ARRAY,
		TYPE_BOOL,
		TYPE_BOOL,
		TYPE_BOOL,
		TYPE_PACKED_VECTOR3_ARRAY,
		TYPE_PACKED_BYTE_ARRAY,
	]
	for i in REQ_SIZE:
		if typeof(request[i]) != types[i]:
			return false
	return true


func _init(watched: Weapon) -> void:
	weapon = watched
	weapon.ray_fired.connect(_on_ray_fired)
	weapon.fired.connect(_on_fired)
	if weapon.has_signal(&"charge_released"):
		weapon.connect(&"charge_released", _on_charge_released)


func _on_ray_fired(from: Vector3, to: Vector3, hit: Dictionary) -> void:
	if not is_instance_valid(weapon):
		return
	if not _pending:
		_pending = true
		var aim := weapon.aim_source if is_instance_valid(weapon.aim_source) else weapon.camera
		_origin = from
		_quat = aim.global_basis.get_rotation_quaternion() if aim != null else Quaternion.IDENTITY
		_flush.call_deferred()
	if not _round_open:
		_round_open = true
		_spreads.append(weapon.get_spread())
	var dir := to - from
	_dirs.append(dir.normalized() if dir.length_squared() > 0.000001 else -Basis(_quat).z)
	_bent.append(1 if weapon.get(&"_bent") == true else 0)
	_tos.append(to)
	_hits.append(0 if hit.is_empty() else 1)


## Round boundary: the seed the round just used.
func _on_fired() -> void:
	_round_open = false
	if _pending and &"last_shot_seed" in weapon:
		_seeds.append(int(weapon.get(&"last_shot_seed")))


func _on_charge_released(charged: bool) -> void:
	if charged:
		_charged = true


func _flush() -> void:
	if not _pending or not is_instance_valid(weapon):
		_reset()
		return
	var request: Array = [
		NetWeapon.id_of(weapon),
		_origin,
		_quat,
		_seeds,
		_spreads,
		_charged,
		weapon.alt_mode,
		weapon.zoomed,
		_dirs,
		_bent,
	]
	var tos := _tos
	var hits := _hits
	_reset()
	captured.emit(request, tos, hits)


func _reset() -> void:
	_pending = false
	_round_open = false
	_charged = false
	_seeds = PackedInt64Array()
	_spreads = PackedFloat32Array()
	_dirs = PackedVector3Array()
	_bent = PackedByteArray()
	_tos = PackedVector3Array()
	_hits = PackedByteArray()
