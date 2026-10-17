class_name CharacterWeaponProps
extends Node
## Third-person weapon visuals for the animated body: the active weapon on WeaponAttach_R and
## the other slot holstered (rifle on the back, pistol on the right thigh). Driven only by the
## synced CharacterAnimState (via CharacterAnimDriver.state_applied), so remote proxies match.
## Visuals are script-less copies of the first-person weapon scenes with viewmodel_only nodes
## removed (same approach as WeaponPickup).
## Switch: the old weapon stays in hand and the new one holstered until the switch clip's
## method key calls anim_swap_weapon() on the exact frame the hand reaches the holster (behind
## the helmet for the rifle, at the hip for the pistol). Holster transforms come from the
## AnimationLibrary metadata (holster_rifle / holster_pistol, written by the generator from that
## frame), so the drawn weapon leaves the holster without a jump. If the key never arrives
## (clip missing, action aborted), the swap happens when the switch would have ended.
## Meshes follow CharacterAnimState.weapon_model / holster_model (shotgun, carbine and rocket
## launcher are held like the rifle but keep their own look; the launcher's tube sits up on the
## shoulder, rocket_shoulder_offset). An unknown model falls back to the
## rifle or pistol by weapon class. Rifle-class weapons holster on the back, pistols on the thigh.
## The New Ottoman weapons (NEW_OTTOMAN_SCENES, loaded on first use) are held like the rifle,
## the sabre and yatagan like the longsword and hung at the hip with it.

const CHEST := "Blockout/BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest"
const NEW_OTTOMAN_SCENES := {
	CharacterAnimState.WeaponModel.TUFEK: "res://scenes/weapons/new_ottoman/tufek.tscn",
	CharacterAnimState.WeaponModel.GLAIVE_RIFLE:
	"res://scenes/weapons/new_ottoman/glaive_rifle.tscn",
	CharacterAnimState.WeaponModel.HUMBARA:
	"res://scenes/weapons/new_ottoman/humbara_launcher.tscn",
	CharacterAnimState.WeaponModel.RAIDER_CARBINE:
	"res://scenes/weapons/new_ottoman/raider_carbine.tscn",
	CharacterAnimState.WeaponModel.LONG_RIFLE: "res://scenes/weapons/new_ottoman/long_rifle.tscn",
	CharacterAnimState.WeaponModel.KILIJ: "res://scenes/weapons/new_ottoman/kilij.tscn",
	CharacterAnimState.WeaponModel.YATAGAN: "res://scenes/weapons/new_ottoman/yatagan.tscn",
}

@export var driver: CharacterAnimDriver
## The PlayerModel root (paths below are relative to it; its first_person_hidden is mirrored).
@export var model_path: NodePath = ^".."
@export
var hand_path: NodePath = NodePath(CHEST + "/PB_UpperArm_R/PB_Forearm_R/PB_Hand_R/WeaponAttach_R")
@export var back_path: NodePath = NodePath(CHEST)
@export var thigh_path: NodePath = ^"Blockout/BodyMesh/PB_Pelvis/PB_Thigh_R"
## The longsword hangs from the hip (pelvis), not the thigh, so it doesn't swing with the leg.
@export var hip_path: NodePath = ^"Blockout/BodyMesh/PB_Pelvis"
@export var rifle_scene: PackedScene = preload("res://scenes/weapons/standard_issue_rifle.tscn")
@export var pistol_scene: PackedScene = preload("res://scenes/weapons/service_pistol.tscn")
## Scenes for the other models; their grip point is found from the scene's Grip mesh
## (grip_from_mesh is the rifle's grip-point offset from its own Grip mesh).
@export var carbine_scene: PackedScene = preload("res://scenes/weapons/marksman_carbine.tscn")
@export var shotgun_scene: PackedScene = preload("res://scenes/weapons/combat_shotgun.tscn")
@export var rocket_scene: PackedScene = preload("res://scenes/weapons/directed_energy_rifle.tscn")
@export var sword_scene: PackedScene = preload("res://scenes/weapons/longsword.tscn")
@export var hammer_scene: PackedScene = preload("res://scenes/weapons/gravity_hammer.tscn")
@export var grip_from_mesh: Vector3 = Vector3(0, 0.02, -0.01)
## First-person weapon scenes are modelled small; third-person props are scaled up.
@export var rifle_scale: float = 1.4
@export var pistol_scale: float = 1.4
## Grip centre in each weapon scene's own space (put on WeaponAttach_R).
@export var rifle_grip: Vector3 = Vector3(0, -0.05, 0.09)
@export var pistol_grip: Vector3 = Vector3(0, -0.045, 0.06)
## Fallback holster transforms of the grip point, in PB_Chest / PB_Thigh_R space, used only if
## the library has no holster_* metadata (values match the generator's v1.2 output).
@export var rifle_holster: Transform3D = Transform3D(
	Basis(Vector3.RIGHT, deg_to_rad(80)) * Basis(Vector3.BACK, deg_to_rad(-25)),
	Vector3(0.10, 0.575, 0.18)
)
@export var pistol_holster: Transform3D = Transform3D(
	Basis(
		Vector3(0.9884, -0.0528, -0.1423),
		Vector3(-0.131, 0.1776, -0.9754),
		Vector3(0.0768, 0.9827, 0.1686)
	),
	Vector3(0.1115, -0.0091, 0.0045)
)
## Rocket launcher in the hand: the tube rides up on the shoulder and back past it, with the
## hand under it on the grip, instead of being held at the chest like a rifle (WeaponAttach_R
## space: +Y up, +Z back). The arms still use the rifle poses; only the prop moves.
@export var rocket_shoulder_offset: Vector3 = Vector3(0.04, 0.15, 0.2)
## Gravity hammer: a MELEE action with it in hand draws MeleeFx.shockwave this far in front of
## the body, smash_delay after the swing starts (Weapon's smash timing).
@export var hammer_smash_reach: float = 2.5
@export var hammer_smash_delay: float = 0.25
## Extra time after the switch's end before the fallback swap, seconds.
@export var swap_fallback_margin: float = 0.05

var _model: Node3D
var _hand: Node3D
var _back: Node3D
var _thigh: Node3D
var _hip: Node3D
## Library holster_<class> metadata (sword, hammer): grip transform in its parent's space.
var _holsters: Dictionary = {}
## WeaponModel -> Node3D visual, one set in the hand and one in the holsters.
var _hand_props: Dictionary = {}
var _holster_props: Dictionary = {}
## WeaponModel -> grip point in the weapon scene's own space (unscaled).
var _grips: Dictionary = {}
var _shown_hand: int = CharacterAnimState.WeaponModel.NONE
var _shown_holster: int = CharacterAnimState.WeaponModel.NONE
var _pending_hand: int = -1
var _pending_holster: int = -1
var _swap_left: float = 0.0
var _last_action_seq: int = -1
var _hidden_layers: bool = false


func _ready() -> void:
	_model = get_node_or_null(model_path) as Node3D
	if _model == null:
		push_warning("%s: no model at %s" % [name, model_path])
		return
	_hand = _model.get_node_or_null(hand_path) as Node3D
	_back = _model.get_node_or_null(back_path) as Node3D
	_thigh = _model.get_node_or_null(thigh_path) as Node3D
	_hip = _model.get_node_or_null(hip_path) as Node3D
	if _hand == null:
		push_warning("%s: no weapon attach at %s" % [name, hand_path])
	if driver != null:
		driver.state_applied.connect(_on_state)
		_read_holster_meta()


## Holster transforms written by tools/character_anims/gen_character_anims.py.
func _read_holster_meta() -> void:
	var player := driver.animation_player
	if player == null or not player.has_animation_library(&""):
		return
	var lib := player.get_animation_library(&"")
	var rifle: Variant = lib.get_meta(&"holster_rifle", null)
	var pistol: Variant = lib.get_meta(&"holster_pistol", null)
	for key: StringName in [&"sword", &"hammer"]:
		var xf: Variant = lib.get_meta(StringName("holster_%s" % key), null)
		if xf is Transform3D:
			_holsters[key] = xf
	if rifle is Transform3D:
		rifle_holster = rifle
	if pistol is Transform3D:
		pistol_holster = pistol


## Called by the switch clips' method track on the frame the hand reaches the holster.
func anim_swap_weapon() -> void:
	if _pending_hand >= 0:
		_show(_pending_hand, _pending_holster)
		_pending_hand = -1


func _process(delta: float) -> void:
	if _model != null:
		# get() is a Variant. Comparing it does not infer a type, so := will not compile.
		var hidden := bool(_model.get(&"first_person_hidden"))
		if hidden != _hidden_layers:
			_hidden_layers = hidden
			for prop: Node3D in _hand_props.values() + _holster_props.values():
				_apply_layers(prop)
	if _pending_hand < 0:
		return
	_swap_left -= delta
	if _swap_left <= 0.0:
		_show(_pending_hand, _pending_holster)
		_pending_hand = -1


func _on_state(state: CharacterAnimState) -> void:
	var new_action := state.action_seq != _last_action_seq and _last_action_seq >= 0
	var switching := (
		state.action == CharacterAnimState.Action.SWITCH and state.action_seq != _last_action_seq
	)
	if (
		new_action
		and state.action == CharacterAnimState.Action.MELEE
		and state.weapon_model == CharacterAnimState.WeaponModel.HAMMER
		and not state.dead
	):
		get_tree().create_timer(hammer_smash_delay, false).timeout.connect(_smash_fx)
	_last_action_seq = state.action_seq
	var hand := _model_or_class(state.weapon_model, state.weapon_type)
	var holster := _model_or_class(state.holster_model, state.holster_type)
	if state.dead and _pending_hand >= 0:
		anim_swap_weapon()
	if switching and _shown_hand != hand and _shown_hand != CharacterAnimState.WeaponModel.NONE:
		# Until the swap key: old weapon in hand, the new one still holstered.
		_show(_shown_hand, hand)
		_pending_hand = hand
		_pending_holster = holster
		_swap_left = maxf(state.action_duration, 0.0) + swap_fallback_margin
		return
	if _pending_hand >= 0:
		_pending_hand = hand
		_pending_holster = holster
		return
	if hand != _shown_hand or holster != _shown_holster:
		_show(hand, holster)


## The synced model, or the class's default mesh when the model is unknown.
static func _model_or_class(model: int, type: int) -> int:
	if model != CharacterAnimState.WeaponModel.NONE:
		return model
	match type:
		CharacterAnimState.WeaponType.RIFLE:
			return CharacterAnimState.WeaponModel.RIFLE
		CharacterAnimState.WeaponType.PISTOL:
			return CharacterAnimState.WeaponModel.PISTOL
		CharacterAnimState.WeaponType.SWORD:
			return CharacterAnimState.WeaponModel.SWORD
		CharacterAnimState.WeaponType.HAMMER:
			return CharacterAnimState.WeaponModel.HAMMER
	return CharacterAnimState.WeaponModel.NONE


## One-handed models: the pistol hold and the thigh holster (the swords hang at the hip).
static func _is_pistol(model: int) -> bool:
	return model == CharacterAnimState.WeaponModel.PISTOL or _is_sword(model)


## Blades on the longsword's frame: its grip, scale and hip holster.
static func _is_sword(model: int) -> bool:
	return (
		model == CharacterAnimState.WeaponModel.SWORD
		or model == CharacterAnimState.WeaponModel.KILIJ
		or model == CharacterAnimState.WeaponModel.YATAGAN
	)


func _show(hand: int, holster: int) -> void:
	_shown_hand = hand
	_shown_holster = holster
	for model: int in CharacterAnimState.WeaponModel.values():
		if model == CharacterAnimState.WeaponModel.NONE:
			continue
		var hand_xf := Transform3D.IDENTITY
		if model == CharacterAnimState.WeaponModel.ROCKET:
			hand_xf.origin = rocket_shoulder_offset
		_set_visible(_hand_props, model, hand == model, _hand, hand_xf)
		var holster_parent := _thigh if _is_pistol(model) else _back
		var holster_xf := pistol_holster if _is_pistol(model) else rifle_holster
		# The melee weapons have their own holsters (generator: holster_sword / _hammer).
		if _is_sword(model) and _holsters.has(&"sword"):
			holster_parent = _hip
			holster_xf = _holsters[&"sword"]
		elif model == CharacterAnimState.WeaponModel.HAMMER and _holsters.has(&"hammer"):
			holster_xf = _holsters[&"hammer"]
		_set_visible(
			_holster_props, model, holster == model and holster != hand, holster_parent, holster_xf
		)


## grip_xf: where the grip point goes in the parent's space (the prop's grip offset is added).
func _set_visible(
	props: Dictionary, model: int, visible: bool, parent: Node3D, grip_xf: Transform3D
) -> void:
	if not visible:
		if props.has(model):
			(props[model] as Node3D).visible = false
		return
	if parent == null:
		return
	if not props.has(model):
		var prop := _make_prop(model)
		if prop == null:
			return
		parent.add_child(prop)
		props[model] = prop
	var node := props[model] as Node3D
	node.transform = grip_xf * _grip_offset(model)
	node.visible = true


func _smash_fx() -> void:
	if _model == null or not _model.is_inside_tree():
		return
	var forward := -_model.global_basis.z
	forward = Vector3(forward.x, 0.0, forward.z).normalized()
	var at := _model.global_position + forward * hammer_smash_reach
	# Onto the floor under that point (the ring lies flat on whatever was hit).
	var space := _model.get_world_3d().direct_space_state
	var down := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.5, at + Vector3.DOWN * 3.0, 1)
	var hit := space.intersect_ray(down)
	if not hit.is_empty():
		at = hit.position + Vector3.UP * 0.05
	var scene := _model.get_tree().current_scene
	MeleeFx.shockwave(scene if scene != null else _model.get_tree().root, at)


## Places the weapon so its grip sits on the attach point (attach -Z = barrel).
func _grip_offset(model: int) -> Transform3D:
	var s := pistol_scale if _is_pistol(model) else rifle_scale
	var grip: Vector3 = _grips.get(model, pistol_grip if _is_pistol(model) else rifle_grip)
	return Transform3D(Basis().scaled(Vector3.ONE * s), -grip * s)


func _scene_of(model: int) -> PackedScene:
	match model:
		CharacterAnimState.WeaponModel.RIFLE:
			return rifle_scene
		CharacterAnimState.WeaponModel.PISTOL:
			return pistol_scene
		CharacterAnimState.WeaponModel.CARBINE:
			return carbine_scene
		CharacterAnimState.WeaponModel.SHOTGUN:
			return shotgun_scene
		CharacterAnimState.WeaponModel.ROCKET:
			return rocket_scene
		CharacterAnimState.WeaponModel.SWORD:
			return sword_scene
		CharacterAnimState.WeaponModel.HAMMER:
			return hammer_scene
	if NEW_OTTOMAN_SCENES.has(model):
		return load(NEW_OTTOMAN_SCENES[model]) as PackedScene
	return null


func _make_prop(model: int) -> Node3D:
	var scene := _scene_of(model)
	if scene == null:
		return null
	var copy := scene.instantiate() as Node3D
	if copy == null:
		return null
	# The weapon scene's root carries its first-person offset; the prop is placed by grip.
	copy.transform = Transform3D.IDENTITY
	var grip_mesh := copy.get_node_or_null(^"Grip") as Node3D
	if (
		grip_mesh != null
		and model != CharacterAnimState.WeaponModel.RIFLE
		and model != CharacterAnimState.WeaponModel.PISTOL
	):
		_grips[model] = grip_mesh.position + grip_from_mesh
	copy.set_script(null)
	for node in copy.find_children("*", "", true, false):
		if node.is_in_group(&"viewmodel_only"):
			node.get_parent().remove_child(node)
			node.free()
	copy.name = "Prop_%s" % CharacterAnimState.WeaponModel.keys()[model].capitalize()
	_apply_layers(copy)
	return copy


func _apply_layers(prop: Node3D) -> void:
	var bits := 2 if _hidden_layers else 1  # PlayerModel.LAYERS_FIRST_PERSON_HIDDEN / VISIBLE
	for node in prop.find_children("*", "GeometryInstance3D", true, false):
		var geo := node as GeometryInstance3D
		geo.layers = bits
		geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
