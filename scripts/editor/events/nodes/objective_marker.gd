class_name ObjectiveMarker
extends LogicNodeBase
## Waypoint manager for navigation HUD and campaign objectives.

signal on_objective_activated()
signal on_objective_completed()

@export var objective_id: String = "obj_1"
@export var objective_text: String = "Proceed to waypoint"
@export var is_active: bool = true

var _in_world_marker: Node3D


func _init() -> void:
	super._init()
	display_name = "Objective Marker"


func _ready() -> void:
	super._ready()
	if not has_meta(&"editor_mode") or not bool(get_meta(&"editor_mode")):
		_setup_waypoint_visual()


func _setup_waypoint_visual() -> void:
	_in_world_marker = Node3D.new()
	_in_world_marker.name = "WaypointVisual"

	var mesh_inst := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.8
	torus.outer_radius = 1.0
	mesh_inst.mesh = torus

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.85)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = mat

	_in_world_marker.add_child(mesh_inst)
	add_child(_in_world_marker)
	_in_world_marker.visible = is_active


func get_node_color() -> Color:
	return Color(1.0, 0.85, 0.1, 0.9)


func get_input_actions() -> Array[String]:
	return ["activate", "complete", "hide_marker"]


func get_output_signals() -> Array[String]:
	return ["on_objective_activated", "on_objective_completed"]


func activate() -> void:
	is_active = true
	if _in_world_marker != null:
		_in_world_marker.visible = true
	on_objective_activated.emit()


func complete() -> void:
	is_active = false
	if _in_world_marker != null:
		_in_world_marker.visible = false
	on_objective_completed.emit()


func hide_marker() -> void:
	is_active = false
	if _in_world_marker != null:
		_in_world_marker.visible = false
