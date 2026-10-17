class_name GrenadePickup
extends Node3D
## Halo-style grenades on the ground: `amount` grenades of one GrenadeData type. Walk over them to
## take as many as fit (GrenadeThrower.max_count per type); the rest stay on the ground, one
## mesh per grenade. Nothing to press. Only bodies with a GrenadeThrower take them (players;
## bots don't throw grenades).
##
## Placed pickups (set in the level) refill to `amount` respawn_delay after the last one is taken.
## Dropped pickups (a dead player's grenades, GrenadeThrower.drop_on_death) never respawn and
## despawn after despawn_time.
##
## The Area3D sits on the Pickup layer (7), masks Player (2) and Enemy (4), and is not
## monitorable, like WeaponPickup / AmmoCrate.
##
## Networking: only the host (or offline play) hands out grenades. Net clients mirror the count
## with net_set_remaining() (NetPickups.state carries it instead of a bool); the taker's new
## count reaches its owner through NetMatch's grenade-count sync.

const SCENE_PATH := "res://scenes/pickups/grenade_pickup.tscn"
const SOUND_TAKE := preload("res://assets/audio/weapons/grenades/grenade_switch.wav")
## How many ancestors thrower_of() climbs from the touching collider.
const SEARCH_DEPTH := 4
## Pad top: the grenades rest on it.
const PAD_TOP := 0.04
## Two or more grenades lie in a ring this wide, so you can count them.
const CLUSTER_RADIUS := 0.17
## A thrower whose body (origin at the feet) is farther than this from the pickup is not in
## reach, whatever the trigger says: right after respawn_at() teleports a player, its capsule
## and Hurtbox still report one physics frame of overlap at the old spot, which would hand a
## respawning player its own death drop. A real overlap is under ~1.9 m (trigger 0.9 m at
## 0.5 m up, capsule radius 0.41 m).
const REACH := 2.0

@export var grenade: GrenadeData
## Grenades here when the pickup spawns (and after each respawn).
@export_range(1, 8) var amount: int = 2
@export var respawn_delay: float = 30.0
## Dropped pickups only. 0 = never despawn.
@export var despawn_time: float = 45.0

var remaining: int = 0
var available: bool = true
var dropped: bool = false

## Thrower -> number of its bodies inside the trigger (a Player has a capsule and a Hurtbox).
var _throwers: Dictionary = {}
## Body inside the trigger -> its thrower (exit lookup works even while the owner is dead).
var _bodies: Dictionary = {}
var _meshes: Array[MeshInstance3D] = []

@onready var area: Area3D = $Area
@onready var visual: Node3D = $Visual
@onready var pad: MeshInstance3D = $Pad


## Spawns a dropped pickup of count grenades of grenade_data at position, parented to parent.
static func drop(grenade_data: GrenadeData, count: int, parent: Node, at: Vector3) -> GrenadePickup:
	var pickup := (load(SCENE_PATH) as PackedScene).instantiate() as GrenadePickup
	pickup.grenade = grenade_data
	pickup.amount = count
	pickup.dropped = true
	parent.add_child(pickup)
	pickup.global_position = at
	return pickup


## The GrenadeThrower for a body touching the trigger, or null (no thrower, or its owner is dead).
static func thrower_of(body: Node) -> GrenadeThrower:
	var node := body
	for _i in SEARCH_DEPTH:
		if node == null:
			return null
		var thrower := node.get_node_or_null(^"GrenadeThrower") as GrenadeThrower
		if thrower != null:
			return null if _owner_dead(thrower) else thrower
		node = node.get_parent()
	return null


func _ready() -> void:
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)
	remaining = amount
	_build_visual()
	if dropped and despawn_time > 0.0:
		get_tree().create_timer(despawn_time, false).timeout.connect(_on_despawn)


## Grenades thrower would take right now (0: full, a type it can't carry, dead, or none here).
func room_for(thrower: GrenadeThrower) -> int:
	if not available or grenade == null or thrower == null or _owner_dead(thrower):
		return 0
	var index := thrower.index_of(grenade)
	if index < 0:
		return 0
	return clampi(thrower.max_count - thrower.get_count(index), 0, remaining)


## Gives thrower as many as fit. Returns how many it took. No reach check.
func give(thrower: GrenadeThrower) -> int:
	if not is_authority():
		return 0
	var room := room_for(thrower)
	if room <= 0:
		return 0
	var taken := thrower.add(thrower.index_of(grenade), room)
	if taken > 0:
		_set_remaining(remaining - taken)
	return taken


## thrower has a body inside the trigger (and is really there, see REACH).
func is_in_reach(thrower: GrenadeThrower) -> bool:
	if thrower == null or not _throwers.has(thrower):
		return false
	var body := thrower.get_parent() as Node3D
	return body != null and body.global_position.distance_to(global_position) <= REACH


## Pickup state changes happen here: offline, or on the net host.
func is_authority() -> bool:
	return not is_inside_tree() or multiplayer.is_server()


## Net client: mirror the host's count (0 = taken, waiting to respawn).
func net_set_remaining(count: int) -> void:
	if count == remaining:
		return
	if count < remaining and available:
		_play_take()
	remaining = maxi(count, 0)
	available = remaining > 0
	_refresh_visual()


func _physics_process(_delta: float) -> void:
	if not available or not is_authority():
		return
	for thrower in _throwers.keys():  # untyped: keys may be freed throwers
		if not available:
			return
		if not is_instance_valid(thrower):
			_throwers.erase(thrower)
		elif is_in_reach(thrower):
			give(thrower)


func _set_remaining(count: int) -> void:
	if count < remaining:
		_play_take()
	remaining = maxi(count, 0)
	_refresh_visual()
	if remaining == 0:
		_consume()


func _consume() -> void:
	available = false
	if dropped:
		queue_free()
		return
	get_tree().create_timer(respawn_delay, false).timeout.connect(_respawn)


func _respawn() -> void:
	remaining = amount
	available = true
	_refresh_visual()


func _on_despawn() -> void:
	if available and is_authority():
		remaining = 0
		_consume()


## A one-shot click where the grenades were. Parented beside the pickup so it outlives a drop
## that frees itself on the same take.
func _play_take() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var voice := AudioStreamPlayer3D.new()
	voice.stream = SOUND_TAKE
	voice.pitch_scale = 0.8
	voice.unit_size = 4.0
	voice.max_distance = 30.0
	voice.finished.connect(voice.queue_free)
	parent.add_child(voice)
	voice.global_position = global_position + Vector3.UP * 0.3
	voice.play()


## One mesh per grenade, lying on the pad. Taken grenades hide from the last one back.
func _build_visual() -> void:
	if grenade == null:
		return
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.2, 0.22, 0.24)
	glow.emission_enabled = true
	glow.emission = grenade.flash_color
	glow.emission_energy_multiplier = 0.3
	pad.material_override = glow
	for i in amount:
		var mesh := Grenade.make_mesh(grenade)
		var angle := TAU * float(i) / float(amount) + 0.4
		var spot := Vector3(cos(angle), 0.0, sin(angle)) * CLUSTER_RADIUS if amount > 1 else Vector3.ZERO
		mesh.position = spot + Vector3.UP * (PAD_TOP + grenade.radius)
		if grenade.kind == GrenadeData.Kind.FRAG:
			# The frag capsule stands along Y: lay it on its side.
			mesh.rotation = Vector3(0.0, -angle, PI * 0.5)
		visual.add_child(mesh)
		_meshes.append(mesh)
	_refresh_visual()


func _refresh_visual() -> void:
	for i in _meshes.size():
		_meshes[i].visible = available and i < remaining


static func _owner_dead(thrower: GrenadeThrower) -> bool:
	var body := thrower.get_parent()
	return body != null and body.has_method(&"is_dead") and bool(body.call(&"is_dead"))


func _on_body_entered(body: Node3D) -> void:
	var thrower := thrower_of(body)
	if thrower == null or _bodies.has(body):
		return
	_bodies[body] = thrower
	_throwers[thrower] = int(_throwers.get(thrower, 0)) + 1


func _on_body_exited(body: Node3D) -> void:
	if not _bodies.has(body):
		return
	var thrower: Variant = _bodies[body]  # may be a freed thrower: no typed assignment
	_bodies.erase(body)
	var count := int(_throwers.get(thrower, 1)) - 1
	if count > 0:
		_throwers[thrower] = count
	else:
		_throwers.erase(thrower)
