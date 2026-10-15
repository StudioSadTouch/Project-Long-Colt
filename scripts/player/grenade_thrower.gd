class_name GrenadeThrower
extends Node
## Halo-style grenades for the Player it sits under ("GrenadeThrower" in player.tscn):
## action_grenade_throw (G, pad LB) throws the selected type, action_grenade_switch (Q, D-pad
## left) cycles types. Counts per type reset to start_counts on respawn and cap at max_count.
## A type that runs out hands the selection to the next type that has grenades.
##
## Net (NetMatch): on a client, throw_hook is set and a throw only predicts the count and asks
## the host (the host checks consume() on its puppet and spawns the real grenade). Offline and
## on the host the grenade is spawned here, authoritative, and `thrown` fires for the broadcast.

signal changed
signal thrown(grenade: Grenade, type_index: int, origin: Vector3, velocity: Vector3)

const SOUND_THROW := preload("res://assets/audio/weapons/grenades/grenade_throw.wav")
const SOUND_SWITCH := preload("res://assets/audio/weapons/grenades/grenade_switch.wav")
## Where the grenade leaves the hand, relative to the camera (forward, right, down).
const HAND_FORWARD := 0.55
const HAND_RIGHT := 0.18
const HAND_DOWN := 0.18
const WORLD_MASK := 1

@export var types: Array[GrenadeData] = [
	preload("res://resources/weapons/frag_grenade.tres"),
	preload("res://resources/weapons/sticky_grenade.tres"),
]
## Grenades of each type at spawn (same order as types).
@export var start_counts: Array[int] = [2, 2]
@export var max_count: int = 4

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
	if _player == null or _player.is_dead() or _player.net_puppet:
		return false
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless"


func get_selected() -> GrenadeData:
	return types[selected] if selected < types.size() else null


func get_count(type_index: int) -> int:
	return counts[type_index] if type_index >= 0 and type_index < counts.size() else 0


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
	if _player == null or _player.camera == null or not consume(selected):
		return false
	var data := types[selected]
	var throw_type := selected
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


func _select_available() -> void:
	if get_count(selected) > 0:
		return
	for step in range(1, types.size()):
		var index := (selected + step) % types.size()
		if get_count(index) > 0:
			selected = index
			return
