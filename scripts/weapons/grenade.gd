class_name Grenade
extends RigidBody3D
## A thrown grenade (GrenadeData). Built in code, no scene. FRAG bounces and goes off fuse_time
## after the throw; STICKY sticks to the first world surface or body it touches (it is
## reparented to that body, so it rides along) and goes off fuse_time after sticking.
##
## authoritative = this copy deals the damage (offline, or the host online). A net client's copy
## is visual only: it never deals damage and, when its fuse runs out, it waits for the host's
## detonate_at() (NetMatch._rpc_grenade_boom), going off on its own only after NET_GRACE.
##
## The blast: every damageable (take_damage) with a collider inside blast_radius on the Player /
## Enemy / Hitbox layers, once each, with a clear line of sight from the blast to its body point
## (World layer only blocks). Damage is full to inner_radius, linear to 0 at blast_radius. The
## thrower is hurt too (Halo rules); the kill goes to the thrower via info.source.

signal exploded(grenade: Grenade, at: Vector3)

const WORLD_MASK := 1
## Player (2) | Enemy (4) | Hitbox (32): the bodies a blast can hurt, and what a sticky sticks to.
const BODY_MASK := 2 | 4 | 32
## Seconds a net client's copy waits past its fuse for the host's detonation before going off.
const NET_GRACE := 0.75
const BOUNCE_SOUND_GAP := 0.12
const BOUNCE_SOUND_MIN_SPEED := 2.0
## Fallen out of the level.
const KILL_Y := -60.0

const SOUND_BOUNCE := preload("res://assets/audio/weapons/grenades/frag_bounce.wav")
const SOUND_STICK := preload("res://assets/audio/weapons/grenades/sticky_stick.wav")
const SOUND_FUSE := preload("res://assets/audio/weapons/grenades/sticky_fuse.wav")
const SOUND_FRAG_BOOM := preload("res://assets/audio/weapons/grenades/frag_explode.wav")
const SOUND_STICKY_BOOM := preload("res://assets/audio/weapons/grenades/sticky_explode.wav")

var data: GrenadeData
## Who threw it (kill credit, collision exceptions). May be freed before the blast.
var thrower: Node3D
var authoritative: bool = true
## NetMatch's id for this grenade (0 offline).
var net_id: int = 0
var stuck: bool = false

var _fuse_left: float = 0.0
var _flight: float = 0.0
var _done: bool = false
var _bounce_gap: float = 0.0
var _voice: AudioStreamPlayer3D


## Throw one: added under parent at origin with velocity. Returns the grenade.
static func spawn(
	parent: Node,
	grenade_data: GrenadeData,
	origin: Vector3,
	velocity: Vector3,
	by: Node3D,
	is_authoritative: bool = true
) -> Grenade:
	var grenade := Grenade.new()
	grenade.data = grenade_data
	grenade.thrower = by
	grenade.authoritative = is_authoritative
	grenade.name = "Grenade"
	parent.add_child(grenade)
	grenade.global_position = origin
	grenade.linear_velocity = velocity
	return grenade


func _ready() -> void:
	if data == null:
		push_error("Grenade without GrenadeData")
		queue_free()
		return
	collision_layer = 0
	collision_mask = WORLD_MASK | BODY_MASK
	mass = data.mass
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	can_sleep = false
	var surface := PhysicsMaterial.new()
	surface.bounce = data.bounce
	surface.friction = data.friction
	physics_material_override = surface
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = data.radius
	shape.shape = sphere
	add_child(shape)
	add_child(_make_mesh())
	_voice = AudioStreamPlayer3D.new()
	_voice.unit_size = 4.0
	_voice.max_distance = 40.0
	add_child(_voice)
	if is_instance_valid(thrower):
		for body in _colliders_of(thrower):
			add_collision_exception_with(body)
	body_entered.connect(_on_body_entered)
	_fuse_left = data.fuse_time


func _make_mesh() -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = data.color
	material.roughness = 0.6
	if data.glow.a > 0.0:
		material.emission_enabled = true
		material.emission = data.glow
		material.emission_energy_multiplier = 2.5
	if data.kind == GrenadeData.Kind.FRAG:
		var body := CapsuleMesh.new()
		body.radius = data.radius
		body.height = data.radius * 2.6
		mesh.mesh = body
	else:
		var ball := SphereMesh.new()
		ball.radius = data.radius
		ball.height = data.radius * 2.0
		mesh.mesh = ball
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mesh


func _physics_process(delta: float) -> void:
	if _done:
		return
	_bounce_gap = maxf(_bounce_gap - delta, 0.0)
	if global_position.y < KILL_Y:
		queue_free()
		return
	if data.kind == GrenadeData.Kind.STICKY and not stuck:
		_flight += delta
		if _flight >= data.max_flight_time:
			_fuse_out()
		return
	_fuse_left -= delta
	if _fuse_left <= 0.0:
		_fuse_out()


func _fuse_out() -> void:
	if authoritative:
		detonate_at(global_position)
	elif _fuse_left <= -NET_GRACE or (not stuck and _flight >= data.max_flight_time + NET_GRACE):
		# The host's detonation never came (lost, or the host's copy went elsewhere).
		detonate_at(global_position)


func _on_body_entered(body: Node) -> void:
	if _done:
		return
	if data.kind == GrenadeData.Kind.STICKY:
		if not stuck:
			_stick.call_deferred(body)
		return
	if _bounce_gap <= 0.0 and linear_velocity.length() >= BOUNCE_SOUND_MIN_SPEED:
		_bounce_gap = BOUNCE_SOUND_GAP
		_play(SOUND_BOUNCE, -6.0, randf_range(0.92, 1.1))


func _stick(body: Node) -> void:
	if stuck or _done or not is_instance_valid(body):
		return
	stuck = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_mask = 0
	contact_monitor = false
	if body is Node3D:
		reparent(body, true)
	_fuse_left = data.fuse_time
	_play(SOUND_STICK, -2.0, randf_range(0.95, 1.05))
	# A second voice for the fuse hiss so the stick thud isn't cut off.
	var hiss := AudioStreamPlayer3D.new()
	hiss.stream = SOUND_FUSE
	hiss.unit_size = 3.0
	hiss.max_distance = 30.0
	hiss.volume_db = -4.0
	add_child(hiss)
	hiss.play()


## Goes off at `at` (the host sends its position to clients). Safe to call more than once.
func detonate_at(at: Vector3) -> void:
	if _done:
		return
	_done = true
	var root := _world_root()
	spawn_explosion_fx(root, at, data)
	if authoritative:
		apply_blast(get_world_3d().direct_space_state, at, data, thrower, self)
	exploded.emit(self, at)
	queue_free()


func _world_root() -> Node:
	var scene := get_tree().current_scene
	return scene if scene != null else get_tree().root


func _play(stream: AudioStream, db: float, pitch: float) -> void:
	if _voice == null:
		return
	_voice.stream = stream
	_voice.volume_db = db
	_voice.pitch_scale = pitch
	_voice.play()


## The blast's damage. Returns {receiver: damage dealt-request} for tests and tuning.
static func apply_blast(
	space: PhysicsDirectSpaceState3D,
	center: Vector3,
	grenade_data: GrenadeData,
	by: Node3D,
	exclude: CollisionObject3D = null
) -> Dictionary:
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = grenade_data.blast_radius
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.collision_mask = BODY_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if exclude != null:
		query.exclude = [exclude.get_rid()]
	var receivers: Dictionary = {}
	for result: Dictionary in space.intersect_shape(query, 64):
		var receiver := _damage_receiver(result.get("collider"))
		if receiver != null:
			receivers[receiver] = true
	var dealt: Dictionary = {}
	for receiver: Variant in receivers:
		var node := receiver as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var point := _body_point(node)
		var distance := center.distance_to(point)
		if distance > grenade_data.blast_radius or not _clear_line(space, center, node, point):
			continue
		var t := inverse_lerp(grenade_data.inner_radius, grenade_data.blast_radius, distance)
		var amount := grenade_data.damage * (1.0 - clampf(t, 0.0, 1.0))
		if amount <= 0.0:
			continue
		var direction := point - center
		direction = direction.normalized() if direction.length_squared() > 0.0001 else Vector3.UP
		var info := {
			"position": point,
			"direction": direction,
			"dir": direction,
			"hit_zone": 0,
			"hit_zone_name": "body",
			"headshot": false,
			"zone_multiplier": 1.0,
			"shield_multiplier": grenade_data.shield_damage_multiplier,
			"bleedthrough": grenade_data.bleedthrough,
			"weapon": grenade_data.display_name,
			"grenade": true,
			"source": by if is_instance_valid(by) else null,
		}
		node.call(&"take_damage", amount, info)
		dealt[node] = amount
	return dealt


## Where the blast aims at a body: its "body" aim point, else 0.9 m above its origin.
static func _body_point(node: Node3D) -> Vector3:
	if node.has_method(&"get_aim_points"):
		var points: Dictionary = node.call(&"get_aim_points")
		if points.has("body"):
			return points.body
	return node.global_position + Vector3.UP * 0.9


## World geometry between the blast and the body blocks it. A grenade stuck to (or lying on) the
## body never blocks itself: only the World layer is tested.
static func _clear_line(
	space: PhysicsDirectSpaceState3D, from: Vector3, node: Node3D, point: Vector3
) -> bool:
	for target: Vector3 in [point, node.global_position + Vector3.UP * 0.3]:
		var ray := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.05, target, WORLD_MASK)
		if space.intersect_ray(ray).is_empty():
			return true
	return false


static func _damage_receiver(collider: Variant) -> Node:
	if not (collider is Node) or not is_instance_valid(collider):
		return null
	var node := collider as Node
	while node != null:
		if node.has_method(&"take_damage"):
			return node
		node = node.get_parent()
	return null


static func _colliders_of(node: Node3D) -> Array[CollisionObject3D]:
	var out: Array[CollisionObject3D] = []
	if node.has_method(&"get_own_colliders"):
		for body: Variant in node.call(&"get_own_colliders"):
			if body is CollisionObject3D:
				out.append(body)
		return out
	if node is CollisionObject3D:
		out.append(node as CollisionObject3D)
	for child in node.find_children("*", "CollisionObject3D", true, false):
		out.append(child as CollisionObject3D)
	return out


## Flash, fireball and boom at `at`, under parent; frees itself.
static func spawn_explosion_fx(parent: Node, at: Vector3, grenade_data: GrenadeData) -> void:
	var fx := Node3D.new()
	fx.name = "GrenadeBlast"
	parent.add_child(fx)
	fx.global_position = at
	var light := OmniLight3D.new()
	light.light_color = grenade_data.flash_color
	light.light_energy = 10.0
	light.omni_range = grenade_data.blast_radius * 2.0
	fx.add_child(light)
	var ball := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	ball.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = grenade_data.flash_color
	ball.material_override = material
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.add_child(ball)
	var boom := AudioStreamPlayer3D.new()
	var sticky := grenade_data.kind == GrenadeData.Kind.STICKY
	boom.stream = SOUND_STICKY_BOOM if sticky else SOUND_FRAG_BOOM
	boom.unit_size = 10.0
	boom.max_distance = 150.0
	boom.pitch_scale = randf_range(0.94, 1.04)
	fx.add_child(boom)
	boom.play()
	var grow := grenade_data.blast_radius * 1.2
	var tween := fx.create_tween().set_parallel(true)
	tween.tween_property(light, "light_energy", 0.0, 0.35)
	tween.tween_property(ball, "scale", Vector3.ONE * grow, 0.25)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.3)
	fx.get_tree().create_timer(2.0, false).timeout.connect(fx.queue_free)
