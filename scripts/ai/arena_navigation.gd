class_name ArenaNavigation
extends NavigationRegion3D
## Runtime navmesh bake for an arena level (Godot isn't run in our pipeline, so nothing is
## prebaked). In _ready it parses the level's static colliders on the World layer and bakes
## asynchronously; `baked` fires once the region has the mesh. NavigationLink3D children
## (lift, drops, jumps) are written by the level generators (tools/lockout/build_lockout_greybox.py,
## tools/headlong/build_headlong.py).
## The baked mesh is in the level root's local space, so the region copies its transform.

signal baked

@export var geometry_root: NodePath = ^"../Lockout"
@export var agent_radius: float = 0.408
@export var agent_height: float = 2.1
@export var agent_max_climb: float = 0.35  # = step-up height (Player.step_height, Bot.STEP_HEIGHT)
@export var agent_max_slope: float = 45.0
@export var geometry_mask: int = 1

var is_baked: bool = false


func _ready() -> void:
	var root := get_node_or_null(geometry_root) as Node3D
	if root == null:
		push_error("ArenaNavigation: geometry_root %s not found" % geometry_root)
		return
	var map := get_world_3d().navigation_map
	var cell_h: float = ProjectSettings.get_setting("navigation/3d/default_cell_height", 0.05)
	var cell_s: float = ProjectSettings.get_setting("navigation/3d/default_cell_size", 0.2)
	NavigationServer3D.map_set_cell_height(map, cell_h)
	NavigationServer3D.map_set_cell_size(map, cell_s)
	var mesh := NavigationMesh.new()
	mesh.cell_size = cell_s
	mesh.cell_height = cell_h
	var climb_cells := agent_max_climb / mesh.cell_height
	if absf(climb_cells - roundf(climb_cells)) > 0.01:
		push_warning(
			(
				"ArenaNavigation: agent_max_climb %.2f is not a multiple of cell_height %.2f"
				% [agent_max_climb, mesh.cell_height]
			)
		)
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
