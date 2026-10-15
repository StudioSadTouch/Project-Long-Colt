class_name NetLag
extends RefCounted
## Host lag compensation: a short history of every combatant's hit colliders (capsule, Hurtbox,
## head boxes; get_own_colliders()) per physics tick. rewind() moves them, straight in the
## physics server so ray queries see it this tick, to where the shooter saw them; restore()
## puts them back. Only collider transforms move: no scene-tree transforms, signals or game
## state change, and nothing is rewound further than MAX_REWIND seconds.

const MAX_REWIND := 0.25

## body -> Array of [tick: int, transforms: Array[Transform3D]] (oldest first)
var _history: Dictionary = {}
var _rewound: Array = []


func record(bodies: Array[Node3D], tick: int) -> void:
	var keep := ceili(MAX_REWIND * Engine.physics_ticks_per_second) + 2
	for body in _history.keys():
		if not is_instance_valid(body) or not bodies.has(body):
			_history.erase(body)
	for body in bodies:
		if not body.has_method(&"get_own_colliders"):
			continue
		var xforms: Array[Transform3D] = []
		for collider: CollisionObject3D in body.call(&"get_own_colliders"):
			xforms.append(collider.global_transform)
		var frames: Array = _history.get(body, [])
		frames.append([tick, xforms])
		while frames.size() > keep:
			frames.pop_front()
		_history[body] = frames


## Moves every recorded body except `shooter` to its state at `tick` (clamped to history).
func rewind(tick: int, shooter: Node) -> void:
	restore()
	for body in _history:  # untyped: keys may be freed bodies
		if body == shooter or not is_instance_valid(body):
			continue
		var frames: Array = _history[body]
		var past: Array = []
		for frame: Array in frames:
			if frame[0] <= tick:
				past = frame
		if past.is_empty() or past[0] == frames[-1][0]:
			continue
		var colliders: Array = body.call(&"get_own_colliders")
		var xforms: Array = past[1]
		if colliders.size() != xforms.size():
			continue
		for i in colliders.size():
			_set_transform(colliders[i], xforms[i])
		_rewound.append(colliders)


func restore() -> void:
	for colliders: Array in _rewound:
		for collider in colliders:  # untyped: may hold freed colliders
			if is_instance_valid(collider):
				_set_transform(collider, collider.global_transform)
	_rewound.clear()


static func _set_transform(collider: CollisionObject3D, xform: Transform3D) -> void:
	if collider is Area3D:
		PhysicsServer3D.area_set_transform(collider.get_rid(), xform)
	else:
		PhysicsServer3D.body_set_state(
			collider.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform
		)
