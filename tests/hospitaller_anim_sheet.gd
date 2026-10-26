extends SceneTree
## Animation review for the Hospitaller: drives the real player body (CharacterAnimDriver) through
## each scenario and writes one contact sheet per scenario to res://.hosp_render/anim_<name>.png:
## a row per sampled moment, side and three-quarter views. Needs a display:
## DISPLAY=:0 flatpak run org.godotengine.Godot --path . --script res://tests/hospitaller_anim_sheet.gd [-- loadout]

const BODY := "res://scenes/characters/player_body.tscn"
const OUT := "res://.hosp_render"
const TILE := Vector2i(420, 520)
## name: [setup callable name, frames between samples, samples]
const SCENARIOS := [
	["idle", 30, 2], ["run_f", 7, 4], ["run_l", 7, 3], ["run_b", 7, 3], ["crouch", 25, 2],
	["crouch_walk", 9, 3], ["aim_up", 25, 1], ["aim_down", 25, 1], ["reload", 12, 4],
	["melee", 6, 4], ["throw", 8, 3], ["jump", 6, 4], ["death", 14, 4], ["pistol", 20, 2],
	["sword", 20, 2], ["hammer", 20, 2],
]

var _vp: SubViewport
var _cam: Camera3D
var _body: Node3D
var _driver: CharacterAnimDriver
var _state: CharacterAnimState


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_vp = SubViewport.new()
	_vp.size = TILE
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.42, 0.44, 0.47)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.72, 0.75)
	env.environment.ambient_light_energy = 0.6
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.1
	_vp.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(20, 0.02, 20)
	ground.mesh = plane
	ground.position.y = -0.01
	_vp.add_child(ground)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 2.3
	_vp.add_child(_cam)
	var args := OS.get_cmdline_user_args()
	for sc in SCENARIOS:
		await _scenario(sc[0], sc[1], sc[2], ArmorLoadout.decode(args[0] if args.size() > 0 else ""))
	print("HOSPITALLER_ANIM_SHEET DONE")
	quit(0)


func _fresh(loadout: Dictionary) -> void:
	if _body != null:
		_body.queue_free()
		await process_frame
	_body = (load(BODY) as PackedScene).instantiate() as Node3D
	var source := _body.get_node_or_null(^"CharacterAnimSource")
	if source != null:
		source.set(&"enabled", false)
	_vp.add_child(_body)
	ArmorLoadout.apply(_body, loadout)
	_driver = _body.get_node(^"CharacterAnimDriver") as CharacterAnimDriver
	_state = CharacterAnimState.new()
	_state.weapon_type = CharacterAnimState.WeaponType.RIFLE
	_state.weapon_model = CharacterAnimState.WeaponModel.RIFLE
	_state.holster_type = CharacterAnimState.WeaponType.PISTOL
	_state.holster_model = CharacterAnimState.WeaponModel.PISTOL
	_state.on_floor = true
	_driver.reset_baseline()


func _setup(scenario: String) -> void:
	var s := _state
	match scenario:
		"run_f":
			s.velocity = Vector3(0, 0, -4.5)
		"run_l":
			s.velocity = Vector3(-4.5, 0, 0)
		"run_b":
			s.velocity = Vector3(0, 0, 4.0)
		"crouch":
			s.crouched = true
		"crouch_walk":
			s.crouched = true
			s.velocity = Vector3(0, 0, -2.0)
		"aim_up":
			s.aim_pitch = deg_to_rad(60)
		"aim_down":
			s.aim_pitch = deg_to_rad(-60)
		"reload":
			s.action = CharacterAnimState.Action.RELOAD
			s.action_duration = 1.6
			s.action_seq = CharacterAnimState.bump(s.action_seq)
		"melee":
			s.action = CharacterAnimState.Action.MELEE
			s.action_duration = 0.6
			s.action_seq = CharacterAnimState.bump(s.action_seq)
		"throw":
			s.action = CharacterAnimState.Action.THROW
			s.action_duration = 0.6
			s.action_seq = CharacterAnimState.bump(s.action_seq)
		"jump":
			s.on_floor = false
			s.velocity = Vector3(0, 4.0, -2.0)
		"death":
			s.dead = true
			s.death_seq = CharacterAnimState.bump(s.death_seq)
		"pistol":
			s.weapon_type = CharacterAnimState.WeaponType.PISTOL
			s.weapon_model = CharacterAnimState.WeaponModel.PISTOL
			s.holster_type = CharacterAnimState.WeaponType.RIFLE
			s.holster_model = CharacterAnimState.WeaponModel.RIFLE
		"sword":
			s.weapon_type = CharacterAnimState.WeaponType.SWORD
			s.weapon_model = CharacterAnimState.WeaponModel.SWORD
		"hammer":
			s.weapon_type = CharacterAnimState.WeaponType.HAMMER
			s.weapon_model = CharacterAnimState.WeaponModel.HAMMER


func _scenario(scenario: String, gap: int, samples: int, loadout: Dictionary) -> void:
	await _fresh(loadout)
	await _feed(12)
	_setup(scenario)
	var shots: Array[Image] = []
	for k in samples:
		await _feed(gap)
		for view in [Vector3(-3.0, 1.0, 0.0), Vector3(-2.3, 1.2, -2.3), Vector3(2.0, 1.3, -2.4)]:
			_cam.look_at_from_position(view + Vector3(0, 0.0, 0), Vector3(0, 0.9, 0))
			await RenderingServer.frame_post_draw
			shots.append(_vp.get_texture().get_image())
	var sheet := Image.create(TILE.x * 3, TILE.y * samples, false, shots[0].get_format())
	for i in shots.size():
		sheet.blit_rect(shots[i], Rect2i(Vector2i.ZERO, TILE), Vector2i((i % 3) * TILE.x, (i / 3) * TILE.y))
	sheet.save_png("%s/anim_%s.png" % [OUT, scenario])


func _feed(frames: int) -> void:
	for f in frames:
		_driver.apply_state(_state)
		await physics_frame
		await process_frame
