class_name VFXRegistry
extends RefCounted
## Catalog registry indexing VFXDefinition resources across res://resources/vfx/ and user://custom_assets/vfx/.

const BUILTIN_DIR := "res://resources/vfx/"
const CUSTOM_DIR := "user://custom_assets/vfx/"

static var _registry: Dictionary = {}
static var _initialized: bool = false


static func initialize() -> void:
	if _initialized:
		return
	_initialized = true
	_scan_dir(BUILTIN_DIR)
	_scan_dir(CUSTOM_DIR)
	_register_fallbacks()


static func _scan_dir(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file in dir.get_files():
		if file.ends_with(".tres") or file.ends_with(".res"):
			var res_path := dir_path + ("" if dir_path.ends_with("/") else "/") + file
			var res := load(res_path)
			if res is VFXDefinition:
				register(res as VFXDefinition)


static func register(vfx: VFXDefinition) -> void:
	if vfx == null or vfx.effect_id.is_empty():
		return
	_registry[vfx.effect_id] = vfx


static func get_vfx(id: String) -> VFXDefinition:
	if not _initialized:
		initialize()
	return _registry.get(id, null)


static func list_ids() -> Array[String]:
	if not _initialized:
		initialize()
	var keys: Array[String] = []
	for k: String in _registry.keys():
		keys.append(k)
	keys.sort()
	return keys


static func list_definitions() -> Array[VFXDefinition]:
	if not _initialized:
		initialize()
	var out: Array[VFXDefinition] = []
	for v in _registry.values():
		out.append(v as VFXDefinition)
	return out


static func _register_fallbacks() -> void:
	if not _registry.has("vfx_fuel_explosion"):
		var f := VFXDefinition.new()
		f.effect_id = "vfx_fuel_explosion"
		f.display_name = "Fuel Tank Explosion"
		f.category = "Explosives"
		f.has_gameplay_damage = true
		f.damage_radius = 7.0
		f.max_damage = 140.0
		f.impulse_force = 22.0
		f.screenshake_trauma = 0.5
		register(f)

	if not _registry.has("vfx_steam_leak"):
		var s := VFXDefinition.new()
		s.effect_id = "vfx_steam_leak"
		s.display_name = "Steam Vent / Pressure Leak"
		s.category = "Atmospheric"
		s.has_gameplay_damage = false
		s.screenshake_trauma = 0.05
		register(s)

	if not _registry.has("vfx_sparks"):
		var sp := VFXDefinition.new()
		sp.effect_id = "vfx_sparks"
		sp.display_name = "Electrical Short Circuit"
		sp.category = "Sparks"
		sp.has_gameplay_damage = true
		sp.damage_radius = 2.0
		sp.max_damage = 25.0
		sp.impulse_force = 4.0
		register(sp)
