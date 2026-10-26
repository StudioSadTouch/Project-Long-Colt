class_name ArmorLoadout
extends RefCounted
## Hospitaller modular armor: the slots, their variants, and the loadout <-> string codec
## (static only). A loadout is a Dictionary slot id -> variant id, e.g.
##   {"helmet": "hospitaller", "chest": "hospitaller", "shoulders": "exo", "arms": "bracer", "legs": "exo"}
## It travels as a string ("helmet=hospitaller,chest=exo,...") in settings.cfg ([profile]
## armor) and in the Net player info ("armor").
##
## Contract with the model (assets/models/characters/hospitaller.glb, built by
## tools/hospitaller/build_hospitaller.py): every armor mesh is named
## AR_<slot>_<variant>_<piece>; PlayerModel shows the pieces of the chosen variant per slot.
## Keep SLOTS / VARIANTS in step with CATALOGUE in tools/hospitaller/hosp_armor.py.

const SLOTS: Array[String] = ["helmet", "chest", "shoulders", "arms", "legs"]
const SLOT_NAMES := {
	"helmet": "Helmet",
	"chest": "Chest",
	"shoulders": "Shoulders",
	"arms": "Arms",
	"legs": "Legs",
}
## slot -> [{id, name}], menu order; the first entry is the slot's default.
const VARIANTS := {
	"helmet": [
		{"id": "hospitaller", "name": "Hospitaller"},
		{"id": "warden", "name": "Warden"},
		{"id": "vanguard", "name": "Vanguard"},
		{"id": "sentry", "name": "Sentry"},
		{"id": "lancer", "name": "Lancer"},
	],
	"chest": [
		{"id": "hospitaller", "name": "Hospitaller"},
		{"id": "breastplate", "name": "Breastplate"},
		{"id": "exo", "name": "Exo Harness"},
		{"id": "carrier", "name": "Plate Carrier"},
		{"id": "grenadier", "name": "Grenadier"},
	],
	"shoulders": [
		{"id": "exo", "name": "Exo Cans"},
		{"id": "pauldron", "name": "Pauldrons"},
		{"id": "heavy", "name": "Heavy"},
	],
	"arms": [
		{"id": "bracer", "name": "Bracers"},
		{"id": "strut", "name": "Struts"},
	],
	"legs": [
		{"id": "exo", "name": "Exo Plates"},
		{"id": "light", "name": "Light Kit"},
	],
}


static func default_loadout() -> Dictionary:
	var out := {}
	for slot: String in SLOTS:
		out[slot] = VARIANTS[slot][0].id
	return out


static func has_variant(slot: String, id: String) -> bool:
	return variant_index(slot, id) >= 0


static func variant_index(slot: String, id: String) -> int:
	var list: Array = VARIANTS.get(slot, [])
	for i in list.size():
		if list[i].id == id:
			return i
	return -1


static func variant_name(slot: String, id: String) -> String:
	var i := variant_index(slot, id)
	return VARIANTS[slot][i].name if i >= 0 else id


## Every slot present and valid; unknown slots dropped, bad variants reset to the default.
static func sanitize(loadout: Dictionary) -> Dictionary:
	var out := default_loadout()
	for slot: String in SLOTS:
		var id := str(loadout.get(slot, ""))
		if has_variant(slot, id):
			out[slot] = id
	return out


## The slot's next (step +1) or previous (-1) variant, wrapping.
static func cycle(loadout: Dictionary, slot: String, step: int) -> Dictionary:
	var out := sanitize(loadout)
	var list: Array = VARIANTS[slot]
	var i := posmod(variant_index(slot, out[slot]) + step, list.size())
	out[slot] = list[i].id
	return out


static func encode(loadout: Dictionary) -> String:
	var clean := sanitize(loadout)
	var parts: PackedStringArray = []
	for slot: String in SLOTS:
		parts.append("%s=%s" % [slot, clean[slot]])
	return ",".join(parts)


## Lenient: garbage, missing or unknown entries fall back to the defaults.
static func decode(text: String) -> Dictionary:
	var raw := {}
	for pair: String in text.split(",", false):
		var kv := pair.split("=", false, 1)
		if kv.size() == 2:
			raw[kv[0].strip_edges()] = kv[1].strip_edges()
	return sanitize(raw)


## Shows `loadout` on target's body (the model itself or its PlayerModel child); no-op on
## models without armor (the capsule placeholder).
static func apply(target: Node, loadout: Dictionary) -> void:
	var model := PlayerColor.model_of(target)
	if model != null and model.has_method(&"set_armor_loadout"):
		model.call(&"set_armor_loadout", loadout)
