class_name LevelData
extends RefCounted
## Custom level files (JSON) and their format. Version 2:
##   {"format_version": 2, "level_name", "settings": {...}, "next_uid", "objects": [entry...]}
##   entry: {"catalog_id", "uid", "label"?, "pos": [x,y,z], "rot": [x,y,z] (degrees),
##           "size"?: [x,y,z] (geometry and volumes), "material"? (geometry),
##           "scale"? (props and models, uniform), "props"?: {...}}
## Version 1 files (the first Level Editor: fixed-size blocks, yaw only) are migrated on load.
## Levels live in user://custom_levels/ plus any folders added with add_dir() (a dedicated
## server's levels_dir). A level's map id is "custom:<file name>" (CustomLevels / MapList).

const FORMAT := 2
const LEVELS_DIR := "user://custom_levels/"
const EXTENSION := ".json"

## Level settings and their defaults.
const DEFAULT_SETTINGS := {
	"environment": "outdoor",  # a key of ENVIRONMENTS
	"sun_yaw": 30.0,
	"sun_pitch": -50.0,
	"sun_energy": 1.2,
	"ground": true,
	"ground_size": 120.0,
	"ground_material": "mat_grid_dark_1m",
	"kill_height": -25.0,
	"enemies_in_matches": false,
	"enemy_respawn": 60.0,  # seconds before a wiped-out enemy squad returns (0 = never)
	"description": "",
}
const ENVIRONMENTS := {
	"outdoor": "res://resources/environments/outdoor_environment.tres",
	"indoor": "res://resources/environments/lockout_environment.tres",
}

## Version 1 ids -> [version 2 id, size or null, material or ""].
const V1_IDS := {
	"cube_1x1x1": ["geo_box", Vector3(1.0, 1.0, 1.0), ""],
	"platform_2x1x2": ["geo_box", Vector3(2.0, 1.0, 2.0), "mat_grid_blue_1m"],
	"wall_4x3": ["geo_wall", Vector3(4.0, 3.0, 0.5), ""],
	"ramp": ["geo_wedge", Vector3(2.0, 1.5, 3.0), ""],
	"pillar": ["geo_cylinder", Vector3(1.0, 4.0, 1.0), ""],
	"cover_crate": ["geo_box", Vector3(1.2, 1.0, 0.8), "mat_scifi_panel"],
	"pickup_carbine": ["weapon:res://scenes/weapons/marksman_carbine.tscn", null, ""],
	"pickup_shotgun": ["weapon:res://scenes/weapons/combat_shotgun.tscn", null, ""],
	"pickup_rocket": ["weapon:res://scenes/weapons/directed_energy_rifle.tscn", null, ""],
	"pickup_longsword": ["weapon:res://scenes/weapons/longsword.tscn", null, ""],
	"pickup_hammer": ["weapon:res://scenes/weapons/gravity_hammer.tscn", null, ""],
	"pickup_ammo": ["pickup:ammo_crate", null, ""],
	"vehicle_humvee": ["vehicle:res://scenes/vehicles/humvee.tscn", null, ""],
	"light_worklight": ["prop:res://scenes/props/lighting/fixture_caged_worklight.tscn", null, ""],
	"light_fluoro": ["prop:res://scenes/props/lighting/fixture_fluoro_strip.tscn", null, ""],
}

static var _extra_dirs: Array[String] = []


static func new_level(level_name: String) -> Dictionary:
	return {
		"format_version": FORMAT,
		"level_name": level_name,
		"settings": DEFAULT_SETTINGS.duplicate(),
		"next_uid": 1,
		"objects": [],
		"assemblies": [],
		"event_graph": [],
	}


## Settings with every key present (defaults filled in).
static func settings_of(data: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULT_SETTINGS.duplicate()
	out.merge(data.get("settings", {}), true)
	return out


## Any version -> version 2 (a copy). Unknown ids are kept (and skipped when built).
static func migrate(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	var version := int(out.get("format_version", 1))
	if not out.has("settings"):
		out["settings"] = DEFAULT_SETTINGS.duplicate()
	if not out.has("assemblies"):
		out["assemblies"] = []
	if not out.has("event_graph"):
		out["event_graph"] = []
	var objects: Array = out.get("objects", [])
	var uid := 1
	for entry: Dictionary in objects:
		uid = maxi(uid, int(entry.get("uid", 0)) + 1)
	for entry: Dictionary in objects:
		if not entry.has("uid") or int(entry.uid) <= 0:
			entry["uid"] = uid
			uid += 1
		if version < 2 and V1_IDS.has(str(entry.get("catalog_id", ""))):
			var mapped: Array = V1_IDS[entry.catalog_id]
			entry["catalog_id"] = mapped[0]
			if mapped[1] != null:
				var s: Vector3 = mapped[1]
				var scale: Array = entry.get("scale", [1.0, 1.0, 1.0])
				entry["size"] = [s.x * float(scale[0]), s.y * float(scale[1]), s.z * float(scale[2])]
				entry.erase("scale")
			if mapped[2] != "":
				entry["material"] = mapped[2]
		if version < 2:
			entry.erase("name")
			if entry.get("props", null) is Dictionary and (entry.props as Dictionary).is_empty():
				entry.erase("props")
			if entry.has("properties"):
				entry.erase("properties")
	out["objects"] = objects
	out["next_uid"] = maxi(int(out.get("next_uid", 1)), uid)
	out["format_version"] = FORMAT
	return out


# ------------------------------------------------------------------ files


static func levels_dirs() -> Array[String]:
	var out: Array[String] = [LEVELS_DIR]
	for dir in _extra_dirs:
		if not out.has(dir):
			out.append(dir)
	return out


## Extra folder to read levels from (a dedicated server's levels_dir).
static func add_dir(dir: String) -> void:
	var clean := dir if dir.ends_with("/") else dir + "/"
	if not _extra_dirs.has(clean):
		_extra_dirs.append(clean)


## Level file names (no extension) in every levels folder, sorted, no duplicates.
static func list_levels() -> Array[String]:
	var out: Array[String] = []
	for dir in levels_dirs():
		var access := DirAccess.open(dir)
		if access == null:
			continue
		for file in access.get_files():
			if file.ends_with(EXTENSION) and not out.has(file.get_basename()):
				out.append(file.get_basename())
	out.sort()
	return out


## The file holding level `name`, searching every folder; "" if none.
static func path_of(level_name: String) -> String:
	for dir in levels_dirs():
		var path := dir + level_name + EXTENSION
		if FileAccess.file_exists(path):
			return path
	return ""


static func clean_name(level_name: String) -> String:
	var clean := level_name.strip_edges().validate_filename().replace(" ", "_")
	return clean if clean != "" else "custom_level"


static func save(data: Dictionary, level_name: String) -> Error:
	DirAccess.make_dir_recursive_absolute(LEVELS_DIR)
	var copy := data.duplicate(true)
	copy["level_name"] = level_name
	copy["format_version"] = FORMAT
	var file := FileAccess.open(LEVELS_DIR + clean_name(level_name) + EXTENSION, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(copy, "\t"))
	file.close()
	return OK


## Version 2 data, or {} if the file is missing or not a level.
static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return parse(FileAccess.get_file_as_string(path))


static func load_level(level_name: String) -> Dictionary:
	return load_file(path_of(level_name))


## Level JSON text (a file, or a host's download) -> version 2 data, or {}.
static func parse(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	var data: Dictionary = json.data
	if not data.get("objects", null) is Array:
		return {}
	return migrate(data)


static func to_text(data: Dictionary) -> String:
	return JSON.stringify(data)


# ------------------------------------------------------------------ entries


static func vec(raw: Variant, fallback: Vector3) -> Vector3:
	if raw is Array and (raw as Array).size() == 3:
		return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	if raw is Vector3:
		return raw
	return fallback


static func arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


## The transform an entry describes (rotation in degrees, YXZ like Node3D).
static func transform_of(entry: Dictionary) -> Transform3D:
	var rot := vec(entry.get("rot", null), Vector3.ZERO)
	var basis := Basis.from_euler(rot * (PI / 180.0))
	return Transform3D(basis, vec(entry.get("pos", null), Vector3.ZERO))
