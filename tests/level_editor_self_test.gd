extends SceneTree
## Level Editor and custom levels, headless. Checks:
##   catalog     every category is filled from the project's assets (all weapons, all ten enemy
##               ranks, props, the humvee, map models) and every item builds for the editor
##               (with something to click) and for a match
##   shapes      every parametric shape fills its size box, has collision, faces outward;
##               LevelGeometry resizes its mesh and collision together
##   gizmo       the drag maths (closest point on an axis, signed angles, a resized box keeps its
##               opposite face where it was, rotated too) and a real drag of the move arrow
##               through the camera, snapped
##   editing     place, select by clicking, multi-select, duplicate, copy / paste, delete,
##               undo / redo, turn (snapped), exact XYZ rotation, resizing a lift volume,
##               per-object properties, uniform scale, material
##   files       save / load round trip, the saved level is a map (MapList), version 1 files
##               migrate (fixed blocks become sized geometry, old pickup ids map over)
##   playtest    the editor's level plays for real (bots, placed enemies as a squad, pickups)
##               and comes back to the editor with its objects, camera and selection
##   bot arena   a saved level starts offline like any map; placed enemies only when the level
##               allows them; LevelEnemies.cluster groups markers into squads
## Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/level_editor_self_test.gd

const EDITOR_SCENE := "res://scenes/editor/level_editor.tscn"
const TEST_LEVEL := "zz_self_test_level"
const V1_LEVEL := "zz_self_test_v1"

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_catalog()
	_test_shapes()
	_test_gizmo_maths()
	await _test_editor()
	await _test_playtest()
	await _test_bot_arena()
	_test_cluster()
	_cleanup()
	if _failed:
		print("LEVEL_EDITOR_SELF_TEST FAIL")
		quit(1)
	else:
		print("LEVEL_EDITOR_SELF_TEST PASS")
		quit(0)


# ------------------------------------------------------------------ catalog


func _test_catalog() -> void:
	print("-- catalog")
	LevelCatalog.reload()
	var items := LevelCatalog.get_items()
	for category: String in LevelCatalog.CATEGORIES:
		_expect(not LevelCatalog.get_items_by_category(category).is_empty(), "category %s has items" % category)
	var weapon_scenes := 0
	for path in LevelCatalog.list_resources(LevelCatalog.WEAPON_DIR, ["tscn"], true):
		if WeaponData.of_scene(load(path) as PackedScene) != null:
			weapon_scenes += 1
	var weapon_items := items.filter(func(i: Dictionary) -> bool: return i.kind == "weapon").size()
	_expect(weapon_items == weapon_scenes and weapon_items >= 14, "every weapon scene is a pickup (%d)" % weapon_items)
	_expect(LevelCatalog.has_item("weapon:res://scenes/weapons/new_ottoman/tufek.tscn"), "New Ottoman guns included")
	_expect(LevelCatalog.get_items_by_category("Enemies").size() == 10, "all ten enemy ranks")
	_expect(LevelCatalog.has_item("vehicle:res://scenes/vehicles/humvee.tscn"), "the humvee")
	_expect(LevelCatalog.has_item("pickup:ammo_crate"), "the ammo crate")
	_expect(LevelCatalog.get_items_by_category("Models").size() >= 5, "map models")
	_expect(LevelCatalog.get_items_by_category("Geometry").size() == LevelShapes.KINDS.size() + 2, "every shape (plus wall and floor presets)")
	var holder := Node3D.new()
	root.add_child(holder)
	var bad: Array[String] = []
	var unpickable: Array[String] = []
	for item in items:
		for editor: bool in [true, false]:
			var node := LevelBuilder.build({"catalog_id": item.id, "uid": 7}, editor)
			if node == null or str(node.get_meta(&"catalog_id", "")) != item.id or int(node.get_meta(&"uid", 0)) != 7:
				bad.append("%s (%s)" % [item.id, "editor" if editor else "match"])
				continue
			if editor and not _pickable(node):
				unpickable.append(item.id)
			holder.add_child(node)
	_expect(bad.is_empty(), "every item builds in both modes %s" % [bad])
	_expect(unpickable.is_empty(), "every editor object can be clicked %s" % [unpickable])
	holder.free()
	var spawn := LevelBuilder.build({"catalog_id": "spawn_red", "uid": 12}, false)
	_expect(str(spawn.name) == "SPAWN_Red_12", "spawn markers named for SpawnManager (%s)" % spawn.name)
	spawn.free()
	var flag := LevelBuilder.build({"catalog_id": "flag_blue", "uid": 3}, false)
	_expect(str(flag.name).begins_with("FLAG_Blue"), "flag bases named for CtfMatch")
	flag.free()
	var roam := LevelBuilder.build({"catalog_id": "roam_point", "uid": 4, "props": {"weight": 3.0}}, false)
	_expect(roam.is_in_group(&"ai_roam_point") and is_equal_approx(float(roam.get_meta(&"weight")), 3.0), "roam points join the bots' group with their weight")
	roam.free()
	var enemy := LevelBuilder.build({"catalog_id": "enemy:nefer", "uid": 5}, false)
	_expect(enemy is Marker3D and str(enemy.get_meta(&"enemy_type", "")).ends_with("nefer.tres"), "match mode: enemies are markers for squads")
	enemy.free()


## Something on a collision layer the editor's pick ray hits (solid body or the pick box).
func _pickable(node: Node) -> bool:
	if node is LevelGeometry:
		return true
	for child in node.find_children("*", "CollisionObject3D", true, false):
		var body := child as CollisionObject3D
		if (body is StaticBody3D or body is RigidBody3D or body is CharacterBody3D) and body.collision_layer != 0:
			return true
	return false


# ------------------------------------------------------------------ shapes


func _test_shapes() -> void:
	print("-- shapes")
	var size := Vector3(3.0, 2.0, 4.0)
	for kind: String in LevelShapes.KINDS:
		var built := LevelShapes.build(kind, size, {})
		var mesh := built.mesh as ArrayMesh
		var aabb := mesh.get_aabb()
		var fits := aabb.position.is_equal_approx(Vector3(-1.5, 0.0, -2.0)) and aabb.size.is_equal_approx(size)
		_expect(fits, "%s fills its size box (%s)" % [kind, aabb])
		_expect(not (built.shapes as Array).is_empty(), "%s has collision" % kind)
	for kind: String in ["box", "wedge", "cylinder", "cone"]:
		_expect(_faces_outward(LevelShapes.build(kind, size, {}).mesh as ArrayMesh), "%s faces point outward (front faces visible)" % kind)
	_expect(LevelShapes.stair_count(Vector3(2.0, 1.5, 3.0)) == 5, "1.5 m of stairs = 5 steps of 0.3")
	_expect(LevelShapes.stair_count(Vector3(2.0, 1.5, 3.0), 3) == 3, "step count override")
	var geo := LevelGeometry.new()
	geo.shape_kind = "box"
	root.add_child(geo)
	geo.size = Vector3(6.0, 3.0, 1.0)
	var shape := (geo.get_node("Shape0") as CollisionShape3D)
	_expect((shape.shape as BoxShape3D).size.is_equal_approx(Vector3(6.0, 3.0, 1.0)), "resizing rebuilds collision")
	_expect(shape.position.is_equal_approx(Vector3(0.0, 1.5, 0.0)), "pivot stays at the bottom centre")
	_expect(geo.get_mesh_instance().get_aabb().size.is_equal_approx(Vector3(6.0, 3.0, 1.0)), "resizing rebuilds the mesh")
	geo.material_id = "mat_hazard_yellow_black"
	_expect(geo.get_mesh_instance().material_override == LevelGeometry.material("mat_hazard_yellow_black"), "material swap")
	geo.free()


## Every triangle's front (Godot: clockwise) faces away from the shape's centre.
func _faces_outward(mesh: ArrayMesh) -> bool:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var index := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		index = arrays[Mesh.ARRAY_INDEX]
	var center := mesh.get_aabb().get_center()
	var count := index.size() if not index.is_empty() else verts.size()
	for i in range(0, count, 3):
		var a := verts[index[i] if not index.is_empty() else i]
		var b := verts[index[i + 1] if not index.is_empty() else i + 1]
		var c := verts[index[i + 2] if not index.is_empty() else i + 2]
		var front := (c - a).cross(b - a)  # clockwise winding's front normal
		if front.length_squared() < 1e-10:
			continue
		if front.dot((a + b + c) / 3.0 - center) < -1e-4:
			return false
	return true


# ------------------------------------------------------------------ gizmo maths


func _test_gizmo_maths() -> void:
	print("-- gizmo maths")
	var t := EditorGizmo.closest_line_param(Vector3(5.0, 10.0, 0.0), Vector3.DOWN, Vector3.ZERO, Vector3.RIGHT)
	_expect(is_equal_approx(t, 5.0), "closest point on the X axis to a ray straight down at x = 5")
	var angle := EditorGizmo.signed_angle(Vector3.RIGHT, Vector3.BACK, Vector3.UP)
	_expect(is_equal_approx(angle, -PI * 0.5), "signed angle about Y (right to back = -90°)")
	var xform := Transform3D(Basis.IDENTITY, Vector3(10.0, 0.0, 0.0))
	var size := Vector3(2.0, 1.0, 2.0)
	var r: Array = EditorGizmo.resize_box(xform, size, 0, 1.0, 1.0, 0.0)
	_expect((r[1] as Vector3).is_equal_approx(Vector3(3.0, 1.0, 2.0)) and (r[0] as Vector3).is_equal_approx(Vector3(10.5, 0.0, 0.0)), "+X face out 1 m: left face stays at x = 9")
	r = EditorGizmo.resize_box(xform, size, 0, -1.0, 1.0, 0.0)
	_expect((r[0] as Vector3).is_equal_approx(Vector3(9.5, 0.0, 0.0)), "-X face out 1 m: right face stays at x = 11")
	r = EditorGizmo.resize_box(xform, size, 1, 1.0, 2.0, 0.0)
	_expect((r[0] as Vector3).is_equal_approx(xform.origin) and is_equal_approx((r[1] as Vector3).y, 3.0), "top face up: the bottom stays on the floor")
	r = EditorGizmo.resize_box(xform, size, 1, -1.0, 1.0, 0.0)
	_expect((r[0] as Vector3).is_equal_approx(Vector3(10.0, -1.0, 0.0)), "bottom face down: the top stays put")
	r = EditorGizmo.resize_box(xform, size, 2, 1.0, 0.3, 0.5)
	_expect(is_equal_approx((r[1] as Vector3).z, 2.5), "resize snaps the size (2.3 -> 2.5)")
	r = EditorGizmo.resize_box(xform, size, 0, 1.0, -5.0, 0.0)
	_expect((r[1] as Vector3).x >= LevelShapes.MIN_SIZE, "can't shrink below the minimum")
	var turned := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO)
	r = EditorGizmo.resize_box(turned, size, 0, 1.0, 2.0, 0.0)
	# Local +X is world -Z after a 90° turn: the far face stays, the box grows toward -Z.
	_expect((r[0] as Vector3).is_equal_approx(Vector3(0.0, 0.0, -1.0)), "rotated box grows along its own axis (%s)" % r[0])


# ------------------------------------------------------------------ editor


func _test_editor() -> void:
	print("-- editor")
	change_scene_to_file(EDITOR_SCENE)
	await _frames(10)
	var ed := current_scene as LevelEditor
	_expect(ed != null, "editor scene loads")
	if ed == null:
		return
	_expect(ed.get_ui() != null and ed.get_ui().get_node_or_null(^"Root/Inspector") != null, "panels built")
	ed.set_pos_snap_index(1)  # 0.5 m
	ed.set_rot_snap_index(1)  # 45°
	_expect(ed.apply_pos_snap(Vector3(1.26, 0.74, -0.2)).is_equal_approx(Vector3(1.5, 0.5, 0.0)), "position snap 0.5 m")
	_expect(is_equal_approx(ed.apply_rot_snap_deg(50.0), 45.0), "rotation snap 45°")

	# Tool selection mode toggling
	_expect(ed.tool == LevelEditor.Tool.SELECT, "starts in select tool mode")
	ed.set_tool(LevelEditor.Tool.PLACE)
	_expect(ed.tool == LevelEditor.Tool.PLACE and ed.is_placing(), "set_tool PLACE activates placing mode")
	ed.set_tool(LevelEditor.Tool.SELECT)
	_expect(ed.tool == LevelEditor.Tool.SELECT and not ed.is_placing(), "set_tool SELECT cancels placing mode")

	# Place and pick by clicking through the camera.
	ed.start_place("geo_box")
	_expect(ed.is_placing() and ed.tool == LevelEditor.Tool.PLACE, "placing mode")
	var box := ed.place_at(Vector3(0.0, 0.0, 0.0))
	ed.cancel_placement()
	_expect(box is LevelGeometry and ed.get_objects().size() == 1 and ed.tool == LevelEditor.Tool.SELECT, "placed a block")
	var cam := ed.get_editor_camera()
	cam.global_position = Vector3(0.0, 6.0, 10.0)
	cam.look_at(Vector3(0.0, 0.5, 0.0))
	await _frames(3)
	var screen := cam.unproject_position(Vector3(0.0, 0.5, 0.0))
	_expect(ed.pick_object(screen) == box, "clicking the block picks it")
	_expect(ed.pick_object(Vector2(5.0, 5.0)) == null, "clicking the sky picks nothing")
	ed.select_object(box)
	_expect(ed.get_selected_object() == box and ed.get_gizmo().visible, "selected, gizmo shown")

	# Drag the move gizmo's X arrow 2 m along the axis, through the camera.
	ed.set_gizmo_mode(EditorGizmo.Mode.MOVE)
	await _frames(2)
	ed.get_gizmo().update_view(cam)
	var length := cam.global_position.distance_to(Vector3.ZERO) * EditorGizmo.SCREEN_FRACTION
	var arrow_mid := cam.unproject_position(Vector3(length * 0.6, 0.0, 0.0))
	var handle := ed.get_gizmo().hit_test(cam, arrow_mid)
	_expect(handle == 0, "the X arrow is under the cursor (got %d)" % handle)
	ed.begin_gizmo_drag(0, arrow_mid)
	ed.update_gizmo_drag(cam.unproject_position(Vector3(length * 0.6 + 2.1, 0.0, 0.0)))
	ed.end_gizmo_drag()
	_expect(box.position.is_equal_approx(Vector3(2.0, 0.0, 0.0)), "dragged 2.1 m along X, snapped to 2.0 (%s)" % box.position)
	ed.undo()
	box = ed.get_objects()[0]
	_expect(box.position.is_equal_approx(Vector3.ZERO), "undo puts it back")
	ed.redo()
	box = ed.get_objects()[0]
	_expect(box.position.is_equal_approx(Vector3(2.0, 0.0, 0.0)), "redo moves it again")

	# Resize gizmo on the block: +X face 1 m out.
	ed.select_object(box)
	ed.set_gizmo_mode(EditorGizmo.Mode.RESIZE)
	ed.begin_gizmo_drag(0, Vector2.ZERO)
	ed.apply_drag({"type": "resize", "index": 0, "sign": 1.0, "amount": 1.0})
	ed.end_gizmo_drag()
	_expect((box as LevelGeometry).size.is_equal_approx(Vector3(3.0, 1.0, 2.0)) and box.position.is_equal_approx(Vector3(2.5, 0.0, 0.0)), "resize gizmo: 3 m wide, left face still at x = 1")

	# Rotate gizmo: about X (full 3D rotation), snapped.
	ed.set_gizmo_mode(EditorGizmo.Mode.ROTATE)
	ed.begin_gizmo_drag(0, Vector2.ZERO)
	ed.apply_drag({"type": "rotate", "axis": Vector3.RIGHT, "angle": deg_to_rad(50.0)})
	ed.end_gizmo_drag()
	_expect(is_equal_approx(box.rotation_degrees.x, 45.0), "rotate gizmo tilts about X, snapped to 45° (%s)" % box.rotation_degrees)
	ed.set_object_rotation(Vector3(10.0, 20.0, 30.0))
	_expect(box.rotation_degrees.is_equal_approx(Vector3(10.0, 20.0, 30.0)), "exact XYZ rotation from the inspector")
	ed.set_object_rotation(Vector3.ZERO)
	ed.rotate_active_or_selected(45.0)
	_expect(is_equal_approx(box.rotation_degrees.y, 45.0), "R turns the selection by the snap")
	ed.set_object_material("mat_grid_red_1m")
	_expect((box as LevelGeometry).material_id == "mat_grid_red_1m", "material from the inspector")
	ed.set_object_position(Vector3(-4.0, 0.0, 2.0))
	_expect(box.position.is_equal_approx(Vector3(-4.0, 0.0, 2.0)), "exact position")

	# Duplicate, copy / paste, multi-select, delete.
	ed.duplicate_selected()
	_expect(ed.get_objects().size() == 2 and ed.get_selected_object() != box, "duplicate selects the copy")
	var copy := ed.get_selected_object()
	_expect(int(copy.get_meta(&"uid")) != int(box.get_meta(&"uid")), "the copy gets its own uid")
	_expect((copy as LevelGeometry).size.is_equal_approx((box as LevelGeometry).size), "the copy keeps the size")
	ed.select_object(box)
	ed.select_object(copy, true)
	_expect(ed.get_selection().size() == 2, "Shift-click adds to the selection")
	ed.copy_selected()
	ed.paste(Vector3(10.0, 0.0, 10.0))
	_expect(ed.get_objects().size() == 4 and ed.get_selection().size() == 2, "paste adds both and selects them")
	ed.delete_selected()
	_expect(ed.get_objects().size() == 2, "delete removes the selection")
	ed.undo()
	_expect(ed.get_objects().size() == 4, "undo brings them back")
	ed.undo()
	_expect(ed.get_objects().size() == 2, "undo the paste")

	# A grav lift: resize the volume, change its speed.
	ed.start_place("grav_lift")
	var lift := ed.place_at(Vector3(6.0, 0.0, -6.0))
	ed.cancel_placement()
	ed.select_object(lift)
	var lift_uid := int(lift.get_meta(&"uid"))
	ed.set_object_size(Vector3(3.0, 8.0, 3.0))
	lift = ed.find_by_uid(lift_uid)
	var box_shape := (lift.get_node("Shape") as CollisionShape3D).shape as BoxShape3D
	_expect(box_shape.size.is_equal_approx(Vector3(3.0, 8.0, 3.0)), "lift volume resized (same uid)")
	ed.set_object_prop("lift_speed", 20.0)
	lift = ed.find_by_uid(lift_uid)
	_expect(is_equal_approx(float(lift.get(&"lift_speed")), 20.0), "lift speed property")
	_expect(ed.get_selected_object() == lift, "still selected after the rebuild")
	# A prop scales uniformly.
	ed.start_place("prop:res://scenes/props/lighting/fixture_beacon.tscn")
	var beacon := ed.place_at(Vector3(-6.0, 0.0, -6.0))
	ed.cancel_placement()
	ed.select_object(beacon)
	ed.set_object_scale(2.0)
	_expect(beacon.scale.is_equal_approx(Vector3.ONE * 2.0), "props scale uniformly")
	# Gameplay and assets for the save test.
	for p: Array in [["spawn_ffa", Vector3(0, 0, 8)], ["spawn_ffa", Vector3(8, 0, 8)], ["enemy:nefer", Vector3(0, 0, -16)], ["enemy:okcu", Vector3(2, 0, -16)], ["weapon:res://scenes/weapons/combat_shotgun.tscn", Vector3(-2, 0, 4)], ["geo_stairs", Vector3(4, 0, 0)]]:
		ed.start_place(p[0])
		ed.place_at(p[1])
	ed.cancel_placement()
	var stairs := ed.get_objects()[-1]
	ed.select_object(stairs)
	ed.set_object_prop("steps", 3)
	stairs = ed.get_selected_object()
	_expect((stairs as LevelGeometry).get_children().filter(func(c: Node) -> bool: return c is CollisionShape3D).size() == 3, "stairs step count property")

	# Save / load round trip.
	var before := ed.serialize_level(TEST_LEVEL)
	_expect(ed.save_level(TEST_LEVEL), "saved")
	_expect(LevelData.list_levels().has(TEST_LEVEL), "listed with the saved levels")
	var map_id := CustomLevels.map_id(TEST_LEVEL)
	_expect(MapList.has(map_id) and MapList.arena_of(map_id) == CustomLevels.ARENA_SCENE, "the saved level is a map")
	_expect(MapList.all_maps().any(func(m: Dictionary) -> bool: return m.id == map_id), "listed in the map pickers")
	ed.clear_level()
	_expect(ed.get_objects().is_empty(), "cleared")
	_expect(ed.load_level(TEST_LEVEL), "loaded")
	var after := ed.serialize_level(TEST_LEVEL)
	var same := JSON.stringify(after.objects) == JSON.stringify(before.objects)
	_expect(same, "round trip keeps every object exactly")
	if not same:
		for i in mini(before.objects.size(), after.objects.size()):
			if JSON.stringify(before.objects[i]) != JSON.stringify(after.objects[i]):
				print("    before ", JSON.stringify(before.objects[i]))
				print("    after  ", JSON.stringify(after.objects[i]))
	_expect(ed.find_by_uid(lift_uid) != null and is_equal_approx(float(ed.find_by_uid(lift_uid).get(&"lift_speed")), 20.0), "lift and its speed survive")

	# Version 1 files (the first editor) migrate.
	var v1 := {
		"format_version": 1,
		"level_name": V1_LEVEL,
		"objects": [
			{"catalog_id": "cube_1x1x1", "name": "Cube", "pos": [1, 0, 1], "rot": [0, 90, 0], "scale": [2, 1, 3], "properties": {}},
			{"catalog_id": "ramp", "pos": [4, 0, 0], "rot": [0, 0, 0], "scale": [1, 1, 1]},
			{"catalog_id": "pickup_shotgun", "pos": [0, 0, 5], "rot": [0, 0, 0], "scale": [1, 1, 1]},
			{"catalog_id": "spawn_red", "pos": [0, 0, -5], "rot": [0, 180, 0], "scale": [1, 1, 1]},
		],
	}
	DirAccess.make_dir_recursive_absolute(LevelData.LEVELS_DIR)
	var file := FileAccess.open(LevelData.LEVELS_DIR + V1_LEVEL + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(v1))
	file.close()
	_expect(ed.load_level(V1_LEVEL), "version 1 file loads")
	var objects := ed.get_objects()
	_expect(objects.size() == 4, "all four old objects")
	if objects.size() == 4:
		_expect(objects[0] is LevelGeometry and (objects[0] as LevelGeometry).size.is_equal_approx(Vector3(2.0, 1.0, 3.0)), "scaled cube -> 2x1x3 block")
		_expect(is_equal_approx(objects[0].rotation_degrees.y, 90.0), "yaw kept")
		_expect((objects[1] as LevelGeometry).shape_kind == "wedge", "ramp -> wedge")
		_expect(str(objects[2].get_meta(&"catalog_id")) == "weapon:res://scenes/weapons/combat_shotgun.tscn", "old pickup id -> weapon pickup")
		_expect(str(objects[3].get_meta(&"catalog_id")) == "spawn_red", "spawns unchanged")
	_expect(int(LevelData.load_level(V1_LEVEL).format_version) == LevelData.FORMAT, "migrated data is version 2")
	ed.load_level(TEST_LEVEL)


# ------------------------------------------------------------------ playtest


func _test_playtest() -> void:
	print("-- playtest")
	var ed := current_scene as LevelEditor
	if ed == null:
		return
	var count := ed.get_objects().size()
	var cam := ed.get_editor_camera()
	cam.global_position = Vector3(3.0, 14.0, 22.0)
	ed.select_object(ed.get_objects()[0])
	var selected_uid := int(ed.get_selected_object().get_meta(&"uid"))
	ed.start_playtest("slayer", 1, true)
	var arena := await _arena()
	_expect(arena is CustomArena, "playtest loads the custom arena")
	if not arena is CustomArena:
		return
	var net := root.get_node("Net")
	_expect(str(net.get(&"map_id")) == CustomLevels.PLAYTEST_ID and CustomLevels.playtest_active, "playtest session")
	var spawns := arena.get_node("SpawnManager") as SpawnManager
	var enemies := arena.get_node_or_null(^"LevelEnemies") as LevelEnemies
	for i in 60 * 20:
		if spawns.bots.size() >= 1 and enemies != null and enemies.living().size() >= 2:
			break
		await _frames(1)
	_expect(spawns.bots.size() == 1, "the bot count asked for (%d)" % spawns.bots.size())
	_expect(enemies != null and enemies.living().size() == 2, "placed enemies fight in a playtest")
	_expect(enemies != null and enemies.squads.size() == 1, "two nearby enemies make one squad")
	_expect(arena.find_children("*", "WeaponPickup", true, false).size() == 1, "the shotgun pickup is live")
	_expect(arena.find_children("GravLift*", "Area3D", true, false).size() == 1, "the lift is live")
	var player := arena.get_node("Player") as Player
	_expect(Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(3.0, 22.0)) < 0.5, "starts under the editor camera")
	var ui := arena.find_children("MatchUI", "", true, false)
	_expect(not ui.is_empty(), "match UI")
	CustomLevels.return_to_editor(self)
	await _frames(30)
	var back := current_scene as LevelEditor
	_expect(back != null, "back in the editor")
	if back == null:
		return
	_expect(back.get_objects().size() == count, "same objects (%d)" % back.get_objects().size())
	_expect(back.get_editor_camera().global_position.is_equal_approx(Vector3(3.0, 14.0, 22.0)), "camera where it was")
	_expect(back.get_selected_object() != null and int(back.get_selected_object().get_meta(&"uid")) == selected_uid, "selection kept")
	_expect(back.level_name == TEST_LEVEL, "level name kept")
	_expect(not CustomLevels.playtest_active, "playtest over")


# ------------------------------------------------------------------ bot arena


func _test_bot_arena() -> void:
	print("-- bot arena")
	var net := root.get_node("Net")
	var map_id := CustomLevels.map_id(TEST_LEVEL)
	net.call(&"start_offline", map_id, "ffa", "slayer")
	var arena := await _arena()
	_expect(arena is CustomArena, "a saved level starts offline like any map")
	if arena is CustomArena:
		_expect(arena.get_node_or_null(^"LevelEnemies") == null, "no placed enemies unless the level allows it")
		var spawns := arena.get_node("Level/Spawns")
		_expect(spawns.get_child_count() == 2, "the level's two spawns")
	var data := LevelData.load_level(TEST_LEVEL)
	data.settings.enemies_in_matches = true
	LevelData.save(data, TEST_LEVEL)
	net.call(&"start_offline", map_id, "ffa", "slayer")
	arena = await _arena()
	_expect(arena is CustomArena and arena.get_node_or_null(^"LevelEnemies") != null, "placed enemies when the level allows it")
	net.call(&"start_offline", map_id, "ffa", "horde")
	arena = await _arena()
	_expect(arena is CustomArena and arena.get_node_or_null(^"LevelEnemies") == null, "Horde brings its own waves instead")
	net.call(&"leave")
	# Let the arena finish (its navmesh bakes on a worker thread) before the test quits.
	await _frames(120)
	current_scene.queue_free()
	await _frames(30)


func _test_cluster() -> void:
	print("-- squads")
	var type := load("res://resources/enemies/new_ottoman/nefer.tres") as EnemyType
	var markers: Array[Dictionary] = []
	for x: float in [0.0, 5.0, 10.0, 60.0, 64.0]:
		markers.append({"type": type, "xform": Transform3D(Basis.IDENTITY, Vector3(x, 0.0, 0.0))})
	var groups := LevelEnemies.cluster(markers, 14.0, 10)
	_expect(groups.size() == 2 and groups[0].size() == 3 and groups[1].size() == 2, "markers chain into squads by distance")
	markers.clear()
	for i in 13:
		markers.append({"type": type, "xform": Transform3D(Basis.IDENTITY, Vector3(i, 0.0, 0.0))})
	groups = LevelEnemies.cluster(markers, 14.0, 10)
	_expect(groups.size() == 2 and groups[0].size() == 10, "squads cap at 10")


# ------------------------------------------------------------------ helpers


func _cleanup() -> void:
	for level_name in [TEST_LEVEL, V1_LEVEL]:
		DirAccess.remove_absolute(LevelData.LEVELS_DIR + level_name + LevelData.EXTENSION)


func _arena() -> Node:
	for i in 60 * 30:
		await _frames(1)
		var scene := current_scene
		if scene != null and scene.get_node_or_null(^"NetMatch") != null:
			await _frames(10)
			return scene
	_expect(false, "arena loaded")
	return null


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
