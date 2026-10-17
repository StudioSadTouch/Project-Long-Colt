class_name CharacterAnimDriver
extends Node
## Third-person animation driver for players, bots and dummies. Builds its own AnimationTree
## over an AnimationPlayer and drives it only from CharacterAnimState (never from input), so
## local, remote and AI bodies animate identically. See /workspace/anims/thirdperson_plan.md.
##
## Tree (parameters/<name>):
##   Locomotion (StateMachine: Ground and Crouch = BS2D -> TimeScale "rate" (playback follows
##     the synced velocity, see loco_rate), StopSettle, JumpStart -> Fall,
##     Land -> Ground, Slide, TurnL / TurnR (idle step in place after turn_threshold_deg of
##     standing yaw); stand/crouch/slide changes cross-fade loco_xfade)  full body
##   weapon (Transition none/rifle/pistol of aim_<w> BS1D down/down_half/mid/up_half/up)
##                                                                              upper only
##   -> action_shot (OneShot, reload/melee/switch/throw, scaled by action_scale)
##   -> crouch_add (Add2 + crouch_weapon Transition of crouch_upper_<w>, amount = crouch)
##   upper_blend (Blend2, filtered to upper_body_paths): Locomotion + crouch_add
##   -> fire_shot (OneShot ADD: CharacterAnimState.MODEL_FIRE clip, else fire_<class>)
##   -> flinch_shot (OneShot ADD)
##   -> pump_add (Add2: pump_weapon Transition of run_pump_<w> -> pump_rate -> pump_seek,
##      phase-locked to the locomotion cycle, amount from synced speed, see _update_pump)
##   -> life (Transition alive / dead: death_anim = death_<dir>, or death_crouch_<dir> when the
##      body was crouched or sliding) -> output
##
## Usage: apply_state(state) every physics tick (authority) or per snapshot (remote).
## reset_baseline() on spawn, respawn and late join so stale counters don't replay.
## Ragdoll hook: death_started(hit_dir, impulse) fires on every new death. Set canned_death
## false and the driver stops posing the body on death so a client-local ragdoll can take it.

signal death_started(hit_dir: int, impulse: Vector3)
## Ground / crouch foot plant. speed is horizontal m/s. A gait-clock reset does not emit.
signal foot_contact(speed: float, crouched: bool)
## Entered Land. impact is the larger of fall speed and horizontal speed, m/s.
signal foot_landed(impact: float)
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
const ST_TURN_L := &"TurnL"
const ST_TURN_R := &"TurnR"
## Indexed by CharacterAnimState.WeaponType; each needs aim_<w>_*, crouch_upper_<w>, run_pump_<w>.
const WEAPON_INPUTS := ["none", "rifle", "pistol", "sword", "hammer"]
const HIT_SUFFIX := ["front", "back", "left", "right"]
## Below this horizontal speed the idle pose owns the blend, so feet stay quiet.
const FOOT_MIN_SPEED := 1.0
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
## Cross-fade (s) for stand <-> crouch <-> slide changes in the locomotion state machine.
@export var loco_xfade: float = 0.13
## Run pump (upper-body additive): weight ramps from 0 at pump_start_speed to 1 at
## pump_full_speed (synced horizontal speed, m/s); off when crouched, sliding, airborne and
## while reload / melee / switch play. pump_cycle must match the generator's CYCLE.
@export var pump_start_speed: float = 3.5
@export var pump_full_speed: float = 7.5
@export var pump_cycle: float = 0.6
## Pump weight smoothing (1/s). 0 = snap.
@export var pump_smoothing: float = 10.0
## A shot caps the run pump weight at pump_fire_weight for pump_fire_hold seconds, so a runner
## who fires steadies the gun on the aim line (less shoulder sway and bob), applied at
## pump_raise_smoothing (1/s), faster than pump_smoothing.
@export var pump_fire_weight: float = 0.25
@export var pump_fire_hold: float = 0.6
@export var pump_raise_smoothing: float = 30.0
## Turn in place: standing yaw (degrees) the body may twist on still feet before it steps.
@export var turn_threshold_deg: float = 35.0
## Above this horizontal speed (m/s) there is no turn step; locomotion owns the feet.
@export var turn_max_speed: float = 0.4
## Steady upper body: the aim / action poses are authored on an upright pelvis, but the
## locomotion pelvis leans into the run (8 deg) and twists with each stride (9 deg), and the
## upper layer rides on it, so without this the weapon dipped 8 deg and swung while running.
## After each mix the first upper_body_paths joint (the abdomen) is counter-rotated by the
## pelvis's lean and twist, so the torso and weapon stay on the aim line while the legs drive.
## Standing locomotion only (ground, settle, turn steps); crouch, slide, air and death keep the
## authored lean. Weight eases in and out at steady_smoothing (1/s).
@export var steady_upper_body: bool = true
@export var steady_smoothing: float = 12.0
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
var _pump_weight: float = 0.0
var _pump_fire_left: float = 0.0
var _steady_weight: float = 0.0
var _pelvis: Node3D
var _abdomen: Node3D
## The abdomen basis this script last wrote: if the mixer did not write a new one since, the
## correction is not stacked on top of itself.
var _steady_written: Basis = Basis()
var _pump_phase: float = 0.0
var _phase_node: StringName = &""
## True after foot_landed until the body leaves the Land state, so a late current-node
## read cannot plant the same landing twice.
var _landing: bool = false
## Yaw turned on the spot since the feet last stepped, radians (+ = left).
var _turn_accum: float = 0.0
## "from>to" pairs of locomotion states joined by a cross-fade transition (travel, not start).
var _xfade_pairs: Dictionary = {}


func _ready() -> void:
	if animation_player == null:
		push_error("%s: needs an AnimationPlayer" % name)
		return
	_build_tree()


## Forget previous sequence counters: the next state sets the baseline without firing.
func reset_baseline() -> void:
	_have_baseline = false
	_landing = false


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
		_pump_weight = 0.0
		_pump_fire_left = 0.0
		_steady_weight = 0.0
		_turn_accum = 0.0
		_set_life(state, false)
		if not state.dead:
			_playback.start(ST_CROUCH if state.crouched else ST_GROUND)
			_restart_phase(ST_CROUCH if state.crouched else ST_GROUND)
		state_applied.emit(state)
		return
	var delta := get_physics_process_delta_time()
	_update_life(state)
	if not state.dead:
		_update_locomotion(state, delta)
		_update_upper(state, delta)
		_update_one_shots(state)
		_update_pump(state, delta)
	_update_steady(state, delta)
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
			_restart_phase(ST_GROUND)


func _set_life(state: CharacterAnimState, emit: bool) -> void:
	if state.dead:
		var idx := clampi(state.death_dir, 0, HIT_SUFFIX.size() - 1)
		# The body clears crouch/slide on the death tick itself, so ask the smoothed crouch
		# amount (previous ticks) whether it went down from low.
		var low := state.crouched or state.sliding or _crouch_amount > 0.5
		var clip := &""
		if low and animation_player.has_animation(StringName("death_crouch_%s" % HIT_SUFFIX[idx])):
			clip = StringName("death_crouch_%s" % HIT_SUFFIX[idx])
		else:
			clip = _clip(StringName("death_%s" % HIT_SUFFIX[idx]))
		_death_anim.animation = clip
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
	var turning := current == ST_TURN_L or current == ST_TURN_R
	var standing_still := (
		state.on_floor and not state.crouched and not state.sliding and speed < turn_max_speed
	)
	if standing_still and (current == ST_GROUND or turning):
		_turn_accum += wrapf(state.yaw - _last.yaw, -PI, PI)
	else:
		_turn_accum = 0.0
	var wanted := current
	var new_turn := false
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
	elif turning and standing_still and not _clip_finished():
		pass  # let the step land; it travels back to Ground when the clip ends
	elif (
		standing_still
		and absf(_turn_accum) >= deg_to_rad(turn_threshold_deg)
		and _clip(&"turn_l") != &""
	):
		wanted = ST_TURN_L if _turn_accum > 0.0 else ST_TURN_R
		new_turn = true
		_turn_accum = 0.0
	elif (
		current == ST_GROUND
		and _prev_speed >= settle_from_speed
		and speed < 0.3
		and _clip(&"stop_settle") != &""
	):
		wanted = ST_SETTLE
	else:
		wanted = ST_GROUND
	if wanted == ST_LAND:
		if not _landing:
			_landing = true
			var fall := maxf(-state.velocity.y, 0.0)
			var horiz := Vector2(state.velocity.x, state.velocity.z).length()
			foot_landed.emit(maxf(fall, horiz))
	else:
		_landing = false
	if turning and wanted == current and _clip_finished():
		if new_turn:
			_playback.start(wanted)  # still turning the same way: step again
		else:
			wanted = ST_GROUND
	if wanted != current:
		if _xfade_pairs.has("%s>%s" % [current, wanted]):
			_playback.travel(wanted)
		else:
			_playback.start(wanted)
	_prev_speed = speed


## True once a one-shot locomotion state (turn step) has played to its end.
func _clip_finished() -> bool:
	return _playback.get_current_play_position() >= _playback.get_current_length() - 0.001


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


## start() restarts a state at 0 even when it is already current: restart the pump clock too.
func _restart_phase(node: StringName) -> void:
	_phase_node = node
	_pump_phase = 0.0


## Run pump: phase follows the Ground state's own clock (it restarts at 0 whenever Ground is
## entered and advances at the locomotion rate, like the synced blendspace), so the additive's
## footfalls stay on the legs' footfalls. Weight from the synced velocity only.
## Plants are at t = 0 and t = half cycle (generator: left foot at 0, right at CYCLE/2).
func _update_pump(state: CharacterAnimState, delta: float) -> void:
	var current := _playback.get_current_node()
	var previous := _pump_phase
	var advanced := false
	if current != _phase_node:
		# start() snaps this clock to 0. That is not a foot crossing.
		_phase_node = current
		_pump_phase = 0.0
	elif pump_cycle > 0.0:
		_pump_phase = fposmod(_pump_phase + delta * _loco_rate, pump_cycle)
		advanced = true
	if advanced and foot_crossed(previous, _pump_phase, pump_cycle):
		_emit_foot(state, current)
	var speed := Vector2(state.velocity.x, state.velocity.z).length()
	var target := smoothstep(pump_start_speed, pump_full_speed, speed)
	if current != ST_GROUND or not state.on_floor or state.crouched or state.sliding:
		target = 0.0
	if bool(tree.get(&"parameters/action_shot/active")):
		target = 0.0
	var rate := pump_smoothing
	if _pump_fire_left > 0.0:
		_pump_fire_left -= delta
		if target > pump_fire_weight:
			target = pump_fire_weight
			rate = pump_raise_smoothing
	if pump_smoothing > 0.0:
		_pump_weight = lerpf(_pump_weight, target, 1.0 - exp(-rate * delta))
	else:
		_pump_weight = target
	var idx := clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)
	tree.set(&"parameters/pump_weapon/transition_request", WEAPON_INPUTS[idx])
	tree.set(&"parameters/pump_rate/scale", _loco_rate)
	tree.set(&"parameters/pump_seek/seek_request", _pump_phase)
	tree.set(&"parameters/pump_add/add_amount", _pump_weight)


func _update_steady(state: CharacterAnimState, delta: float) -> void:
	var current := _playback.get_current_node()
	var standing := (
		current == ST_GROUND or current == ST_SETTLE or current == ST_TURN_L or current == ST_TURN_R
	)
	var on := (
		steady_upper_body and standing and not state.dead and not state.crouched
		and not state.sliding and state.on_floor
	)
	var target := 1.0 if on else 0.0
	if steady_smoothing > 0.0:
		_steady_weight = lerpf(_steady_weight, target, 1.0 - exp(-steady_smoothing * delta))
	else:
		_steady_weight = target


## After the mix: abdomen = pelvis^-1 * abdomen (weighted), so pelvis * abdomen is what the
## upper-body clips were authored on (an upright pelvis, identity rotation).
func _apply_steady() -> void:
	if _abdomen == null or _pelvis == null or _steady_weight <= 0.001:
		return
	var current := _abdomen.basis
	if current.is_equal_approx(_steady_written):
		return  # the mixer didn't write the abdomen this frame: already corrected
	var undo := _pelvis.basis.get_rotation_quaternion().inverse()
	var fix := Quaternion.IDENTITY.slerp(undo, clampf(_steady_weight, 0.0, 1.0))
	_abdomen.basis = Basis(fix) * current
	_steady_written = _abdomen.basis


## True when playback from previous to now crosses a plant (cycle start, or half cycle).
## now < previous is a wrap. Do not call this for a phase reset.
static func foot_crossed(previous: float, now: float, cycle: float) -> bool:
	if cycle <= 0.0 or now == previous:
		return false
	if now < previous:
		return true
	var half := cycle * 0.5
	return previous < half and now >= half


func _emit_foot(state: CharacterAnimState, current: StringName) -> void:
	if state.dead or state.sliding or not state.on_floor:
		return
	if current != ST_GROUND and current != ST_CROUCH:
		return
	var speed := Vector2(state.velocity.x, state.velocity.z).length()
	if speed < FOOT_MIN_SPEED:
		return
	foot_contact.emit(speed, state.crouched)


func _update_one_shots(state: CharacterAnimState) -> void:
	if state.action_seq != _last.action_seq and state.action != CharacterAnimState.Action.NONE:
		_play_action(state)
	elif state.action_cancel_seq != _last.action_cancel_seq:
		tree.set(&"parameters/action_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
	if state.fire_seq != _last.fire_seq:
		_pump_fire_left = pump_fire_hold
		var weapon: String = WEAPON_INPUTS[clampi(state.weapon_type, 0, WEAPON_INPUTS.size() - 1)]
		var fire := &""
		var by_model: StringName = CharacterAnimState.MODEL_FIRE.get(state.weapon_model, &"")
		if by_model != &"" and animation_player.has_animation(by_model):
			fire = by_model
		elif weapon != "none":
			fire = _clip(StringName("fire_%s" % weapon))
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
			# Alternate swings (the longsword's forehand / backhand) by the synced action
			# counter, so every peer picks the same one.
			var alt := "%s_b" % base
			if state.action_seq % 2 == 1 and animation_player.has_animation(StringName(alt)):
				base = alt
		CharacterAnimState.Action.SWITCH:
			base = "switch_%s" % weapon
		CharacterAnimState.Action.THROW:
			base = "throw_%s" % weapon
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


## Blend point named after its clip (Godot 4.7 warns about unnamed points).
func _add_point(space: AnimationRootNode, clip: StringName, pos: Variant) -> void:
	space.call(&"add_blend_point", _anim(clip), pos, -1, clip)


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
		_add_point(aim, StringName("aim_%s_down" % w), -1.0)
		_add_point(aim, StringName("aim_%s_down_half" % w), -0.5)
		_add_point(aim, StringName("aim_%s_mid" % w), 0.0)
		_add_point(aim, StringName("aim_%s_up_half" % w), 0.5)
		_add_point(aim, StringName("aim_%s_up" % w), 1.0)
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

	# Run pump additive, phase-locked to locomotion (seeked every tick, rated in between).
	var pump_weapon := AnimationNodeTransition.new()
	pump_weapon.xfade_time = 0.15
	for i in WEAPON_INPUTS.size():
		var w: String = WEAPON_INPUTS[i]
		pump_weapon.add_input(w)
		var pump_clip := StringName("run_pump_%s" % w)
		root.add_node(pump_clip, _anim(pump_clip), Vector2(700, 500 + i * 100))
	root.add_node(&"pump_weapon", pump_weapon, Vector2(900, 500))
	for i in WEAPON_INPUTS.size():
		root.connect_node(&"pump_weapon", i, StringName("run_pump_%s" % WEAPON_INPUTS[i]))
	root.add_node(&"pump_rate", AnimationNodeTimeScale.new(), Vector2(1050, 500))
	root.connect_node(&"pump_rate", 0, &"pump_weapon")
	root.add_node(&"pump_seek", AnimationNodeTimeSeek.new(), Vector2(1200, 500))
	root.connect_node(&"pump_seek", 0, &"pump_rate")
	var pump_add := AnimationNodeAdd2.new()
	_apply_filter(pump_add)
	root.add_node(&"pump_add", pump_add, Vector2(1100, 100))
	root.connect_node(&"pump_add", 0, &"flinch_shot")
	root.connect_node(&"pump_add", 1, &"pump_seek")

	_death_anim = _anim(&"")
	root.add_node(&"death_anim", _death_anim, Vector2(900, 300))
	var life := AnimationNodeTransition.new()
	life.add_input("alive")
	life.add_input("dead")
	life.xfade_time = 0.08
	root.add_node(&"life", life, Vector2(1300, 100))
	root.connect_node(&"life", 0, &"pump_add")
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
	tree.set(&"parameters/pump_add/add_amount", 0.0)
	_playback = tree.get(&"parameters/Locomotion/playback")
	_playback.start(ST_GROUND)
	if not upper_body_paths.is_empty():
		var anim_root := animation_player.get_node(animation_player.root_node)
		_abdomen = anim_root.get_node_or_null(upper_body_paths[0]) as Node3D
		_pelvis = _abdomen.get_parent() as Node3D if _abdomen != null else null
	tree.mixer_applied.connect(_apply_steady)


func _build_locomotion() -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	var ground := AnimationNodeBlendSpace2D.new()
	ground.min_space = Vector2(-run_speed, -run_speed)
	ground.max_space = Vector2(run_speed, run_speed)
	ground.sync = true
	_add_point(ground, &"idle", Vector2.ZERO)
	for d: String in DIRS:
		_add_point(ground, StringName("walk_%s" % d), DIRS[d] * walk_speed)
		_add_point(ground, StringName("run_%s" % d), DIRS[d] * run_speed)
	sm.add_node(ST_GROUND, _rated(ground), Vector2(0, 0))

	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.min_space = Vector2(-crouch_walk_speed, -crouch_walk_speed)
	crouch.max_space = Vector2(crouch_walk_speed, crouch_walk_speed)
	crouch.sync = true
	_add_point(crouch, &"crouch_idle", Vector2.ZERO)
	for d: String in DIRS:
		_add_point(crouch, StringName("crouch_walk_%s" % d), DIRS[d] * crouch_walk_speed)
	sm.add_node(ST_CROUCH, _rated(crouch), Vector2(0, 150))

	sm.add_node(ST_SETTLE, _anim(&"stop_settle"), Vector2(-250, 0))
	sm.add_node(ST_JUMP, _anim(&"jump_start"), Vector2(250, -100))
	sm.add_node(ST_FALL, _anim(&"fall"), Vector2(450, -100))
	sm.add_node(ST_LAND, _anim(&"land"), Vector2(450, 100))
	sm.add_node(ST_SLIDE, _anim(&"slide"), Vector2(250, 250))
	sm.add_node(ST_TURN_L, _anim(&"turn_l"), Vector2(-250, -150))
	sm.add_node(ST_TURN_R, _anim(&"turn_r"), Vector2(-100, -150))

	sm.add_transition(ST_JUMP, ST_FALL, _auto_at_end(0.05))
	sm.add_transition(ST_LAND, ST_GROUND, _auto_at_end(0.1))
	sm.add_transition(ST_SETTLE, ST_GROUND, _auto_at_end(0.1))
	# Stand / crouch / slide: short cross-fades instead of instant switches, so the pelvis
	# height drop (crouch hitbox and eye height already move smoothly) doesn't pop.
	_xfade_pairs.clear()
	var pairs := [
		[ST_GROUND, ST_SLIDE],
		[ST_SLIDE, ST_GROUND],
		[ST_CROUCH, ST_SLIDE],
		[ST_SLIDE, ST_CROUCH],
		[ST_GROUND, ST_CROUCH],
		[ST_CROUCH, ST_GROUND],
		[ST_LAND, ST_CROUCH],
		[ST_SETTLE, ST_CROUCH],
		[ST_LAND, ST_SLIDE],
		[ST_SETTLE, ST_SLIDE],
		# Turn steps: in from Ground, out to Ground at the clip end (or on moving off),
		# and out to crouch / slide at any time.
		[ST_GROUND, ST_TURN_L],
		[ST_GROUND, ST_TURN_R],
		[ST_TURN_L, ST_GROUND],
		[ST_TURN_R, ST_GROUND],
		[ST_TURN_L, ST_CROUCH],
		[ST_TURN_R, ST_CROUCH],
		[ST_TURN_L, ST_SLIDE],
		[ST_TURN_R, ST_SLIDE],
	]
	for pair: Array in pairs:
		sm.add_transition(pair[0], pair[1], _xfade(loco_xfade))
		_xfade_pairs["%s>%s" % [pair[0], pair[1]]] = true
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


## Immediate cross-fade, taken only when the driver travels to it.
func _xfade(xfade: float) -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED
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
