class_name CharacterAnimDriver
extends Node
## Third-person animation driver for players, bots and dummies. Builds its own AnimationTree
## (see /workspace/anims/thirdperson_plan.md §2) over an existing AnimationPlayer and drives it
## only from CharacterAnimState, so local, remote and AI bodies animate identically.
## Rig-independent: clip names, upper-body filter paths and blendspace speeds are exports.
## Missing clips are skipped (one warning each), so this can be wired before clips exist.
##
## Usage: driver.apply_state(state) every physics tick (local/authority), or whenever a
## snapshot arrives (remote). Call reset_baseline() on spawn / late join so stale sequence
## counters don't replay an old action.

const LOCO := &"Locomotion"
const ST_GROUND := &"Ground"
const ST_CROUCH := &"Crouch"
const ST_JUMP := &"JumpStart"
const ST_FALL := &"Fall"
const ST_LAND := &"Land"
const ST_SLIDE := &"Slide"
const WEAPON_INPUTS := ["none", "rifle", "pistol"]
const DEATH_CLIPS := [&"death_fwd", &"death_back", &"death_left", &"death_right"]

@export var animation_player: AnimationPlayer
## Node paths (relative to the AnimationPlayer's root node) that take the upper-body layer:
## aim, fire, reload, melee, switch. Fill in once the rig is signed off.
@export var upper_body_paths: Array[NodePath] = []
## Authored speeds of the walk / run / crouch-walk clips, m/s.
@export var walk_speed: float = 3.5
@export var run_speed: float = 7.5
@export var crouch_walk_speed: float = 3.2
## Pitch that maps to the aim_*_up / aim_*_down poses, degrees.
@export var aim_pitch_limit_deg: float = 89.0
## Blend-position smoothing rate (1/s). 0 = snap.
@export var blend_smoothing: float = 12.0
@export var action_fade_in: float = 0.08
@export var action_fade_out: float = 0.12

var tree: AnimationTree

var _playback: AnimationNodeStateMachinePlayback
var _action_anim: AnimationNodeAnimation
var _fire_anim: AnimationNodeAnimation
var _death_anim: AnimationNodeAnimation
var _warned: Dictionary = {}
var _have_baseline: bool = false
var _last: CharacterAnimState
var _move_blend: Vector2 = Vector2.ZERO
var _was_on_floor: bool = true


func _ready() -> void:
	if animation_player == null:
		push_error("%s: needs an AnimationPlayer" % name)
		return
	_build_tree()


## Forget previous sequence counters: the next state sets the baseline without firing.
func reset_baseline() -> void:
	_have_baseline = false


func apply_state(state: CharacterAnimState) -> void:
	if tree == null or state == null:
		return
	if not _have_baseline:
		_last = CharacterAnimState.from_dict(state.to_dict())
		_have_baseline = true
		_was_on_floor = state.on_floor
		_set_life(state.dead, state.death_dir)
		return
	var delta := get_physics_process_delta_time()
	_update_life(state)
	if not state.dead:
		_update_locomotion(state, delta)
		_update_upper(state)
		_update_one_shots(state)
	_was_on_floor = state.on_floor
	_last = CharacterAnimState.from_dict(state.to_dict())


func _update_life(state: CharacterAnimState) -> void:
	if state.death_seq != _last.death_seq or state.dead != _last.dead:
		_set_life(state.dead, state.death_dir)
		if not state.dead:
			_playback.start(ST_GROUND)


func _set_life(dead: bool, death_dir: int) -> void:
	if dead:
		_death_anim.animation = _clip(DEATH_CLIPS[clampi(death_dir, 0, DEATH_CLIPS.size() - 1)])
		tree.set(&"parameters/action_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
		tree.set(&"parameters/fire_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set(&"parameters/life/transition_request", "dead" if dead else "alive")


func _update_locomotion(state: CharacterAnimState, delta: float) -> void:
	var local := Basis(Vector3.UP, state.yaw).inverse() * state.velocity
	var target := Vector2(local.x, -local.z)
	if blend_smoothing > 0.0:
		_move_blend = _move_blend.lerp(target, 1.0 - exp(-blend_smoothing * delta))
	else:
		_move_blend = target
	tree.set(&"parameters/Locomotion/Ground/blend_position", _move_blend)
	tree.set(&"parameters/Locomotion/Crouch/blend_position", _move_blend)
	var current := _playback.get_current_node()
	var wanted := current
	if state.sliding:
		wanted = ST_SLIDE
	elif not state.on_floor:
		if _was_on_floor and state.velocity.y > 0.1 and _clip(&"jump_start") != &"":
			wanted = ST_JUMP
		elif current != ST_JUMP and current != ST_FALL:
			wanted = ST_FALL
	elif not _was_on_floor and _clip(&"land") != &"":
		wanted = ST_LAND
	elif current == ST_LAND:
		# Land auto-advances to Ground at its end; crouch picks up on the next tick.
		wanted = ST_LAND
	else:
		wanted = ST_CROUCH if state.crouched else ST_GROUND
	if wanted != current:
		_playback.start(wanted)


func _update_upper(state: CharacterAnimState) -> void:
	var idx := clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)
	tree.set(&"parameters/weapon/transition_request", WEAPON_INPUTS[idx])
	var pitch := clampf(state.aim_pitch / deg_to_rad(aim_pitch_limit_deg), -1.0, 1.0)
	for w: String in WEAPON_INPUTS:
		tree.set(StringName("parameters/aim_%s/blend_position" % w), pitch)


func _update_one_shots(state: CharacterAnimState) -> void:
	if state.action_seq != _last.action_seq and state.action != CharacterAnimState.Action.NONE:
		_play_action(state)
	elif state.action_cancel_seq != _last.action_cancel_seq:
		tree.set(&"parameters/action_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	if state.fire_seq != _last.fire_seq:
		var rifle := state.weapon_type == CharacterAnimState.WeaponType.RIFLE
		var fire := _clip(&"fire_rifle" if rifle else &"fire_pistol")
		if fire != &"":
			_fire_anim.animation = fire
			tree.set(&"parameters/fire_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _play_action(state: CharacterAnimState) -> void:
	var weapon: String = WEAPON_INPUTS[clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)]
	var base := ""
	match state.action:
		CharacterAnimState.Action.RELOAD:
			base = "reload_%s" % weapon
		CharacterAnimState.Action.RELOAD_EMPTY:
			base = "reload_%s_empty" % weapon
		CharacterAnimState.Action.MELEE:
			base = "melee_%s" % weapon
		CharacterAnimState.Action.SWITCH:
			base = "switch_%s" % weapon
	var clip := _clip(StringName(base))
	if clip == &"" and state.action == CharacterAnimState.Action.RELOAD_EMPTY:
		clip = _clip(StringName("reload_%s" % weapon))
	if clip == &"":
		return
	_action_anim.animation = clip
	var length := animation_player.get_animation(clip).length
	var scale := 1.0
	if state.action_duration > 0.0:
		scale = length / state.action_duration
	tree.set(&"parameters/action_scale/scale", scale)
	tree.set(&"parameters/action_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## Returns the clip name if the AnimationPlayer has it, else &"" (warns once).
func _clip(clip_name: StringName) -> StringName:
	if animation_player.has_animation(clip_name):
		return clip_name
	if not _warned.has(clip_name):
		_warned[clip_name] = true
		push_warning("%s: missing clip '%s'" % [name, clip_name])
	return &""


func _anim(clip_name: StringName) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = clip_name
	return node


func _build_tree() -> void:
	var root := AnimationNodeBlendTree.new()
	root.add_node(LOCO, _build_locomotion(), Vector2(0, 0))

	var weapon := AnimationNodeTransition.new()
	for w: String in WEAPON_INPUTS:
		weapon.add_input(w)
	root.add_node(&"weapon", weapon, Vector2(0, 200))
	for i in WEAPON_INPUTS.size():
		var w: String = WEAPON_INPUTS[i]
		var aim := AnimationNodeBlendSpace1D.new()
		aim.min_space = -1.0
		aim.max_space = 1.0
		aim.add_blend_point(_anim(StringName("aim_%s_down" % w)), -1.0)
		aim.add_blend_point(_anim(StringName("aim_%s_mid" % w)), 0.0)
		aim.add_blend_point(_anim(StringName("aim_%s_up" % w)), 1.0)
		root.add_node(StringName("aim_%s" % w), aim, Vector2(-200, 200 + i * 100))
		root.connect_node(&"weapon", i, StringName("aim_%s" % w))

	var upper := AnimationNodeBlend2.new()
	_apply_filter(upper)
	root.add_node(&"upper_blend", upper, Vector2(200, 100))
	root.connect_node(&"upper_blend", 0, LOCO)
	root.connect_node(&"upper_blend", 1, &"weapon")

	_action_anim = _anim(&"")
	root.add_node(&"action_anim", _action_anim, Vector2(200, 300))
	root.add_node(&"action_scale", AnimationNodeTimeScale.new(), Vector2(350, 300))
	root.connect_node(&"action_scale", 0, &"action_anim")
	var action := AnimationNodeOneShot.new()
	action.fadein_time = action_fade_in
	action.fadeout_time = action_fade_out
	_apply_filter(action)
	root.add_node(&"action_shot", action, Vector2(500, 100))
	root.connect_node(&"action_shot", 0, &"upper_blend")
	root.connect_node(&"action_shot", 1, &"action_scale")

	_fire_anim = _anim(&"")
	root.add_node(&"fire_anim", _fire_anim, Vector2(500, 300))
	var fire := AnimationNodeOneShot.new()
	fire.fadein_time = 0.0
	fire.fadeout_time = 0.05
	_apply_filter(fire)
	root.add_node(&"fire_shot", fire, Vector2(700, 100))
	root.connect_node(&"fire_shot", 0, &"action_shot")
	root.connect_node(&"fire_shot", 1, &"fire_anim")

	_death_anim = _anim(&"")
	root.add_node(&"death_anim", _death_anim, Vector2(700, 300))
	var life := AnimationNodeTransition.new()
	life.add_input("alive")
	life.add_input("dead")
	life.xfade_time = 0.1
	root.add_node(&"life", life, Vector2(900, 100))
	root.connect_node(&"life", 0, &"fire_shot")
	root.connect_node(&"life", 1, &"death_anim")
	root.connect_node(&"output", 0, &"life")

	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	tree.tree_root = root
	add_child(tree)
	tree.anim_player = tree.get_path_to(animation_player)
	tree.root_node = tree.get_path_to(animation_player.get_node(animation_player.root_node))
	tree.active = true
	# Without a filter the upper layer would replace the legs, so it stays off until paths exist.
	tree.set(&"parameters/upper_blend/blend_amount", 0.0 if upper_body_paths.is_empty() else 1.0)
	_playback = tree.get(&"parameters/Locomotion/playback")
	_playback.start(ST_GROUND)


func _build_locomotion() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	var ground := AnimationNodeBlendSpace2D.new()
	ground.min_space = Vector2(-run_speed, -run_speed)
	ground.max_space = Vector2(run_speed, run_speed)
	ground.add_blend_point(_anim(&"idle"), Vector2.ZERO)
	for s: Array in [[walk_speed, "walk"], [run_speed, "run"]]:
		var v: float = s[0]
		ground.add_blend_point(_anim(StringName("%s_f" % s[1])), Vector2(0, v))
		ground.add_blend_point(_anim(StringName("%s_b" % s[1])), Vector2(0, -v))
		ground.add_blend_point(_anim(StringName("%s_l" % s[1])), Vector2(-v, 0))
		ground.add_blend_point(_anim(StringName("%s_r" % s[1])), Vector2(v, 0))
	sm.add_node(ST_GROUND, ground, Vector2(0, 0))

	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.min_space = Vector2(-crouch_walk_speed, -crouch_walk_speed)
	crouch.max_space = Vector2(crouch_walk_speed, crouch_walk_speed)
	crouch.add_blend_point(_anim(&"crouch_idle"), Vector2.ZERO)
	crouch.add_blend_point(_anim(&"crouch_walk_f"), Vector2(0, crouch_walk_speed))
	crouch.add_blend_point(_anim(&"crouch_walk_b"), Vector2(0, -crouch_walk_speed))
	crouch.add_blend_point(_anim(&"crouch_walk_l"), Vector2(-crouch_walk_speed, 0))
	crouch.add_blend_point(_anim(&"crouch_walk_r"), Vector2(crouch_walk_speed, 0))
	sm.add_node(ST_CROUCH, crouch, Vector2(0, 150))

	sm.add_node(ST_JUMP, _anim(&"jump_start"), Vector2(250, -100))
	sm.add_node(ST_FALL, _anim(&"fall"), Vector2(450, -100))
	sm.add_node(ST_LAND, _anim(&"land"), Vector2(450, 100))
	sm.add_node(ST_SLIDE, _anim(&"slide"), Vector2(250, 250))

	var to_fall := AnimationNodeStateMachineTransition.new()
	to_fall.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	to_fall.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	to_fall.xfade_time = 0.05
	sm.add_transition(ST_JUMP, ST_FALL, to_fall)
	var to_ground := AnimationNodeStateMachineTransition.new()
	to_ground.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	to_ground.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	to_ground.xfade_time = 0.1
	sm.add_transition(ST_LAND, ST_GROUND, to_ground)
	return sm


func _apply_filter(node: AnimationNode) -> void:
	if upper_body_paths.is_empty():
		return
	node.filter_enabled = true
	for path: NodePath in upper_body_paths:
		node.set_filter_path(path, true)
