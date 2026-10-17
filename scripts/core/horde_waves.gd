class_name HordeWaves
extends RefCounted
## Horde wave composition (static only, so it's testable and easy to retune). Waves come in
## rounds of ROUND_LENGTH; each wave is a list of squads, each squad one Orta. The five-wave
## round walks through the enemy board's encounter grammar, then repeats harder:
##   1 Screen     an Azab line and its Bolukbasi
##   2 Raiders    the line with Okcu behind it, and an Akinji pair on the flank
##   3 Gunline    the line, and a Janissary pair behind it
##   4 Overwatch  line + Okcu, Akinji raider + marksman, Odabasi + Nefer
##   5 The Orta   the board's full Phase 0 orta, Corbaci included (kill him: the orta breaks)
## Every BOSS_EVERY waves the finale is the Aga's guard instead. Each later round adds
## Azabs to every line, an extra Azab squad, and from round 3 a Nefer to every Janissary squad.
## Ids are EnemyType file names in resources/enemies/new_ottoman/.

const ROUND_LENGTH := 5
const BOSS_EVERY := 10
## Alive at once stays under this: extra squads wait for room (HordeMatch).
const MAX_ALIVE := 20

const ROUND := [
	{"name": "Screen", "squads": [["bolukbasi", "azab", "azab", "azab", "azab"]]},
	{
		"name": "Raiders",
		"squads": [["bolukbasi", "azab", "azab", "azab", "okcu", "okcu"], ["akinji", "akinji"]],
	},
	{"name": "Gunline", "squads": [["bolukbasi", "azab", "azab", "azab", "azab"], ["nefer", "nefer"]]},
	{
		"name": "Overwatch",
		"squads":
		[
			["bolukbasi", "azab", "azab", "azab", "okcu"],
			["akinji", "akinji_marksman"],
			["odabasi", "nefer"],
		],
	},
	{
		"name": "The Orta",
		"squads":
		[
			[
				"bolukbasi", "azab", "azab", "azab", "azab", "okcu",
				"akinji", "akinji_marksman", "nefer", "nefer", "corbaci",
			],
		],
	},
]
const BOSS := {
	"name": "The Aga",
	"squads":
	[
		["aga", "odabasi", "nefer", "nefer"],
		["akinci_beyi", "akinji", "akinji"],
		["bolukbasi", "azab", "azab", "azab", "azab"],
	],
}
## Points per kill (the scoreboard's Points column). Officers and plate are worth more.
const POINTS := {
	"azab": 10, "okcu": 15, "bolukbasi": 30,
	"akinji": 20, "akinji_marksman": 30, "akinci_beyi": 80,
	"nefer": 50, "odabasi": 60, "corbaci": 120, "aga": 500,
}


## Round number (1-based) of wave (1-based).
static func round_of(wave: int) -> int:
	return (maxi(wave, 1) - 1) / ROUND_LENGTH + 1


static func is_round_end(wave: int) -> bool:
	return maxi(wave, 1) % ROUND_LENGTH == 0


static func is_boss(wave: int) -> bool:
	return maxi(wave, 1) % BOSS_EVERY == 0


## {"name": String, "squads": Array of Array[String]} for wave (1-based).
static func wave(wave_number: int) -> Dictionary:
	var n := maxi(wave_number, 1)
	var base: Dictionary = BOSS if is_boss(n) else ROUND[(n - 1) % ROUND_LENGTH]
	var extra := round_of(n) - 1  # 0 in the first round
	var squads: Array = []
	for squad: Array in base.squads:
		var members: Array[String] = []
		members.assign(squad)
		if members.has("bolukbasi"):
			for i in mini(extra, 3):
				members.append("azab")
		var janissaries := members.has("nefer") or members.has("odabasi")
		if janissaries and extra >= 2 and not members.has("aga"):
			members.append("nefer")
		squads.append(members)
	if extra >= 1 and not is_boss(n) and not is_round_end(n):
		squads.append(["bolukbasi", "azab", "azab", "azab"] as Array[String])
	return {"name": str(base.name), "squads": squads}


static func enemy_count(wave_number: int) -> int:
	var total := 0
	for squad: Array in wave(wave_number).squads:
		total += squad.size()
	return total


static func points_for(type_id: StringName) -> int:
	return int(POINTS.get(String(type_id), 10))
