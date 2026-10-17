class_name GameModes
extends RefCounted
## Game modes (static only), the MapList of rules. Order is the menu order. `id` is what goes
## on the wire and in user://settings.cfg. GameRules applies a mode to the arena.
##
## Rule keys (all optional; missing = the arena's own setup, i.e. Slayer):
##   start_weapons  Array of weapon scene paths every combatant spawns with (players and bots)
##   shields        false = no shields: health only
##   power_weapons  false = placed pickups whose WeaponData.power_weapon is set never spawn
##   objective      "ctf" = Capture the Flag (CtfMatch): kills no longer win, captures do
##                  "horde" = Horde (HordeMatch): co-op waves of New Ottoman enemies
##   teams          true = needs Red vs Blue; a free-for-all player count becomes TEAM_FALLBACK
##   coop           true = everyone on one side (Horde); a team player count becomes
##                  COOP_FALLBACK, since Red vs Blue would turn the defenders on each other
##   capture_limit  captures to win (objective "ctf")
##   bots           false = no bots spawn (NetMatch), whatever the bot count says
##   score          false = kills never end the match (SpawnManager.kill_win)
##   infinite_ammo  true = carried reserves, batteries and grenades refill (GameRules)
##   online         false = offline only (Bot Arena): hidden from the LAN host and lobby
##                  (no mode uses it today; Horde replicates since protocol 11)

const MODES: Array[Dictionary] = [
	{"id": "slayer", "name": "Slayer"},
	{
		"id": "swat",
		"name": "SWAT",
		"start_weapons": ["res://scenes/weapons/service_pistol.tscn"],
		"shields": false,
		"power_weapons": false,
	},
	{
		"id": "ctf",
		"name": "Capture the Flag",
		"objective": "ctf",
		"teams": true,
		"capture_limit": 3,
	},
	{
		# Co-op waves of New Ottoman enemies; bots and every human fight on one side.
		"id": "horde",
		"name": "Horde",
		"objective": "horde",
		"score": false,
		"coop": true,
	},
	{
		# Weapon testing (pairs with the Weapon Range map, works on any map, LAN too).
		"id": "range",
		"name": "Weapon Range",
		"bots": false,
		"score": false,
		"infinite_ammo": true,
	},
]
const DEFAULT_ID := "slayer"
## The team player count a teams-only mode falls back to from free-for-all (same 8 seats).
const TEAM_FALLBACK := "team_4v4"
## The player count co-op rules fall back to from a team count.
const COOP_FALLBACK := "ffa"


static func has(id: String) -> bool:
	return index_of(id) >= 0


## Index of id in MODES, or -1.
static func index_of(id: String) -> int:
	for i in MODES.size():
		if str(MODES[i].id) == id:
			return i
	return -1


## id if known, else DEFAULT_ID (old settings files, a newer host's unknown mode).
static func sanitize(id: String) -> String:
	return id if has(id) else DEFAULT_ID


static func name_of(id: String) -> String:
	return str(get_mode(id).name)


static func get_mode(id: String) -> Dictionary:
	return MODES[index_of(sanitize(id))]


static func objective_of(id: String) -> String:
	return str(get_mode(id).get("objective", ""))


static func is_ctf(id: String) -> bool:
	return objective_of(id) == "ctf"


static func is_horde(id: String) -> bool:
	return objective_of(id) == "horde"


## False for offline-only rules (Horde): the LAN pickers skip them and Net refuses to host them.
static func allows_online(id: String) -> bool:
	return bool(get_mode(id).get("online", true))


## Rules ids in menu order; online = true leaves out the offline-only ones.
static func ids(online: bool = false) -> Array[String]:
	var out: Array[String] = []
	for mode in MODES:
		if not online or bool(mode.get("online", true)):
			out.append(str(mode.id))
	return out


static func allows_bots(id: String) -> bool:
	return bool(get_mode(id).get("bots", true))


static func keeps_score(id: String) -> bool:
	return bool(get_mode(id).get("score", true))


static func is_coop(id: String) -> bool:
	return bool(get_mode(id).get("coop", false))


static func needs_teams(id: String) -> bool:
	return bool(get_mode(id).get("teams", false))


static func capture_limit(id: String) -> int:
	return int(get_mode(id).get("capture_limit", 3))


## The GameMode (player count) id to play `rules` with: game_mode itself, TEAM_FALLBACK when
## the rules need teams and game_mode is free-for-all, or COOP_FALLBACK when the rules are
## co-op and game_mode has teams.
static func fit_mode(rules: String, game_mode: String) -> String:
	if needs_teams(rules) and not GameMode.is_team(game_mode):
		return TEAM_FALLBACK
	if is_coop(rules) and GameMode.is_team(game_mode):
		return COOP_FALLBACK
	return game_mode
