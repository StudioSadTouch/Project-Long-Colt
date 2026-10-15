# Lockout (Halo 2, 2004) — Greybox Blockout Spec for Project Long Colt

> **Read this first:** No published measurements of Lockout exist in the sources I found. **Every dimension in this document is ESTIMATED** from Bungie-era screenshots, the original Bungie design doc and the overhead concept/blockout art, scaled against a 2.1 m Spartan. Treat it as a movement-test arena *in the spirit of* Lockout, not an exact copy. Tags: **[S]** = sourced (fact/name/placement from a cited source), **[E]** = estimated by me.

## 1. Scale assumption
- Player (Spartan) height = **2.1 m** (given). Doorways in refs read ~1.4–1.5× player height → **3.0 m door height** [E].
- Jump height **~1.6 m** standing, crouch-jump **~2.0 m** (within the given 1.5–2 m range). Gaps are tuned so ordinary obstacles are ≤1.5 m and "tricks" sit at 1.8–2.0 m [E].
- Storey pitch: **3.0 m floor-to-floor per tower level**, inferred from S1/S2/S3 and BR1/BR2/BR3 stacking in the Bungie.net callout shots (each level ≈ 1.4 doors high) [E].
- I did **not** use Halo world units / Blender extraction: no Bungie-era extracted dimensions were found. (If you later rip `lockout.scenario`/BSP with the H2EK, 1 Halo WU = 10 ft = 3.048 m; replace my numbers then.)
- Map designers called it the smallest of the 9 launch arena maps, originally a 1v1 map [S: Halopedia]; overall size was chosen to be compact accordingly [E].

## 2. Footprint & coordinate system
- **Overall: ~46 m (X) × ~45 m (Z), ~11 m vertical** (ground 0 → S3/BR3 roof 10.5 m) [E].
- **Origin:** ground level (Bottom Mid floor top, y=0) directly under the centre of Top Mid.
- **Godot axes:** +Y up, **+X = east, −Z = north** (Godot forward). In the diagram north is up.
- Orientation [S, layout relations]: Lift/Blue tower **south**; standing on top of the lift facing north, **BR tower is on the left (west)** and **Sniper tower on the right (east)** [S: Halopedia, Durinsbane]; **Library** overlooks Top Mid from the far (north) side [S: Active Rush/Bungie.net callout image]. Exact angles are [E]; the real map is a skewed "figure-eight" around the centre [S: Halopedia].

## 3. Named callouts (community names) — all positions/sizes [E], names [S]
Names come from Bungie.net callout screenshots reposted by Active Rush and a r/halo callout thread (BR 1/2/3, S 1/2/3, Sword, Library, Top/Bottom Mid, Elbow, Lift/Lift wings, Shotgun/Green).

| Callout | Center (x,z) | Footprint (m) | Floor heights y (m) | Notes |
|---|---|---|---|---|
| Top Mid | (0,0) | 16×16 | 4.5 | Open square deck, ~1 m parapets, centre hole/light. Main fight area [S]. |
| Bottom Mid (Under Mid) | (0,0) | 16×16 | 0 | Room under Top Mid; corner ambush spot [S]. Ceiling 4.0. |
| Green Hall / Green Room (Shotgun hall) | (0,15) | 6×14 | 0 | Stasis pods; leads to grav lift [S]. |
| Bottom Blue | (0,17) | 12×6 | 2.5 | Ledge at foot of Blue Lift; Blue Ramp rises from here [S name]. |
| Left Mag / Right Mag (Lift wings) | (±4.5,14) | 3×4 | 6.0 | Alcoves above Bottom Blue [S name]. |
| Top Blue (Top of Lift) | (0,18) | 12×8 | 9.0 | Grav lift exit; BR + magnums [S]. |
| Blue Lift | (0,21) | 3×3 pad | 0 → 9.0 | Gravity lift [S]. |
| S1 | (16,-1) | 10×10 | 4.5 | Level with Top Mid; Elbow arrives here [S name]. |
| S2 | (17,-4) | 8×6 | 7.5 | |
| S3 (Sniper spawn) | (16,-6) | 10×6 | 10.5 | Sniper rifle, turret, explosive barrels at back [S]. |
| Snipe Ramp | (21.5,0) | 2.5×10 | 7.5 → 10.5 | Outer ramp S2→S3 [S name]. |
| Elbow | L-shape (12,19)→(16,6) | 2.5 wide | 2.5 → 3.9 | Catwalk lower lift → Sniper [S]. |
| BR1 | (-16,1) | 10×10 | 4.5 | Level with Top Mid. |
| BR2 | (-17,-1) | 8×8 | 7.5 | |
| BR3 (roof) | (-17,-3) | 8×8 | 10.5 | Rifle overwatch of sniper tower [S]. |
| Open Ramp | (-22.5,4) | 2.5×12 | 0 → 4.5 | Outer ramp on BR tower [S name]. |
| BR Bridge | (-10,-10) | 10×2.5 | 7.5 | BR2 → Library [S name]. |
| Sword | (-11,-12) | 6×6 | 2.0 | Under BR Bridge [S name/placement in callout shot]. |
| Library (+ Library Window) | (-1,-14) | 12×8 | 7.5 | Overlooks Top Mid [S name]. |

## 4. Connections [E lengths/rises]
| From → To | Type | Length (m) | Rise (m) | Slope |
|---|---|---|---|---|
| Bottom Blue → Top Mid (south edge) | Blue Ramp | 7 | +2.0 | 16° |
| Green Hall → Top Blue | Grav lift | — | +9.0 | vertical |
| Green Hall ↔ Bottom Blue | Step/short stair | 3 | +2.5 | stairs |
| Bottom Mid ↔ Green Hall | Doorway | 2 | 0 | flat |
| Bottom Blue → Elbow South | Catwalk | 10 | 0 | flat |
| Elbow South → Elbow North end | Catwalk ramp | 12 | +1.4 | 7° |
| Elbow North end → S1 | **Elbow Jump** | 1.5 gap | +0.6–1.0 lip | jump |
| S1 ↔ Top Mid | Bridge/link | 5 | 0 | flat |
| S1 → S2 | Interior ramp/stair | 6 | +3.0 | 27° |
| S2 → S3 | Snipe Ramp (outside) | 10 | +3.0 | 17° |
| BR1 ↔ Top Mid | Bridge/link | 5 | 0 | flat |
| Ground (west) → BR1 | Open Ramp | 12 | +4.5 | 21° |
| BR1 → BR2 → BR3 | Interior stairs | 6 each | +3.0 each | 27° |
| BR2 → Library | BR Bridge | 10 | 0 | flat |
| Library → Top Mid | Drop (window/ledge) | — | −3.0 | drop |
| Sword room → Bottom Mid | Doorway/ramp | 6 | −2.0 | 18° |
| Top Blue → Top Mid | Drop | ~6 horiz | −4.5 | drop |

Design doc [S]: north area attached by a bridge below but reachable on top by jumping; west area attached on bottom level but reachable by jumping across; SE area largest, 3 levels, access to centre top and bottom. (Doc predates final layout; use as intent.)

## 5. Jumps / tricks to preserve (tuning checks) [E numbers]
| Trick | Source | Geometry to build | Movement requirement |
|---|---|---|---|
| Elbow Jump onto S1 | [S name, callout shot] | 1.5 m gap, landing 0.6–1.0 m higher | Must succeed with run+jump; fail if walking |
| Crouch-jump from below sniper spawn to ramp landing | [S Halopedia] | 1.9 m ledge from S2 area to Snipe Ramp landing | Must **require** crouch-jump (standing 1.6 < 1.9 ≤ crouch 2.0) |
| Open Ramp Jump (BR side) | [S name, callout shot] | ~1.7 m step from Open Ramp rail onto BR1/BR2 ledge | Borderline standing jump |
| Top Mid ↔ BR1 / S1 jumps across | [S design doc "reached by jumping across"] | 2.5–3 m horizontal gap at equal height if you remove link bridges | Test max horizontal jump (~3 m at run speed) |
| Lift-top drop/jumps from Top Blue to Top Mid | [S] | 4.5 m drop | Fall damage off/none |
| Superbounce onto Lift tower / Sniper tower roofs | [S Halopedia] | Physics glitch — **do not replicate**; optionally leave roof reachable via deliberate trick | — |
| BR3 → S3 rifle sightline | [S Halopedia] | ~33 m line of sight | Sightline only |
| "Sniper Alley" long lower hall | [S Halopedia] | Keep continuous ground-level line Green Hall↔Bottom Mid (~25 m) | Sightline |

## 6. Spawns & weapons
Weapons on map [S Halopedia]: Battle Rifle, SMG, Magnum, Shotgun, Sniper Rifle, Plasma Rifle, Carbine, Energy Sword, Needler.
Placements:
- **Sniper Rifle** — top of Sniper Tower (S3) [S Halopedia].
- **Battle Rifle** — top of Grav-lift tower (Top Blue) and BR tower (opposite sniper) [S Halopedia]; 2 Magnums also on top of lift [S Durinsbane].
- **Shotgun + SMG** — bottom of lift tower / green shotgun hallway [S Durinsbane; Halopedia production note].
- **Energy Sword** — "Sword" callout under BR Bridge [S Bungie.net callout image].
- Plasma Rifle, Carbine, Needler — present [S], positions **unknown** (place freely).
- **Project Long Colt five-gun mapping** (emit_arena_tscn.py / emit_lockout_tscn.py, see docs/weapons/roster_balance.md): Combat Shotgun at BotMid (0, 0, 0), Directed Energy Rifle in Green hall at (0, 0, 17), both 90 s respawn; Marksman Carbine on the BR3 roof; Service Pistols on S3 and Top Blue (x2); Standard Issue Rifle on Top Blue. All on open floor, none gated by a step or lip.
- Exact spawn points are **not sourced**. Diagram cyan dots are suggested FFA spawns spread across all 3 heights [E]. "3D/3D spawn" is a callout on the BR side [S name only].

## 7. Godot build order (CSG / box primitives)
1. Make a `Node3D` "Lockout"; add `CSGCombiner3D` with `use_collision = true`.
2. Ground slabs: BotMid, GreenHall, Sword room. 3. Top Mid deck + four 1 m parapets (gap the parapets where links/ramps meet).
4. Blue tower (Bottom Blue, Mags, Top Blue) + `Area3D` grav lift (upward impulse to reach 9.5 m).
5. BR tower stack + Open Ramp; Sniper stack + Snipe Ramp. 6. Links, BR Bridge, Library, Elbow.
7. Walls/ceilings last (subtract doorways 2×3 m with `CSGBox3D` operation=Subtraction). 8. Kill volume at y = −10.
9. Mark spawns (`Marker3D`) and weapon pickups. Test checklist = Section 5.
Ramps: rotate about X or Z by `atan(rise/length)`, and lengthen the box to `sqrt(L²+rise²)`.

### Primitive table (CSGBox3D: `position` = center, `size`) [E]
| Node | Group | Center (x, y, z) | Size (x, y, z) | Notes |
|---|---|---|---|---|
| BotMid_Floor | Center | (0, -0.25, 0) | (16, 0.5, 16) |  |
| TopMid_Deck | Center | (0, 4.25, 0) | (16, 0.5, 16) |  |
| GreenHall_Floor | Blue/Lift | (0, -0.25, 15) | (6, 0.5, 14) |  |
| BottomBlue_Ledge | Blue/Lift | (0, 2.25, 17) | (12, 0.5, 6) |  |
| BlueRamp | Blue/Lift | (0, 3.30, 10.5) | (4, 0.4, 7) | SLOPED: rotate to match rise in connection table |
| LeftMag | Blue/Lift | (-4.5, 5.75, 14) | (3, 0.5, 4) |  |
| RightMag | Blue/Lift | (4.5, 5.75, 14) | (3, 0.5, 4) |  |
| TopBlue_Deck | Blue/Lift | (0, 8.75, 18) | (12, 0.5, 8) |  |
| BlueLift_Pad | Blue/Lift | (0, -0.05, 21) | (3, 0.1, 3) |  |
| S1_Floor | Sniper | (16, 4.25, -1) | (10, 0.5, 10) |  |
| S2_Floor | Sniper | (17, 7.25, -4) | (8, 0.5, 6) |  |
| S3_SnipeDeck | Sniper | (16, 10.25, -6) | (10, 0.5, 6) |  |
| SnipeRamp | Sniper | (21.5, 8.80, 0) | (2.5, 0.4, 10) | SLOPED: rotate to match rise in connection table |
| Elbow_South | Elbow | (12, 2.30, 19) | (10, 0.4, 2.5) |  |
| Elbow_North | Elbow | (16, 3.00, 12) | (2.5, 0.4, 12) | SLOPED: rotate to match rise in connection table |
| BR1_Floor | BR | (-16, 4.25, 1) | (10, 0.5, 10) |  |
| BR2_Floor | BR | (-17, 7.25, -1) | (8, 0.5, 8) |  |
| BR3_Roof | BR | (-17, 10.25, -3) | (8, 0.5, 8) |  |
| OpenRamp | BR | (-22.5, 2.05, 4) | (2.5, 0.4, 12) | SLOPED: rotate to match rise in connection table |
| BR_Bridge | BR | (-10, 7.30, -10) | (10, 0.4, 2.5) |  |
| Sword_Room | Library/Sword | (-11, 1.75, -12) | (6, 0.5, 6) |  |
| Library_Floor | Library/Sword | (-1, 7.25, -14) | (12, 0.5, 8) |  |
| S1_TopMid_Link | Sniper | (10.5, 4.25, 0) | (5, 0.5, 4) |  |
| BR1_TopMid_Link | BR | (-10.5, 4.25, 2) | (5, 0.5, 4) |  |

Walls not listed: wrap each tower level with 0.5 m thick walls, 3 m high, with doorways facing its links.

## 8. Confidence
| Category | Confidence | Why |
|---|---|---|
| Callout names | **High** | Bungie.net labeled screenshots + community thread + Halopedia agree. |
| Relative layout (which is next to which, level counts) | **Medium-High** | Halopedia text, Bungie design doc, concept overhead and callout shots agree; final map differs from design doc in detail. |
| Weapon set & key placements (sniper, BR, sword, shotgun) | **Medium-High** | Halopedia + Durinsbane + callout image; remaining weapons unplaced. |
| Heights/levels | **Low-Medium** | Inferred from door-height ratios in screenshots; no measurement. |
| Footprint & horizontal distances | **Low** | Pure visual estimate; screenshots are perspective. |
| Jump gaps | **Low** | Built to *require* your movement values; validate in play. |
| Spawn points | **Low** | Not sourced; suggested only. |

## Gaps
- No overhead orthographic map or community measurements from the Bungie era were found; no extracted H2 geometry used. Best upgrade: open `lockout` in the H2EK/Halo 2 Vista assets and read BSP coordinates (WU×3.048 m).
- MLG-era respawn/weapon timers not verified. The 2005 HBO video walkthrough exists but wasn't watched.
- Callout screenshots from Active Rush are 720p captures with Bungie.net watermarks; some look like Halo 2 Vista (2007, PC port), not 343. No H2A/Lockdown art used.

## Sources actually used
- https://www.halopedia.org/Lockout (text; image list via its MediaWiki API)
- Halopedia-hosted Bungie images: https://halo.wiki.gallery/images/0/03/H2_Lockout_Overview.png, https://halo.wiki.gallery/images/2/26/H2_Lockout_Concept_Overhead.jpg, https://halo.wiki.gallery/images/b/bb/H2_Lockout_DesignDoc.jpg, https://halo.wiki.gallery/images/5/55/H2_Lockout_Blockout_1.jpg, https://halo.wiki.gallery/images/1/18/H2_Lockout_Blockout_2.jpg
- https://activerush.wordpress.com/halo-2-callouts-guide/ (Bungie.net callout images, Aug 2014 uploads; see refs/SOURCES.tsv)
- https://www.reddit.com/r/halo/comments/2wa80w/halo_callouts/ (callout names, from search snippet)
- https://durinsbane.home.blog/2020/05/19/halo-2-maps-lockout/ (weapon placements text only)
- https://halo.bungie.org/gameplay/stratguide/map_guides/lockout.html (confirms callout video exists; not watched)

Files: `lockout_overhead.png`, `lockout_elevation.png`, `build_lockout.py` (edit numbers here and re-run), `refs/` (+ `refs/SOURCES.tsv`). Reference images are copyrighted — internal use only.
