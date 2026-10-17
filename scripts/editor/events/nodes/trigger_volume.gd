class_name TriggerVolume
extends LogicNodeBase
## Bounded Area3D volume checking actor collision filters for campaign scripting.

signal on_player_entered(body: Node)
signal on_player_exited(body: Node)
signal on_triggered()

@export var volume_size: Vector3 = Vector3(4.0, 3.0, 4.0):
	set(val):
		volume_size = val
		_update_shape()
@export var trigger_once: bool = true
@export var filter: String = "player"  # "player", "bot", "enemy", "any"
@export var is_active: bool = true

var _triggered: bool = false
var _area: Area3D
var _col_shape: CollisionShape3D
var _box_shape: BoxShape3D


func _init() -> void:
	super._init()
	display_name = "Trigger Volume"


func _ready() -> void:
	super._ready()
	_setup_area()


func _setup_area() -> void:
	_area = Area3D.new()
	_area.name = "Area"
	_area.collision_layer = 0
	# Monitor players (layer 2), bots (layer 4), enemies (layer 8)
	_area.collision_mask = 2 | 4 | 8
	_area.monitorable = false

	_col_shape = CollisionShape3D.new()
	_col_shape.name = "Shape"
	_box_shape = BoxShape3D.new()
	_box_shape.size = volume_size
	_col_shape.shape = _box_shape
	_area.add_child(_col_shape)
	add_child(_area)

	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)


func _update_shape() -> void:
	if _box_shape != null:
		_box_shape.size = volume_size
	if _editor_visual != null and _editor_visual.mesh is BoxMesh:
		(_editor_visual.mesh as BoxMesh).size = volume_size


func _create_editor_visual() -> void:
	if _editor_visual != null:
		return
	_editor_visual = MeshInstance3D.new()
	_editor_visual.name = "EditorVisual"
	var box := BoxMesh.new()
	box.size = volume_size
	_editor_visual.mesh = box

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = get_node_color()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_editor_visual.material_override = mat
	add_child(_editor_visual)


func get_node_color() -> Color:
	return Color(0.15, 0.85, 0.35, 0.35)


func get_input_actions() -> Array[String]:
	return ["activate", "deactivate", "reset"]


func get_output_signals() -> Array[String]:
	return ["on_player_entered", "on_player_exited", "on_triggered"]


func _matches_filter(body: Node) -> bool:
	if not is_active:
		return false
	match filter:
		"player":
			return body is Player or body.is_in_group(&"players")
		"bot":
			return body.is_in_group(&"bots")
		"enemy":
			return body is Enemy or body.is_in_group(&"enemies")
		"any", "all":
			return true
	return false


func _on_body_entered(body: Node) -> void:
	if _matches_filter(body):
		if trigger_once and _triggered:
			return
		_triggered = true
		on_player_entered.emit(body)
		on_triggered.emit()


func _on_body_exited(body: Node) -> void:
	if _matches_filter(body):
		on_player_exited.emit(body)


func activate() -> void:
	is_active = true


func deactivate() -> void:
	is_active = false


func reset() -> void:
	_triggered = false
	is_active = true
