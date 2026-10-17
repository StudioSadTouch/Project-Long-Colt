# Texture & PBR Material Pipeline — Project Long Colt

This directory provides procedural generation utilities and CC0 PBR fetching tools for Project Long Colt (Godot 4.7 Forward+).

---

## 1. Quick Start

### Regenerate All Prototype Textures & Materials
```bash
python3 tools/textures/generate_prototype_textures.py
```
This procedurally creates all 1024x1024 seamless prototype textures (albedo, roughness, metallic, normal, emission) and automatically emits corresponding Godot `StandardMaterial3D` resources (`.tres`) with triplanar world-space mapping enabled.

### Fetch Curated CC0 PBR Materials
```bash
# List recommended curated CC0 assets:
python3 tools/textures/fetch_cc0_pbr.py --list

# Download and generate materials for a specific ambientCG asset:
python3 tools/textures/fetch_cc0_pbr.py --asset Concrete019 --res 1K

# Download all curated assets:
python3 tools/textures/fetch_cc0_pbr.py --curated-all
```

---

## 2. Generated Assets Directory Layout

### Prototype Textures (`assets/textures/prototype/`)
* **Metric Grids (1.0m, 1024x1024, seamless):**
  * `grid_dark_1m.png`: Charcoal/gunmetal grey base (#1c1f24), 0.1m minor lines, 0.5m mid lines, 1.0m outer border, corner L-brackets, center crosshairs, metric measures.
  * `grid_light_1m.png`: Off-white / laboratory grey (#d6dae0) for ceilings and clean interior labs.
  * `grid_orange_1m.png`: High-visibility industrial test orange (#b84800) for interactive elements, jump pads, test chambers.
  * `grid_green_1m.png`: Tactical OD / UNSC military green (#1e3322) for exterior bases and military compound blockouts.
  * `grid_blue_1m.png`: High-tech naval cobalt blue (#14253d) for command centers and tech installations.
  * `grid_red_1m.png`: Red hazard/combat base (#3d1515) for team bases and lethal kill-zones.
* **Metric Grids (0.5m, 1024x1024, seamless):**
  * `grid_dark_05m.png`, `grid_light_05m.png`, `grid_orange_05m.png`: 4 distinct 0.5m quadrants (SEC-A1, SEC-A2, SEC-B1, SEC-B2) with 0.1m and 0.25m subdivision marks.
* **Hazard Warning Stripes (1024x1024, seamless 45-degree):**
  * `hazard_yellow_black.png`: Industrial OSHA yellow (#f1b80d) and matte black (#1e2024) with rivet border frame.
  * `hazard_orange_dark.png`: Tactical deep orange (#df500e) and dark gunmetal (#23262c).
* **Industrial Dark Concrete PBR Set (1024x1024, seamless):**
  * `concrete_dark_albedo.png`: Aggregate concrete with formwork seams and corner tie-rod depressions.
  * `concrete_dark_roughness.png`: Matte roughness map (0.85–0.96) with aggregate variation.
  * `concrete_dark_normal.png`: Tangent-space normal map capturing formwork seams and aggregate pitting.
* **Metal Deck Tread Floor PBR Set (1024x1024, seamless):**
  * `metal_deck_albedo.png`: Chequer diamond plate with polished tread peaks and dark seam channels.
  * `metal_deck_roughness.png`: Smooth tread tops (0.35), matte valleys (0.75).
  * `metal_deck_metallic.png`: Steel metallic map (0.92).
  * `metal_deck_normal.png`: 3D raised diamond lugs and recessed plate joints.
* **Sci-Fi Bulkhead Wall Panel PBR Set (1024x1024):**
  * `scifi_panel_albedo.png`: Heavy composite armor plates, central recessed maintenance bay with cooling louvers, corner hex bolts, stencil markings ("LONG COLT // SEC-04"), status LEDs.
  * `scifi_panel_roughness.png`, `scifi_panel_metallic.png`, `scifi_panel_normal.png`.
* **Sci-Fi Trim Sheet PBR Set (1024x1024, horizontally seamless):**
  * `scifi_trim_albedo.png`: 7 functional trim bands (Hydraulic pipe, Armor edge, Hazard runner, Vent grille, Optical LED channel, Cable tray, Heavy kickplate).
  * `scifi_trim_roughness.png`, `scifi_trim_metallic.png`, `scifi_trim_normal.png`.
  * `scifi_trim_emission.png`: Emissive channel for glowing cyan optical tracks and amber status lamps.

### Godot Materials (`resources/materials/prototype/` & `resources/materials/environment/`)
All materials are Godot `StandardMaterial3D` resources configured for instant greybox drop-in:
* `uv1_triplanar = true`
* `uv1_world_triplanar = true`
* `uv1_scale = Vector3(1, 1, 1)` (1 Godot unit = 1 real-world meter)
* `texture_filter = 5` (Linear with mipmaps anisotropic)

---

## 3. How to Use in Level Design

1. Drag any material from `res://resources/materials/prototype/` (or `res://resources/materials/environment/`) onto any greybox mesh, CSGBox3D, CSGPolygon3D, or level geometry.
2. Because `uv1_world_triplanar = true` is enabled:
   * **Zero UV Unwrapping Required**: The engine projects the texture seamlessly along the world X, Y, and Z axes.
   * **Seamless Geometry Adjacency**: Adjacent modular blocks, ramps, and walls align seamlessly at 1-meter intervals without texture seams or manual texture alignment.
   * **Immediate Scale Feedback**: The 1.0m, 0.5m, and 0.1m grid marks immediately tell designers if doorway heights, jump distances, and cover heights match gameplay specs (e.g., standard Spartan jump height: 1.1m; crouching cover: 1.2m; standing cover: 2.0m; doorway: 2.5m).
