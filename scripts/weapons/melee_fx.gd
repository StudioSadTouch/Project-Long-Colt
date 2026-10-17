class_name MeleeFx
extends RefCounted
## Placeholder melee VFX (static). The gravity hammer's shockwave: a flash and an expanding,
## fading ring on the floor. Spawned by CharacterWeaponProps from the synced animation state
## (a MELEE action with the hammer in hand), so every peer sees every smash with no extra
## network message, the swinger included.

const RING_COLOR := Color(0.45, 0.7, 1.0, 0.85)
const FLASH_COLOR := Color(0.7, 0.85, 1.0, 0.45)
const RING_TIME := 0.45
## Radius the ring grows to (the hammer's smash_radius).
const RING_RADIUS := 4.5


static func shockwave(parent: Node, position: Vector3, radius: float = RING_RADIUS) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.85
	torus.outer_radius = 1.0
	torus.rings = 32
	torus.ring_segments = 6
	ring.mesh = torus
	ring.material_override = _material(RING_COLOR)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.top_level = true
	parent.add_child(ring)
	ring.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(0.2, 0.3, 0.2)), position)
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	flash.mesh = sphere
	flash.material_override = _material(FLASH_COLOR)
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.top_level = true
	parent.add_child(flash)
	flash.global_position = position + Vector3.UP * 0.3
	var tween := ring.create_tween().set_parallel(true)
	tween.tween_property(ring, ^"scale", Vector3(radius, 1.0, radius), RING_TIME).set_ease(
		Tween.EASE_OUT
	).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(ring.material_override, ^"albedo_color:a", 0.0, RING_TIME)
	tween.chain().tween_callback(ring.queue_free)
	var fade := flash.create_tween().set_parallel(true)
	fade.tween_property(flash, ^"scale", Vector3.ONE * 1.8, 0.15)
	fade.tween_property(flash.material_override, ^"albedo_color:a", 0.0, 0.15)
	fade.chain().tween_callback(flash.queue_free)


static func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
