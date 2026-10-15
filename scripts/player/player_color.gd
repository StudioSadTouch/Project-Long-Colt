class_name PlayerColor
extends RefCounted
## Halo-style armor colors and the body tint applier (static only).
## Contract with LC Modeler (player_model.tscn): the character scene is instanced as
## `PlayerModel` directly under the Player / Bot root and implements
##   set_primary_color(color)         primary armor tint (instance uniform primary_color)
##   set_accent_color(color)          optional, team accent slot (unused in FFA)
##   first_person_hidden: bool        false = meshes on render layer 1 (visible to everyone),
##                                    true = layer 2; only the LOCAL player's model sets it, and
##                                    every gameplay camera culls layer 2.
## The capsule placeholder (player_body_fallback.tscn) implements the same API.
## Colours are sRGB Color values, passed through as-is (no srgb_to_linear here): the model's
## shader owns any colour-space conversion of its primary_color uniform.

## Preset palette, Halo 3-ish armor primaries. Order is the menu order; index is not sent on
## the wire (the color itself is), so presets can be retuned freely.
const PRESETS: Array[Dictionary] = [
	{"name": "Steel", "color": Color(0.43, 0.46, 0.5)},
	{"name": "Red", "color": Color(0.62, 0.12, 0.1)},
	{"name": "Blue", "color": Color(0.14, 0.26, 0.6)},
	{"name": "Green", "color": Color(0.2, 0.42, 0.17)},
	# LC Modeler's default primary (#4a5039), so an untinted model and "Olive" match.
	{"name": "Olive", "color": Color(0.290196, 0.313725, 0.223529)},
	{"name": "Orange", "color": Color(0.82, 0.42, 0.1)},
	{"name": "Gold", "color": Color(0.8, 0.64, 0.2)},
	{"name": "Purple", "color": Color(0.38, 0.2, 0.55)},
	{"name": "White", "color": Color(0.86, 0.86, 0.84)},
	{"name": "Black", "color": Color(0.11, 0.11, 0.12)},
	{"name": "Brown", "color": Color(0.4, 0.27, 0.15)},
	{"name": "Cobalt", "color": Color(0.24, 0.38, 0.72)},
	{"name": "Pink", "color": Color(0.86, 0.45, 0.62)},
	{"name": "Sage", "color": Color(0.5, 0.58, 0.45)},
]
const DEFAULT_PRESET := 4
## Team accent slot, for team modes later (FFA leaves the model's default accent).
const TEAM_RED_ACCENT := Color(0.7, 0.1, 0.08)
const TEAM_BLUE_ACCENT := Color(0.1, 0.25, 0.75)
const MODEL_NODE := ^"PlayerModel"
const PRIMARY_PARAM := &"primary_color"


static func default_color() -> Color:
	return PRESETS[DEFAULT_PRESET].color


## Index of the preset equal to color, or -1 (custom).
static func preset_index(color: Color) -> int:
	for i in PRESETS.size():
		if (PRESETS[i].color as Color).is_equal_approx(color):
			return i
	return -1


## The body model of target (target itself if it is the model, else its PlayerModel child).
static func model_of(target: Node) -> Node:
	if target == null:
		return null
	if target.has_method(&"set_primary_color") and not target is CharacterBody3D:
		return target
	return target.get_node_or_null(MODEL_NODE)


## Tints target's body: PlayerModel.set_primary_color when present; else the primary_color
## instance uniform on ShaderMaterial geometry under the model; else (plain meshes, e.g. a
## capsule) a per-instance copy of each StandardMaterial3D with that albedo.
static func apply(target: Node, color: Color) -> void:
	var model := model_of(target)
	if model == null:
		return
	if model.has_method(&"set_primary_color"):
		model.call(&"set_primary_color", color)
		return
	for node in model.find_children("*", "GeometryInstance3D", true, false):
		tint_geometry(node as GeometryInstance3D, color)


## Team accent; no-op on models without set_accent_color.
static func apply_accent(target: Node, color: Color) -> void:
	var model := model_of(target)
	if model != null and model.has_method(&"set_accent_color"):
		model.call(&"set_accent_color", color)


## Local player only: move the body to render layer 2 (culled by gameplay cameras).
static func set_first_person_hidden(target: Node, hidden: bool) -> void:
	var model := model_of(target)
	if model != null and &"first_person_hidden" in model:
		model.set(&"first_person_hidden", hidden)


static func tint_geometry(geometry: GeometryInstance3D, color: Color) -> void:
	if geometry == null:
		return
	var material := geometry.material_override
	var mesh_instance := geometry as MeshInstance3D
	if material == null and mesh_instance != null and mesh_instance.mesh != null:
		if mesh_instance.mesh.get_surface_count() > 0:
			material = mesh_instance.get_active_material(0)
	if material is ShaderMaterial:
		geometry.set_instance_shader_parameter(PRIMARY_PARAM, Vector3(color.r, color.g, color.b))
	elif material is StandardMaterial3D:
		var copy := material.duplicate() as StandardMaterial3D
		copy.albedo_color = color
		geometry.material_override = copy
