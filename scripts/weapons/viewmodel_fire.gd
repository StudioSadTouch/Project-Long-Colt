class_name ViewmodelFire
extends Node
## Per-shot first-person mechanism animation: bolt / slide cycling, the shotgun's pump rack,
## the rocket leaving the tube. Child of a Weapon, next to ViewmodelReload / ViewmodelMelee.
## On `fired` it plays "fire", or "fire_empty" when that shot emptied the magazine (bolt or
## slide locks back: the pose reload_empty starts from). Clips are looked up bare first, then
## in the "fx" library (fx/fire) for weapons whose default library is hand-keyed in the scene.
## Never interrupts a reload or melee clip. Gun kick is ViewmodelMotion's job, not this one's.

@export var animation_player: AnimationPlayer

var _weapon: Weapon


func _ready() -> void:
	_weapon = get_parent() as Weapon
	if _weapon == null or animation_player == null:
		push_error("%s needs a Weapon parent and an AnimationPlayer" % name)
		return
	_weapon.fired.connect(_on_fired)


func _on_fired() -> void:
	if _busy():
		return
	var clip := &""
	if _weapon.magazine <= 0:
		clip = _find(&"fire_empty")
	if clip == &"":
		clip = _find(&"fire")
	if clip == &"":
		return
	animation_player.speed_scale = 1.0
	animation_player.play(clip, 0.0)
	animation_player.seek(0.0, true)  # automatic fire restarts the same clip every shot


## Reload and melee clips own the pose while they play.
func _busy() -> bool:
	if not animation_player.is_playing():
		return false
	var current := String(animation_player.current_animation)
	return current.begins_with("reload") or current == "melee"


func _find(clip: StringName) -> StringName:
	if animation_player.has_animation(clip):
		return clip
	var fx := StringName("fx/%s" % clip)
	if animation_player.has_animation(fx):
		return fx
	return &""
