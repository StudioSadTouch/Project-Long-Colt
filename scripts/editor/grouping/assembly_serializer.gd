class_name AssemblySerializer
extends RefCounted
## Reads and writes custom assemblies / prefabs to user://prefabs/[name].json.

const PREFABS_DIR := "user://prefabs/"
const EXTENSION := ".json"


static func clean_name(name_str: String) -> String:
	var clean := name_str.strip_edges().validate_filename().replace(" ", "_")
	return clean if clean != "" else "custom_prefab"


static func serialize_assembly(root: AssemblyRoot3D, prefab_name: String = "") -> Dictionary:
	var members_data: Array[Dictionary] = []
	for child in root.get_members():
		var entry := LevelWorld.entry_of(child)
		# Convert position & rotation to be relative to root
		var rel_xform := root.global_transform.affine_inverse() * child.global_transform
		entry["pos"] = LevelData.arr(rel_xform.origin)
		entry["rot"] = LevelData.arr(rel_xform.basis.get_euler() * (180.0 / PI))
		members_data.append(entry)

	return {
		"format_version": 1,
		"prefab_name": prefab_name if prefab_name != "" else root.display_name,
		"assembly_uid": root.assembly_uid,
		"root_pos": LevelData.arr(root.position),
		"root_rot": LevelData.arr(root.rotation_degrees),
		"members": members_data,
	}


static func save_prefab(root: AssemblyRoot3D, prefab_name: String) -> Error:
	DirAccess.make_dir_recursive_absolute(PREFABS_DIR)
	var data := serialize_assembly(root, prefab_name)
	var path := PREFABS_DIR + clean_name(prefab_name) + EXTENSION
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return OK


static func load_prefab(prefab_name: String) -> Dictionary:
	var path := PREFABS_DIR + clean_name(prefab_name) + EXTENSION
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	return json.data as Dictionary


static func has_prefab(prefab_name: String) -> bool:
	var path := PREFABS_DIR + clean_name(prefab_name) + EXTENSION
	return FileAccess.file_exists(path)


static func delete_prefab(prefab_name: String) -> Error:
	var path := PREFABS_DIR + clean_name(prefab_name) + EXTENSION
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path)
	return OK


static func list_prefabs() -> Array[String]:
	var out: Array[String] = []
	var access := DirAccess.open(PREFABS_DIR)
	if access == null:
		return out
	for file in access.get_files():
		if file.ends_with(EXTENSION):
			out.append(file.get_basename())
	out.sort()
	return out


static func instantiate_prefab(data_or_name: Variant, editor: bool = false) -> AssemblyRoot3D:
	var data: Dictionary
	if data_or_name is String:
		data = load_prefab(data_or_name as String)
	elif data_or_name is Dictionary:
		data = data_or_name as Dictionary
	else:
		return null

	var members_data: Array = data.get("members", [])
	if members_data.is_empty():
		return null
	var root := AssemblyRoot3D.new()
	root.assembly_uid = str(data.get("assembly_uid", "prefab_%d" % root.get_instance_id()))
	root.display_name = str(data.get("prefab_name", "Prefab"))
	root.name = "Assembly_%s" % root.assembly_uid
	root.position = LevelData.vec(data.get("root_pos", null), Vector3.ZERO)
	root.rotation_degrees = LevelData.vec(data.get("root_rot", null), Vector3.ZERO)

	for entry_variant in members_data:
		if not entry_variant is Dictionary:
			continue
		var entry: Dictionary = entry_variant
		var child := LevelBuilder.build(entry, editor)
		if child == null:
			continue
		child.position = LevelData.vec(entry.get("pos", null), Vector3.ZERO)
		child.rotation_degrees = LevelData.vec(entry.get("rot", null), Vector3.ZERO)
		root.add_child(child, true)
		child.set_meta(&"assembly_parent", root)

	return root
