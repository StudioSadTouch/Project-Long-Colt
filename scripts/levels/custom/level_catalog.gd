class_name LevelCatalog
extends RefCounted
## Everything a custom level can contain. Built-in pieces (parametric geometry, gameplay markers
## and volumes) plus every game asset, found by scanning the project at runtime so new assets
## appear with no list to maintain:
##   Weapons   every weapon scene under scenes/weapons/ (New Ottoman guns included) as a pickup,
##             every grenade type (GrenadeData under resources/weapons/) as a grenade pickup,
##             and the ammo crate
##   Enemies   every EnemyType under resources/enemies/new_ottoman/
##   Props     every scene under scenes/props/ (light fixtures) and the target dummies
##   Vehicles  every scene under scenes/vehicles/
##   Models    every map model under assets/models/environment/ (static, with collision)
## Item ids are stable strings saved in levels: "geo_box", "spawn_red", "weapon:<scene path>",
## "grenade:<GrenadeData path>", "enemy:<type id>", "prop:<scene path>", "vehicle:<scene path>",
## "model:<glb path>".
## LevelBuilder turns an item into a node (for the editor or for a match).
##
## Item fields: id, name, category, kind, and per kind: shape + default_size (geometry and
## volumes, which resize), scalable (props and models take a uniform scale), path (scenes,
## models, enemy types), props (default per-object properties, editable in the inspector).

const CATEGORIES := ["Geometry", "Gameplay", "Weapons", "Enemies", "Props", "Vehicles", "Models", "VFX", "Logic"]
const WEAPON_DIR := "res://scenes/weapons/"
const ENEMY_DIR := "res://resources/enemies/new_ottoman/"
const PROP_DIRS := ["res://scenes/props/"]
## Shape options a geometry piece can change in the inspector (LevelShapes reads them).
## steps 0 = one step per LevelShapes.STEP_RISE of height.
const SHAPE_PROPS := {
	"stairs": {"steps": 0},
	"doorway": {"door_width": 1.6, "door_height": 2.4},
	"window": {"window_width": 2.0, "window_bottom": 1.0, "window_top": 2.2},
}
const EXTRA_PROPS := ["res://scenes/ai/target_dummy.tscn", "res://scenes/ai/moving_dummy.tscn"]
const AMMO_CRATE := "res://scenes/pickups/ammo_crate.tscn"
const GRENADE_DIR := "res://resources/weapons/"
const VEHICLE_DIR := "res://scenes/vehicles/"
const MODEL_DIR := "res://assets/models/environment/"

const GEOMETRY := [
	["geo_box", "Block", "box", Vector3(2.0, 1.0, 2.0)],
	["geo_wall", "Wall", "box", Vector3(4.0, 3.0, 0.3)],
	["geo_floor", "Floor Slab", "box", Vector3(8.0, 0.2, 8.0)],
	["geo_wedge", "Ramp (Wedge)", "wedge", Vector3(2.0, 1.5, 3.0)],
	["geo_stairs", "Stairs", "stairs", Vector3(2.0, 1.5, 3.0)],
	["geo_cylinder", "Cylinder / Pillar", "cylinder", Vector3(1.0, 4.0, 1.0)],
	["geo_cone", "Cone", "cone", Vector3(2.0, 2.0, 2.0)],
	["geo_arch", "Arch", "arch", Vector3(4.0, 3.5, 0.5)],
	["geo_doorway", "Doorway Wall", "doorway", Vector3(4.0, 3.0, 0.3)],
	["geo_window", "Window Wall", "window", Vector3(4.0, 3.0, 0.3)],
	["geo_catwalk", "Catwalk (railed)", "catwalk", Vector3(2.0, 1.15, 6.0)],
	["geo_quarter_pipe", "Quarter Pipe", "quarter_pipe", Vector3(4.0, 2.0, 2.0)],
]
## Default material per geometry item (the rest use the dark grid).
const GEOMETRY_MATERIAL := {
	"geo_wall": "mat_concrete_dark", "geo_floor": "mat_grid_dark_1m",
	"geo_wedge": "mat_grid_orange_1m", "geo_stairs": "mat_metal_deck",
	"geo_catwalk": "mat_metal_deck", "geo_doorway": "mat_concrete_dark",
	"geo_window": "mat_concrete_dark", "geo_arch": "mat_concrete_dark",
	"geo_cylinder": "mat_scifi_panel", "geo_quarter_pipe": "mat_grid_orange_1m",
}

static var _items: Array[Dictionary] = []
static var _by_id: Dictionary = {}


static func get_items() -> Array[Dictionary]:
	if _items.is_empty():
		_discover()
	return _items


static func get_item(id: String) -> Dictionary:
	if _items.is_empty():
		_discover()
	return _by_id.get(id, {})


static func has_item(id: String) -> bool:
	return not get_item(id).is_empty()


static func get_items_by_category(category: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for item in get_items():
		if item.category == category:
			out.append(item)
	return out


static func get_categories() -> Array[String]:
	var result: Array[String] = []
	for c in CATEGORIES:
		result.append(c)
	if not get_items_by_category("Custom").is_empty():
		result.append("Custom")
	return result


## Drops the cache (tests, or after adding assets while running).
static func reload() -> void:
	_items.clear()
	_by_id.clear()


static func _discover() -> void:
	for g: Array in GEOMETRY:
		var item := {
			"id": g[0], "name": g[1], "category": "Geometry", "kind": "geometry",
			"shape": g[2], "default_size": g[3],
			"material": GEOMETRY_MATERIAL.get(g[0], LevelGeometry.DEFAULT_MATERIAL),
		}
		if SHAPE_PROPS.has(g[2]):
			item["props"] = (SHAPE_PROPS[g[2]] as Dictionary).duplicate()
		_add(item)
	_add({"id": "spawn_ffa", "name": "Spawn: Free for All", "category": "Gameplay", "kind": "spawn", "prefix": "SPAWN_FFA", "color": Color(0.95, 0.75, 0.15)})
	_add({"id": "spawn_red", "name": "Spawn: Red Team", "category": "Gameplay", "kind": "spawn", "prefix": "SPAWN_Red", "color": Color(0.9, 0.2, 0.2)})
	_add({"id": "spawn_blue", "name": "Spawn: Blue Team", "category": "Gameplay", "kind": "spawn", "prefix": "SPAWN_Blue", "color": Color(0.2, 0.45, 0.95)})
	_add({"id": "flag_red", "name": "CTF Flag Base: Red", "category": "Gameplay", "kind": "flag", "prefix": "FLAG_Red", "color": Color(0.9, 0.2, 0.2)})
	_add({"id": "flag_blue", "name": "CTF Flag Base: Blue", "category": "Gameplay", "kind": "flag", "prefix": "FLAG_Blue", "color": Color(0.2, 0.45, 0.95)})
	_add({"id": "roam_point", "name": "AI Roam Point", "category": "Gameplay", "kind": "roam", "props": {"weight": 1.0}})
	_add({"id": "grav_lift", "name": "Grav Lift", "category": "Gameplay", "kind": "volume", "default_size": Vector3(2.0, 4.0, 2.0), "props": {"lift_speed": 12.0}})
	_add({"id": "kill_volume", "name": "Kill Volume", "category": "Gameplay", "kind": "volume", "default_size": Vector3(10.0, 2.0, 10.0)})
	for path in list_resources(WEAPON_DIR, ["tscn"], true):
		var data := WeaponData.of_scene(load(path) as PackedScene)
		if data == null:
			continue
		_add({
			"id": "weapon:" + path, "name": data.display_name, "category": "Weapons",
			"kind": "weapon", "path": path, "props": {"respawn_delay": 30.0},
		})
	for path in list_resources(GRENADE_DIR, ["tres"]):
		var grenade := load(path) as GrenadeData
		if grenade == null:
			continue
		_add({
			"id": "grenade:" + path, "name": grenade.display_name + "s", "category": "Weapons",
			"kind": "grenade", "path": path, "props": {"amount": 2, "respawn_delay": 30.0},
		})
	_add({"id": "pickup:ammo_crate", "name": "Ammo Crate", "category": "Weapons", "kind": "scene", "path": AMMO_CRATE})
	for path in list_resources(ENEMY_DIR, ["tres"]):
		var type := load(path) as EnemyType
		if type == null:
			continue
		_add({
			"id": "enemy:" + String(type.id), "name": "%s (%s)" % [type.native_name, type.role_name().capitalize()],
			"category": "Enemies", "kind": "enemy", "path": path,
		})
	var props: Array[String] = []
	for dir: String in PROP_DIRS:
		props.append_array(list_resources(dir, ["tscn"], true))
	props.append_array(EXTRA_PROPS.filter(func(p: String) -> bool: return ResourceLoader.exists(p)))
	for path in props:
		_add({"id": "prop:" + path, "name": humanize(path), "category": "Props", "kind": "scene", "path": path, "scalable": true})
	for path in list_resources(VEHICLE_DIR, ["tscn"]):
		_add({"id": "vehicle:" + path, "name": humanize(path), "category": "Vehicles", "kind": "vehicle", "path": path})
	for path in list_resources(MODEL_DIR, ["glb"]):
		_add({"id": "model:" + path, "name": humanize(path), "category": "Models", "kind": "model", "path": path, "scalable": true})

	# VFX Emitters
	VFXRegistry.initialize()
	for def: VFXDefinition in VFXRegistry.list_definitions():
		_add({
			"id": "vfx:" + def.effect_id,
			"name": def.display_name,
			"category": "VFX",
			"kind": "vfx",
			"effect_id": def.effect_id,
			"props": {
				"damage_override": def.max_damage,
				"radius_override": def.damage_radius,
				"impulse_override": def.impulse_force,
				"one_shot": true,
			}
		})

	# Visual Logic & Campaign Nodes
	_add({"id": "logic:trigger_volume", "name": "Trigger Volume", "category": "Logic", "kind": "logic_trigger", "default_size": Vector3(4.0, 3.0, 4.0), "props": {"filter": "player", "trigger_once": true}})
	_add({"id": "logic:orta_tracker", "name": "Orta / Squad Tracker", "category": "Logic", "kind": "logic_tracker", "props": {"squad_id": ""}})
	_add({"id": "logic:door_actuator", "name": "Door Actuator", "category": "Logic", "kind": "logic_door", "props": {"speed": 3.0, "is_locked": false, "slide_y": 3.5}})
	_add({"id": "logic:radio_transmitter", "name": "Radio Transmitter", "category": "Logic", "kind": "logic_radio", "props": {"callsign": "COMMAND", "subtitle": "Proceed to objective.", "duration": 4.0}})
	_add({"id": "logic:objective_marker", "name": "Objective Marker", "category": "Logic", "kind": "logic_objective", "props": {"objective_id": "obj_1", "text": "Proceed to waypoint"}})
	_add({"id": "logic:delay_relay", "name": "Delay Relay", "category": "Logic", "kind": "logic_delay", "props": {"delay": 1.0, "repeat": false}})
	_add({"id": "logic:spawner_node", "name": "Dynamic Spawner", "category": "Logic", "kind": "logic_spawner", "props": {"spawn_item_id": "enemy:nefer", "count": 1, "spread": 2.0}})

	# Custom Ingested Assets
	AssetImporter.ensure_directories()
	for mesh_file in AssetImporter.list_meshes():
		_add({
			"id": "custom_mesh:" + mesh_file,
			"name": mesh_file.get_basename().capitalize(),
			"category": "Custom",
			"kind": "custom_mesh",
			"path": AssetImporter.mesh_path(mesh_file),
			"scalable": true,
		})


static func _add(item: Dictionary) -> void:
	if _by_id.has(item.id):
		return
	_items.append(item)
	_by_id[item.id] = item


## Resource paths under dir with one of the extensions, as they load at runtime. In an exported
## build text scenes are listed as "x.tscn.remap" and models as "x.glb.import"; both map back to
## the path ResourceLoader takes.
static func list_resources(dir: String, extensions: Array, recursive: bool = false) -> Array[String]:
	var out: Array[String] = []
	var access := DirAccess.open(dir)
	if access == null:
		return out
	for file in access.get_files():
		var name := file.trim_suffix(".remap").trim_suffix(".import")
		if extensions.has(name.get_extension()):
			var path := dir.path_join(name)
			if not out.has(path) and ResourceLoader.exists(path):
				out.append(path)
	if recursive:
		for sub in access.get_directories():
			out.append_array(list_resources(dir.path_join(sub), extensions, true))
	out.sort()
	return out


## "res://scenes/props/lighting/fixture_caged_worklight.tscn" -> "Caged Worklight".
static func humanize(path: String) -> String:
	var base := path.get_file().get_basename()
	for prefix in ["fixture_", "prop_"]:
		base = base.trim_prefix(prefix)
	base = base.trim_suffix("_greybox")
	return base.replace("_", " ").capitalize()
