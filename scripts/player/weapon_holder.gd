class_name WeaponHolder
extends Node3D
## Two weapon slots, Halo style. No dual-wield.
## Lives under the player camera so view models follow aim.

signal active_weapon_changed(weapon: Weapon)

const SLOT_COUNT := 2

@export var starting_weapons: Array[PackedScene] = []

var slots: Array[Weapon] = []
var active_index: int = 0

var _player: Player
var _melee_left: float = 0.0
var _camera: Camera3D


func _ready() -> void:
	_camera = get_parent() as Camera3D
	_player = owner as Player
	slots.resize(SLOT_COUNT)
	for i in mini(starting_weapons.size(), SLOT_COUNT):
		if starting_weapons[i] != null:
			_install(starting_weapons[i].instantiate() as Weapon, i)
	# Equip exactly once at startup.
	_equip(_first_filled(0))


func get_active() -> Weapon:
	if slots.is_empty():
		return null
	return slots[active_index]


## Puts weapon in slot (or the active slot) and returns whatever it replaced, already detached.
func give_weapon(weapon: Weapon, slot: int = -1) -> Weapon:
	if weapon == null:
		return null
	if slot < 0:
		slot = active_index if slots[active_index] != null else _first_empty()
	var old := _install(weapon, slot)
	if slot == active_index:
		_equip(slot)
	return old


func switch_weapon() -> void:
	var other := (active_index + 1) % SLOT_COUNT
	if slots[other] != null:
		_equip(other)


func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled():
		return
	var weapon := get_active()
	if (
		event.is_action_pressed("action_weapon_switch")
		or event.is_action_pressed("action_weapon_next")
		or event.is_action_pressed("action_weapon_prev")
	):
		switch_weapon()
	elif event.is_action_pressed("action_weapon_1") and slots[0] != null:
		_equip(0)
	elif event.is_action_pressed("action_weapon_2") and slots[1] != null:
		_equip(1)
	elif weapon == null:
		return
	elif event.is_action_pressed("action_fire"):
		weapon.trigger(true, true)
	elif event.is_action_released("action_fire"):
		weapon.release_trigger()
	elif event.is_action_pressed("action_alt_fire"):
		weapon.secondary_pressed()
	elif event.is_action_pressed("action_reload"):
		weapon.reload()
	elif event.is_action_pressed("action_melee") and _melee_left <= 0.0 and weapon.data != null:
		_melee_left = weapon.data.melee_cooldown
		weapon.melee()


func _physics_process(delta: float) -> void:
	_melee_left = maxf(_melee_left - delta, 0.0)
	var weapon := get_active()
	if weapon != null:
		if _input_enabled() and Input.is_action_pressed("action_fire"):
			weapon.trigger(false, true)
		else:
			weapon.release_trigger()
	if _player != null:
		_player.view_kick = weapon.get_recoil() if weapon != null else Vector2.ZERO
	_update_zoom_fov(delta)


func _input_enabled() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or DisplayServer.get_name() == "headless"


## Swaps weapon into slot without equipping. Returns the detached previous weapon.
func _install(weapon: Weapon, slot: int) -> Weapon:
	var old := slots[slot]
	if old != null:
		old.holster()
		if old.zoom_changed.is_connected(_on_zoom_changed):
			old.zoom_changed.disconnect(_on_zoom_changed)
		remove_child(old)
	weapon.camera = _camera
	weapon.player = _player
	add_child(weapon)
	weapon.zoom_changed.connect(_on_zoom_changed)
	slots[slot] = weapon
	weapon.holster()
	return old


func _equip(index: int) -> void:
	if index < 0 or slots[index] == null:
		return
	var current := get_active()
	if current != null and index != active_index:
		current.holster()
	active_index = index
	slots[index].equip()
	active_weapon_changed.emit(slots[index])


func _on_zoom_changed(_zoomed: bool) -> void:
	if _player == null:
		return
	var weapon := get_active()
	var zoomed := weapon != null and weapon.data != null and weapon.zoomed
	# A scale, not a write to mouse_sensitivity, so runtime settings changes survive zoom.
	_player.look_sensitivity_scale = weapon.data.zoom_sensitivity if zoomed else 1.0


func _update_zoom_fov(delta: float) -> void:
	if _camera == null or _player == null:
		return
	var weapon := get_active()
	var target := _player.fov
	var blend_time := 0.1
	if weapon != null and weapon.data == null:
		weapon = null
	if weapon != null:
		blend_time = maxf(weapon.data.zoom_time, 0.001)
		if weapon.zoomed:
			target = weapon.data.zoom_fov
	var step := absf(_player.fov - (weapon.data.zoom_fov if weapon != null else _player.fov))
	_camera.fov = move_toward(_camera.fov, target, maxf(step, 1.0) / blend_time * delta)


func _first_filled(start: int) -> int:
	for i in SLOT_COUNT:
		var index := (start + i) % SLOT_COUNT
		if slots[index] != null:
			return index
	return -1


func _first_empty() -> int:
	for i in SLOT_COUNT:
		if slots[i] == null:
			return i
	return active_index
