class_name AssetImporter
extends RefCounted
## Scans and indexes custom user assets in user://custom_assets/.

const ROOT_DIR := "user://custom_assets/"
const MESH_DIR := "user://custom_assets/meshes/"
const TEXTURE_DIR := "user://custom_assets/textures/"
const AUDIO_DIR := "user://custom_assets/audio/"


static func ensure_directories() -> void:
	DirAccess.make_dir_recursive_absolute(MESH_DIR)
	DirAccess.make_dir_recursive_absolute(TEXTURE_DIR)
	DirAccess.make_dir_recursive_absolute(AUDIO_DIR)


static func list_files(dir_path: String, extensions: Array[String]) -> Array[String]:
	ensure_directories()
	var out: Array[String] = []
	var access := DirAccess.open(dir_path)
	if access == null:
		return out
	for file in access.get_files():
		var ext := file.get_extension().to_lower()
		if extensions.has(ext):
			out.append(file)
	out.sort()
	return out


static func list_meshes() -> Array[String]:
	return list_files(MESH_DIR, ["glb", "gltf"])


static func list_textures() -> Array[String]:
	return list_files(TEXTURE_DIR, ["png", "jpg", "jpeg", "webp"])


static func list_audio() -> Array[String]:
	return list_files(AUDIO_DIR, ["ogg", "wav"])


static func mesh_path(filename: String) -> String:
	return MESH_DIR + filename


static func texture_path(filename: String) -> String:
	return TEXTURE_DIR + filename


static func audio_path(filename: String) -> String:
	return AUDIO_DIR + filename
