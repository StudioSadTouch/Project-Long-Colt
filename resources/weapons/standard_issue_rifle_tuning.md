# Standard Issue Rifle tuning (vs. HealthShield 70 shield / 45 health)

Damage 9 per round. Helmet and face both x2.0 (health only, no one-shots). No bleedthrough.
AUTO: 10 rounds/s, falloff 15 -> 40 m down to 0.5x. Spread 0.5 deg, +0.25/round, max 2.6, recovers 1.1 deg/s.
BURST (secondary toggles): 3 rounds, 0.06 s apart, 0.35 s from last round to next burst
(0.47 s cycle, ~6.4 rounds/s effective). Falloff 35 -> 70 m down to 0.6x (alt_min_damage_multiplier). Spread x0.4, bloom x0.5.
Magazine 32, reserve 128 (max 192), reload 2.1 s.

TTK = time from the first round fired (t = 0) to the killing round, 100% hits. "Head" = every round after the shield breaks
hits helmet or face (x2). The round that breaks the shield never spills.

| Mode | Range | Per round | Body only | Head finish |
|---|---|---|---|---|
| AUTO | 10 m | 9.0 | 13 rounds, 1.20 s | 11 rounds, 1.00 s |
| AUTO | 35 m | 5.4 | 22 rounds, 2.10 s | 18 rounds, 1.70 s |
| AUTO | 70 m | 4.5 | 26 rounds, 2.50 s | 21 rounds, 2.00 s |
| BURST | 10 m | 9.0 | 13 rounds (5 bursts), 1.88 s | 11 rounds (4 bursts), 1.47 s |
| BURST | 35 m | 9.0 | 13 rounds, 1.88 s | 11 rounds, 1.47 s |
| BURST | 70 m | 5.4 | 22 rounds (8 bursts), 3.29 s | 18 rounds (6 bursts), 2.47 s |
| Pistol (ref) | <= 35 m | 22 | 7, 1.33 s | 6 helmet 1.11 s / 5 face 0.89 s |
| Pistol (ref) | 70 m | 13.2 | 10, 2.00 s | 8 helmet 1.56 s / 7 face 1.33 s |

Shield strip (70), first round to the breaking round:
- AUTO: 8 rounds / 0.70 s at 10 m, 13 / 1.20 s at 35 m, 16 / 1.50 s at 70 m.
- BURST: 8 rounds / 1.00 s to 35 m (rounds at 0, .06, .12, .47, .53, .59, .94, 1.00), 13 / 1.88 s at 70 m.
- Pistol: 4 / 0.67 s to 35 m, 6 / 1.11 s at 70 m.
Rifle-strip then pistol-finish costs a weapon swap (0.3 s pistol equip).

What spread implies (cone half-angle -> miss radius; dummy body is 0.7 m wide, head ~0.36 m):
- AUTO rested 0.5 deg: 0.09 m at 10 m, 0.31 m at 35 m, 0.61 m at 70 m. Held fire nets about
  +0.14 deg per round (0.25 added, 0.11 recovered per 0.1 s), reaching the 2.6 deg cap after ~15
  rounds (~1.5 s); full recovery takes ~1.9 s. At the cap: 0.45 m at 10 m, 1.6 m at 35 m.
  Practically: near-100% body hits at 10 m; at 35 m the first ~6 rounds land, then accuracy
  falls off (rough guess 50-70% over a kill); well under 50% at 70 m. Real AUTO TTK beyond
  ~20 m is much worse than the table, by design. Short controlled bursts reset bloom.
- BURST 0.2 deg rested: 0.12 m at 35 m, 0.24 m at 70 m. Bloom adds 0.125 deg per round
  (0.375 per burst before the x0.4 spread multiplier); the 0.47 s cycle recovers 0.52 deg, so
  bursts don't stack bloom at the intended cadence; spamming faster isn't possible. Near-100% body hits to 70 m, headshots realistic to ~35 m.
- Pistol: 0.1 deg rested, the precision finisher.
