class_name RadioTransmitter
extends LogicNodeBase
## Displays subtitles and plays radio voice-over audio for campaign storytelling.

signal on_transmission_started()
signal on_transmission_ended()

@export var callsign: String = "COMMAND"
@export var subtitle: String = "Proceed to the objective."
@export var audio_stream: AudioStream
@export var duration: float = 4.0

var _audio_player: AudioStreamPlayer
var _timer: SceneTreeTimer


func _init() -> void:
	super._init()
	display_name = "Radio Transmitter"


func get_node_color() -> Color:
	return Color(0.2, 0.85, 0.95, 0.85)


func get_input_actions() -> Array[String]:
	return ["transmit", "stop"]


func get_output_signals() -> Array[String]:
	return ["on_transmission_started", "on_transmission_ended"]


func transmit() -> void:
	on_transmission_started.emit()

	# Audio
	if audio_stream != null:
		if _audio_player == null:
			_audio_player = AudioStreamPlayer.new()
			_audio_player.bus = &"Voice" if AudioServer.get_bus_index(&"Voice") != -1 else &"Master"
			add_child(_audio_player)
		_audio_player.stream = audio_stream
		_audio_player.play()

	# Subtitle HUD display
	_show_hud_subtitle()

	var tree := get_tree()
	if tree != null:
		_timer = tree.create_timer(duration)
		_timer.timeout.connect(_on_duration_timeout)


func stop() -> void:
	if _audio_player != null and _audio_player.playing:
		_audio_player.stop()
	_hide_hud_subtitle()
	on_transmission_ended.emit()


func _on_duration_timeout() -> void:
	_hide_hud_subtitle()
	on_transmission_ended.emit()


func _show_hud_subtitle() -> void:
	var root := get_tree().root
	var hud_layer := root.get_node_or_null(^"RadioSubtitlesLayer") as CanvasLayer
	if hud_layer == null:
		hud_layer = CanvasLayer.new()
		hud_layer.name = "RadioSubtitlesLayer"
		hud_layer.layer = 100
		root.add_child(hud_layer)

	var label := hud_layer.get_node_or_null(^"SubtitleLabel") as RichTextLabel
	if label == null:
		label = RichTextLabel.new()
		label.name = "SubtitleLabel"
		label.anchor_left = 0.2
		label.anchor_right = 0.8
		label.anchor_top = 0.82
		label.anchor_bottom = 0.92
		label.bbcode_enabled = true
		label.fit_content = true
		label.scroll_active = false
		hud_layer.add_child(label)

	label.text = "[center][b][color=#3cd3f3][%s][/color][/b] %s[/center]" % [callsign, subtitle]
	label.visible = true


func _hide_hud_subtitle() -> void:
	var root := get_tree().root
	var label := root.get_node_or_null(^"RadioSubtitlesLayer/SubtitleLabel") as CanvasLayer
	if label != null:
		label.visible = false
