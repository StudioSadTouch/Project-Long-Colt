class_name LevelEditorCatalog
extends RefCounted
## Object Palette / Catalog for Project Long Colt Level Editor.
## Defines catalog items across Geometry, Gameplay, Weapons, Vehicles, and Lighting,
## along with instantiation and ghost preview generators.

const CATEGORIES := ["Geometry", "Gameplay", "Weapons", "Vehicles", "Lighting"]

const GHOST_COLOR := Color(0.18, 0.82, 0.98, 0.45)
const GHOST_INVALID_COLOR := Color(0.95, 0.25, 0.2, 0.45)

static var _ghost_mat: StandardMaterial3D
static var _geo_mat_cube: StandardMaterial3D
static var _geo_mat_platform: StandardMaterial3D
static var _geo_mat_wall: StandardMaterial3D
static var _geo_mat_ramp: StandardMaterial3D
static var _geo_mat_pillar: StandardMaterial3D
static var _geo_mat_crate: StandardMaterial3D


static func get_ghost_material(valid: bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = GHOST_COLOR if valid else GHOST_INVALID_COLOR
	return mat


static func _get_mat(albedo: Color, rough: float = 0.7, metal: float = 0.15) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = rough
	mat.metallic = metal
	return mat


static func get_catalog_items() -> Array[Dictionary]:
	return [
		# Geometry Blocks
		{
			"id": "cube_1x1x1",
			"name": "1x1x1 Cube",
			"category": "Geometry",
			"dimensions": Vector3(1.0, 1.0, 1.0),
			"icon_hint": "Cube",
		},
		{
			"id": "platform_2x1x2",
			"name": "2x1x2 Platform",
			"category": "Geometry",
			"dimensions": Vector3(2.0, 1.0, 2.0),
			"icon_hint": "Platform",
		},
		{
			"id": "wall_4x3",
			"name": "4x3x0.5 Wall",
			"category": "Geometry",
			"dimensions": Vector3(4.0, 3.0, 0.5),
			"icon_hint": "Wall",
		},
		{
			"id": "ramp",
			"name": "Ramp (Wedge)",
			"category": "Geometry",
			"dimensions": Vector3(2.0, 1.5, 3.0),
			"icon_hint": "Ramp",
		},
		{
			"id": "pillar",
			"name": "Pillar",
			"category": "Geometry",
			"dimensions": Vector3(1.0, 4.0, 1.0),
			"icon_hint": "Pillar",
		},
		{
			"id": "cover_crate",
			"name": "Cover Crate",
			"category": "Geometry",
			"dimensions": Vector3(1.2, 1.0, 0.8),
			"icon_hint": "Crate",
		},

		# Gameplay Spawns
		{
			"id": "spawn_ffa",
			"name": "Player Spawn (FFA)",
			"category": "Gameplay",
			"dimensions": Vector3(1.2, 0.1, 1.2),
			"icon_hint": "Spawn FFA",
		},
		{
			"id": "spawn_red",
			"name": "Player Spawn (Red)",
			"category": "Gameplay",
			"dimensions": Vector3(1.2, 0.1, 1.2),
			"icon_hint": "Spawn Red",
		},
		{
			"id": "spawn_blue",
			"name": "Player Spawn (Blue)",
			"category": "Gameplay",
			"dimensions": Vector3(1.2, 0.1, 1.2),
			"icon_hint": "Spawn Blue",
		},

		# Weapon Pickups
		{
			"id": "pickup_carbine",
			"name": "Marksman Carbine Rack",
			"category": "Weapons",
			"scene_path": "res://scenes/weapons/marksman_carbine.tscn",
			"dimensions": Vector3(1.0, 0.8, 1.0),
			"icon_hint": "Carbine",
		},
		{
			"id": "pickup_shotgun",
			"name": "Combat Shotgun Rack",
			"category": "Weapons",
			"scene_path": "res://scenes/weapons/combat_shotgun.tscn",
			"dimensions": Vector3(1.0, 0.8, 1.0),
			"icon_hint": "Shotgun",
		},
		{
			"id": "pickup_rocket",
			"name": "Rocket Launcher Rack",
			"category": "Weapons",
			"scene_path": "res://scenes/weapons/directed_energy_rifle.tscn",
			"dimensions": Vector3(1.0, 0.8, 1.0),
			"icon_hint": "Rocket",
		},
		{
			"id": "pickup_longsword",
			"name": "Longsword Rack",
			"category": "Weapons",
			"scene_path": "res://scenes/weapons/longsword.tscn",
			"dimensions": Vector3(1.0, 0.8, 1.0),
			"icon_hint": "Longsword",
		},
		{
			"id": "pickup_hammer",
			"name": "Gravity Hammer Rack",
			"category": "Weapons",
			"scene_path": "res://scenes/weapons/gravity_hammer.tscn",
			"dimensions": Vector3(1.0, 0.8, 1.0),
			"icon_hint": "Hammer",
		},
		{
			"id": "pickup_ammo",
			"name": "Ammo Crate",
			"category": "Weapons",
			"scene_path": "res://scenes/pickups/ammo_crate.tscn",
			"dimensions": Vector3(0.8, 0.5, 0.6),
			"icon_hint": "Ammo",
		},

		# Vehicles
		{
			"id": "vehicle_humvee",
			"name": "Humvee Spawn",
			"category": "Vehicles",
			"scene_path": "res://scenes/vehicles/humvee.tscn",
			"dimensions": Vector3(2.4, 2.0, 4.8),
			"icon_hint": "Humvee",
		},

		# Lighting
		{
			"id": "light_worklight",
			"name": "Caged Worklight",
			"category": "Lighting",
			"scene_path": "res://scenes/props/lighting/fixture_caged_worklight.tscn",
			"dimensions": Vector3(0.5, 0.5, 0.5),
			"icon_hint": "Worklight",
		},
		{
			"id": "light_fluoro",
			"name": "Fluorescent Fixture",
			"category": "Lighting",
			"scene_path": "res://scenes/props/lighting/fixture_fluoro_strip.tscn",
			"dimensions": Vector3(1.5, 0.3, 0.3),
			"icon_hint": "Fluorescent",
		},
	]


static func get_item(catalog_id: String) -> Dictionary:
	for item in get_catalog_items():
		if item["id"] == catalog_id:
			return item
	return {}


static func get_items_by_category(category: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item in get_catalog_items():
		if item["category"] == category:
			result.append(item)
	return result


## Builds a concrete wedge ArrayMesh for the ramp.
static func build_ramp_mesh(w: float = 2.0, h: float = 1.5, d: float = 3.0) -> ArrayMesh:
	var hw := w * 0.5
	var hd := d * 0.5

	# Vertices: front at +Z (height 0), back at -Z (height h)
	var v0 := Vector3(-hw, 0.0, hd)   # Front-Left-Bottom
	var v1 := Vector3( hw, 0.0, hd)   # Front-Right-Bottom
	var v2 := Vector3( hw, 0.0, -hd)  # Back-Right-Bottom
	var v3 := Vector3(-hw, 0.0, -hd)  # Back-Left-Bottom
	var v4 := Vector3(-hw, h, -hd)    # Back-Left-Top
	var v5 := Vector3( hw, h, -hd)    # Back-Right-Top

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Slope face (walkway)
	st.set_normal(Vector3(0.0, hd, h).normalized())
	st.set_uv(Vector2(0, 0))
	st.add_vertex(v0)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v5)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(v1)

	st.set_uv(Vector2(0, 0))
	st.add_vertex(v0)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(v4)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v5)

	# Back face
	st.set_normal(Vector3.BACK)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(v3)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(v2)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v5)

	st.set_uv(Vector2(0, 0))
	st.add_vertex(v3)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v5)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(v4)

	# Bottom face
	st.set_normal(Vector3.DOWN)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(v0)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(v1)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v2)

	st.set_uv(Vector2(0, 0))
	st.add_vertex(v0)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v2)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(v3)

	# Left triangular side
	st.set_normal(Vector3.LEFT)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(v0)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(v3)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v4)

	# Right triangular side
	st.set_normal(Vector3.RIGHT)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(v1)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(v5)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(v2)

	st.generate_normals()
	return st.commit()


## Instantiates an in-world object for the editor and gameplay.
static func instantiate_object(catalog_id: String) -> Node3D:
	var item := get_item(catalog_id)
	if item.is_empty():
		push_error("LevelEditorCatalog: Unknown catalog ID '%s'" % catalog_id)
		return null

	var node: Node3D = null

	match catalog_id:
		"cube_1x1x1":
			node = _create_static_box(Vector3(1.0, 1.0, 1.0), Color(0.38, 0.40, 0.42))
		"platform_2x1x2":
			node = _create_static_box(Vector3(2.0, 1.0, 2.0), Color(0.34, 0.37, 0.40))
		"wall_4x3":
			node = _create_static_box(Vector3(4.0, 3.0, 0.5), Color(0.44, 0.46, 0.48))
		"ramp":
			node = _create_static_ramp(Vector3(2.0, 1.5, 3.0), Color(0.40, 0.42, 0.44))
		"pillar":
			node = _create_static_cylinder(0.5, 4.0, Color(0.36, 0.38, 0.40))
		"cover_crate":
			node = _create_cover_crate(Vector3(1.2, 1.0, 0.8))

		"spawn_ffa":
			node = _create_spawn_marker("SPAWN_FFA", Color(0.95, 0.75, 0.15))
		"spawn_red":
			node = _create_spawn_marker("SPAWN_Red", Color(0.9, 0.2, 0.2))
		"spawn_blue":
			node = _create_spawn_marker("SPAWN_Blue", Color(0.2, 0.45, 0.95))

		"pickup_carbine", "pickup_shotgun", "pickup_rocket", "pickup_longsword", "pickup_hammer":
			node = _create_weapon_pickup(item["scene_path"], catalog_id)
		"pickup_ammo":
			node = _create_scene_instance("res://scenes/pickups/ammo_crate.tscn")

		"vehicle_humvee":
			node = _create_scene_instance("res://scenes/vehicles/humvee.tscn")
			if node != null:
				node.set_physics_process(false)

		"light_worklight":
			node = _create_scene_instance("res://scenes/props/lighting/fixture_caged_worklight.tscn", catalog_id)
		"light_fluoro":
			node = _create_scene_instance("res://scenes/props/lighting/fixture_fluoro_strip.tscn", catalog_id)

	if node != null:
		node.set_meta(&"catalog_id", catalog_id)
		node.set_meta(&"level_editor_object", true)
		if not node.has_meta(&"display_name"):
			node.set_meta(&"display_name", item.get("name", catalog_id))

	return node


## Creates a collision-free semi-transparent ghost preview node for placement.
static func create_ghost_visual(catalog_id: String) -> Node3D:
	var item := get_item(catalog_id)
	if item.is_empty():
		return null

	var ghost_root := Node3D.new()
	ghost_root.name = "GhostVisual"
	var ghost_mat := get_ghost_material(true)

	match catalog_id:
		"cube_1x1x1":
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = BoxMesh.new()
			mesh_inst.mesh.size = Vector3(1.0, 1.0, 1.0)
			mesh_inst.position.y = 0.5
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"platform_2x1x2":
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = BoxMesh.new()
			mesh_inst.mesh.size = Vector3(2.0, 1.0, 2.0)
			mesh_inst.position.y = 0.5
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"wall_4x3":
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = BoxMesh.new()
			mesh_inst.mesh.size = Vector3(4.0, 3.0, 0.5)
			mesh_inst.position.y = 1.5
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"ramp":
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = build_ramp_mesh(2.0, 1.5, 3.0)
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"pillar":
			var mesh_inst := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 4.0
			mesh_inst.mesh = cyl
			mesh_inst.position.y = 2.0
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"cover_crate":
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = BoxMesh.new()
			mesh_inst.mesh.size = Vector3(1.2, 1.0, 0.8)
			mesh_inst.position.y = 0.5
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

		"spawn_ffa", "spawn_red", "spawn_blue":
			var pad := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.6
			cyl.bottom_radius = 0.6
			cyl.height = 0.08
			pad.mesh = cyl
			pad.position.y = 0.04
			pad.material_override = ghost_mat
			ghost_root.add_child(pad)

			var arrow := MeshInstance3D.new()
			var prism := PrismMesh.new()
			prism.size = Vector3(0.4, 0.1, 0.5)
			arrow.mesh = prism
			arrow.rotation_degrees.x = -90.0
			arrow.position = Vector3(0.0, 0.1, -0.4)
			arrow.material_override = ghost_mat
			ghost_root.add_child(arrow)

		_:
			# For weapon pickups, vehicles, lights: create a proxy bounding box or stripped node
			var dims: Vector3 = item.get("dimensions", Vector3.ONE)
			var mesh_inst := MeshInstance3D.new()
			mesh_inst.mesh = BoxMesh.new()
			mesh_inst.mesh.size = dims
			mesh_inst.position.y = dims.y * 0.5
			mesh_inst.material_override = ghost_mat
			ghost_root.add_child(mesh_inst)

	return ghost_root


# -----------------------------------------------------------------------------
# Internal Node Generators
# -----------------------------------------------------------------------------

static func _create_static_box(size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position.y = size.y * 0.5
	body.add_child(shape)

	var mesh_inst := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_inst.mesh = mesh
	mesh_inst.position.y = size.y * 0.5
	mesh_inst.material_override = _get_mat(color)
	body.add_child(mesh_inst)

	return body


static func _create_static_ramp(size: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0

	var shape := CollisionShape3D.new()
	var poly := ConvexPolygonShape3D.new()
	var hw := size.x * 0.5
	var hd := size.z * 0.5
	poly.points = PackedVector3Array([
		Vector3(-hw, 0.0, hd),
		Vector3( hw, 0.0, hd),
		Vector3( hw, 0.0, -hd),
		Vector3(-hw, 0.0, -hd),
		Vector3(-hw, size.y, -hd),
		Vector3( hw, size.y, -hd)
	])
	shape.shape = poly
	body.add_child(shape)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = build_ramp_mesh(size.x, size.y, size.z)
	mesh_inst.material_override = _get_mat(color, 0.75, 0.1)
	body.add_child(mesh_inst)

	return body


static func _create_static_cylinder(radius: float, height: float, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0

	var shape := CollisionShape3D.new()
	var cyl_shape := CylinderShape3D.new()
	cyl_shape.radius = radius
	cyl_shape.height = height
	shape.shape = cyl_shape
	shape.position.y = height * 0.5
	body.add_child(shape)

	var mesh_inst := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh_inst.mesh = mesh
	mesh_inst.position.y = height * 0.5
	mesh_inst.material_override = _get_mat(color)
	body.add_child(mesh_inst)

	return body


static func _create_cover_crate(size: Vector3) -> StaticBody3D:
	var body := _create_static_box(size, Color(0.28, 0.32, 0.24))

	# Add metallic corner trim accents
	var trim := MeshInstance3D.new()
	var trim_mesh := BoxMesh.new()
	trim_mesh.size = Vector3(size.x * 1.02, size.y * 0.1, size.z * 1.02)
	trim.mesh = trim_mesh
	trim.position.y = size.y * 0.5
	trim.material_override = _get_mat(Color(0.18, 0.20, 0.22), 0.5, 0.5)
	body.add_child(trim)

	return body


static func _create_spawn_marker(prefix: String, ring_color: Color) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = prefix

	# Editor visual (ring pad + arrow)
	var visual := Node3D.new()
	visual.name = "EditorVisual"
	marker.add_child(visual)

	var pad := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.6
	cyl.bottom_radius = 0.6
	cyl.height = 0.05
	pad.mesh = cyl
	pad.position.y = 0.025

	var mat := StandardMaterial3D.new()
	mat.albedo_color = ring_color
	mat.emission_enabled = true
	mat.emission = ring_color
	mat.emission_energy_multiplier = 0.8
	mat.roughness = 0.4
	pad.material_override = mat
	visual.add_child(pad)

	# Forward arrow (-Z)
	var arrow := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.35, 0.08, 0.45)
	arrow.mesh = prism
	arrow.rotation_degrees.x = -90.0
	arrow.position = Vector3(0.0, 0.07, -0.35)
	arrow.material_override = mat
	visual.add_child(arrow)

	# Editor selection collider
	var sel_body := StaticBody3D.new()
	sel_body.name = "EditorCollider"
	sel_body.collision_layer = 1
	sel_body.collision_mask = 0
	var sel_shape := CollisionShape3D.new()
	var cyl_shape := CylinderShape3D.new()
	cyl_shape.radius = 0.6
	cyl_shape.height = 0.2
	sel_shape.shape = cyl_shape
	sel_shape.position.y = 0.1
	sel_body.add_child(sel_shape)
	marker.add_child(sel_body)

	return marker


static func _create_weapon_pickup(weapon_scene_path: String, catalog_id: String) -> Node3D:
	var pickup_scene := load("res://scenes/pickups/weapon_pickup.tscn") as PackedScene
	if pickup_scene == null:
		push_error("LevelEditorCatalog: Failed to load weapon_pickup.tscn")
		return null

	var pickup: WeaponPickup = pickup_scene.instantiate() as WeaponPickup
	var weapon_res := load(weapon_scene_path) as PackedScene
	pickup.weapon_scene = weapon_res
	pickup.respawn_delay = 30.0

	# Base rack pedestal
	var pedestal := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.45
	cyl.bottom_radius = 0.55
	cyl.height = 0.12
	pedestal.mesh = cyl
	pedestal.position.y = 0.06
	pedestal.material_override = _get_mat(Color(0.2, 0.22, 0.24), 0.6, 0.4)
	pickup.add_child(pedestal)

	return pickup


static func _create_scene_instance(scene_path: String, catalog_id: String = "") -> Node3D:
	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_error("LevelEditorCatalog: Failed to load scene '%s'" % scene_path)
		return null
	var inst := scene.instantiate() as Node3D
	if not _has_collision(inst):
		var item := get_item(catalog_id)
		var dims: Vector3 = item.get("dimensions", Vector3(0.5, 0.5, 0.5))
		var sel_body := StaticBody3D.new()
		sel_body.name = "EditorCollider"
		sel_body.collision_layer = 1
		sel_body.collision_mask = 0
		var sel_shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = dims
		sel_shape.shape = box
		sel_shape.position.y = dims.y * 0.5
		sel_body.add_child(sel_shape)
		inst.add_child(sel_body)
	return inst


static func _has_collision(node: Node) -> bool:
	if node is CollisionObject3D:
		return true
	for child in node.get_children():
		if _has_collision(child):
			return true
	return false
