extends SceneTree
## Visual check for the Hospitaller in the engine: five armor loadouts on the real player body
## (player_body.tscn, driven by CharacterAnimDriver) standing with a rifle, then the default
## loadout running, crouched and aiming down, to see the skinned undersuit bend under the rigid
## armor. Needs a display (not --headless); writes PNGs to res://.hosp_render/:
## DISPLAY=:0 flatpak run org.godotengine.Godot --path . --script res://tests/hospitaller_render.gd

const BODY := "res://scenes/characters/player_body.tscn"
const OUT := "res://.hosp_render"
const ENV := "res://resources/environments/outdoor_environment.tres"
const LOADOUTS := [
	{},
	{"helmet": "warden", "chest": "breastplate", "shoulders": "pauldron"},
	{"helmet": "sentry", "chest": "grenadier", "shoulders": "heavy"},
	{"helmet": "vanguard", "chest": "carrier", "arms": "strut", "legs": "light"},
	{"helmet": "lancer", "chest": "exo", "shoulders": "pauldron", "arms": "strut", "legs": "light"},
]
const COLORS := [
	Color(0.290196, 0.313725, 0.223529), Color(0.62, 0.48, 0.32), Color(0.43, 0.46, 0.5),
	Color(0.14, 0.26, 0.6), Color(0.62, 0.12, 0.1),
]

var _vp: SubViewport
var _cam: Camera3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_vp = SubViewport.new()
	_vp.size = Vector2i(1600, 900)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var env := WorldEnvironment.new()
	env.environment = load(ENV) as Environment
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	_vp.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(30, 0.1, 30)
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.42, 0.43, 0.44)
	plane.material = grey
	ground.mesh = plane
	ground.position.y = -0.05
	_vp.add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 32.0
	_vp.add_child(_cam)

	var bodies: Array[Node3D] = []
	var drivers: Array[CharacterAnimDriver] = []
	var states: Array[CharacterAnimState] = []
	for i in LOADOUTS.size():
		var body := (load(BODY) as PackedScene).instantiate() as Node3D
		var source := body.get_node_or_null(^"CharacterAnimSource")
		if source != null:
			source.set(&"enabled", false)
		body.position = Vector3((i - 2) * 0.95, 0, 0)
		body.rotation.y = deg_to_rad(205)
		_vp.add_child(body)
		ArmorLoadout.apply(body, LOADOUTS[i])
		PlayerColor.apply(body, COLORS[i])
		var driver := body.get_node(^"CharacterAnimDriver") as CharacterAnimDriver
		var state := CharacterAnimState.new()
		state.weapon_type = CharacterAnimState.WeaponType.RIFLE
		state.weapon_model = CharacterAnimState.WeaponModel.RIFLE
		state.holster_type = CharacterAnimState.WeaponType.PISTOL
		state.holster_model = CharacterAnimState.WeaponModel.PISTOL
		state.on_floor = true
		driver.reset_baseline()
		bodies.append(body)
		drivers.append(driver)
		states.append(state)
	# The bodies face +Z (turned 205 deg from -Z), so the front camera sits on +Z.
	_cam.look_at_from_position(Vector3(0, 1.3, 7.2), Vector3(0, 0.9, 0))
	await _settle(drivers, states, 40)
	await _shot("lineup_front")
	_cam.look_at_from_position(Vector3(4.5, 1.5, 5.5), Vector3(0, 0.9, 0))
	await _shot("lineup_q34")
	_cam.look_at_from_position(Vector3(-3.5, 1.6, -6.5), Vector3(0, 0.9, 0))
	await _shot("lineup_back")

	# Poses on the default loadout (the others hidden).
	for i in range(1, bodies.size()):
		bodies[i].visible = false
	var hero := bodies[0]
	hero.position = Vector3.ZERO
	var st := states[0]
	_cam.fov = 28.0
	st.velocity = Vector3(0, 0, -4.0).rotated(Vector3.UP, hero.rotation.y)
	await _settle(drivers.slice(0, 1), states.slice(0, 1), 18)
	_cam.look_at_from_position(Vector3(3.6, 1.2, 2.6), Vector3(0, 0.85, 0))
	await _shot("pose_run")
	st.velocity = Vector3.ZERO
	st.crouched = true
	await _settle(drivers.slice(0, 1), states.slice(0, 1), 40)
	await _shot("pose_crouch")
	st.crouched = false
	st.aim_pitch = deg_to_rad(-45)
	await _settle(drivers.slice(0, 1), states.slice(0, 1), 40)
	await _shot("pose_aim_down")
	st.aim_pitch = deg_to_rad(40)
	await _settle(drivers.slice(0, 1), states.slice(0, 1), 40)
	_cam.look_at_from_position(Vector3(2.2, 1.4, 2.9), Vector3(0, 1.1, 0))
	await _shot("pose_aim_up")
	print("HOSPITALLER_RENDER DONE")
	quit(0)


func _settle(drivers: Array, states: Array, frames: int) -> void:
	for f in frames:
		for i in drivers.size():
			(drivers[i] as CharacterAnimDriver).apply_state(states[i])
		await physics_frame
		await process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, shot_name])
