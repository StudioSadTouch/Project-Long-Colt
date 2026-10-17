class_name LogicWireRenderer
extends Node3D
## Renders 3D cubic bezier line splines connecting logic nodes in the editor viewport.

const WIRE_SEGMENTS := 16
const WIRE_COLOR := Color(0.2, 0.85, 1.0, 0.9)
const DRAFT_COLOR := Color(1.0, 0.85, 0.2, 0.9)

var event_manager: EventManager
var map_root: Node3D
var active: bool = true

var draft_source: Node3D = null
var draft_target_pos: Vector3 = Vector3.ZERO

var _mesh_inst: MeshInstance3D
var _immediate: ImmediateMesh
var _mat: StandardMaterial3D


func _ready() -> void:
	_immediate = ImmediateMesh.new()
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.mesh = _immediate
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mesh_inst.material_override = _mat

	add_child(_mesh_inst)


func _process(_delta: float) -> void:
	if not active or event_manager == null or map_root == null:
		if _immediate != null:
			_immediate.clear_surfaces()
		return
	redraw()


func redraw() -> void:
	if _immediate == null:
		return
	_immediate.clear_surfaces()

	var valid_connections: Array[Array] = []
	if event_manager != null and map_root != null:
		for conn in event_manager.connections:
			var s_id: String = str(conn.get("source_uid", ""))
			var t_id: String = str(conn.get("target_uid", ""))
			var source := EventManager.find_node_by_uid(map_root, s_id) as Node3D
			var target := EventManager.find_node_by_uid(map_root, t_id) as Node3D
			if source != null and target != null:
				valid_connections.append([source.global_position, target.global_position])

	if valid_connections.is_empty() and draft_source == null:
		return

	_immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for pair in valid_connections:
		_draw_bezier(pair[0], pair[1], WIRE_COLOR)

	if draft_source != null:
		_draw_bezier(draft_source.global_position, draft_target_pos, DRAFT_COLOR)

	_immediate.surface_end()


func _draw_bezier(p0: Vector3, p3: Vector3, col: Color) -> void:
	var dist := p0.distance_to(p3)
	var lift := clampf(dist * 0.25, 0.5, 4.0)
	var p1 := p0 + Vector3(0.0, lift, 0.0)
	var p2 := p3 + Vector3(0.0, lift, 0.0)

	var prev := p0
	for i in range(1, WIRE_SEGMENTS + 1):
		var t := float(i) / float(WIRE_SEGMENTS)
		var curr := _cubic_bezier(p0, p1, p2, p3, t)

		_immediate.surface_set_color(col)
		_immediate.surface_add_vertex(to_local(prev))
		_immediate.surface_set_color(col)
		_immediate.surface_add_vertex(to_local(curr))
		prev = curr


static func _cubic_bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	var tt := t * t
	var uu := u * u
	var uuu := uu * u
	var ttt := tt * t

	var p := uuu * p0
	p += 3.0 * uu * t * p1
	p += 3.0 * u * tt * p2
	p += ttt * p3
	return p
