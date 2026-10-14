# Standard Issue Rifle tuning (vs. HealthShield 70 shield / 45 health)

Damage 9 per round. Helmet and face both x2.0 (health only, no one-shots). No bleedthrough.
AUTO: 10 rounds/s, falloff 15 -> 40 m down to 0.5x. Spread 0.5 deg, +0.22/shot, max 2.6, -7/s.
BURST (secondary toggles): 3 rounds, 0.06 s apart, 0.35 s from last round to next burst
(0.47 s cycle, ~6.4 rounds/s effective). Falloff 35 -> 70 m down to 0.6x. Spread x0.4, bloom x0.5.
Magazine 32, reserve 128 (max 192), reload 2.1 s.

TTK = time from first to killing round, 100% hits. "Head" = every round after the shield breaks
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

Shield strip (70): AUTO 8 rounds / 0.70 s at 10 m (13 / 1.20 s at 35 m); BURST 8 rounds / 1.06 s
out to 35 m; pistol 4 / 0.67 s. Rifle-strip then pistol-finish costs a weapon swap (0.3 s equip).

What spread implies (cone half-angle -> miss radius; dummy body is 0.7 m wide, head ~0.36 m):
- AUTO rested 0.5 deg: 0.09 m at 10 m, 0.31 m at 35 m, 0.61 m at 70 m. Bloom hits the 2.6 deg cap
  after ~10 rounds held (net +0.22 - 0.7 per 0.1 s... recovery 0.7/round interval, so held-fire
  bloom grows only ~0 per round once recovery outruns it: effective sustained spread ~0.5-0.8 deg).
  Practically: near-100% at 10 m, ~60-80% body hits at 35 m, under 50% at 70 m. Real AUTO TTK at
  35-70 m is much worse than the table, by design.
- BURST 0.2 deg rested: 0.12 m at 35 m, 0.24 m at 70 m; bloom per round 0.044 deg is erased by the
  0.35 s gap. Near-100% body hits to 70 m, headshots realistic to ~35 m.
- Pistol: 0.1 deg rested, the precision finisher.
