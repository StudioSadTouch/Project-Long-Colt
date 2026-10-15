class_name CharacterAnimDriver
extends Node
## Third-person animation driver for players, bots and dummies. Builds its own AnimationTree
## over an AnimationPlayer and drives it only from CharacterAnimState (never from input), so
## local, remote and AI bodies animate identically. See /workspace/anims/thirdperson_plan.md.
##
## Tree (parameters/<name>):
##   Locomotion (StateMachine: Ground and Crouch = BS2D -> TimeScale "rate" (playback follows
##     the synced velocity, see loco_rate), StopSettle, JumpStart -> Fall,
##     Land -> Ground, Slide)                                                  full body
##   weapon (Transition none/rifle/pistol of aim_<w> BS1D down/mid/up)          upper only
##   -> action_shot (OneShot, reload/melee/switch, scaled by action_scale)
##   -> crouch_add (Add2 + crouch_weapon Transition of crouch_upper_<w>, amount = crouch)
##   upper_blend (Blend2, filtered to upper_body_paths): Locomotion + crouch_add
##   -> fire_shot (OneShot ADD) -> flinch_shot (OneShot ADD)
##   -> life (Transition alive / dead: death_anim) -> output
##
## Usage: apply_state(state) every physics tick (authority) or per snapshot (remote).
## reset_baseline() on spawn, respawn and late join so stale counters don't replay.
## Ragdoll hook: death_started(hit_dir, impulse) fires on every new death. Set canned_death
## false and the driver stops posing the body on death so a client-local ragdoll can take it.

signal death_started(hit_dir: int, impulse: Vector3)
## After every apply_state (props and other listeners follow the same synced state).
signal state_applied(state: CharacterAnimState)

const LOCO := &"Locomotion"
const ST_GROUND := &"Ground"
const ST_CROUCH := &"Crouch"
const ST_SETTLE := &"StopSettle"
const ST_JUMP := &"JumpStart"
const ST_FALL := &"Fall"
const ST_LAND := &"Land"
const ST_SLIDE := &"Slide"
const WEAPON_INPUTS := ["none", "rifle", "pistol"]
const HIT_SUFFIX := ["front", "back", "left", "right"]
## Eight directions, clockwise from forward; blend position is (right, forward).
const DIRS := {
	"f": Vector2(0, 1),
	"fr": Vector2(0.70710678, 0.70710678),
	"r": Vector2(1, 0),
	"br": Vector2(0.70710678, -0.70710678),
	"b": Vector2(0, -1),
	"bl": Vector2(-0.70710678, -0.70710678),
	"l": Vector2(-1, 0),
	"fl": Vector2(-0.70710678, 0.70710678),
}

@export var animation_player: AnimationPlayer
## Node paths (relative to the AnimationPlayer's root node) that take the upper-body layer.
@export var upper_body_paths: Array[NodePath] = []
## Method-track paths (relative to the AnimationPlayer root) that must pass the upper-body
## filters, e.g. the switch clips' swap call on CharacterWeaponProps.
@export var event_track_paths: Array[NodePath] = [^"CharacterWeaponProps"]
## Authored speeds of the walk / run / crouch-walk clips, m/s.
@export var walk_speed: float = 3.5
@export var run_speed: float = 7.5
@export var crouch_walk_speed: float = 3.2
## Sideways stride cut the walk/run/crouch clips were authored with (generator
## LATERAL_STRIDE_CUT): a pure strafe covers (1 - cut) of the forward stride per cycle.
@export var lateral_stride_cut: float = 0.45
## Locomotion playback rate = actual speed / blended clip speed, clamped to this range
## (covers velocity above/below the authored speeds and blend-position smoothing lag) ...
@export var loco_rate_min: float = 0.6
@export var loco_rate_max: float = 1.4
## ... times the strafe stride compensation 1 / (1 - cut * |sideways|) (up to 1.82 for a pure
## strafe), with the product capped here.
@export var loco_rate_cap: float = 1.9
## Below this speed (m/s) the idle pose dominates and the rate eases back to 1.
@export var loco_rate_min_speed: float = 0.5
## Rate smoothing (1/s). 0 = snap.
@export var loco_rate_smoothing: float = 10.0
## Pitch that maps to the aim_*_up / aim_*_down poses, degrees.
@export var aim_pitch_limit_deg: float = 70.0
## Blend-position smoothing rate (1/s). 0 = snap.
@export var blend_smoothing: float = 12.0
## Crouch additive fade rate (1/s).
@export var crouch_smoothing: float = 14.0
## Horizontal speed (m/s) above which coming to a stop plays stop_settle.
@export var settle_from_speed: float = 2.0
@export var action_fade_in: float = 0.08
@export var action_fade_out: float = 0.12
## False: on death only death_started is emitted and the tree is frozen (ragdoll mode).
@export var canned_death: bool = true

var tree: AnimationTree

var _playback: AnimationNodeStateMachinePlayback
var _action_anim: AnimationNodeAnimation
var _fire_anim: AnimationNodeAnimation
var _flinch_anim: AnimationNodeAnimation
var _death_anim: AnimationNodeAnimation
var _warned: Dictionary = {}
var _have_baseline: bool = false
var _last: CharacterAnimState
var _move_blend: Vector2 = Vector2.ZERO
var _crouch_amount: float = 0.0
var _was_on_floor: bool = true
var _prev_speed: float = 0.0
var _loco_rate: float = 1.0


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
		_crouch_amount = 1.0 if state.crouched or state.sliding else 0.0
		_move_blend = Vector2.ZERO
		_loco_rate = 1.0
		_set_life(state, false)
		if not state.dead:
			_playback.start(ST_CROUCH if state.crouched else ST_GROUND)
		state_applied.emit(state)
		return
	var delta := get_physics_process_delta_time()
	_update_life(state)
	if not state.dead:
		_update_locomotion(state, delta)
		_update_upper(state, delta)
		_update_one_shots(state)
	_was_on_floor = state.on_floor
	_last = CharacterAnimState.from_dict(state.to_dict())
	state_applied.emit(state)


func _update_life(state: CharacterAnimState) -> void:
	var new_death := state.dead and (state.death_seq != _last.death_seq or not _last.dead)
	if new_death or state.dead != _last.dead:
		_set_life(state, new_death)
		if not state.dead:
			tree.active = true
			_playback.start(ST_GROUND)


func _set_life(state: CharacterAnimState, emit: bool) -> void:
	if state.dead:
		var idx := clampi(state.death_dir, 0, HIT_SUFFIX.size() - 1)
		_death_anim.animation = _clip(StringName("death_%s" % HIT_SUFFIX[idx]))
		for shot: String in ["action_shot", "fire_shot", "flinch_shot"]:
			tree.set("parameters/%s/request" % shot, AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
		if emit:
			death_started.emit(state.death_dir, state.death_impulse)
		if not canned_death:
			tree.active = false
			return
	tree.set(&"parameters/life/transition_request", "dead" if state.dead else "alive")


func _update_locomotion(state: CharacterAnimState, delta: float) -> void:
	var local := Basis(Vector3.UP, state.yaw).inverse() * state.velocity
	var target := Vector2(local.x, -local.z)
	if blend_smoothing > 0.0:
		_move_blend = _move_blend.lerp(target, 1.0 - exp(-blend_smoothing * delta))
	else:
		_move_blend = target
	tree.set(&"parameters/Locomotion/Ground/bs/blend_position", _move_blend)
	tree.set(&"parameters/Locomotion/Crouch/bs/blend_position", _move_blend)
	var speed := target.length()
	var top := crouch_walk_speed if state.crouched else run_speed
	var rate := loco_rate(speed, _move_blend, top)
	if loco_rate_smoothing > 0.0:
		_loco_rate = lerpf(_loco_rate, rate, 1.0 - exp(-loco_rate_smoothing * delta))
	else:
		_loco_rate = rate
	tree.set(&"parameters/Locomotion/Ground/rate/scale", _loco_rate)
	tree.set(&"parameters/Locomotion/Crouch/rate/scale", _loco_rate)
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
	elif current == ST_LAND or current == ST_SETTLE:
		# Land / StopSettle auto-advance to Ground; leave early only for crouch or moving off.
		if state.crouched:
			wanted = ST_CROUCH
		elif current == ST_SETTLE and speed > 0.5:
			wanted = ST_GROUND
	elif state.crouched:
		wanted = ST_CROUCH
	elif (
		current == ST_GROUND
		and _prev_speed >= settle_from_speed
		and speed < 0.3
		and _clip(&"stop_settle") != &""
	):
		wanted = ST_SETTLE
	else:
		wanted = ST_GROUND
	if wanted != current:
		_playback.start(wanted)
	_prev_speed = speed


## Playback rate that makes the blended locomotion clips' feet move at `speed` (m/s, actual
## horizontal velocity) for blend position `blend` (m/s, right/forward). `top`: outermost
## authored speed of the active blendspace.
func loco_rate(speed: float, blend: Vector2, top: float) -> float:
	var mag := blend.length()
	if mag < 0.001:
		return 1.0
	var lateral := absf(blend.x) / mag
	var strafe := 1.0 / maxf(1.0 - lateral_stride_cut * lateral, 0.1)
	var ratio := clampf(speed / minf(mag, top), loco_rate_min, loco_rate_max)
	var rate := minf(ratio * strafe, loco_rate_cap)
	# Ease to 1 near standstill, where the blend is mostly idle.
	var w := clampf(speed / maxf(loco_rate_min_speed, 0.001), 0.0, 1.0)
	return lerpf(1.0, rate, w)


func _update_upper(state: CharacterAnimState, delta: float) -> void:
	var idx := clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)
	tree.set(&"parameters/weapon/transition_request", WEAPON_INPUTS[idx])
	tree.set(&"parameters/crouch_weapon/transition_request", WEAPON_INPUTS[idx])
	var pitch := clampf(state.aim_pitch / deg_to_rad(aim_pitch_limit_deg), -1.0, 1.0)
	for w: String in WEAPON_INPUTS:
		tree.set("parameters/aim_%s/blend_position" % w, pitch)
	var crouch_target := 1.0 if state.crouched or state.sliding else 0.0
	if crouch_smoothing > 0.0:
		_crouch_amount = lerpf(_crouch_amount, crouch_target, 1.0 - exp(-crouch_smoothing * delta))
	else:
		_crouch_amount = crouch_target
	tree.set(&"parameters/crouch_add/add_amount", _crouch_amount)


func _update_one_shots(state: CharacterAnimState) -> void:
	if state.action_seq != _last.action_seq and state.action != CharacterAnimState.Action.NONE:
		_play_action(state)
	elif state.action_cancel_seq != _last.action_cancel_seq:
		tree.set(&"parameters/action_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	if state.fire_seq != _last.fire_seq:
		var weapon: String = WEAPON_INPUTS[clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)]
		var fire := _clip(StringName("fire_%s" % weapon)) if weapon != "none" else &""
		if fire != &"":
			_fire_anim.animation = fire
			tree.set(&"parameters/fire_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	if state.flinch_seq != _last.flinch_seq:
		var idx := clampi(state.flinch_dir, 0, HIT_SUFFIX.size() - 1)
		var flinch := _clip(StringName("flinch_%s" % HIT_SUFFIX[idx]))
		if flinch != &"":
			_flinch_anim.animation = flinch
			tree.set(&"parameters/flinch_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func _play_action(state: CharacterAnimState) -> void:
	var weapon: String = WEAPON_INPUTS[clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)]
	if weapon == "none":
		return
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


func _one_shot(fade_in: float, fade_out: float, additive: bool) -> AnimationNodeOneShot:
	var shot := AnimationNodeOneShot.new()
	shot.fadein_time = fade_in
	shot.fadeout_time = fade_out
	if additive:
		shot.mix_mode = AnimationNodeOneShot.MIX_MODE_ADD
	_apply_filter(shot)
	return shot


func _build_tree() -> void:
	var root := AnimationNodeBlendTree.new()
	root.add_node(LOCO, _build_locomotion(), Vector2(0, 0))

	# Standing aim per weapon class, then crouch additive on top.
	var weapon := AnimationNodeTransition.new()
	weapon.xfade_time = 0.15
	var crouch_weapon := AnimationNodeTransition.new()
	crouch_weapon.xfade_time = 0.15
	for w: String in WEAPON_INPUTS:
		weapon.add_input(w)
		crouch_weapon.add_input(w)
	root.add_node(&"weapon", weapon, Vector2(-100, 200))
	root.add_node(&"crouch_weapon", crouch_weapon, Vector2(100, 450))
	for i in WEAPON_INPUTS.size():
		var w: String = WEAPON_INPUTS[i]
		var aim := AnimationNodeBlendSpace1D.new()
		aim.min_space = -1.0
		aim.max_space = 1.0
		aim.add_blend_point(_anim(StringName("aim_%s_down" % w)), -1.0)
		aim.add_blend_point(_anim(StringName("aim_%s_mid" % w)), 0.0)
		aim.add_blend_point(_anim(StringName("aim_%s_up" % w)), 1.0)
		root.add_node(StringName("aim_%s" % w), aim, Vector2(-300, 200 + i * 100))
		root.connect_node(&"weapon", i, StringName("aim_%s" % w))
		var crouch_clip := StringName("crouch_upper_%s" % w)
		root.add_node(crouch_clip, _anim(crouch_clip), Vector2(-100, 450 + i * 100))
		root.connect_node(&"crouch_weapon", i, crouch_clip)

	_action_anim = _anim(&"")
	root.add_node(&"action_anim", _action_anim, Vector2(-100, 350))
	root.add_node(&"action_scale", AnimationNodeTimeScale.new(), Vector2(50, 350))
	root.connect_node(&"action_scale", 0, &"action_anim")
	root.add_node(
		&"action_shot", _one_shot(action_fade_in, action_fade_out, false), Vector2(100, 200)
	)
	root.connect_node(&"action_shot", 0, &"weapon")
	root.connect_node(&"action_shot", 1, &"action_scale")

	var crouch_add := AnimationNodeAdd2.new()
	_apply_filter(crouch_add)
	root.add_node(&"crouch_add", crouch_add, Vector2(300, 200))
	root.connect_node(&"crouch_add", 0, &"action_shot")
	root.connect_node(&"crouch_add", 1, &"crouch_weapon")

	var upper := AnimationNodeBlend2.new()
	_apply_filter(upper)
	root.add_node(&"upper_blend", upper, Vector2(500, 100))
	root.connect_node(&"upper_blend", 0, LOCO)
	root.connect_node(&"upper_blend", 1, &"crouch_add")

	_fire_anim = _anim(&"")
	root.add_node(&"fire_anim", _fire_anim, Vector2(500, 300))
	root.add_node(&"fire_shot", _one_shot(0.0, 0.04, true), Vector2(700, 100))
	root.connect_node(&"fire_shot", 0, &"upper_blend")
	root.connect_node(&"fire_shot", 1, &"fire_anim")

	_flinch_anim = _anim(&"")
	root.add_node(&"flinch_anim", _flinch_anim, Vector2(700, 300))
	root.add_node(&"flinch_shot", _one_shot(0.02, 0.05, true), Vector2(900, 100))
	root.connect_node(&"flinch_shot", 0, &"fire_shot")
	root.connect_node(&"flinch_shot", 1, &"flinch_anim")

	_death_anim = _anim(&"")
	root.add_node(&"death_anim", _death_anim, Vector2(900, 300))
	var life := AnimationNodeTransition.new()
	life.add_input("alive")
	life.add_input("dead")
	life.xfade_time = 0.08
	root.add_node(&"life", life, Vector2(1100, 100))
	root.connect_node(&"life", 0, &"flinch_shot")
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
	tree.set(&"parameters/crouch_add/add_amount", 0.0)
	_playback = tree.get(&"parameters/Locomotion/playback")
	_playback.start(ST_GROUND)


func _build_locomotion() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	var ground := AnimationNodeBlendSpace2D.new()
	ground.min_space = Vector2(-run_speed, -run_speed)
	ground.max_space = Vector2(run_speed, run_speed)
	ground.sync = true
	ground.add_blend_point(_anim(&"idle"), Vector2.ZERO)
	for d: String in DIRS:
		ground.add_blend_point(_anim(StringName("walk_%s" % d)), DIRS[d] * walk_speed)
		ground.add_blend_point(_anim(StringName("run_%s" % d)), DIRS[d] * run_speed)
	sm.add_node(ST_GROUND, _rated(ground), Vector2(0, 0))

	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.min_space = Vector2(-crouch_walk_speed, -crouch_walk_speed)
	crouch.max_space = Vector2(crouch_walk_speed, crouch_walk_speed)
	crouch.sync = true
	crouch.add_blend_point(_anim(&"crouch_idle"), Vector2.ZERO)
	for d: String in DIRS:
		crouch.add_blend_point(_anim(StringName("crouch_walk_%s" % d)), DIRS[d] * crouch_walk_speed)
	sm.add_node(ST_CROUCH, _rated(crouch), Vector2(0, 150))

	sm.add_node(ST_SETTLE, _anim(&"stop_settle"), Vector2(-250, 0))
	sm.add_node(ST_JUMP, _anim(&"jump_start"), Vector2(250, -100))
	sm.add_node(ST_FALL, _anim(&"fall"), Vector2(450, -100))
	sm.add_node(ST_LAND, _anim(&"land"), Vector2(450, 100))
	sm.add_node(ST_SLIDE, _anim(&"slide"), Vector2(250, 250))

	sm.add_transition(ST_JUMP, ST_FALL, _auto_at_end(0.05))
	sm.add_transition(ST_LAND, ST_GROUND, _auto_at_end(0.1))
	sm.add_transition(ST_SETTLE, ST_GROUND, _auto_at_end(0.1))
	return sm


## Wraps a blendspace as bs -> rate (TimeScale) so locomotion speed can follow velocity.
func _rated(space: AnimationRootNode) -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	bt.add_node(&"bs", space, Vector2(0, 0))
	bt.add_node(&"rate", AnimationNodeTimeScale.new(), Vector2(200, 0))
	bt.connect_node(&"rate", 0, &"bs")
	bt.connect_node(&"output", 0, &"rate")
	return bt


func _auto_at_end(xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	t.xfade_time = xfade
	return t


func _apply_filter(node: AnimationNode) -> void:
	if upper_body_paths.is_empty():
		return
	node.filter_enabled = true
	for path: NodePath in upper_body_paths:
		node.set_filter_path(path, true)
	for path: NodePath in event_track_paths:
		node.set_filter_path(path, true)
