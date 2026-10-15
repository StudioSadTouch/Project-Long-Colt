extends Node3D
## Boot steps and landings for any body that runs CharacterAnimDriver (player, bot, puppet).
## Plants come from the gait clock, so the sound lands on the same frames as the feet.
## 3D at the body origin (the feet). The local camera is about 2 m up, inside unit_size,
## so your own steps stay full while other bodies fall off across the arena.

## Fantozzi's Footsteps (stone, CC0), alternating left / right foot (assets/audio/SOURCES.txt).
const STEPS: Array[AudioStream] = [
	preload("res://assets/audio/foley/step_0.wav"),
	preload("res://assets/audio/foley/step_1.wav"),
	preload("res://assets/audio/foley/step_2.wav"),
	preload("res://assets/audio/foley/step_3.wav"),
	preload("res://assets/audio/foley/step_4.wav"),
	preload("res://assets/audio/foley/step_5.wav"),
]
const LAND := preload("res://assets/audio/foley/land.wav")
const VOICES := 3

var _voices: Array[AudioStreamPlayer3D] = []
var _cursor: int = 0
var _step: int = 0


func _ready() -> void:
	var driver := get_parent().get_node_or_null(^"CharacterAnimDriver") as CharacterAnimDriver
	if driver == null:
		push_error("%s: no CharacterAnimDriver on %s" % [name, get_parent().name])
		return
	driver.foot_contact.connect(_on_step)
	driver.foot_landed.connect(_on_land)
	for _i in VOICES:
		var voice := AudioStreamPlayer3D.new()
		voice.unit_size = 2.5
		voice.max_distance = 20.0
		if AudioServer.get_bus_index(&"Foley") >= 0:
			voice.bus = &"Foley"
		add_child(voice)
		_voices.append(voice)


func _on_step(speed: float, crouched: bool) -> void:
	var stream: AudioStream = STEPS[_step % STEPS.size()]
	_step += 1
	var loud := clampf((speed - 1.0) / 6.5, 0.0, 1.0)
	var db := lerpf(-16.0, -8.0, loud)
	if crouched:
		db -= 7.0
	_play(stream, db, randf_range(0.94, 1.06))


func _on_land(impact: float) -> void:
	var db := lerpf(-14.0, -5.0, clampf(impact / 8.0, 0.0, 1.0))
	_play(LAND, db, randf_range(0.92, 1.04))


func _play(stream: AudioStream, db: float, pitch: float) -> void:
	if _voices.is_empty() or stream == null:
		return
	var voice := _voices[_cursor]
	_cursor = (_cursor + 1) % _voices.size()
	voice.stream = stream
	voice.volume_db = db
	voice.pitch_scale = pitch
	voice.play()
