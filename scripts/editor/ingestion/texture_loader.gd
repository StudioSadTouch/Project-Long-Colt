class_name TextureLoader
extends RefCounted
## Runtime loader for image textures (.png, .jpg, .webp) and Decal generators.


static func load_texture(path: String) -> ImageTexture:
	if not FileAccess.file_exists(path):
		push_error("TextureLoader: file not found at '%s'" % path)
		return null

	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		push_error("TextureLoader: failed to load image from '%s'" % path)
		return null

	return ImageTexture.create_from_image(image)


static func create_decal(path: String, size: Vector3 = Vector3(2.0, 2.0, 2.0)) -> Decal:
	var tex := load_texture(path)
	if tex == null:
		return null

	var decal := Decal.new()
	decal.name = path.get_file().get_basename()
	decal.texture_albedo = tex
	decal.size = size
	return decal


static func create_material(path: String) -> StandardMaterial3D:
	var tex := load_texture(path)
	if tex == null:
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	return mat
