extends Node3D
## Animation preview / playtest bench (no gameplay). Runs the body scene's driver from a fake
## CharacterAnimState. Keys: 1 idle, 2 walk, 3 run, 4 crouch, 5 slide, 6 jump, 7 fire,
## 8 reload, 9 melee, 0 switch, F flinch, K die (cycles direction), R respawn,
## W pistol/rifle, arrows: move direction / aim pitch. Q/E turn the body.

@export var body: Node3D

var state := CharacterAnimState.new()
var _driver: CharacterAnimDriver
var _speed: float = 0.0
var _dir: Vector2 = Vector2(0, 1)
var _air_time: float = 0.0


func _ready() -> void:
	if body == null:
		return
	_driver = body.get_node_or_null(^"CharacterAnimDriver") as CharacterAnimDriver
	var source := body.get_node_or_null(^"CharacterAnimSource")
	if source != null:
		source.set(&"enabled", false)
	state.weapon_type = CharacterAnimState.WeaponType.RIFLE
	state.holster_type = CharacterAnimState.WeaponType.PISTOL
	if _driver != null:
		_driver.reset_baseline()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1:
			_speed = 0.0
			state.crouched = false
		KEY_2:
			_speed = 3.5
		KEY_3:
			_speed = 7.5
		KEY_4:
			state.crouched = not state.crouched
		KEY_5:
			state.sliding = not state.sliding
		KEY_6:
			_air_time = 0.8
		KEY_7:
			state.fire_seq = CharacterAnimState.bump(state.fire_seq)
		KEY_8:
			_action(CharacterAnimState.Action.RELOAD, 0.0)
		KEY_9:
			_action(CharacterAnimState.Action.MELEE, 0.0)
		KEY_0:
			var old := state.weapon_type
			state.weapon_type = state.holster_type
			state.holster_type = old
			_action(CharacterAnimState.Action.SWITCH, 0.35)
		KEY_F:
			state.flinch_dir = (state.flinch_dir + 1) % 4
			state.flinch_seq = CharacterAnimState.bump(state.flinch_seq)
		KEY_K:
			state.death_dir = (state.death_dir + 1) % 4
			state.dead = true
			state.death_seq = CharacterAnimState.bump(state.death_seq)
		KEY_R:
			state.dead = false
		KEY_W:
			var tmp := state.weapon_type
			state.weapon_type = state.holster_type
			state.holster_type = tmp
		KEY_UP:
			state.aim_pitch = clampf(state.aim_pitch + deg_to_rad(15), -1.4, 1.4)
		KEY_DOWN:
			state.aim_pitch = clampf(state.aim_pitch - deg_to_rad(15), -1.4, 1.4)
		KEY_LEFT:
			_dir = _dir.rotated(-PI / 4)
		KEY_RIGHT:
			_dir = _dir.rotated(PI / 4)
		KEY_Q:
			body.rotation.y += PI / 8
		KEY_E:
			body.rotation.y -= PI / 8


func _action(action: int, duration: float) -> void:
	state.action = action
	state.action_duration = duration
	state.action_seq = CharacterAnimState.bump(state.action_seq)


func _physics_process(delta: float) -> void:
	if _driver == null:
		return
	var local := Vector3(_dir.x, 0, -_dir.y) * _speed
	state.yaw = body.rotation.y
	state.velocity = Basis(Vector3.UP, state.yaw) * local
	if _air_time > 0.0:
		_air_time -= delta
		state.on_floor = _air_time <= 0.0
		state.velocity.y = 4.0 if _air_time > 0.6 else -4.0
	else:
		state.on_floor = true
	_driver.apply_state(state)
