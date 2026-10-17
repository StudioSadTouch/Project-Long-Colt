class_name LevelMaterials
extends Node
## Automatically applies rich triplanar PBR prototype textures and sets cull_mode = CULL_BACK
## across all greybox level meshes on _ready().

const MATERIAL_MAP := {
	"mat_floor": preload("res://resources/materials/prototype/mat_grid_dark_1m.tres"),
	"mat_deck": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_wall": preload("res://resources/materials/prototype/mat_concrete_dark.tres"),
	"mat_ramp": preload("res://resources/materials/prototype/mat_grid_orange_1m.tres"),
	"mat_catwalk": preload("res://resources/materials/prototype/mat_metal_deck.tres"),
	"mat_cover": preload("res://resources/materials/prototype/mat_scifi_panel.tres"),
	"mat_light": preload("res://resources/materials/prototype/mat_grid_light_1m.tres"),
	"mat_lift": preload("res://resources/materials/prototype/mat_grid_orange_05m.tres"),
	"mat_oob": preload("res://resources/materials/prototype/mat_grid_red_1m.tres"),
	"mat_snow": preload("res://resources/materials/prototype/mat_grid_light_1m.tres"),
	"mat_ground": preload("res://resources/materials/prototype/mat_grid_dark_1m.tres"),
	"mat_road": preload("res://resources/materials/prototype/mat_concrete_dark.tres"),
	"mat_sea": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_pit": preload("res://resources/materials/prototype/mat_grid_red_1m.tres"),
	"mat_statue": preload("res://resources/materials/prototype/mat_scifi_trim.tres"),
	"mat_tele": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_bridge": preload("res://resources/materials/prototype/mat_metal_deck.tres"),
	"mat_city": preload("res://resources/materials/prototype/mat_concrete_dark.tres"),
	"mat_dark": preload("res://resources/materials/prototype/mat_grid_dark_05m.tres"),
	"mat_grass": preload("res://resources/materials/prototype/mat_grid_green_1m.tres"),
	"mat_lamp": preload("res://resources/materials/prototype/mat_grid_light_05m.tres"),
	"mat_pad": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_palm": preload("res://resources/materials/prototype/mat_grid_green_1m.tres"),
	"mat_plaza": preload("res://resources/materials/prototype/mat_grid_dark_1m.tres"),
	"mat_rail": preload("res://resources/materials/prototype/mat_scifi_trim.tres"),
	"mat_rock": preload("res://resources/materials/prototype/mat_concrete_dark.tres"),
	"mat_sand": preload("res://resources/materials/prototype/mat_grid_light_1m.tres"),
	"mat_seawall": preload("res://resources/materials/prototype/mat_concrete_dark.tres"),
	"mat_surf": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_tank": preload("res://resources/materials/prototype/mat_metal_deck.tres"),
	"mat_trim": preload("res://resources/materials/prototype/mat_scifi_trim.tres"),
	"mat_under": preload("res://resources/materials/prototype/mat_grid_dark_1m.tres"),
	"mat_water": preload("res://resources/materials/prototype/mat_grid_blue_1m.tres"),
	"mat_wheel": preload("res://resources/materials/prototype/mat_metal_deck.tres"),
	"mat_wood": preload("res://resources/materials/prototype/mat_scifi_panel.tres"),
}


func _ready() -> void:
	apply(get_parent() if get_parent() else self)


## Walks all MeshInstance3Ds in root and assigns prototype PBR materials with backface culling.
static func apply(root: Node) -> void:
	if not root:
		return
	var meshes: Array[Node] = root.find_children("*", "MeshInstance3D", true, false)
	for mesh_node in meshes:
		var m := mesh_node as MeshInstance3D
		if not m or not m.mesh:
			continue
		for s in m.mesh.get_surface_count():
			var orig := m.mesh.surface_get_material(s)
			var mat_name := orig.resource_name if orig else ""
			if MATERIAL_MAP.has(mat_name):
				var target_mat: StandardMaterial3D = MATERIAL_MAP[mat_name]
				# Ensure backface culling is strictly enforced to prevent overlap flickering
				target_mat.cull_mode = BaseMaterial3D.CULL_BACK
				m.set_surface_override_material(s, target_mat)
			elif orig is BaseMaterial3D:
				(orig as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_BACK
