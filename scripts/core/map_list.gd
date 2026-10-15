class_name MapList
extends RefCounted
## Playable maps (static only). Order is the menu order. `id` is what goes on the wire and in
## user://settings.cfg; `arena` is the full match scene (level + Player + bots + NetMatch), the
## one Net loads for Bot Arena and for LAN.

const MAPS: Array[Dictionary] = [
	{"id": "lockout", "name": "Lockout", "arena": "res://scenes/main/arena_lockout.tscn"},
	{
		"id": "headlong",
		"name": "Headlong (greybox)",
		"arena": "res://scenes/main/arena_headlong.tscn",
	},
]
const DEFAULT_ID := "lockout"


static func has(id: String) -> bool:
	return index_of(id) >= 0


## Index of id in MAPS, or -1.
static func index_of(id: String) -> int:
	for i in MAPS.size():
		if str(MAPS[i].id) == id:
			return i
	return -1


## id if known, else DEFAULT_ID (old settings files, a newer host's unknown map).
static func sanitize(id: String) -> String:
	return id if has(id) else DEFAULT_ID


static func name_of(id: String) -> String:
	return str(MAPS[index_of(sanitize(id))].name)


static func arena_of(id: String) -> String:
	return str(MAPS[index_of(sanitize(id))].arena)
