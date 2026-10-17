class_name LevelEditor
extends Node3D
## Level Editor (scenes/editor/level_editor.tscn). Builds custom levels from LevelCatalog
## items: parametric geometry at any size, gameplay markers and volumes, and every game asset.
## The level is LevelData (JSON in user://custom_levels/); what you see is built by the same
## LevelWorld / LevelBuilder code a match uses, in editor mode.
##
## Controls (also in the bottom bar):
##   Fly        WASD, Q/E down/up, Shift faster, mouse wheel speed, hold RMB to look
##   Select     V or Esc: click object to select; Shift+LMB adds / removes; Ctrl+A all
##   Place      B or click catalog: LMB places (repeatable), R / Shift+R turns it,
##              Esc / V stops placing
##   Transform  1 move, 2 rotate, 3 resize (drag the gizmo handles), L local / world axes,
##              R / Shift+R turns the selection by the rotation snap, F frames it
##   Edit       Ctrl+D duplicate, Ctrl+C / Ctrl+V copy / paste at the cursor, Del delete,
##              Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo, Ctrl+S save, G grid
##   Playtest   F5: plays the level for real (bots, enemies, pickups); F5 there comes back
## The inspector edits the exact position, rotation, size or scale, material and properties.
## EditorUI builds the panels; EditorGizmo the handles; EditorHistory undo / redo.

signal selection_changed
## Objects added, removed or changed (outliner and inspector refresh).
signal level_changed
signal status_changed(text: String)
signal tool_changed(tool: Tool)
signal navmesh_baked

enum Tool { SELECT, PLACE }

const SNAP_POS_OPTIONS: Array[float] = [1.0, 0.5, 0.25, 0.0]
const SNAP_ROT_OPTIONS: Array[float] = [15.0, 45.0, 90.0, 0.0]
const DEFAULT_LEVEL_NAME := "custom_level_1"
const LEVELS_DIR := LevelData.LEVELS_DIR
const SURFACE_MASK := 1
const PICK_MASK := 0xFFFFFFFF
const RAY_LENGTH := 800.0

@export var fly_speed: float = 14.0
@export var fly_boost_multiplier: float = 2.5
@export var mouse_sensitivity: float = 0.003
@export var look_invert_y: bool = false

var level_name: String = DEFAULT_LEVEL_NAME
var settings: Dictionary = LevelData.DEFAULT_SETTINGS.duplicate()
var tool: Tool = Tool.SELECT
var grid_visible: bool = true
var history := EditorHistory.new()
var event_manager := EventManager.new()
var wire_renderer: LogicWireRenderer

var _map_root: Node3D
var _world_root: Node3D
var _camera: Camera3D
var _gizmo: EditorGizmo
var _grid: EditorGrid
var _ui: EditorUI
## Amber boxes around the selected objects.
var _highlight: MeshInstance3D
var _next_uid: int = 1
var _selection: Array[Node3D] = []
var _place_id: String = ""
var _ghost: Node3D
var _ghost_yaw: float = 0.0
var _clipboard: Array[Dictionary] = []
var _snap_pos_index: int = 1
var _snap_rot_index: int = 1
# gizmo drag
var _dragging: bool = false
var _drag_starts: Array = []  # [node, transform, size] per selected node
var _drag_pivot := Transform3D.IDENTITY
# camera
var _cam_yaw: float = 0.0
var _cam_pitch: float = -0.3
var _looking: bool = false


func _ready() -> void:
	_map_root = get_node_or_null(^"MapObjects") as Node3D
	if _map_root == null:
		_map_root = Node3D.new()
		_map_root.name = "MapObjects"
		add_child(_map_root)
	_world_root = Node3D.new()
	_world_root.name = "World"
	add_child(_world_root)
	_camera = get_node_or_null(^"EditorCamera") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "EditorCamera"
		_camera.position = Vector3(0.0, 8.0, 16.0)
		add_child(_camera)
	_camera.current = true
	_camera.near = 0.1
	_camera.far = 1000.0
	_gizmo = EditorGizmo.new()
	_gizmo.name = "Gizmo"
	_gizmo.visible = false
	add_child(_gizmo)
	_grid = EditorGrid.new()
	_grid.name = "Grid"
	add_child(_grid)
	_highlight = MeshInstance3D.new()
	_highlight.name = "SelectionBoxes"
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var box_mat := StandardMaterial3D.new()
	box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_mat.no_depth_test = true
	box_mat.albedo_color = MenuTheme.ACCENT
	box_mat.render_priority = 5
	_highlight.material_override = box_mat
	add_child(_highlight)
	_ui = EditorUI.new()
	_ui.name = "UI"
	_ui.editor = self
	add_child(_ui)
	wire_renderer = LogicWireRenderer.new()
	wire_renderer.name = "WireRenderer"
	wire_renderer.event_manager = event_manager
	wire_renderer.map_root = _map_root
	add_child(wire_renderer)
	var returning := CustomLevels.take_editor_state()
	if returning.is_empty():
		_apply_level(LevelData.new_level(DEFAULT_LEVEL_NAME))
	else:
		level_name = str(returning.get("level_name", DEFAULT_LEVEL_NAME))
		_apply_level(returning.get("level", LevelData.new_level(level_name)))
		if returning.get("camera", null) is Transform3D:
			_camera.global_transform = returning.camera
		_select_uids(returning.get("selection", []))
		_status("Back from the playtest.")
	_cam_pitch = _camera.rotation.x
	_cam_yaw = _camera.rotation.y
	if returning.is_empty():
		_status("Level Editor ready: pick something from the catalog, or click an object to select it.")


# ------------------------------------------------------------------ accessors


func get_map_root() -> Node3D:
	return _map_root


func get_editor_camera() -> Camera3D:
	return _camera


func get_gizmo() -> EditorGizmo:
	return _gizmo


func get_ui() -> EditorUI:
	return _ui


func get_selection() -> Array[Node3D]:
	_prune_selection()
	return _selection.duplicate()


## The first selected object (what the inspector shows), or null.
func get_selected_object() -> Node3D:
	_prune_selection()
	return _selection[0] if not _selection.is_empty() else null


## Every placed object, in level order (including assembly members).
func get_objects() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for child in _map_root.get_children():
		if child is Node3D and child.has_meta(&"level_object") and not child.is_queued_for_deletion():
			out.append(child)
			if child is AssemblyRoot3D:
				for member in (child as AssemblyRoot3D).get_members():
					if member.has_meta(&"level_object") and not member.is_queued_for_deletion():
						out.append(member)
	return out


func find_by_uid(uid: int) -> Node3D:
	for node in get_objects():
		if int(node.get_meta(&"uid", 0)) == uid:
			return node
	return null


func is_placing() -> bool:
	return tool == Tool.PLACE


# ------------------------------------------------------------------ level


## The level as LevelData (what gets saved, undone and playtested).
func serialize_level(name_override: String = "") -> Dictionary:
	var objects: Array = []
	var assemblies_data: Array = []
	for child in _map_root.get_children():
		if child is AssemblyRoot3D:
			var root_ass := child as AssemblyRoot3D
			var member_uids: Array[int] = []
			for m in root_ass.get_members():
				member_uids.append(int(m.get_meta(&"uid", 0)))
			assemblies_data.append({
				"assembly_uid": root_ass.assembly_uid,
				"root_pos": LevelData.arr(root_ass.position),
				"root_rot": LevelData.arr(root_ass.rotation_degrees),
				"member_uids": member_uids,
			})
	for node in get_objects():
		if not node is AssemblyRoot3D:
			objects.append(LevelWorld.entry_of(node))
	return {
		"format_version": LevelData.FORMAT,
		"level_name": name_override if name_override != "" else level_name,
		"settings": settings.duplicate(),
		"next_uid": _next_uid,
		"objects": objects,
		"assemblies": assemblies_data,
		"event_graph": event_manager.connections.duplicate(true),
	}


## Replaces the level with `data` (any format version). Clears the selection.
func deserialize_level(data: Dictionary) -> bool:
	if not data.get("objects", null) is Array:
		push_error("LevelEditor: level data has no objects array")
		return false
	_apply_level(LevelData.migrate(data))
	_status("Loaded '%s' (%d objects)." % [level_name, get_objects().size()])
	return true


func _apply_level(data: Dictionary) -> void:
	cancel_placement()
	_clear_selection_silent()
	for child in _map_root.get_children():
		_map_root.remove_child(child)
		child.queue_free()
	settings = LevelData.settings_of(data)
	level_name = str(data.get("level_name", level_name))
	_next_uid = int(data.get("next_uid", 1))
	_rebuild_world()
	for entry: Dictionary in data.get("objects", []):
		_next_uid = maxi(_next_uid, int(entry.get("uid", 0)) + 1)
		LevelWorld.add_object(_map_root, entry, true)

	# Restore assemblies
	for ass_entry_variant in data.get("assemblies", []):
		if not ass_entry_variant is Dictionary:
			continue
		var ass_entry: Dictionary = ass_entry_variant
		var member_uids: Array = ass_entry.get("member_uids", [])
		var members: Array[Node3D] = []
		for uid_val in member_uids:
			var node := find_by_uid(int(uid_val))
			if node != null and node.get_parent() == _map_root:
				members.append(node)
		if not members.is_empty():
			var ass := AssemblyRoot3D.create_from_nodes(members, str(ass_entry.get("assembly_uid", "")))
			if ass != null and ass_entry.has("root_pos"):
				ass.position = LevelData.vec(ass_entry.get("root_pos"), ass.position)
				ass.rotation_degrees = LevelData.vec(ass_entry.get("root_rot"), ass.rotation_degrees)

	# Restore event graph
	event_manager.load_connections(data.get("event_graph", []))
	if wire_renderer != null:
		wire_renderer.redraw()

	selection_changed.emit()
	level_changed.emit()


func _rebuild_world() -> void:
	for child in _world_root.get_children():
		_world_root.remove_child(child)
		child.queue_free()
	LevelWorld.add_environment(_world_root, settings)
	LevelWorld.add_ground(_world_root, settings)


func new_level() -> void:
	checkpoint("New level")
	level_name = DEFAULT_LEVEL_NAME
	_apply_level(LevelData.new_level(level_name))
	_status("New level.")


## Removes every object (undoable).
func clear_level() -> void:
	checkpoint("Clear level")
	cancel_placement()
	_clear_selection_silent()
	for child in _map_root.get_children():
		_map_root.remove_child(child)
		child.queue_free()
	selection_changed.emit()
	level_changed.emit()
	_status("Level cleared.")


func get_saved_level_names() -> PackedStringArray:
	return PackedStringArray(LevelData.list_levels())


func save_level(new_name: String) -> bool:
	var clean := LevelData.clean_name(new_name)
	level_name = clean
	var err := LevelData.save(serialize_level(clean), clean)
	if err != OK:
		_status("Could not save '%s' (%s)." % [clean, error_string(err)])
		return false
	_status("Saved '%s'. It's in Bot Arena and LAN as a map now." % clean)
	return true


func load_level(saved_name: String) -> bool:
	var data := LevelData.load_level(LevelData.clean_name(saved_name))
	if data.is_empty():
		_status("Could not load '%s'." % saved_name)
		return false
	checkpoint("Load level")
	return deserialize_level(data)


func set_setting(key: String, value: Variant) -> void:
	if not settings.has(key) or settings[key] == value:
		return
	checkpoint("Level settings")
	settings[key] = value
	_rebuild_world()
	level_changed.emit()


# ------------------------------------------------------------------ undo / redo


func checkpoint(label: String) -> void:
	history.checkpoint(_state(), label)


func undo() -> void:
	var step := history.undo(_state())
	if step.is_empty():
		_status("Nothing to undo.")
		return
	_restore(step.state)
	_status("Undid: %s" % step.label)


func redo() -> void:
	var step := history.redo(_state())
	if step.is_empty():
		_status("Nothing to redo.")
		return
	_restore(step.state)
	_status("Redid: %s" % step.label)


func _state() -> Dictionary:
	var uids: Array = []
	for node in get_selection():
		uids.append(int(node.get_meta(&"uid", 0)))
	return {"level": serialize_level(), "selection": uids}


func _restore(state: Dictionary) -> void:
	_apply_level(state.level)
	_select_uids(state.get("selection", []))


# ------------------------------------------------------------------ selection


## Selects node (alone, or added / toggled with additive).
func select_object(node: Node3D, additive: bool = false) -> void:
	if node == null:
		return
	if additive:
		if _selection.has(node):
			_selection.erase(node)
		else:
			_selection.append(node)
	else:
		_selection = [node]
	_after_selection()


func select_all() -> void:
	_selection = get_objects()
	_after_selection()


func deselect_object() -> void:
	_clear_selection_silent()
	_after_selection()


func _clear_selection_silent() -> void:
	_selection.clear()


func _after_selection() -> void:
	_prune_selection()
	_update_gizmo()
	selection_changed.emit()
	if _selection.size() == 1:
		_status("Selected %s." % _selection[0].get_meta(&"display_name", _selection[0].name))
	elif _selection.size() > 1:
		_status("%d objects selected." % _selection.size())


func _select_uids(uids: Array) -> void:
	_selection.clear()
	for uid: Variant in uids:
		var node := find_by_uid(int(uid))
		if node != null:
			_selection.append(node)
	_after_selection()


func _prune_selection() -> void:
	_selection = _selection.filter(
		func(n: Node3D) -> bool: return is_instance_valid(n) and not n.is_queued_for_deletion()
	)


## Pivot of the selection: the object itself, or the centre of several (world axes).
func selection_pivot() -> Transform3D:
	_prune_selection()
	if _selection.size() == 1:
		return _selection[0].global_transform
	var center := Vector3.ZERO
	for node in _selection:
		center += node.global_position
	if not _selection.is_empty():
		center /= _selection.size()
	return Transform3D(Basis.IDENTITY, center)


## Size of the one selected resizable object, else ZERO.
func selection_size() -> Vector3:
	var node := get_selected_object()
	if node == null or _selection.size() != 1 or not node.has_meta(&"size"):
		return Vector3.ZERO
	return node.get_meta(&"size")


func _update_gizmo() -> void:
	_gizmo.visible = not _selection.is_empty() and tool == Tool.SELECT
	if _gizmo.visible:
		var pivot := selection_pivot()
		pivot.basis = pivot.basis.orthonormalized()
		_gizmo.configure(pivot, selection_size())


func set_gizmo_mode(mode: EditorGizmo.Mode) -> void:
	if tool == Tool.PLACE:
		cancel_placement()
	_gizmo.set_mode(mode)
	_update_gizmo()
	_status(["Move", "Rotate", "Resize"][mode] + " tool" + ("" if mode != EditorGizmo.Mode.RESIZE or selection_size() != Vector3.ZERO else " (select one block or volume to resize)"))
	selection_changed.emit()


func toggle_local_space() -> void:
	_gizmo.local_space = not _gizmo.local_space
	_update_gizmo()
	_status("Gizmo axes: %s" % ("local" if _gizmo.local_space else "world"))
	selection_changed.emit()


func set_tool(new_tool: Tool) -> void:
	if new_tool == Tool.SELECT:
		cancel_placement()
	elif new_tool == Tool.PLACE:
		if _place_id.is_empty():
			var sel := get_selected_object()
			if sel != null and sel.has_meta(&"catalog_id"):
				start_place(str(sel.get_meta(&"catalog_id")))
			else:
				var items: Array[Dictionary] = LevelCatalog.get_items()
				if not items.is_empty():
					start_place(str(items[0].get("id", "")))
				else:
					_status("Pick an item in the catalog to place.")
		else:
			start_place(_place_id)


# ------------------------------------------------------------------ placing


func start_place(catalog_id: String) -> void:
	if not LevelCatalog.has_item(catalog_id):
		return
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	deselect_object()
	_place_id = catalog_id
	tool = Tool.PLACE
	tool_changed.emit(tool)
	_ghost = LevelBuilder.build({"catalog_id": catalog_id, "uid": 0}, true)
	if _ghost != null:
		_ghost.name = "Ghost"
		add_child(_ghost)
		_ghostify(_ghost)
		_ghost.rotation_degrees.y = _ghost_yaw
	_update_gizmo()
	var item := LevelCatalog.get_item(catalog_id)
	_status("Placing %s: LMB places, R turns, Esc / V stops." % item.name)


func cancel_placement() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	var was_placing := tool == Tool.PLACE
	tool = Tool.SELECT
	tool_changed.emit(tool)
	if was_placing:
		_status("Select mode: click an object to select, 1/2/3 to transform, V/B to toggle tools.")
	_place_id = ""
	_update_gizmo()


## Places the current item at a world position (undoable); returns the new object.
func place_at(pos: Vector3) -> Node3D:
	if _place_id == "":
		return null
	checkpoint("Place")
	var item := LevelCatalog.get_item(_place_id)
	var entry := {
		"catalog_id": _place_id,
		"uid": _take_uid(),
		"pos": LevelData.arr(pos),
		"rot": [0.0, _ghost_yaw, 0.0],
	}
	if item.has("default_size"):
		entry["size"] = LevelData.arr(item.default_size)
	if item.has("material"):
		entry["material"] = item.material
	var node := LevelWorld.add_object(_map_root, entry, true)
	level_changed.emit()
	_status("Placed %s." % item.name)
	return node


## Adds a saved-format entry as a new object (fresh uid); returns it.
func add_entry(entry: Dictionary) -> Node3D:
	var copy := entry.duplicate(true)
	copy["uid"] = _take_uid()
	var node := LevelWorld.add_object(_map_root, copy, true)
	level_changed.emit()
	return node


func _take_uid() -> int:
	var uid := _next_uid
	_next_uid += 1
	return uid


## A ghost: no collision, no thinking, see-through.
func _ghostify(node: Node) -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.8, 1.0, 0.4)
	for child in node.find_children("*", "", true, false) + [node]:
		if child is CollisionObject3D:
			(child as CollisionObject3D).collision_layer = 0
			(child as CollisionObject3D).collision_mask = 0
		if child is Area3D:
			(child as Area3D).monitoring = false
		if child is GeometryInstance3D and not child is Label3D:
			(child as GeometryInstance3D).material_override = mat
			(child as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if child is Light3D:
			(child as Light3D).visible = false
	node.process_mode = Node.PROCESS_MODE_DISABLED


# ------------------------------------------------------------------ editing


func delete_selected() -> void:
	var nodes := get_selection()
	if nodes.is_empty():
		return
	checkpoint("Delete")
	for node in nodes:
		var uid_str := str(node.get_meta(&"uid", ""))
		event_manager.remove_connections_for_uid(uid_str)
		_map_root.remove_child(node)
		node.queue_free()
	deselect_object()
	if wire_renderer != null:
		wire_renderer.redraw()
	level_changed.emit()
	_status("Deleted %d object%s." % [nodes.size(), "" if nodes.size() == 1 else "s"])


## Copies the selection in place, offset by the snap (or 1 m) along X, and selects the copies.
func duplicate_selected() -> void:
	var nodes := get_selection()
	if nodes.is_empty():
		return
	checkpoint("Duplicate")
	var step := maxf(get_current_pos_snap(), 1.0)
	var copies: Array[Node3D] = []
	for node in nodes:
		var entry := LevelWorld.entry_of(node)
		var pos := LevelData.vec(entry.pos, Vector3.ZERO) + Vector3(step, 0.0, 0.0)
		entry["pos"] = LevelData.arr(pos)
		copies.append(add_entry(entry))
	_selection = copies
	_after_selection()
	_status("Duplicated %d object%s." % [copies.size(), "" if copies.size() == 1 else "s"])


func copy_selected() -> void:
	var nodes := get_selection()
	if nodes.is_empty():
		return
	var pivot := selection_pivot().origin
	_clipboard.clear()
	for node in nodes:
		var entry := LevelWorld.entry_of(node)
		entry["pos"] = LevelData.arr(LevelData.vec(entry.pos, Vector3.ZERO) - pivot)
		_clipboard.append(entry)
	_status("Copied %d object%s." % [nodes.size(), "" if nodes.size() == 1 else "s"])


## Pastes the clipboard with its pivot at `at` (the cursor's surface point by default).
func paste(at: Variant = null) -> void:
	if _clipboard.is_empty():
		_status("Nothing to paste.")
		return
	var target: Vector3 = at if at is Vector3 else _cursor_surface_point()
	checkpoint("Paste")
	var pasted: Array[Node3D] = []
	for entry in _clipboard:
		var copy := entry.duplicate(true)
		copy["pos"] = LevelData.arr(apply_pos_snap(target + LevelData.vec(entry.pos, Vector3.ZERO)))
		pasted.append(add_entry(copy))
	_selection = pasted
	_after_selection()
	_status("Pasted %d object%s." % [pasted.size(), "" if pasted.size() == 1 else "s"])


## Turns the ghost or the selection about world Y by `degrees` (snapped).
func rotate_active_or_selected(degrees: float) -> void:
	if tool == Tool.PLACE:
		_ghost_yaw = apply_rot_snap_deg(wrapf(_ghost_yaw + degrees, 0.0, 360.0))
		if _ghost != null:
			_ghost.rotation_degrees.y = _ghost_yaw
		_status("Turned to %.0f°." % _ghost_yaw)
		return
	if _selection.is_empty():
		return
	checkpoint("Rotate")
	var pivot := selection_pivot().origin
	var turn := Basis(Vector3.UP, deg_to_rad(degrees))
	for node in get_selection():
		node.global_transform = Transform3D(turn * node.global_basis, pivot + turn * (node.global_position - pivot))
	_after_edit()


# ---- exact values (inspector), applied to the first selected object


func set_object_position(pos: Vector3) -> void:
	_edit_first("Move", func(node: Node3D) -> void: node.position = pos)


func set_object_rotation(degrees: Vector3) -> void:
	_edit_first("Rotate", func(node: Node3D) -> void: node.rotation_degrees = degrees)


func set_object_size(size: Vector3) -> void:
	_edit_first("Resize", func(node: Node3D) -> void: _resize_node(node, size.max(Vector3.ONE * LevelShapes.MIN_SIZE)))


func set_object_scale(value: float) -> void:
	var node := get_selected_object()
	if node == null or not LevelBuilder.is_scalable(str(node.get_meta(&"catalog_id", ""))):
		return
	_edit_first("Scale", func(n: Node3D) -> void: n.scale = Vector3.ONE * clampf(value, 0.05, 50.0))


func set_object_material(material_id: String) -> void:
	var node := get_selected_object()
	if not node is LevelGeometry:
		return
	checkpoint("Material")
	for each in get_selection():
		if each is LevelGeometry:
			(each as LevelGeometry).material_id = material_id
	_after_edit()


func set_object_label(text: String) -> void:
	_edit_first("Rename", func(node: Node3D) -> void:
		var item := LevelCatalog.get_item(str(node.get_meta(&"catalog_id", "")))
		node.set_meta(&"display_name", text.strip_edges() if text.strip_edges() != "" else str(item.get("name", ""))))


## Sets a per-object property (respawn delay, lift speed, stair steps...) and rebuilds it.
func set_object_prop(key: String, value: Variant) -> void:
	var node := get_selected_object()
	if node == null:
		return
	checkpoint("Property")
	var entry := LevelWorld.entry_of(node)
	var props: Dictionary = node.get_meta(&"props", {}).duplicate()
	props[key] = value
	entry["props"] = props
	_replace_node(node, entry)
	_after_edit()


func _edit_first(label: String, change: Callable) -> void:
	var node := get_selected_object()
	if node == null:
		return
	checkpoint(label)
	change.call(node)
	_after_edit()


func _after_edit() -> void:
	_prune_selection()
	_update_gizmo()
	level_changed.emit()
	selection_changed.emit()


## New size for a geometry piece (in place) or a volume (rebuilt).
func _resize_node(node: Node3D, size: Vector3) -> Node3D:
	if node is LevelGeometry:
		(node as LevelGeometry).size = size
		node.set_meta(&"size", size)
		return node
	if not node.has_meta(&"size"):
		return node
	var entry := LevelWorld.entry_of(node)
	entry["size"] = LevelData.arr(size)
	return _replace_node(node, entry)


## Rebuilds an object from an entry (same uid, same place in the selection and the level).
func _replace_node(node: Node3D, entry: Dictionary) -> Node3D:
	var index := node.get_index()
	var fresh := LevelBuilder.build(entry, true)
	if fresh == null:
		return node
	var keep_scale := fresh.scale
	fresh.transform = node.transform
	if LevelBuilder.is_scalable(str(entry.catalog_id)):
		fresh.scale = keep_scale
	_map_root.add_child(fresh, true)
	_map_root.move_child(fresh, index)
	var at := _selection.find(node)
	if at >= 0:
		_selection[at] = fresh
	for start: Array in _drag_starts:
		if start[0] == node:
			start[0] = fresh
	_map_root.remove_child(node)
	node.queue_free()
	return fresh


# ------------------------------------------------------------------ gizmo dragging


func begin_gizmo_drag(handle: int, mouse: Vector2) -> void:
	checkpoint(["Move", "Rotate", "Resize"][_gizmo.mode])
	_dragging = true
	_drag_pivot = selection_pivot()
	_drag_starts.clear()
	for node in get_selection():
		_drag_starts.append([node, node.global_transform, node.get_meta(&"size", Vector3.ZERO)])
	_gizmo.begin_drag(handle, _camera, mouse)


func update_gizmo_drag(mouse: Vector2) -> void:
	if not _dragging:
		return
	apply_drag(_gizmo.drag(_camera, mouse))


## Applies a gizmo measurement (EditorGizmo.drag) to the selection, from where the drag
## started, with snapping. Public so tests can drive it without a mouse.
func apply_drag(delta: Dictionary) -> void:
	match str(delta.get("type", "")):
		"move":
			var distance := float(delta.distance)
			var snap := get_current_pos_snap()
			if snap > 0.0:
				distance = snappedf(distance, snap)
			var offset: Vector3 = delta.axis * distance
			for start: Array in _drag_starts:
				var node: Node3D = start[0]
				var xform: Transform3D = start[1]
				node.global_position = xform.origin + offset
		"rotate":
			var angle := float(delta.angle)
			var snap_deg := get_current_rot_snap_deg()
			if snap_deg > 0.0:
				angle = deg_to_rad(snappedf(rad_to_deg(angle), snap_deg))
			var turn := Basis((delta.axis as Vector3).normalized(), angle)
			var pivot := _drag_pivot.origin
			for start: Array in _drag_starts:
				var node: Node3D = start[0]
				var xform: Transform3D = start[1]
				node.global_transform = Transform3D(turn * xform.basis, pivot + turn * (xform.origin - pivot))
		"resize":
			if _drag_starts.size() != 1:
				return
			var start: Array = _drag_starts[0]
			var size: Vector3 = start[2]
			if size == Vector3.ZERO:
				return
			var xform: Transform3D = start[1]
			var result := EditorGizmo.resize_box(
				xform, size, int(delta.index), float(delta.sign), float(delta.amount), get_current_pos_snap()
			)
			var node: Node3D = start[0]
			node.global_position = result[0]
			_resize_node(node, result[1])
	_update_gizmo()
	selection_changed.emit()


func end_gizmo_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	_drag_starts.clear()
	_gizmo.end_drag()
	_after_edit()


func is_dragging() -> bool:
	return _dragging


# ------------------------------------------------------------------ snapping


func get_current_pos_snap() -> float:
	return SNAP_POS_OPTIONS[_snap_pos_index]


func get_current_rot_snap_deg() -> float:
	return SNAP_ROT_OPTIONS[_snap_rot_index]


func set_pos_snap_index(index: int) -> void:
	_snap_pos_index = clampi(index, 0, SNAP_POS_OPTIONS.size() - 1)
	var snap := get_current_pos_snap()
	_grid.spacing = snap if snap > 0.0 else 1.0
	_status("Position snap: %s" % ("off" if snap <= 0.0 else "%.2f m" % snap))
	selection_changed.emit()


func set_rot_snap_index(index: int) -> void:
	_snap_rot_index = clampi(index, 0, SNAP_ROT_OPTIONS.size() - 1)
	var snap := get_current_rot_snap_deg()
	_status("Rotation snap: %s" % ("off" if snap <= 0.0 else "%.0f°" % snap))
	selection_changed.emit()


func get_pos_snap_index() -> int:
	return _snap_pos_index


func get_rot_snap_index() -> int:
	return _snap_rot_index


func apply_pos_snap(pos: Vector3) -> Vector3:
	var snap := get_current_pos_snap()
	if snap <= 0.001:
		return pos
	return Vector3(snappedf(pos.x, snap), snappedf(pos.y, snap), snappedf(pos.z, snap))


func apply_rot_snap_deg(deg: float) -> float:
	var snap := get_current_rot_snap_deg()
	if snap <= 0.001:
		return deg
	return snappedf(deg, snap)


func toggle_grid() -> void:
	grid_visible = not grid_visible
	_grid.visible = grid_visible
	_status("Grid %s." % ("on" if grid_visible else "off"))


## Puts the camera where it sees the selection (or the level's origin).
func focus_selection() -> void:
	var target := selection_pivot().origin if not _selection.is_empty() else Vector3.ZERO
	var reach := 8.0
	var size := selection_size()
	if size != Vector3.ZERO:
		reach = maxf(size.length() * 1.5, 4.0)
	var back := _camera.global_basis.z.normalized()
	_camera.global_position = target + back * reach + Vector3.UP * reach * 0.25
	_camera.look_at(target, Vector3.UP)
	_cam_pitch = _camera.rotation.x
# ------------------------------------------------------------------ assemblies and navmesh


func group_selected() -> AssemblyRoot3D:
	var sel := get_selection()
	if sel.size() < 2:
		_status("Select 2 or more objects to group into an Assembly (Ctrl+G).")
		return null
	checkpoint("Group Assembly")
	var assembly := AssemblyRoot3D.create_from_nodes(sel)
	if assembly != null:
		deselect_object()
		select_object(assembly)
		_status("Grouped %d objects into Assembly (%s)." % [sel.size(), assembly.assembly_uid])
		level_changed.emit()
	return assembly


func ungroup_selected() -> Array[Node3D]:
	var sel := get_selected_object()
	if not sel is AssemblyRoot3D:
		_status("Select an Assembly to ungroup (Ctrl+Shift+G).")
		return []
	checkpoint("Ungroup Assembly")
	var root_ass := sel as AssemblyRoot3D
	deselect_object()
	var released := root_ass.disband()
	for node in released:
		select_object(node, true)
	_status("Disbanded assembly into %d objects." % released.size())
	level_changed.emit()
	return released


func bake_navmesh() -> void:
	_status("Baking dynamic navmesh...")
	var map := get_world_3d().navigation_map
	var cell_h: float = ProjectSettings.get_setting("navigation/3d/default_cell_height", 0.05)
	var cell_s: float = ProjectSettings.get_setting("navigation/3d/default_cell_size", 0.2)
	NavigationServer3D.map_set_cell_height(map, cell_h)
	NavigationServer3D.map_set_cell_size(map, cell_s)
	var mesh := NavigationMesh.new()
	mesh.cell_size = cell_s
	mesh.cell_height = cell_h
	mesh.agent_radius = 0.408
	mesh.agent_height = 2.1
	mesh.agent_max_climb = 0.35
	mesh.agent_max_slope = 45.0
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = 1
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, _map_root)
	NavigationServer3D.bake_from_source_geometry_data_async(
		mesh, source, func() -> void:
			_status("Dynamic navmesh baked successfully (%d polygons)." % mesh.get_polygon_count())
			navmesh_baked.emit()
	)


# ------------------------------------------------------------------ playtest


## Plays the level for real (CustomArena): `rules` (GameModes id) with `bots` Marine bots;
## at_camera starts the player on the ground under the camera (else at a spawn point).
func start_playtest(rules: String = "slayer", bots: int = 0, at_camera: bool = false) -> void:
	cancel_placement()
	var uids: Array = []
	for node in get_selection():
		uids.append(int(node.get_meta(&"uid", 0)))
	var data := serialize_level()
	CustomLevels.begin_playtest(
		data,
		{"level": data, "level_name": level_name, "camera": _camera.global_transform, "selection": uids},
		bots,
		_ground_under_camera() if at_camera else null
	)
	var net := get_node(^"/root/Net")
	var mode := GameModes.fit_mode(rules, "team_4v4" if GameModes.needs_teams(rules) else "ffa")
	net.call(&"start_offline", CustomLevels.PLAYTEST_ID, mode, rules)


## Where the player would stand below the camera, facing its way; null over the void.
func _ground_under_camera() -> Variant:
	var from := _camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * RAY_LENGTH, SURFACE_MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return Transform3D(Basis(Vector3.UP, _cam_yaw), (hit.position as Vector3) + Vector3.UP * 0.05)


# ------------------------------------------------------------------ frame and input


func _process(delta: float) -> void:
	_fly(delta)
	_update_ghost()
	if _gizmo.visible:
		_update_gizmo()
		_gizmo.update_view(_camera)
	_grid.follow(_camera)
	_draw_selection_boxes()


func _fly(delta: float) -> void:
	if _typing() or Input.is_key_pressed(KEY_CTRL):
		return
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_key_pressed(KEY_E):
		input.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		input.y -= 1.0
	if input == Vector3.ZERO:
		return
	var speed := fly_speed * (fly_boost_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var basis := _camera.global_basis
	var move := basis.x * input.x + -basis.z * -input.z + Vector3.UP * input.y
	_camera.global_position += move.normalized() * speed * delta


func _update_ghost() -> void:
	if _ghost == null:
		return
	var mouse := get_viewport().get_mouse_position()
	if _ui.is_over_ui(mouse):
		_ghost.visible = false
		return
	_ghost.visible = true
	_ghost.global_position = _cursor_surface_point()


## Outlines every selected object's bounds (in its own orientation).
func _draw_selection_boxes() -> void:
	_prune_selection()
	if _selection.is_empty():
		_highlight.visible = false
		return
	_highlight.visible = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for node in _selection:
		var box := LevelBuilder.local_bounds(node).grow(0.03)
		var xform := node.global_transform
		var corners: Array[Vector3] = []
		for i in 8:
			corners.append(xform * (box.position + box.size * Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1)))
		for edge: Array in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
			mesh.surface_add_vertex(corners[edge[0]])
			mesh.surface_add_vertex(corners[edge[1]])
	mesh.surface_end()
	_highlight.mesh = mesh


## Where the cursor ray meets level geometry or the ground (or the y = 0 plane), snapped.
func _cursor_surface_point() -> Vector3:
	var mouse := get_viewport().get_mouse_position()
	var from := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * RAY_LENGTH, SURFACE_MASK)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var point := from + dir * 15.0
	if not hit.is_empty():
		point = hit.position
	else:
		var ground: Variant = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
		if ground != null:
			point = ground
	return apply_pos_snap(point)


## The placed object under the cursor, or null.
func pick_object(mouse: Vector2) -> Node3D:
	var from := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * RAY_LENGTH, PICK_MASK)
	var exclude: Array[RID] = []
	var space := get_world_3d().direct_space_state
	for _i in 8:
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return null
		var node: Node = hit.collider
		while node != null and node != _map_root:
			if node.has_meta(&"level_object"):
				if node.has_meta(&"assembly_parent") and not Input.is_key_pressed(KEY_ALT):
					var parent_assembly: Variant = node.get_meta(&"assembly_parent")
					if parent_assembly is Node3D:
						return parent_assembly as Node3D
				return node as Node3D
			node = node.get_parent()
		exclude.append(hit.rid)  # ground or something not ours: look further
	return null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey and event.pressed and not event.echo:
		if _typing():
			return
		_key(event as InputEventKey)


func _mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			_looking = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and not _ui.is_over_ui(event.position):
				var step := 2.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -2.0
				fly_speed = clampf(fly_speed + step, 2.0, 80.0)
				_status("Fly speed %.0f m/s." % fly_speed)
		MOUSE_BUTTON_LEFT:
			if not event.pressed:
				end_gizmo_drag()
				return
			if _ui.is_over_ui(event.position) or _ui.any_dialog_open():
				return
			if tool == Tool.PLACE:
				place_at(_cursor_surface_point())
				return
			if _gizmo.visible:
				var handle := _gizmo.hit_test(_camera, event.position)
				if handle >= 0:
					begin_gizmo_drag(handle, event.position)
					return
			var picked := pick_object(event.position)
			if picked != null:
				select_object(picked, event.shift_pressed)
			elif not event.shift_pressed:
				deselect_object()
	get_viewport().set_input_as_handled()


func _mouse_motion(event: InputEventMouseMotion) -> void:
	if _looking:
		_cam_yaw -= event.relative.x * mouse_sensitivity
		var invert := -1.0 if look_invert_y else 1.0
		_cam_pitch = clampf(_cam_pitch - event.relative.y * mouse_sensitivity * invert, -1.53, 1.53)
		_camera.rotation = Vector3(_cam_pitch, _cam_yaw, 0.0)
		return
	if _dragging:
		update_gizmo_drag(event.position)
	elif _gizmo.visible:
		_gizmo.set_hover(_gizmo.hit_test(_camera, event.position))


func _key(event: InputEventKey) -> void:
	var ctrl := event.ctrl_pressed or event.meta_pressed
	if ctrl:
		match event.keycode:
			KEY_Z:
				redo() if event.shift_pressed else undo()
			KEY_Y:
				redo()
			KEY_D:
				duplicate_selected()
			KEY_C:
				copy_selected()
			KEY_V:
				paste()
			KEY_A:
				select_all()
			KEY_S:
				_ui.open_save_dialog()
			KEY_G:
				if event.shift_pressed:
					ungroup_selected()
				else:
					group_selected()
			_:
				return
		get_viewport().set_input_as_handled()
		return
	match event.keycode:
		KEY_F5:
			_ui.open_playtest_dialog()
		KEY_1:
			set_gizmo_mode(EditorGizmo.Mode.MOVE)
		KEY_2:
			set_gizmo_mode(EditorGizmo.Mode.ROTATE)
		KEY_3:
			set_gizmo_mode(EditorGizmo.Mode.RESIZE)
		KEY_V:
			set_tool(Tool.SELECT)
		KEY_B:
			set_tool(Tool.PLACE)
		KEY_L:
			toggle_local_space()
		KEY_R:
			var step := get_current_rot_snap_deg()
			step = step if step > 0.0 else 15.0
			rotate_active_or_selected(-step if event.shift_pressed else step)
		KEY_F:
			focus_selection()
		KEY_G:
			toggle_grid()
		KEY_DELETE, KEY_BACKSPACE, KEY_X:
			delete_selected()
		KEY_ESCAPE:
			if _ui.any_dialog_open():
				_ui.close_dialogs()
			elif tool == Tool.PLACE:
				cancel_placement()
			else:
				deselect_object()
		KEY_TAB:
			if event.shift_pressed:
				Input.mouse_mode = (
					Input.MOUSE_MODE_CAPTURED
					if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
					else Input.MOUSE_MODE_VISIBLE
				)
			else:
				start_playtest("slayer", 0, true)
		_:
			return
	get_viewport().set_input_as_handled()


## A text box has the keyboard (typing a name must not fly the camera or delete things).
func _typing() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox


func _status(text: String) -> void:
	status_changed.emit(text)


func exit_to_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


# ------------------------------------------------------------------ event graph / logic


func add_event_connection(source_uid: Variant, signal_name: String, target_uid: Variant, target_action: String, params: Dictionary = {}) -> bool:
	checkpoint("Add Event Wire")
	var success: bool = event_manager.add_connection(source_uid, signal_name, target_uid, target_action, params)
	if success:
		if wire_renderer != null:
			wire_renderer.redraw()
		level_changed.emit()
		selection_changed.emit()
		_status("Connected wire: %s -> %s" % [signal_name, target_action])
	return success


func remove_event_connection(index: int) -> void:
	checkpoint("Remove Event Wire")
	event_manager.remove_connection(index)
	if wire_renderer != null:
		wire_renderer.redraw()
	level_changed.emit()
	selection_changed.emit()
	_status("Removed event wire.")


func get_event_connections_for_node(node: Node3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if node == null:
		return result
	var uid_str := str(node.get_meta(&"uid", ""))
	for i in event_manager.connections.size():
		var conn: Dictionary = event_manager.connections[i]
		if str(conn.get("source_uid")) == uid_str or str(conn.get("target_uid")) == uid_str:
			var copy: Dictionary = conn.duplicate(true)
			copy["_index"] = i
			result.append(copy)
	return result


func get_available_logic_targets(exclude_node: Node3D = null) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for obj in get_objects():
		if obj == exclude_node:
			continue
		if obj.has_meta(&"logic_node") or obj.has_method(&"execute_action") or obj.has_method(&"get_input_actions"):
			result.append(obj)
	return result
