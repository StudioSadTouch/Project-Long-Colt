class_name WeaponAudio
extends RefCounted
## A weapon's own fire sound, from its scene's WeaponFx, for anyone who plays it from outside
## the weapon (CombatFeedback's 3D gunfire for other combatants). Looking it up by scene keeps
## new guns audible with no table to update: the New Ottoman weapons inherit their base scene's
## WeaponFx, and a renamed weapon (the rocket launcher, once "Directed Energy Rifle") still
## resolves. Scene lookups are cached per path.

## scene path -> AudioStream, or null for a weapon without a fire sound (blades).
static var _cache: Dictionary = {}


## The fire sound of a live weapon: its own WeaponFx child (player and puppet weapons), else
## its source scene's (a BotWeapon is built in code), else its scene file's. Null if none.
static func fire_sound_of(weapon: Node) -> AudioStream:
	if weapon == null or not is_instance_valid(weapon):
		return null
	var fx := weapon.get_node_or_null(^"WeaponFx") as WeaponFx
	if fx != null:
		return fx.fire_sound
	var scene: PackedScene = null
	var source: Variant = weapon.get(&"source_scene")
	if source is PackedScene:
		scene = source
	elif weapon.scene_file_path != "":
		scene = load(weapon.scene_file_path) as PackedScene
	return fire_sound_of_scene(scene)


## The fire sound in a weapon scene's WeaponFx (cached per scene path), or null.
static func fire_sound_of_scene(scene: PackedScene) -> AudioStream:
	if scene == null:
		return null
	var key := scene.resource_path
	if key != "" and _cache.has(key):
		return _cache[key]
	var sound: AudioStream = null
	var instance := scene.instantiate()
	if instance != null:
		var fx := instance.get_node_or_null(^"WeaponFx") as WeaponFx
		if fx != null:
			sound = fx.fire_sound
		instance.free()
	if key != "":
		_cache[key] = sound
	return sound
