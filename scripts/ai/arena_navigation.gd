class_name ArenaNavigation
extends NavigationRegion3D
## Runtime navmesh bake for an arena level (Godot isn't run in our pipeline, so nothing is
## prebaked). In _ready it parses the level's static colliders on the World layer and bakes
## asynchronously; `baked` fires once the region has the mesh. NavigationLink3D children
## (lift, drops, jumps) are placed by tools/lockout/emit_arena_tscn.py.
## The baked mesh is in the level root's local space, so the region copies its transform.

signal baked

@export var geometry_root: NodePath = ^"../Lockout"
@export var agent_radius: float = 0.35
@export var agent_height: float = 1.8
@export var agent_max_climb: float = 0.25
@export var agent_max_slope: float = 45.0
@export var geometry_mask: int = 1

var is_baked: bool = false


func _ready() -> void:
	var root := get_node_or_null(geometry_root) as Node3D
	if root == null:
		push_error("ArenaNavigation: geometry_root %s not found" % geometry_root)
		return
	var map := get_world_3d().navigation_map
	var mesh := NavigationMesh.new()
	# Match the map's cell size, or the region won't merge with links cleanly.
	mesh.cell_size = NavigationServer3D.map_get_cell_size(map)
	mesh.cell_height = NavigationServer3D.map_get_cell_height(map)
	mesh.agent_radius = agent_radius
	mesh.agent_height = agent_height
	mesh.agent_max_climb = agent_max_climb
	mesh.agent_max_slope = agent_max_slope
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = geometry_mask
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var source := NavigationMeshSourceGeometryData3D.new()
	# Parsing must happen on the main thread; baking runs on a worker.
	NavigationServer3D.parse_source_geometry_data(mesh, source, root)
	global_transform = root.global_transform
	NavigationServer3D.bake_from_source_geometry_data_async(
		mesh, source, func() -> void: _finish.call_deferred(mesh)
	)


func _finish(mesh: NavigationMesh) -> void:
	navigation_mesh = mesh
	is_baked = true
	if mesh.get_polygon_count() == 0:
		push_warning("ArenaNavigation: bake produced no polygons; bots will stand still")
	else:
		print("[Arena] navmesh baked: %d polygons" % mesh.get_polygon_count())
	# Give the navigation map one physics frame to sync the new region before anyone paths.
	await get_tree().physics_frame
	await get_tree().physics_frame
	baked.emit()
