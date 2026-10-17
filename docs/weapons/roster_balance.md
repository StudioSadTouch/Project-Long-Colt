# Five-gun roster: balance sheet (v2 TTK pass)

> **Rocket launcher (2026-10-15, Morgon: "turn the DER into a rocket launcher, no beam. Too
> OP"):** the DER slot is now the **Rocket Launcher**. Same weapon id
> (`resources/weapons/directed_energy_rifle.tres`, never renamed: it is the network id) and scene
> path, new behaviour: a travelling rocket (35 m/s, `scripts/weapons/rocket.gd`) instead of a
> hitscan beam. Blast (Grenade.apply_blast rules): 160 full to 2 m, linear to 0 at 6 m, so it
> kills within ~3.1 m of the body point and wounds out to 6 m; walls block; the shooter is hurt
> too. SEMI 1.0/s, 2 in the tube + 2 spare (4 max), 2.5 s reload, 2x zoom, no aim bend, no
> battery, no heat. The DER rows and section below are history.

> **v2 TTK pass (2026-10-15, Morgon's targets):** Carbine 3 body / 2 head, Shotgun 2 blasts, DER
> a scoped one-shot (auto and charge removed), Pistol 7 body, Rifle 5 bursts (4 with a head
> finish). The Pistol and Rifle already met their targets, so their values are unchanged. The
> sections below are updated for Carbine, Shotgun and DER. The old DER (bolts, heat, charge shot,
> the "noob combo") is gone; the framework for it (heat, CHARGE) stays in the code, unused.

Target: Bungie-era Halo (CE through Reach, Halo 2 first). Every number below is checked against
HealthShield (70 shield / 45 health) and the shared Weapon code:

- No bleedthrough on any gun: the round (or shotgun blast) that breaks the shield is absorbed,
  its overflow is lost. A shotgun blast is one damage event per victim (section 3).
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
| Marksman Carbine | Map pickup, mid-long precision | SEMI 3.0/s, 2.5x scope | 55, **bleedthrough** | x2.0 / x2.5 | 1.0 / 0.75 | 15-60 m (2-head), 15-75 m (3-body) | 50 -> 90 m, 0.7 |
| Combat Shotgun | Power weapon, close range | SEMI pump 1.2/s, 10 pellets | 9 per pellet (90 per blast) | x4.0 / x4.0 (head blast) | 1.0 / 1.0 | 0-6 m (2-blast kill), useless past 10 m | 6 -> 12 m, 0.1 |
| Rocket Launcher (was the DER) | Power weapon, splash | SEMI 1.0/s, 35 m/s rocket, 2x zoom, 2 + 2 rockets, 2.5 s reload | blast 160 full to 2 m, 0 at 6 m, **bleedthrough** | none (blast) | 1.0 / 1.0 | kill within ~3.1 m of impact; self-damage up close | none (blast falloff only) |

Pistol (`resources/weapons/service_pistol.tres`) and rifle
(`resources/weapons/standard_issue_rifle.tres`) are unchanged by the v2 pass: they already hit the
targets (pistol 7 body, rifle 5 bursts / 4 with a head finish).

**Bleedthrough guns (Carbine, DER).** With the default no-bleedthrough rule the shot that breaks a
shield loses its overflow, so nothing can kill a full 70 + 45 in fewer than two shots, and a
2-shot kill needs a first shot of 70+ (which would also be a 2-shot body kill). The Carbine's
"2 headshots" and the DER's one-shot both need the overflow to spill into health, with the zone
and health multipliers applied to it (HealthShield already supports this). A shot that lands on
the shield still ignores the head bonus (Halo rule), so for the carbine **only the second shot has
to be a headshot**: body then head also kills in 2.

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
| Carbine | <= 60 m | 55 (41.25 to health) | 2 (0.33 s) | **3 (0.67 s)** | **2 (0.33 s)** (2nd shot head) | 2 (0.33 s) |
| Carbine | 70 m | 46.75 | 2 (0.33 s) | 3 (0.67 s) | 3 (0.67 s) | 3 (0.67 s) |
| Carbine | >= 90 m | 38.5 | 2 (0.33 s) | 4 (1.00 s) | 3 (0.67 s) | 3 (0.67 s) |
| DER | <= 43 m | 125 (70 shield + 55 health) | 1 | **1** | 1 | 1 |
| DER | 60 m | 100 | 1 | 2 (1.67 s) | same | same |
| DER | >= 80 m | 75 | 1 | 2 (1.67 s) | same | same |
| Shotgun | <= 6 m | 90 per blast (8+ of 10 pellets strip) | **1 blast** | **2 blasts (0.83 s)** | 2 | 2 |

Morgon's v2 rule for the shotgun: 2 blasts kill. One blast of 8+ pellets (72+) strips, then 5+
pellets (45+) on bare health finish. Head blasts no longer change the count at full range.

Melee (70, all five guns, no bleedthrough): breaks a full shield exactly, kills bare health.

### Combos (the Halo sandbox loop)

| Combo | Notes |
|---|---|
| Shotgun -> melee | One blast strips, melee (70) kills bare health. Same speed as the 2-blast kill but works on a blast that lands only 8 pellets. |
| Melee -> Pistol face / Carbine any | Melee strips; the next precision shot finishes (carbine body 41.25 < 45, so the carbine needs the head). |
| Rifle strip -> Pistol face | Unchanged. |
| The old DER "noob combo" | Gone: the DER kills on its own now. |

## 3. Per-gun design notes

### Marksman Carbine (`resources/weapons/marksman_carbine.tres`)
- v2: **3 body shots, 2 if the second is a headshot** (0.67 s / 0.33 s at 3/s). Damage 55 with
  bleedthrough and 0.75 to health: shot 1 takes 55 off the shield, shot 2 breaks it and spills
  40 x 0.75 = 30 (x2.0 helmet = 60, x2.5 face = 75, both kill; body 30 < 45 doesn't), shot 3
  always kills.
- Why 0.75 to health: it keeps one carbine body shot on bare health under 45 (41.25), so the
  carbine doesn't one-shot a stripped target to the body. The helmet still does (82.5).
- Range: the 2-headshot kill holds while damage stays >= 50 (to ~60 m); 3 shots to ~75 m, 4 past
  ~85 m.
- Unchanged: 3.0/s cap, 0.05 deg rested spread with bloom that stacks at max cadence, 1.6 deg
  kick, 2.5x scope, 10-round magazine (30 reserve, 40 max), 0.8 deg bend.

### Combat Shotgun (`resources/weapons/combat_shotgun.tres`)
- v2: **2 blasts kill** (0.83 s). 10 pellets x 9 = 90 per blast. A blast is still one damage event
  per victim, so the first blast strips (no bleedthrough, overflow lost) as long as 8+ pellets
  land (72 >= 70), and the second kills bare health on 5+ pellets (45). Head blasts (centre
  pellet on the head) are still x4.0 to health, so a head-aimed second blast kills on 2 pellets.
- One blast never kills a full shield; it does kill a bare-health target (90 >= 45).
- Range: unchanged falloff (full to 6 m, 0.1 at 12 m). Past ~6 m the 7 deg cone and falloff drop
  the first blast under 70, and it becomes a 3-blast gun; past 10 m it is useless.
- Unchanged: 7 deg cone, 0.83 s pump, 6 shells (12 reserve, 24 max), whole-tube 2.6 s reload,
  big kick, 0.6 s equip. The v1 pellet-odds table no longer applies (it was for 4 per pellet).

### Directed Energy Rifle (`resources/weapons/directed_energy_rifle.tres`) — replaced by the Rocket Launcher, see the top
- v2: **one shot kills** a full 70 + 45 inside ~43 m, with a long cycle: 0.6 shots/s (1.67 s
  between shots). 125 damage with bleedthrough: 70 breaks the shield and 55 spills into health.
  No head bonus (bots aim centre mass).
- Auto fire, the charge shot, fire select and heat are removed (fire_mode SEMI, heat_per_shot 0).
  Right click is now a **3x zoom** with the FIELD scope overlay; zoomed spread is x0.1 of the
  0.25 deg hip cone.
- Battery: 8 shots, no reload, no ammo pickups (as before). A flat DER is still a swap target.
- Range: full damage to 40 m, 0.6 at 80 m. The one-shot holds while damage >= 115 (~43 m). Past
  that it is a 2-shot gun (1.67 s).
- Counterplay: the 1.67 s cycle. A miss, or a second target, gives the other player time to
  close; inside ~12 m bots treat it as a poor gun.
- Leftover scene hooks (charge whine, vent crunch, coil glow) are no longer triggered.

## 4. How the five fit together

- Spawn kit: Standard Issue Rifle + Service Pistol (unchanged). Rifle AUTO owns 0-15 m, BURST
  15-40 m; the pistol is the "still dangerous" precision finisher and the face one-shot.
- Pickups add a step up in each band, each with a clear cost:
  - close: Shotgun (power) kills in 2 blasts (0.83 s) inside 6 m, loses past 10 m.
  - mid-long: Carbine kills in 3 body (0.67 s) or 2 with a head finish (0.33 s) to ~60 m, but
    kicks hard and runs out (40 rounds max).
  - long: DER one-shots to ~43 m from a 3x scope, but 1.67 s between shots, 8 shots total, no
    reload: every miss is costly.
- **Flag: the v2 targets compress the power guns well below the spawn kit.** Perfect-play kill
  times from full shield: pistol 1.33 s body / 0.89 s face, rifle bursts ~1.9 s body / ~1.5 s
  head, carbine 0.67 s / 0.33 s, shotgun 0.83 s, DER instant. In v1 everything sat at ~0.9-1.3 s
  and the power guns won on reliability; in v2 they win on raw speed. That is a deliberate
  direction change (Morgon's call), noted so it gets playtested: the carbine is the gun to watch,
  since it is a common map pickup and now kills about twice as fast as the pistol.

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
- `pellet_count = 1`, `pellet_spread = 0.0`: pellets per shot, cone half-angle around pellet 0
  (the aim ray). A blast sums its pellets per victim into one take_damage, zoned by pellet 0.
  Every shot (pistol and rifle too) is seeded from `Weapon._spread_rng`, a seedable
  RandomNumberGenerator.
- `battery = false`: magazine is battery charge, no reload, no ammo pickup.
- `heat_per_shot = 0.0` (0 = no heat), `heat_cooldown_delay`, `heat_cooldown_rate`,
  `overheat_vent_time`.
- `FireMode.CHARGE` (appended, value 3): `charge_time`, `charge_damage_multiplier`,
  `charge_ammo_cost`, `charge_heat`, `charge_hold_drain`.

See the commit messages and the report for the exact members added to weapon.gd and
weapon_data.gd.

## 7. Confirmed by Morgon

- Marksman Carbine: stays BR-like. No change.
- DER swap-when-flat: confirmed (a DER pickup with more battery than yours is a swap).
- Combat Shotgun retune and the head-blast rule above.

## 9. Grenades (`resources/weapons/frag_grenade.tres`, `sticky_grenade.tres`)

G throws the selected type, Q switches (pad: LB / D-pad left). Spawn with 2 of each, max 4,
refilled on respawn; a type that runs out hands the selection to the other. 0.8 s between
throws. Blast damage is full to the inner radius, linear to 0 at the blast radius, needs a clear
line from the blast to the body (walls block), uses bleedthrough, and hurts the thrower too.

| | Damage (centre) | Inner / blast radius | Fuse | Full-shield target at the centre |
|---|---|---|---|---|
| Frag | 100 | 1.5 / 5.0 m | 2.5 s after the throw, bounces (0.35) | survives at 15 health (70 shield + 30) |
| Sticky | 150 | 1.2 / 4.0 m | 2.0 s after sticking (6 s if it never sticks) | dies |

Combos: frag + any one shot finishes (15 health); frag + melee kills. Not done yet: grenade
pickups and death drops (counts only refill on respawn), a throw animation, bot grenades.
