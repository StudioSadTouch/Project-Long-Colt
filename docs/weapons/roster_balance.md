# Five-gun roster: balance sheet (v1, pre-implementation)

Target: Bungie-era Halo (CE through Reach, Halo 2 first). Every number below is checked against
HealthShield (70 shield / 45 health) and the shared Weapon code:

- No bleedthrough on any gun: the round (or pellet) that breaks the shield is absorbed, its
  overflow is lost.
- Zone multipliers (helmet = `hitbox_head_armored`, face/neck = `hitbox_head_unarmored`) apply to
  health only. While the shield is up every zone does base damage to the shield.
- `shield_damage_multiplier` applies to shield damage only. New: `health_damage_multiplier`
  (default 1.0) scales health damage only, on top of the zone multiplier (energy weapons < 1).
- Falloff: full damage to `falloff_start`, linear to `min_damage_multiplier` at `falloff_end`,
  flat beyond.
- TTK is measured from the first shot (t = 0) to the killing shot, all hits, so it is
  (shots - 1) / fire_rate. "Helmet" and "Face" mean every shot after the shield breaks hits
  that zone. The shots are paced at the gun's max cadence.
- Halo 2 bullet bend with face one-shots (`aim_bend_allow_head = true`) is Morgon-approved
  design. Bend only moves rays that would have missed, so it changes hit rates, not the table.
- Numbers come from a small script that mirrors HealthShield and Weapon._falloff
  (/workspace/scratch/ttk.py, not committed).

## 1. The five guns at a glance

| Gun | Role | Fire | Damage | Helmet / Face | Shield / Health mult | Effective range | Falloff (start -> end, floor) |
|---|---|---|---|---|---|---|---|
| Service Pistol (existing) | Spawn sidearm, precision finisher | SEMI 4.5/s, 2x zoom | 22 | x2.0 / x5.0 | 1.0 / 1.0 | 0-50 m | 35 -> 70 m, 0.6 |
| Standard Issue Rifle (existing) | Spawn primary, close-mid sprayer; burst for mid | AUTO 10/s; BURST 3 rounds (0.47 s cycle) | 9 | x2.0 / x2.0 | 1.0 / 1.0 | AUTO 0-20 m, BURST 0-40 m | AUTO 15 -> 40 m, 0.5; BURST 35 -> 70 m, 0.6 |
| Marksman Carbine (new) | Map pickup, mid-long precision | SEMI 3.0/s, 2.5x scope | 28 | x2.0 / x2.5 | 1.0 / 1.0 | 15-75 m | 50 -> 90 m, 0.7 |
| Combat Shotgun (new) | Power weapon, close range | SEMI pump 1.2/s, 10 pellets | 10 per pellet (100) | x1.0 / x1.0 | 1.0 / 1.0 | 0-6 m (one-shot), useless past 10 m | 3 -> 12 m, 0.1 |
| Directed Energy Rifle (new) | Power weapon, shield stripper | AUTO 8/s bolts; alt mode: charge shot | 10 (charge 50) | x1.0 / x1.0 | 1.6 / 0.75 | 0-25 m | 20 -> 45 m, 0.5 (charge 25 -> 50 m, 0.6) |

Values verified from the .tres files for pistol (`resources/weapons/service_pistol.tres`) and
rifle (`resources/weapons/standard_issue_rifle.tres`); both unchanged by this work.

## 2. TTK table (70 shield / 45 health, all hits)

Shots to kill (time). Strip = shots to break the shield.

| Gun | Range | Per shot | Strip | Body | Helmet | Face |
|---|---|---|---|---|---|---|
| Pistol | <= 35 m | 22 | 4 (0.67 s) | 7 (1.33 s) | 6 (1.11 s) | **5 (0.89 s)** |
| Pistol | 50 m | 18.2 | 4 (0.67 s) | 7 (1.33 s) | 6 (1.11 s) | 5 (0.89 s) |
| Pistol | >= 70 m | 13.2 | 6 (1.11 s) | 10 (2.00 s) | 8 (1.56 s) | 7 (1.33 s) |
| Rifle AUTO | 10 m | 9 | 8 (0.70 s) | 13 (1.20 s) | 11 (1.00 s) | 11 (1.00 s) |
| Rifle AUTO | 35 m | 5.4 | 13 (1.20 s) | 22 (2.10 s) | 18 (1.70 s) | 18 (1.70 s) |
| Rifle AUTO | >= 40 m | 4.5 | 16 (1.50 s) | 26 (2.50 s) | 21 (2.00 s) | 21 (2.00 s) |
| Rifle BURST | <= 35 m | 9 | 8 (1.00 s) | 13 (1.88 s) | 11 (1.47 s) | 11 (1.47 s) |
| Rifle BURST | 70 m | 5.4 | 13 (1.88 s) | 22 (3.29 s) | 18 (2.47 s) | 18 (2.47 s) |
| Carbine | <= 50 m | 28 | 3 (0.67 s) | 5 (1.33 s) | **4 (1.00 s)** | 4 (1.00 s) |
| Carbine | 70 m | 23.8 | 3 (0.67 s) | 5 (1.33 s) | 4 (1.00 s) | 4 (1.00 s) |
| Carbine | >= 90 m | 19.6 | 4 (1.00 s) | 7 (2.00 s) | 6 (1.67 s) | 5 (1.33 s) |
| DER bolts | <= 20 m | 16 shield / 7.5 health | 5 (0.50 s) | 11 (1.25 s) | 11 (1.25 s) | 11 (1.25 s) |
| DER bolts | 35 m | 11.2 / 5.25 | 7 (0.75 s) | 16 (1.88 s), overheats at 14 | same | same |
| DER bolts | >= 45 m | 8 / 3.75 | 9 (1.00 s) | 21 (2.50 s), overheats | same | same |
| DER charge | <= 25 m | 80 shield / 37.5 health | **1** (after 0.75 s charge) | never alone (37.5 < 45) | - | - |
| Shotgun | <= 3 m, 10 pellets | 100 | 1st shot strips + 30 health | **2 shots (0.83 s)**, or shot + melee | same (no head bonus) | same |
| Shotgun | <= 3 m vs **unshielded** | 100 | - | **1 shot** (needs 5 of 10 pellets) | - | - |
| Shotgun | 6 m vs unshielded | 7 per pellet | - | 1 shot needs 7+ pellets (~92% of shots with centred aim at 4 deg) | - | - |
| Shotgun | 8 m vs unshielded | 5 per pellet | - | 1 shot only with all 10 | - | - |
| Shotgun | 10 m, full shield | 3 per pellet | - | 4+ shots: not a 10 m gun | - | - |

Pellets are separate hits, each going through HealthShield on its own. The "breaking shot
doesn't carry through" rule is therefore per pellet: the pellet that breaks the shield loses its
overflow, and every pellet after it in the same blast hits health. At point blank, 10 x 10:
pellets 1-7 take exactly 70 shield, pellets 8-10 do 30 health. So the shotgun never one-shots a
full shield, as specified, but shot + melee (70) or shot + any follow-up kills.
Tuning note for Morgon: 12 damage per pellet makes it a Halo 2/3-style one-shot on a full shield at
<= 3 m with all 10 pellets (6 to break, 4 x 12 = 48 health). It is not shipped that way.

Melee (70, all five guns, no bleedthrough): breaks a full shield exactly, kills bare health.

### Combos (the Halo sandbox loop)

| Combo | Time to kill from full shield | Notes |
|---|---|---|
| DER charge -> Pistol face | ~0.75 s charge (can be pre-charged before the peek) + 0.30 s pistol equip -> ~0.3 s after release | The Halo 2 "noob combo". The DER overheats after every charge shot, so the swap is forced. |
| DER charge -> Carbine helmet | + 0.45 s carbine equip -> ~0.45 s after release | Helmet one-shots with the carbine. |
| DER charge -> melee | ~0.1-0.3 s after release (lunge 3.5 m) | |
| DER bolts (5) -> Pistol face | 0.50 s + 0.30 s equip + 1 shot = ~0.8 s | |
| Shotgun -> melee | ~0.1-0.3 s after the blast | Classic CE/H2 close-quarters combo. |
| Melee -> Pistol face | melee then 1 shot | Unchanged. |
| Rifle strip (AUTO 10 m, 0.70 s) -> Pistol face | 0.70 + 0.30 + 1 shot = ~1.0 s | Unchanged. |

## 3. Per-gun design notes

### Marksman Carbine (`resources/weapons/marksman_carbine.tres`)
- BR/DMR-family role but not a burst gun and not a 5-shot DMR copy: a 4-shot (3 body + 1 head)
  semi-auto with a slower, deliberate 3.0/s cap and a strong, sharp kick (recoil 1.6 deg, recovers
  more slowly than the pistol).
- Skill ceiling: tiny rested spread (0.05 deg) and a bloom that stacks slightly at max cadence
  (+0.6 deg per shot, recovers 1.5 deg/s: +0.1 deg net per shot at 3/s). Spamming the 4-shot puts
  the 4th shot at ~0.35 deg (0.3 m radius at 50 m: a coin flip on a head). Pacing at ~2.5/s keeps it
  pin-point for a 1.2 s kill. Smaller bend (0.8 deg) and less magnetism than the pistol.
- Owns helmet one-shots: 28 x 2.0 = 56 >= 45 out to 70 m (23.8 x 2 = 47.6), which the pistol
  deliberately doesn't have (see section 5). Face gets 2.5, which only matters past ~85 m.
- Range: full damage to 50 m, 0.7 floor at 90 m. Beats the pistol past ~40 m (pistol drops to a
  7-shot face kill at 70 m vs the carbine's 4).
- 2.5x scope with the HUD scope overlay (pistol 2x, rifle 1.8x burst-only).
- 10-round magazine, 30 reserve (max 40): about 7-8 kills from a fresh pickup.
- Distinct report: a sharp high crack with a long, ringing tail (placeholder generated audio).

### Combat Shotgun (`resources/weapons/combat_shotgun.tres`)
- 10 pellets x 10 in a 4 deg half-angle cone (seedable RNG, see the framework section), no head
  bonus (Halo shotguns never had one), pump 0.83 s, 6 shells, 12 reserve (max 24).
- One-shots unshielded targets up close: 100 at <= 3 m (needs 5 pellets), 7 pellets at 6 m.
  Falloff 3 -> 12 m to 0.1: at 10 m a full blast does 30.
- Two shots or shot + melee on a full shield (0.83 s or ~0.3 s): faster than any rifle up close,
  hopeless past 10 m. Huge kick (7 deg pitch, 1.8 deg yaw) and a 0.6 s equip.
- Reload is a whole-tube reload (2.6 s). A Halo-style shell-by-shell reload is a follow-up
  (needs a per-round reload mode and LC Animator's clips).

### Directed Energy Rifle (`resources/weapons/directed_energy_rifle.tres`)
- Plasma family: 1.6x to shields, 0.75x to health, no head bonus. Strips a shield in 5 bolts
  (0.50 s, fastest in the game) and finishes slowly (6 more bolts).
- Battery, no reload: 100 charge, 1 per bolt, 10 per charge shot. Ammo pickups and dropped guns
  can't refill it (Halo: plasma weapons don't take ammo). A dead battery is a gun to drop: a
  DER pickup with more battery than yours is offered as a swap (hold to take; bots take it too)
  and your DER drops in its place.
- Heat: +0.075 per bolt, cools 0.8/s after 0.3 s of not firing. 14 bolts in a row overheat it
  (1.63 s of trigger), which is enough for one perfect kill (11), not two. An overheat locks the gun
  for 1.8 s while it vents.
- Secondary (right click / pad LT, `action_alt_fire`) toggles CHARGE mode, as does fire select
  (F / D-pad up). In CHARGE mode a tap fires one bolt on release (Halo 2 plasma pistol rules);
  taps faster than fire_rate (8/s) are dropped, and tap bolts use the alt spread (x0.5) and the
  alt falloff (25 -> 50 m to 0.6), like the charge shot. Holding for 0.75 s charges a shot that
  does 50 base: 80 to a shield (strips a full shield in one), 37.5 to health (never kills alone).
  The charge shot costs 10 battery and fills heat to 100%, so it always vents afterwards. Holding
  a full charge drains 4 battery/s.
- Range: bolts 20 -> 45 m to 0.5, the charge shot 25 -> 50 m to 0.6. Past 35 m the bolts
  overheat before they kill.
- Hook: cyan emissive coils that glow with heat and charge, a rising whine while charging and a
  vent hiss on overheat (placeholder generated audio).

## 4. How the five fit together

- Spawn kit: Standard Issue Rifle + Service Pistol (unchanged). Rifle AUTO owns 0-15 m, BURST
  15-40 m; the pistol is the "still dangerous" precision finisher and the face one-shot.
- Pickups add a step up in each band, each with a clear cost:
  - close: Shotgun (power) beats the rifle inside 6 m, loses past 10 m, 2 shots on shields.
  - mid-long: Carbine beats the pistol past 40 m and forgives helmet hits, but is slower to
    fire (3/s), kicks harder and runs out (40 rounds max).
  - shields: DER strips faster than anything and enables combos, but can't finish efficiently,
    overheats, can't reload, and loses to range.
- Nobody wins every band. Kill times from full shield cluster around 0.9-1.3 s for perfect
  play (pistol face 0.89, carbine head 1.00, rifle AUTO head 1.00, DER 1.25, shotgun 0.83),
  so encounters stay readable (Halo 2's ~1 s range). The power guns win on reliability, not on
  a faster theoretical TTK. Combos (DER + precision, shotgun + melee) are the fast kills, Halo-style.

## 5. Flag: the pistol helmet shot (44 vs 45)

The pistol does 22 x 2.0 = **44** to bare health on a helmet hit, 1 short of 45. A helmet shot
after the shield breaks leaves the target at 1 HP. Helmet kills take 6 shots (1.11 s), face kills
5 (0.89 s), body 7 (1.33 s).

History: 1327f0a moved the pistol from 23 (chosen as "the smallest round number" for a helmet
one-shot, 46 >= 45) to 22, and its tuning notes say "the helmet is no longer a one-shot finisher".
So the 1 HP gap is a consequence of a deliberate damage change, not an accident in the multiplier.

**Recommendation: keep it (no pistol change in this work).**
- Keeping it is what gives the armored/unarmored split meaning on the pistol: the face is the
  skill shot (5-shot, 0.89 s), the helmet is only a bit better than the body. If the helmet also
  killed, face and helmet would both be 5-shot at <= 50 m and the visor zone would only matter
  past 70 m.
- The roster now has a helmet one-shot gun, the Marksman Carbine (56 to 70 m). That gives the pickup
  a reason to exist over the spawn pistol.
- The exactly-1-HP leftover reads as a bug, so it should be a deliberate margin instead. The
  zone sits in the multiplier, so the clean fix is to make the shortfall clearly visible rather
  than 1 HP: e.g. `headshot_armored_multiplier = 1.8` (39.6, leaves 5.4 HP). This is a
  feel call for Morgon and is NOT applied. Body-shot TTK is unaffected either way.
- If Morgon instead wants Halo CE/2-style helmet kills on the pistol: `headshot_armored_multiplier
  = 2.1` (46.2 >= 45). Helmet kills become 5 shots / 0.89 s (same as face) at <= 50 m, and 8 shots
  at 70 m (13.2 x 2.1 = 27.7, 2 needed). Don't use 2.05: 45.1 kills only by a float hair.

## 6. Framework additions (generic, defaults keep pistol and rifle identical)

WeaponData (all appended, defaults = old behaviour):
- `health_damage_multiplier = 1.0`: health-only scale, multiplied into zone_multiplier.
- `pellet_count = 1`, `pellet_spread = 0.0`: pellets per shot, cone half-angle around the aim ray.
  Pellet directions come from `Weapon._spread_rng`, a seedable RandomNumberGenerator; the
  single-ray path keeps the global randf() so the pistol and rifle are byte-identical.
- `battery = false`: magazine is battery charge, no reload, no ammo pickup.
- `heat_per_shot = 0.0` (0 = no heat), `heat_cooldown_delay`, `heat_cooldown_rate`,
  `overheat_vent_time`.
- `FireMode.CHARGE` (appended, value 3): `charge_time`, `charge_damage_multiplier`,
  `charge_ammo_cost`, `charge_heat`, `charge_hold_drain`.

See the commit messages and the report for the exact members added to weapon.gd and
weapon_data.gd.
