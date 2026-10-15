class_name BotDifficulty
extends Resource
## Tunables for one bot skill level. Angles in degrees, times in seconds, distances in meters,
## chances 0..1 (per roll) or per second where noted. Presets live in resources/ai/.
## Bungie shipped no multiplayer bots in CE-Reach, so the presets follow the loose shape of
## Bungie campaign difficulty (faster reactions, tighter aim, more aggression on Legendary).
## Every Halo-derived number is APPROXIMATE.

@export var preset_name: String = "Normal"

@export_group("Perception")
## Full cone angle the bot can see in.
@export var fov_deg: float = 100.0
@export var sight_range: float = 50.0
## Gunfire inside this radius is heard (reveals the shooter's position).
@export var hearing_radius: float = 25.0

@export_group("Aim")
## Delay from acquiring a target to the first shot.
@export var reaction_time: float = 0.45
## Random +/- fraction applied to reaction_time.
@export_range(0.0, 1.0) var reaction_jitter: float = 0.2
## Angular aim error at acquisition.
@export var aim_error_deg: float = 6.0
## Error never converges below this.
@export var min_error_deg: float = 1.5
## Exponential convergence rate of the error, per second.
@export var convergence: float = 1.2
## Time constant of the aim chasing the target (bigger = laggier tracking).
@export var tracking_lag: float = 0.22
@export var max_turn_rate_deg: float = 270.0
## 0..1: how much of the tracking lag the bot cancels by leading a moving target.
@export_range(0.0, 1.0) var lead_skill: float = 0.3
## Fraction of aim_error_deg added back when the target reverses its strafe.
@export_range(0.0, 1.0) var strafe_error_bump: float = 0.5
## Extra angular slack (on top of the target's angular size) before the bot will fire.
@export var fire_tolerance_deg: float = 1.5
## Chance to aim at the head once the target's shield is down.
@export_range(0.0, 1.0) var headshot_bias: float = 0.15
@export var uses_zoom: bool = false

@export_group("Fire discipline")
## Semi-auto / burst pacing as a fraction of the weapon's max rate.
@export_range(0.1, 1.0) var semi_cadence: float = 0.6
## Rifle AUTO spray length at 10 m (shortened with range).
@export var spray_time: float = 0.6
## Pause between AUTO sprays at 10 m (lengthened with range) so bloom recovers.
@export var burst_pause: float = 0.35
## Past this range the rifle toggles to its alt (BURST) mode.
@export var burst_switch_range: float = 20.0
## Chance to swap to a loaded weapon instead of reloading mid-fight.
@export_range(0.0, 1.0) var weapon_switch_skill: float = 0.4

@export_group("Movement")
## Chance to reverse strafe direction at each strafe leg.
@export_range(0.0, 1.0) var strafe_frequency: float = 0.45
@export var strafe_min_time: float = 0.35
@export var strafe_max_time: float = 0.9
## Crouches per second while engaged (Halo 2 crouch-spam).
@export var crouch_chance: float = 0.1
## Jumps per second while engaged.
@export var jump_chance: float = 0.05
## Use the Elbow and Open Ramp skill-jump links (nav layer 2).
@export var use_skill_jumps: bool = false

@export_group("Temperament")
## 0..1: pushes into range, chases weak targets, retreats less.
@export_range(0.0, 1.0) var aggression: float = 0.4
## Retreat is considered when shield fraction drops to this (0 = only when popped).
@export_range(0.0, 1.0) var retreat_threshold: float = 0.1
## Chance to actually retreat each time the threshold is crossed.
@export_range(0.0, 1.0) var retreat_chance: float = 0.7
## Shield fraction at which a retreating bot re-engages.
@export_range(0.0, 1.0) var reengage_shield_fraction: float = 0.9
## Melee tries per second when in lunge range (always melees a shield-down target in range).
@export var melee_eagerness: float = 0.4
