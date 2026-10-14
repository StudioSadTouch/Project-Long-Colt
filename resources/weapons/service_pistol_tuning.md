# Service Pistol tuning (vs. HealthShield 70 shield / 45 health)

Damage 22. Helmet (armored) x2.0, face/neck (unarmored) x5.0. Zone multipliers apply to
health only. A shot that breaks the shield does not spill into health (no bleedthrough).
Falloff: full damage to 35 m, linear to 0.6x at 70 m, flat beyond.

| Range | Per shot | Shield (70) | Health (45) | Total |
|---|---|---|---|---|
| <= 35 m, body only | 22 | 4 (88, overflow lost) | 3 body (66; 2 = 44 < 45) | **7** |
| <= 35 m, helmet finish | 22 | 4 | 2 helmet (88; 1 = 44 < 45) | **6** |
| <= 35 m, face finish | 22 | 4 | 1 face (110) | **5** |
| 70 m floor, body only | 13.2 | 6 (79.2; 5 = 66 < 70) | 4 body (52.8; 3 = 39.6) | **10** |
| 70 m floor, helmet finish | 13.2 | 6 | 2 helmet (52.8; 1 = 26.4) | **8** |
| 70 m floor, face finish | 13.2 | 6 | 1 face (66) | **7** |

Notes
- Headshots while the shield is up do base damage (22) to the shield.
- A single helmet hit on bare health does 44, one short of 45: the helmet is no longer a
  one-shot finisher; it takes two (or helmet + body: 44 + 22).
- Face one-shots bare health at any range: 13.2 * 5.0 = 66 >= 45 (needs m >= 3.41).
- Close-range TTK at 4.5 shots/s (interval 0.222 s): 5 shots = 0.89 s, 6 = 1.11 s, 7 = 1.33 s.

Melee (70, shield multiplier 1.0, no bleedthrough, cooldown 0.8 s)
- On a full shield: breaks it exactly (70), no health damage.
- On bare health: kills (70 >= 45).
- Melee then face shot: kills (2 hits). Melee then helmet: 44, needs a second shot.
- Melee then melee: kills, gated by the 0.8 s cooldown.
- Shield broken by shots, then melee: kills.

## Reload animation

`reload_insert_fraction` is the mag-insert beat as a fraction of `reload_time`; ammo moves there (once). The viewmodel `reload_empty` / `reload_tactical` animations key the mag seat at the same fraction of their authored length and play at `length / reload_time`, so changing `reload_time` retimes them. If you retime the insert key in an animation, update this value to match.
