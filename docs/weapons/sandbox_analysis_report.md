# Project Long Colt — Weapons Sandbox Balance & Combat Design Analysis Report

**Date:** October 15, 2026  
**Milestone:** v0.3.2  
**Author:** Weapons Sandbox Balance & Combat Designer  
**Scope:** Complete Arsenal Analysis (7 Weapons, 2 Grenades, Health/Shield Subsystem, AI Preferences, Netcode Impact)  
**Reference Target:** Bungie-Era Halo (Halo 2 / Reach pacing & lethality) + *Star Wars: Republic Commando* (tactical weight, functional weapon modularity, dark industrial grit)

---

## 1. Executive Summary & Arsenal Master Sheet

Project Long Colt's combat sandbox operates on an arena-shooter paradigm governed by strict weapon roles, sharp time-to-kill (TTK) curves, and readable engagement hierarchies. Combat pacing relies on the **70 Shield / 45 Health** dynamic (`HealthShield`), where standard ballistic weapons do not bleed through shields upon shield break (overflow damage is absorbed), while designated anti-materiel, power, and explosive ordnance feature full shield bleedthrough.

Following the **v2 TTK Pass**, the sandbox features five ballistic/projectile firearms, two power melee weapons, and two tactical grenade types:

```
+-------------------------------------------------------------------------------------------------------------------------+
|                                           PROJECT LONG COLT — WEAPON ARSENAL MATRIX                                     |
+----------------------+-------------+--------------+--------+-------------+--------------+-------------+-----------------+
| Weapon               | Class       | Fire Mode    | Damage | Bleedthrough| TTK (Body)   | TTK (Head)  | Effective Range |
+----------------------+-------------+--------------+--------+-------------+--------------+-------------+-----------------+
| Service Pistol       | Spawn Side  | Semi 4.5/s   | 22.0   | No          | 1.33s (7 hit)| 0.89s (Face)| 0 - 50 m        |
| Standard Rifle (AUTO)| Spawn Prim  | Auto 10.0/s  |  9.0   | No          | 1.20s (13hit)| 1.00s (11hit| 0 - 15 m        |
| Standard Rifle(BURST)| Spawn Prim  | Burst (0.47s)|  9.0   | No          | 1.88s (13hit)| 1.47s (11hit| 15 - 40 m       |
| Marksman Carbine     | Map Pickup  | Semi 3.0/s   | 55.0   | Yes         | 0.67s (3 hit)| 0.33s (2 hit| 15 - 75 m       |
| Combat Shotgun       | Power Weapon| Pump 1.2/s   | 90.0   | No          | 0.83s (2 bst)| 0.83s (2 bst| 0 - 6 m         |
| Rocket Launcher      | Power Weapon| Semi 1.0/s   | 160.0  | Yes         | 0.00s (1 hit)| 0.00s (1 hit| 0 - 45 m        |
| Longsword            | Power Melee | Melee 0.65s  | 200.0  | Yes         | 0.22s (Lunge)| 0.22s (Lunge| 0 - 6.5 m       |
| Gravity Hammer       | Power Melee | Melee 1.10s  | 160.0  | Yes         | 0.25s (Smash)| 0.25s (Smash| 0 - 2.7 m (AOE) |
| Frag Grenade         | Ordnance    | Thrown (2.5s)| 100.0  | Yes         | N/A (Strip+30| N/A         | 0 - 8.0 m Blast |
| Sticky Grenade       | Ordnance    | Thrown (2.0s)| 150.0  | Yes         | 2.00s (Stick)| 2.00s (Stick| 0 - 6.5 m Blast |
+----------------------+-------------+--------------+--------+-------------+--------------+-------------+-----------------+
```

### Key Takeaways from Current State
1. **Precision & Power Weapons Feel Brutal and Decisive:** The Marksman Carbine, Rocket Launcher, Combat Shotgun, and Longsword command immense tactical presence. Securing weapon spawns dictates match momentum.
2. **Critical Identity Crisis on Standard Issue Rifle:** The Rifle's Burst fire mode has a catastrophic TTK disadvantage (1.47s head / 1.88s body) compared to the spawn Service Pistol (0.89s face / 1.11s helmet / 1.33s body). Players have virtually no competitive incentive to switch to Burst.
3. **The "Bulltrue" Dilemma:** Because the Combat Shotgun deals 90 max blast damage without bleedthrough, it requires strictly two blasts (0.83s) to kill a full-shield player. Consequently, it is mathematically impossible to stop a charging Longsword user lunging from 6.5m (0.22s travel time).
4. **Melee Power Disparity:** The Longsword possesses infinite swings, zero energy depletion, a 6.5m lunge at 18 m/s, and a 0.65s cooldown. The Gravity Hammer is saddled with 10 battery charges, a 0.25s pre-smash windup delay, zero lunge, and a 1.1s cooldown.
5. **Republic Commando Tactical Utility is Largely Unrealized:** Beyond the Rifle's fire-mode toggle, the game currently lacks secondary weapon mechanics (no alternate firing modes, attachments, or modular utilities).

---

## 2. Mathematical Sandbox & TTK Analysis

### 2.1 The Health & Shield Economy
Target baseline: **70 Shield / 45 Health (Total 115 HP)**.
* **Shield Rule:** Zone multipliers (helmet x2.0, face x5.0) apply exclusively to health damage. While shields are up, all hits deal base flat damage to shields regardless of hit zone.
* **Shield Bleedthrough Rule:** When `bleedthrough = false`, any excess damage from the shot that breaks the shield is absorbed and lost. Thus, a non-bleedthrough weapon requires a minimum of two hits to kill from full shields (at least 1 shot to break shield, followed by 1+ shots to damage health).
* **When `bleedthrough = true`:** Leftover shield damage is converted back to base damage and applied to health with zone and `health_damage_multiplier` applied:
  $$\text{Damage to Health} = \frac{\text{To Shield} - \text{Shield Left}}{\text{shield\_mult}} \times \text{zone\_mult} \times \text{health\_mult}$$

```
+--------------------------------------------------------------------------------------------------+
|                                    TIME TO KILL (TTK) MATRIX                                     |
|                        Measured from first shot (t=0) to lethal damage frame                     |
+----------------------+--------------------+--------------------+--------------------+------------+
| Weapon & Mode        | 0 - 15m (CQC)      | 15 - 40m (Mid)     | 40 - 70m (Long)    | Ammo / Mag |
+----------------------+--------------------+--------------------+--------------------+------------+
| Service Pistol       | Body: 1.33s (7)    | Body: 1.33s (7)    | Body: 2.00s (10)   | 12 / 48    |
|                      | Helmet: 1.11s (6)  | Helmet: 1.11s (6)  | Helmet: 1.56s (8)  |            |
|                      | Face: 0.89s (5)    | Face: 0.89s (5)    | Face: 1.33s (7)    |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Standard Rifle AUTO  | Body: 1.20s (13)   | Body: 2.10s (22)*  | Body: 2.50s (26)*  | 32 / 128   |
|                      | Head: 1.00s (11)   | Head: 1.70s (18)*  | Head: 2.00s (21)*  |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Standard Rifle BURST | Body: 1.88s (13)   | Body: 1.88s (13)   | Body: 3.29s (22)   | 32 / 128   |
|                      | Head: 1.47s (11)   | Head: 1.47s (11)   | Head: 2.47s (18)   |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Marksman Carbine     | Body: 0.67s (3)    | Body: 0.67s (3)    | Body: 0.67s (3)**  | 10 / 30    |
|                      | Head: 0.33s (2)    | Head: 0.33s (2)    | Head: 0.67s (3)**  |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Combat Shotgun       | Blast: 0.83s (2)   | Useless (>12m)     | Useless            | 6 / 12     |
|                      | Blast+Melee: ~0.1s |                    |                    |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Rocket Launcher      | Instant (1 shot)   | Instant (1 shot)   | Travel time gated  | 2 / 2      |
|                      | (Risk self-damage) |                    | (35 m/s)           |            |
+----------------------+--------------------+--------------------+--------------------+------------+
| Longsword            | Instant (0.22s lunge)                   | N/A (>6.5m)        | Infinite   |
+----------------------+--------------------+--------------------+--------------------+------------+
| Gravity Hammer       | Instant / 0.25s    | N/A (>4.5m)        | N/A                | 10 swings  |
+----------------------+--------------------+--------------------+--------------------+------------+
* Paper TTK; in practice, held bloom at 35m gives cone radius 1.59m vs 0.4m player radius, causing >50% misses.
** Carbine 2-shot kill drops off at ~60m; 3-shot kill extends to 75m; 4-shot kill beyond 85m.
```

---

## 3. What Works: High Points & Combat Clarity

### 3.1 Marksman Carbine Precision Loop
* **Crisp Rhythm & Gun Feel:** With a 3.0/s cadence (333ms cycle), a 2.5x scope, and punchy auditory report, the Marksman Carbine feels authoritative.
* **Skill Differentiation:** The 2-shot kill requires the shield to be broken on shot 1 (55 damage), followed by an unarmored/armored headshot on shot 2 ($40 \text{ overflow} \times 0.75 \text{ health mult} \times 2.0 = 60 \ge 45$). A player landing body-only shots is penalized with a 3-shot kill (0.67s).
* **Bloom Discipline:** 0.05° base spread with 0.6° bloom per shot ensures pacing shots slightly below max cadence maintains sniper-like precision, rewarding trigger discipline.

### 3.2 Power Weapon Impact & Clarity
* **Rocket Launcher (`directed_energy_rifle.tres`):** Transitioning from the hitscan beam to a physical 35 m/s rocket projectile was a massive balance upgrade. The 160 blast damage with 2.0m inner and 6.0m outer radius creates a lethal 3.125m kill circle. High velocity makes leading intuitive, while projectile travel time gives distant targets counterplay through cover and evasive sliding.
* **Combat Shotgun CQC Role:** A 10-pellet 90-damage blast strips a full shield in one hit. The classic "Blast + Melee" combo (90 damage + 70 melee = 160) works seamlessly in close quarters.
* **Melee Weapon Presence:** The Longsword and Gravity Hammer dramatically alter spatial control on maps like Lockout, Zanzibar, and Ivory Tower. The visual feedback (blade trails, third-person props, hammer shockwave particle rings) is clean, readable, and synced over netcode.

### 3.3 Physics Knockback & Traversals
* **Knockback Integration:** The directional shove from melee (`Knockback.melee`) and the explosive launch from blasts (`Knockback.blast`) interact naturally with Godot's Jolt physics. Grenade jumping, launch recovery, and physical displacement feel grounded and responsive.

---

## 4. What Doesn't: Critical Gaps, Dead Zones & Redundancies

### 4.1 The Standard Issue Rifle Identity Crisis (Auto vs Burst)
The Standard Issue Rifle is designed as the spawn primary weapon, tasked with bridging CQC spraying and mid-range burst precision. In its current implementation, **Burst mode is a severe mathematical trap**.

#### Why Burst Mode Fails:
1. **Uncompetitive Cycle Time:** Burst mode fires 3 rounds spaced by 0.06s with a 0.35s delay before the next burst. That is a **0.47s cycle time**, delivering an effective fire rate of only ~6.4 rounds/s (compared to 10.0 rounds/s in Auto).
2. **Abysmal TTK:** 
   * A full burst kill requires 5 bursts (13 rounds): **1.88s TTK**.
   * A perfect headshot finish still requires 4 bursts (11 rounds): **1.47s TTK**.
3. **Severe Underperformance vs the Spawn Pistol:**
   * At 15–35m, the Service Pistol kills in **0.89s (face)** or **1.11s (helmet)** or **1.33s (body)**.
   * The Service Pistol strips shields in **0.67s** (4 shots) vs the Rifle Burst's **1.00s** (8 rounds).
   * The Service Pistol has 2x zoom and zero bloom accumulation at paced cadence.
4. **Artisanal Zoom Lock:** Zooming with the rifle is artificially gated to Burst mode only (`zoom_only_in_mode = 2`). Right-clicking in Auto mode does nothing, creating a disjointed user experience.

```
       MID-RANGE (25m) TTK COMPARISON: SPAWN WEAPONS
       =============================================
Service Pistol (Face Finish):   [0.89s] █████████
Service Pistol (Helmet Finish): [1.11s] ███████████
Service Pistol (Body Only):     [1.33s] █████████████
Standard Rifle (AUTO Paper):    [1.60s] ████████████████  (High miss rate)
Standard Rifle (BURST Head):    [1.47s] ███████████████
Standard Rifle (BURST Body):    [1.88s] ███████████████████
Marksman Carbine (Headshot):    [0.33s] ███
```

### 4.2 The "No Bulltrue" Flaw on Combat Shotgun
In Bungie-era Halo (Halo 2 and Reach), the Shotgun served as the vital hard-counter to the Energy Sword. A player with pinpoint timing could execute a "Bulltrue" by blast-killing a lunging sword user at point-blank range before the sword swing connected.

In Project Long Colt:
* The Longsword lunges from **6.5m** at **18 m/s** (travel time ~0.22s).
* The Combat Shotgun deals **90 max damage** with **`bleedthrough = false`**.
* Even if all 10 pellets hit the charging sword user in the face, the first blast only strips the 70 shield (with 20 overflow discarded). The sword user survives with 45 health.
* The Shotgun's pump cycle is **0.833s**. The sword user completes the lunge in **0.22s** and scores a 200-damage 1-hit kill.
* **Conclusion:** In Project Long Colt, a full-health sword user is mathematically invulnerable to a solo shotgun defender during a lunge. This breaks weapon counter-play.

### 4.3 Longsword vs Gravity Hammer Disparity
The balance between the two power melee weapons is completely one-sided:

| Parameter | Longsword | Gravity Hammer | Balance Imbalance Note |
|---|---|---|---|
| **Lunge Distance** | **6.5 meters** | 2.5 meters (None) | Sword engages from more than double the distance. |
| **Damage & Bleed** | 200 (100% kill) | 160 (100% kill inner 2m) | Both kill in inner radius; hammer drops off to 0 at 4.5m. |
| **Windup Delay** | **0.00s (Instant)** | **0.25s (Smash Delay)** | Hammer delay gives victims a 250ms window to counter-kill. |
| **Cooldown / Rate** | **0.65s** | **1.10s** | Sword swings 70% faster. |
| **Ammo Consumption**| **Unlimited (0 Cost)**| **10 Swings Max (1 Cost)** | Sword never depletes; hammer expends 10% battery per swing. |
| **Whiff Penalty** | Zero | 1 Battery lost on miss | Hammer penalizes misses; sword allows rapid spam. |

In a direct clash, the Longsword user lunges from 6.5m and kills the Hammer user in 0.22s. The Hammer user cannot even reach through the 0.25s windup delay before dying.

### 4.4 The 44 HP Pistol Helmet Margin
As noted in `service_pistol_tuning.md` and `roster_balance.md`, the Service Pistol deals $22 \times 2.0 = 44$ damage to bare health on an armored head (helmet) hit. Because max health is 45, a helmet shot leaves the victim at exactly **1 HP**.
* To players, surviving a clean headshot with a visible 1% health bar reads as an arithmetic bug or bad netcode hit registration rather than a deliberate tactical design.
* While keeping the unarmored face as the sole 1-shot finisher creates high skill expression, leaving 1 HP feels unpolished.

### 4.5 Republic Commando Secondary Modes — Unrealized Utility
The game's design pillar calls for *Republic Commando* tactical weight and weapon versatility. Currently:
* **Pistol:** 2x optical zoom only. No secondary fire mode (e.g., charged overcharge, armor-piercing round, fast double-tap).
* **Shotgun:** No secondary action (secondary = `NONE`). Missing tactical choke switch (wide spread vs tight slug).
* **Carbine:** 2.5x zoom only. No alternate utility.
* **Rocket Launcher:** 2x zoom only. No trajectory or lock-on utility.
* **Rifle:** Secondary is toggling fire mode, but zoom is tied to the burst mode only.

### 4.6 Grenade Sandbox Discrepancies & AI Dead Zone
1. **Config Discrepancy:**
   * `docs/weapons/roster_balance.md` specifies Frag radius as $1.5\text{m} / 5.0\text{m}$ and Sticky as $1.2\text{m} / 4.0\text{m}$.
   * The actual resource files (`frag_grenade.tres` and `sticky_grenade.tres`) define:
     * Frag: `inner_radius = 1.5`, `blast_radius = 8.0`.
     * Sticky: `inner_radius = 1.2`, `blast_radius = 6.5`.
   * The 8.0m frag blast radius is colossal in tight maps like Lockout and Ivory Tower, making grenade spam overly suppressive.
2. **Missing Bot Grenade AI:**
   * Neither `scripts/ai/bot_brain.gd` nor `scripts/ai/bot.gd` contains any grenade-throwing logic. In single-player or bot matches, bots never throw grenades, depriving players of the authentic Halo/Republic Commando combat dance.
3. **No Field Pickups:**
   * Grenades can only be replenished by dying and respawning. Map racks and enemy death drops do not drop grenades.

---

## 5. Distance Bracket Analysis (0–15m, 15–40m, 40–80m)

```
0m               15m                             40m                             80m
|-----------------|-------------------------------|-------------------------------|
|   CQC BRACKET   |       MID-RANGE BRACKET       |       LONG-RANGE BRACKET      |
| Shotgun / Sword | Pistol / Carbine / Rifle Auto | Carbine / Rocket Launcher     |
| Hammer / Frag   | (Rifle Burst: Dead Zone)      | (Pistol: Visor Sniping)       |
```

### 5.1 Close Quarters Combat (0–15m)
* **Dominant Arsenal:** Longsword, Combat Shotgun, Gravity Hammer, Rifle AUTO.
* **Dynamics:** Explosive, lethal, rapid-fire decisions. Rifle AUTO's 1.00s head / 1.20s body TTK shreds rushing enemies. Shotgun + Melee delivers sub-100ms kills.
* **Friction Points:**
  * Inability for Shotgun to one-blast kill an oncoming Sword lunge.
  * Hammer's 0.25s windup delay frequently results in the user dying before the shockwave triggers.

### 5.2 Mid-Range Combat (15–40m)
* **Dominant Arsenal:** Marksman Carbine, Service Pistol.
* **Dynamics:** This is the core arena engagement bracket where gunskill is tested. The Carbine rules supreme with a blistering 0.33s 2-shot kill. The Service Pistol offers exceptional consistency with a 0.89s face finish.
* **Friction Points:**
  * Standard Issue Rifle loses virtually all utility past 20m. Held AUTO fire exceeds the target silhouette by 25m due to bloom (max 2.6°). Switching to BURST increases TTK to an uncompetitive 1.47s - 1.88s.
  * Players who do not find a Carbine pickup are forced to holster their primary rifle and use their sidearm pistol for all mid-range duels.

### 5.3 Long-Range Combat (40–80m)
* **Dominant Arsenal:** Marksman Carbine (scoped 2.5x), Rocket Launcher (suppressive splash).
* **Dynamics:** Carbine maintains high lethality out to 60m (2-shot kill) and 75m (3-shot kill). Scoped view stabilizes spread.
* **Friction Points:**
  * Service Pistol remains surprisingly potent out to 50m (5-shot 0.89s face kill), creating a strange dynamic where the spawn pistol out-snipes the spawn rifle at long distance.
  * Rifle Burst mode at 70m requires 22 rounds (8 bursts) taking 3.29 seconds to kill to the body, making it completely ineffective.

---

## 6. Concrete Balance & Tuning Recommendations (Phase 1)

To restore competitive parity, eliminate dead zones, and fulfill the grounded military sci-fi vision, the following balance adjustments are recommended for Phase 1 implementation.

### Recommendation 1: Rebalance Standard Issue Rifle Burst Mode
**Goal:** Make Burst mode a compelling, competitive mid-range firing mode (15–45m) rather than a dead-zone trap.

* **Changes in `resources/weapons/standard_issue_rifle.tres`:**
  1. **Shorten Burst Cooldown:** Reduce `burst_cooldown` from `0.35s` to **`0.22s`**.
     * With `burst_interval = 0.06s` (2 intervals = 0.12s), total cycle time drops from `0.47s` to **`0.34s`** (~8.8 rounds/s effective).
  2. **Increase Burst Damage per Round:** Buff burst-mode damage from 9.0 to **10.5** (via an `alt_damage` property, or buff base rifle damage to 10.0 and tune auto fire rate to 9.5/s).
  3. **TTK Impact with 0.34s cycle:**
     * 4-burst kill (11 rounds with head finish): drops from `1.47s` to **`1.08s`**!
     * 5-burst body kill (13 rounds): drops from `1.88s` to **`1.38s`**.
     * This places the Rifle Burst directly in competitive range with the Service Pistol (1.11s helmet / 1.33s body), giving players a viable mid-range assault weapon.
  4. **Decouple Zoom from Burst:** Set `zoom_only_in_mode = -1`. Allow players to zoom with the 1.8x optic in both AUTO and BURST modes.

### Recommendation 2: Enable Shotgun "Bulltrue" Anti-Lunge Counter
**Goal:** Restore the high-skill Shotgun vs Sword counter-play dynamic.

* **Mechanics Update:**
  * Option A (Bleedthrough on Pellets): Set `bleedthrough = true` on `combat_shotgun.tres`.
    * A point-blank blast landing all 10 pellets delivers 90 damage.
    * 70 strips the shield; 20 spills into health.
    * With center pellet on the head (`headshot_armored_multiplier = 4.0`), the health damage is $20 \times 4.0 = 80 \ge 45$, securing a **point-blank 1-blast headshot kill**!
    * A body blast still leaves 25 health ($45 - 20 = 25$), preserving the 2-blast kill requirement for center-mass shots.
  * This restores the legendary "Bulltrue" skill check: if you hit a charging sword user squarely in the face at <3 meters, they die. If you aim center-mass, you die to their lunge.

### Recommendation 3: Rebalance Longsword vs Gravity Hammer
**Goal:** Equalize risk/reward between the two power melee weapons.

1. **Longsword (`longsword.tres`):**
   * **Reduce Lunge Range:** Decrease `melee_lunge_range` from `6.5m` to **`5.0m`** (or `5.2m`). A 6.5m lunge covers too much arena space instantaneously.
   * **Introduce Durability / Charge:** Set `battery = true`, `magazine_size = 10`, `swing_cost = 1`, `swing_cost_on_hit_only = true`. Give the sword 10 fatal strikes. Unlimited instant-kill weapons distort map flow.
2. **Gravity Hammer (`gravity_hammer.tres`):**
   * **Reduce Smash Windup:** Reduce `smash_delay` from `0.25s` to **`0.15s`**. A 250ms windup is too vulnerable to fast reactions.
   * **Expand Instant Kill Inner Radius:** Increase `smash_inner_radius` from `2.0m` to **`2.5m`** (kill radius expands to 3.2m).
   * **Add Short Forward Step:** Increase `melee_lunge_range` from `2.5m` to **`3.5m`** with a short 8.0 m/s hop forward to close distance on shockwave release.

### Recommendation 4: Normalize Grenade Blast Radiuses & Add Bot AI
1. **Sync Grenade Resources with Specs:**
   * Update `frag_grenade.tres`: Change `blast_radius` from `8.0m` to **`6.0m`** (matching intended arena bounds).
   * Update `sticky_grenade.tres`: Change `blast_radius` from `6.5m` to **`5.0m`**.
2. **Implement Bot Grenade Logic (`bot_brain.gd`):**
   * Introduce bot grenade evaluation in `_do_engage()`:
     * When target is in cover or behind a corner, throw Frag.
     * When target is moving predictably or stationary at 10–20m, throw Sticky.
     * Limit throws with a tactical cooldown (8.0s per bot).
3. **Add Map Grenade Pickups:**
   * Add placed grenade pickups (boxes of 2x Frag or 2x Sticky) at key map chokepoints and respawn them every 60s.

### Recommendation 5: Republic Commando Tactical Utility (Secondary Actions)
To fulfill the *Republic Commando* tactical pillar, introduce secondary tactical modes across the arsenal:

1. **Service Pistol — Tactical Overcharge / AP Double-Tap:**
   * Tap Right-Click: 2x Scope (as current).
   * Hold Secondary / Fire-Select (F): Toggle to "AP Penetrator" mode (fires a 2-round high-velocity burst at 12.0/s with 1.5x armored penetration, costing 2 rounds).
2. **Combat Shotgun — Secondary Slugs / Choke Toggle:**
   * Right-Click: Tighten choke (reduces pellet spread from 7.0° to 2.5°, increases zoom to 1.4x, slightly decreases rate of fire to 0.9/s). Enables lethal combat out to 15m.
3. **Marksman Carbine — Variable Zoom Scope:**
   * Right-Click 1: 2.5x Combat Scope.
   * Right-Click 2: 4.5x Long-Range Marksman Optic with target silhouette highlighting.

---

## 7. Sandbox Verification & Test Results

All existing weapon tests were verified against engine execution:
* `tests/ttk_self_test.gd`: **PASS** (16/16 assertions pass).
* `tests/rocket_self_test.gd`: **PASS** (22/22 assertions pass).
* `tests/grenade_self_test.gd`: **PASS** (46/46 assertions pass).
* `tests/range_self_test.gd`: **PASS** (All weapon pickups, racks, and infinite ammo verified).
* `tests/melee_weapons_self_test.gd`: **PASS** (Sword lunge, alternating animations, hammer shockwave falloff, wall occlusion, and bot lunge kill verified).

---

## 8. Conclusion

Project Long Colt boasts a remarkably solid, grounded mechanical foundation. The gunplay feels weighty, the visual and physical feedback is satisfying, and the Halo 2/Reach movement integration provides crisp arena readability. 

By executing the Phase 1 balance pass—remedying the Standard Rifle Burst identity, enabling the Shotgun Bulltrue skill-check, balancing Sword durability against Hammer shockwaves, and introducing Republic Commando-inspired secondary utility—the sandbox will achieve true competitive excellence and tactical depth.
