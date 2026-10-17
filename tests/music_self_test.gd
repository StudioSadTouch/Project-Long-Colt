extends SceneTree
## Sanctuary OS catalog loads, and menu / pause / match levels stay distinct. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/music_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load("res://scripts/audio/music.gd") as GDScript
	if script == null:
		push_error("music.gd failed to load")
		quit(1)
		return
	var paths: PackedStringArray = script.call(&"track_paths")
	var titles: PackedStringArray = script.call(&"track_titles")
	if paths.size() != 12 or titles.size() != paths.size():
		push_error("expected 12 tracks, got %d paths and %d titles" % [paths.size(), titles.size()])
		_failed = true
	for i in paths.size():
		_check_track(str(paths[i]), str(titles[i]))
	_expect_level(script, true, false, -8.0, "menu")
	_expect_level(script, true, true, -8.0, "menu keeps music while captured")
	_expect_level(script, false, false, -8.0, "pause and game over")
	_expect_level(script, false, true, -20.0, "live match ducks")
	var music := get_root().get_node_or_null(^"Music")
	if music == null:
		push_error("Music autoload is missing")
		_failed = true
		_finish()
		return
	create_timer(0.6).timeout.connect(_check_playing.bind(music))


func _check_track(path: String, title: String) -> void:
	var stream := load(path) as AudioStream
	var seconds := stream.get_length() if stream != null else 0.0
	print("%s (%s) length=%.1f" % [path.get_file(), title, seconds])
	if title == "":
		push_error("%s has an empty title" % path)
		_failed = true
	if seconds < 60.0 or seconds > 420.0:
		push_error("%s length %.1f is outside 60..420" % [path, seconds])
		_failed = true


func _expect_level(
	script: GDScript, on_menu: bool, captured: bool, expected: float, label: String
) -> void:
	var got: float = script.call(&"level_db", on_menu, captured)
	print("%s -> %.1f" % [label, got])
	if not is_equal_approx(got, expected):
		push_error("%s: got %.1f, expected %.1f" % [label, got, expected])
		_failed = true


func _check_playing(music: Node) -> void:
	var playing: bool = music.call(&"is_playing")
	var now := str(music.get(&"title"))
	print("playing=%s title=%s" % [playing, now])
	if not playing:
		push_error("Music autoload did not start playback")
		_failed = true
	if now == "":
		push_error("Music autoload has no track title")
		_failed = true
	_finish()


func _finish() -> void:
	if _failed:
		quit(1)
		return
	print("MUSIC_SELF_TEST PASS")
	quit(0)
