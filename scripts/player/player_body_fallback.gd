class_name PlayerBodyFallback
extends Node3D
## Capsule placeholder body until LC Modeler's player_model.tscn lands. Same API and node name
## (PlayerModel) as the real model, so PlayerColor and Player treat both alike:
##   set_primary_color(color), set_accent_color(color), first_person_hidden (layer 1 / 2).
## Origin at the feet, -Z forward, 2.1 m tall. Under the Player root (not the Rig), so it doesn't
## crouch; hitboxes are separate and unaffected.

const VISIBLE_LAYER := 1
const HIDDEN_LAYER := 1 << 1

## true = meshes on render layer 2 (local first-person body; gameplay cameras cull it).
@export var first_person_hidden: bool = false:
	set(value):
		first_person_hidden = value
		_apply_layers()
@export var primary_color: Color = Color(0.290196, 0.313725, 0.223529):
	set(value):
		primary_color = value
		_apply_material(^"Body", value)
@export var accent_color: Color = Color(0.701961, 0.14902, 0.117647):
	set(value):
		accent_color = value
		_apply_material(^"Accent", value)


func _ready() -> void:
	_apply_layers()
	_apply_material(^"Body", primary_color)
	_apply_material(^"Accent", accent_color)


func set_primary_color(color: Color) -> void:
	primary_color = color


func set_accent_color(color: Color) -> void:
	accent_color = color


func _apply_layers() -> void:
	if not is_inside_tree():
		return
	var layer := HIDDEN_LAYER if first_person_hidden else VISIBLE_LAYER
	for node in find_children("*", "VisualInstance3D", true, false):
		(node as VisualInstance3D).layers = layer


func _apply_material(path: NodePath, color: Color) -> void:
	var mesh := get_node_or_null(path) as MeshInstance3D
	if mesh == null:
		return
	# Own copy per instance, so each player tints separately.
	var material := mesh.material_override as StandardMaterial3D
	if material == null or not material.resource_local_to_scene:
		var source := mesh.get_active_material(0) as StandardMaterial3D
		material = source.duplicate() as StandardMaterial3D if source else StandardMaterial3D.new()
		material.resource_local_to_scene = true
		mesh.material_override = material
	material.albedo_color = color
