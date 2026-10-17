class_name GrenadeThrower
extends Node
## Halo-style grenades for the Player it sits under ("GrenadeThrower" in player.tscn):
## action_grenade_throw (G, pad LB) throws the selected type, action_grenade_switch (Q, D-pad
## left) cycles types. Counts per type reset to start_counts on respawn and cap at max_count.
## A type that runs out hands the selection to the next type that has grenades.
##
## Halo: on death (not a kill volume) the grenades still carried drop as GrenadePickups, one
## per type, on the floor around the body; add() takes grenades from pickups.
##
## Net (NetMatch): on a client, throw_hook is set and a throw only predicts the count and asks
## the host (the host checks consume() on its puppet and spawns the real grenade). Offline and
## on the host the grenade is spawned here, authoritative, and `thrown` fires for the broadcast.
## Death drops happen where the counts are authoritative: NetMatch turns drop_on_death off on
## clients (their own player and every puppet) and leaves it on for the host's puppets.

signal changed
signal thrown(grenade: Grenade, type_index: int, origin: Vector3, velocity: Vector3)
## Every accepted throw by this player, offline, host and net client alike (thrown only fires
## where the grenade is spawned). Animation listens to this one.
signal throw_started(type_index: int)

const SOUND_THROW := preload("res://assets/audio/weapons/grenades/grenade_throw.wav")
const SOUND_SWITCH := preload("res://assets/audio/weapons/grenades/grenade_switch.wav")
## Where the grenade leaves the hand, relative to the camera (forward, right, down).
const HAND_FORWARD := 0.55
const HAND_RIGHT := 0.18
const HAND_DOWN := 0.18
const WORLD_MASK := 1
## Death drops: one pickup per type, spread this far apart along the body's facing (weapons drop
## to the sides, WeaponHolder.DEATH_DROP_SPREAD). A wall in the way shortens it.
const DEATH_DROP_SPREAD := 0.8
const DROP_CHEST_HEIGHT := 1.2
const DROP_WALL_MARGIN := 0.4
## How far below chest height to look for floor.
const DROP_FLOOR_SEARCH := 2.5

@export var types: Array[GrenadeData] = [
	preload("res://resources/weapons/frag_grenade.tres"),
	preload("res://resources/weapons/sticky_grenade.tres"),
]
## Grenades of each type at spawn (same order as types).
@export var start_counts: Array[int] = [2, 2]
@export var max_count: int = 4
## Halo: carried grenades drop as pickups on death (never for kill-volume deaths).
@export var drop_on_death: bool = true

var counts: Array[int] = []
var selected: int = 0
## Net client: Callable(type_index, origin, velocity). Set by NetMatch; empty offline / host.
var throw_hook: Callable

var _player: Player
var _cooldown: float = 0.0
var _voice: AudioStreamPlayer


func _ready() -> void:
	_player = get_parent() as Player
	_voice = AudioStreamPlayer.new()
	_voice.volume_db = -4.0
	add_child(_voice)
	reset()
	if _player != null:
		_player.respawned.connect(func(_p: Player) -> void: reset())
		_player.died.connect(_on_owner_died)


func reset() -> void:
	counts.clear()
	for i in types.size():
		counts.append(clampi(start_counts[i] if i < start_counts.size() else 0, 0, max_count))
	selected = 0
	_cooldown = 0.0
	_select_available()
	changed.emit()


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled():
		return
	if event.is_action_pressed(&"action_grenade_throw"):
		throw_selected()
	elif event.is_action_pressed(&"action_grenade_switch"):
		cycle()


func _input_enabled() -> bool:
	if _player == null or _player.is_dead() or _player.net_puppet or _player.is_mounted():
		return false
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless"


func get_selected() -> GrenadeData:
	return types[selected] if selected < types.size() else null


func get_count(type_index: int) -> int:
	return counts[type_index] if type_index >= 0 and type_index < counts.size() else 0


## Index of a grenade type in types (matched by resource path, so copies match), or -1.
func index_of(data: GrenadeData) -> int:
	if data == null:
		return -1
	for i in types.size():
		if types[i] == data:
			return i
		if data.resource_path != "" and types[i].resource_path == data.resource_path:
			return i
	return -1


## Next type (Halo: switching works even if that type is empty).
func cycle() -> void:
	if types.size() < 2:
		return
	selected = (selected + 1) % types.size()
	_voice.stream = SOUND_SWITCH
	_voice.play()
	changed.emit()


## Adds grenades of a type (pickups); returns how many were taken.
func add(type_index: int, amount: int) -> int:
	if type_index < 0 or type_index >= counts.size():
		return 0
	var taken := clampi(amount, 0, max_count - counts[type_index])
	counts[type_index] += taken
	if taken > 0:
		changed.emit()
	return taken


## Throws the selected type from the camera. Returns false when out or still cooling down.
func throw_selected() -> bool:
	if _player == null or _player.camera == null:
		return false
	# consume() moves the selection off a type it just emptied. The throw is the type
	# that was selected, not the one that selection moved to.
	var throw_type := selected
	if not consume(throw_type):
		return false
	var data := types[throw_type]
	var basis := _player.camera.global_basis
	var forward := -basis.z
	var eye := _player.camera.global_position
	var origin := eye + forward * HAND_FORWARD + basis.x * HAND_RIGHT - basis.y * HAND_DOWN
	var space := _player.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(eye, origin, WORLD_MASK)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		# Up against a wall: release just in front of it instead of inside it.
		origin = (hit.position as Vector3) - forward * (data.radius + 0.05)
	var velocity := forward * data.throw_speed + Vector3.UP * data.throw_lift
	velocity += _player.velocity * data.inherit_velocity
	_voice.stream = SOUND_THROW
	_voice.play()
	throw_started.emit(throw_type)
	if throw_hook.is_valid():
		throw_hook.call(throw_type, origin, velocity)
		return true
	var grenade := spawn(throw_type, origin, velocity, true)
	thrown.emit(grenade, throw_type, origin, velocity)
	return true


## Spends one grenade of type_index if it has one and the cooldown is over (the host calls this
## on a puppet to validate a client's throw). Moves the selection off an emptied type.
func consume(type_index: int) -> bool:
	if _cooldown > 0.0 or get_count(type_index) <= 0:
		return false
	counts[type_index] -= 1
	_cooldown = types[type_index].throw_cooldown
	_select_available()
	changed.emit()
	return true


## A grenade of type_index thrown by this player, under the player's parent (the arena root).
func spawn(type_index: int, origin: Vector3, velocity: Vector3, authoritative: bool) -> Grenade:
	var parent: Node = _player.get_parent() if _player != null else get_tree().current_scene
	return Grenade.spawn(parent, types[type_index], origin, velocity, _player, authoritative)


## Net client: adopt the host's counts (it is the authority; a refused throw gives one back).
func apply_counts(new_counts: Array) -> void:
	var changed_any := false
	for i in mini(new_counts.size(), counts.size()):
		var value := clampi(int(new_counts[i]), 0, max_count)
		if counts[i] != value:
			counts[i] = value
			changed_any = true
	if changed_any:
		_select_available()
		changed.emit()


func _on_owner_died(_player_node: Player, _killer: Node, info: Dictionary) -> void:
	if not drop_on_death or info.get("kill_volume", false):
		return
	var carried: Array[int] = counts.duplicate()
	for i in counts.size():
		counts[i] = 0
	changed.emit()
	# Deferred: death can come from a body_entered during the physics flush, when no Area3D
	# may be added.
	_drop_carried.call_deferred(carried)


## One GrenadePickup per type with grenades, spread along the body's facing.
func _drop_carried(carried: Array[int]) -> void:
	if _player == null or not _player.is_inside_tree():
		return
	var kinds: Array[int] = []
	for i in mini(carried.size(), types.size()):
		if carried[i] > 0:
			kinds.append(i)
	var parent := _player.get_parent()
	for n in kinds.size():
		var offset := (float(n) - float(kinds.size() - 1) * 0.5) * DEATH_DROP_SPREAD
		var index := kinds[n]
		GrenadePickup.drop(types[index], carried[index], parent, _drop_position(offset))


## Floor under the body, offset along its facing (short of walls). Falls back to the feet.
func _drop_position(offset: float) -> Vector3:
	var feet := _player.global_position
	var space := _player.get_world_3d().direct_space_state
	var chest := feet + Vector3.UP * DROP_CHEST_HEIGHT
	var from := chest
	if offset != 0.0:
		var forward := -_player.global_transform.basis.z
		forward.y = 0.0
		forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
		var target := chest + forward * offset
		var wall := space.intersect_ray(
			PhysicsRayQueryParameters3D.create(chest, target, WORLD_MASK)
		)
		if wall.is_empty():
			from = target
		else:
			var reach := maxf(chest.distance_to(wall.position) - DROP_WALL_MARGIN, 0.0)
			from = chest + forward * signf(offset) * reach
	var down := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.DOWN * DROP_FLOOR_SEARCH, WORLD_MASK
	)
	var floor_hit := space.intersect_ray(down)
	if floor_hit.is_empty():
		return feet
	return floor_hit.position


func _select_available() -> void:
	if get_count(selected) > 0:
		return
	for step in range(1, types.size()):
		var index := (selected + step) % types.size()
		if get_count(index) > 0:
			selected = index
			return
