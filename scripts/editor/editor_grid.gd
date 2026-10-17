class_name EditorGrid
extends MeshInstance3D
## The editor's ground grid: lines every `spacing` metres (the position snap) on y = 0, with a
## brighter line every MAJOR_EVERY and red / blue X / Z axes through the origin. It follows the
## camera in whole cells, so it always looks endless without being huge.

const HALF_CELLS := 60
const MAJOR_EVERY := 5
const MINOR := Color(0.75, 0.85, 0.9, 0.12)
const MAJOR := Color(0.75, 0.85, 0.9, 0.28)
const AXIS_X := Color(0.95, 0.3, 0.3, 0.7)
const AXIS_Z := Color(0.3, 0.5, 1.0, 0.7)
## Just above y = 0, so the ground slab's top doesn't hide it.
const LIFT := 0.01

var spacing: float = 1.0:
	set(value):
		var clean := maxf(value, 0.1)
		if is_equal_approx(clean, spacing):
			return
		spacing = clean
		_rebuild()

var _built_at := Vector2.INF


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	material_override = mat
	_rebuild()


## Keeps the grid under the camera (moves in whole major cells, so lines never slide).
func follow(camera: Camera3D) -> void:
	var step := spacing * MAJOR_EVERY
	var at := Vector2(
		roundf(camera.global_position.x / step) * step, roundf(camera.global_position.z / step) * step
	)
	if at != _built_at:
		_built_at = at
		_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var center := _built_at if _built_at != Vector2.INF else Vector2.ZERO
	var reach := HALF_CELLS * spacing
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var first := -HALF_CELLS
	var base_x := roundf(center.x / spacing)
	var base_z := roundf(center.y / spacing)
	for i in range(first, HALF_CELLS + 1):
		# Lines of constant x, then of constant z.
		var cell_x := int(base_x) + i
		var x := cell_x * spacing
		_line(mesh, Vector3(x, LIFT, center.y - reach), Vector3(x, LIFT, center.y + reach), _color(cell_x, AXIS_Z))
		var cell_z := int(base_z) + i
		var z := cell_z * spacing
		_line(mesh, Vector3(center.x - reach, LIFT, z), Vector3(center.x + reach, LIFT, z), _color(cell_z, AXIS_X))
	mesh.surface_end()
	self.mesh = mesh


func _color(cell: int, axis: Color) -> Color:
	if cell == 0:
		return axis
	return MAJOR if cell % MAJOR_EVERY == 0 else MINOR


static func _line(mesh: ImmediateMesh, a: Vector3, b: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(a)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(b)
