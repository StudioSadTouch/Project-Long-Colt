class_name AssemblyRoot3D
extends Node3D
## Node3D wrapper for grouped entities in Project Long Colt Level Editor.
## When grouped, child nodes retain their world transforms while reparenting to AssemblyRoot3D.
## The AssemblyRoot3D origin is centered at the aggregate centroid of its members.

var assembly_uid: String = ""
var display_name: String = "Assembly"


func _init() -> void:
	set_meta(&"assembly_root", true)
	set_meta(&"level_object", true)


## Creates an AssemblyRoot3D bundling the given nodes, centering its origin at their centroid.
static func create_from_nodes(nodes: Array[Node3D], uid_str: String = "") -> AssemblyRoot3D:
	if nodes.is_empty():
		return null
	var valid_nodes: Array[Node3D] = []
	for n in nodes:
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			valid_nodes.append(n)
	if valid_nodes.is_empty():
		return null

	var center := Vector3.ZERO
	for n in valid_nodes:
		center += n.global_position
	center /= float(valid_nodes.size())

	var root := AssemblyRoot3D.new()
	root.assembly_uid = uid_str if uid_str != "" else "assembly_%d" % root.get_instance_id()
	root.name = "Assembly_%s" % root.assembly_uid
	root.set_meta(&"uid", root.get_instance_id())
	root.set_meta(&"display_name", root.display_name)

	var first_parent := valid_nodes[0].get_parent()
	if first_parent != null:
		first_parent.add_child(root, true)
	root.global_position = center

	for n in valid_nodes:
		var prev_gx := n.global_transform
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		root.add_child(n, true)
		n.global_transform = prev_gx
		n.set_meta(&"assembly_parent", root)

	return root


## Disbands the assembly, reparenting all child nodes back to the root's parent while preserving world transforms.
func disband() -> Array[Node3D]:
	var parent := get_parent()
	var members := get_members()
	for child in members:
		var prev_gx := child.global_transform
		remove_child(child)
		if parent != null:
			parent.add_child(child, true)
		child.global_transform = prev_gx
		if child.has_meta(&"assembly_parent"):
			child.remove_meta(&"assembly_parent")
	queue_free()
	return members


## Returns all direct Node3D child members.
func get_members() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for child in get_children():
		if child is Node3D and not child.is_queued_for_deletion():
			out.append(child)
	return out


## Returns an array of UIDs from all child members.
func get_member_uids() -> Array[int]:
	var out: Array[int] = []
	for m in get_members():
		if m.has_meta(&"uid"):
			out.append(int(m.get_meta(&"uid")))
	return out


## Computes the aggregate world-space AABB of all child members.
func calculate_bounds() -> AABB:
	var members := get_members()
	if members.is_empty():
		return AABB(global_position - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	var first := true
	var bounds := AABB()
	for child in members:
		var child_aabb := AABB(child.global_position - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
		if child is LevelGeometry:
			var sz := (child as LevelGeometry).size
			child_aabb = AABB(child.global_position - sz * 0.5, sz)
		elif child.has_node("CollisionShape3D"):
			var col := child.get_node("CollisionShape3D") as CollisionShape3D
			if col != null and col.shape != null:
				var s: Vector3 = Vector3.ONE
				if col.shape is BoxShape3D:
					s = (col.shape as BoxShape3D).size
				child_aabb = AABB(col.global_position - s * 0.5, s)
		if first:
			bounds = child_aabb
			first = false
		else:
			bounds = bounds.merge(child_aabb)
	return bounds
