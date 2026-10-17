# Kamino: Cloning Facility (Star Wars: Battlefront II, 2005): Greybox Blockout Spec for Project Long Colt

> **Read this first:** the only layout source is the in-game overhead map on the Battlefront wiki. No measurements exist, so **every dimension is ESTIMATED [E]**. I traced the overhead at **1 px ≈ 0.36 m**, then made it exactly point-symmetric about the Central Platform. The trace was already symmetric to within ~15 px. That way Red and Blue are mirror images for Team Slayer 8v8. Tags: **[S]** = sourced, **[E]** = estimated by me.

Build: `PYTHONPATH=<dir with numpy> blender -b --factory-startup --python tools/kamino/build_kamino.py` (from the repo root). Blender 4.0's glTF exporter needs numpy. `pip install --target <dir> numpy` is enough. Add `-- --no-render` to skip the previews.

The script regenerates all of these (edit the script, never the outputs):

| Output | What it is |
|---|---|
| `assets/models/environment/kamino_greybox.glb` | Geometry. Every walkable / solid mesh is `*-col` (trimesh StaticBodies on World layer 1). Ocean, platform undersides, stilts and the distant city are visual only. |
| `tools/kamino/kamino_greybox.blend` | The same scene, grouped into collections (Platforms, Bridges, Nubs, RedBase, BlueBase, Ocean, Markers, Callouts). `tools/kamino/.gdignore` keeps Godot from trying to import it. |
| `scenes/levels/kamino.tscn` | Level: glb + `Spawns` (11 Red, 11 Blue, 17 FFA Marker3Ds) + KillVolume at y -12 (the ocean). |
| `scenes/main/main_kamino.tscn` | Offline testbed: Player + 11 weapon pickups + sun/environment, no bots. |
| `scenes/main/arena_kamino.tscn` | Arena (Bot Arena / LAN, in `MapList` as `kamino`): pickups, bots (count set by the game mode), runtime navmesh (~1.7k polygons), 27 roam points, NetMatch. |
| `tools/kamino/previews/*.png` | Overhead (north up, 160 m frame), overhead without roofs, and two perspective renders. |

## 1. Scale
- Player 2.1 m, 7.5 m/s, ~6.7 m running jump (`scripts/player/player.gd`).
- **Footprint ~140 × 140 m.** Base centres are ±55 m apart on x and the far landing nubs reach ±75 m on z. That is about 1.2× Headlong. BF2 ran this map at 32+ players, and at 16 the lanes are long but the bridges funnel the fights.
- Platform decks have a **9 m** radius (the overhead ring is ~30 px ≈ 10.8 m including the lip) [E]. Bridges are 4 m wide with 1 m rails. Gaps between platform edges are 6–8 m, and the base bridges are ~11 m.
- Deck heights [E] (BF2's platforms sit at different levels, with ramps between them [S strategy page: "head up the ramp to platform ten"]): Central / Mid platforms **0**, the bases' North/South platforms **2.5**, the landing pads **4**, the Cross platforms **1**, the Flank platforms **-1.5**, the base plazas **0**, the facility roofs **8**. Every bridge slope is ≤ 21°, and the roof ramps are 29°.
- Ocean at -14 (visual). KillVolume at -12: **falling off is death**, and no platform edge has a rail.

## 2. Coordinates
Godot axes: +Y up, **+X east, -Z north** (north = top of the wiki overhead). The origin is the Central Platform. **Red base = west** (the overhead's left D-shaped building) and **Blue base = east**. Everything on the Blue side is the Red side rotated 180° about the origin.

## 3. Callouts
The wiki names none, and players in BF2 call command posts by number [S]. These names are mine [E]. Pairs are mirror images.

| Callout (Red side / Blue side) | Deck y | Notes |
|---|---|---|
| Central Platform | 0 | Four bridges (one to each Mid and Flank platform). Four turret emplacements and the **Directed Energy Rifle**. "The central platform, which has the most fighting" [S]. |
| Red Mid / Blue Mid | 0 | A base's straight exit to Central. Its nub is a jump (~1.8 m gap, 1.5 m drop) to the enemy Flank platform. |
| Red North / Blue South | 2.5 | A base's raised exit. Standard Issue Rifle. |
| North Pad / South Pad | 4 | The high landing platforms (the overhead's ship icon) [S], two nubs each. **Combat Shotgun**. |
| North Cross / South Cross | 1 | Links the Pad, the near Mid and the far Flank. |
| Blue Flank / Red Flank | -1.5 | The low exit of the *other* team's base (Blue Flank sits on the north half). Standard Issue Rifle. |
| Base Plaza | 0 | The open half-disc deck (r 31) where you spawn. Blast walls before the doors, two turret emplacements, crates. Three bridges leave it. |
| Facility Hall | 0 | Half-disc building (r 13). Three doors and four firing slits in the curved wall, columns and low cover. |
| Facility Roof | 8 | "A fantastic sniping post just outside the lab plaza" [S]. Two exterior ramps from the plaza's back corners. **Marksman Carbine**. |
| Cloning Lab | 0 | Round room behind the hall (the overhead's circle with dots) [S]. Four clone tanks as cover. Service Pistol. |
| Landing Pads (×2 per base) | 0 | Behind the flat side at both ends (the overhead's small rectangles) [S], each with a parked gunship as cover. Spawn area. |
| Nubs | platform y | 12 dead-end round perches on short railed catwalks (the overhead's small circles) [S]. |

## 4. Weapons (Long Colt five-gun mapping [E])
BF2 has class loadouts, not pickups, so this is Halo-style power logic placed symmetrically:
- **Directed Energy Rifle** (90 s): Central Platform. It is the only one.
- **Combat Shotgun** (90 s): North Pad, South Pad.
- **Marksman Carbine**: each Facility Roof.
- **Standard Issue Rifle**: Red North, Blue South, Red Flank, Blue Flank.
- **Service Pistol**: each Cloning Lab.

## 5. Spawns and modes
- `SPAWN_Red_00..10` / `SPAWN_Blue_00..10`: plaza (4), hall (2), lab (1), landing pads (2) and roof (2) of the team's base. Team Slayer uses only your team's.
- `SPAWN_FFA_00..16`: one on every platform (11), plus each base's plaza front, lab and roof (6). Free for All uses only these.
- SpawnManager picks the marker farthest from living enemies and out of their sight, then faces it toward the map centre.

## 6. Not done / next steps
- **BF2 features with no Long Colt equivalent yet:** laser turrets (the emplacements are just cover blocks), command posts / Conquest, 1-Flag CTF, health and ammo droids, heroes.
- **Bots** path over the runtime navmesh (bridges, ramps, roofs). They don't know about the nub-to-platform jump.
- **Lighting:** a cool, dim sun only (stormy Kamino), with no rain, fog or lightmap bake yet.
- **Checked headless only** (Godot 4.7, `tests/map_select_self_test.gd`, `tests/game_mode_self_test.gd`): it imports, bakes, spawns 8 (FFA) and 16 (Team Slayer) players on the right markers, and bots cross the map. Nobody has played it yet.

## 7. Confidence
| Category | Confidence | Why |
|---|---|---|
| Plan (platform lattice, bridges, D-shaped bases, lab, pads, nubs) | **Medium-High** | Traced directly from the in-game overhead. |
| Footprint / distances | **Low-Medium** | One scale factor chosen so platforms and bridges read right next to a 2.1 m Spartan. |
| Heights | **Low** | Read from one screenshot plus the strategy page's "ramp up to platform ten". |
| Interiors (hall, roof access, lab) | **Low** | The overhead shows outlines only. |
| Weapons, spawns, callout names | **Low** | Not sourced (BF2 has no weapon pickups and uses numbered command posts). |

## Sources
- https://battlefront.fandom.com/wiki/Kamino:_Cloning_Facility/Original (text, read through the MediaWiki API: `api.php?action=parse&page=Kamino:_Cloning_Facility/Original&prop=wikitext`)
- `File:Kamino_Cloning_Facility_Map.PNG` (in-game overhead, the main trace) and `File:Kamino_Cloning_Facility.PNG` (in-game screenshot: stilted platforms, ramps between levels)
- https://battlefront.fandom.com/wiki/Strategies:_Kamino ("platform ten / nine", sniping from higher platforms, crates and turrets as the only cover)

The reference images are copyrighted and not committed. Fetch them from the URLs above.
