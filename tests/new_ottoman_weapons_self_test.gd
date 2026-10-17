extends SceneTree
## New Ottoman issue weapons as player weapons (their own models,
## tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py): each scene keeps the weapon
## contract (its data, a Grip, viewmodel-only hands, every clip track resolves, gunfire on the
## guns and none on the blades, nothing glows), maps to its own third-person model, and works in
## a player's hands: the gun fires and its fire clip plays, reloads with its clip and refills;
## the blade swings with its clip. The third-person prop and the pickup show the model. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/new_ottoman_weapons_self_test.gd

const NAMES := [
	"tufek", "long_rifle", "glaive_rifle", "raider_carbine", "humbara_launcher", "kilij", "yatagan"
]
const PICKUP := "res://scenes/pickups/weapon_pickup.tscn"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var floor_body := _box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var models := {}
	for weapon_name in NAMES:
		_test_scene(weapon_name, models)
	for weapon_name in NAMES:
		await _test_in_hand(weapon_name)
	await _test_pickups()
	floor_body.queue_free()
	if _failed:
		print("NEW_OTTOMAN_WEAPONS_SELF_TEST FAIL")
		quit(1)
		return
	print("NEW_OTTOMAN_WEAPONS_SELF_TEST PASS")
	quit(0)


static func _path(weapon_name: String) -> String:
	return "res://scenes/weapons/new_ottoman/%s.tscn" % weapon_name


func _test_scene(weapon_name: String, models: Dictionary) -> void:
	var path := _path(weapon_name)
	var weapon := (load(path) as PackedScene).instantiate() as Weapon
	_expect(weapon != null, "%s: a Weapon scene" % weapon_name)
	if weapon == null:
		return
	var data_path := "res://resources/weapons/new_ottoman/%s.tres" % weapon_name
	_expect(weapon.data != null and weapon.data.resource_path == data_path, "%s: its own data" % weapon_name)
	var grip := weapon.get_node_or_null(^"Grip") as MeshInstance3D
	_expect(grip != null and not grip.is_in_group(&"viewmodel_only"), "%s: a Grip mesh" % weapon_name)
	var hand := weapon.get_node_or_null(^"RightHand")
	_expect(hand != null and hand.is_in_group(&"viewmodel_only"), "%s: viewmodel-only hand" % weapon_name)
	var blade := weapon.data.melee_primary
	var fx := weapon.get_node_or_null(^"WeaponFx") as WeaponFx
	if blade:
		_expect(fx == null, "%s: a blade has no gunfire" % weapon_name)
	else:
		_expect(fx != null and fx.fire_sound != null, "%s: gunfire sound" % weapon_name)
	# Clips: the set the viewmodel scripts play, and every track lands on a node.
	var anim := weapon.get_node_or_null(^"AnimationPlayer") as AnimationPlayer
	var want := ["RESET", "idle", "melee"]
	want += ["melee_b"] if blade else ["reload_tactical", "reload_empty", "fire", "fire_empty"]
	var missing := []
	var broken := []
	for clip: String in want:
		if anim == null or not anim.has_animation(clip):
			missing.append(clip)
			continue
		var a := anim.get_animation(clip)
		for i in a.get_track_count():
			var node_path := NodePath(String(a.track_get_path(i)).get_slice(":", 0))
			if weapon.get_node_or_null(node_path) == null:
				broken.append("%s/%s" % [clip, node_path])
	_expect(missing.is_empty(), "%s: clips %s (missing %s)" % [weapon_name, want, missing])
	_expect(broken.is_empty(), "%s: every clip track resolves %s" % [weapon_name, broken])
	# No glow anywhere (the board: the sensor slit is the faction's only light).
	var lit := []
	for node in weapon.find_children("*", "MeshInstance3D", true, false):
		var material := (node as MeshInstance3D).get_active_material(0) as StandardMaterial3D
		if material != null and material.emission_enabled:
			lit.append(node.name)
	_expect(lit.is_empty(), "%s: nothing glows %s" % [weapon_name, lit])
	# Its own third-person model, drawn from this scene.
	var model := CharacterAnimState.model_from_scene(data_path)
	_expect(model != CharacterAnimState.WeaponModel.NONE, "%s: a third-person model id" % weapon_name)
	_expect(not models.has(model), "%s: model id not shared" % weapon_name)
	models[model] = weapon_name
	_expect(
		CharacterWeaponProps.NEW_OTTOMAN_SCENES.get(model, "") == path,
		"%s: the prop table draws this scene" % weapon_name
	)
	weapon.free()


func _test_in_hand(weapon_name: String) -> void:
	var player := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector3(0, 0.05, 0)
	root.add_child(player)
	await _frames(5)
	var holder := player.get_weapon_holder()
	holder.give_weapon((load(_path(weapon_name)) as PackedScene).instantiate() as Weapon)
	await _frames(60)  # equip
	var weapon := holder.get_active()
	_expect(weapon != null and weapon.scene_file_path == _path(weapon_name), "%s: in hand" % weapon_name)
	if weapon == null:
		player.queue_free()
		return
	var model := CharacterAnimState.model_from_scene(weapon.data.resource_path)
	var prop_name := "Prop_%s" % CharacterAnimState.WeaponModel.keys()[model].capitalize()
	var prop := player.find_child(prop_name, true, false) as Node3D
	var meshes := prop.find_children("*", "MeshInstance3D", true, false).size() if prop != null else 0
	_expect(prop != null and prop.visible and meshes > 5, "%s: third-person prop %s (%d meshes)" % [weapon_name, prop_name, meshes])
	var anim := weapon.get_node(^"AnimationPlayer") as AnimationPlayer
	player.rotation.y = PI  # nothing in front: blades whiff, the humbara lobs into open floor
	await _frames(2)
	if weapon.data.melee_primary:
		weapon.trigger(true, true)
		weapon.trigger(false, true)
		weapon.release_trigger()
		await _frames(2)
		var clip := String(anim.current_animation)
		_expect(clip in ["melee", "melee_b"], "%s: the swing plays its clip (%s)" % [weapon_name, clip])
	else:
		var before := weapon.magazine
		weapon.trigger(true, true)
		await _frames(1)
		var fire_clip := String(anim.current_animation)
		weapon.release_trigger()
		_expect(weapon.magazine == before - 1, "%s: fires (%d -> %d)" % [weapon_name, before, weapon.magazine])
		_expect(fire_clip == "fire", "%s: the fire clip plays (%s)" % [weapon_name, fire_clip])
		await _frames(70)
		weapon.reload()
		await _frames(2)
		var reload_clip := String(anim.current_animation)
		_expect(reload_clip == "reload_tactical", "%s: reload clip (%s)" % [weapon_name, reload_clip])
		await _frames(int(weapon.data.reload_time * 60.0) + 20)
		_expect(
			weapon.magazine == weapon.data.magazine_size,
			"%s: reload refills (%d / %d)" % [weapon_name, weapon.magazine, weapon.data.magazine_size]
		)
		_expect(not anim.current_animation.begins_with("reload"), "%s: back to idle after the reload" % weapon_name)
	player.queue_free()
	await _frames(2)


## Pickups (drops, racks) show the model without the hands.
func _test_pickups() -> void:
	for weapon_name in NAMES:
		var pickup := (load(PICKUP) as PackedScene).instantiate() as WeaponPickup
		pickup.weapon_scene = load(_path(weapon_name)) as PackedScene
		pickup.position = Vector3(5, 0.9, 5)
		root.add_child(pickup)
		await _frames(2)
		var visual: Variant = pickup.get(&"_visual")
		var meshes := 0
		var hands := false
		if visual is Node3D:
			meshes = (visual as Node3D).find_children("*", "MeshInstance3D", true, false).size()
			hands = (visual as Node3D).find_child("RightHand", true, false) != null
		_expect(meshes > 5 and not hands, "%s: pickup shows the model (%d meshes, no hands)" % [weapon_name, meshes])
		pickup.queue_free()
		await _frames(1)


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)
	return body


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("PASS ", message)
		return
	_failed = true
	push_error("FAIL " + message)
