class_name LevelWorld
extends RefCounted
## Builds a level's world from its data, the same way in the editor and in a match: the
## environment and sun (settings), the ground slab, the safety kill volume, and every object
## (LevelBuilder) at its saved transform. entry_of() is the inverse, so the editor saves exactly
## what it shows.


## WorldEnvironment + sun under parent, from the level settings.
static func add_environment(parent: Node, settings: Dictionary) -> void:
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var path: String = LevelData.ENVIRONMENTS.get(str(settings.environment), LevelData.ENVIRONMENTS.outdoor)
	env.environment = load(path) as Environment
	parent.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(float(settings.sun_pitch), float(settings.sun_yaw), 0.0)
	sun.light_energy = float(settings.sun_energy)
	sun.light_color = Color(1.0, 0.95, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	parent.add_child(sun)


## The ground slab (top at y = 0) if the settings want one; null otherwise.
static func add_ground(parent: Node, settings: Dictionary) -> LevelGeometry:
	if not bool(settings.ground):
		return null
	var ground := LevelGeometry.new()
	ground.name = "Ground"
	var side := clampf(float(settings.ground_size), 4.0, 2000.0)
	ground.size = Vector3(side, 1.0, side)
	ground.material_id = str(settings.ground_material)
	ground.position.y = -1.0
	parent.add_child(ground)
	return ground


## A wide kill volume below kill_height, so falling off the level kills (and respawns).
static func add_kill_floor(parent: Node, settings: Dictionary) -> void:
	var kill := Area3D.new()
	kill.name = "KillFloor"
	kill.set_script(load("res://scripts/levels/kill_volume.gd"))
	kill.collision_layer = LevelBuilder.AREA_LAYER
	kill.collision_mask = 2 | 4
	kill.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 20.0, 4000.0)
	shape.shape = box
	kill.add_child(shape)
	kill.position.y = float(settings.kill_height) - 10.0
	parent.add_child(kill)


## Every object of the level under root (built for the editor or a match).
static func add_objects(root: Node3D, data: Dictionary, editor: bool) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for entry: Dictionary in data.get("objects", []):
		var node := add_object(root, entry, editor)
		if node != null:
			out.append(node)
	return out


static func add_object(root: Node3D, entry: Dictionary, editor: bool) -> Node3D:
	var node := LevelBuilder.build(entry, editor)
	if node == null:
		return null
	var scale := node.scale
	node.transform = LevelData.transform_of(entry)
	node.scale = scale
	root.add_child(node, true)
	return node


## The saved entry for a built object (inverse of LevelBuilder.build + add_object).
static func entry_of(node: Node3D) -> Dictionary:
	var id := str(node.get_meta(&"catalog_id", ""))
	var item := LevelCatalog.get_item(id)
	var entry := {
		"catalog_id": id,
		"uid": int(node.get_meta(&"uid", 0)),
		"pos": LevelData.arr(node.global_position),
		"rot": LevelData.arr(node.global_rotation_degrees),
	}
	var label := str(node.get_meta(&"display_name", ""))
	if label != "" and label != str(item.get("name", "")):
		entry["label"] = label
	if node is TriggerVolume:
		entry["size"] = LevelData.arr((node as TriggerVolume).volume_size)
	elif node is LevelGeometry:
		var geo := node as LevelGeometry
		entry["size"] = LevelData.arr(geo.size)
		entry["material"] = geo.material_id
	elif node.has_meta(&"size"):
		entry["size"] = LevelData.arr(node.get_meta(&"size"))
	if item.get("scalable", false) and not is_equal_approx(node.scale.x, 1.0):
		entry["scale"] = snappedf(node.scale.x, 0.001)
	var props: Dictionary = node.get_meta(&"props", {})
	var defaults: Dictionary = item.get("props", {})
	var changed := {}
	for key: String in props:
		if not defaults.has(key) or defaults[key] != props[key]:
			changed[key] = props[key]
	if not changed.is_empty():
		entry["props"] = changed
	return entry
