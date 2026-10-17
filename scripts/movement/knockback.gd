class_name Knockback
extends RefCounted
## One-shot shove for melee and explosions (Player and Bot). Gunshots do not use it.
## Speeds stay inside the host move budget (NetHost MOVE_SPEED 14, RISE_SPEED 16) so the
## owning client can apply the same impulse from the damaged RPC.
##
## Melee is a stumble: about a step backward, with a small hop. A blast uses the same
## falloff as its damage and always carries some upward speed so a blast at the feet
## leaves the floor. apply_knockback adds this once; loose ground accel keeps the
## landing from braking it away in a single tick.

const MELEE_SPEED := 10.0
const MELEE_HOP := 3.0
const BLAST_SPEED := 12.0
const BLAST_MIN_HOP := 3.0
const MAX_HORIZONTAL := 13.0
const MAX_UP := 12.0
## Seconds of reduced ground accel after a shove, so accel 70 does not erase it.
const LOOSE_TIME := 0.3
const LOOSE_ACCEL := 24.0


## Horizontal push along direction, plus a hop. A zero direction is only the hop.
static func melee(direction: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return Vector3.UP * MELEE_HOP
	return flat.normalized() * MELEE_SPEED + Vector3.UP * MELEE_HOP


## direction is away from the blast. Scale matches damage falloff (1 at full damage).
## Zero when the blast dealt nothing. Upward component is at least BLAST_MIN_HOP * scale.
static func blast(direction: Vector3, amount: float, full_damage: float) -> Vector3:
	var scale := clampf(amount / maxf(full_damage, 0.001), 0.0, 1.0)
	if scale <= 0.0:
		return Vector3.ZERO
	var dir := direction
	if dir.length_squared() < 0.0001:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
	var impulse := dir * BLAST_SPEED * scale
	impulse.y = maxf(impulse.y, BLAST_MIN_HOP * scale)
	return impulse
