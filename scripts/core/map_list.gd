class_name MapList
extends RefCounted
## Playable maps (static only). Order is the menu order. `id` is what goes on the wire and in
## user://settings.cfg; `arena` is the full match scene (level + Player + bots + NetMatch), the
## one Net loads for Bot Arena and for LAN.
## Custom levels from the Level Editor are maps too: id "custom:<file name>", arena
## arena_custom.tscn (CustomArena builds the level). all_maps() lists them after the built-ins.
## A custom id is kept if the level is known here (a file, the playtest, or a level a host sent:
## CustomLevels), so a client can load a map it didn't have before joining.

const MAPS: Array[Dictionary] = [
	{"id": "lockout", "name": "Lockout", "arena": "res://scenes/main/arena_lockout.tscn"},
	{
		"id": "headlong",
		"name": "Headlong (greybox)",
		"arena": "res://scenes/main/arena_headlong.tscn",
	},
	{
		"id": "ivory_tower",
		"name": "Ivory Tower (greybox)",
		"arena": "res://scenes/main/arena_ivory_tower.tscn",
	},
	{
		"id": "zanzibar",
		"name": "Zanzibar (greybox)",
		"arena": "res://scenes/main/arena_zanzibar.tscn",
	},
	{
		"id": "kamino",
		"name": "Kamino (greybox)",
		"arena": "res://scenes/main/arena_kamino.tscn",
	},
	# Test map: every weapon on a rack, dummies at range, a melee pit, a blast pad.
	{"id": "range", "name": "Weapon Range", "arena": "res://scenes/main/arena_range.tscn"},
]
const DEFAULT_ID := "lockout"


## Built-in maps, then every saved custom level.
static func all_maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = MAPS.duplicate()
	out.append_array(CustomLevels.map_entries())
	return out


static func has(id: String) -> bool:
	if CustomLevels.is_custom(id):
		return CustomLevels.exists(id)
	return _builtin_index(id) >= 0


## Index of id in all_maps(), or -1.
static func index_of(id: String) -> int:
	var maps := all_maps()
	for i in maps.size():
		if str(maps[i].id) == id:
			return i
	return -1


static func is_custom(id: String) -> bool:
	return CustomLevels.is_custom(id)


## id if known, else DEFAULT_ID (old settings files, a newer host's unknown map).
static func sanitize(id: String) -> String:
	return id if has(id) else DEFAULT_ID


## A custom level's name even before we have it (a client in the lobby).
static func name_of(id: String) -> String:
	if CustomLevels.is_custom(id):
		return CustomLevels.level_name_of(id).replace("_", " ")
	return str(MAPS[_builtin_index(sanitize(id))].name)


static func arena_of(id: String) -> String:
	var clean := sanitize(id)
	if CustomLevels.is_custom(clean):
		return CustomLevels.ARENA_SCENE
	return str(MAPS[_builtin_index(clean)].arena)


static func _builtin_index(id: String) -> int:
	for i in MAPS.size():
		if str(MAPS[i].id) == id:
			return i
	return -1
