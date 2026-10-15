class_name GrenadeData
extends Resource
## Tuning for one grenade type (resources/weapons/*_grenade.tres). Distances in meters, times in
## seconds. Damage goes through HealthShield like any shot: info carries zone_multiplier 1.0,
## shield_multiplier and bleedthrough from here, "weapon" = display_name and "source" = the
## thrower (kill credit, including self-kills).

## Values are stored as ints in .tres files: append, never reorder.
## FRAG bounces and goes off fuse_time after the throw. STICKY sticks to the first thing it
## touches (world or a body) and goes off fuse_time after sticking.
enum Kind { FRAG, STICKY }

@export var display_name: String = "Grenade"
## Short HUD name.
@export var short_name: String = "FRAG"
@export var kind: Kind = Kind.FRAG

@export_group("Throw")
## Launch speed along the view direction.
@export var throw_speed: float = 18.0
## Extra upward speed so a level throw arcs (Halo-style lob).
@export var throw_lift: float = 3.5
## Fraction of the thrower's velocity added to the grenade.
@export_range(0.0, 1.0) var inherit_velocity: float = 0.5
## Seconds after a throw before the thrower can throw again.
@export var throw_cooldown: float = 0.8

@export_group("Physics")
@export var radius: float = 0.12
@export var mass: float = 0.5
@export_range(0.0, 1.0) var bounce: float = 0.35
@export_range(0.0, 1.0) var friction: float = 0.6
## Seconds to detonation: after the throw (FRAG) or after sticking (STICKY).
@export var fuse_time: float = 2.5
## STICKY only: also goes off this long after the throw if it never sticks (thrown into the sky).
@export var max_flight_time: float = 6.0

@export_group("Explosion")
## Damage at the centre. Full out to inner_radius, linear to 0 at blast_radius.
@export var damage: float = 100.0
@export var inner_radius: float = 1.5
@export var blast_radius: float = 5.0
@export var shield_damage_multiplier: float = 1.0
## Overflow of the hit that breaks a shield spills into health (with zone 1.0).
@export var bleedthrough: bool = true

@export_group("Look")
@export var color: Color = Color(0.25, 0.3, 0.22)
## Emissive glow (sticky); alpha 0 = none.
@export var glow: Color = Color(0, 0, 0, 0)
@export var flash_color: Color = Color(1.0, 0.7, 0.35)
