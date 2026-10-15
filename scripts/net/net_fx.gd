class_name NetFx
extends RefCounted
## Placeholder FX for remote shooters (players and bots seen over the network). WeaponFx is
## first-person only, so NetMatch drives these from the batched shot message (one per trigger
## pull, every pellet in it) and from snapshot weapon state (charge glow, overheat vent).
## Audio and real VFX can hook NetMatch.remote_shot instead; this keeps greybox readable.

const TRACER_TIME := 0.12
const IMPACT_TIME := 0.22
const FLASH_TIME := 0.05
const VENT_TIME := 0.6
const TRACER_COLOR := Color(1.0, 0.85, 0.45, 0.9)
const IMPACT_COLOR := Color(1.0, 0.7, 0.3, 1.0)
const FLASH_COLOR := Color(1.0, 0.8, 0.4, 1.0)
const CHARGE_COLOR := Color(0.45, 0.85, 1.0, 0.85)
const VENT_COLOR := Color(0.85, 0.85, 0.9, 0.5)
## Tracers start this far along the ray, so they don't cover the shooter's own face.
const MUZZLE_OFFSET := 0.6
const CHARGE_NODE := &"NetChargeFx"


## One trigger pull: a muzzle flash and a tracer per ray. tos[i] is ray i's end point; hits[i]
## is 1 when it hit something (impact puff).
static func spawn_shots(
	parent: Node, from: Vector3, tos: PackedVector3Array, hits: PackedByteArray
) -> void:
	if parent == null or not parent.is_inside_tree() or tos.is_empty():
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _material(TRACER_COLOR))
	for i in tos.size():
		var start := from
		var dir := tos[i] - from
		if dir.length() > MUZZLE_OFFSET:
			start += dir.normalized() * MUZZLE_OFFSET
		mesh.surface_add_vertex(start)
		mesh.surface_add_vertex(tos[i])
		if i < hits.size() and hits[i] != 0:
			_sphere(parent, tos[i], 0.06, IMPACT_COLOR, IMPACT_TIME)
	mesh.surface_end()
	var line := MeshInstance3D.new()
	line.mesh = mesh
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	line.top_level = true
	parent.add_child(line)
	line.global_transform = Transform3D.IDENTITY
	_free_after(line, TRACER_TIME)
	var aim := tos[0] - from
	var muzzle := from + aim.normalized() * MUZZLE_OFFSET if aim.length() > 0.001 else from
	_sphere(parent, muzzle, 0.09, FLASH_COLOR, FLASH_TIME)


## Charge glow at the body's muzzle point while charging (0..1 grows it); hidden otherwise.
static func set_charge(
	body: Node3D, eye: Vector3, forward: Vector3, on: bool, amount: float
) -> void:
	if body == null or not body.is_inside_tree():
		return
	var glow := body.get_node_or_null(NodePath(String(CHARGE_NODE))) as MeshInstance3D
	if not on:
		if glow != null:
			glow.visible = false
		return
	if glow == null:
		glow = MeshInstance3D.new()
		glow.name = CHARGE_NODE
		var sphere := SphereMesh.new()
		sphere.radius = 0.08
		sphere.height = 0.16
		sphere.material = _material(CHARGE_COLOR)
		glow.mesh = sphere
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glow.top_level = true
		body.add_child(glow)
	glow.visible = true
	glow.global_position = eye + forward * MUZZLE_OFFSET
	glow.scale = Vector3.ONE * lerpf(0.3, 1.4, clampf(amount, 0.0, 1.0))


## Overheat: a short grey vent puff at the muzzle point.
static func vent(parent: Node, at: Vector3) -> void:
	_sphere(parent, at, 0.18, VENT_COLOR, VENT_TIME)


static func _sphere(parent: Node, at: Vector3, radius: float, color: Color, life: float) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var puff := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.material = _material(color)
	puff.mesh = sphere
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	puff.top_level = true
	parent.add_child(puff)
	puff.global_position = at
	_free_after(puff, life)


static func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material


static func _free_after(node: Node, seconds: float) -> void:
	node.get_tree().create_timer(seconds, false).timeout.connect(node.queue_free)
