class_name PlayerModel
extends Node3D
## Third-person body for the player (block-out v1). Instanced as `PlayerModel` directly under
## the Player CharacterBody3D: origin at the feet, -Z forward, 1.81 m to the helmet crown,
## visor centre at y 1.60 (camera eye 1.62).
##
## Tint contract (LC Programmer): callers only use set_primary_color(). It writes the
## `primary_color` instance uniform on every primary-armor MeshInstance3D; the shared
## player_armor_primary.tres is never duplicated, so each player tints separately for free.
##
## The meshes come from res://assets/models/characters/player_blockout.glb (parts PB_*,
## grouped BodyMesh / NeckMesh / HelmetMesh / VisorMesh like dummy_rig.tscn). On _ready the
## glb's four imported materials are swapped, by material name, for the project materials
## below.
##
## Render layers (first_person_hidden): false (default, remote players, bots) puts every mesh
## on layer 1 only; true (set on the LOCAL player only) puts every mesh on layer 2 only, so the
## first-person camera can drop layer 2 from its cull_mask. cast_shadow is SHADOW_CASTING_SETTING_ON
## in both states, so the local player still casts its own shadow.

const PRIMARY_MATERIAL := preload("res://assets/characters/player/materials/player_armor_primary.tres")
const SECONDARY_MATERIAL := preload("res://assets/characters/player/materials/player_armor_secondary.tres")
const VISOR_MATERIAL := preload("res://assets/characters/player/materials/player_visor.tres")
const ACCENT_MATERIAL := preload("res://assets/characters/player/materials/player_accent.tres")
## glb material name -> project material. Primary parts are the ones using mat_armor.
const MATERIAL_BY_NAME := {
	&"mat_armor": PRIMARY_MATERIAL,
	&"mat_undersuit": SECONDARY_MATERIAL,
	&"mat_visor": VISOR_MATERIAL,
	&"mat_accent": ACCENT_MATERIAL,
}
const PRIMARY_PARAM := &"primary_color"
## Field olive #4a5039, same as the shader default.
const DEFAULT_PRIMARY := Color(0.290196, 0.313725, 0.223529)

const LAYERS_VISIBLE := 1  ## layer 1 only
const LAYERS_FIRST_PERSON_HIDDEN := 2  ## layer 2 only

## True on the local player only: meshes go to layer 2 so its own camera can cull them.
## Safe to set at runtime and before _ready (re-applied in _ready).
@export var first_person_hidden: bool = false:
	set = set_first_person_hidden
@export var primary_color: Color = DEFAULT_PRIMARY

var _primary_meshes: Array[MeshInstance3D] = []
var _all_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_collect(self)
	if _primary_meshes.is_empty():
		push_warning("PlayerModel: no mat_armor meshes found; primary tint will do nothing.")
	set_primary_color(primary_color)
	_apply_layers()


## The only tint entry point. Safe to call before the node is in the tree (applied in _ready).
func set_primary_color(color: Color) -> void:
	primary_color = color
	var value := Vector3(color.r, color.g, color.b)
	for mesh: MeshInstance3D in _primary_meshes:
		mesh.set_instance_shader_parameter(PRIMARY_PARAM, value)


func set_first_person_hidden(hidden: bool) -> void:
	first_person_hidden = hidden
	_apply_layers()


func _apply_layers() -> void:
	var layer_bits := LAYERS_FIRST_PERSON_HIDDEN if first_person_hidden else LAYERS_VISIBLE
	for mesh: MeshInstance3D in _all_meshes:
		mesh.layers = layer_bits
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## Primary-armor meshes (mat_armor), e.g. for outlines or hit flashes.
func get_primary_meshes() -> Array[MeshInstance3D]:
	return _primary_meshes


## Every model mesh.
func get_meshes() -> Array[MeshInstance3D]:
	return _all_meshes


func _collect(node: Node) -> void:
	for child: Node in node.get_children():
		var mesh := child as MeshInstance3D
		if mesh != null and mesh.mesh != null:
			_setup_mesh(mesh)
		_collect(child)


func _setup_mesh(mesh: MeshInstance3D) -> void:
	_all_meshes.append(mesh)
	var source := mesh.mesh.surface_get_material(0)
	var key := StringName(source.resource_name) if source != null else &""
	var material: Material = MATERIAL_BY_NAME.get(key)
	if material == null:
		push_warning("PlayerModel: %s has unknown material '%s'." % [mesh.name, key])
		return
	mesh.material_override = material
	if material == PRIMARY_MATERIAL:
		_primary_meshes.append(mesh)
