class_name BodySkinSync
extends Node
## Drives the Hospitaller undersuit's Skeleton3D from the PB_* joint nodes.
##
## The animation library poses the joint nodes (Blockout/BodyMesh/PB_Pelvis/...), exactly as
## it did for the rigid block-out; the armor hangs off those nodes. The undersuit is one skinned
## mesh whose bones B_<x> follow PB_<x>: each frame, after the AnimationPlayer and the anim
## driver have run, every bone gets its joint's current transform times the bone's rest
## offset from that joint (captured once, at rest, in _ready).
## A child of PlayerModel (player_model.tscn), after the glb instance.

## Bone name prefix -> joint name prefix (B_Chest follows PB_Chest).
const BONE_PREFIX := "B_"
const JOINT_PREFIX := "PB_"

var _skeleton: Skeleton3D
## Per bone index: the joint it follows (null = left at rest) and the bone's rest pose in that
## joint's space.
var _joints: Array[Node3D] = []
var _offsets: Array[Transform3D] = []
var _parents: PackedInt32Array = []
var _globals: Array[Transform3D] = []


func _ready() -> void:
	# After the AnimationPlayer (priority 0) and CharacterAnimDriver have posed the joints.
	process_priority = 100
	var model := get_parent()
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		set_process(false)
		return
	_skeleton = found[0] as Skeleton3D
	var inv := _skeleton.global_transform.affine_inverse()
	var count := _skeleton.get_bone_count()
	_joints.resize(count)
	_offsets.resize(count)
	_globals.resize(count)
	_parents.resize(count)
	for bone in count:
		_parents[bone] = _skeleton.get_bone_parent(bone)
		var bone_name := _skeleton.get_bone_name(bone)
		var joint: Node3D = null
		if bone_name.begins_with(BONE_PREFIX):
			var joint_name := JOINT_PREFIX + bone_name.substr(BONE_PREFIX.length())
			joint = model.find_child(joint_name, true, false) as Node3D
		if joint == null:
			push_warning("BodySkinSync: no joint for bone %s; it stays at rest." % bone_name)
		_joints[bone] = joint
		var rest := _skeleton.get_bone_global_rest(bone)
		_offsets[bone] = (inv * joint.global_transform).affine_inverse() * rest if joint else rest
	sync()


func _process(_delta: float) -> void:
	sync()


## Copies the joints' current poses onto the bones (call after posing joints by hand).
func sync() -> void:
	if _skeleton == null:
		return
	var inv := _skeleton.global_transform.affine_inverse()
	for bone in _joints.size():
		var joint := _joints[bone]
		_globals[bone] = (
			(inv * joint.global_transform) * _offsets[bone] if joint != null
			else _skeleton.get_bone_global_rest(bone)
		)
	for bone in _joints.size():
		var parent := _parents[bone]
		var local := _globals[bone] if parent < 0 else _globals[parent].affine_inverse() * _globals[bone]
		_skeleton.set_bone_pose_position(bone, local.origin)
		_skeleton.set_bone_pose_rotation(bone, local.basis.get_rotation_quaternion())
		_skeleton.set_bone_pose_scale(bone, local.basis.get_scale())
