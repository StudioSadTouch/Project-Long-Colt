class_name PlayerModel
extends Node3D
## Third-person body for the player: the Hospitaller (tools/hospitaller). Instanced as
## `PlayerModel` directly under the Player CharacterBody3D: origin at the feet, -Z forward,
## ~1.8 m to the helmet crown, visor centre at y 1.60 (camera eye 1.62).
##
## Modular armor: the glb carries every armor variant; meshes named AR_<slot>_<variant>_<piece>
## (ArmorLoadout) are shown only when their variant is the loadout's pick for that slot
## (set_armor_loadout). CORE_* meshes (gloves, boots, neck seal) and the skinned Undersuit
## (the baggy BDU, mat_bdu) always show. Its skeleton follows the PB_* joints through
## BodySkinSync.
##
## Tint contract (LC Programmer): callers only use set_primary_color(). It writes the
## `primary_color` instance uniform on every primary-armor MeshInstance3D; the shared
## player_armor_primary.tres is never duplicated, so each player tints separately for free.
## set_visor_color() does the same for the visor (`visor_color` on the shared player_visor.tres).
## set_accent_color() does the same for the team accent (`accent_color` on the shared
## player_accent.tres): the left shoulder piece and the helmet's left ear pivot.
##
## The meshes come from res://assets/models/characters/hospitaller.glb (instanced as
## `Blockout`, the block-out's node name, so every existing path holds). The joints keep the
## block-out's names, pivots and hierarchy: BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest/PB_Neck/
## PB_Head, so posing the chest or neck carries the head. Mesh lookup is a recursive walk, so the
## tint and layer setters reach every mesh wherever it sits. Markers: .../PB_Hand_R/
## WeaponAttach_R and .../PB_Hand_L/OffHand_L (Node3D, -Z along the barrel / forward, +Y up).
## On _ready every surface's imported material is swapped, by material name, for the project
## materials below (a part may use several).
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
const WEBBING_MATERIAL := preload("res://assets/characters/player/materials/player_webbing.tres")
const FRAME_MATERIAL := preload("res://assets/characters/player/materials/player_frame.tres")
const BDU_MATERIAL := preload("res://assets/characters/player/materials/player_bdu.tres")
## glb material name -> project material. Primary parts are the ones using mat_armor.
const MATERIAL_BY_NAME := {
	&"mat_armor": PRIMARY_MATERIAL,
	&"mat_undersuit": SECONDARY_MATERIAL,
	&"mat_visor": VISOR_MATERIAL,
	&"mat_accent": ACCENT_MATERIAL,
	&"mat_webbing": WEBBING_MATERIAL,
	&"mat_frame": FRAME_MATERIAL,
	&"mat_bdu": BDU_MATERIAL,
}
## Armor mesh name prefix: AR_<slot>_<variant>_<piece>.
const ARMOR_PREFIX := "AR_"
## Vanguard's up-armour plate (AR_helmet_vanguard_visorplate) pivots on the ear hinges about X:
## 0 = down over the visor (NVG in front), PLATE_UP_DEG = flipped up over the crown.
const VISOR_PLATE_TAG := "_visorplate"
const PLATE_UP_DEG := 100.0
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
## Encoded ArmorLoadout ("helmet=warden,chest=exo,..."); empty = the defaults.
@export var armor_loadout: String = ""
## Vanguard's NVG plate flipped up (true) or down over the visor (false).
@export var visor_plate_up: bool = false

var _primary_meshes: Array[MeshInstance3D] = []
var _accent_meshes: Array[MeshInstance3D] = []
var _visor_meshes: Array[MeshInstance3D] = []
var _all_meshes: Array[MeshInstance3D] = []
## slot -> variant -> armor nodes of that variant.
var _armor := {}
var _visor_plates: Array[Node3D] = []
var _loadout: Dictionary = ArmorLoadout.default_loadout()


func _ready() -> void:
	_collect(self)
	if _primary_meshes.is_empty():
		push_warning("PlayerModel: no mat_armor meshes found; primary tint will do nothing.")
	if _accent_meshes.is_empty():
		push_warning("PlayerModel: no mat_accent meshes found; accent tint will do nothing.")
	set_primary_color(primary_color)
	set_accent_color(accent_color)
	set_visor_color(visor_color)
	set_armor_loadout(ArmorLoadout.decode(armor_loadout))
	set_visor_plate_up(visor_plate_up)
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


## Shows one variant per armor slot (ArmorLoadout; invalid entries fall back to the defaults).
## Safe to call before the node is in the tree (applied in _ready).
func set_armor_loadout(loadout: Dictionary) -> void:
	_loadout = ArmorLoadout.sanitize(loadout)
	armor_loadout = ArmorLoadout.encode(_loadout)
	for slot: String in _armor:
		for variant: String in _armor[slot]:
			var shown: bool = _loadout.get(slot, "") == variant
			for node: Node3D in _armor[slot][variant]:
				node.visible = shown


func get_armor_loadout() -> Dictionary:
	return _loadout.duplicate()


## Vanguard's up-armour plate: flipped up over the crown, or down over the visor.
func set_visor_plate_up(up: bool) -> void:
	visor_plate_up = up
	for plate: Node3D in _visor_plates:
		plate.rotation = Vector3(deg_to_rad(PLATE_UP_DEG) if up else 0.0, 0.0, 0.0)


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


## Accent meshes (meshes with a mat_accent surface): the left shoulder piece of every shoulder
## variant and the left ear pivot of every helmet.
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
		if child is Node3D and String(child.name).begins_with(ARMOR_PREFIX):
			_register_armor(child as Node3D)
		_collect(child)


## AR_<slot>_<variant>_<piece>: file the node under its slot and variant.
func _register_armor(node: Node3D) -> void:
	var bits := String(node.name).split("_")
	if bits.size() < 4:
		return
	var slot := bits[1]
	var variant := bits[2]
	if not _armor.has(slot):
		_armor[slot] = {}
	if not _armor[slot].has(variant):
		_armor[slot][variant] = []
	_armor[slot][variant].append(node)
	if String(node.name).ends_with(VISOR_PLATE_TAG):
		_visor_plates.append(node)


func _setup_mesh(mesh: MeshInstance3D) -> void:
	_all_meshes.append(mesh)
	for surface in mesh.mesh.get_surface_count():
		var source := mesh.mesh.surface_get_material(surface)
		var key := StringName(source.resource_name) if source != null else &""
		var material: Material = MATERIAL_BY_NAME.get(key)
		if material == null:
			push_warning("PlayerModel: %s has unknown material '%s'." % [mesh.name, key])
			continue
		mesh.set_surface_override_material(surface, material)
		if material == PRIMARY_MATERIAL and not _primary_meshes.has(mesh):
			_primary_meshes.append(mesh)
		elif material == ACCENT_MATERIAL and not _accent_meshes.has(mesh):
			_accent_meshes.append(mesh)
		elif material == VISOR_MATERIAL and not _visor_meshes.has(mesh):
			_visor_meshes.append(mesh)
