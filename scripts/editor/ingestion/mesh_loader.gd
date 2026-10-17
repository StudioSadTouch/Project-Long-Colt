class_name MeshLoader
extends RefCounted
## Runtime loader for .glb / .gltf mesh files using Godot's GLTFDocument API.
## Automatically creates static trimesh or convex collision hulls for loaded geometry.


static func load_mesh(path: String, collision_type: String = "convex") -> Node3D:
	if not FileAccess.file_exists(path):
		push_error("MeshLoader: file not found at '%s'" % path)
		return null

	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var err := gltf.append_from_file(path, state)
	if err != OK:
		push_error("MeshLoader: failed to parse GLTF file '%s' (error %d)" % [path, err])
		return null

	var root := gltf.generate_scene(state) as Node3D
	if root == null:
		push_error("MeshLoader: generate_scene returned null for '%s'" % path)
		return null

	root.name = path.get_file().get_basename()
	_generate_collisions(root, collision_type)
	return root


static func _generate_collisions(node: Node, collision_type: String) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			if collision_type == "trimesh" or collision_type == "concave":
				mi.create_trimesh_collision()
			else:
				mi.create_convex_collision(true, true)
	for child in node.get_children():
		_generate_collisions(child, collision_type)
