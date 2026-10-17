class_name LogicNodeBase
extends Node3D
## Base class for visual campaign logic and event scripting nodes.
## Visualized as color-coded billboard holograms in Edit Mode; disabled/hidden in Playtest Mode.

@export var node_uid: String = ""
@export var display_name: String = "Logic Node"

var _editor_visual: MeshInstance3D


func _init() -> void:
	set_meta(&"logic_node", true)
	set_meta(&"level_object", true)


func _ready() -> void:
	if has_meta(&"editor_mode") and bool(get_meta(&"editor_mode")):
		_create_editor_visual()


func _create_editor_visual() -> void:
	if _editor_visual != null:
		return
	_editor_visual = MeshInstance3D.new()
	_editor_visual.name = "EditorVisual"
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.6, 0.6)
	_editor_visual.mesh = box

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = get_node_color()
	_editor_visual.material_override = mat
	add_child(_editor_visual)


func get_node_color() -> Color:
	return Color(0.2, 0.7, 1.0, 0.85)


func get_input_actions() -> Array[String]:
	return ["trigger"]


func get_output_signals() -> Array[String]:
	return []


func execute_action(action_name: String, _params: Dictionary = {}) -> void:
	if has_method(action_name):
		call(action_name)
