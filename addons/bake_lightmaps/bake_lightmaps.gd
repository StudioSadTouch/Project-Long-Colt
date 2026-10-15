@tool
extends EditorPlugin
## Temporary editor driver. Bakes only when LONG_COLT_BAKE_LIGHTMAPS=1, then quits.
## Delete this addon after the bake. A normal editor launch does nothing.

const SCENES: PackedStringArray = PackedStringArray([
	"res://scenes/main/arena_lockout.tscn",
	"res://scenes/main/main_lockout.tscn",
	"res://scenes/main/arena_headlong.tscn",
	"res://scenes/main/main_headlong.tscn",
])

const STATUS_PATH: String = "/tmp/long_colt_lightmap_bake.status"

var _index: int = 0

func _enter_tree() -> void:
	if OS.get_environment("LONG_COLT_BAKE_LIGHTMAPS") != "1":
		return
	call_deferred("_run")

func _status(line: String) -> void:
	print(line)
	var f: FileAccess = FileAccess.open(STATUS_PATH, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(STATUS_PATH, FileAccess.WRITE)
	else:
		f.seek_end()
	if f == null:
		return
	f.store_line(line)
	f.flush()
	f.close()

func _fail(reason: String) -> void:
	_status("FAILED " + reason)
	get_tree().quit(1)

func _run() -> void:
	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().process_frame
	await get_tree().process_frame
	await _bake_next()

func _bake_next() -> void:
	if _index >= SCENES.size():
		# Leave the editor on the scene it was already using.
		EditorInterface.open_scene_from_path("res://scenes/main/main.tscn")
		_status("LIGHTMAP_BAKE_ALL_DONE")
		get_tree().quit(0)
		return
	var scene_path: String = SCENES[_index]
	_status("LIGHTMAP_BAKE_OPEN " + scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	await get_tree().process_frame
	await get_tree().process_frame
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != scene_path:
		_fail("edited scene is not " + scene_path)
		return
	var lightmap: LightmapGI = root.get_node_or_null(^"LightmapGI") as LightmapGI
	if lightmap == null:
		_fail("no LightmapGI in " + scene_path)
		return
	EditorInterface.edit_node(lightmap)
	await get_tree().process_frame
	var found: Array = EditorInterface.get_base_control().find_children("", "LightmapGIEditorPlugin", true, false)
	if found.is_empty():
		_fail("LightmapGIEditorPlugin missing")
		return
	var plugin: Node = found[0] as Node
	plugin.call("_bake")
	var dialog: Node = null
	for _frame in 30:
		dialog = _lightmap_dialog()
		if dialog != null:
			break
		await get_tree().process_frame
	if dialog == null:
		var warning: String = _visible_warning()
		if warning.is_empty():
			_fail("lightmap save dialog missing for " + scene_path)
		else:
			_fail(scene_path + " " + warning)
		return
	var save_path: String = str(dialog.get("current_path"))
	if save_path.is_empty() or not save_path.ends_with(".lmbake"):
		save_path = scene_path.get_basename() + ".lmbake"
	_status("LIGHTMAP_BAKE_START " + save_path)
	dialog.emit_signal("file_selected", save_path)
	var data: LightmapGIData = lightmap.light_data
	if data == null:
		var warning2: String = _visible_warning()
		if warning2.is_empty():
			_fail("bake produced no light_data for " + scene_path)
		else:
			_fail(scene_path + " " + warning2)
		return
	var err: Error = EditorInterface.save_scene()
	if err != OK:
		_fail("save failed %s %s" % [scene_path, err])
		return
	_status("LIGHTMAP_BAKE_SCENE_DONE " + scene_path + " " + data.resource_path)
	_index += 1
	await _bake_next()

func _lightmap_dialog() -> Node:
	var dialogs: Array = EditorInterface.get_base_control().find_children("", "EditorFileDialog", true, false)
	for d in dialogs:
		var node: Node = d as Node
		if node == null:
			continue
		var title: String = str(node.get("title")).to_lower()
		if title.contains("lightmap"):
			return node
	return null

func _visible_warning() -> String:
	var dialogs: Array = EditorInterface.get_base_control().find_children("", "AcceptDialog", true, false)
	var text: String = ""
	for d in dialogs:
		var node: Node = d as Node
		if node == null or node is EditorFileDialog:
			continue
		if not bool(node.get("visible")):
			continue
		var body: String = str(node.get("dialog_text")).strip_edges()
		if body.is_empty():
			continue
		if not text.is_empty():
			text += " | "
		text += body
	return text
