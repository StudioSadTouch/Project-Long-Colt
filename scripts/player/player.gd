# gdlint: disable=max-public-methods
class_name Player
extends CharacterBody3D
## First-person body for the Phase 0 pad.
## Yaw lives on this node. Pitch lives on Head. Movement reads this body's -Z.
## Hit layout, same scheme and sizes as the dummies and bots (dummy_rig.tscn), so TTK matches
## both ways:
##   root capsule  layer 2 (Player), movement, pickups, lifts, kill volumes. In group
##                 Weapon.PASSTHROUGH_GROUP, so hitscan and melee pass through it (a 0.41 m
##                 capsule would cover the visor and turn head shots into body shots).
##   Hurtbox       AnimatableBody3D on layer 2, box 0.82 x 1.70 x 0.47: body hits.
##   Rig heads     HeadArmored (helmet) / HeadUnarmored (visor + neck) on Hitbox (32).
## Crouch lowers the Rig and shortens the Hurtbox with the eye. The player's own weapons and
## AimAssist exclude all of these (get_own_colliders()). take_damage stays on the root, so
## Weapon's receiver (nearest ancestor with take_damage) is the Player for every zone.
## Death and respawn (for game modes, e.g. SpawnManager):
##   died(player, killer, info) fires once when health hits 0. Input, movement, collision
##   (capsule, Hurtbox, heads) and weapons are off while dead; the camera stays put. Carried
##   weapons with ammo drop as pickups (WeaponHolder.drop_weapons_on_death; not for
##   kill_volume deaths). After respawn_delay, respawn_requested(player) fires: answer it (or
##   any time while dead) with respawn_at(spawn). If nothing has respawned the player one frame
##   later and auto_respawn is on, it respawns at its scene spawn. A mode with its own timer
##   just calls respawn_at(); that cancels the pending fallback. respawn_at() on a live player
##   is a full reset + teleport.
## Body visual: an optional PlayerModel child, LC Animator's scenes/characters/player_body.tscn
## (LC Modeler's model + CharacterAnimDriver/Source; the capsule fallback
## scenes/player/player_body_fallback.tscn has the same contract). Its meshes are on render
## layer 1 unless first_person_hidden is set, which moves them to layer 2. Only the LOCAL player
## sets it, and gameplay cameras cull layer 2, so you never see your own body while remote
## players and bots stay visible. Visible while dead (death clip). set_primary_color(color)
## tints it (PlayerColor.apply).
## Networking (scripts/net, docs/net/netcode.md). Offline everything below stays at its default:
##   net_puppet            set BEFORE add_child: a remote player (or a bot seen from a client).
##                         No input, camera, HUD or AimAssist; the pose comes from
##                         apply_net_pose(). On the host its HealthShield, hitboxes and weapons are
##                         real (the host re-casts the owner's shots with them).
##   net_damage_authority  false on net clients: take_damage is ignored there, the host's
##                         HealthShield values arrive through HealthShield.apply_network_state and
##                         death through net_force_death().

## A hit landed (amount = shield + health actually removed). info carries a world-space "dir"
## (from the attacker toward this player) for hit reactions and third-person animation.
signal damaged(amount: float, info: Dictionary)
## Health reached 0. killer = info.source when it is a live Node (may be self or null).
## info carries "dir" like damaged (death clip / ragdoll direction).
## Can fire inside a physics flush (KillVolume): defer tree or physics changes in listeners.
signal died(player: Player, killer: Node, info: Dictionary)
## respawn_delay elapsed while dead. Call respawn_at(spawn) from here to pick the spawn point.
signal respawn_requested(player: Player)
signal respawned(player: Player)

## Lockout is built for a 2.1 m Spartan. These are the old 1.8 m body scaled by 2.1/1.8.
const STAND_HEIGHT := 2.1
const CROUCH_HEIGHT := 1.342
const CAPSULE_RADIUS := 0.408
const STAND_EYE := 1.89
const CROUCH_EYE := 1.108
const PITCH_LIMIT := 89.0
const HURTBOX_HEIGHT := 1.703
const HURTBOX_MIN_HEIGHT := 0.817
## get_aim_points().body height above the Rig origin, as DummyCore and Bot.
const BODY_AIM_HEIGHT := 0.852
## Step camera smoothing: the -dy view offset decays at this rate per second (~0.1 s to 5%).
const STEP_SMOOTH_RATE := 30.0
## Render layer for first-person-hidden bodies (layer 2); every gameplay camera culls it.
const HIDDEN_BODY_LAYER := 1 << 1

@export var stand_speed: float = 7.5
@export var crouch_speed: float = 3.2
@export var ground_accel: float = 70.0
@export var air_accel: float = 18.0
## How high the feet rise, in meters. Jump speed is derived from project gravity.
@export var jump_height: float = 2.2
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.12
@export var slide_min_speed: float = 6.0
@export var slide_speed: float = 9.2
@export var slide_duration: float = 0.5
@export var slide_decel: float = 10.0
## Auto step-up / step-down height (StepUp, shared with Bot). 0 = off.
@export var step_height: float = 0.35
@export var mouse_sensitivity: float = 0.0022
@export var eye_blend_speed: float = 12.0
@export var fov: float = 75.0
@export_group("Controller")
## Right-stick look speed at full deflection, degrees per second.
@export var stick_yaw_speed: float = 200.0
@export var stick_pitch_speed: float = 120.0
@export var stick_invert_y: bool = false
## Response curve: deflection^exponent after the deadzone (1 = linear, 2 = Halo-like ease-in).
@export var stick_curve_exponent: float = 2.0
## Radial stick deadzone, shared by look here and AimAssist's device detection.
@export_range(0.0, 0.9) var stick_deadzone: float = 0.2
@export_group("Respawn")
## Seconds dead before respawn_requested (~Halo 2 default).
@export var respawn_delay: float = 5.0
## Respawn at the scene spawn if respawn_requested goes unanswered for a frame.
@export var auto_respawn: bool = true
@export_group("")

## Refreshed every physics tick from get_gravity() so Area3D overrides apply.
var gravity: float = 22.0
## Runtime multiplier on mouse_sensitivity, set by zoom. Settings change mouse_sensitivity.
var look_sensitivity_scale: float = 1.0
## Runtime multiplier from AimAssist slowdown (1.0 = none).
var aim_slowdown_scale: float = 1.0
## Camera pitch/yaw offset in radians (weapon recoil). Applied on top of aim, never baked in.
var view_kick: Vector2 = Vector2.ZERO
var crouched: bool = false
var sliding: bool = false
var dead: bool = false
## Info of the last hit taken (kill credit: "source").
var last_damage_info: Dictionary = {}
## Net hooks, see the header. Set net_puppet before the node enters the tree.
var net_puppet: bool = false
var net_damage_authority: bool = true
## Set by Humvee while this body is in the driver seat. Movement and weapons stay off.
var mounted_vehicle: Node = null

var _eye_height: float = STAND_EYE
var _landing_dip: float = 0.0
## Camera-only vertical offset that hides step-ups/downs (and small net snaps); decays to 0.
var _view_offset: float = 0.0
var _coyote_left: float = 0.0
var _jump_buffer_left: float = 0.0
var _crouch_edge: bool = false
var _slide_time_left: float = 0.0
var _slide_speed: float = 0.0
var _slide_dir: Vector3 = Vector3.ZERO
var _stand_probe: CapsuleShape3D
var _lunge_dir: Vector3 = Vector3.ZERO
var _lunge_speed: float = 0.0
var _lunge_left: float = 0.0
var _spawn_transform: Transform3D
## Collision layers of get_own_colliders() bodies, restored on respawn.
var _layers: Dictionary = {}
## Bumped on every death and respawn, so stale respawn timers do nothing.
var _life_id: int = 0
var _respawn_timer: SceneTreeTimer

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var health_shield: HealthShield = get_node_or_null("HealthShield")
## Optional (older scenes without them keep the capsule as the hit body).
@onready var hurtbox: AnimatableBody3D = get_node_or_null(^"Hurtbox") as AnimatableBody3D
@onready var hurtbox_shape := get_node_or_null(^"Hurtbox/Shape") as CollisionShape3D
@onready var rig: Node3D = get_node_or_null(^"Rig") as Node3D


func _ready() -> void:
	gravity = get_gravity().length()
	_spawn_transform = global_transform
	if health_shield != null:
		health_shield.died.connect(_on_died)
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	collision_layer = 2
	# World and Enemy. Projectiles and interactables do not block the body.
	collision_mask = 1 | 4
	_stand_probe = CapsuleShape3D.new()
	_stand_probe.radius = CAPSULE_RADIUS
	_stand_probe.height = STAND_HEIGHT - 0.06
	_eye_height = STAND_EYE
	_apply_capsule()
	camera.fov = fov
	if net_puppet:
		_become_puppet()
	else:
		camera.current = true
		# First person: our own body goes to layer 2, which this camera doesn't draw.
		PlayerColor.set_first_person_hidden(self, true)
	camera.cull_mask &= ~HIDDEN_BODY_LAYER
	add_to_group("player")
	# GravLift pushes CharacterBody3Ds in this group.
	add_to_group(&"lift_rider")
	if hurtbox != null:
		# Rays hit the Hurtbox and Rig heads instead of the capsule.
		add_to_group(Weapon.PASSTHROUGH_GROUP)
	for body in get_own_colliders():
		_layers[body] = body.collision_layer
	if DisplayServer.get_name() != "headless" and not net_puppet:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Remote representation: no camera, HUD, AimAssist or input; the WeaponHolder stays (the host
## re-casts this player's shots with its weapons) but is hidden and ignores input.
func _become_puppet() -> void:
	camera.current = false
	set_process_unhandled_input(false)
	for path: NodePath in [^"HUD", ^"AimAssist"]:
		var node := get_node_or_null(path)
		if node != null:
			node.queue_free()
	var holder := get_weapon_holder()
	if holder != null:
		holder.visible = false
	# Other players' AimAssist and the bots target this body.
	add_to_group(AimAssist.TARGET_GROUP)


func _unhandled_input(event: InputEvent) -> void:
	if net_puppet:
		return
	if event.is_action_pressed("action_pause"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	if (
		event is InputEventMouseButton
		and event.pressed
		and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	if dead:
		return
	if mounted_vehicle != null:
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_apply_look(event.relative)
		return
	if event.is_action_pressed("action_jump"):
		_jump_buffer_left = jump_buffer_time
	if event.is_action_pressed("action_crouch"):
		_crouch_edge = true
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_look(event.relative)


func _physics_process(delta: float) -> void:
	if dead:
		return
	if net_puppet:
		# Pose comes from apply_net_pose; only the lunge timer runs (host melee waits on it).
		_lunge_left = maxf(_lunge_left - delta, 0.0)
		_update_head(delta)
		return
	if mounted_vehicle != null:
		# The humvee snaps this body to the seat. Stick look still aims its gun.
		_apply_stick_look(delta)
		return
	_apply_stick_look(delta)
	gravity = get_gravity().length()
	var on_floor_before := is_on_floor()
	if on_floor_before:
		_coyote_left = coyote_time

	_update_stance()

	var wish := _wish_direction()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var slide_velocity := Vector3.ZERO
	if _lunge_left > 0.0:
		# A melee lunge owns horizontal motion until it times out or is cancelled on contact.
		_lunge_left -= delta
		sliding = false
		horizontal = _lunge_dir * _lunge_speed
		if _lunge_left <= 0.0:
			horizontal = horizontal.limit_length(stand_speed)
	elif sliding:
		slide_velocity = _tick_slide(delta)
		horizontal = Vector3(slide_velocity.x, 0.0, slide_velocity.z)
	elif on_floor_before:
		horizontal = _apply_ground(horizontal, wish, delta)
	else:
		horizontal = _apply_air(horizontal, wish, delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	var vertical_before := velocity.y
	var jumped := _consume_jump()
	# Airborne gravity is split into two half steps around the move (trapezoid rule),
	# so the jump apex matches jump_height at any physics tick rate.
	var airborne := jumped or not on_floor_before
	if jumped:
		velocity.y = sqrt(2.0 * gravity * jump_height)
		sliding = false
	elif airborne:
		pass
	elif sliding:
		# Follow the floor so slides run down and up ramps instead of launching off them.
		velocity.y = slide_velocity.y
	elif velocity.y < 0.0:
		velocity.y = 0.0
	if airborne:
		velocity.y -= gravity * delta * 0.5

	var stepped := StepUp.move_and_slide(self, step_height, on_floor_before, jumped)
	if stepped != 0.0:
		absorb_view_offset(stepped)

	if airborne and not is_on_floor():
		velocity.y -= gravity * delta * 0.5

	if jumped:
		_coyote_left = 0.0
	elif is_on_floor():
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)

	if not on_floor_before and is_on_floor():
		var impact := maxf(-vertical_before, 0.0)
		if impact > 6.0:
			_landing_dip = minf(impact * 0.008, 0.07)

	if sliding:
		var actual := Vector3(velocity.x, 0.0, velocity.z).length()
		if actual < _slide_speed * 0.35:
			sliding = false

	_update_head(delta)
	_jump_buffer_left = maxf(_jump_buffer_left - delta, 0.0)
	_crouch_edge = false


## Damage contract shared with enemies; HealthShield applies the shield and zone rules.
func take_damage(amount: float, info: Dictionary) -> void:
	if dead or health_shield == null or not net_damage_authority:
		return
	# Anim contract: info.dir is world shooter -> victim; info.impulse is optional, passed on.
	if not info.has("dir"):
		info["dir"] = damage_direction(self, info)
	last_damage_info = info
	var result := health_shield.apply_damage(amount, info)
	# Shooter feedback reads these off the same Dictionary hit_confirmed receives.
	info["shield_dealt"] = result.shield
	info["health_dealt"] = result.health
	var applied: float = result.shield + result.health
	if applied > 0.0:
		damaged.emit(applied, info)


## World-space direction a hit travelled (attacker -> victim), from info.direction (weapons),
## else from info.source's position, else zero (falls, kill volumes).
static func damage_direction(victim: Node3D, info: Dictionary) -> Vector3:
	var direction: Variant = info.get("direction")
	if direction is Vector3 and (direction as Vector3).length_squared() > 0.0001:
		return (direction as Vector3).normalized()
	var source: Variant = info.get("source")
	if source is Node3D and is_instance_valid(source) and source != victim:
		var offset := victim.global_position - (source as Node3D).global_position
		if offset.length_squared() > 0.0001:
			return offset.normalized()
	return Vector3.ZERO


func is_dead() -> bool:
	return dead


func is_mounted() -> bool:
	return mounted_vehicle != null


## Third-person animation getters (CharacterAnimState contract; keep stable).
func get_aim_pitch() -> float:
	return head.rotation.x


func is_crouching() -> bool:
	return crouched


func is_sliding() -> bool:
	return sliding


func get_active_weapon() -> Weapon:
	var holder := get_weapon_holder()
	return holder.get_active() if holder != null else null


## Seconds until respawn_requested, 0 when alive or already requested.
func get_respawn_time_left() -> float:
	if not dead or _respawn_timer == null:
		return 0.0
	return maxf(_respawn_timer.time_left, 0.0)


## Respawn (or, if alive, reset and teleport) at xform: its origin and the yaw of its -Z.
## Full shield and health, starting loadout, collision and input back on.
func respawn_at(xform: Transform3D) -> void:
	if mounted_vehicle != null and is_instance_valid(mounted_vehicle) and mounted_vehicle.has_method(&"force_exit"):
		mounted_vehicle.call(&"force_exit")
	_life_id += 1
	_respawn_timer = null
	var forward := -xform.basis.z
	forward.y = 0.0
	var yaw := rotation.y
	if forward.length_squared() > 0.0001:
		yaw = atan2(-forward.x, -forward.z)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), xform.origin)
	head.rotation.x = 0.0
	velocity = Vector3.ZERO
	cancel_lunge()
	sliding = false
	crouched = false
	_eye_height = STAND_EYE
	_landing_dip = 0.0
	_view_offset = 0.0
	_coyote_left = 0.0
	_jump_buffer_left = 0.0
	_crouch_edge = false
	view_kick = Vector2.ZERO
	aim_slowdown_scale = 1.0
	_apply_capsule()
	_update_head(0.0)
	for body in _layers:  # untyped: a freed key fails a typed iterator before the check
		if is_instance_valid(body):
			body.collision_layer = _layers[body]
	collision_shape.disabled = false
	_set_model_visible(true)
	last_damage_info = {}
	if health_shield != null:
		health_shield.reset()
	var holder := get_weapon_holder()
	if holder != null:
		holder.reset_loadout()
	dead = false
	respawned.emit(self)


func get_weapon_holder() -> WeaponHolder:
	return get_node_or_null(^"Head/Camera3D/WeaponHolder") as WeaponHolder


## Pickup-carrier hook (WeaponPickup.carrier_of): the WeaponHolder, none while dead.
func get_pickup_carrier() -> Object:
	return null if dead else get_weapon_holder()


func _on_died() -> void:
	if dead:
		return
	dead = true
	cancel_lunge()
	sliding = false
	velocity = Vector3.ZERO
	# Deferred: death can come from a KillVolume body_entered during the physics flush.
	for body in _layers:  # untyped: a freed key fails a typed iterator before the check
		if is_instance_valid(body):
			body.set_deferred(&"collision_layer", 0)
	collision_shape.set_deferred(&"disabled", true)
	# The model stays visible while dead so the death clip plays (respawn_at re-shows it anyway).
	var info := last_damage_info
	var holder := get_weapon_holder()
	if holder != null:
		holder.on_owner_died(not info.get("kill_volume", false))
	var killer: Node = null
	var source: Variant = info.get("source")
	if is_instance_valid(source) and source is Node:
		killer = source
	_life_id += 1
	var life := _life_id
	_respawn_timer = get_tree().create_timer(maxf(respawn_delay, 0.0), false)
	_respawn_timer.timeout.connect(_on_respawn_timeout.bind(life))
	died.emit(self, killer, info)


func _on_respawn_timeout(life: int) -> void:
	if life != _life_id or not dead:
		return
	respawn_requested.emit(self)
	if not auto_respawn or life != _life_id:
		return
	# One frame for a game mode on its own respawn timer to call respawn_at first.
	await get_tree().process_frame
	if life == _life_id and dead:
		respawn_at(_spawn_transform)


## Net: pose from the network (host: the owning client's validated state; client: interpolated
## snapshot). Yaw on the body, pitch on Head, crouch resizes capsule, Hurtbox and Rig.
func apply_net_pose(pos: Vector3, yaw: float, pitch: float, is_crouched: bool) -> void:
	global_position = pos
	rotation.y = yaw
	head.rotation.x = clampf(pitch, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))
	if is_crouched != crouched:
		crouched = is_crouched
		_apply_capsule()


## Net client: the host says this player died. info is the host's (lite) damage info with
## source resolved to a local node or null. Runs the normal death path (_on_died).
func net_force_death(info: Dictionary) -> void:
	if dead or health_shield == null:
		return
	last_damage_info = info
	health_shield.force_death()


## Tints the body (PlayerModel, see PlayerColor.apply).
func set_primary_color(color: Color) -> void:
	PlayerColor.apply(self, color)


func set_visor_color(color: Color) -> void:
	PlayerColor.apply_visor(self, color)


func get_model() -> Node3D:
	return get_node_or_null(^"PlayerModel") as Node3D


func _set_model_visible(on: bool) -> void:
	var model := get_model()
	if model != null:
		model.visible = on


## Every collider the player's own weapons, melee and AimAssist must ignore.
func get_own_colliders() -> Array[CollisionObject3D]:
	var bodies: Array[CollisionObject3D] = [self]
	for path: NodePath in [^"Hurtbox", ^"Rig/HeadArmored", ^"Rig/HeadUnarmored"]:
		var body := get_node_or_null(path) as CollisionObject3D
		if body != null:
			bodies.append(body)
	return bodies


## Aim points in DummyCore's format (body, helmet "head", visor "face"), for bots. Empty while
## dead. The player is not in group aim_target, so its own AimAssist never sees these.
func get_aim_points() -> Dictionary:
	if is_dead():
		return {}
	var base := rig.global_position if rig != null else global_position
	var points := {"body": base + Vector3.UP * BODY_AIM_HEIGHT}
	var helmet := get_node_or_null(^"Rig/HeadArmored") as Node3D
	if helmet != null:
		points["head"] = helmet.global_position
	var visor := get_node_or_null(^"Rig/HeadUnarmored/VisorShape") as Node3D
	if visor != null:
		points["face"] = visor.global_position
	return points


func get_eye_position() -> Vector3:
	return camera.global_position


## Melee lunge: drive horizontal velocity along direction for up to duration seconds.
func start_lunge(direction: Vector3, speed: float, duration: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001 or duration <= 0.0:
		return
	_lunge_dir = flat.normalized()
	_lunge_speed = speed
	_lunge_left = duration


## Ends a lunge and clamps horizontal speed to run speed so jump + melee can't boost.
## No-op when not lunging.
func cancel_lunge() -> void:
	if _lunge_left <= 0.0:
		return
	_lunge_left = 0.0
	var horizontal := Vector3(velocity.x, 0.0, velocity.z).limit_length(stand_speed)
	velocity.x = horizontal.x
	velocity.z = horizontal.z


func is_lunging() -> bool:
	return _lunge_left > 0.0


## The body just moved up by dy (a step, or a small net correction): offset the camera by -dy so
## the view eases there instead of popping. Camera only; hitboxes follow the body at once.
func absorb_view_offset(dy: float) -> void:
	_view_offset = clampf(_view_offset - dy, -step_height * 2.0, step_height * 2.0)


func _apply_look(relative: Vector2) -> void:
	# Probe: rotate_y(+) turns -Z toward world -X, and rotate_x(+) looks up.
	# Mouse right is +x and mouse down is +y, so both axes are negated.
	var sensitivity := mouse_sensitivity * look_sensitivity_scale * aim_slowdown_scale
	if mounted_vehicle != null and mounted_vehicle.has_method(&"add_look"):
		mounted_vehicle.call(&"add_look", relative, sensitivity)
		return
	rotate_y(-relative.x * sensitivity)
	head.rotate_x(-relative.y * sensitivity)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))


## Right-stick look, frame-rate independent (deg/s * delta). Shares look_sensitivity_scale
## (zoom) and aim_slowdown_scale (AimAssist) with the mouse; AimAssist magnetism adds its own
## add_aim_offset nudge on the same physics tick.
func _apply_stick_look(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and DisplayServer.get_name() != "headless":
		return
	# get_vector applies the deadzone radially and rescales the rest to 0..1.
	var stick := Input.get_vector(
		"action_look_left",
		"action_look_right",
		"action_look_up",
		"action_look_down",
		stick_deadzone
	)
	var magnitude := stick.length()
	if magnitude <= 0.0:
		return
	stick = stick / magnitude * pow(minf(magnitude, 1.0), stick_curve_exponent)
	var look_scale := look_sensitivity_scale * aim_slowdown_scale
	var y_sign := -1.0 if stick_invert_y else 1.0
	add_aim_offset(
		-deg_to_rad(stick.x * stick_yaw_speed) * look_scale * delta,
		-deg_to_rad(stick.y * stick_pitch_speed) * look_scale * delta * y_sign
	)


## Aim nudge in radians (AimAssist magnetism): yaw on the body, pitch on Head, clamped.
func add_aim_offset(yaw: float, pitch: float) -> void:
	if mounted_vehicle != null and mounted_vehicle.has_method(&"add_aim_radians"):
		mounted_vehicle.call(&"add_aim_radians", yaw, pitch)
		return
	rotate_y(yaw)
	head.rotate_x(pitch)
	head.rotation.x = clampf(head.rotation.x, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))


func _wish_direction() -> Vector3:
	var input_forward := (
		Input.get_action_strength("action_move_forward")
		- Input.get_action_strength("action_move_back")
	)
	var input_right := (
		Input.get_action_strength("action_move_right")
		- Input.get_action_strength("action_move_left")
	)
	# Body -Z, flattened. Pitch on Head must not steer this vector.
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3.ZERO
	fwd = fwd.normalized()
	# forward × up = right. Facing -Z, right is +X.
	var right := fwd.cross(Vector3.UP)
	var wish := fwd * input_forward + right * input_right
	if wish.length_squared() < 0.0001:
		return Vector3.ZERO
	# Keep analog stick magnitude; only clamp diagonals (keyboard W+D) to 1.
	return wish.limit_length(1.0)


func _apply_ground(horizontal: Vector3, wish: Vector3, delta: float) -> Vector3:
	var speed := crouch_speed if crouched else stand_speed
	return horizontal.move_toward(wish * speed, ground_accel * delta)


func _apply_air(horizontal: Vector3, wish: Vector3, delta: float) -> Vector3:
	if wish == Vector3.ZERO:
		return horizontal
	var along := horizontal.dot(wish)
	var add_speed := stand_speed - along
	if add_speed <= 0.0:
		return horizontal
	var accel_speed := minf(air_accel * delta, add_speed)
	return horizontal + wish * accel_speed


func _tick_slide(delta: float) -> Vector3:
	_slide_time_left -= delta
	_slide_speed = maxf(_slide_speed - slide_decel * delta, 0.0)
	if _slide_time_left <= 0.0 or _slide_speed <= crouch_speed:
		sliding = false
	# _slide_dir stays flat to lock heading; project it onto the floor each tick.
	var dir := _slide_dir
	if is_on_floor():
		dir = _slide_dir.slide(get_floor_normal()).normalized()
	return dir * _slide_speed


func _update_stance() -> void:
	var held := Input.is_action_pressed("action_crouch")
	var horizontal_speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if _crouch_edge and is_on_floor() and not sliding and horizontal_speed >= slide_min_speed:
		sliding = true
		_slide_time_left = slide_duration
		_slide_dir = Vector3(velocity.x, 0.0, velocity.z).normalized()
		_slide_speed = maxf(horizontal_speed, slide_speed)
	if held or sliding:
		crouched = true
	elif _can_stand():
		crouched = false
	_apply_capsule()


func _consume_jump() -> bool:
	if _jump_buffer_left <= 0.0:
		return false
	if not is_on_floor() and _coyote_left <= 0.0:
		return false
	_jump_buffer_left = 0.0
	_coyote_left = 0.0
	return true


func _can_stand() -> bool:
	if not crouched:
		return true
	var space := get_world_3d().direct_space_state
	var margin := 0.06
	var test_height := STAND_HEIGHT - margin
	var center := global_position + Vector3.UP * (margin + test_height * 0.5)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _stand_probe
	params.transform = Transform3D(global_transform.basis, center)
	params.collision_mask = collision_mask
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).is_empty()


func _apply_capsule() -> void:
	var height := CROUCH_HEIGHT if crouched else STAND_HEIGHT
	var shape := collision_shape.shape as CapsuleShape3D
	shape.radius = CAPSULE_RADIUS
	shape.height = height
	collision_shape.position = Vector3(0.0, height * 0.5, 0.0)


func _update_head(delta: float) -> void:
	var target := CROUCH_EYE if crouched else STAND_EYE
	_eye_height = move_toward(_eye_height, target, eye_blend_speed * delta)
	_landing_dip = move_toward(_landing_dip, 0.0, 0.45 * delta)
	_view_offset *= exp(-STEP_SMOOTH_RATE * delta)
	if absf(_view_offset) < 0.001:
		_view_offset = 0.0
	head.position.y = _eye_height - _landing_dip + _view_offset
	camera.rotation = Vector3(view_kick.x, view_kick.y, 0.0)
	_apply_hit_pose()


## Crouch lowers the Rig (head hitboxes ride with it) and shortens the Hurtbox, like Bot.
func _apply_hit_pose() -> void:
	var drop := STAND_EYE - _eye_height
	if rig != null:
		rig.position.y = -drop
	if hurtbox_shape == null:
		return
	var box := hurtbox_shape.shape as BoxShape3D
	var height := maxf(HURTBOX_HEIGHT - drop, HURTBOX_MIN_HEIGHT)
	if box == null or is_equal_approx(box.size.y, height):
		return
	box.size = Vector3(box.size.x, height, box.size.z)
	hurtbox_shape.position = Vector3(0.0, height * 0.5, 0.0)
