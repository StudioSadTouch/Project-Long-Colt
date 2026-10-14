# Service Pistol tuning (vs. HealthShield 70 shield / 45 health)

Zone multipliers apply to health only. A shot that breaks the shield does not spill (no bleedthrough).
Damage 23, armored helmet x2.0, unarmored face/neck x5.0, falloff 35 -> 70 m down to 0.6x.

| Range | Per shot | Shield (70) | Then health (45) | Total |
|---|---|---|---|---|
| <= 35 m | 23 | 4 body (23*4 = 92, overflow lost) | 1 helmet (46) or 1 face (115) | **4 body + 1 head = 5** |
| <= 35 m, body only | 23 | 4 | 2 body (46) | 6 |
| 70 m floor | 13.8 | 6 body (82.8) | 2 helmet (27.6*2 = 55.2) or 1 face (13.8*5 = 69) | 6 + 2 helmet = 8, or 6 + 1 face = 7 |
| 70 m floor, body only | 13.8 | 6 | 4 body (55.2) | 10 |

- Headshots while shields are up do base damage (23) to the shield; the bonus only lands on bare health.
- Helmet one-shot needs 2.0 * damage >= 45, so damage >= 22.5 at full range; 23 is the smallest round number.
- Face one-shot at the floor needs 13.8 * m >= 45, so m >= 3.27; 5.0 keeps a wide margin.
- Close-range optimal TTK: 5 shots at 4.5/s = 4 intervals = ~0.89 s.
- Melee (70) breaks a full shield exactly with no spill; melee + 1 headshot kills.
