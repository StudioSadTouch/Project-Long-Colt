# gdlint: disable=max-public-methods, max-returns
class_name Bot
extends CharacterBody3D
## Arena combat bot body: player-identical movement, HealthShield, dummy-rig hitboxes, two
## weapon slots (BotWeapon on the existing WeaponData), melee lunge, weapon pickups. The Brain
## child (BotBrain) writes move_wish / want_crouch, calls set_aim(), request_jump(), fire, melee.
##
## Collision layout (see docs/ai/arena_ai_spec.md):
##   root capsule  layer 0, mask World | Player | Enemy. Movement only; weapons never hit it,
##                 because a 0.35 m capsule would cover the visor and turn head shots into body.
##   Hurtbox       AnimatableBody3D on Enemy (4), box 0.7 x 1.4 x 0.4 like the dummies.
##   Rig heads     HeadArmored / HeadUnarmored on Hitbox (32), from dummy_rig.tscn.
## Damage: take_damage on the root only, so Weapon's receiver (nearest ancestor with
## take_damage) is always the Bot for hurtbox and head hits alike (keeps the visor probe's
## same-target check working). KillVolume, GravLift, WeaponPickup and AmmoCrate see the
## Hurtbox (Enemy layer) and resolve its parent Bot (take_damage / group lift_rider / group
## pickup_carrier).

signal died(bot: Bot, killer: Node, info: Dictionary)
signal respawned(bot: Bot)
## amount is shield plus health actually removed.
signal damaged(amount: float, info: Dictionary)
signal weapon_changed(weapon: BotWeapon)

# Movement constants DUPLICATED from scripts/player/player.gd @ a5e85f3 (exports and consts).
# Not imported on purpose; keep in sync by hand if the player's tuning changes.
const STAND_SPEED := 7.5
const CROUCH_SPEED := 3.2
const GROUND_ACCEL := 70.0
const AIR_ACCEL := 18.0
const JUMP_HEIGHT := 2.2
const COYOTE_TIME := 0.1
const JUMP_BUFFER_TIME := 0.12
const EYE_BLEND_SPEED := 12.0
const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.15
const CAPSULE_RADIUS := 0.35
const STAND_EYE := 1.62
const CROUCH_EYE := 0.95
const PITCH_LIMIT := 89.0
const FLOOR_SNAP := 0.3
const FLOOR_MAX_ANGLE_DEG := 50.0

const SLOT_COUNT := 2
const ENEMY_LAYER := 4
const MOVE_MASK := 1 | 2 | 4
const HURTBOX_HEIGHT := 1.4
const HURTBOX_MIN_HEIGHT := 0.7
## Horizontal reach to take or top up from a WeaponPickup.
const DROP_MASK := 1
## Half the spacing between the two weapons a dead bot drops (Halo 2 drops both). The pickup
## trigger spheres have radius 1.0, so 2 x 1.1 m keeps them apart; walls shorten it.
const DROP_SPREAD := 1.1
const BODY_AIM_HEIGHT := 0.7

@export var display_name: String = "Bot"
## Same team = friendly. SpawnManager assigns unique teams in FFA. Player is team 0.
@export var team: int = 1
## Player weapon scenes (service_pistol.tscn, standard_issue_rifle.tscn): data is read from the
## scene's root, and the scene is used to build a real pickup when the bot drops the weapon.
@export var starting_weapons: Array[PackedScene] = []
@export var difficulty: BotDifficulty
@export var drop_weapon_on_death: bool = true
## Name / state / shield / health above the bot. The rig's Label3D ignores depth, so it shows
## through walls: debug only.
@export var show_debug_label: bool = false
## AmmoCrates serve every pickup carrier in reach through get_weapons(). Off: bots ignore crates
## (design decision); weapon pickups still top bots up.
@export var use_ammo_crates: bool = false
## Node whose position is get_aim_points().head. A node, not a hard-coded helmet centre, so it
## can move if AimAssist's head point moves (e.g. top/back of the helmet).
@export var head_aim_path: NodePath = ^"Rig/AimHeadPoint"
@export var face_aim_path: NodePath = ^"Rig/HeadUnarmored/VisorShape"

var gravity: float = 22.0
var crouched: bool = false
var dead: bool = false
var slots: Array[BotWeapon] = []
var active_index: int = 0
## Brain inputs. World-space horizontal wish, length 0..1 (scales run speed on the ground).
var move_wish: Vector3 = Vector3.ZERO
var want_crouch: bool = false
## Last damage info and its source (kill credit).
var last_damage_info: Dictionary = {}

var _eye_height: float = STAND_EYE
var _coyote_left: float = 0.0
var _jump_buffer_left: float = 0.0
var _lunge_dir: Vector3 = Vector3.ZERO
var _lunge_speed: float = 0.0
var _lunge_left: float = 0.0
var _lunge_target: Node3D
var _melee_left: float = 0.0
var _aim_dir: Vector3 = Vector3.FORWARD
var _stand_probe: CapsuleShape3D
var _layers: Dictionary = {}
## Stance the hurtbox was last sized for (-1 = not yet): resized on stance changes only.
var _hurtbox_stance: int = -1

@onready var head: Node3D = $Head
@onready var eye: Node3D = $Head/Eye
@onready var weapon_mount: Node3D = $Head/Eye/WeaponMount
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var hurtbox: AnimatableBody3D = $Hurtbox
@onready var hurtbox_shape: CollisionShape3D = $Hurtbox/Shape
@onready var rig: Node3D = $Rig
@onready var health_shield: HealthShield = $HealthShield
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var label: Label3D = get_node_or_null(^"Rig/HPLabel") as Label3D


func _ready() -> void:
	gravity = get_gravity().length()
	collision_layer = 0
	collision_mask = MOVE_MASK
	floor_snap_length = FLOOR_SNAP
	floor_max_angle = deg_to_rad(FLOOR_MAX_ANGLE_DEG)
	hurtbox.collision_layer = ENEMY_LAYER
	hurtbox.collision_mask = 0
	add_collision_exception_with(hurtbox)
	for body in get_own_colliders():
		_layers[body] = body.collision_layer
	_layers[self] = 0
	_stand_probe = CapsuleShape3D.new()
	_stand_probe.radius = CAPSULE_RADIUS
	_stand_probe.height = STAND_HEIGHT - 0.06
	_apply_capsule()
	add_to_group(&"bot")
	add_to_group(&"aim_target")
	add_to_group(&"lift_rider")  # GravLift pushes this group
	add_to_group(WeaponPickup.CARRIER_GROUP)  # pickups and crates see the Hurtbox, then the Bot
	health_shield.died.connect(_on_health_died)
	health_shield.changed.connect(_on_health_changed)
	slots.resize(SLOT_COUNT)
	_give_starting_weapons()
	if difficulty != null:
		nav_agent.navigation_layers = 1 | (2 if difficulty.use_skill_jumps else 0)
	if label != null:
		label.visible = show_debug_label
	_on_health_changed(health_shield.shield, health_shield.health)


# ------------------------------------------------------------------ public API


func is_dead() -> bool:
	return dead


func get_eye_position() -> Vector3:
	return eye.global_position


## Current look direction (aim before recoil).
func get_look_direction() -> Vector3:
	return _aim_dir


## AimAssist targets (group aim_target). Same format as DummyCore.get_aim_points():
## body centre, helmet ("head"), visor ("face"). Empty while dead.
func get_aim_points() -> Dictionary:
	if dead:
		return {}
	var points := {"body": rig.global_position + Vector3.UP * BODY_AIM_HEIGHT}
	var head_node := get_node_or_null(head_aim_path) as Node3D
	if head_node != null:
		points["head"] = head_node.global_position
	var face_node := get_node_or_null(face_aim_path) as Node3D
	if face_node != null:
		points["face"] = face_node.global_position
	return points


## Every collider the bot's own weapons must ignore.
func get_own_colliders() -> Array[CollisionObject3D]:
	var bodies: Array[CollisionObject3D] = [self]
	for path: NodePath in [^"Hurtbox", ^"Rig/HeadArmored", ^"Rig/HeadUnarmored"]:
		var body := get_node_or_null(path) as CollisionObject3D
		if body != null:
			bodies.append(body)
	return bodies


## Applies aim immediately (body yaw, head pitch, eye recoil) so a shot fired this tick uses it.
func set_aim(direction: Vector3) -> void:
	if direction.length_squared() < 0.0001:
		return
	_aim_dir = direction.normalized()
	rotation.y = atan2(-_aim_dir.x, -_aim_dir.z)
	var limit := deg_to_rad(PITCH_LIMIT)
	head.rotation.x = clampf(asin(clampf(_aim_dir.y, -1.0, 1.0)), -limit, limit)
	var weapon := get_active()
	var recoil := weapon.get_recoil() if weapon != null else Vector2.ZERO
	eye.rotation = Vector3(recoil.x, recoil.y, 0.0)


func request_jump() -> void:
	_jump_buffer_left = JUMP_BUFFER_TIME


func get_active() -> BotWeapon:
	if slots.is_empty():
		return null
	return slots[active_index]


func get_other() -> BotWeapon:
	if slots.is_empty():
		return null
	return slots[(active_index + 1) % SLOT_COUNT]


func switch_weapon() -> void:
	var other := (active_index + 1) % SLOT_COUNT
	if slots[other] != null:
		_equip(other)


func find_weapon(weapon_id: String) -> BotWeapon:
	if weapon_id == "":
		return null
	for w in slots:
		if w != null and WeaponPickup.weapon_id_of(w) == weapon_id:
			return w
	return null


func total_ammo(weapon: BotWeapon) -> int:
	return weapon.magazine + weapon.reserve if weapon != null else 0


## Melee with the same cooldown rule as WeaponHolder (owned here so switching can't skip it).
## In melee_range: swing now. In lunge range: lunge (player rules) and swing on arrival.
func try_melee(target: Node3D, target_point: Vector3) -> bool:
	var weapon := get_active()
	if weapon == null or weapon.data == null or _melee_left > 0.0 or dead:
		return false
	var distance := eye.global_position.distance_to(target_point)
	if distance > weapon.data.melee_lunge_range:
		return false
	_melee_left = weapon.data.melee_cooldown
	if distance <= weapon.data.melee_range:
		# Halo melee: snap to the body point, no aim error (same as the lunge's arrival swing).
		set_aim(target_point - eye.global_position)
		weapon.melee()
		return true
	var duration := (distance - weapon.data.melee_range) / weapon.data.melee_lunge_speed + 0.1
	start_lunge(target_point - global_position, weapon.data.melee_lunge_speed, duration)
	_lunge_target = target
	return true


func is_melee_ready() -> bool:
	return _melee_left <= 0.0


func start_lunge(direction: Vector3, speed: float, duration: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001 or duration <= 0.0:
		return
	_lunge_dir = flat.normalized()
	_lunge_speed = speed
	_lunge_left = duration


## Same rule as Player.cancel_lunge: clamp to run speed so jump + melee can't boost.
func cancel_lunge() -> void:
	_lunge_target = null
	if _lunge_left <= 0.0:
		return
	_lunge_left = 0.0
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).limit_length(STAND_SPEED)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func is_lunging() -> bool:
	return _lunge_left > 0.0


## Weapon contract. Records the source for kill credit, then HealthShield applies the rules.
func take_damage(amount: float, info: Dictionary) -> void:
	if dead:
		return
	last_damage_info = info
	var result := health_shield.apply_damage(amount, info)
	var applied: float = result.shield + result.health
	if applied > 0.0:
		damaged.emit(applied, info)
		# Halo: taking damage knocks you out of zoom.
		var weapon := get_active()
		if weapon != null:
			weapon.set_zoom(false)


## Pickup carrier API (WeaponPickup's duck-typed contract, as WeaponHolder): the brain calls
## pickup.is_useful_to(self) / is_in_reach(self) / try_pickup(self); walk-over ammo from weapon
## pickups is applied by the pickup itself (it uses find_weapon). Installs a weapon the pickup
## hands over: an empty slot first, else it replaces the active weapon and drops that one.
func take_pickup(pickup: WeaponPickup) -> bool:
	if dead or pickup == null:
		return false
	var taken := pickup.take()
	if taken == null:
		return false
	var w := _weapon_from_taken(taken)
	if w == null:
		return false
	var empty := slots.find(null)
	if empty >= 0:
		_install(w, empty)
		_equip(empty)
		return true
	var old := _install(w, active_index)
	_equip(active_index)
	if old != null:
		_drop(old)
	return true


## Carried weapons for AmmoCrate, its only caller. Bots ignore ammo crates (Morgon), so this is
## empty unless use_ammo_crates is set; the crate then has nothing to fill and leaves bots alone.
func get_weapons() -> Array[Weapon]:
	var out: Array[Weapon] = []
	if not use_ammo_crates:
		return out
	for w in slots:
		if w != null:
			out.append(w)
	return out


func respawn_at(xform: Transform3D) -> void:
	global_transform = Transform3D(Basis(), xform.origin)
	velocity = Vector3.ZERO
	cancel_lunge()
	_melee_left = 0.0
	crouched = false
	want_crouch = false
	move_wish = Vector3.ZERO
	_eye_height = STAND_EYE
	_apply_capsule()
	_apply_pose()
	for body: CollisionObject3D in _layers:
		body.collision_layer = _layers[body]
	collision_mask = MOVE_MASK
	collision_shape.disabled = false
	health_shield.reset()
	last_damage_info = {}
	_clear_weapons()
	_give_starting_weapons()
	dead = false
	visible = true
	set_aim(-xform.basis.z)
	respawned.emit(self)


# ------------------------------------------------------------------ physics


func _physics_process(delta: float) -> void:
	if dead:
		return
	gravity = get_gravity().length()
	_melee_left = maxf(_melee_left - delta, 0.0)
	var on_floor_before := is_on_floor()
	if on_floor_before:
		_coyote_left = COYOTE_TIME
	_update_stance()
	var wish := Vector3(move_wish.x, 0.0, move_wish.z).limit_length(1.0)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if _lunge_left > 0.0:
		_lunge_left -= delta
		horizontal = _lunge_dir * _lunge_speed
		if _lunge_left <= 0.0:
			horizontal = horizontal.limit_length(STAND_SPEED)
	elif on_floor_before:
		var speed := CROUCH_SPEED if crouched else STAND_SPEED
		horizontal = horizontal.move_toward(wish * speed, GROUND_ACCEL * delta)
	else:
		horizontal = _apply_air(
			horizontal, wish.normalized() if wish.length_squared() > 0.0001 else Vector3.ZERO, delta
		)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	var jumped := _consume_jump()
	# Trapezoid gravity around the move, as in player.gd, so the jump apex is tick-independent.
	var airborne := jumped or not on_floor_before
	if jumped:
		velocity.y = sqrt(2.0 * gravity * JUMP_HEIGHT)
	elif not airborne and velocity.y < 0.0:
		velocity.y = 0.0
	if airborne:
		velocity.y -= gravity * delta * 0.5
	move_and_slide()
	if airborne and not is_on_floor():
		velocity.y -= gravity * delta * 0.5
	if jumped:
		_coyote_left = 0.0
	elif is_on_floor():
		_coyote_left = COYOTE_TIME
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)
	_jump_buffer_left = maxf(_jump_buffer_left - delta, 0.0)
	_tick_lunge_melee()
	_update_eye(delta)


func _apply_air(horizontal: Vector3, wish: Vector3, delta: float) -> Vector3:
	if wish == Vector3.ZERO:
		return horizontal
	var along := horizontal.dot(wish)
	var add_speed := STAND_SPEED - along
	if add_speed <= 0.0:
		return horizontal
	return horizontal + wish * minf(AIR_ACCEL * delta, add_speed)


func _consume_jump() -> bool:
	if _jump_buffer_left <= 0.0 or _lunge_left > 0.0:
		return false
	if not is_on_floor() and _coyote_left <= 0.0:
		return false
	_jump_buffer_left = 0.0
	_coyote_left = 0.0
	return true


func _tick_lunge_melee() -> void:
	if _lunge_target == null:
		return
	var weapon := get_active()
	if not is_instance_valid(_lunge_target) or weapon == null or weapon.data == null:
		cancel_lunge()
		return
	var points := ArenaEvents.aim_points_of(_lunge_target)
	if points.is_empty():
		cancel_lunge()
		return
	var point: Vector3 = points.body
	if eye.global_position.distance_to(point) <= weapon.data.melee_range:
		cancel_lunge()
		set_aim(point - eye.global_position)
		weapon.melee()
	elif not is_lunging():
		_lunge_target = null


func _update_stance() -> void:
	if want_crouch:
		crouched = true
	elif crouched and _can_stand():
		crouched = false
	_apply_capsule()


func _can_stand() -> bool:
	var space := get_world_3d().direct_space_state
	var margin := 0.06
	var test_height := STAND_HEIGHT - margin
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _stand_probe
	params.transform = Transform3D(
		Basis(), global_position + Vector3.UP * (margin + test_height * 0.5)
	)
	params.collision_mask = 1
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).is_empty()


func _apply_capsule() -> void:
	var height := CROUCH_HEIGHT if crouched else STAND_HEIGHT
	var shape := collision_shape.shape as CapsuleShape3D
	shape.radius = CAPSULE_RADIUS
	shape.height = height
	collision_shape.position = Vector3(0.0, height * 0.5, 0.0)


func _update_eye(delta: float) -> void:
	var target := CROUCH_EYE if crouched else STAND_EYE
	_eye_height = move_toward(_eye_height, target, EYE_BLEND_SPEED * delta)
	_apply_pose()


## Crouch lowers the eye, the rig (head hitboxes ride with it) and shortens the hurtbox.
func _apply_pose() -> void:
	head.position.y = _eye_height
	var drop := STAND_EYE - _eye_height
	rig.position.y = -drop
	# Resizing a shape rebuilds it in the physics server, so only on a stance change; the box
	# snaps to the stance's height while the eye and rig ease toward it.
	var stance := 1 if crouched else 0
	if stance == _hurtbox_stance:
		return
	_hurtbox_stance = stance
	var box := hurtbox_shape.shape as BoxShape3D
	var height := maxf(
		HURTBOX_HEIGHT - (STAND_EYE - CROUCH_EYE if crouched else 0.0), HURTBOX_MIN_HEIGHT
	)
	box.size = Vector3(box.size.x, height, box.size.z)
	hurtbox_shape.position = Vector3(0.0, height * 0.5, 0.0)


# ------------------------------------------------------------------ weapons


func _give_starting_weapons() -> void:
	for i in mini(starting_weapons.size(), SLOT_COUNT):
		var scene := starting_weapons[i]
		var data := _data_of_scene(scene)
		if data == null:
			push_warning("%s: %s has no WeaponData on its root" % [name, scene])
			continue
		_install(_make_weapon(data, scene), i)
	for i in SLOT_COUNT:
		if slots[i] != null:
			_equip(i)
			return


## Reads the root's exported `data` from a weapon scene without instantiating its viewmodel.
static func _data_of_scene(scene: PackedScene) -> WeaponData:
	if scene == null:
		return null
	var state := scene.get_state()
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == &"data":
			return state.get_node_property_value(0, i) as WeaponData
	return null


func _make_weapon(data: WeaponData, scene: PackedScene) -> BotWeapon:
	var w := BotWeapon.new()
	w.data = data
	w.source_scene = scene
	w.name = data.display_name.validate_node_name()
	w.configure(self, eye, get_own_colliders())
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.08, 0.12, 0.55 if data.fire_mode == WeaponData.FireMode.AUTO else 0.3)
	mesh.mesh = box
	mesh.position = Vector3(0.22, -0.28, -0.35)
	w.add_child(mesh)
	return w


## Swaps a weapon into slot and returns the detached previous one.
func _install(weapon: BotWeapon, slot: int) -> BotWeapon:
	var old := slots[slot]
	if old != null:
		old.holster()
		weapon_mount.remove_child(old)
	weapon_mount.add_child(weapon)
	slots[slot] = weapon
	weapon.holster()
	var events := ArenaEvents.find(get_tree())
	if events != null:
		events.watch_weapon(weapon, self)
	return old


func _equip(index: int) -> void:
	if index < 0 or slots[index] == null:
		return
	var current := get_active()
	if current != null and index != active_index:
		current.holster()
	active_index = index
	slots[index].equip()
	weapon_changed.emit(slots[index])


func _clear_weapons() -> void:
	for i in SLOT_COUNT:
		if slots[i] != null:
			slots[i].holster()
			slots[i].queue_free()
			slots[i] = null
	active_index = 0


## BotWeapon from a Weapon a pickup handed over. Fresh placed weapons never ran _ready, so
## their ammo is the data's start values; dropped ones carry their live ammo (or bot_ammo meta).
func _weapon_from_taken(taken: Weapon) -> BotWeapon:
	var data := taken.data
	var scene: PackedScene = null
	if taken.scene_file_path != "":
		scene = load(taken.scene_file_path) as PackedScene
	var magazine := data.magazine_size if data != null else 0
	var reserve := mini(data.reserve_start, data.reserve_max) if data != null else 0
	if taken.has_meta(&"bot_ammo"):
		var ammo: Array = taken.get_meta(&"bot_ammo")
		magazine = ammo[0]
		reserve = ammo[1]
	elif taken.is_node_ready():
		magazine = taken.magazine
		reserve = taken.reserve
	taken.free()
	if data == null:
		return null
	var w := _make_weapon(data, scene)
	# _ready (run by _install's add_child) fills the magazine; set the real ammo after.
	var restore := func() -> void:
		w.magazine = magazine
		w.reserve = reserve
	w.ready.connect(restore, CONNECT_ONE_SHOT)
	return w


## Drops weapon as a real pickup (the player weapon scene, so the player can take it).
func _drop(weapon: BotWeapon, side: float = 0.0) -> void:
	var magazine := weapon.magazine
	var reserve := weapon.reserve
	var scene := weapon.source_scene
	weapon.queue_free()
	if scene == null or magazine + reserve <= 0:
		return
	var real := scene.instantiate() as Weapon
	if real == null:
		return
	# Not in the tree yet: walk-over ammo reads these directly; _ready would reset them, so the
	# ready hook restores them when a player installs it, and bot_ammo covers bots.
	real.magazine = magazine
	real.reserve = reserve
	real.set_meta(&"bot_ammo", [magazine, reserve])
	var restore := func() -> void:
		real.magazine = magazine
		real.reserve = reserve
		real.remove_meta(&"bot_ammo")
	real.ready.connect(restore, CONNECT_ONE_SHOT)
	var parent: Node = (
		get_tree().current_scene if get_tree().current_scene != null else get_parent()
	)
	WeaponPickup.drop(real, parent, _drop_position(side))


## Halo 2 style: both carried weapons drop, side by side across the bot's facing (active on
## the right), each keeping its own magazine and reserve. Empty weapons aren't dropped.
func _drop_all() -> void:
	var carried: Array[BotWeapon] = []
	for i in SLOT_COUNT:
		var index := (active_index + i) % SLOT_COUNT
		var w := slots[index]
		if w == null:
			continue
		slots[index] = null
		if w.get_parent() != null:
			w.get_parent().remove_child(w)
		carried.append(w)
	for i in carried.size():
		var side := 0.0 if carried.size() == 1 else (1.0 if i == 0 else -1.0)
		_drop(carried[i], side)


## Floor point under the bot, offset `side` x DROP_SPREAD along its right vector (pulled in
## short of any wall in the way).
func _drop_position(side: float = 0.0) -> Vector3:
	var space := get_world_3d().direct_space_state
	var centre := global_position + Vector3.UP * 1.0
	var from := centre
	if side != 0.0:
		var right := global_transform.basis.x
		right.y = 0.0
		right = right.normalized() if right.length_squared() > 0.001 else Vector3.RIGHT
		var target := centre + right * side * DROP_SPREAD
		var wall := space.intersect_ray(
			PhysicsRayQueryParameters3D.create(centre, target, DROP_MASK)
		)
		if wall.is_empty():
			from = target
		else:
			var reach := maxf(centre.distance_to(wall.position) - 0.3, 0.0)
			from = centre + right * side * reach
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0, DROP_MASK)
	var hit := space.intersect_ray(query)
	return hit.position if not hit.is_empty() else Vector3(from.x, global_position.y, from.z)


# ------------------------------------------------------------------ death


func _on_health_died() -> void:
	if dead:
		return
	dead = true
	var killer: Node = null
	var source: Variant = last_damage_info.get("source")
	if source is Node and is_instance_valid(source):
		killer = source
	cancel_lunge()
	var weapon := get_active()
	if weapon != null:
		weapon.release_trigger()
		weapon.holster()
	if drop_weapon_on_death and not last_damage_info.get("kill_volume", false):
		_drop_all()
	# Deferred: death can come from a KillVolume body_entered during the physics flush.
	for body: CollisionObject3D in _layers:
		body.set_deferred(&"collision_layer", 0)
	set_deferred(&"collision_mask", 0)
	collision_shape.set_deferred(&"disabled", true)
	velocity = Vector3.ZERO
	move_wish = Vector3.ZERO
	visible = false
	died.emit(self, killer, last_damage_info)


func _on_health_changed(shield: float, health: float) -> void:
	if label == null:
		return
	var state := ""
	var brain := get_node_or_null(^"Brain")
	if brain != null and brain.has_method("get_state_name"):
		state = " [%s]" % brain.call("get_state_name")
	label.text = "%s%s\nS %d  H %d" % [display_name, state, ceili(shield), ceili(health)]
