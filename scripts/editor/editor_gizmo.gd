class_name EditorGizmo
extends Node3D
## The level editor's transform handles, drawn on top of everything at a constant screen size.
##   MOVE    three arrows: drag along an axis
##   ROTATE  three rings: drag around an axis
##   RESIZE  six face handles on the object's box: drag a face out or in; the opposite face
##           stays put (geometry and volumes only)
## Axes are world axes, or the object's own in local space (RESIZE is always local).
## Handles are picked in screen space (distance from the cursor to the projected arrow, ring or
## handle), so they're as easy to grab far away as up close. The gizmo only measures: drag()
## returns how far / which way, and LevelEditor applies it (with snapping) to the selection.
## The maths is static (closest_line_param, signed_angle, resize_box) so tests can check it.

enum Mode { MOVE, ROTATE, RESIZE }

const COLORS := [Color(0.95, 0.25, 0.25), Color(0.3, 0.9, 0.3), Color(0.3, 0.5, 1.0)]
const HOVER_COLOR := Color(1.0, 0.85, 0.2)
## Gizmo length as a fraction of the camera distance (constant screen size).
const SCREEN_FRACTION := 0.16
const PICK_PIXELS := 12.0
const RING_SAMPLES := 48

var mode: Mode = Mode.MOVE
var local_space: bool = false

## Pivot and orientation of what is being edited; box size for RESIZE.
var _pivot := Transform3D.IDENTITY
var _box := Vector3.ZERO
var _length: float = 1.0
var _hover: int = -1
var _drag_handle: int = -1
var _drag: Dictionary = {}
var _parts: Array[MeshInstance3D] = []
var _materials: Array[StandardMaterial3D] = []


func _ready() -> void:
	_rebuild()


func set_mode(new_mode: Mode) -> void:
	if mode == new_mode:
		return
	mode = new_mode
	_hover = -1
	_rebuild()


## Where to draw: the selection's pivot transform, and its box size (Vector3.ZERO = can't resize).
func configure(pivot: Transform3D, box: Vector3) -> void:
	_pivot = pivot
	_box = box
	if mode == Mode.RESIZE and _parts.size() != 6:
		_rebuild()


func can_resize() -> bool:
	return _box != Vector3.ZERO


## World direction of handle axis i.
func axis(i: int) -> Vector3:
	if local_space or mode == Mode.RESIZE:
		return _pivot.basis[i].normalized()
	return [Vector3.RIGHT, Vector3.UP, Vector3.BACK][i]


func is_dragging() -> bool:
	return _drag_handle >= 0


func get_hover() -> int:
	return _hover


## Per frame: follow the pivot, keep a constant screen size, colour the hovered handle.
func update_view(camera: Camera3D) -> void:
	_length = maxf(camera.global_position.distance_to(_pivot.origin), 1.0) * SCREEN_FRACTION
	var orient := Basis.IDENTITY
	if local_space or mode == Mode.RESIZE:
		orient = _pivot.basis.orthonormalized()
	if mode == Mode.RESIZE:
		global_transform = Transform3D(orient, _pivot.origin)
		var handle_scale := _length * 0.12
		for i in _parts.size():
			_parts[i].position = _face_local(i)
			_parts[i].scale = Vector3.ONE * handle_scale
			_parts[i].visible = can_resize()
	else:
		global_transform = Transform3D(orient.scaled(Vector3.ONE * _length), _pivot.origin)
	for i in _parts.size():
		var base: Color = COLORS[_axis_of(i)]
		_materials[i].albedo_color = HOVER_COLOR if i == (_drag_handle if _drag_handle >= 0 else _hover) else base


## The handle under the cursor, or -1.
func hit_test(camera: Camera3D, mouse: Vector2) -> int:
	var best := -1
	var best_d := PICK_PIXELS
	var origin := _pivot.origin
	match mode:
		Mode.MOVE:
			for i in 3:
				var d := _segment_distance(camera, mouse, origin, origin + axis(i) * _length)
				if d < best_d:
					best_d = d
					best = i
		Mode.ROTATE:
			for i in 3:
				var d := _ring_distance(camera, mouse, origin, axis(i), _length * 0.9)
				if d < best_d:
					best_d = d
					best = i
		Mode.RESIZE:
			if not can_resize():
				return -1
			for i in 6:
				var world := _pivot.origin + _pivot.basis.orthonormalized() * _face_local(i)
				if camera.is_position_behind(world):
					continue
				var d := camera.unproject_position(world).distance_to(mouse)
				if d < best_d + 6.0:
					best_d = d
					best = i
	return best


func set_hover(handle: int) -> void:
	_hover = handle


func begin_drag(handle: int, camera: Camera3D, mouse: Vector2) -> void:
	_drag_handle = handle
	var ray := _ray(camera, mouse)
	match mode:
		Mode.MOVE:
			var a := axis(handle)
			_drag = {"axis": a, "origin": _pivot.origin, "t0": closest_line_param(ray[0], ray[1], _pivot.origin, a)}
		Mode.ROTATE:
			var a := axis(handle)
			_drag = {"axis": a, "center": _pivot.origin, "prev": _ring_vector(ray, _pivot.origin, a, mouse), "angle": 0.0, "mouse": mouse}
		Mode.RESIZE:
			var i := handle / 2
			var sign := 1.0 if handle % 2 == 0 else -1.0
			var dir := _pivot.basis[i].normalized() * sign
			var face := _pivot.origin + _pivot.basis.orthonormalized() * _face_local(handle)
			_drag = {"index": i, "sign": sign, "dir": dir, "face": face, "t0": closest_line_param(ray[0], ray[1], face, dir)}


## How far the drag has gone since begin_drag:
##   MOVE    {"type": "move", "axis": Vector3, "distance": float}
##   ROTATE  {"type": "rotate", "axis": Vector3, "angle": float (radians, accumulated)}
##   RESIZE  {"type": "resize", "index": 0..2, "sign": +-1, "amount": float (outward)}
func drag(camera: Camera3D, mouse: Vector2) -> Dictionary:
	if _drag_handle < 0:
		return {}
	var ray := _ray(camera, mouse)
	match mode:
		Mode.MOVE:
			var t := closest_line_param(ray[0], ray[1], _drag.origin, _drag.axis)
			return {"type": "move", "axis": _drag.axis, "distance": t - float(_drag.t0)}
		Mode.ROTATE:
			var v := _ring_vector(ray, _drag.center, _drag.axis, mouse)
			if v == Vector3.ZERO or _drag.prev == Vector3.ZERO:
				# Ring seen edge-on: turn by horizontal mouse travel instead.
				var dx: float = mouse.x - (_drag.mouse as Vector2).x
				_drag.angle = float(_drag.angle) + dx * 0.01
			else:
				_drag.angle = float(_drag.angle) + signed_angle(_drag.prev, v, _drag.axis)
				_drag.prev = v
			_drag.mouse = mouse
			return {"type": "rotate", "axis": _drag.axis, "angle": float(_drag.angle)}
		_:
			var t := closest_line_param(ray[0], ray[1], _drag.face, _drag.dir)
			return {"type": "resize", "index": int(_drag.index), "sign": float(_drag.sign), "amount": t - float(_drag.t0)}


func end_drag() -> void:
	_drag_handle = -1
	_drag = {}


# ------------------------------------------------------------------ maths (static, tested)


## Parameter t along the line (line_origin + t * line_dir) closest to the ray.
static func closest_line_param(
	ray_origin: Vector3, ray_dir: Vector3, line_origin: Vector3, line_dir: Vector3
) -> float:
	var d1 := ray_dir.normalized()
	var d2 := line_dir.normalized()
	var w0 := ray_origin - line_origin
	var b := d1.dot(d2)
	var denom := 1.0 - b * b
	if absf(denom) < 1e-6:
		return d2.dot(w0)  # parallel: project the ray origin
	var d := d1.dot(w0)
	var e := d2.dot(w0)
	return (e - b * d) / denom


## Signed angle from a to b around axis (radians, -PI..PI).
static func signed_angle(a: Vector3, b: Vector3, around: Vector3) -> float:
	return atan2(around.normalized().dot(a.cross(b)), a.dot(b))


## A box (bottom-centre pivot, local size) resized by dragging face (index, sign) out by amount:
## the opposite face stays where it was. snap > 0 rounds the new size. -> [position, size].
static func resize_box(
	xform: Transform3D, size: Vector3, index: int, sign: float, amount: float, snap: float
) -> Array:
	var new_extent := size[index] + amount
	if snap > 0.0:
		new_extent = maxf(snappedf(new_extent, snap), snap)
	new_extent = maxf(new_extent, LevelShapes.MIN_SIZE)
	var grow := new_extent - size[index]
	var new_size := size
	new_size[index] = new_extent
	var dir := xform.basis[index].normalized()
	var origin := xform.origin
	if index == 1:
		# Pivot at the bottom: growing the top moves nothing; growing the bottom moves the pivot.
		if sign < 0.0:
			origin -= dir * grow
	else:
		origin += dir * sign * grow * 0.5
	return [origin, new_size]


# ------------------------------------------------------------------ internals


func _rebuild() -> void:
	for p in _parts:
		p.queue_free()
	_parts.clear()
	_materials.clear()
	match mode:
		Mode.MOVE:
			for i in 3:
				_parts.append(_arrow(i))
		Mode.ROTATE:
			for i in 3:
				_parts.append(_ring(i))
		Mode.RESIZE:
			for i in 6:
				_parts.append(_cube(i))


func _axis_of(part: int) -> int:
	return part / 2 if mode == Mode.RESIZE else part


func _material(i: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.render_priority = 10
	m.albedo_color = COLORS[_axis_of(i)]
	_materials.append(m)
	return m


## A unit arrow along local axis i (the node is scaled to _length).
func _arrow(i: int) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.06
	mesh.height = 0.25
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.015
	shaft.bottom_radius = 0.015
	shaft.height = 0.8
	var arrow := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.append_from(shaft, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.4, 0.0)))
	st.append_from(mesh, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.875, 0.0)))
	arrow.mesh = st.commit()
	arrow.material_override = _material(i)
	arrow.basis = _y_to_axis(i)
	arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(arrow)
	return arrow


func _ring(i: int) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = 0.87
	torus.outer_radius = 0.93
	torus.rings = 48
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	ring.material_override = _material(i)
	ring.basis = _y_to_axis(i)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	return ring


func _cube(i: int) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var cube := MeshInstance3D.new()
	cube.mesh = box
	cube.material_override = _material(i)
	cube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cube)
	return cube


## Rotation taking local +Y to axis i (meshes are built along Y).
static func _y_to_axis(i: int) -> Basis:
	match i:
		0:
			return Basis(Vector3.BACK, -PI * 0.5)
		2:
			return Basis(Vector3.RIGHT, PI * 0.5)
		_:
			return Basis.IDENTITY


## Face-handle i's centre in the object's (unscaled) local space: i = axis * 2 + (0: +, 1: -).
func _face_local(i: int) -> Vector3:
	var index := i / 2
	var sign := 1.0 if i % 2 == 0 else -1.0
	var p := Vector3(0.0, _box.y * 0.5, 0.0)
	if index == 1:
		p.y = _box.y if sign > 0.0 else 0.0
	else:
		p[index] = sign * _box[index] * 0.5
	return p


static func _ray(camera: Camera3D, mouse: Vector2) -> Array:
	return [camera.project_ray_origin(mouse), camera.project_ray_normal(mouse)]


func _segment_distance(camera: Camera3D, mouse: Vector2, a: Vector3, b: Vector3) -> float:
	if camera.is_position_behind(a) or camera.is_position_behind(b):
		return INF
	var pa := camera.unproject_position(a)
	var pb := camera.unproject_position(b)
	return Geometry2D.get_closest_point_to_segment(mouse, pa, pb).distance_to(mouse)


func _ring_distance(camera: Camera3D, mouse: Vector2, center: Vector3, normal: Vector3, radius: float) -> float:
	var u := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := normal.cross(u).normalized()
	var best := INF
	var prev := Vector2.INF
	for k in RING_SAMPLES + 1:
		var t := TAU * k / RING_SAMPLES
		var world := center + (u * cos(t) + v * sin(t)) * radius
		if camera.is_position_behind(world):
			prev = Vector2.INF
			continue
		var p := camera.unproject_position(world)
		if prev != Vector2.INF:
			best = minf(best, Geometry2D.get_closest_point_to_segment(mouse, prev, p).distance_to(mouse))
		prev = p
	return best


## Unit vector from the ring centre to where the cursor ray meets the ring's plane; ZERO when
## the plane is seen edge-on.
func _ring_vector(ray: Array, center: Vector3, normal: Vector3, _mouse: Vector2) -> Vector3:
	var plane := Plane(normal, center)
	var dir: Vector3 = ray[1]
	if absf(dir.normalized().dot(normal)) < 0.08:
		return Vector3.ZERO
	var hit: Variant = plane.intersects_ray(ray[0], dir)
	if hit == null:
		return Vector3.ZERO
	var v: Vector3 = (hit as Vector3) - center
	return v.normalized() if v.length_squared() > 1e-6 else Vector3.ZERO
