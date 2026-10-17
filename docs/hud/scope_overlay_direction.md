# Project Long Colt: Scope Overlay Direction (v2)

Owner: Art Director. Branch `artdir/scope-overlays` (worktree `/workspace/lc-scopes`, base reserve/integration 2cbef1c).
Code: `scripts/ui/scope_overlay.gd`, `scenes/ui/scope_overlay.tscn`. Preview port: `tools/hud/render_scopes.py` (PIL; previews kept out of the repo so Godot does not import them).

## 1. Survey: what zooms and how zoom works today

| Weapon (.tres) | Secondary | Zoom | zoom_time | Overlay before | Overlay now |
|---|---|---|---|---|---|
| Service Pistol | ZOOM | 2.0x | 0.10 s | CE-style black circle (`zoom_overlay = true`) | **SIDEARM** |
| Standard Issue Rifle | ZOOM, only in BURST (`zoom_only_in_mode = 2`) | 1.8x (46.2 deg) | 0.12 s | none (`zoom_overlay = false`) | **SERVICE_RIFLE** |
| Marksman Carbine | ZOOM | 2.5x | 0.12 s | CE-style black circle | **MARKSMAN** |
| Combat Shotgun | NONE | n/a | | | n/a |
| Directed Energy Rifle | TOGGLE_MODE | n/a | | | n/a |
| Any future zoomer | ZOOM | any | | | **FIELD** (the default) |

How zoom flows through the code:
- `Weapon.secondary_pressed` toggles `set_zoom()`, which emits `zoom_changed`. Zoom is cancelled by reload (`start_reload`), melee, fire-mode toggle when `!can_zoom()`, `equip()`, `holster()`, and damage (`WeaponHolder._on_owner_damaged`).
- `WeaponHolder._update_zoom_fov` (physics) uses `move_toward` to move `camera.fov` to `get_zoom_fov(player.fov)` over `zoom_time`. `_on_zoom_changed` scales look sensitivity.
- Death: `on_owner_died` holsters everything. Respawn: `reset_loadout` frees the weapons, reinstalls them and resets the FOV. Switching, pickup swaps, `apply_loadout` and the death drop all holster before they disconnect or reparent a weapon.
- The HUD is a CanvasLayer child of the local Player only. `_become_puppet()` frees it, so anything the HUD draws is client-local by construction. The net host mirrors the zoom flag onto puppets, which have no HUD and a hidden holder (`holder.visible = false`).
- Constraints found:
  - `Weapon._physics_process` gates on `visible`, so the viewmodel can't be hidden with `weapon.visible`.
  - `holder.visible` is puppet state.
  - The local camera already culls `Player.HIDDEN_BODY_LAYER` (1 << 1), the first-person-hidden body layer.

## 2. Style

The overlays are Bungie-era Halo 2 to Reach in spirit:
- heavy, readable white reticles with a dark halo, floating on glass;
- a chunky bevelled bezel with clamp tabs;
- amber readouts on small dark plates;
- a near-black mask rather than pure black.

The BR, DMR and H2 pistol overlays were used for mood only. Every shape here is original:
- no circle-in-circle BR ring;
- no DMR chevron;
- no H2 pistol bracket.

The early-2000s military-HUD feel comes from the hard rectangular tabs, the plated readouts, the flat fills, and the haloed strokes.

### Units
- Everything is authored in **reference pixels at 1080p**: `u = viewport_height / 1080`.
- **Reticle** strokes are `max(2 px, w * u)`, and every reticle element (lines, arcs, the dot, numerals) gets a **1.5 u dark halo** on all sides, ends included.
- **Hardware** (bezel, tabs, plates) uses `max(1 px, w * u)`.
- Shapes scale with height only. Ultrawide adds mask; the pill and octagon apertures clamp to about 0.45 of the width so 4:3 still fits.
- There are no textures. Everything is drawn with `Control._draw`: polygons, polylines, arcs, `draw_string_outline` / `draw_string` with `ThemeDB.fallback_font`.

### Weights at 1080p (v2: about 2x heavier than v1)

| Element | Width |
|---|---|
| Main posts and outboard bars | 6 to 7 px |
| Split lines, lower posts, pistol ring | 4 to 5 px |
| Stadia bars | 4 to 5 px, amber |
| Duplex fine lines | 2.5 px |
| Mil ticks | 2 px minor, 3 px major |
| Centre dots | 6 to 8 px squares |
| Halo | +1.5 px per side, `#050709` at alpha 0.72 |

### Bezels and hardware (v2: about 1.7x thicker)
- Bezels are drawn **outside** the aperture as a mitred offset ring, so the glass is not eaten.
- Thickness: pistol 28 u, rifle and field 24 u, marksman 34 u.
- Bevel, from the glass outward:
  - a 2 u lit lip (`#6e8191`);
  - an inner chamfer band, 30 % of the bezel, in `#3e4c5a`;
  - the dark body, `#1d2630`;
  - a 2 u `#3e4c5a` rim edge.
- Clamp tabs:
  - pistol 76 x 40 u, rifle 170 x 38 u;
  - 3 u `#3e4c5a` border and a 2 u lit line on the outer face.
- Marksman index notches are 44 u wide and 34 u deep, with a lit edge.

### Readouts
- Magnification sits in amber `#e0a040` on a **plate** set on the bezel.
- Plate: `#13191f` at alpha 0.94, a 2 u `#3e4c5a` border, a 1.5 u lit top line, and 13 u side padding.
- Type sizes: magnification 26 u, fire mode 22 u (plated), range and mil numerals 18 u (outlined, not plated, `AMBER_DIM`).
- All text has a 4 u dark outline.

### Palette (art board "Frozen blue-grey", plus the sodium amber accent and the HUD palette)

| Role | Colour |
|---|---|
| Mask | `#0b0f14`, alpha 0.94 to 0.97 |
| Bezel body / chamfer / lip | `#1d2630` / `#3e4c5a` / `#6e8191` |
| Readout plate | `#13191f`, alpha 0.94 |
| Reticle | `#dfe6ea`, alpha 0.97 |
| Reticle on target | HUD `RETICLE_TARGET_COLOR` red |
| Halo and text outline | `#050709`, alpha 0.72 |
| Readouts | `#e0a040` |
| Range numerals | `AMBER_DIM` (0.82, 0.53, 0.20) |
| Glass tint | HUD `SHIELD_FILL` cyan, alpha 0.04 |
| Rim shade | 8 stacked bands of `#05080a` at alpha 0.035, darkest at the rim (about 0.25), fading inward |
| Scanlines (marksman only) | black, alpha 0.045, every 4 u |

### Glass depth
- Every overlay darkens slightly inside the window rim. Rim depth: pistol 50 u, rifle and field 60 u, marksman 80 u.
- It is subtle, readable as a lens edge rather than a vignette, and never reaches the reticle.

### Fade timing (v2)
- **Fade in:** alpha follows `WeaponHolder.get_zoom_blend()`, 0 to 1 linear over the weapon's `zoom_time` (0.10 s pistol, 0.12 s rifle and carbine), the same curve as the FOV blend. At blend 0.5 the crosshair hides and the viewmodel is culled.
- **Unzoom:** snaps the overlay off the same frame, through the `zoom_changed` signal and in physics. The viewmodel and crosshair come back at once, so the overlay never fades over a visible gun.
- Switching weapons, death and respawn also snap it to 0.

### Ranging conventions
- Stadia are true for the current camera FOV:
  - `px_per_mil = 0.001 / tan(fov/2) * H/2`;
  - `px_for(m, d) = m / d * 1000 * px_per_mil`.
- **Feet-line stadia:** put the target's head on the centre, and its feet land on the bar for its range. The target is the Player capsule, **2.1 m**.
- Ranges stay inside Lockout's 15 to 75 m band (roster_balance).

## 3. Identities

### SIDEARM (Service Pistol, 2.0x): fastest read
- Aperture: compact round eyepiece, r = 300 u, mask alpha 0.94.
- Bezel 28 u. Tabs left, top and right. The **"2.0x" plate is the bottom tab**.
- Reticle, nothing else:
  - a broken ring, r = 38 u, **5 u**, as four 57-degree arcs on the diagonals;
  - four **7 u** posts from 54 to 106 u;
  - an 8 u centre dot.
- No ranging and no numerals in the glass.

### SERVICE_RIFLE (Standard Issue Rifle, 1.8x, BURST only): service burst optic with a simple ranging read
- Aperture: wide stadium, 650 x 330 u half-extents, mask alpha 0.95. Bezel 24 u, with big rail tabs top and bottom centre.
- Reticle:
  - split horizontal lines, 4 u, 22 to 150 u from centre;
  - 6 u outboard bars at 185 to 280 u;
  - a 4 u lower post running to just past the 20 m bar;
  - a 6 u dot;
  - no top post.
- Ranging, bold and simple: **two** amber feet-line bars on the post, **20 m and 40 m** (about 114 / 57 px at 1080p). Each is 72 u wide, 5 u thick, with 12 u upturned end hooks, and labelled to the right at 18 u.
- Readouts: a **"1.8x"** plate and a **"BURST"** plate on the flat bottom bezel, either side of the centre tab.

### MARKSMAN (Marksman Carbine, 2.5x): precision duplex, mil ticks, stadia stack
- Aperture: large round tube, r = 470 u, mask alpha 0.97. Bezel 34 u, with four index notches. Glass tint, rim shade (80 u) and scanlines.
- Reticle:
  - a duplex: **6 u** heavy posts from 0.36 r to the bezel, 2.5 u fine lines from 10 u out to 0.36 r;
  - a 6 u dot.
- **Mil ticks on the horizontal only** (lead reads; there is no bullet drop):
  - true mils at the current FOV;
  - the step is auto-picked from 1/2/5/10/20/50 mil, first at least 14 u apart, so 10 mil at 2.5x;
  - 2 u minor and 3 u major ticks every fifth;
  - only the right-hand major ("50") is labelled.
- **Stadia stack hanging from the lower fine post:** amber feet-line bars for **25 / 50 / 75 m** (about 127 / 63 / 42 px at 1080p). They are 4 u thick, graduate 60 / 46 / 32 u wide, and are labelled to the right at 18 u.
- v1's detached lower-left ladder, the 100 m post, the vertical mil ticks and the "MIL" caption are all cut.
- Readout: a **"2.5x"** plate on the bezel at the lower-right 45-degree point.

### FIELD (default for any other zoomer)
- Aperture: chamfered octagon, 540 x 380 u with 130 u chamfers. Bezel 24 u, rim shade 60 u.
- Reticle: a T-post, with 4 u split horizontals, a 6 u lower post (20 to 160 u) and a 3 u centre circle, r = 12 u.
- Readout: a magnification plate on the bottom bezel.
- `ScopeStyle.NONE` opts a zoomer out entirely.

## 4. Implementation contract
- **WeaponData:**
  - `enum ScopeStyle { NONE, FIELD, SIDEARM, SERVICE_RIFLE, MARKSMAN }`, stored as an int; append only.
  - `@export var scope_style: ScopeStyle = ScopeStyle.FIELD`. It replaces `zoom_overlay`.
  - Values set: pistol 2, rifle 3, carbine 4.
- **ScopeOverlay** (Control, full rect, mouse ignore) is instanced as `HUD/Scope`. Each frame the HUD calls:

  ```
  show_scope(style, blend, camera.fov, magnification, fire_mode_name, reticle_on_target)
  ```

- **WeaponHolder:**
  - Owns the blend: rise over `zoom_time`, 0 at once on unzoom.
  - Hides the viewmodel past blend 0.5 by moving the active weapon's GeometryInstance3D descendants to `Player.HIDDEN_BODY_LAYER`.
  - Restores the original layers on unzoom, switch, death and respawn.
  - Applies to the local player only.
- The crosshair hides when blend is at least 0.5 and the style isn't NONE.
- Preview port: `tools/hud/render_scopes.py`, a 1:1 geometry port in PIL. It is the reference for review; the engine is the truth.

## 5. Review checklist (in engine)
- [ ] Each zoomer at 1280x720, 1920x1080, 2560x1440 and 3440x1440: the aperture is the same relative size, reticle strokes are at least 2 px with a halo, and plates are crisp.
- [ ] Reticle and numerals read on the bright snow sky **and** on dark `#1d2630` walls.
- [ ] Unzoom: the overlay, crosshair and viewmodel all swap in the same frame, with no fade over the gun.
- [ ] Rifle: zoom is only available in BURST. Toggling to AUTO while zoomed drops the overlay at once.
- [ ] Zoom, then reload / melee / take damage / switch / die / respawn: the viewmodel and crosshair come back every time.
- [ ] Pick up a weapon while zoomed: the dropped pickup's meshes are on layer 1.
- [ ] Marksman 50 m bar and rifle 40 m bar: a standing player at that range, head on the centre, has its feet on the bar.
- [ ] The reticle turns red on target.
- [ ] The muzzle flash light still lights the world while scoped. Expected.

## Changelog
- **v2 (polish):**
  - reticle about 2x heavier with a halo;
  - bezels about 1.7x thicker and bevelled;
  - bigger tabs;
  - plated amber readouts (26 / 22 / 18 u);
  - marksman stadia moved to the lower post and decluttered;
  - rifle stadia cut to two bold bars;
  - rim shade on all glass;
  - the overlay snaps off on unzoom.
- **v1:** first pass (fe3ef0f).
