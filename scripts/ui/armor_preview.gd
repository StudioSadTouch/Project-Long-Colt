class_name ArmorPreview
extends SubViewportContainer
## Main menu armor preview: the real player body (player_body.tscn, idle, rifle in hand) on a
## turntable in its own World3D, tinted through PlayerColor.apply exactly like in a match.
## Spins slowly; drag with the mouse (or hold left/right on a pad while it has focus) to turn
## it. Built in code like the rest of the menu.

const BODY_SCENE := preload("res://scenes/characters/player_body.tscn")
const SPIN_SPEED := 0.45  # rad/s while idle
const DRAG_SPEED := 0.012  # rad per pixel
const PAD_SPEED := 2.5  # rad/s
## Seconds after a manual turn before the idle spin resumes.
const RESUME_DELAY := 2.0

var _stage: Node3D
var _pivot: Node3D
var _body: Node3D
var _driver: CharacterAnimDriver
var _state := CharacterAnimState.new()
var _dragging := false
var _idle_left: float = 0.0
var _color: Color = PlayerColor.default_color()
var _visor: Color = PlayerColor.default_visor()


func _init() -> void:
	stretch = true
	custom_minimum_size = Vector2(440, 600)
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)

	_stage = Node3D.new()
	_stage.name = "Stage"
	viewport.add_child(_stage)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.68)
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_stage.add_child(world_env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 35, 0)
	key.light_energy = 1.0
	key.light_color = Color(1, 0.95, 0.88)
	key.shadow_enabled = true
	_stage.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-15, 200, 0)
	rim.light_energy = 0.6
	rim.light_color = MenuTheme.RIM
	_stage.add_child(rim)

	var plinth := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.6
	disc.bottom_radius = 0.64
	disc.height = 0.06
	plinth.mesh = disc
	plinth.position.y = -0.03
	var plinth_mat := StandardMaterial3D.new()
	plinth_mat.albedo_color = MenuTheme.PANEL.lightened(0.15)
	plinth_mat.roughness = 0.8
	plinth.material_override = plinth_mat
	_stage.add_child(plinth)

	_pivot = Node3D.new()
	_stage.add_child(_pivot)
	_body = BODY_SCENE.instantiate() as Node3D
	# No gameplay body to sample: we feed the driver ourselves (as character_anim_preview does).
	var source := _body.get_node_or_null(^"CharacterAnimSource")
	if source != null:
		source.set(&"enabled", false)
	_pivot.add_child(_body)
	_driver = _body.get_node_or_null(^"CharacterAnimDriver") as CharacterAnimDriver
	_state.weapon_type = CharacterAnimState.WeaponType.RIFLE
	_state.holster_type = CharacterAnimState.WeaponType.PISTOL
	_state.on_floor = true
	if _driver != null:
		_driver.reset_baseline()

	var camera := Camera3D.new()
	camera.fov = 30.0
	_stage.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 1.25, 3.9), Vector3(0.0, 0.95, 0.0))
	camera.current = true

	# The model faces -Z and the camera sits on +Z: turn it round, three-quarter on.
	_pivot.rotation.y = deg_to_rad(155.0)
	set_color(_color)
	set_visor_color(_visor)


## Tint the preview body (call on every swatch / picker change). Safe before _ready.
func set_color(color: Color) -> void:
	_color = color
	if _body != null:
		PlayerColor.apply(_body, color)


## Tint the preview visor. Safe before _ready.
func set_visor_color(color: Color) -> void:
	_visor = color
	if _body != null:
		PlayerColor.apply_visor(_body, color)


func _process(delta: float) -> void:
	if _pivot == null:
		return
	var turn := 0.0
	if has_focus():
		turn = Input.get_axis(&"ui_left", &"ui_right")
	if absf(turn) > 0.1:
		_pivot.rotation.y += turn * PAD_SPEED * delta
		_idle_left = RESUME_DELAY
	elif _dragging:
		_idle_left = RESUME_DELAY
	elif _idle_left > 0.0:
		_idle_left -= delta
	else:
		_pivot.rotation.y += SPIN_SPEED * delta


func _physics_process(_delta: float) -> void:
	if _driver != null and is_visible_in_tree():
		_driver.apply_state(_state)


func _gui_input(event: InputEvent) -> void:
	# Left/right turn the body (_process) instead of moving focus; up/down still navigate.
	if event.is_action(&"ui_left") or event.is_action(&"ui_right"):
		accept_event()
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		_dragging = button.pressed
		if button.pressed:
			grab_focus()
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		_pivot.rotation.y += motion.relative.x * DRAG_SPEED
		accept_event()
