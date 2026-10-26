extends SceneTree
## Hospitaller player model + modular armor (tools/hospitaller, scripts/player/armor_loadout.gd):
## the glb keeps the block-out's joint contract (every animated PB_* path, the weapon markers);
## every ArmorLoadout variant has pieces in the model and nothing else is named AR_*; a loadout
## shows exactly its variants; the loadout string round-trips and survives garbage; every
## surface gets a project material; the undersuit's skeleton follows the joints (BodySkinSync);
## Vanguard's NVG plate swings up; first_person_hidden reaches the undersuit too. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/hospitaller_armor_self_test.gd

const BODY := "res://scenes/characters/player_body.tscn"
const GLB := "res://assets/models/characters/hospitaller.glb"
const ROOT := "Blockout/BodyMesh/PB_Pelvis"
const JOINT_PATHS := [
	ROOT,
	ROOT + "/PB_Abdomen",
	ROOT + "/PB_Abdomen/PB_Chest",
	ROOT + "/PB_Abdomen/PB_Chest/PB_Neck/PB_Head",
	ROOT + "/PB_Abdomen/PB_Chest/PB_UpperArm_L/PB_Forearm_L/PB_Hand_L/OffHand_L",
	ROOT + "/PB_Abdomen/PB_Chest/PB_UpperArm_R/PB_Forearm_R/PB_Hand_R/WeaponAttach_R",
	ROOT + "/PB_Thigh_L/PB_Shin_L/PB_Boot_L",
	ROOT + "/PB_Thigh_R/PB_Shin_R/PB_Boot_R",
]
## Block-out pivots the animation library was keyed on (global, model at the origin).
const PIVOTS := {
	"PB_Pelvis": Vector3(0, 0.93, 0),
	"PB_Chest": Vector3(0, 1.12, 0),
	"PB_Head": Vector3(0, 1.54, 0),
	"PB_UpperArm_L": Vector3(-0.25, 1.36, 0),
	"PB_Forearm_R": Vector3(0.275, 1.0, 0),
	"PB_Hand_R": Vector3(0.29, 0.8, 0),
	"PB_Shin_L": Vector3(-0.11, 0.51, 0),
	"PB_Boot_R": Vector3(0.11, 0.12, 0),
	"WeaponAttach_R": Vector3(0.28, 0.745, -0.01),
}

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_codec()
	# The bare glb (no animation player) for the pivot contract.
	var glb := (load(GLB) as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	root.add_child(holder)
	glb.name = "Blockout"
	holder.add_child(glb)
	_test_contract(holder)
	holder.queue_free()
	var body := (load(BODY) as PackedScene).instantiate() as Node3D
	root.add_child(body)
	await process_frame
	_test_catalogue(body)
	_test_loadouts(body)
	_test_materials(body)
	await _test_skin(body)
	_test_plate(body)
	_test_layers(body)
	body.queue_free()
	if _failed:
		print("HOSPITALLER_ARMOR_SELF_TEST FAIL")
		quit(1)
		return
	print("HOSPITALLER_ARMOR_SELF_TEST PASS")
	quit(0)


func _test_codec() -> void:
	var lo := {"helmet": "vanguard", "chest": "carrier", "shoulders": "heavy", "arms": "strut", "legs": "light"}
	_expect(ArmorLoadout.decode(ArmorLoadout.encode(lo)) == lo, "loadout string round-trips")
	_expect(ArmorLoadout.decode("") == ArmorLoadout.default_loadout(), "empty string -> defaults")
	var junk := ArmorLoadout.decode("helmet=nope,,legs=light,bogus=1,chest")
	_expect(junk.helmet == "hospitaller" and junk.legs == "light" and junk.size() == 5,
		"garbage falls back per slot")
	var cycled := ArmorLoadout.cycle(ArmorLoadout.default_loadout(), "helmet", -1)
	_expect(cycled.helmet == ArmorLoadout.VARIANTS.helmet[-1].id, "cycle wraps backwards")


func _test_contract(body: Node3D) -> void:
	for path: String in JOINT_PATHS:
		_expect(body.get_node_or_null(path) != null, "joint path %s" % path)
	for joint_name: String in PIVOTS:
		var node := body.find_child(joint_name, true, false) as Node3D
		_expect(node != null and node.global_position.distance_to(PIVOTS[joint_name]) < 0.002,
			"%s on the block-out pivot" % joint_name)


func _armor_nodes(body: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for node in body.find_children("AR_*", "Node3D", true, false):
		out.append(node as Node3D)
	return out


func _test_catalogue(body: Node3D) -> void:
	var seen := {}
	for node in _armor_nodes(body):
		var bits := String(node.name).split("_")
		_expect(bits.size() >= 4, "%s is AR_<slot>_<variant>_<piece>" % node.name)
		if bits.size() >= 4:
			_expect(ArmorLoadout.has_variant(bits[1], bits[2]), "%s is a catalogue variant" % node.name)
			seen["%s/%s" % [bits[1], bits[2]]] = true
	for slot: String in ArmorLoadout.SLOTS:
		for v: Dictionary in ArmorLoadout.VARIANTS[slot]:
			_expect(seen.has("%s/%s" % [slot, v.id]), "model has %s / %s" % [slot, v.id])


func _test_loadouts(body: Node3D) -> void:
	var model := PlayerColor.model_of(body)
	for slot: String in ArmorLoadout.SLOTS:
		for v: Dictionary in ArmorLoadout.VARIANTS[slot]:
			var lo := ArmorLoadout.default_loadout()
			lo[slot] = v.id
			ArmorLoadout.apply(body, lo)
			var wrong := 0
			for node in _armor_nodes(body):
				var bits := String(node.name).split("_")
				if node.visible != (lo.get(bits[1], "") == bits[2]):
					wrong += 1
			_expect(wrong == 0, "loadout %s=%s shows exactly its pieces" % [slot, v.id])
	ArmorLoadout.apply(body, ArmorLoadout.default_loadout())


func _test_materials(body: Node3D) -> void:
	var meshes := body.find_children("*", "MeshInstance3D", true, false)
	_expect(meshes.size() > 20, "model has its meshes")
	for node in meshes:
		var mesh := node as MeshInstance3D
		for s in mesh.mesh.get_surface_count():
			_expect(mesh.get_surface_override_material(s) != null,
				"%s surface %d has a project material" % [mesh.name, s])


func _test_skin(body: Node3D) -> void:
	var skel := body.find_children("*", "Skeleton3D", true, false)
	_expect(skel.size() == 1, "one skeleton (the undersuit)")
	if skel.is_empty():
		return
	var sk := skel[0] as Skeleton3D
	var bone := sk.find_bone("B_Forearm_R")
	_expect(bone >= 0, "bone B_Forearm_R")
	var anim := body.get_node_or_null(^"AnimationPlayer") as AnimationPlayer
	if anim != null:
		anim.stop()
	var forearm := body.find_child("PB_Forearm_R", true, false) as Node3D
	forearm.rotation = Vector3(deg_to_rad(-80), 0, 0)
	(body.get_node(^"BodySkinSync") as BodySkinSync).sync()
	var bone_global := sk.global_transform * sk.get_bone_global_pose(bone)
	var delta_joint := forearm.global_basis.get_rotation_quaternion()
	var rest := sk.global_transform * sk.get_bone_global_rest(bone)
	var delta_bone := bone_global.basis.get_rotation_quaternion() * rest.basis.get_rotation_quaternion().inverse()
	_expect(delta_bone.angle_to(delta_joint) < 0.01, "B_Forearm_R turns with PB_Forearm_R")
	_expect(bone_global.origin.distance_to(forearm.global_position) < 0.002, "B_Forearm_R stays on the elbow")
	forearm.rotation = Vector3.ZERO
	(body.get_node(^"BodySkinSync") as BodySkinSync).sync()


func _test_plate(body: Node3D) -> void:
	var model := PlayerColor.model_of(body)
	var lo := ArmorLoadout.default_loadout()
	lo.helmet = "vanguard"
	ArmorLoadout.apply(body, lo)
	var plate := body.find_child("AR_helmet_vanguard_visorplate", true, false) as Node3D
	_expect(plate != null and plate.visible, "Vanguard's plate shows")
	if plate == null:
		return
	var down := plate.global_transform
	model.set_visor_plate_up(true)
	_expect(absf(plate.rotation.x - deg_to_rad(100.0)) < 0.001, "plate swings up about X")
	model.set_visor_plate_up(false)
	_expect(plate.global_transform.is_equal_approx(down), "plate back down")
	ArmorLoadout.apply(body, ArmorLoadout.default_loadout())


func _test_layers(body: Node3D) -> void:
	var model := PlayerColor.model_of(body)
	model.set(&"first_person_hidden", true)
	var under := body.find_child("Undersuit", true, false) as MeshInstance3D
	_expect(under != null and under.layers == 2, "undersuit follows first_person_hidden")
	model.set(&"first_person_hidden", false)
	_expect(under != null and under.layers == 1, "undersuit back on layer 1")


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failed = true
		print("  FAIL: ", what)
	else:
		print("  ok: ", what)
