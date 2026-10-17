class_name VFXDefinition
extends Resource
## Data-driven resource defining visual effects, audio, and physical gameplay impact.

@export_group("Identifiers")
@export var effect_id: String = "vfx_fuel_explosion"
@export var display_name: String = "Fuel Tank Explosion"
@export_enum("Explosives", "Fire", "Atmospheric", "Sparks") var category: String = "Explosives"

@export_group("Visuals & Audio")
@export var effect_scene: PackedScene
@export var sound_effect: AudioStream
@export var screenshake_trauma: float = 0.4

@export_group("Gameplay Impact")
@export var has_gameplay_damage: bool = true
@export var damage_radius: float = 6.0
@export var max_damage: float = 120.0
@export var impulse_force: float = 22.0
@export var armor_spalling: bool = true
