class_name ViewmodelMelee
extends Node
## Plays a weapon's first-person "melee" clip and keeps its hit frame on the damage tick.
## Child of a Weapon, next to ViewmodelReload. The clip is authored as:
##   0 .. hit_time          windup / anticipation
##   hit_time               impact frame (method track calls _on_hit_frame)
##   hit_time .. length     hit hold, recovery, last 3 frames = idle
## Windup is scaled to the time until the damage tick: melee_started's time_to_hit (or
## Weapon.get_melee_time_to_hit()). 0 means the hit already landed this frame, so the clip
## starts on the impact frame. Recovery is scaled so the clip ends with data.melee_cooldown,
## the same way reload clips scale to reload_time. melee_hit (or hit_confirmed with
## info.melee) is a safety snap: if damage lands before the impact frame, jump to it.
## Signals are connected defensively, so this works before and after the melee_started /
## melee_hit / melee_whiffed signals land on Weapon (falls back to melee_swung / hit_confirmed).

signal melee_event(event: StringName)
## A world-geometry impact (melee_hit_surface). surface is Weapon's hint ("" if none).
signal melee_surface_impact(surface: String)

## Lets the weapon's next physics tick deliver a lunge-arrival hit before calling a whiff.
const WHIFF_GRACE := 0.05

@export var animation_player: AnimationPlayer
@export var clip: StringName = &"melee"
## Authored impact time inside the clip, seconds. Must match the method key.
@export var hit_time: float = 0.1
## Windup used when the time to hit is unknown (old melee_swung, or a whiff).
@export var default_windup: float = 0.1
@export var impact_kick_deg: float = 1.0
@export var whiff_kick_deg: float = 0.0
## Kick for a wall/floor impact (melee_hit_surface): lighter than a body hit.
@export var surface_kick_deg: float = 0.5

var _weapon: Weapon
var _reload: Node
var _active: bool = false
var _impact_done: bool = false
var _hit_landed: bool = false
var _waiting_for_hit: bool = false
var _whiffed: bool = false
var _recovery_speed: float = 1.0
## Seconds the impact pose has waited with no lunge and no hit; past WHIFF_GRACE it's a whiff.
var _unresolved_for: float = 0.0


func _ready() -> void:
	_weapon = get_parent() as Weapon
	if _weapon == null or animation_player == null:
		push_error("%s needs a Weapon parent and an AnimationPlayer" % name)
		set_process(false)
		return
	_reload = _weapon.get_node_or_null(^"ViewmodelReload")
	if _weapon.has_signal(&"melee_started"):
		_weapon.connect(&"melee_started", _on_melee_started)
	elif _weapon.has_signal(&"melee_swung"):
		_weapon.connect(&"melee_swung", _on_melee_started)
	if _weapon.has_signal(&"melee_hit"):
		_weapon.connect(&"melee_hit", _on_melee_hit)
	elif _weapon.has_signal(&"hit_confirmed"):
		_weapon.connect(&"hit_confirmed", _on_hit_confirmed)
	if _weapon.has_signal(&"melee_hit_surface"):
		# LC Programmer: a wall/floor hit in reach plays the impact, not the whiff.
		_weapon.connect(&"melee_hit_surface", _on_melee_hit_surface)
	if _weapon.has_signal(&"melee_whiffed"):
		_weapon.connect(&"melee_whiffed", _on_melee_whiffed)
	_weapon.visibility_changed.connect(_on_visibility_changed)
	animation_player.animation_finished.connect(_on_animation_finished)
	set_process(false)


## Accepts melee_started(weapon, time_to_hit) and the old zero-argument melee_swung.
## time_to_hit: 0 = in reach (hit lands this frame), > 0 = lunge arrival, < 0 = whiff (nothing
## in reach; play the default windup). NAN = not passed (melee_swung): ask the weapon if it can.
func _on_melee_started(_w: Object = null, time_to_hit: float = NAN) -> void:
	if _weapon.data == null or not animation_player.has_animation(clip):
		return
	if is_nan(time_to_hit):
		time_to_hit = -1.0
		if _weapon.has_method(&"get_melee_time_to_hit"):
			time_to_hit = _weapon.call(&"get_melee_time_to_hit")
	var length := animation_player.get_animation(clip).length
	var cooldown := maxf(_weapon.data.melee_cooldown, hit_time + 0.05)
	_active = true
	_impact_done = false
	_hit_landed = false
	_waiting_for_hit = false
	_whiffed = false
	_unresolved_for = 0.0
	_event(&"sfx_melee_swing")
	animation_player.speed_scale = 1.0
	animation_player.play(clip, 0.0, 1.0)
	if time_to_hit == 0.0:
		# In reach: damage lands this same frame. Start on the impact pose and let melee_hit
		# (or melee_whiffed / the whiff grace) decide impact vs whiff.
		_recovery_speed = (length - hit_time) / cooldown
		animation_player.seek(hit_time, true)
		animation_player.speed_scale = 0.0
		_waiting_for_hit = true
	else:
		var windup := time_to_hit if time_to_hit > 0.0 else default_windup
		_recovery_speed = (length - hit_time) / maxf(cooldown - windup, 0.05)
		animation_player.seek(0.0, true)
		animation_player.speed_scale = hit_time / maxf(windup, 0.001)
	set_process(true)


func _process(delta: float) -> void:
	if not _active:
		set_process(false)
		return
	if animation_player.current_animation != clip:
		# Something else (a reload) took over the player.
		_end()
		return
	if _waiting_for_hit and not _is_lunging():
		_unresolved_for += delta
		if _unresolved_for >= WHIFF_GRACE:
			# Lunge ended (or never started) without contact: finish as a whiff.
			_impact(false)
	else:
		_unresolved_for = 0.0


## Method-track key at hit_time.
func _on_hit_frame() -> void:
	if not _active or _impact_done:
		return
	if _hit_landed:
		_impact(true)
	elif _whiffed:
		_impact(false)
	elif _is_lunging():
		# Still closing distance: hold the impact pose until contact or the lunge ends.
		_waiting_for_hit = true
		animation_player.speed_scale = 0.0
	else:
		_impact(false)


func _on_melee_hit(_target: Object = null, _info: Dictionary = {}) -> void:
	_land_hit(impact_kick_deg, "")


## melee_hit_surface(position, normal, collider, info): a wall or floor in reach.
func _on_melee_hit_surface(
	_position: Vector3, _normal: Vector3, _collider: Object, info: Dictionary
) -> void:
	_land_hit(surface_kick_deg, str(info.get("surface", "")), true)


## Shared by body and surface hits: snap to the impact frame if early, then impact once.
func _land_hit(kick_deg: float, surface: String, is_surface: bool = false) -> void:
	if not _active:
		return
	_hit_landed = true
	if _impact_done:
		return
	var pos := animation_player.current_animation_position
	if animation_player.current_animation == clip and pos < hit_time:
		animation_player.seek(hit_time, true)
	_impact(true, kick_deg, surface, is_surface)


func _on_hit_confirmed(target: Object, info: Dictionary) -> void:
	if info.get("melee", false):
		_on_melee_hit(target, info)


## melee_whiffed(weapon). Before the impact frame it only marks the swing; the frame
## then plays the whiff.
func _on_melee_whiffed(_w: Object = null) -> void:
	if not _active or _impact_done:
		return
	_whiffed = true
	if _waiting_for_hit:
		_impact(false)


func _impact(
	landed: bool, kick_deg: float = -1.0, surface: String = "", is_surface: bool = false
) -> void:
	if _impact_done:
		return
	_impact_done = true
	_waiting_for_hit = false
	if landed:
		if kick_deg < 0.0:
			kick_deg = impact_kick_deg
		if is_surface:
			melee_surface_impact.emit(surface)
		_event(_impact_event(surface), kick_deg)
	else:
		_event(&"sfx_melee_whiff", whiff_kick_deg)
	animation_player.speed_scale = _recovery_speed


func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == clip and _active:
		_end()
		if animation_player.has_animation(&"idle"):
			animation_player.play(&"idle", 0.0)


func _on_visibility_changed() -> void:
	if _active and not _weapon.visible:
		_end()
		animation_player.stop()
		if animation_player.has_animation(&"idle"):
			animation_player.play(&"idle", 0.0)
			animation_player.seek(0.0, true)


func _end() -> void:
	_active = false
	_waiting_for_hit = false
	animation_player.speed_scale = 1.0
	set_process(false)


func _is_lunging() -> bool:
	var p := _weapon.player
	return p != null and p.has_method(&"is_lunging") and p.is_lunging()


## sfx_melee_impact_<surface> when ViewmodelReload.sounds has that key, else sfx_melee_impact.
## melee_event reports whichever key was used; the raw hint also rides on melee_surface_impact.
func _impact_event(surface: String) -> StringName:
	if surface != "" and _reload != null:
		var sounds = _reload.get(&"sounds")
		var key := StringName("sfx_melee_impact_" + surface)
		if sounds is Dictionary and sounds.has(key):
			return key
	return &"sfx_melee_impact"


## sfx/kick routing shared with the reload clips: ViewmodelReload._anim_event plays the stream
## from its `sounds` map and applies the kick. Also called by the clip's method track.
func _anim_event(event: StringName, kick_deg: float = 0.0) -> void:
	_event(event, kick_deg)


func _event(event: StringName, kick_deg: float = 0.0) -> void:
	melee_event.emit(event)
	if _reload != null and _reload.has_method(&"_anim_event"):
		_reload.call(&"_anim_event", event, kick_deg)
	elif kick_deg > 0.0 and _weapon.has_method(&"add_view_kick"):
		_weapon.add_view_kick(kick_deg)
