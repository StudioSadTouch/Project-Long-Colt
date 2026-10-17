class_name GameMode
extends RefCounted
## Match rules (static only), the MapList of game types. `id` goes on the wire and in
## user://settings.cfg. `max_players` is the session cap (humans + bots); `teams` is 0 for
## free-for-all or 2 for Red vs Blue; `score_limit` is kills to win (per player in FFA, per
## team total in team modes). Values are the Halo 2 Slayer defaults.
##
## Team ids: TEAM_RED / TEAM_BLUE are the `team` field / meta that ArenaEvents.is_hostile
## compares. FFA keeps unique teams per combatant (SpawnManager / NetMatch assign them).

const MODES: Array[Dictionary] = [
	{"id": "ffa", "name": "Free for All", "max_players": 8, "teams": 0, "score_limit": 25},
	{
		"id": "team_4v4",
		"name": "Team Slayer 4v4",
		"max_players": 8,
		"teams": 2,
		"score_limit": 50,
	},
	{
		"id": "team_slayer",
		"name": "Team Slayer 8v8",
		"max_players": 16,
		"teams": 2,
		"score_limit": 50,
	},
]
const DEFAULT_ID := "ffa"
## Largest max_players of any mode: the ENet server is created for this many and Net rejects
## joins above the current mode's cap.
const MAX_PLAYERS_ANY := 16

const TEAM_RED := 1
const TEAM_BLUE := 2
const TEAMS: Array[int] = [TEAM_RED, TEAM_BLUE]
const TEAM_NAMES := {TEAM_RED: "Red Team", TEAM_BLUE: "Blue Team"}
## Halo 2 team armor primaries (sRGB); also the scoreboard tint.
const TEAM_COLORS := {TEAM_RED: Color(0.62, 0.12, 0.1), TEAM_BLUE: Color(0.14, 0.26, 0.6)}
## Spawn marker name prefixes. A map without team markers uses every spawn for everyone.
const SPAWN_PREFIX := {TEAM_RED: "SPAWN_Red", TEAM_BLUE: "SPAWN_Blue"}
const FFA_SPAWN_PREFIX := "SPAWN_FFA"


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


static func info(id: String) -> Dictionary:
	return MODES[index_of(sanitize(id))]


static func name_of(id: String) -> String:
	return str(info(id).name)


static func max_players(id: String) -> int:
	return int(info(id).max_players)


static func is_team(id: String) -> bool:
	return int(info(id).teams) > 0


static func score_limit(id: String) -> int:
	return int(info(id).score_limit)


static func team_name(team: int) -> String:
	return str(TEAM_NAMES.get(team, "Team %d" % team))


static func team_color(team: int) -> Color:
	return TEAM_COLORS.get(team, PlayerColor.default_color())


static func is_team_id(team: int) -> bool:
	return TEAMS.has(team)


## Team id -> summed kills of a SpawnManager / NetMatch scores Dictionary (entries carry
## "team"; FFA entries are -1 and are skipped).
static func team_totals(scores: Dictionary) -> Dictionary:
	var totals := {}
	for team in TEAMS:
		totals[team] = 0
	for who: Variant in scores:
		var entry: Dictionary = scores[who]
		var team := int(entry.get("team", -1))
		if totals.has(team):
			totals[team] += int(entry.get("kills", 0))
	return totals
