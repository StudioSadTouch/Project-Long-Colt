class_name Rocket
extends Node3D
## A rocket from a projectile weapon (WeaponData.projectile_speed > 0). Built in code, no scene.
## Flies straight at projectile_speed, swept by a ray each physics tick so it can't tunnel, and
## goes off on the first World / Enemy / Hitbox / Player collider it touches (the shooter's own
## colliders and non-hitbox Areas are skipped, as for hitscan), or after data.max_range.
##
## authoritative = this copy deals the blast (offline, or the host online). A net client's copy
## (its own shot, or a remote shot from NetMatch._rpc_shot_fx) is visual only: same flight, same
## explosion FX, no damage. The blast is Grenade.apply_blast with data.blast, so the shooter is
## hurt too (Halo rules) and the kill goes to them via info.source.

signal exploded(rocket: Rocket, at: Vector3)

## Fallen out of the level.
const KILL_Y := -60.0
## Detonation point is pulled back off the surface so the blast's line-of-sight rays start clear.
const SURFACE_BACKOFF := 0.1

var data: WeaponData
## Who fired it (kill credit). May be freed before the blast.
var shooter: Node3D
var authoritative: bool = true
var velocity: Vector3 = Vector3.ZERO
var hit_mask: int = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
## Colliders the flight never hits (the shooter's own).
var exclude: Array[RID] = []

var _travelled: float = 0.0
var _done: bool = false


## Fire one: added under parent at origin flying along direction. Returns the rocket.
static func spawn(
	parent: Node,
	weapon_data: WeaponData,
	origin: Vector3,
	direction: Vector3,
	by: Node3D,
	skip: Array[RID] = [],
	is_authoritative: bool = true,
	mask: int = Weapon.HIT_MASK | Weapon.LAYER_PLAYER
) -> Rocket:
	var rocket := Rocket.new()
	rocket.data = weapon_data
	rocket.shooter = by
	rocket.authoritative = is_authoritative
	rocket.exclude = skip
	rocket.hit_mask = mask
	rocket.velocity = direction.normalized() * weapon_data.projectile_speed
	rocket.name = "Rocket"
	rocket.top_level = true
	parent.add_child(rocket)
	rocket.global_position = origin
	if rocket.velocity.length_squared() > 0.0001:
		var up := Vector3.UP if absf(direction.normalized().y) < 0.99 else Vector3.FORWARD
		rocket.look_at(origin + rocket.velocity, up)
	return rocket


func _ready() -> void:
	if data == null or data.blast == null or data.projectile_speed <= 0.0:
		push_error("Rocket without projectile WeaponData")
		queue_free()
		return
	add_child(_make_mesh())
	var light := OmniLight3D.new()
	light.light_color = data.projectile_glow
	light.light_energy = 1.5
	light.omni_range = 3.0
	light.position = Vector3(0.0, 0.0, 0.3)
	add_child(light)


func _make_mesh() -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var tube := CylinderMesh.new()
	tube.top_radius = 0.06
	tube.bottom_radius = 0.06
	tube.height = 0.5
	body.mesh = tube
	body.rotation = Vector3(PI * 0.5, 0.0, 0.0)  # cylinder axis Y -> flight axis -Z
	var shell := StandardMaterial3D.new()
	shell.albedo_color = data.projectile_color
	shell.roughness = 0.7
	body.material_override = shell
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(body)
	var flame := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.08
	ball.height = 0.16
	flame.mesh = ball
	flame.position = Vector3(0.0, 0.0, 0.28)
	var hot := StandardMaterial3D.new()
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot.albedo_color = data.projectile_glow
	flame.material_override = hot
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flame)
	return root


func _physics_process(delta: float) -> void:
	if _done:
		return
	var from := global_position
	if data.projectile_gravity > 0.0:
		velocity.y -= data.projectile_gravity * delta
		if velocity.length_squared() > 0.0001 and absf(velocity.normalized().y) < 0.99:
			look_at(from + velocity, Vector3.UP)
	var step := velocity * delta
	var hit := _sweep(from, from + step)
	if not hit.is_empty():
		var normal: Vector3 = hit.get("normal", Vector3.ZERO)
		detonate_at(hit.position + normal * SURFACE_BACKOFF)
		return
	global_position = from + step
	_travelled += step.length()
	if _travelled >= data.max_range or global_position.y < KILL_Y:
		detonate_at(global_position)


## First collider on the flight segment that a shot would hit (Weapon's skip rules).
func _sweep(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, hit_mask)
	query.collide_with_areas = true
	var skip: Array[RID] = []
	skip.assign(exclude)
	var space := get_world_3d().direct_space_state
	for _i in Weapon.MAX_AREA_SKIPS:
		query.exclude = skip
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not Weapon.is_ignored_collider(hit.collider):
			return hit
		skip.append(hit.rid)
	return {}


## Goes off at `at`. Safe to call more than once.
func detonate_at(at: Vector3) -> void:
	if _done:
		return
	_done = true
	var scene := get_tree().current_scene
	Grenade.spawn_explosion_fx(scene if scene != null else get_tree().root, at, data.blast)
	if authoritative:
		# The shooter may have left (or been freed) mid-flight: no credit then.
		var by: Node3D = shooter if is_instance_valid(shooter) else null
		Grenade.apply_blast(get_world_3d().direct_space_state, at, data.blast, by)
	exploded.emit(self, at)
	queue_free()
