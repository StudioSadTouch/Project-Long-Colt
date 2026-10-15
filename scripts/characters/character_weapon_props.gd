class_name CharacterWeaponProps
extends Node
## Third-person weapon visuals for the animated body: the active weapon on WeaponAttach_R and
## the other slot holstered (rifle on the back, pistol on the right thigh). Driven only by the
## synced CharacterAnimState (via CharacterAnimDriver.state_applied), so remote proxies match.
## Visuals are script-less copies of the first-person weapon scenes with viewmodel_only nodes
## removed (same approach as WeaponPickup). On a switch the hand prop swaps at
## swap_fraction of the switch, when the switch clip has the hand at the holster.

const CHEST := "Blockout/BodyMesh/PB_Pelvis/PB_Abdomen/PB_Chest"

@export var driver: CharacterAnimDriver
## The PlayerModel root (paths below are relative to it; its first_person_hidden is mirrored).
@export var model_path: NodePath = ^".."
@export
var hand_path: NodePath = NodePath(CHEST + "/PB_UpperArm_R/PB_Forearm_R/PB_Hand_R/WeaponAttach_R")
@export var back_path: NodePath = NodePath(CHEST)
@export var thigh_path: NodePath = ^"Blockout/BodyMesh/PB_Pelvis/PB_Thigh_R"
@export var rifle_scene: PackedScene = preload("res://scenes/weapons/standard_issue_rifle.tscn")
@export var pistol_scene: PackedScene = preload("res://scenes/weapons/service_pistol.tscn")
## First-person weapon scenes are modelled small; third-person props are scaled up.
@export var rifle_scale: float = 1.4
@export var pistol_scale: float = 1.4
## Grip centre in each weapon scene's own space (put on WeaponAttach_R).
@export var rifle_grip: Vector3 = Vector3(0, -0.05, 0.09)
@export var pistol_grip: Vector3 = Vector3(0, -0.045, 0.06)
## Holster transforms of the grip point, in PB_Chest / PB_Thigh_R space (rest pose).
@export var rifle_holster: Transform3D = Transform3D(
	Basis(Vector3.RIGHT, deg_to_rad(80)) * Basis(Vector3.BACK, deg_to_rad(-25)),
	Vector3(0.14, 0.54, 0.2)
)
@export var pistol_holster: Transform3D = Transform3D(
	Basis(Vector3.RIGHT, deg_to_rad(-75)), Vector3(0.13, -0.02, 0.02)
)
@export_range(0.0, 1.0) var swap_fraction: float = 0.5

var _model: Node3D
var _hand: Node3D
var _back: Node3D
var _thigh: Node3D
## WeaponType -> Node3D visual (one per class, reparented between hand and holster).
var _hand_props: Dictionary = {}
var _holster_props: Dictionary = {}
var _shown_hand: int = CharacterAnimState.WeaponType.NONE
var _shown_holster: int = CharacterAnimState.WeaponType.NONE
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
	if _hand == null:
		push_warning("%s: no weapon attach at %s" % [name, hand_path])
	if driver != null:
		driver.state_applied.connect(_on_state)


func _process(delta: float) -> void:
	if _model != null:
		var hidden := _model.get(&"first_person_hidden") == true
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
	var switching := (
		state.action == CharacterAnimState.Action.SWITCH and state.action_seq != _last_action_seq
	)
	_last_action_seq = state.action_seq
	var hand := state.weapon_type
	var holster := state.holster_type
	if switching and _shown_hand != hand and _shown_hand != CharacterAnimState.WeaponType.NONE:
		# First half of the switch: old weapon in hand, the new one still holstered.
		_show(_shown_hand, hand)
		_pending_hand = hand
		_pending_holster = holster
		_swap_left = maxf(state.action_duration, 0.0) * swap_fraction
		return
	if _pending_hand >= 0:
		_pending_hand = hand
		_pending_holster = holster
		return
	if hand != _shown_hand or holster != _shown_holster:
		_show(hand, holster)


func _show(hand: int, holster: int) -> void:
	_shown_hand = hand
	_shown_holster = holster
	for type: int in [CharacterAnimState.WeaponType.RIFLE, CharacterAnimState.WeaponType.PISTOL]:
		_set_visible(_hand_props, type, hand == type, _hand, _hand_transform(type))
		var holster_parent := _back if type == CharacterAnimState.WeaponType.RIFLE else _thigh
		var holster_xf := (
			rifle_holster if type == CharacterAnimState.WeaponType.RIFLE else pistol_holster
		)
		_set_visible(
			_holster_props,
			type,
			holster == type and holster != hand,
			holster_parent,
			holster_xf * _grip_offset(type)
		)


func _set_visible(
	props: Dictionary, type: int, visible: bool, parent: Node3D, xf: Transform3D
) -> void:
	if not visible:
		if props.has(type):
			(props[type] as Node3D).visible = false
		return
	if parent == null:
		return
	if not props.has(type):
		var prop := _make_prop(type)
		if prop == null:
			return
		parent.add_child(prop)
		props[type] = prop
	var node := props[type] as Node3D
	node.transform = xf
	node.visible = true


func _hand_transform(type: int) -> Transform3D:
	return _grip_offset(type)


## Places the weapon so its grip sits on the attach point (attach -Z = barrel).
func _grip_offset(type: int) -> Transform3D:
	var rifle := type == CharacterAnimState.WeaponType.RIFLE
	var s := rifle_scale if rifle else pistol_scale
	var grip := rifle_grip if rifle else pistol_grip
	return Transform3D(Basis().scaled(Vector3.ONE * s), -grip * s)


func _make_prop(type: int) -> Node3D:
	var scene := rifle_scene if type == CharacterAnimState.WeaponType.RIFLE else pistol_scene
	if scene == null:
		return null
	var copy := scene.instantiate() as Node3D
	if copy == null:
		return null
	copy.set_script(null)
	for node in copy.find_children("*", "", true, false):
		if node.is_in_group(&"viewmodel_only"):
			node.get_parent().remove_child(node)
			node.free()
	copy.name = "Prop_%s" % ("Rifle" if type == CharacterAnimState.WeaponType.RIFLE else "Pistol")
	_apply_layers(copy)
	return copy


func _apply_layers(prop: Node3D) -> void:
	var bits := 2 if _hidden_layers else 1  # PlayerModel.LAYERS_FIRST_PERSON_HIDDEN / VISIBLE
	for node in prop.find_children("*", "GeometryInstance3D", true, false):
		var geo := node as GeometryInstance3D
		geo.layers = bits
		geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
