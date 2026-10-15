class_name PlayerModel
extends Node3D
## Third-person body for the player (block-out v1). Instanced as `PlayerModel` directly under
## the Player CharacterBody3D: origin at the feet, -Z forward, 1.81 m to the helmet crown,
## visor centre at y 1.60 (camera eye 1.62).
##
## Tint contract (LC Programmer): callers only use set_primary_color(). It writes the
## `primary_color` instance uniform on every primary-armor MeshInstance3D; the shared
## player_armor_primary.tres is never duplicated, so each player tints separately for free.
## set_visor_color() does the same for the visor (`visor_color` on the shared player_visor.tres).
## set_accent_color() does the same for the team accent (`accent_color` on the shared
## player_accent.tres): PB_Pauldron_L and PB_HelmetStripe_L.
##
## The meshes come from res://assets/models/characters/player_blockout.glb (parts PB_*). The
## head is real hierarchy: BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest/PB_Neck/PB_Head, with the
## dummy_rig slot groups NeckMesh (under PB_Neck), HelmetMesh and VisorMesh (under PB_Head), so
## posing the chest or neck carries the head. Mesh lookup is a recursive walk, so the tint and
## layer setters reach every mesh wherever it sits. Markers: .../PB_Hand_R/WeaponAttach_R and
## .../PB_Hand_L/OffHand_L (Node3D, -Z along the barrel / forward, +Y up). On _ready the
## glb's four imported materials are swapped, by material name, for the project materials
## below.
##
## Render layers (first_person_hidden): false (default, remote players, bots) puts every mesh
## on layer 1 only; true (set on the LOCAL player only) puts every mesh on layer 2 only, so the
## first-person camera can drop layer 2 from its cull_mask. cast_shadow is SHADOW_CASTING_SETTING_ON
## in both states, so the local player still casts its own shadow.

const PRIMARY_MATERIAL := preload(
	"res://assets/characters/player/materials/player_armor_primary.tres"
)
const SECONDARY_MATERIAL := preload(
	"res://assets/characters/player/materials/player_armor_secondary.tres"
)
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
const ACCENT_PARAM := &"accent_color"
const VISOR_PARAM := &"visor_color"
## Field olive #4a5039, same as the shader default.
const DEFAULT_PRIMARY := Color(0.290196, 0.313725, 0.223529)
## Stencil red #b3261e, same as the shader default.
const DEFAULT_ACCENT := Color(0.701961, 0.149020, 0.117647)
## Amber gold #a87a1e, same as the shader default.
const DEFAULT_VISOR := Color(0.658824, 0.478431, 0.117647)

const LAYERS_VISIBLE := 1  ## layer 1 only
const LAYERS_FIRST_PERSON_HIDDEN := 2  ## layer 2 only

## True on the local player only: meshes go to layer 2 so its own camera can cull them.
## Safe to set at runtime and before _ready (re-applied in _ready).
@export var first_person_hidden: bool = false:
	set = set_first_person_hidden
@export var primary_color: Color = DEFAULT_PRIMARY
@export var accent_color: Color = DEFAULT_ACCENT
@export var visor_color: Color = DEFAULT_VISOR

var _primary_meshes: Array[MeshInstance3D] = []
var _accent_meshes: Array[MeshInstance3D] = []
var _visor_meshes: Array[MeshInstance3D] = []
var _all_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	_collect(self)
	if _primary_meshes.is_empty():
		push_warning("PlayerModel: no mat_armor meshes found; primary tint will do nothing.")
	if _accent_meshes.is_empty():
		push_warning("PlayerModel: no mat_accent meshes found; accent tint will do nothing.")
	set_primary_color(primary_color)
	set_accent_color(accent_color)
	set_visor_color(visor_color)
	_apply_layers()


## The only tint entry point. Safe to call before the node is in the tree (applied in _ready).
func set_primary_color(color: Color) -> void:
	primary_color = color
	# A Color (not Vector3) so the source_color uniform gets its sRGB -> linear conversion;
	# a Vector3 is taken as linear and the armor renders washed out.
	var value := Color(color.r, color.g, color.b)
	for mesh: MeshInstance3D in _primary_meshes:
		mesh.set_instance_shader_parameter(PRIMARY_PARAM, value)


## Team accent. Safe to call before the node is in the tree (applied in _ready).
func set_accent_color(color: Color) -> void:
	accent_color = color
	# A Color (not Vector3) so the source_color uniform gets its sRGB -> linear conversion;
	# a Vector3 is taken as linear and the armor renders washed out.
	var value := Color(color.r, color.g, color.b)
	for mesh: MeshInstance3D in _accent_meshes:
		mesh.set_instance_shader_parameter(ACCENT_PARAM, value)


## Visor tint. Safe to call before the node is in the tree (applied in _ready).
func set_visor_color(color: Color) -> void:
	visor_color = color
	var value := Color(color.r, color.g, color.b)  # Color: see set_primary_color
	for mesh: MeshInstance3D in _visor_meshes:
		mesh.set_instance_shader_parameter(VISOR_PARAM, value)


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


## Accent meshes (mat_accent): PB_Pauldron_L, PB_HelmetStripe_L.
func get_accent_meshes() -> Array[MeshInstance3D]:
	return _accent_meshes


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
	elif material == ACCENT_MATERIAL:
		_accent_meshes.append(mesh)
	elif material == VISOR_MATERIAL:
		_visor_meshes.append(mesh)
