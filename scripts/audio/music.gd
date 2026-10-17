extends Node
## Sanctuary OS by Dusqk: the console-idle album, in album order, then it loops.
## Menu, pause, and game over play at menu level. A live match (mouse captured, off the menu)
## ducks it so gunfire stays in front. Two players crossfade the track change.

signal track_changed(title: String)

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const BUS := &"Music"
const MENU_DB := -8.0
const MATCH_DB := -20.0
const SILENT_DB := -80.0
const CROSSFADE_SEC := 2.5
## Live track moving between menu level and the match duck.
const LEVEL_DB_PER_SEC := 14.0
## Outgoing track leaving a crossfade, and the first fade-in from silence.
const OUT_DB_PER_SEC := 32.0
## Incoming track starts this far under the target so the overlap is a crossfade.
const CROSSFADE_START_DB := 24.0

const TRACKS: Array[String] = [
	"res://assets/audio/music/sanctuary_os.mp3",
	"res://assets/audio/music/sanctuary_01.mp3",
	"res://assets/audio/music/sanctuary_02.mp3",
	"res://assets/audio/music/sanctuary_03.mp3",
	"res://assets/audio/music/sanctuary_04.mp3",
	"res://assets/audio/music/sanctuary_05.mp3",
	"res://assets/audio/music/sanctuary_06.mp3",
	"res://assets/audio/music/sanctuary_07.mp3",
	"res://assets/audio/music/sanctuary_08.mp3",
	"res://assets/audio/music/sanctuary_09.mp3",
	"res://assets/audio/music/sanctuary_10.mp3",
	"res://assets/audio/music/sanctuary_11.mp3",
]
const TITLES: Array[String] = [
	"Sanctuary OS",
	"Sanctuary 1",
	"Sanctuary 2",
	"Sanctuary 3",
	"Sanctuary 4",
	"Sanctuary 5",
	"Sanctuary 6",
	"Sanctuary 7",
	"Sanctuary 8",
	"Sanctuary 9",
	"Sanctuary 10",
	"Sanctuary 11",
]

var title: String = ""
var track_index: int = 0

var _players: Array[AudioStreamPlayer] = []
var _active: int = 0
var _on_menu: bool = true
## Track index that already started its outgoing crossfade. Stops the overlap window
## from advancing the playlist on every frame.
var _crossfade_from: int = -1


static func track_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	paths.append_array(TRACKS)
	return paths


static func track_titles() -> PackedStringArray:
	var names := PackedStringArray()
	names.append_array(TITLES)
	return names


## Menu, pause, and game over (mouse free) stay at menu level. Captured mouse off-menu ducks.
static func level_db(on_menu: bool, mouse_captured: bool) -> float:
	if on_menu or not mouse_captured:
		return MENU_DB
	return MATCH_DB


func _ready() -> void:
	if DedicatedServer.requested():
		set_process(false)  # a dedicated server plays no music (and decodes none)
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in 2:
		var player := AudioStreamPlayer.new()
		player.name = "Bed%d" % i
		player.bus = BUS if AudioServer.get_bus_index(BUS) >= 0 else &"Master"
		player.volume_db = SILENT_DB
		player.finished.connect(_on_finished.bind(player))
		add_child(player)
		_players.append(player)
	_start(0, true)


func is_playing() -> bool:
	if _players.is_empty():
		return false
	return _players[_active].playing


func _process(delta: float) -> void:
	if _players.is_empty():
		return
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path != "":
		_on_menu = scene.scene_file_path == MENU_SCENE
	var target := level_db(_on_menu, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	var active := _players[_active]
	var idle := _players[1 - _active]
	var rate := OUT_DB_PER_SEC if active.volume_db < target - 20.0 else LEVEL_DB_PER_SEC
	active.volume_db = move_toward(active.volume_db, target, rate * delta)
	if idle.playing:
		idle.volume_db = move_toward(idle.volume_db, SILENT_DB, OUT_DB_PER_SEC * delta)
		if idle.volume_db <= SILENT_DB + 1.0:
			idle.stop()
			idle.stream = null
	_maybe_crossfade(active)


func _maybe_crossfade(active: AudioStreamPlayer) -> void:
	if _crossfade_from == track_index or not active.playing or active.stream == null:
		return
	var length := active.stream.get_length()
	if length <= CROSSFADE_SEC + 1.0:
		return
	var left := length - active.get_playback_position()
	if left > CROSSFADE_SEC:
		return
	_crossfade_from = track_index
	_start(wrapi(track_index + 1, 0, TRACKS.size()), false)


func _on_finished(player: AudioStreamPlayer) -> void:
	if _players.is_empty() or player != _players[_active]:
		return
	_start(wrapi(track_index + 1, 0, TRACKS.size()), true)


func _start(index: int, hard: bool) -> void:
	var stream := ResourceLoader.load(
		TRACKS[index], "", ResourceLoader.CACHE_MODE_IGNORE
	) as AudioStream
	if stream == null:
		push_warning("Music: missing %s" % TRACKS[index])
		return
	track_index = index
	var slot := _active if hard else 1 - _active
	var player := _players[slot]
	player.stream = stream
	if hard:
		player.volume_db = SILENT_DB
	else:
		var target := level_db(_on_menu, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
		player.volume_db = target - CROSSFADE_START_DB
		_active = slot
	player.play()
	title = TITLES[index]
	track_changed.emit(title)
