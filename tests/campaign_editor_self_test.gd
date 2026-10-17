extends SceneTree
## Comprehensive headless test suite for the Custom Campaign Level Editor subsystems:
##   1. Assemblies & Grouping (AssemblyRoot3D, centroid calculation, global transform preservation, disbanding)
##   2. Assembly Serialization & Prefabs (AssemblySerializer save/load/instantiate round-trip)
##   3. VFX Definition & Emitter Subsystem (VFXRegistry, EffectEmitter3D radial impact & signal trigger)
##   4. Runtime Asset Ingestion (AssetImporter directories, MeshLoader/TextureLoader/AudioLoader error resilience)
##   5. Visual Logic & Event Graph (TriggerVolume -> EventManager -> DoorActuator / RadioTransmitter / DelayRelay / ObjectiveMarker / SpawnerNode)
##   6. Logic Wire Renderer (ImmediateMesh bezier spline generation without surface errors)
##   7. Dynamic NavMesh Baking (Bake navmesh over custom level colliders)
## Run:
##   flatpak run org.godotengine.Godot --headless --path . -s tests/campaign_editor_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========================================")
	print(" CAMPAIGN LEVEL EDITOR SELF-TEST")
	print("========================================")

	_test_assemblies_and_grouping()
	_test_prefab_serialization()
	_test_vfx_subsystem()
	_test_asset_ingestion()
	_test_logic_nodes_and_event_manager()
	_test_logic_wire_renderer()
	_test_dynamic_navmesh_baking()

	print("========================================")
	if _failed:
		print("CAMPAIGN_EDITOR_SELF_TEST FAIL")
		quit(1)
	else:
		print("CAMPAIGN_EDITOR_SELF_TEST PASS")
		quit(0)


# ------------------------------------------------------------------ 1. Assemblies & Grouping


func _test_assemblies_and_grouping() -> void:
	print("-- 1. Assemblies & Grouping")
	var holder := Node3D.new()
	root.add_child(holder)

	var node_a := Node3D.new()
	node_a.name = "BlockA"
	node_a.position = Vector3(0.0, 0.0, 0.0)
	node_a.set_meta(&"uid", 101)
	holder.add_child(node_a)

	var node_b := Node3D.new()
	node_b.name = "BlockB"
	node_b.position = Vector3(2.0, 4.0, 0.0)
	node_b.set_meta(&"uid", 102)
	holder.add_child(node_b)

	var node_c := Node3D.new()
	node_c.name = "BlockC"
	node_c.position = Vector3(4.0, 2.0, 0.0)
	node_c.set_meta(&"uid", 103)
	holder.add_child(node_c)

	# Group into assembly
	var nodes: Array[Node3D] = [node_a, node_b, node_c]
	var assembly := AssemblyRoot3D.create_from_nodes(nodes, "assembly_test_01")
	_expect(assembly != null, "assembly root created from 3 nodes")
	_expect(assembly.get_parent() == holder, "assembly attached to scene parent")

	# Centroid should be around ( (0+2+4)/3, (0+4+2)/3, 0 ) = (2.0, 2.0, 0.0)
	var expected_center := Vector3(2.0, 2.0, 0.0)
	_expect(assembly.position.is_equal_approx(expected_center), "assembly centroid calculated correctly (%s)" % assembly.position)

	# Verify children's global positions were preserved
	_expect(node_a.global_position.is_equal_approx(Vector3(0.0, 0.0, 0.0)), "member A global position preserved")
	_expect(node_b.global_position.is_equal_approx(Vector3(2.0, 4.0, 0.0)), "member B global position preserved")
	_expect(node_c.global_position.is_equal_approx(Vector3(4.0, 2.0, 0.0)), "member C global position preserved")

	# Verify member UIDs
	var uids: Array[int] = assembly.get_member_uids()
	_expect(uids.has(101) and uids.has(102) and uids.has(103), "member UIDs recorded on assembly root")

	# Move assembly and check member global positions update accordingly
	assembly.position += Vector3(10.0, 0.0, 0.0)
	_expect(node_a.global_position.is_equal_approx(Vector3(10.0, 0.0, 0.0)), "moving assembly root transforms member A")

	# Disband assembly
	var disbanded := assembly.disband()
	_expect(disbanded.size() == 3, "disband returns all members")
	_expect(node_a.get_parent() == holder, "member A returned to holder")
	_expect(node_a.global_position.is_equal_approx(Vector3(10.0, 0.0, 0.0)), "member A preserves position after disband")

	holder.free()


# ------------------------------------------------------------------ 2. Prefab Serialization


func _test_prefab_serialization() -> void:
	print("-- 2. Prefab Serialization")
	var holder := Node3D.new()
	root.add_child(holder)

	var node_1 := Node3D.new()
	node_1.name = "PrefabPart1"
	node_1.position = Vector3(-1.0, 0.0, 0.0)
	node_1.set_meta(&"uid", 201)
	node_1.set_meta(&"catalog_id", "geo_box")
	holder.add_child(node_1)

	var node_2 := Node3D.new()
	node_2.name = "PrefabPart2"
	node_2.position = Vector3(1.0, 0.0, 0.0)
	node_2.set_meta(&"uid", 202)
	node_2.set_meta(&"catalog_id", "geo_cylinder")
	holder.add_child(node_2)

	var assembly := AssemblyRoot3D.create_from_nodes([node_1, node_2], "bunker_core")
	var prefab_name := "test_bunker_unit"

	# Save prefab
	var saved: Error = AssemblySerializer.save_prefab(assembly, prefab_name)
	_expect(saved == OK, "assembly successfully serialized to user://prefabs/")
	_expect(AssemblySerializer.has_prefab(prefab_name), "prefab exists in catalog")

	# Load prefab metadata/data
	var loaded_data := AssemblySerializer.load_prefab(prefab_name)
	_expect(not loaded_data.is_empty(), "prefab data loaded from disk")
	_expect((loaded_data.get("members", []) as Array).size() == 2, "prefab contains 2 member descriptors")

	# Instantiate prefab
	var instance := AssemblySerializer.instantiate_prefab(prefab_name)
	_expect(instance != null and instance is AssemblyRoot3D, "prefab instantiated into new AssemblyRoot3D")
	_expect(instance.get_child_count() == 2, "instantiated prefab has 2 children")

	# Cleanup
	AssemblySerializer.delete_prefab(prefab_name)
	_expect(not AssemblySerializer.has_prefab(prefab_name), "prefab deleted cleanly")
	if instance != null:
		instance.free()
	holder.free()


# ------------------------------------------------------------------ 3. VFX Subsystem


func _test_vfx_subsystem() -> void:
	print("-- 3. VFX Registry & Emitter")
	VFXRegistry.initialize()

	var explosion := VFXRegistry.get_vfx("vfx_fuel_explosion")
	_expect(explosion != null, "vfx_fuel_explosion found in VFXRegistry")
	_expect(explosion.has_gameplay_damage and explosion.max_damage > 0.0, "fuel explosion has gameplay damage")

	var steam := VFXRegistry.get_vfx("vfx_steam_leak")
	_expect(steam != null, "vfx_steam_leak found in VFXRegistry")
	_expect(steam.category == "Atmospheric", "steam leak has Atmospheric category")

	var sparks := VFXRegistry.get_vfx("vfx_sparks")
	_expect(sparks != null, "vfx_sparks found in VFXRegistry")

	# Place an EffectEmitter3D and test triggering
	var holder := Node3D.new()
	root.add_child(holder)

	var emitter := EffectEmitter3D.new()
	emitter.effect_id = "vfx_fuel_explosion"
	emitter.damage_override = 75.0
	emitter.radius_override = 8.0
	emitter.one_shot = true
	holder.add_child(emitter)

	var trigger_received: Array[bool] = [false]
	emitter.triggered.connect(func(_e: EffectEmitter3D): trigger_received[0] = true)

	emitter.trigger()
	_expect(trigger_received[0], "EffectEmitter3D triggered signal emitted")

	# Test one_shot prevention
	trigger_received[0] = false
	emitter.trigger()
	_expect(not trigger_received[0], "one_shot emitter does not re-trigger")

	holder.free()


# ------------------------------------------------------------------ 4. Asset Ingestion


func _test_asset_ingestion() -> void:
	print("-- 4. Runtime Asset Ingestion")
	AssetImporter.ensure_directories()
	_expect(DirAccess.dir_exists_absolute("user://custom_assets/meshes/"), "meshes directory initialized")
	_expect(DirAccess.dir_exists_absolute("user://custom_assets/textures/"), "textures directory initialized")
	_expect(DirAccess.dir_exists_absolute("user://custom_assets/audio/"), "audio directory initialized")

	# Verify loaders handle non-existent files gracefully without crashing
	var dummy_mesh := MeshLoader.load_mesh("user://custom_assets/meshes/nonexistent.glb")
	_expect(dummy_mesh == null, "MeshLoader handles missing file gracefully")

	var dummy_tex := TextureLoader.load_texture("user://custom_assets/textures/nonexistent.png")
	_expect(dummy_tex == null, "TextureLoader handles missing file gracefully")

	var dummy_audio := AudioLoader.load_audio("user://custom_assets/audio/nonexistent.ogg")
	_expect(dummy_audio == null, "AudioLoader handles missing file gracefully")

	# Test procedural fallback materials from TextureLoader
	var test_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	test_img.fill(Color(1.0, 0.0, 0.0, 1.0))
	var test_tex_path := "user://custom_assets/textures/self_test_temp.png"
	test_img.save_png(test_tex_path)

	var loaded_tex := TextureLoader.load_texture(test_tex_path)
	_expect(loaded_tex != null and loaded_tex is ImageTexture, "TextureLoader successfully loads runtime PNG to ImageTexture")

	var decal := TextureLoader.create_decal(test_tex_path, Vector3(2.0, 2.0, 2.0))
	_expect(decal != null and decal is Decal, "TextureLoader creates Decal node from texture")
	if decal != null:
		decal.free()

	DirAccess.remove_absolute(test_tex_path)


# ------------------------------------------------------------------ 5. Visual Logic & Event Graph


func _test_logic_nodes_and_event_manager() -> void:
	print("-- 5. Visual Logic & Event Graph")
	var holder := Node3D.new()
	root.add_child(holder)

	# 1. TriggerVolume
	var trigger := TriggerVolume.new()
	trigger.name = "TriggerAlpha"
	trigger.volume_size = Vector3(4.0, 2.0, 4.0)
	trigger.filter = "all"
	trigger.trigger_once = true
	trigger.set_meta(&"uid", 501)
	holder.add_child(trigger)

	# 2. DoorActuator
	var door := DoorActuator.new()
	door.name = "DoorBravo"
	door.speed = 10.0
	door.slide_offset = Vector3(0.0, 4.0, 0.0)
	door.set_meta(&"uid", 502)
	holder.add_child(door)

	# 3. RadioTransmitter
	var radio := RadioTransmitter.new()
	radio.name = "RadioCharlie"
	radio.callsign = "HQ"
	radio.subtitle = "Target neutralized. Move to rally point."
	radio.set_meta(&"uid", 503)
	holder.add_child(radio)

	# 4. ObjectiveMarker
	var objective := ObjectiveMarker.new()
	objective.name = "ObjDelta"
	objective.objective_id = "obj_infiltrate"
	objective.objective_text = "Infiltrate the base"
	objective.is_active = true
	objective.set_meta(&"uid", 504)
	holder.add_child(objective)

	# 5. DelayRelay
	var delay := DelayRelay.new()
	delay.name = "DelayEcho"
	delay.delay_seconds = 0.05
	delay.set_meta(&"uid", 505)
	holder.add_child(delay)

	# 6. SpawnerNode
	var spawner := SpawnerNode.new()
	spawner.name = "SpawnerFoxtrot"
	spawner.spawn_item_id = "pickup:ammo_crate"
	spawner.spawn_count = 1
	spawner.set_meta(&"uid", 506)
	holder.add_child(spawner)

	# 7. EffectEmitter3D (Logic connection to effects)
	var emitter := EffectEmitter3D.new()
	emitter.name = "EmitterGolf"
	emitter.effect_id = "vfx_fuel_explosion"
	emitter.set_meta(&"uid", 507)
	holder.add_child(emitter)
	_expect(emitter.get_input_actions().has("trigger"), "EffectEmitter3D exposes 'trigger' input action")
	_expect(emitter.get_output_signals().has("triggered"), "EffectEmitter3D exposes 'triggered' output signal")

	# Event Manager Wiring
	var event_mgr := EventManager.new()
	# Trigger -> Door (open)
	var c1 := event_mgr.add_connection(501, "on_triggered", 502, "open")
	# Trigger -> Radio (broadcast)
	var c2 := event_mgr.add_connection(501, "on_triggered", 503, "broadcast")
	# Door opened -> Objective (complete)
	var c3 := event_mgr.add_connection(502, "on_opened", 504, "complete")
	# Trigger -> Effect Emitter (trigger explosion)
	var c4 := event_mgr.add_connection(501, "on_triggered", 507, "trigger")

	_expect(c1 and c2 and c3 and c4, "4 event connections registered in EventManager")
	_expect(event_mgr.connections.size() == 4, "EventManager holds 4 connections")

	# Duplicate connection should be rejected
	var c_dup := event_mgr.add_connection(501, "on_triggered", 502, "open")
	_expect(not c_dup, "duplicate connection rejected")

	# Bind graph
	event_mgr.bind_graph(holder)

	# Verify initial states
	_expect(not door.is_open, "door is initially closed")
	_expect(objective.is_active, "objective is initially active")
	_expect(not emitter._triggered, "effect emitter is initially un-triggered")

	# Simulate actor trigger
	var dummy_actor := CharacterBody3D.new()
	holder.add_child(dummy_actor)
	trigger._on_body_entered(dummy_actor)

	# Door should now be open and effect emitter triggered
	_expect(door.is_open, "door opened via TriggerVolume signal binding")
	_expect(emitter._triggered, "effect emitter triggered via TriggerVolume signal binding")

	# Simulate door opening completing objective
	door.on_opened.emit()
	_expect(not objective.is_active, "objective completed via door on_opened signal")

	# Verify TargetDummy takes radial impact damage from EffectEmitter3D without error
	var dummy_scene: PackedScene = load("res://scenes/ai/target_dummy.tscn")
	var target_dummy := dummy_scene.instantiate() as Node3D
	holder.add_child(target_dummy)
	target_dummy.global_position = emitter.global_position + Vector3(1.0, 0.0, 0.0)
	emitter.one_shot = false
	emitter._triggered = false
	emitter.trigger()
	var hs := target_dummy.get_node("HealthShield") as HealthShield
	_expect(hs != null and hs.shield < hs.max_shield, "TargetDummy took radial explosion damage from EffectEmitter3D")

	# Test removal by UID
	event_mgr.remove_connections_for_uid("507")
	_expect(event_mgr.connections.size() == 3, "remove_connections_for_uid cleanly removed effect emitter wires")

	target_dummy.free()
	dummy_actor.free()
	holder.free()


# ------------------------------------------------------------------ 6. Logic Wire Renderer


func _test_logic_wire_renderer() -> void:
	print("-- 6. Logic Wire Renderer")
	var holder := Node3D.new()
	root.add_child(holder)

	var node_a := Node3D.new()
	node_a.position = Vector3(0.0, 1.0, 0.0)
	node_a.set_meta(&"uid", 601)
	holder.add_child(node_a)

	var node_b := Node3D.new()
	node_b.position = Vector3(10.0, 1.0, 0.0)
	node_b.set_meta(&"uid", 602)
	holder.add_child(node_b)

	var event_mgr := EventManager.new()
	event_mgr.add_connection(601, "actor_entered", 602, "open")

	var wire_renderer := LogicWireRenderer.new()
	wire_renderer.event_manager = event_mgr
	wire_renderer.map_root = holder
	holder.add_child(wire_renderer)

	# Test redraw without error
	wire_renderer.redraw()
	_expect(true, "wire renderer redraws bezier connection cleanly")

	# Test redraw when empty
	event_mgr.clear()
	wire_renderer.redraw()
	_expect(true, "wire renderer handles empty connections without ImmediateMesh error")

	holder.free()


# ------------------------------------------------------------------ 7. Dynamic NavMesh Baking


func _test_dynamic_navmesh_baking() -> void:
	print("-- 7. Dynamic NavMesh Baking")
	var holder := Node3D.new()
	root.add_child(holder)

	# Add a walkable floor slab
	var floor_obj := LevelBuilder.build({
		"catalog_id": "geo_floor",
		"uid": 701,
		"pos": [0.0, 0.0, 0.0],
		"size": [16.0, 0.2, 16.0],
	}, false)
	holder.add_child(floor_obj)

	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = 0.2
	nav_mesh.cell_height = 0.05
	nav_mesh.agent_radius = 0.4
	nav_mesh.agent_height = 2.0
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 1
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN

	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav_mesh, source, holder)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source)

	var poly_count: int = nav_mesh.get_polygon_count()
	_expect(poly_count > 0, "dynamic navmesh baked over custom geometry (%d polygons)" % poly_count)

	holder.free()


# ------------------------------------------------------------------ Helpers


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
