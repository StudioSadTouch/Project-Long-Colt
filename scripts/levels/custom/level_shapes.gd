class_name LevelShapes
extends RefCounted
## Parametric level geometry: a mesh plus matching collision for each shape kind, at any size.
## Every shape is built from boxes or convex prisms, so collision is exact and the navmesh bakes
## from it. Size is the bounding box (x width, y height, z depth); the pivot is bottom-centre
## (x and z centred, y from 0 up), so a piece sits on whatever it's placed on. Slopes rise
## toward -Z (forward is -Z in Godot). Materials are world-triplanar, so no UVs are needed and a
## resized piece keeps a true 1 m grid.
##
## build(kind, size, params) -> {"mesh": ArrayMesh, "shapes": [[Shape3D, Transform3D], ...]}

const KINDS := [
	"box", "wedge", "stairs", "cylinder", "cone", "arch", "doorway", "window", "catwalk",
	"quarter_pipe",
]
## Smallest size along any axis.
const MIN_SIZE := 0.05
## Riser height stairs aim for: under the 0.35 m step-up, so players and bots walk them.
const STEP_RISE := 0.3
const ROUND_SEGMENTS := 20
const CURVE_SEGMENTS := 10


static func build(kind: String, size: Vector3, params: Dictionary = {}) -> Dictionary:
	size = size.max(Vector3.ONE * MIN_SIZE)
	var b := _Builder.new()
	match kind:
		"wedge":
			_wedge(b, size)
		"stairs":
			_stairs(b, size, int(params.get("steps", 0)))
		"cylinder":
			_round(b, size, false)
		"cone":
			_round(b, size, true)
		"arch":
			_arch(b, size)
		"doorway":
			_doorway(b, size, params)
		"window":
			_window(b, size, params)
		"catwalk":
			_catwalk(b, size)
		"quarter_pipe":
			_quarter_pipe(b, size)
		_:
			b.box(Vector3(0.0, size.y * 0.5, 0.0), size)
	return {"mesh": b.commit(), "shapes": b.shapes}


## Steps for a stair of this size: params.steps, else risers of about STEP_RISE.
static func stair_count(size: Vector3, wanted: int = 0) -> int:
	if wanted > 0:
		return wanted
	return maxi(ceili(size.y / STEP_RISE), 1)


static func _wedge(b: _Builder, s: Vector3) -> void:
	var hz := s.z * 0.5
	# Profile in (z, y): low at the front (+Z), high at the back (-Z).
	b.prism(PackedVector2Array([Vector2(hz, 0.0), Vector2(-hz, 0.0), Vector2(-hz, s.y)]), "yz", -s.x * 0.5, s.x * 0.5)


static func _stairs(b: _Builder, s: Vector3, wanted: int) -> void:
	var n := stair_count(s, wanted)
	var rise := s.y / n
	var run := s.z / n
	var hz := s.z * 0.5
	for k in n:
		# Step k is solid from the floor up; the front (+Z) step is the lowest.
		var z_front := hz - k * run
		var height := (k + 1) * rise
		b.box(Vector3(0.0, height * 0.5, z_front - run * 0.5), Vector3(s.x, height, run))


## Cylinder (or cone): an ellipse of s.x by s.z, so it stretches with the size.
static func _round(b: _Builder, s: Vector3, cone: bool) -> void:
	var rx := s.x * 0.5
	var rz := s.z * 0.5
	if cone:
		var base := PackedVector3Array()
		for i in ROUND_SEGMENTS:
			var a := TAU * i / ROUND_SEGMENTS
			base.append(Vector3(cos(a) * rx, 0.0, sin(a) * rz))
		b.pyramid(base, Vector3(0.0, s.y, 0.0))
		return
	var ring := PackedVector2Array()
	for i in ROUND_SEGMENTS:
		var a := TAU * i / ROUND_SEGMENTS
		ring.append(Vector2(cos(a) * rx, sin(a) * rz))
	b.prism(ring, "xz", 0.0, s.y)


## A wall (x wide, y tall, z thick) with a round-topped opening.
static func _arch(b: _Builder, s: Vector3) -> void:
	var hx := s.x * 0.5
	var hz := s.z * 0.5
	var opening := clampf(s.x * 0.6, 0.2, maxf(s.x - 0.2, 0.2))
	var r := opening * 0.5
	var spring := clampf(s.y * 0.75 - r, 0.0, maxf(s.y - r - 0.1, 0.0))  # where the curve starts
	var pier := (s.x - opening) * 0.5
	if pier > 0.001:
		b.box(Vector3(-hx + pier * 0.5, s.y * 0.5, 0.0), Vector3(pier, s.y, s.z))
		b.box(Vector3(hx - pier * 0.5, s.y * 0.5, 0.0), Vector3(pier, s.y, s.z))
	# Above the opening: vertical strips whose undersides follow the semicircle.
	for i in CURVE_SEGMENTS:
		var x0 := -r + opening * float(i) / CURVE_SEGMENTS
		var x1 := -r + opening * float(i + 1) / CURVE_SEGMENTS
		var y0 := spring + sqrt(maxf(r * r - x0 * x0, 0.0))
		var y1 := spring + sqrt(maxf(r * r - x1 * x1, 0.0))
		if minf(y0, y1) >= s.y - 0.001:
			continue
		var profile := PackedVector2Array(
			[Vector2(x0, y0), Vector2(x1, y1), Vector2(x1, s.y), Vector2(x0, s.y)]
		)
		b.prism(profile, "xy", -hz, hz)


## A wall with a rectangular door. params: door_width, door_height.
static func _doorway(b: _Builder, s: Vector3, params: Dictionary) -> void:
	var w := clampf(float(params.get("door_width", 1.6)), 0.2, maxf(s.x - 0.2, 0.2))
	var h := clampf(float(params.get("door_height", 2.4)), 0.2, maxf(s.y - 0.1, 0.2))
	var side := (s.x - w) * 0.5
	var hx := s.x * 0.5
	if side > 0.001:
		b.box(Vector3(-hx + side * 0.5, s.y * 0.5, 0.0), Vector3(side, s.y, s.z))
		b.box(Vector3(hx - side * 0.5, s.y * 0.5, 0.0), Vector3(side, s.y, s.z))
	if s.y - h > 0.001:
		b.box(Vector3(0.0, (h + s.y) * 0.5, 0.0), Vector3(w, s.y - h, s.z))


## A wall with a window. params: window_width, window_bottom, window_top.
static func _window(b: _Builder, s: Vector3, params: Dictionary) -> void:
	var w := clampf(float(params.get("window_width", s.x * 0.5)), 0.2, maxf(s.x - 0.2, 0.2))
	var bottom := clampf(float(params.get("window_bottom", 1.0)), 0.0, maxf(s.y - 0.3, 0.0))
	var top := clampf(float(params.get("window_top", 2.2)), bottom + 0.2, s.y)
	var side := (s.x - w) * 0.5
	var hx := s.x * 0.5
	if side > 0.001:
		b.box(Vector3(-hx + side * 0.5, s.y * 0.5, 0.0), Vector3(side, s.y, s.z))
		b.box(Vector3(hx - side * 0.5, s.y * 0.5, 0.0), Vector3(side, s.y, s.z))
	if bottom > 0.001:
		b.box(Vector3(0.0, bottom * 0.5, 0.0), Vector3(w, bottom, s.z))
	if s.y - top > 0.001:
		b.box(Vector3(0.0, (top + s.y) * 0.5, 0.0), Vector3(w, s.y - top, s.z))


## A deck along Z with a rail on each side (rails need size.y above the deck).
static func _catwalk(b: _Builder, s: Vector3) -> void:
	var deck := minf(0.15, s.y)
	b.box(Vector3(0.0, deck * 0.5, 0.0), Vector3(s.x, deck, s.z))
	var rail_h := s.y - deck
	if rail_h < 0.3 or s.x < 0.4:
		return
	var t := 0.06
	for side: float in [-1.0, 1.0]:
		var x := side * (s.x * 0.5 - t * 0.5)
		# Top bar, mid bar and posts: open enough to see through, solid enough to stop you.
		b.box(Vector3(x, s.y - t * 0.5, 0.0), Vector3(t, t, s.z))
		b.box(Vector3(x, deck + rail_h * 0.5, 0.0), Vector3(t, t, s.z))
		var posts := maxi(ceili(s.z / 2.0), 1)
		for i in posts + 1:
			var z := -s.z * 0.5 + s.z * float(i) / posts
			z = clampf(z, -s.z * 0.5 + t * 0.5, s.z * 0.5 - t * 0.5)
			b.box(Vector3(x, deck + rail_h * 0.5, z), Vector3(t, rail_h, t))


## A concave ramp: flat at the front (+Z), vertical at the back (-Z).
static func _quarter_pipe(b: _Builder, s: Vector3) -> void:
	var hz := s.z * 0.5
	var hx := s.x * 0.5
	for i in CURVE_SEGMENTS:
		var a0 := (PI * 0.5) * float(i) / CURVE_SEGMENTS
		var a1 := (PI * 0.5) * float(i + 1) / CURVE_SEGMENTS
		var z0 := hz - s.z * sin(a0)
		var z1 := hz - s.z * sin(a1)
		var y0 := s.y - s.y * cos(a0)
		var y1 := s.y - s.y * cos(a1)
		var profile := PackedVector2Array(
			[Vector2(z0, 0.0), Vector2(z1, 0.0), Vector2(z1, y1), Vector2(z0, y0)]
		)
		if absf(z0 - z1) < 0.0001:
			continue
		b.prism(profile, "yz", -hx, hx)


## Mesh and collision accumulator. Faces get flat outward normals and Godot's clockwise front
## winding, worked out from each piece's centre, so every piece is a closed convex solid.
class _Builder:
	var st := SurfaceTool.new()
	var shapes: Array = []

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func commit() -> ArrayMesh:
		return st.commit()

	func box(center: Vector3, size: Vector3) -> void:
		var h := size * 0.5
		var c := [
			center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
			center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
			center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
			center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
		]
		for face: Array in [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [3, 2, 6, 7], [0, 3, 7, 4], [1, 2, 6, 5]]:
			_quad(c[face[0]], c[face[1]], c[face[2]], c[face[3]], center)
		var shape := BoxShape3D.new()
		shape.size = size
		shapes.append([shape, Transform3D(Basis.IDENTITY, center)])

	## A convex 2D profile extruded between `from` and `to` along the axis the plane leaves out:
	## "yz" = (z, y) extruded along X, "xy" = (x, y) along Z, "xz" = (x, z) along Y.
	func prism(profile: PackedVector2Array, plane: String, from: float, to: float) -> void:
		var near := PackedVector3Array()
		var far := PackedVector3Array()
		for p in profile:
			near.append(_map(p, plane, from))
			far.append(_map(p, plane, to))
		var points := near + far
		var center := Vector3.ZERO
		for p in points:
			center += p
		center /= points.size()
		var n := profile.size()
		for i in range(1, n - 1):  # caps
			_tri(near[0], near[i], near[i + 1], center)
			_tri(far[0], far[i], far[i + 1], center)
		for i in n:  # sides
			var j := (i + 1) % n
			_quad(near[i], near[j], far[j], far[i], center)
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		shapes.append([shape, Transform3D.IDENTITY])

	## A cone: a flat base polygon and an apex.
	func pyramid(base: PackedVector3Array, apex: Vector3) -> void:
		var points := base.duplicate()
		points.append(apex)
		var center := Vector3.ZERO
		for p in points:
			center += p
		center /= points.size()
		var n := base.size()
		for i in range(1, n - 1):
			_tri(base[0], base[i], base[i + 1], center)
		for i in n:
			_tri(base[i], base[(i + 1) % n], apex, center)
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		shapes.append([shape, Transform3D.IDENTITY])

	func _map(p: Vector2, plane: String, along: float) -> Vector3:
		match plane:
			"yz":
				return Vector3(along, p.y, p.x)
			"xy":
				return Vector3(p.x, p.y, along)
			_:
				return Vector3(p.x, along, p.y)

	func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, center: Vector3) -> void:
		_tri(a, b, c, center)
		_tri(a, c, d, center)

	func _tri(a: Vector3, b: Vector3, c: Vector3, center: Vector3) -> void:
		var cross := (b - a).cross(c - a)
		if cross.length_squared() < 1e-12:
			return
		var mid := (a + b + c) / 3.0
		var outward := cross.normalized()
		if outward.dot(mid - center) < 0.0:
			outward = -outward
		# Godot's front faces wind clockwise seen from outside: the cross product points in.
		if cross.dot(outward) > 0.0:
			var t := b
			b = c
			c = t
		st.set_normal(outward)
		st.add_vertex(a)
		st.set_normal(outward)
		st.add_vertex(b)
		st.set_normal(outward)
		st.add_vertex(c)
