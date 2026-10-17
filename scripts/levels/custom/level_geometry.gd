class_name LevelGeometry
extends StaticBody3D
## One piece of custom-level geometry (LevelShapes kind at any size, with a prototype
## material). Resizing rebuilds the mesh and the collision instead of scaling the node, so
## physics stays exact and the world-triplanar grid keeps its true 1 m spacing. Static, on the
## World layer (1): players walk on it, bullets stop on it, the navmesh bakes from it.

const MATERIAL_DIR := "res://resources/materials/prototype/"
const DEFAULT_MATERIAL := "mat_grid_dark_1m"

static var _materials: Dictionary = {}
static var _material_ids: Array[String] = []

@export var shape_kind: String = "box":
	set(value):
		shape_kind = value
		_dirty()
@export var size: Vector3 = Vector3(2.0, 1.0, 2.0):
	set(value):
		size = value.max(Vector3.ONE * LevelShapes.MIN_SIZE)
		_dirty()
@export var material_id: String = DEFAULT_MATERIAL:
	set(value):
		material_id = value
		_apply_material()
## Shape options (stairs: steps; doorway: door_width / door_height; window: window_*).
@export var params: Dictionary = {}:
	set(value):
		params = value
		_dirty()

var _mesh: MeshInstance3D


func _init() -> void:
	collision_layer = 1
	collision_mask = 0


func _ready() -> void:
	rebuild()


## Rebuilds the mesh and collision from shape_kind, size and params.
func rebuild() -> void:
	for child in get_children():
		if child.has_meta(&"level_geometry_part"):
			remove_child(child)
			child.free()
	var built := LevelShapes.build(shape_kind, size, params)
	_mesh = MeshInstance3D.new()
	_mesh.name = "Mesh"
	_mesh.mesh = built.mesh
	_mesh.set_meta(&"level_geometry_part", true)
	add_child(_mesh)
	var i := 0
	for pair: Array in built.shapes:
		var collider := CollisionShape3D.new()
		collider.name = "Shape%d" % i
		collider.shape = pair[0]
		collider.transform = pair[1]
		collider.set_meta(&"level_geometry_part", true)
		add_child(collider)
		i += 1
	_apply_material()


func get_mesh_instance() -> MeshInstance3D:
	return _mesh


func _dirty() -> void:
	if is_inside_tree():
		rebuild()


func _apply_material() -> void:
	if _mesh != null:
		_mesh.material_override = material(material_id)


## A prototype material by id (file name without .tres), cached; the default if unknown.
static func material(id: String) -> Material:
	if _materials.has(id):
		return _materials[id]
	var path := MATERIAL_DIR + id + ".tres"
	var mat: Material = load(path) as Material if ResourceLoader.exists(path) else null
	if mat == null and id != DEFAULT_MATERIAL:
		return material(DEFAULT_MATERIAL)
	_materials[id] = mat
	return mat


## Every prototype material id, sorted (works in exported builds: .remap names too).
static func material_ids() -> Array[String]:
	if not _material_ids.is_empty():
		return _material_ids
	for file in LevelCatalog.list_resources(MATERIAL_DIR, ["tres"]):
		_material_ids.append(file.get_file().get_basename())
	_material_ids.sort()
	return _material_ids
