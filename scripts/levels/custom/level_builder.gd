class_name LevelBuilder
extends RefCounted
## Turns a LevelCatalog item plus a saved object entry into a node, for the editor or a match.
##   editor = true   adds what only the editor needs: visuals for invisible things (spawns, flags,
##                   roam points, volumes), a pick collider on EDITOR_PICK_LAYER for anything
##                   without solid collision, enemies shown frozen (no Brain, no physics),
##                   vehicles frozen, volumes inert.
##   editor = false  the real thing for play: markers named for the systems that find them
##                   (SPAWN_* for SpawnManager, FLAG_* for CtfMatch, group ai_roam_point for
##                   bots), working pickups, lifts, kill volumes, vehicles. Enemies are markers
##                   (meta enemy_type) that CustomArena turns into squads.
## Every built node carries metas: level_object, catalog_id, uid, display_name.

const EDITOR_PICK_LAYER := 1 << 19
const AREA_LAYER := 16
const PICKUP_SCENE := "res://scenes/pickups/weapon_pickup.tscn"
const GRENADE_SCENE := "res://scenes/pickups/grenade_pickup.tscn"
const ENEMY_SCENE := "res://scenes/enemies/enemy.tscn"


## entry: a LevelData object entry ({catalog_id, uid, size, material, scale, props, ...}).
static func build(entry: Dictionary, editor: bool) -> Node3D:
	var id := str(entry.get("catalog_id", ""))
	var item := LevelCatalog.get_item(id)
	if item.is_empty():
		push_warning("LevelBuilder: unknown item '%s' (skipped)" % id)
		return null
	var uid := int(entry.get("uid", 0))
	var props := props_of(item, entry)
	var node: Node3D = null
	match str(item.kind):
		"geometry":
			node = _geometry(item, entry, props)
		"spawn", "flag":
			node = _marker(item, uid, editor)
		"roam":
			node = _roam(uid, props, editor)
		"volume":
			node = _volume(item, entry, props, editor)
		"weapon":
			node = _weapon(item, props, editor)
		"grenade":
			node = _grenades(item, props)
		"enemy":
			node = _enemy(item, uid, editor)
		"vehicle":
			node = _scene(str(item.path), editor)
			if node != null and editor:
				_freeze(node)
		"model":
			node = _model(str(item.path))
		"vfx":
			node = _vfx_emitter(item, props, editor)
		"logic_trigger":
			node = _logic_trigger(item, entry, props, editor)
		"logic_tracker":
			node = _logic_tracker(item, props, editor)
		"logic_door":
			node = _logic_door(item, props, editor)
		"logic_radio":
			node = _logic_radio(item, props, editor)
		"logic_objective":
			node = _logic_objective(item, props, editor)
		"logic_delay":
			node = _logic_delay(item, props, editor)
		"logic_spawner":
			node = _logic_spawner(item, props, editor)
		"custom_mesh":
			node = _custom_mesh(item, props, editor)
		_:
			node = _scene(str(item.path), editor)
	if node == null:
		return null
	if item.get("scalable", false):
		node.scale = Vector3.ONE * float(entry.get("scale", 1.0))
	if item.has("default_size"):
		node.set_meta(&"size", size_of(entry))
	node.set_meta(&"level_object", true)
	node.set_meta(&"catalog_id", id)
	node.set_meta(&"uid", uid)
	node.set_meta(&"display_name", str(entry.get("label", item.name)))
	node.set_meta(&"props", props)
	if editor and not _has_pick(node):
		_add_pick_body(node)
	return node


## The item's default properties with the entry's on top, each kept to its default's type
## (JSON brings every number back as a float: a step count must stay an int).
static func props_of(item: Dictionary, entry: Dictionary) -> Dictionary:
	var props: Dictionary = (item.get("props", {}) as Dictionary).duplicate()
	var saved: Variant = entry.get("props", {})
	if not saved is Dictionary:
		return props
	for key: Variant in saved:
		var value: Variant = saved[key]
		match typeof(props.get(key)):
			TYPE_INT:
				value = int(value)
			TYPE_FLOAT:
				value = float(value)
			TYPE_BOOL:
				value = bool(value)
		props[str(key)] = value
	return props


## Size of a resizable object (geometry or volume); default_size for a fresh one.
static func size_of(entry: Dictionary) -> Vector3:
	var item := LevelCatalog.get_item(str(entry.get("catalog_id", "")))
	var fallback: Vector3 = item.get("default_size", Vector3.ONE)
	var raw: Variant = entry.get("size", null)
	if raw is Array and (raw as Array).size() == 3:
		return Vector3(raw[0], raw[1], raw[2])
	if raw is Vector3:
		return raw
	return fallback


static func is_resizable(id: String) -> bool:
	var item := LevelCatalog.get_item(id)
	return item.has("default_size")


static func is_scalable(id: String) -> bool:
	return bool(LevelCatalog.get_item(id).get("scalable", false))


# ------------------------------------------------------------------ kinds


static func _geometry(item: Dictionary, entry: Dictionary, props: Dictionary) -> Node3D:
	var geo := LevelGeometry.new()
	geo.shape_kind = str(item.shape)
	geo.size = size_of(entry)
	geo.material_id = str(entry.get("material", item.get("material", LevelGeometry.DEFAULT_MATERIAL)))
	geo.params = props
	geo.name = "Geometry"
	return geo


static func _marker(item: Dictionary, uid: int, editor: bool) -> Node3D:
	var marker := Marker3D.new()
	marker.name = "%s_%d" % [item.prefix, uid]
	if editor:
		var color: Color = item.color
		if item.kind == "spawn":
			_add_mesh(marker, _cylinder_mesh(0.6, 0.05), Vector3(0.0, 0.025, 0.0), _glow(color))
			var arrow := _add_mesh(marker, _prism_mesh(Vector3(0.35, 0.08, 0.45)), Vector3(0.0, 0.07, -0.35), _glow(color))
			arrow.rotation_degrees.x = -90.0
		else:
			_add_mesh(marker, _cylinder_mesh(0.9, 0.08), Vector3(0.0, 0.04, 0.0), _glow(color.darkened(0.3)))
			_add_mesh(marker, _cylinder_mesh(0.04, 2.4), Vector3(0.0, 1.2, 0.0), _plain(Color(0.7, 0.7, 0.7)))
			_add_mesh(marker, _box_mesh(Vector3(0.9, 0.55, 0.03)), Vector3(0.45, 2.1, 0.0), _glow(color))
	return marker


static func _roam(uid: int, props: Dictionary, editor: bool) -> Node3D:
	var marker := Marker3D.new()
	marker.name = "RoamPoint_%d" % uid
	marker.add_to_group(&"ai_roam_point", true)
	marker.set_meta(&"weight", float(props.get("weight", 1.0)))
	if editor:
		var diamond := _add_mesh(marker, _box_mesh(Vector3(0.35, 0.35, 0.35)), Vector3(0.0, 0.6, 0.0), _glow(Color(0.4, 0.95, 0.5)))
		diamond.rotation_degrees = Vector3(45.0, 0.0, 45.0)
	return marker


## Grav lift or kill volume: an Area3D box (bottom-centre pivot) at any size.
static func _volume(item: Dictionary, entry: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var size := size_of(entry)
	var area := Area3D.new()
	var lift: bool = item.id == "grav_lift"
	if lift:
		area.set_script(load("res://scripts/levels/grav_lift.gd"))
		area.set(&"lift_speed", float(props.get("lift_speed", 12.0)))
		area.collision_mask = 2
	else:
		area.set_script(load("res://scripts/levels/kill_volume.gd"))
		area.collision_mask = 2 | 4
	area.name = "GravLift" if lift else "KillVolume"
	area.collision_layer = AREA_LAYER
	area.monitorable = false
	area.monitoring = not editor
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position.y = size.y * 0.5
	shape.name = "Shape"
	area.add_child(shape)
	var color := Color(0.3, 0.75, 1.0, 0.18) if lift else Color(1.0, 0.2, 0.15, 0.18)
	if editor or lift:
		# A lift shows in play too (a glowing pad and a faint column); a kill volume doesn't.
		_add_mesh(area, _box_mesh(size), Vector3(0.0, size.y * 0.5, 0.0), _see_through(color))
	if lift:
		_add_mesh(area, _cylinder_mesh(minf(size.x, size.z) * 0.45, 0.06), Vector3(0.0, 0.03, 0.0), _glow(Color(0.3, 0.75, 1.0)))
	return area


static func _weapon(item: Dictionary, props: Dictionary, _editor: bool) -> Node3D:
	var pickup := (load(PICKUP_SCENE) as PackedScene).instantiate() as WeaponPickup
	pickup.weapon_scene = load(str(item.path)) as PackedScene
	pickup.respawn_delay = float(props.get("respawn_delay", 30.0))
	pickup.name = "WeaponPickup"
	_add_mesh(pickup, _cylinder_mesh(0.5, 0.12), Vector3(0.0, 0.06, 0.0), _plain(Color(0.2, 0.22, 0.24)))
	return pickup


static func _grenades(item: Dictionary, props: Dictionary) -> Node3D:
	var pickup := (load(GRENADE_SCENE) as PackedScene).instantiate() as GrenadePickup
	pickup.grenade = load(str(item.path)) as GrenadeData
	pickup.amount = clampi(int(props.get("amount", 2)), 1, 8)
	pickup.respawn_delay = float(props.get("respawn_delay", 30.0))
	pickup.name = "GrenadePickup"
	return pickup


## Match: a marker CustomArena turns into a real enemy. Editor: the real rig, frozen.
static func _enemy(item: Dictionary, uid: int, editor: bool) -> Node3D:
	if not editor:
		var marker := Marker3D.new()
		marker.name = "Enemy_%d" % uid
		marker.set_meta(&"enemy_type", str(item.path))
		return marker
	var e := (load(ENEMY_SCENE) as PackedScene).instantiate() as Enemy
	e.enemy_type = load(str(item.path)) as EnemyType
	e.net_copy = true  # inert: no thinking, no damage, no drops
	var brain := e.get_node_or_null(^"Brain")
	if brain != null:
		e.remove_child(brain)
		brain.free()
	e.name = "Enemy_%d" % uid
	e.ready.connect(func() -> void: e.set_physics_process(false), CONNECT_ONE_SHOT)
	return e


static func _scene(path: String, editor: bool) -> Node3D:
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var node := scene.instantiate() as Node3D
	if editor and node is MovingDummy:
		node.ready.connect(func() -> void: node.set_physics_process(false), CONNECT_ONE_SHOT)
	return node


## A map model: the imported scene plus static trimesh collision on every mesh.
static func _model(path: String) -> Node3D:
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var node := scene.instantiate() as Node3D
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var inst := mesh as MeshInstance3D
		if inst.mesh != null and inst.find_children("*", "CollisionShape3D", true, false).is_empty():
			inst.create_trimesh_collision()
	return node


## Editor: vehicles hold still (and don't drive).
static func _freeze(node: Node) -> void:
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
	node.ready.connect(func() -> void: node.set_physics_process(false), CONNECT_ONE_SHOT)


# ------------------------------------------------------------------ editor picking


static func _has_pick(node: Node) -> bool:
	for child in node.find_children("*", "CollisionObject3D", true, false):
		var body := child as CollisionObject3D
		if body is StaticBody3D or body is RigidBody3D or body is CharacterBody3D:
			if body.collision_layer != 0:
				return true
	return node is LevelGeometry


## A box around the node's meshes on EDITOR_PICK_LAYER, so clicking it selects it.
static func _add_pick_body(node: Node3D) -> void:
	var aabb := local_bounds(node)
	var body := StaticBody3D.new()
	body.name = "EditorPick"
	body.collision_layer = EDITOR_PICK_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size.max(Vector3.ONE * 0.4)
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)
	node.add_child(body)


## The node's visual bounds in its own space (meshes, before it is in the tree).
static func local_bounds(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in node.find_children("*", "VisualInstance3D", true, false):
		var visual := child as VisualInstance3D
		var xform := Transform3D.IDENTITY
		var walk: Node = visual
		while walk != null and walk != node:
			if walk is Node3D:
				xform = (walk as Node3D).transform * xform
			walk = walk.get_parent()
		var box := xform * visual.get_aabb()
		out = box if first else out.merge(box)
		first = false
	if first:
		return AABB(Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 0.6, 0.6))
	return out


# ------------------------------------------------------------------ small visuals


static func _add_mesh(parent: Node3D, mesh: Mesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = at
	inst.material_override = mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(inst)
	return inst


static func _box_mesh(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _cylinder_mesh(radius: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	return m


static func _prism_mesh(size: Vector3) -> PrismMesh:
	var m := PrismMesh.new()
	m.size = size
	return m


static func _plain(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.7
	return m


static func _glow(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 0.8
	return m


static func _see_through(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	return m


static func _vfx_emitter(item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var emitter := EffectEmitter3D.new()
	emitter.name = "VFXEmitter"
	emitter.effect_id = str(item.get("effect_id", "vfx_fuel_explosion"))
	emitter.trigger_mode = str(props.get("trigger_mode", "on_signal"))
	emitter.damage_override = float(props.get("damage_override", -1.0))
	emitter.radius_override = float(props.get("radius_override", -1.0))
	emitter.impulse_override = float(props.get("impulse_override", -1.0))
	emitter.one_shot = bool(props.get("one_shot", true))
	if editor:
		emitter.set_meta(&"editor_mode", true)
	return emitter


static func _logic_trigger(_item: Dictionary, entry: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var trig := TriggerVolume.new()
	trig.name = "TriggerVolume"
	trig.volume_size = size_of(entry)
	trig.filter = str(props.get("filter", "player"))
	trig.trigger_once = bool(props.get("trigger_once", true))
	if editor:
		trig.set_meta(&"editor_mode", true)
	return trig


static func _logic_tracker(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var tracker := OrtaTracker.new()
	tracker.name = "OrtaTracker"
	tracker.squad_id = str(props.get("squad_id", ""))
	if editor:
		tracker.set_meta(&"editor_mode", true)
	return tracker


static func _logic_door(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var door := DoorActuator.new()
	door.name = "DoorActuator"
	door.speed = float(props.get("speed", 3.0))
	door.is_locked = bool(props.get("is_locked", false))
	door.slide_offset = Vector3(0.0, float(props.get("slide_y", 3.5)), 0.0)
	var mesh := LevelGeometry.new()
	mesh.name = "DoorMesh"
	mesh.size = Vector3(3.0, 3.5, 0.4)
	mesh.material_id = "mat_metal_deck"
	door.add_child(mesh)
	if editor:
		door.set_meta(&"editor_mode", true)
	return door


static func _logic_radio(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var radio := RadioTransmitter.new()
	radio.name = "RadioTransmitter"
	radio.callsign = str(props.get("callsign", "COMMAND"))
	radio.subtitle = str(props.get("subtitle", "Proceed to objective."))
	radio.duration = float(props.get("duration", 4.0))
	if editor:
		radio.set_meta(&"editor_mode", true)
	return radio


static func _logic_objective(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var obj := ObjectiveMarker.new()
	obj.name = "ObjectiveMarker"
	obj.objective_id = str(props.get("objective_id", "obj_1"))
	obj.objective_text = str(props.get("text", "Proceed to waypoint"))
	if editor:
		obj.set_meta(&"editor_mode", true)
	return obj


static func _logic_delay(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var delay := DelayRelay.new()
	delay.name = "DelayRelay"
	delay.delay_seconds = float(props.get("delay", 1.0))
	delay.repeat = bool(props.get("repeat", false))
	if editor:
		delay.set_meta(&"editor_mode", true)
	return delay


static func _logic_spawner(_item: Dictionary, props: Dictionary, editor: bool) -> Node3D:
	var spawner := SpawnerNode.new()
	spawner.name = "DynamicSpawner"
	spawner.spawn_item_id = str(props.get("spawn_item_id", "enemy:nefer"))
	spawner.spawn_count = int(props.get("count", 1))
	spawner.spawn_spread = float(props.get("spread", 2.0))
	if editor:
		spawner.set_meta(&"editor_mode", true)
	return spawner


static func _custom_mesh(item: Dictionary, _props: Dictionary, _editor: bool) -> Node3D:
	var path := str(item.get("path", ""))
	var node := MeshLoader.load_mesh(path, "convex")
	return node
