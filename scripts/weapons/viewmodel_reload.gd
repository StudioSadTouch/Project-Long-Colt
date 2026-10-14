class_name ViewmodelReload
extends Node
## Plays a weapon's first-person reload animations from its reload signals.
## Child of a Weapon. Expects an AnimationPlayer with "idle", "reload_empty", "reload_tactical"
## and "RESET". Playback speed is authored length / data.reload_time, so tuning reload_time
## retimes the animation. Ammo is NOT moved here: Weapon refills at data.reload_insert_fraction,
## and each reload animation keys its mag seat at that same fraction of its length.
## Reload clips call _anim_event(event, kick_deg) from a method track on contact frames
## (sfx_mag_release, sfx_mag_out, sfx_mag_drop, sfx_mag_pouch, sfx_mag_in, sfx_mag_seat,
## sfx_slide_release / sfx_bolt_release, sfx_regrip). Each one emits reload_event, plays the
## matching stream from `sounds` if one is assigned, and adds an additive camera kick if
## kick_deg > 0. No audio assets exist yet, so `sounds` ships empty.

signal reload_event(event: StringName)

@export var animation_player: AnimationPlayer
## Blend back to idle after a finished reload. Cancels snap with no blend.
@export var return_blend: float = 0.08
## Event name (e.g. &"sfx_mag_seat") -> AudioStream. Missing entries are silent.
@export var sounds: Dictionary = {}

var _weapon: Weapon
var _audio: AudioStreamPlayer


func _ready() -> void:
	_weapon = get_parent() as Weapon
	if _weapon == null or animation_player == null:
		push_error("%s needs a Weapon parent and an AnimationPlayer" % name)
		return
	_weapon.reload_started.connect(_on_reload_started)
	_weapon.reload_finished.connect(_on_reload_finished)
	_weapon.reload_cancelled.connect(_snap_to_idle)
	_audio = AudioStreamPlayer.new()
	_audio.max_polyphony = 4
	add_child(_audio)
	_snap_to_idle()


func _on_reload_started() -> void:
	if _weapon.data == null or _weapon.data.reload_time <= 0.0:
		return
	var anim_name := &"reload_empty" if _weapon.reload_empty else &"reload_tactical"
	if not animation_player.has_animation(anim_name):
		return
	var length := animation_player.get_animation(anim_name).length
	animation_player.speed_scale = 1.0
	animation_player.play(anim_name, 0.0, length / _weapon.data.reload_time)
	animation_player.seek(0.0, true)


func _on_reload_finished() -> void:
	if _is_melee_playing():
		return
	if animation_player.has_animation(&"idle"):
		animation_player.play(&"idle", return_blend)


## Hard stop: every animated node goes straight back to its rest pose.
## A melee that is already playing owns the pose (its clip keys every reload track), so a
## reload cancelled by that melee must not stomp it back to idle.
func _snap_to_idle() -> void:
	if _is_melee_playing():
		return
	animation_player.stop()
	animation_player.speed_scale = 1.0
	if animation_player.has_animation(&"RESET"):
		animation_player.play(&"RESET")
		animation_player.seek(0.0, true)
	if animation_player.has_animation(&"idle"):
		animation_player.play(&"idle", 0.0)
		animation_player.seek(0.0, true)


## Called by the reload clips' method track.
func _anim_event(event: StringName, kick_deg: float = 0.0) -> void:
	reload_event.emit(event)
	var stream: AudioStream = sounds.get(event)
	if stream != null and _audio != null:
		_audio.stream = stream
		_audio.play()
	if kick_deg > 0.0 and _weapon != null:
		_weapon.add_view_kick(kick_deg)


func _is_melee_playing() -> bool:
	return animation_player.is_playing() and animation_player.current_animation == "melee"
