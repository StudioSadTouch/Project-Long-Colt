class_name StepUp
extends RefCounted
## Shared auto step-up / step-down for CharacterBody3Ds (Player and Bot). Static only.
## Call StepUp.move_and_slide(body, step_height, was_on_floor, jumping) instead of
## body.move_and_slide(). Returns the vertical step taken this tick (> 0 up, < 0 down, 0 none),
## so a camera can smooth it (Player does; hitboxes are never smoothed).
##
## Step-up runs when the body is supported (on the floor, or just barely off it and not rising)
## and this tick's horizontal motion is blocked by something that is not a floor. The capsule is
## lifted by step_height plus a small clearance, then walked forward until a down-sweep lands on
## a floor. A ledge corner reports the sphere's contact normal, which is steeper than
## floor_max_angle even when the top is walkable, so one down-sweep at the blocking point is not
## enough. The probe continues, up to about a capsule radius, until the down-sweep hits a real
## floor. Landings taller than step_height are rejected, and a low ceiling shortens the lift, so
## the body cannot step into headroom it does not have. A same-height landing is kept only when
## it has cleared the block (a seam, or a lip shorter than MIN_STEP).
## Step-down: walking off a drop of up to step_height while grounded and not moving up re-lands
## on the lower floor instead of going airborne.
## A thin bar that only clips the top of the head (a rail across a ramp) is ignored for that
## one move, including while walking up the ramp. A beam at chest height, a long soffit,
## and a low ceiling still block.
## Deterministic: physics queries only, no randomness or timers, so the same state and input
## give the same result on any peer in the same physics tick.

## Extra distance for the down sweep, so a ledge exactly at the lifted height still lands.
const STEP_DOWN_MARGIN := 0.05
## Ledges lower than this are seams, not stairs. A seam is still crossed when it was blocking.
const MIN_STEP := 0.02
const SAFE_MARGIN := 0.001
## Extra lift so the capsule bottom clears the ledge corner on the forward probe.
const LIFT_CLEARANCE := 0.06
## A landing this far above step_height is a wall, not a step.
const CLIMB_SLOP := 0.02
## Forward samples while looking for the floor on top of a lip.
const PROBE_STEP := 0.1
## How far below the feet still counts as "just left the floor" for one climb attempt.
const COYOTE_FLOOR := 0.12
## A bar this thin along the move, and only near the top of the head, can be stepped under.
const BAR_THICKNESS := 0.75
const NOT_HANDLED := INF


static func move_and_slide(
	body: CharacterBody3D, step_height: float, was_on_floor: bool, jumping: bool
) -> float:
	var delta := body.get_physics_process_delta_time()
	var horizontal := Vector3(body.velocity.x, 0.0, body.velocity.z) * delta
	var rising := body.velocity.y > 0.2
	var supported := was_on_floor or (
		not jumping and not rising and _feet_near_floor(body, COYOTE_FLOOR)
	)
	var moving := horizontal.length_squared() > 0.000001
	# Walking up a ramp leaves velocity.y positive. That is the slope, not a jump,
	# and the bar across the ramp has to be ignored on those frames too. A jump is
	# the takeoff frame (`jumping`) and any later rise that started off the floor.
	var airborne_rise := rising and not was_on_floor
	var feet_down := was_on_floor or _feet_near_floor(body, COYOTE_FLOOR)
	if step_height > 0.0 and moving and not jumping and not airborne_rise and feet_down:
		var bar := _overhead_bar(body, horizontal)
		if bar != null:
			body.add_collision_exception_with(bar)
			body.move_and_slide()
			body.remove_collision_exception_with(bar)
			if was_on_floor and body.velocity.y <= 0.0:
				return _try_step_down(body, step_height)
			return 0.0
	var may_step := (
		step_height > 0.0
		and supported
		and not jumping
		and not rising
		and moving
	)
	if may_step:
		var climbed := _try_step_up(body, horizontal, step_height)
		if climbed != NOT_HANDLED:
			return climbed
	body.move_and_slide()
	if step_height > 0.0 and was_on_floor and not jumping and body.velocity.y <= 0.0:
		return _try_step_down(body, step_height)
	return 0.0


static func _try_step_up(body: CharacterBody3D, horizontal: Vector3, step_height: float) -> float:
	var start := body.global_transform
	var hit := KinematicCollision3D.new()
	# recovery_as_collision matches move_and_slide, which treats an overlap with a seam as a wall.
	if not body.test_move(start, horizontal, hit, SAFE_MARGIN, true, 6):
		return NOT_HANDLED
	if not _has_wall(body, hit):
		return NOT_HANDLED
	var dir := horizontal.normalized()
	var up := Vector3.UP * (step_height + LIFT_CLEARANCE)
	var up_hit := KinematicCollision3D.new()
	if body.test_move(start, up, up_hit, SAFE_MARGIN):
		up = up_hit.get_travel()
	if up.y < MIN_STEP:
		# The overhead is too low to lift the full step, which is also how a ramp wedges
		# under the next floor. A short lip ahead can still be a place to stand.
		return _step_onto_ahead(body, start, dir, step_height)
	var reach := horizontal.length() + _body_radius(body) + LIFT_CLEARANCE
	var cursor := start.translated(up)
	var searched := 0.0
	var guard := 0
	while searched < reach - 0.001 and guard < 8:
		guard += 1
		var step_len := minf(PROBE_STEP, reach - searched)
		var fwd := dir * step_len
		var fwd_hit := KinematicCollision3D.new()
		# Recovery so a lift that embedded the capsule in a tall wall stops the probe
		# instead of letting it travel through the overlap.
		if body.test_move(cursor, fwd, fwd_hit, SAFE_MARGIN, true, 4):
			var travel := fwd_hit.get_travel()
			if travel.dot(dir) < 0.008:
				break
			cursor = cursor.translated(travel)
			searched += travel.dot(dir)
		else:
			cursor = cursor.translated(fwd)
			searched += step_len
		var dropped: Variant = _drop_to_floor(body, cursor, up.y + STEP_DOWN_MARGIN)
		if dropped == null:
			# Past the floor. A low edge pins move_and_slide; step off when the lip is short.
			var left := _leave_ledge(body, start, dir, hit, step_height)
			if left != NOT_HANDLED:
				return left
			return _step_onto_ahead(body, start, dir, step_height)
		if not (dropped is Transform3D):
			continue
		var landing := dropped as Transform3D
		var climbed: float = landing.origin.y - start.origin.y
		if climbed > step_height + CLIMB_SLOP:
			return NOT_HANDLED
		if climbed >= MIN_STEP:
			_place(body, landing, dir)
			return climbed
		# Same floor, or a drop no taller than a step. Only once this sample is clear of the
		# riser, so the floor in front of a stair is not treated as the landing.
		var drop_ok := climbed >= -step_height - CLIMB_SLOP
		var advanced := (landing.origin - start.origin).dot(dir)
		if drop_ok and advanced > 0.04 and searched + 0.001 >= horizontal.length() and not _still_blocked(body, landing, dir, horizontal.length()):
			_place(body, landing, dir)
			return climbed
	var left := _leave_ledge(body, start, dir, hit, step_height)
	if left != NOT_HANDLED:
		return left
	return _step_onto_ahead(body, start, dir, step_height)


## Blocked under a low soffit, which is how a ramp tucks into the next floor. Look a short
## distance ahead for a floor no higher than step_height that the capsule can stand on.
static func _step_onto_ahead(
	body: CharacterBody3D, start: Transform3D, dir: Vector3, step_height: float
) -> float:
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return NOT_HANDLED
	var distances: Array[float] = [0.25, 0.4, 0.55]
	for dist in distances:
		var from := start.origin + dir * dist + Vector3.UP * 1.4
		var to := start.origin + dir * dist + Vector3.DOWN * 0.2
		var query := PhysicsRayQueryParameters3D.create(from, to, body.collision_mask)
		query.exclude = [body.get_rid()]
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit.normal
		if not _is_floor(body, normal):
			continue
		var point: Vector3 = hit.position
		var climbed := point.y - start.origin.y
		if climbed < MIN_STEP or climbed > step_height + CLIMB_SLOP:
			continue
		var floor_at := Transform3D(start.basis, point)
		if not _standable(body, floor_at):
			continue
		_place(body, floor_at, dir)
		return climbed
	return NOT_HANDLED


static func _standable(body: CharacterBody3D, at: Transform3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	if space != null:
		# Headroom. A lip under a low ceiling is not a place to stand.
		var from := at.origin + Vector3.UP * 0.15
		var to := at.origin + Vector3.UP * (_body_height(body) - 0.05)
		var query := PhysicsRayQueryParameters3D.create(from, to, body.collision_mask)
		query.exclude = [body.get_rid()]
		if not space.intersect_ray(query).is_empty():
			return false
	var hit := KinematicCollision3D.new()
	if not body.test_move(at, Vector3.UP * 0.05, hit, SAFE_MARGIN, true, 4):
		return true
	if hit.get_travel().length() > 0.01:
		return true
	return _has_floor(body, hit) and not _has_wall(body, hit)


## A separate thin collider that only crosses the top of the head. Null when the blocker is
## the floor, a chest-high beam, or anything thick along the move.
static func _overhead_bar(body: CharacterBody3D, horizontal: Vector3) -> Node:
	var height := _body_height(body)
	if height < 1.8:
		return null
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return null
	var dir := horizontal.normalized()
	var feet := body.global_position
	var support := _support_node(body, space)
	var chest_from := feet + Vector3.UP * 1.05
	var chest_query := PhysicsRayQueryParameters3D.create(chest_from, chest_from + dir * 0.55, body.collision_mask)
	chest_query.exclude = [body.get_rid()]
	var chest := space.intersect_ray(chest_query)
	# Forward rays at the crown catch a bar before the capsule stops on its face.
	# One sits in the top of the head, one just above it, so a rail at the apex still counts.
	for lift in [height - 0.02, height + 0.06]:
		var from := feet + Vector3.UP * float(lift)
		var query := PhysicsRayQueryParameters3D.create(from, from + dir * 0.5, body.collision_mask)
		query.exclude = [body.get_rid()]
		var ahead := space.intersect_ray(query)
		if ahead.is_empty():
			continue
		var ahead_at: Vector3 = ahead.position
		if from.distance_to(ahead_at) > 0.45:
			continue
		var candidate := _as_bar(ahead.collider as Node, support, chest, dir)
		if candidate != null:
			return candidate
	# A wide box around the top of the head. Its center stays below a bar the crown has
	# entered: a trimesh overlap goes silent once the query center is inside the mesh,
	# which is how a small crown sphere lost the rail and the body was shoved back out.
	# The box is as wide as the capsule, so it keeps overlapping until the head is clear.
	# The chest ray above rejects a wall this box also reaches.
	var radius := _body_radius(body)
	var crown := BoxShape3D.new()
	crown.size = Vector3(radius * 2.0, 0.9, radius * 2.0)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = crown
	params.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * (height - 0.35))
	params.collision_mask = body.collision_mask
	params.exclude = [body.get_rid()]
	for hit in space.intersect_shape(params, 8):
		var bar := _as_bar(hit.collider as Node, support, chest, dir)
		if bar != null:
			return bar
	return null


static func _as_bar(bar: Node, support: Node, chest: Dictionary, dir: Vector3) -> Node:
	if bar == null or bar == support:
		return null
	if not chest.is_empty() and chest.collider == bar:
		return null
	if not _thin_along(bar, dir):
		return null
	return bar


static func _support_node(body: CharacterBody3D, space: PhysicsDirectSpaceState3D) -> Node:
	var from := body.global_position + Vector3.UP * 0.2
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 0.6, body.collision_mask)
	query.exclude = [body.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.collider as Node


static func _thin_along(node: Node, dir: Vector3) -> bool:
	var shape_node := _first_shape(node)
	if shape_node == null:
		return false
	var xform := shape_node.global_transform
	var min_d := INF
	var max_d := -INF
	var box := shape_node.shape as BoxShape3D
	var mesh := shape_node.shape as ConcavePolygonShape3D
	if box != null:
		var half := box.size * 0.5
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var d: float = (xform * Vector3(sx * half.x, sy * half.y, sz * half.z)).dot(dir)
					min_d = minf(min_d, d)
					max_d = maxf(max_d, d)
	elif mesh != null:
		var faces := mesh.get_faces()
		if faces.is_empty():
			return false
		for point in faces:
			var d: float = (xform * point).dot(dir)
			min_d = minf(min_d, d)
			max_d = maxf(max_d, d)
	else:
		return false
	return max_d - min_d <= BAR_THICKNESS


static func _first_shape(node: Node) -> CollisionShape3D:
	if node is CollisionShape3D:
		return node as CollisionShape3D
	for child in node.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node != null and not shape_node.disabled:
			return shape_node
	return null


static func _body_height(body: CharacterBody3D) -> float:
	for child in body.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.disabled:
			continue
		var capsule := shape_node.shape as CapsuleShape3D
		if capsule != null:
			return capsule.height
	return 2.0


## The floor ends in a lip shorter than a stair. move_and_slide treats that lip as a wall and
## pins a grounded capsule to it. Move far enough that the capsule clears the lip, and land
## if another floor is within step_height.
static func _leave_ledge(
	body: CharacterBody3D, start: Transform3D, dir: Vector3, hit: KinematicCollision3D, step_height: float
) -> float:
	if not _pushing_into(body, hit, dir):
		return NOT_HANDLED
	var lift := Vector3.UP * 0.08
	var up_hit := KinematicCollision3D.new()
	if body.test_move(start, lift, up_hit, SAFE_MARGIN):
		lift = up_hit.get_travel()
	if lift.y < 0.04:
		return NOT_HANDLED
	var dist := _body_radius(body) + 0.06
	var raised := start.translated(lift)
	var fwd_hit := KinematicCollision3D.new()
	if body.test_move(raised, dir * dist, fwd_hit, SAFE_MARGIN, true, 4):
		if fwd_hit.get_travel().dot(dir) < dist * 0.85:
			return NOT_HANDLED
	var off := start.translated(dir * dist + lift)
	var landed: Variant = _drop_to_floor(body, off, lift.y + step_height + STEP_DOWN_MARGIN)
	if landed is Transform3D:
		var floor_at := landed as Transform3D
		var drop: float = floor_at.origin.y - start.origin.y
		if drop <= CLIMB_SLOP and drop >= -step_height - CLIMB_SLOP:
			_place(body, floor_at, dir)
			return drop
	_place(body, off, dir)
	return 0.0


static func _pushing_into(body: CharacterBody3D, hit: KinematicCollision3D, dir: Vector3) -> bool:
	var worst := 0.0
	for i in hit.get_collision_count():
		if _is_floor(body, hit.get_normal(i)):
			continue
		worst = minf(worst, hit.get_normal(i).dot(dir))
	return worst < -0.5


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


## null: nothing below (a gap). false: hit only steep surfaces (a corner or a riser).
## Transform3D: feet on a floor.
static func _drop_to_floor(body: CharacterBody3D, from: Transform3D, drop: float) -> Variant:
	var hit := KinematicCollision3D.new()
	if not body.test_move(from, Vector3.DOWN * drop, hit, SAFE_MARGIN, false, 6):
		return null
	# The contact that stopped the sweep has to be the floor. A later contact in the
	# same result is often the ledge corner, and standing there shoves the body up a wall.
	if not _is_floor(body, hit.get_normal()):
		return false
	return from.translated(hit.get_travel())


static func _still_blocked(body: CharacterBody3D, at: Transform3D, dir: Vector3, motion: float) -> bool:
	var hit := KinematicCollision3D.new()
	var dist := maxf(motion, PROBE_STEP)
	if not body.test_move(at, dir * dist, hit, SAFE_MARGIN, true, 4):
		return false
	return _has_wall(body, hit)


static func _feet_near_floor(body: CharacterBody3D, reach: float) -> bool:
	var hit := KinematicCollision3D.new()
	if not body.test_move(body.global_transform, Vector3.DOWN * reach, hit, SAFE_MARGIN, false, 4):
		return false
	return _has_floor(body, hit)


static func _place(body: CharacterBody3D, landing: Transform3D, dir: Vector3) -> void:
	body.global_transform = landing
	var keep := body.velocity
	# Settle floor state without spending the horizontal move a second time.
	body.velocity = Vector3.ZERO
	body.move_and_slide()
	var shifted := body.global_position - landing.origin
	# A zero-velocity settle can depenetrate back down off the lip we just stood on.
	if shifted.dot(dir) < -0.01 or shifted.y < -0.05:
		body.global_transform = landing
	body.velocity = Vector3(keep.x, maxf(keep.y, 0.0), keep.z)


static func _body_radius(body: CharacterBody3D) -> float:
	for child in body.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.disabled:
			continue
		var capsule := shape_node.shape as CapsuleShape3D
		if capsule != null:
			return capsule.radius
	return 0.4


static func _has_floor(body: CharacterBody3D, hit: KinematicCollision3D) -> bool:
	for i in hit.get_collision_count():
		if _is_floor(body, hit.get_normal(i)):
			return true
	return false


static func _has_wall(body: CharacterBody3D, hit: KinematicCollision3D) -> bool:
	for i in hit.get_collision_count():
		if not _is_floor(body, hit.get_normal(i)):
			return true
	return false


static func _is_floor(body: CharacterBody3D, normal: Vector3) -> bool:
	return normal.angle_to(Vector3.UP) <= body.floor_max_angle + 0.01
