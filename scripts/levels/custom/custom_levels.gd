class_name CustomLevels
extends RefCounted
## Custom levels as maps: their ids, where a match gets its level data, and the editor's
## playtest round trip. Static only (survives scene changes).
##   map id     "custom:<file name>" for a saved level; PLAYTEST_ID for the editor's playtest
##   data_for   the level a custom arena builds: the playtest level, a level a host sent us
##              (cache), or the file
##   playtest   begin_playtest() keeps the level and the editor's view; the arena plays it;
##              return_to_editor() reloads the editor, which takes the view back

const PREFIX := "custom:"
const PLAYTEST_ID := "custom:__playtest__"
const ARENA_SCENE := "res://scenes/main/arena_custom.tscn"
const EDITOR_SCENE := "res://scenes/editor/level_editor.tscn"

## Level data per map id, from a host (a client has no file for it).
static var cache: Dictionary = {}
static var playtest_active: bool = false
static var _playtest_level: Dictionary = {}
## What the editor needs back after a playtest: level, view, name, selection.
static var _editor_state: Dictionary = {}
## Playtest options: bots to spawn (rules come with the match), and where the player starts
## (a Transform3D; null = at a spawn point).
static var playtest_bots: int = 0
static var playtest_start: Variant = null


static func is_custom(map_id: String) -> bool:
	return map_id.begins_with(PREFIX)


static func map_id(level_name: String) -> String:
	return PREFIX + level_name


static func level_name_of(map_id: String) -> String:
	if map_id == PLAYTEST_ID:
		return "Playtest"
	return map_id.trim_prefix(PREFIX)


## A custom map we can play: the playtest, a cached download, or a level file.
static func exists(map_id: String) -> bool:
	if not is_custom(map_id):
		return false
	if map_id == PLAYTEST_ID:
		return playtest_active
	return cache.has(map_id) or LevelData.path_of(level_name_of(map_id)) != ""


## Saved custom levels as MapList entries ({id, name, arena}).
static func map_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for level_name in LevelData.list_levels():
		out.append({"id": map_id(level_name), "name": level_name.replace("_", " "), "arena": ARENA_SCENE})
	return out


## The level a custom arena should build ({} if none).
static func data_for(map_id: String) -> Dictionary:
	if map_id == PLAYTEST_ID:
		return _playtest_level
	if cache.has(map_id):
		return cache[map_id]
	return LevelData.load_level(level_name_of(map_id))


## The level's JSON text, for a host to send to clients ("" if unknown).
static func text_for(map_id: String) -> String:
	var data := data_for(map_id)
	return LevelData.to_text(data) if not data.is_empty() else ""


## A host sent us this level.
static func store_download(map_id: String, text: String) -> bool:
	var data := LevelData.parse(text)
	if data.is_empty():
		return false
	cache[map_id] = data
	return true


static func begin_playtest(
	level: Dictionary, editor_state: Dictionary, bots: int, start: Variant = null
) -> void:
	playtest_active = true
	_playtest_level = level.duplicate(true)
	_editor_state = editor_state.duplicate(true)
	playtest_bots = bots
	playtest_start = start


## The editor's state from before the playtest (once), or {}.
static func take_editor_state() -> Dictionary:
	var state := _editor_state
	_editor_state = {}
	return state


## Leaves the playtest match and reopens the editor.
static func return_to_editor(tree: SceneTree) -> void:
	playtest_active = false
	var net := tree.root.get_node_or_null(^"Net")
	if net != null:
		net.call(&"leave")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	tree.change_scene_to_file.call_deferred(EDITOR_SCENE)
