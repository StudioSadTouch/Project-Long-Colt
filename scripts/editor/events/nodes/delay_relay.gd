class_name DelayRelay
extends LogicNodeBase
## Pauses signal flow by N seconds before emitting output trigger.

signal on_timeout()

@export var delay_seconds: float = 1.0
@export var repeat: bool = false

var _timer: SceneTreeTimer
var _active: bool = false


func _init() -> void:
	super._init()
	display_name = "Delay Relay"


func get_node_color() -> Color:
	return Color(0.7, 0.4, 0.95, 0.85)


func get_input_actions() -> Array[String]:
	return ["trigger", "start", "cancel"]


func get_output_signals() -> Array[String]:
	return ["on_timeout"]


func trigger() -> void:
	start()


func start() -> void:
	_active = true
	var tree := get_tree()
	if tree != null:
		_timer = tree.create_timer(delay_seconds)
		_timer.timeout.connect(_on_timer_timeout)


func cancel() -> void:
	_active = false
	_timer = null


func _on_timer_timeout() -> void:
	if not _active:
		return
	on_timeout.emit()
	if repeat:
		start()
	else:
		_active = false
