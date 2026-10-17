extends SceneTree
## Visual check for the New Ottoman weapon models: first-person poses (idle, mid reload, mag
## seat, melee hit, a fire frame), each model from four sides as the pickups show it, and the
## third-person props on the player body (in hand, and another one holstered). Needs a
## display (not --headless); writes PNGs to res://.noe_render/ (Godot skips dot folders):
## DISPLAY=:0 flatpak run org.godotengine.Godot --path . --script res://tests/new_ottoman_weapons_render.gd

const NAMES := [
	"tufek", "long_rifle", "glaive_rifle", "raider_carbine", "humbara_launcher", "kilij", "yatagan"
]
const OUT := "res://.noe_render"
const ENV := "res://resources/environments/outdoor_environment.tres"
const SCRIPT_NODES := [&"WeaponFx", &"ViewmodelReload", &"ViewmodelMelee", &"ViewmodelFire"]

var _vp: SubViewport
var _cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_vp = SubViewport.new()
	_vp.size = Vector2i(1280, 720)
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var env := WorldEnvironment.new()
	env.environment = load(ENV) as Environment
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	_vp.add_child(sun)
	var backdrop := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(40, 40, 0.1)
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.42, 0.44, 0.46)
	plane.material = grey
	backdrop.mesh = plane
	_vp.add_child(backdrop)
	_cam = Camera3D.new()
	_cam.fov = 75.0
	_cam.near = 0.05
	_vp.add_child(_cam)
	for weapon_name in NAMES:
		await _first_person(weapon_name)
	backdrop.visible = false
	for weapon_name in NAMES:
		await _views(weapon_name)
	await _third_person()
	print("NOE_RENDER DONE")
	quit(0)


func _strip(path: String, keep_viewmodel: bool) -> Node3D:
	var copy := (load(path) as PackedScene).instantiate() as Node3D
	copy.set_script(null)
	for node in copy.find_children("*", "", true, false):
		var drop := node.name in SCRIPT_NODES
		if not keep_viewmodel and node.is_in_group(&"viewmodel_only"):
			drop = true
		if drop and is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.free()
	return copy


## Five poses side by side: idle, reload at 35 %, the mag seat, the melee hit, a fire frame.
func _first_person(weapon_name: String) -> void:
	var path := "res://scenes/weapons/new_ottoman/%s.tscn" % weapon_name
	var data := WeaponData.of_scene(load(path) as PackedScene)
	_cam.transform = Transform3D.IDENTITY
	_cam.position = Vector3(0, 1.0, 3.0)
	var weapon := _strip(path, true)
	var rest := weapon.transform
	_cam.add_child(weapon)
	var player := weapon.get_node(^"AnimationPlayer") as AnimationPlayer
	var poses := [[&"idle", 0.0]]
	if player.has_animation(&"reload_tactical"):
		var length := player.get_animation(&"reload_tactical").length
		poses.append([&"reload_tactical", length * 0.35])
		poses.append([&"reload_empty", length * data.reload_insert_fraction - 0.05])
	poses.append([&"melee", 0.1])
	if player.has_animation(&"fire"):
		poses.append([&"fire", 0.46 if weapon_name == "long_rifle" else 0.12])
	elif player.has_animation(&"melee_b"):
		poses.append([&"melee_b", 0.1])
	var shots: Array[Image] = []
	for pose: Array in poses:
		weapon.transform = rest
		player.play(&"RESET")
		player.seek(0.0, true)
		player.play(pose[0])
		player.seek(pose[1], true)
		player.pause()
		await _frames(3)
		shots.append(_vp.get_texture().get_image())
	_save_strip(shots, "%s/fp_%s.png" % [OUT, weapon_name], true)
	weapon.queue_free()
	await _frames(1)


## Pickup-style copy (no hands) from four sides: right, left, front 3/4, shooter's 3/4.
func _views(weapon_name: String) -> void:
	var copy := _strip("res://scenes/weapons/new_ottoman/%s.tscn" % weapon_name, false)
	copy.transform = Transform3D.IDENTITY
	_vp.add_child(copy)
	await _frames(1)
	var box := _bounds(copy)
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.62, 0.3)
	var shots: Array[Image] = []
	for dir: Vector3 in [Vector3(1, 0.02, 0), Vector3(-1, 0.02, 0), Vector3(-0.6, 0.45, -0.75), Vector3(0.7, 0.5, 0.6)]:
		var eye := centre + dir.normalized() * reach * 1.8
		_cam.transform = Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)
		_cam.fov = 32.0
		await _frames(3)
		shots.append(_vp.get_texture().get_image())
	_cam.fov = 75.0
	_save_strip(shots, "%s/views_%s.png" % [OUT, weapon_name])
	copy.queue_free()
	await _frames(1)


## [in hand, holstered] pairs; the standard rifle and longsword first as size references.
func _third_person() -> void:
	const M := CharacterAnimState.WeaponModel
	var pairs := [
		[M.RIFLE, M.PISTOL], [M.SWORD, M.RIFLE], [M.TUFEK, M.YATAGAN], [M.GLAIVE_RIFLE, M.KILIJ],
		[M.HUMBARA, M.TUFEK], [M.RAIDER_CARBINE, M.KILIJ], [M.LONG_RIFLE, M.YATAGAN],
		[M.KILIJ, M.RAIDER_CARBINE], [M.YATAGAN, M.TUFEK],
	]
	var body := (load("res://scenes/characters/player_body.tscn") as PackedScene).instantiate() as Node3D
	_vp.add_child(body)
	var source := body.get_node_or_null(^"CharacterAnimSource")
	if source != null:
		source.set(&"enabled", false)
	var driver := body.get_node(^"CharacterAnimDriver") as CharacterAnimDriver
	driver.reset_baseline()
	var shots: Array[Image] = []
	var sheet := 0
	for pair: Array in pairs:
		var state := CharacterAnimState.new()
		state.weapon_model = pair[0]
		state.holster_model = pair[1]
		state.weapon_type = _class_of(pair[0])
		state.holster_type = _class_of(pair[1])
		for i in 40:
			driver.apply_state(state)
			await process_frame
		for eye: Vector3 in [Vector3(1.7, 1.6, -2.2), Vector3(-2.4, 1.5, 0.9)]:
			_cam.transform = Transform3D(Basis.IDENTITY, eye).looking_at(Vector3(0, 1.15, 0), Vector3.UP)
			_cam.fov = 45.0
			await _frames(2)
			shots.append(_vp.get_texture().get_image())
		if shots.size() == 6:
			_save_strip(shots, "%s/third_person_%d.png" % [OUT, sheet])
			shots.clear()
			sheet += 1
	if not shots.is_empty():
		_save_strip(shots, "%s/third_person_%d.png" % [OUT, sheet])
	body.queue_free()


static func _class_of(model: int) -> int:
	const M := CharacterAnimState.WeaponModel
	match model:
		M.PISTOL:
			return CharacterAnimState.WeaponType.PISTOL
		M.SWORD, M.KILIJ, M.YATAGAN:
			return CharacterAnimState.WeaponType.SWORD
	return CharacterAnimState.WeaponType.RIFLE


func _bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var b := mesh.global_transform * mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## 3 x 2 sheet. crop: keep each frame's lower-right 60 % at full size (where the viewmodel
## sits) instead of shrinking the whole frame.
func _save_strip(shots: Array[Image], path: String, crop: bool = false) -> void:
	var full := Vector2i(shots[0].get_width(), shots[0].get_height())
	var w := int(full.x * 0.6) if crop else full.x / 2
	var h := int(full.y * 0.6) if crop else full.y / 2
	var sheet := Image.create(w * 3, h * 2, false, shots[0].get_format())
	for i in shots.size():
		var part := shots[i].duplicate() as Image
		if crop:
			part = part.get_region(Rect2i(full.x - w, full.y - h, w, h))
		else:
			part.resize(w, h)
		sheet.blit_rect(part, Rect2i(0, 0, w, h), Vector2i((i % 3) * w, (i / 3) * h))
	sheet.save_png(path)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
