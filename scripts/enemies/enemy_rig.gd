class_name EnemyRig
extends Node3D
## Greybox body for a New Ottoman enemy, built from primitives by EnemyType (no art yet). It
## owns the head hitboxes Bot expects under Rig (HeadArmored, HeadUnarmored with VisorShape and
## NeckShape, AimHeadPoint, HPLabel), so Weapon's zones and AimAssist work as on the dummies.
##
## Silhouettes follow the board's black-fill test (docs/enemies/new_ottoman.md):
##   Azab       upright, blade standing above a red cap (rifle at port arms until it engages)
##   Akinji     low and running, split coat flaring behind, fur cap
##   Janissary  towering, crest trailing back over massive shoulders
## Rank lives only on the crest, cap or coat (EnemyType.rank_color); every enemy carries one
## turquoise sensor slit, the faction's only glow. Animation is procedural: leg swing, lean,
## coat flare, weapon port-arms / aim, a fall on death.
## Janissary plate comes off in pieces (ArmorStages): SPALLED drops crest and pauldrons,
## EXPOSED drops the chest plate and tassets, shows the frame and vents the hydraulics.

## Palette from the board (section 6). Gunmetal and oxblood come from EnemyType.
const SENSOR := Color("2a9d97")
const TOMBAK := Color("b07a3a")
const FELT := Color("ece4d4")
const FUR := Color("5e3a1c")
const DARK := Color("23262b")
const LEATHER := Color("3b2a20")
const SKIN := Color(0.6, 0.45, 0.35)
const STEEL := Color("8a9099")
const HOSE := Color("9c2f2c")
const HITBOX_LAYER := 32
## Rifle pitch at rest. Azab: port arms, nearly upright, so the blades stand above the caps.
## Janissary: upright with ceremony. Akinji: low ready, muzzle down (a hunter, not a sentry),
## which also keeps the two ordinary-man silhouettes apart in the black-fill test.
const REST_PITCH := {
	EnemyType.Corps.AZAB: 1.35, EnemyType.Corps.JANISSARY: 1.2, EnemyType.Corps.AKINJI: -0.55
}
const DEBRIS_LIFETIME := 6.0

var enemy: Enemy
var type: EnemyType
var s: float = 1.0

var _body: Node3D
var _head: Node3D
var _legs: Array[Node3D] = []
var _arms: Node3D
var _coat_panels: Array[Node3D] = []
var _spall_parts: Array[Node3D] = []
var _plate_parts: Array[Node3D] = []
var _frame_parts: Array[Node3D] = []
var _vent: CPUParticles3D
var _props: Dictionary = {}  # BotWeapon -> Node3D
var _stowed: Dictionary = {}  # BotWeapon -> Node3D (blades at the hip)
var _glint: MeshInstance3D
var _glint_left: float = 0.0
var _hum: AudioStreamPlayer3D
var _materials: Dictionary = {}
var _walk_phase: float = 0.0
var _arm_pitch: float = 0.0
var _head_pitch: float = 0.0
var _shoulder_y: float = 0.0
var _recoil_pitch: float = 0.0
var _recoil_push: float = 0.0
var _melee_swing_t: float = -1.0
var _melee_duration: float = 0.35
var _melee_is_blade: bool = false
var _flinch_t: float = 0.0
var _flinch_amount: float = 1.0
var _active_weapon: BotWeapon
var _death_t: float = -1.0


func build(owner_enemy: Enemy, enemy_type: EnemyType) -> void:
	enemy = owner_enemy
	type = enemy_type
	s = type.body_scale()
	_arm_pitch = REST_PITCH[type.corps]
	_build_hitboxes()
	_build_body()
	enemy.weapon_changed.connect(_on_weapon_changed)
	enemy.died.connect(_on_died)
	enemy.damaged.connect(_on_damaged)
	if enemy.armor_stages != null:
		enemy.armor_stages.stage_changed.connect(_on_stage_changed)


## Respawn: rebuild the plate (debris that fell off is gone) and stand back up.
func reset_armor() -> void:
	_death_t = -1.0
	if _body != null:
		_body.queue_free()
	_body = null
	_build_body()
	for w: BotWeapon in enemy.slots:
		if w != null:
			_ensure_prop(w)
	_on_weapon_changed(enemy.get_active())


## Scope glint for an Akinji marksman: a bright flash at the scope, seen before the shot.
func glint(duration: float = 0.45) -> void:
	if _glint == null:
		return
	_glint_left = duration
	_glint.visible = true
	NewOttomanSounds.play_at(self, &"glint", _glint.global_position, -6.0)


# ------------------------------------------------------------------ hitboxes


## Same layout as dummy_rig.tscn scaled to the body: helmet (armored), face + neck (unarmored).
## EnemyType.hitbox_scale widens the boxes; the face moves out with the helmet's front so it
## stays the first thing a shot to the face meets.
func _build_hitboxes() -> void:
	var hs := clampf(s, 0.85, 1.1)  # heads don't grow with a Janissary's frame
	var pad := Vector3(type.hitbox_scale, 1.0, type.hitbox_scale)
	var helmet_y := 1.913 * s
	var armored := StaticBody3D.new()
	armored.name = "HeadArmored"
	armored.collision_layer = HITBOX_LAYER
	armored.collision_mask = 0
	armored.add_to_group(&"hitbox_head_armored")
	armored.position = Vector3(0.0, helmet_y, 0.0)
	add_child(armored)
	_shape(armored, "HelmetShape", Vector3(0.4, 0.38, 0.4) * hs * pad, Vector3.ZERO)
	var bare := StaticBody3D.new()
	bare.name = "HeadUnarmored"
	bare.collision_layer = HITBOX_LAYER
	bare.collision_mask = 0
	bare.add_to_group(&"hitbox_head_unarmored")
	add_child(bare)
	# The face: an open helmet (Azab, Akinji) or the Janissary's sensor slit.
	_shape(
		bare,
		"VisorShape",
		Vector3(0.26, 0.16, 0.047) * hs * pad,
		Vector3(0.0, helmet_y - 0.05 * hs, -0.22 * hs * pad.z)
	)
	_shape(
		bare,
		"NeckShape",
		Vector3(0.18, 0.08, 0.18) * hs * pad,
		Vector3(0.0, helmet_y - 0.24 * hs, 0.0)
	)
	var aim := Marker3D.new()
	aim.name = "AimHeadPoint"
	aim.position = Vector3(0.0, helmet_y, 0.0)
	add_child(aim)
	var label := Label3D.new()
	label.name = "HPLabel"
	label.position = Vector3(0.0, type.height + 0.4, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.001
	label.font_size = 32
	label.outline_size = 8
	add_child(label)


func _shape(body: StaticBody3D, shape_name: String, size: Vector3, at: Vector3) -> void:
	var shape := CollisionShape3D.new()
	shape.name = shape_name
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = at
	body.add_child(shape)


# ------------------------------------------------------------------ body


func _build_body() -> void:
	_legs.clear()
	_coat_panels.clear()
	_spall_parts.clear()
	_plate_parts.clear()
	_frame_parts.clear()
	_props.clear()
	_stowed.clear()
	_glint = null
	_vent = null
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	_head = Node3D.new()
	_head.name = "HeadVisual"
	_body.add_child(_head)
	match type.corps:
		EnemyType.Corps.JANISSARY:
			_build_janissary()
		EnemyType.Corps.AKINJI:
			_build_akinji()
		_:
			_build_azab()


## Conscript, ~1.75 m: quilted coat, one stamped chest plate, open cone helmet under a felt
## cover in the rank colour, bare arms of cloth. The rifle's long blade is the silhouette.
func _build_azab() -> void:
	var h := type.height
	var hs := clampf(s, 0.85, 1.1)
	var head_y := 1.913 * s
	_build_legs(0.1 * h / 1.75, 0.46 * h, 0.12, type.cloth_color.darkened(0.3), LEATHER)
	var coat := type.cloth_color
	_box(_body, Vector3(0.44, 0.5, 0.28), Vector3(0.0, 0.5 * h + 0.06, 0.0), coat)  # skirt
	_box(_body, Vector3(0.46, 0.42, 0.29), Vector3(0.0, 0.73 * h, 0.0), coat)  # quilted chest
	for i in 4:  # quilting ribs read at close range only
		_box(
			_body,
			Vector3(0.47, 0.012, 0.295),
			Vector3(0.0, 0.62 * h + i * 0.07, 0.0),
			coat.darkened(0.25)
		)
	_box(_body, Vector3(0.47, 0.06, 0.3), Vector3(0.0, 0.53 * h, 0.0), LEATHER)  # belt
	_box(_body, Vector3(0.24, 0.2, 0.04), Vector3(0.0, 0.74 * h, -0.155), type.plate_color)
	if type.horn:
		var horn := _cylinder(
			_body, 0.02, 0.05, 0.32, Vector3(-0.1, 0.76 * h, -0.17), TOMBAK, Vector3(0, 0, 1.0)
		)
		horn.name = "SignalHorn"
	_build_head_open(head_y, hs, true)
	_build_arms(0.82 * h, 0.2, type.cloth_color)


## Raider, ~1.8 m: mail shirt, long riding coat split front and back (rank colour), fur cap
## over a skullcap, riding boots with shin wraps.
func _build_akinji() -> void:
	var h := type.height
	var hs := clampf(s, 0.85, 1.1)
	var head_y := 1.913 * s
	_build_legs(0.1, 0.47 * h, 0.12, LEATHER, FELT.darkened(0.35))
	_box(_body, Vector3(0.42, 0.5, 0.26), Vector3(0.0, 0.72 * h, 0.0), STEEL.darkened(0.2))  # mail
	_box(_body, Vector3(0.46, 0.3, 0.3), Vector3(0.0, 0.8 * h, 0.0), type.rank_color)  # coat top
	_box(_body, Vector3(0.44, 0.06, 0.28), Vector3(0.0, 0.54 * h, 0.0), LEATHER)  # belt
	# Split skirts hinge at the belt; they flare with speed in _animate.
	var skirt := 0.36 * h
	for spec: Array in [
		[Vector3(0.0, 0.54 * h, 0.13), Vector3(0.42, skirt, 0.03)],  # back
		[Vector3(-0.11, 0.54 * h, -0.13), Vector3(0.2, skirt * 0.92, 0.03)],  # front left
		[Vector3(0.11, 0.54 * h, -0.13), Vector3(0.2, skirt * 0.92, 0.03)],  # front right
	]:
		var hinge := Node3D.new()
		hinge.position = spec[0]
		_body.add_child(hinge)
		var size: Vector3 = spec[1]
		_box(hinge, size, Vector3(0.0, -size.y * 0.5, 0.0), type.rank_color)
		_coat_panels.append(hinge)
	if type.trophies:
		for x: float in [-0.16, 0.0, 0.16]:
			_box(_body, Vector3(0.08, 0.1, 0.06), Vector3(x, 0.52 * h, -0.16), Color("6b6146"))
	_build_head_open(head_y, hs, false)
	_build_arms(0.8 * h, 0.2, STEEL.darkened(0.2))


## Armoured cyborg, ~2.6 m: human torso in a load-bearing frame, mass high and wide in the
## shoulders, plate over a mail-and-plate skirt, chichak cone helmet with aventail, crest
## trailing back like the bork's felt flap, a sensor mast on the brow.
func _build_janissary() -> void:
	var h := type.height
	var hs := clampf(s, 0.85, 1.1)
	var head_y := 1.913 * s
	var plate := TOMBAK if type.full_tombak else type.plate_color
	var chest := TOMBAK if type.gilt_chest or type.full_tombak else plate
	_build_legs(0.21, 0.4 * h, 0.22, DARK, plate)
	# Mail-and-plate skirt; the tassets are plate and come off at EXPOSED.
	_box(_body, Vector3(0.72, 0.42, 0.5), Vector3(0.0, 0.41 * h, 0.0), STEEL.darkened(0.35))
	for x: float in [-0.2, 0.2]:
		_plate_parts.append(
			_box(_body, Vector3(0.3, 0.36, 0.05), Vector3(x, 0.4 * h, -0.27), plate)
		)
	# Frame torso; the chest plate rides on it.
	_box(_body, Vector3(0.7, 0.7, 0.46), Vector3(0.0, 0.62 * h, 0.0), DARK)
	_plate_parts.append(_box(_body, Vector3(0.76, 0.62, 0.1), Vector3(0.0, 0.63 * h, -0.26), chest))
	_plate_parts.append(_box(_body, Vector3(0.7, 0.5, 0.08), Vector3(0.0, 0.64 * h, 0.25), plate))
	# The kazan, the orta's cauldron, painted on the chest plate as the squad standard.
	_plate_parts.append(
		_box(_body, Vector3(0.18, 0.12, 0.02), Vector3(0.0, 0.66 * h, -0.32), type.rank_color)
	)
	# Hydraulic frame behind the plate: hidden until EXPOSED.
	for x: float in [-0.24, 0.0, 0.24]:
		var strut := _box(_body, Vector3(0.05, 0.6, 0.05), Vector3(x, 0.63 * h, -0.25), STEEL)
		strut.visible = false
		_frame_parts.append(strut)
	for x: float in [-0.3, 0.3]:
		var hose := _cylinder(_body, 0.025, 0.025, 0.55, Vector3(x, 0.63 * h, -0.2), HOSE)
		hose.visible = false
		_frame_parts.append(hose)
	# Pauldrons: the biggest shapes on the silhouette, first to spall.
	for x: float in [-0.5, 0.5]:
		_spall_parts.append(
			_box(_body, Vector3(0.36, 0.22, 0.52), Vector3(x, 0.77 * h, 0.0), plate)
		)
	_build_head_janissary(head_y, hs, plate)
	_build_arms(0.74 * h, 0.42, DARK, 0.17)
	_vent = CPUParticles3D.new()
	_vent.name = "Vent"
	_vent.emitting = false
	_vent.amount = 24
	_vent.lifetime = 0.9
	_vent.position = Vector3(0.0, 0.72 * h, 0.1)
	_vent.direction = Vector3(0.0, 1.0, 0.4)
	_vent.spread = 35.0
	_vent.initial_velocity_min = 1.0
	_vent.initial_velocity_max = 2.4
	_vent.gravity = Vector3(0.0, 0.6, 0.0)
	_vent.scale_amount_min = 0.15
	_vent.scale_amount_max = 0.35
	var puff := SphereMesh.new()
	puff.radius = 0.12
	puff.height = 0.24
	puff.material = _material(Color(0.82, 0.84, 0.85, 0.45), false, true)
	_vent.mesh = puff
	_body.add_child(_vent)


func _build_head_janissary(head_y: float, hs: float, plate: Color) -> void:
	if _head != null:
		_head.position = Vector3(0.0, head_y, 0.0)
	var parent_head: Node3D = _head if _head != null else _body
	var r := 0.2 * hs
	# Aventail at the neck.
	_box(parent_head, Vector3(0.36, 0.22, 0.36) * hs, Vector3(0.0, -0.08 * hs, 0.0), DARK)
	_cylinder(parent_head, r * 0.15, r, 0.42 * hs, Vector3(0.0, 0.08 * hs, 0.0), plate)  # cone
	if type.gilt_bands > 0 or type.full_tombak:
		_cylinder(
			parent_head, r * 1.02, r * 1.04, 0.04, Vector3(0.0, -0.1 * hs, 0.0), TOMBAK
		)
	# Nasal and the turquoise slit (the face hitbox sits on it).
	_box(parent_head, Vector3(0.03, 0.16, 0.03) * hs, Vector3(0.0, -0.06 * hs, -r - 0.01), plate)
	_sensor(parent_head, Vector3(0.0, -0.04 * hs, -r + 0.01), Vector3(0.22, 0.03, 0.02) * hs)
	# The bork's spoon-holder reborn as a sensor and command mast.
	_box(parent_head, Vector3(0.03, 0.14, 0.03) * hs, Vector3(0.0, 0.2 * hs, -r * 0.6), STEEL)
	# Crest: a tall felt fin trailing back. Spalls at stage 2.
	var crest := Node3D.new()
	crest.name = "Crest"
	crest.position = Vector3(0.0, 0.26 * hs, 0.02)
	crest.rotation.x = 0.55
	parent_head.add_child(crest)
	_box(crest, Vector3(0.06, 0.62, 0.34) * hs, Vector3(0.0, 0.22 * hs, 0.12 * hs), type.rank_color)
	if type.gilt_bands > 0:
		_box(crest, Vector3(0.07, 0.05, 0.36) * hs, Vector3(0.0, -0.04, 0.12 * hs), TOMBAK)
	if type.plume:
		_box(crest, Vector3(0.05, 0.5, 0.08) * hs, Vector3(0.0, 0.7 * hs, 0.05), FELT)
	_spall_parts.append(crest)


## Open-faced head: face (skin), cone helmet with nasal, the sensor slit on the brow.
## Azab (felt_cover): the rank-coloured felt pulled over the cone, flap hanging behind.
## Akinji: a fur cap over a skullcap instead of the cone.
func _build_head_open(head_y: float, hs: float, felt_cover: bool) -> void:
	if _head != null:
		_head.position = Vector3(0.0, head_y, 0.0)
	var parent_head: Node3D = _head if _head != null else _body
	_box(parent_head, Vector3(0.1, 0.1, 0.1) * hs, Vector3(0.0, -0.24 * hs, 0.0), SKIN)  # neck
	_box(parent_head, Vector3(0.19, 0.24, 0.21) * hs, Vector3(0.0, -0.06 * hs, -0.02), SKIN)
	var r := 0.135 * hs
	var brow := 0.04 * hs
	if felt_cover:
		# The cap is the class tell: a tall felt cone over the helmet, flap hanging behind.
		_cylinder(parent_head, 0.01, r, 0.3 * hs, Vector3(0.0, brow + 0.15 * hs, 0.0), type.plate_color)
		_cylinder(
			parent_head, 0.02, r * 1.15, 0.4 * hs, Vector3(0.0, brow + 0.2 * hs, 0.015), type.rank_color
		)
		var flap := _box(
			parent_head,
			Vector3(0.22, 0.3, 0.03) * hs,
			Vector3(0.0, brow - 0.02 * hs, 0.16 * hs),
			type.rank_color
		)
		flap.rotation.x = -0.25
		var nasal_at := Vector3(0.0, -0.04 * hs, -0.13 * hs)
		_box(parent_head, Vector3(0.025, 0.13, 0.02) * hs, nasal_at, type.plate_color)
		_sensor(parent_head, Vector3(0.0, brow + 0.02 * hs, -r + 0.02), Vector3(0.11, 0.018, 0.012) * hs)
		if type.plume:
			_box(parent_head, Vector3(0.04, 0.3, 0.06) * hs, Vector3(0.0, brow + 0.42 * hs, 0.04), FELT)
	else:
		_cylinder(parent_head, r, r * 1.02, 0.08 * hs, Vector3(0.0, brow + 0.02 * hs, 0.0), STEEL.darkened(0.3))
		var cap_h := (0.26 if type.plume else 0.15) * hs
		var cap_at := Vector3(0.0, brow + 0.06 * hs + cap_h * 0.5, 0.0)
		_cylinder(parent_head, r * 1.08, r * 1.22, cap_h, cap_at, FUR)
		_sensor(parent_head, Vector3(0.0, brow - 0.01 * hs, -r - 0.005), Vector3(0.11, 0.018, 0.012) * hs)
		# Looted Marine goggle strap.
		_box(parent_head, Vector3(0.21, 0.03, 0.22) * hs, Vector3(0.0, brow + 0.04 * hs, -0.01), LEATHER)
		if type.plume:
			_box(parent_head, Vector3(0.04, 0.32, 0.06) * hs, Vector3(0.0, brow + 0.38 * hs, 0.05), FELT)


func _build_legs(half_gap: float, length: float, width: float, cloth: Color, boot: Color) -> void:
	for side: float in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(side * half_gap, length, 0.0)
		_body.add_child(hip)
		_box(hip, Vector3(width, length * 0.55, width * 1.1), Vector3(0.0, -length * 0.27, 0.0), cloth)
		var boot_size := Vector3(width * 1.05, length * 0.48, width * 1.2)
		_box(hip, boot_size, Vector3(0.0, -length * 0.74, 0.0), boot)
		_legs.append(hip)


## Arms and the weapon pivot at the shoulder line; props hang under _arms pointing -Z.
func _build_arms(shoulder_y: float, half_width: float, color: Color, thick: float = 0.1) -> void:
	_shoulder_y = shoulder_y
	_arms = Node3D.new()
	_arms.name = "Arms"
	_arms.position = Vector3(0.12 * s, _shoulder_y, -0.05)
	_arms.rotation.x = _arm_pitch
	_body.add_child(_arms)
	# Upper arms reaching to the grip and fore-end.
	_box(_arms, Vector3(thick, thick, 0.42), Vector3(0.0, -0.08, -0.12), color)
	_box(_arms, Vector3(thick, thick, 0.5), Vector3(-half_width * 0.9, -0.06, -0.3), color)


func _sensor(parent: Node3D, at: Vector3, size: Vector3) -> void:
	var slit := _box(parent, size, at, SENSOR)
	slit.material_override = _material(SENSOR, true)
	slit.name = "SensorSlit"


# ------------------------------------------------------------------ weapon props


func _on_weapon_changed(weapon: BotWeapon) -> void:
	if is_instance_valid(_active_weapon):
		if _active_weapon.is_connected(&"fired", _on_weapon_fired):
			_active_weapon.disconnect(&"fired", _on_weapon_fired)
		if _active_weapon.is_connected(&"melee_swung", _on_melee_swung):
			_active_weapon.disconnect(&"melee_swung", _on_melee_swung)
	_active_weapon = weapon
	if is_instance_valid(_active_weapon):
		_active_weapon.fired.connect(_on_weapon_fired)
		_active_weapon.melee_swung.connect(_on_melee_swung)
	for w: Variant in _props.keys():
		if is_instance_valid(w):
			(_props[w] as Node3D).visible = w == weapon
			if _stowed.has(w):
				(_stowed[w] as Node3D).visible = w != weapon
	if weapon != null:
		_ensure_prop(weapon).visible = true
		if _stowed.has(weapon):
			(_stowed[weapon] as Node3D).visible = false
	_update_hum(weapon)


func _on_weapon_fired() -> void:
	_recoil_pitch = minf(_recoil_pitch + 0.12, 0.3)
	_recoil_push = minf(_recoil_push + 0.035, 0.08)


func _on_melee_swung() -> void:
	_melee_swing_t = 0.0
	var w := enemy.get_active()
	_melee_is_blade = w != null and w.data != null and w.data.melee_primary
	_melee_duration = w.data.melee_cooldown * 0.55 if (w != null and w.data != null) else 0.35


func _ensure_prop(weapon: BotWeapon) -> Node3D:
	if _props.has(weapon) and is_instance_valid(_props[weapon]):
		return _props[weapon]
	var prop := _make_prop(weapon.data, false)
	_arms.add_child(prop)
	_props[weapon] = prop
	if weapon.data != null and weapon.data.melee_primary:
		var hip := _make_prop(weapon.data, true)
		hip.position = Vector3(-0.2 * s, 0.5 * type.height, 0.05)
		hip.rotation = Vector3(-0.4, 0.0, 0.25)
		_body.add_child(hip)
		_stowed[weapon] = hip
	prop.visible = false
	return prop


## Prop by weapon mechanics, like BotWeaponPrefs' roles: blade, lobbing tube, or a rifle sized
## by role (glaive rifle with its blade, marksman rifle with a scope, short carbine, tufek).
func _make_prop(data: WeaponData, stowed: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "Prop"
	if data == null:
		return root
	var wood := Color("4a3423")
	if data.melee_primary:
		var janissary := type.corps == EnemyType.Corps.JANISSARY
		var length := 0.85 if janissary else 0.78
		_box(root, Vector3(0.04, 0.05, 0.18), Vector3(0.0, 0.0, -0.05), LEATHER)  # grip
		# Yatagan curves forward (down toward the edge), the kilij sweeps back near the tip.
		var bend := -0.18 if janissary else 0.22
		var a := _box(
			root, Vector3(0.012, 0.06, length * 0.6), Vector3(0.0, 0.0, -0.14 - length * 0.3), STEEL
		)
		a.rotation.x = bend * 0.4
		var b := _box(
			root,
			Vector3(0.012, 0.055, length * 0.45),
			Vector3(0.0, bend * length * 0.25, -0.14 - length * 0.78),
			STEEL
		)
		b.rotation.x = bend
		if not stowed:
			root.position = Vector3(-0.1, -0.1, -0.15)
		return root
	if data.projectile_speed > 0.0:
		var tube_rot := Vector3(PI * 0.5, 0.0, 0.0)
		_cylinder(root, 0.06, 0.07, 0.62, Vector3(0.0, 0.0, -0.3), type.plate_color, tube_rot)
		_box(root, Vector3(0.05, 0.12, 0.05), Vector3(0.0, -0.08, -0.08), wood)
		return root
	var length := 0.75
	if data.secondary == WeaponData.Secondary.ZOOM and data.damage >= 35.0:
		length = 1.25  # marksman long rifle
	elif type.corps == EnemyType.Corps.JANISSARY:
		length = 1.45  # tufek
	elif data.melee_damage >= 90.0:
		length = 1.05  # glaive rifle
	length *= clampf(s, 0.9, 1.2)
	_box(root, Vector3(0.05, 0.07, length * 0.55), Vector3(0.0, -0.01, -length * 0.2), wood)  # stock
	_box(root, Vector3(0.025, 0.025, length * 0.6), Vector3(0.0, 0.02, -length * 0.65), DARK)
	if data.secondary == WeaponData.Secondary.ZOOM and data.damage >= 35.0:
		_box(root, Vector3(0.04, 0.04, 0.24), Vector3(0.0, 0.07, -length * 0.35), DARK)
		_glint = _box(root, Vector3(0.05, 0.05, 0.01), Vector3(0.0, 0.07, -length * 0.35 - 0.125), FELT)
		_glint.material_override = _material(Color(1.0, 0.95, 0.8), true)
		_glint.scale = Vector3.ONE * 2.5
		_glint.visible = false
	if data.melee_damage >= 90.0 and type.corps == EnemyType.Corps.AZAB:
		# Glaive-length blade fixed under the muzzle: the forest of steel over the caps.
		_box(root, Vector3(0.008, 0.07, 0.5), Vector3(0.0, -0.01, -length * 0.95 - 0.22), STEEL)
	return root


func _update_hum(weapon: BotWeapon) -> void:
	var blade := (
		weapon != null
		and weapon.data != null
		and weapon.data.melee_primary
		and type.corps == EnemyType.Corps.JANISSARY
	)
	if not blade:
		if _hum != null:
			_hum.stop()
		return
	if _hum == null:
		_hum = AudioStreamPlayer3D.new()
		_hum.name = "BladeHum"
		_hum.stream = NewOttomanSounds.get_stream(&"hum")
		_hum.volume_db = -8.0
		_hum.unit_size = 4.0
		_hum.max_distance = 30.0
		add_child(_hum)
	if is_inside_tree():
		_hum.play()


# ------------------------------------------------------------------ damage and death


func _on_stage_changed(stage: ArmorStages.Stage) -> void:
	match stage:
		ArmorStages.Stage.SPALLED:
			for part in _spall_parts:
				_shed(part)
			_spall_parts.clear()
			if is_inside_tree():
				NewOttomanSounds.play_at(self, &"spall", global_position + Vector3(0, 1.4, 0), -4.0)
		ArmorStages.Stage.EXPOSED:
			for part in _spall_parts + _plate_parts:
				_shed(part)
			_spall_parts.clear()
			_plate_parts.clear()
			for part in _frame_parts:
				part.visible = true
			if _vent != null:
				_vent.emitting = true
			if is_inside_tree():
				NewOttomanSounds.play_at(self, &"spall", global_position + Vector3(0, 1.4, 0), -2.0)
				NewOttomanSounds.play_at(self, &"vent", _vent.global_position if _vent else global_position, -3.0)


## Throws a plate piece off as short-lived debris.
func _shed(part: Node3D) -> void:
	if not is_instance_valid(part) or not is_inside_tree():
		return
	var xform := part.global_transform
	var debris := RigidBody3D.new()
	debris.name = "PlateDebris"
	debris.collision_layer = 0
	debris.collision_mask = 1
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	var shape := CollisionShape3D.new()
	shape.shape = box
	debris.add_child(shape)
	var scene := get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	scene.add_child(debris)
	debris.global_transform = Transform3D(Basis(), xform.origin)
	part.get_parent().remove_child(part)
	debris.add_child(part)
	part.transform = Transform3D(xform.basis, Vector3.ZERO)
	var out := (xform.origin - global_position)
	out.y = 0.0
	out = out.normalized() if out.length_squared() > 0.001 else Vector3.BACK
	debris.linear_velocity = out * 2.5 + Vector3.UP * 3.0
	debris.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	get_tree().create_timer(DEBRIS_LIFETIME).timeout.connect(debris.queue_free)


func _on_damaged(amount: float, info: Dictionary) -> void:
	if amount > 0.0:
		_flinch_t = 0.16
		_flinch_amount = clampf(amount / 35.0, 0.4, 1.2)
	if float(info.get("shield_dealt", 0.0)) <= 0.0 or not info.has("position"):
		return
	# Plate hit: sparks and a whine, so plate reads as plate.
	var at: Vector3 = info.position
	var sparks := CPUParticles3D.new()
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.amount = 10
	sparks.lifetime = 0.25
	sparks.direction = info.get("normal", Vector3.UP)
	sparks.spread = 50.0
	sparks.initial_velocity_min = 3.0
	sparks.initial_velocity_max = 7.0
	var dot := SphereMesh.new()
	dot.radius = 0.015
	dot.height = 0.03
	dot.material = _material(Color(1.0, 0.75, 0.35), true)
	sparks.mesh = dot
	var scene := get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	scene.add_child(sparks)
	sparks.global_position = at
	sparks.emitting = true
	sparks.finished.connect(sparks.queue_free)
	if randf() < 0.35:
		NewOttomanSounds.play_at(scene, &"ricochet", at, -10.0)


func _on_died(_bot: Bot, _killer: Node, _info: Dictionary) -> void:
	_death_t = 0.0
	if _hum != null:
		_hum.stop()
	if _vent != null:
		_vent.emitting = false
	if _glint != null:
		_glint.visible = false


# ------------------------------------------------------------------ animation


func _physics_process(delta: float) -> void:
	if enemy == null or _body == null:
		return
	if _death_t >= 0.0:
		# Fall backward over 0.5 s and stay down.
		_death_t = minf(_death_t + delta, 0.5)
		var k := _death_t / 0.5
		_body.rotation.x = lerpf(0.0, PI * 0.5, k * k)
		_body.rotation.z = 0.0
		_body.position.y = -0.1 * k
		return
	_body.rotation.x = 0.0
	_body.position.y = 0.0
	var vel := enemy.velocity
	var speed := Vector2(vel.x, vel.z).length()
	var run := clampf(speed / Bot.STAND_SPEED, 0.0, 1.3)
	var on_floor := enemy.is_on_floor() or enemy.net_copy
	_walk_phase += delta * (4.0 + 7.0 * run) * (1.0 if on_floor else 0.2)
	for i in _legs.size():
		var swing := sin(_walk_phase + PI * i) * 0.6 * run
		_legs[i].rotation.x = swing if on_floor else -0.3
	# Akinji run low; a charging Janissary leans in.
	var lean := 0.0
	match type.corps:
		EnemyType.Corps.AKINJI:
			lean = -0.1 - 0.22 * run  # always a little hunched, low when running
		EnemyType.Corps.JANISSARY:
			lean = -0.12 * run
		_:
			lean = -0.06 * run
	if enemy.crouched:
		lean -= 0.25

	# Flinch reaction on body
	var flinch_x := 0.0
	var flinch_z := 0.0
	if _flinch_t > 0.0:
		_flinch_t = maxf(_flinch_t - delta, 0.0)
		var flinch_k := sin((_flinch_t / 0.16) * PI) * 0.1 * _flinch_amount
		flinch_x = flinch_k * 0.7
		flinch_z = flinch_k * 0.5

	_body.rotation.x = lean + flinch_x
	_body.rotation.z = flinch_z

	# Coat flares behind the runner (back panel most).
	for i in _coat_panels.size():
		var flare := -1.1 * run if i == 0 else -0.5 * run
		_coat_panels[i].rotation.x = flare + sin(_walk_phase * 2.0 + i) * 0.08 * run

	# Head: tracks aim pitch smoothly.
	var head_target: float = enemy.head.rotation.x - lean
	_head_pitch = lerpf(_head_pitch, head_target, 1.0 - exp(-14.0 * delta))
	if _head != null:
		_head.rotation.x = clampf(_head_pitch, -0.85, 0.85)

	# Weapon: aim along the head's pitch while engaging, else port arms.
	var target: float = REST_PITCH[type.corps]
	var brain := enemy.get_node_or_null(^"Brain") as BotBrain
	var fighting := brain != null and (
		brain.state == BotBrain.State.ENGAGE or brain.state == BotBrain.State.RETREAT
	)
	if fighting or (enemy.net_copy and enemy.net_aiming):
		target = enemy.head.rotation.x - lean
	_arm_pitch = lerpf(_arm_pitch, target, 1.0 - exp(-10.0 * delta))

	# Recoil decay
	_recoil_pitch = lerpf(_recoil_pitch, 0.0, 1.0 - exp(-20.0 * delta))
	_recoil_push = lerpf(_recoil_push, 0.0, 1.0 - exp(-16.0 * delta))

	# Melee swing progress
	var melee_rot := Vector3.ZERO
	var melee_off := Vector3.ZERO
	if _melee_swing_t >= 0.0:
		_melee_swing_t += delta
		if _melee_swing_t >= _melee_duration:
			_melee_swing_t = -1.0
		else:
			var p := _melee_swing_t / _melee_duration
			if _melee_is_blade:
				if p < 0.25:
					var wind := p / 0.25
					melee_rot = Vector3(-0.45 * wind, -0.55 * wind, 0.35 * wind)
				else:
					var cut_p := (p - 0.25) / 0.75
					var cut := sin(cut_p * PI)
					melee_rot = Vector3(0.75 * cut, 0.8 * cut, -0.45 * cut)
					melee_off = Vector3(0.05 * cut, -0.05 * cut, -0.15 * cut)
			else:
				var jab := sin(p * PI)
				melee_rot = Vector3(0.22 * jab, 0.0, 0.0)
				melee_off = Vector3(0.0, 0.0, -0.2 * jab)

	# Natural arm gait sway when moving
	if not fighting and _melee_swing_t < 0.0 and on_floor:
		melee_rot.x += sin(_walk_phase) * 0.06 * run
		melee_rot.z += cos(_walk_phase) * 0.03 * run

	if _arms != null:
		_arms.rotation = Vector3(_arm_pitch + _recoil_pitch + melee_rot.x, melee_rot.y, melee_rot.z)
		_arms.position = Vector3(
			0.12 * s + melee_off.x,
			_shoulder_y + melee_off.y,
			-0.05 + _recoil_push + melee_off.z
		)

	if _glint_left > 0.0:
		_glint_left -= delta
		if _glint_left <= 0.0 and _glint != null:
			_glint.visible = false
	if _hum != null and _hum.playing and brain != null and brain.target != null:
		var d := enemy.global_position.distance_to(brain.target.global_position)
		_hum.pitch_scale = lerpf(1.6, 0.8, clampf(d / 15.0, 0.0, 1.0))


# ------------------------------------------------------------------ primitives


func _box(parent: Node3D, size: Vector3, at: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = at
	inst.material_override = _material(color)
	parent.add_child(inst)
	return inst


func _cylinder(
	parent: Node3D,
	top: float,
	bottom: float,
	height: float,
	at: Vector3,
	color: Color,
	rot: Vector3 = Vector3.ZERO
) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 12
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = at
	inst.rotation = rot
	inst.material_override = _material(color)
	parent.add_child(inst)
	return inst


## Lacquered plate is a little glossy; tombak is metallic; cloth is rough. Emissive = sensor.
func _material(
	color: Color, emissive: bool = false, transparent: bool = false
) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), emissive, transparent]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.8
	if color == TOMBAK:
		m.metallic = 0.8
		m.roughness = 0.35
	elif color == type.plate_color or color == STEEL:
		m.metallic = 0.5
		m.roughness = 0.45
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 2.0
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_materials[key] = m
	return m
