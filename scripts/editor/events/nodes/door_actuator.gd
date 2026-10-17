class_name DoorActuator
extends LogicNodeBase
## Controls mechanical sliding, blast doors, and security barriers in campaign levels.

signal on_opened()
signal on_closed()
signal on_locked()
signal on_unlocked()

@export var door_target_path: NodePath
@export var slide_offset: Vector3 = Vector3(0.0, 3.5, 0.0)
@export var speed: float = 3.0
@export var is_locked: bool = false
@export var is_open: bool = false

var _closed_transform: Transform3D
var _door_node: Node3D
var _moving: bool = false
var _target_pos: Vector3


func _init() -> void:
	super._init()
	display_name = "Door Actuator"


func _ready() -> void:
	super._ready()
	if not door_target_path.is_empty():
		_door_node = get_node_or_null(door_target_path) as Node3D
	elif get_child_count() > 0:
		for c in get_children():
			if c is Node3D and c != _editor_visual:
				_door_node = c
				break
	if _door_node != null:
		_closed_transform = _door_node.transform
		_target_pos = _closed_transform.origin if not is_open else _closed_transform.origin + slide_offset


func _process(delta: float) -> void:
	if _door_node == null:
		return
	if not _door_node.position.is_equal_approx(_target_pos):
		_door_node.position = _door_node.position.move_toward(_target_pos, speed * delta)
		if _door_node.position.is_equal_approx(_target_pos):
			if is_open:
				on_opened.emit()
			else:
				on_closed.emit()


func get_node_color() -> Color:
	return Color(0.85, 0.65, 0.15, 0.85)


func get_input_actions() -> Array[String]:
	return ["open", "close", "toggle", "lock", "unlock", "unlock_and_open"]


func get_output_signals() -> Array[String]:
	return ["on_opened", "on_closed", "on_locked", "on_unlocked"]


func open() -> void:
	if is_locked or is_open:
		return
	is_open = true
	_target_pos = _closed_transform.origin + slide_offset


func close() -> void:
	if is_locked or not is_open:
		return
	is_open = false
	_target_pos = _closed_transform.origin


func toggle() -> void:
	if is_open:
		close()
	else:
		open()


func lock() -> void:
	is_locked = true
	on_locked.emit()


func unlock() -> void:
	is_locked = false
	on_unlocked.emit()


func unlock_and_open() -> void:
	unlock()
	open()
