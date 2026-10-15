class_name WeaponFx
extends Node
## First-person presentation hooks for a Weapon: fire / cycle / charge / overheat sounds, a
## muzzle flash light, and emissive "glow" meshes that track heat and charge. Child of a Weapon,
## in group viewmodel_only (pickup visuals strip it). Reads only public Weapon signals and state,
## so it never changes gameplay. Every field is optional; missing streams are silent.

@export var fire_sound: AudioStream
## Played instead of fire_sound for a FireMode.CHARGE charged shot.
@export var charged_fire_sound: AudioStream
## Pump / bolt cycle, cycle_delay seconds after each shot (shotgun pump).
@export var cycle_sound: AudioStream
@export var cycle_delay: float = 0.25
## Looped-feel whine while charging (stopped on release).
@export var charge_sound: AudioStream
@export var overheat_sound: AudioStream
@export_range(-0.5, 0.5) var pitch_jitter: float = 0.04
@export var volume_db: float = -8.0
## OmniLight3D flashed on each shot.
@export var muzzle_light: OmniLight3D
@export var flash_time: float = 0.05
@export var flash_energy: float = 2.0
## Meshes whose material emission follows max(heat, charge). Their material is duplicated per
## instance so two copies of the gun don't share a glow.
@export var glow_meshes: Array[MeshInstance3D] = []
@export var glow_idle_energy: float = 0.4
@export var glow_max_energy: float = 6.0
@export var overheat_color: Color = Color(1.0, 0.35, 0.1)

var _weapon: Weapon
var _shot_audio: AudioStreamPlayer
var _loop_audio: AudioStreamPlayer
var _flash_left: float = 0.0
var _materials: Array[StandardMaterial3D] = []
var _base_colors: Array[Color] = []
var _charge_open: bool = false
var _was_overheated: bool = false


func _ready() -> void:
	_weapon = get_parent() as Weapon
	if _weapon == null:
		push_error("%s needs a Weapon parent" % name)
		set_process(false)
		return
	_shot_audio = _make_player(6)
	_loop_audio = _make_player(1)
	_weapon.fired.connect(_on_fired)
	_weapon.charge_started.connect(_on_charge_started)
	_weapon.charge_released.connect(_on_charge_released)
	_weapon.heat_changed.connect(_on_heat_changed)
	_arm_charge_loop()
	for mesh in glow_meshes:
		var source := mesh.get_active_material(0) as StandardMaterial3D if mesh != null else null
		if source == null:
			continue
		var material := source.duplicate() as StandardMaterial3D
		mesh.set_surface_override_material(0, material)
		_materials.append(material)
		_base_colors.append(material.emission)
	if muzzle_light != null:
		muzzle_light.visible = false


func _process(delta: float) -> void:
	if muzzle_light != null and _flash_left > 0.0:
		_flash_left -= delta
		muzzle_light.visible = _flash_left > 0.0 and not _scope_hides_flash()
	if _materials.is_empty():
		return
	var level := maxf(_weapon.heat, _weapon.charge)
	var energy := lerpf(glow_idle_energy, glow_max_energy, level)
	for i in _materials.size():
		var hot := _base_colors[i].lerp(overheat_color, _weapon.heat if _weapon.overheated else 0.0)
		_materials[i].emission = hot
		_materials[i].emission_energy_multiplier = energy


func _make_player(polyphony: int) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.max_polyphony = polyphony
	player.volume_db = volume_db
	if AudioServer.get_bus_index(&"Weapons") >= 0:
		player.bus = &"Weapons"
	add_child(player)
	return player


## The charge whine is one trimmed clip. Loop it here so the import sidecar can stay unlooped.
func _arm_charge_loop() -> void:
	var wav := charge_sound as AudioStreamWAV
	if wav != null:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD


func _play(stream: AudioStream) -> void:
	if stream == null or _shot_audio == null:
		return
	_shot_audio.stream = stream
	_shot_audio.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	_shot_audio.play()


## Weapon._fire_charged emits fired before charge_released(true), and a tap shot emits
## charge_released(false) before fired, so a fired that arrives while a charge is still open is
## the charged shot.
func _on_fired() -> void:
	var charged := _charge_open
	_charge_open = false
	_play(charged_fire_sound if charged and charged_fire_sound != null else fire_sound)
	if muzzle_light != null:
		muzzle_light.light_energy = flash_energy * (3.0 if charged else 1.0)
		muzzle_light.visible = not _scope_hides_flash()
		_flash_left = flash_time * (2.0 if charged else 1.0)
	if cycle_sound != null:
		get_tree().create_timer(cycle_delay, false).timeout.connect(_play.bind(cycle_sound))


## Local player scoped (WeaponHolder hid the viewmodel): no flash light, which would only glare
## on the scope overlay. Puppets and bots have no hiding holder, so their flash is unchanged.
func _scope_hides_flash() -> bool:
	var holder := _weapon.get_parent() as WeaponHolder
	return holder != null and holder.is_scope_hiding(_weapon)


func _on_charge_started() -> void:
	_charge_open = true
	if charge_sound != null:
		_loop_audio.stream = charge_sound
		_loop_audio.play()


func _on_charge_released(_charged: bool) -> void:
	_charge_open = false
	_loop_audio.stop()


func _on_heat_changed(_heat: float, overheated: bool) -> void:
	if overheated and not _was_overheated:
		_play(overheat_sound)
	_was_overheated = overheated
