class_name StepUp
extends RefCounted
## Shared auto step-up / step-down for CharacterBody3Ds (Player and Bot). Static only.
## Call StepUp.move_and_slide(body, step_height, was_on_floor, jumping) instead of
## body.move_and_slide(). Returns the vertical step taken this tick (> 0 up, < 0 down, 0 none),
## so a camera can smooth it (Player does; hitboxes are never smoothed).
##
## Step-up, when grounded (was_on_floor) and not jumping, if the horizontal motion this tick is
## blocked by a wall-ish surface (normal steeper than floor_max_angle): sweep the body's own
## shapes up by step_height, forward by the horizontal motion, then down by the climbed height
## plus STEP_DOWN_MARGIN. Accepted only when the down sweep lands on a surface within
## floor_max_angle and the ledge is higher than MIN_STEP. The capsule is swept through every leg,
## so the landing is clear by construction. On accept the body is placed on the ledge and a
## zero-horizontal move_and_slide settles floor state (floor snap); velocity is kept.
## Step-down: walking off a drop of up to step_height while grounded and not moving up re-lands
## on the lower floor (test_move + apply_floor_snap) instead of going airborne.
## Deterministic: physics queries only, no randomness or timers, so the same state and input
## give the same result on any peer in the same physics tick.

## Extra distance for the down sweep, so a ledge exactly step_height tall still lands.
const STEP_DOWN_MARGIN := 0.05
## Ledges lower than this are left to move_and_slide / floor snap.
const MIN_STEP := 0.02
## Forward leg on the raised capsule must travel at least this fraction of the motion.
const MIN_FORWARD_FRACTION := 0.25
const SAFE_MARGIN := 0.001


static func move_and_slide(
	body: CharacterBody3D, step_height: float, was_on_floor: bool, jumping: bool
) -> float:
	var delta := body.get_physics_process_delta_time()
	var horizontal := Vector3(body.velocity.x, 0.0, body.velocity.z) * delta
	var may_step := (
		step_height > 0.0
		and was_on_floor
		and not jumping
		and horizontal.length_squared() > 0.000001
	)
	if may_step:
		var climbed := _try_step_up(body, horizontal, step_height)
		if climbed > 0.0:
			return climbed
	body.move_and_slide()
	if step_height > 0.0 and was_on_floor and not jumping and body.velocity.y <= 0.0:
		return _try_step_down(body, step_height)
	return 0.0


static func _try_step_up(body: CharacterBody3D, horizontal: Vector3, step_height: float) -> float:
	var start := body.global_transform
	var hit := KinematicCollision3D.new()
	if not body.test_move(start, horizontal, hit, SAFE_MARGIN):
		return 0.0
	if _is_floor(body, hit.get_normal()):
		return 0.0
	# Up.
	var up := Vector3.UP * step_height
	var up_hit := KinematicCollision3D.new()
	if body.test_move(start, up, up_hit, SAFE_MARGIN):
		up = up_hit.get_travel()
	if up.y < MIN_STEP:
		return 0.0
	var raised := start.translated(up)
	# Forward.
	var forward := horizontal
	var forward_hit := KinematicCollision3D.new()
	if body.test_move(raised, horizontal, forward_hit, SAFE_MARGIN):
		forward = forward_hit.get_travel()
		if forward.length() < horizontal.length() * MIN_FORWARD_FRACTION:
			return 0.0
	var ahead := raised.translated(forward)
	# Down onto the ledge.
	var down_hit := KinematicCollision3D.new()
	if not body.test_move(ahead, Vector3.DOWN * (up.y + STEP_DOWN_MARGIN), down_hit, SAFE_MARGIN):
		return 0.0
	if not _is_floor(body, down_hit.get_normal()):
		return 0.0
	var landing := ahead.translated(down_hit.get_travel())
	var climbed := landing.origin.y - start.origin.y
	if climbed < MIN_STEP:
		return 0.0
	body.global_transform = landing
	# Horizontal motion for this tick is spent; settle floor state without moving again.
	var keep := body.velocity
	body.velocity = Vector3.ZERO
	body.move_and_slide()
	body.velocity = Vector3(keep.x, maxf(keep.y, 0.0), keep.z)
	return climbed


static func _try_step_down(body: CharacterBody3D, step_height: float) -> float:
	if body.is_on_floor():
		return 0.0
	var hit := KinematicCollision3D.new()
	var reach := Vector3.DOWN * (step_height + STEP_DOWN_MARGIN)
	if not body.test_move(body.global_transform, reach, hit, SAFE_MARGIN):
		return 0.0
	if not _is_floor(body, hit.get_normal()):
		return 0.0
	var drop := hit.get_travel()
	body.global_position += drop
	body.apply_floor_snap()
	body.velocity.y = 0.0
	return drop.y


static func _is_floor(body: CharacterBody3D, normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) <= body.floor_max_angle + 0.01
