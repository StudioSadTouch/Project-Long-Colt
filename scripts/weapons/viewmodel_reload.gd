class_name ViewmodelReload
extends Node
## Plays a weapon's first-person reload animations from its reload signals.
## Child of a Weapon. Expects an AnimationPlayer with "idle", "reload_empty", "reload_tactical"
## and "RESET". Playback speed is authored length / data.reload_time, so tuning reload_time
## retimes the animation. Ammo is NOT moved here: Weapon refills at data.reload_insert_fraction,
## and each reload animation keys its mag seat at that same fraction of its length.

@export var animation_player: AnimationPlayer
## Blend back to idle after a finished reload. Cancels snap with no blend.
@export var return_blend: float = 0.08

var _weapon: Weapon


func _ready() -> void:
	_weapon = get_parent() as Weapon
	if _weapon == null or animation_player == null:
		push_error("%s needs a Weapon parent and an AnimationPlayer" % name)
		return
	_weapon.reload_started.connect(_on_reload_started)
	_weapon.reload_finished.connect(_on_reload_finished)
	_weapon.reload_cancelled.connect(_snap_to_idle)
	_snap_to_idle()


func _on_reload_started() -> void:
	if _weapon.data == null or _weapon.data.reload_time <= 0.0:
		return
	var anim_name := &"reload_empty" if _weapon.reload_empty else &"reload_tactical"
	if not animation_player.has_animation(anim_name):
		return
	var length := animation_player.get_animation(anim_name).length
	animation_player.play(anim_name, 0.0, length / _weapon.data.reload_time)
	animation_player.seek(0.0, true)


func _on_reload_finished() -> void:
	if animation_player.has_animation(&"idle"):
		animation_player.play(&"idle", return_blend)


## Hard stop: every animated node goes straight back to its rest pose.
func _snap_to_idle() -> void:
	animation_player.stop()
	if animation_player.has_animation(&"RESET"):
		animation_player.play(&"RESET")
		animation_player.seek(0.0, true)
	if animation_player.has_animation(&"idle"):
		animation_player.play(&"idle", 0.0)
		animation_player.seek(0.0, true)
