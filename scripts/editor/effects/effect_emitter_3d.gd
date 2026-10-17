class_name EffectEmitter3D
extends Node3D
## In-world entity executing a VFXDefinition.
## Instances particle scenes, plays 3D positional audio, and optionally applies radial damage & knockback.

signal triggered(emitter: EffectEmitter3D)

@export var effect_id: String = "vfx_fuel_explosion"
@export var trigger_mode: String = "on_signal"  # "on_signal", "on_start", "on_touch"
@export var damage_override: float = -1.0       # -1 uses definition default
@export var radius_override: float = -1.0
@export var impulse_override: float = -1.0
@export var one_shot: bool = true

var _triggered: bool = false
var _editor_mode: bool = false


func _init() -> void:
	set_meta(&"logic_node", true)
	set_meta(&"level_object", true)


func get_input_actions() -> Array[String]:
	return ["trigger", "reset"]


func get_output_signals() -> Array[String]:
	return ["triggered"]


func execute_action(action_name: String, _params: Dictionary = {}) -> void:
	match action_name:
		"trigger":
			trigger()
		"reset":
			_triggered = false
		_:
			if has_method(action_name):
				call(action_name)


func _ready() -> void:
	if has_meta(&"editor_mode") and bool(get_meta(&"editor_mode")):
		_editor_mode = true
		_setup_editor_visual()
	elif trigger_mode == "on_start":
		call_deferred(&"trigger")


func _setup_editor_visual() -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "EditorIcon"
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.45, 0.1, 0.8)
	mesh_inst.material_override = mat
	add_child(mesh_inst)


func trigger() -> void:
	if one_shot and _triggered:
		return
	_triggered = true
	triggered.emit(self)

	var vfx := VFXRegistry.get_vfx(effect_id)
	if vfx == null:
		push_warning("EffectEmitter3D: unknown effect_id '%s'" % effect_id)
		return

	# Visual particle instance
	if vfx.effect_scene != null:
		var scene_inst := vfx.effect_scene.instantiate()
		if scene_inst is Node3D:
			get_parent().add_child(scene_inst)
			scene_inst.global_position = global_position
	else:
		_spawn_fallback_particles(vfx)

	# Audio
	if vfx.sound_effect != null:
		var player := AudioStreamPlayer3D.new()
		player.stream = vfx.sound_effect
		player.unit_size = 15.0
		player.max_distance = 60.0
		player.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") != -1 else &"Master"
		get_parent().add_child(player)
		player.global_position = global_position
		player.play()
		player.finished.connect(player.queue_free)

	# Gameplay damage & impulse
	var damage_enabled: bool = vfx.has_gameplay_damage
	var radius: float = radius_override if radius_override >= 0.0 else vfx.damage_radius
	var max_dmg: float = damage_override if damage_override >= 0.0 else vfx.max_damage
	var impulse: float = impulse_override if impulse_override >= 0.0 else vfx.impulse_force

	if damage_enabled and radius > 0.0 and max_dmg > 0.0:
		_apply_radial_impact(radius, max_dmg, impulse)


func _spawn_fallback_particles(vfx: VFXDefinition) -> void:
	var p := CPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = 1.0
	p.amount = 24
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 8.0
	p.gravity = Vector3(0.0, -9.8, 0.0)

	var draw_mesh := SphereMesh.new()
	draw_mesh.radius = 0.15
	draw_mesh.height = 0.3
	p.mesh = draw_mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if vfx.category == "Explosives":
		mat.albedo_color = Color(1.0, 0.4, 0.05)
	elif vfx.category == "Atmospheric":
		mat.albedo_color = Color(0.8, 0.85, 0.9, 0.6)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	else:
		mat.albedo_color = Color(1.0, 0.9, 0.2)
	p.material_override = mat

	get_parent().add_child(p)
	p.global_position = global_position
	p.restart()
	# Auto cleanup particles after finish
	var tree := get_tree()
	if tree != null:
		tree.create_timer(p.lifetime + 0.2).timeout.connect(p.queue_free)


func _apply_radial_impact(radius: float, max_dmg: float, impulse: float) -> void:
	var space := get_world_3d().direct_space_state
	var shape_query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape_query.shape = sphere
	shape_query.transform = Transform3D(Basis.IDENTITY, global_position)
	shape_query.collision_mask = 2 | 4 | 8  # Players, Bots, Enemies

	var hits := space.intersect_shape(shape_query, 32)
	var damaged: Dictionary = {}
	for hit in hits:
		var collider: Object = hit.get("collider", null)
		var receiver := _find_damage_receiver(collider)
		if receiver == null or damaged.has(receiver):
			continue
		damaged[receiver] = true

		var target_pos: Vector3 = (receiver as Node3D).global_position if receiver is Node3D else global_position
		var to_target := target_pos - global_position
		var dist := to_target.length()
		var fraction := clampf(1.0 - (dist / radius), 0.0, 1.0)
		var damage := max_dmg * fraction

		var dir := to_target.normalized() if dist > 0.001 else Vector3.UP
		var target_impulse := dir * (impulse * fraction)

		var info := {
			"direction": dir,
			"impulse": target_impulse,
			"source": self,
			"weapon": effect_id,
			"zone": "body",
			"zone_multiplier": 1.0,
		}

		if receiver.has_method(&"take_damage"):
			receiver.call(&"take_damage", damage, info)
		elif receiver.has_node("HealthShield"):
			var hs := receiver.get_node("HealthShield")
			if hs.has_method(&"apply_damage"):
				hs.call(&"apply_damage", damage, info)

		if receiver.has_method(&"apply_knockback"):
			var kb := Knockback.blast(dir, damage, max_dmg)
			receiver.call(&"apply_knockback", kb)


static func _find_damage_receiver(collider: Variant) -> Node:
	if not (collider is Node) or not is_instance_valid(collider):
		return null
	var node := collider as Node
	while node != null:
		if node.has_method(&"take_damage") or node.has_node("HealthShield"):
			return node
		node = node.get_parent()
	return null
