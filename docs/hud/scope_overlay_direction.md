# Project Long Colt: Scope Overlay Direction (v1)

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
- the readable white reticle floats on glass;
- a chunky dark bezel has clamp tabs;
- small amber numerals give range and stadia reads;
- the mask is near-black rather than pure black.

The BR, DMR and H2 pistol overlays were used for mood only. Every shape here is original:
- no circle-in-circle BR ring;
- no DMR chevron;
- no H2 pistol bracket.

The early-2000s military-HUD feel comes from three things: the hard rectangular tabs, the flat colour fills, and the under-stroked lines.

### Units
- Everything is authored in **reference pixels at 1080p**.
- At draw time, `u = viewport_height / 1080`, and a line width is `max(1 px, w * u)`.
- Shapes scale with height only. 16:9, 16:10 and ultrawide keep the same aperture and the extra width becomes mask. Pill and octagon apertures also clamp to about 0.47 of the width, so 4:3 still fits.
- There are no textures. Everything is drawn with `Control._draw`: polygons, polylines, arcs and `ThemeDB.fallback_font`.

### Palette (art board "Frozen blue-grey", plus the sodium amber accent and the HUD palette)

| Role | Colour | Source |
|---|---|---|
| Mask | `#0b0f14`, alpha 0.94 to 0.97 | A darker step below board `#1d2630` |
| Bezel body | `#1d2630` | Board |
| Bezel inner edge, tabs, notches | `#3e4c5a` | Board |
| Bezel glass lip, 1 u | `#6e8191` | Board |
| Reticle | `#dfe6ea`, alpha 0.95 | Board highlight, near HUD `FRAME_COLOR` |
| Reticle on target | `(1, 0.18, 0.15)` | HUD `RETICLE_TARGET_COLOR`, so the scope goes red like the crosshair |
| Reticle under-stroke | black, alpha 0.5, line width + 2 u | Readability on snow and on sodium-lit concrete |
| Readouts (magnification) | `#e0a040` | Sodium amber, lifted for text |
| Range numerals, labels | `#c47a2c`, alpha 0.8 | Board accent |
| Glass tint | HUD `SHIELD_FILL` cyan at alpha 0.04 | Barely-there "coated optic" cool |
| Scanlines (MARKSMAN only) | black, alpha 0.045, 1 u lines every 4 u | Subtle, clipped to the aperture |

### Fade timing
- The overlay alpha follows `WeaponHolder.get_zoom_blend()`, which is 0 to 1 linear over the weapon's `zoom_time`. That is 0.10 s for the pistol and 0.12 s for the rifle and carbine, the same curve as the FOV blend.
- At blend 0.5, the crosshair hides and the viewmodel is culled.
- Unzoom shows the viewmodel immediately. The crosshair returns once the blend passes back under 0.5, and the overlay fades out over `zoom_time`.
- Switching weapons, death and respawn snap the blend to 0, so an overlay never carries over to the next weapon or life.

### Ranging conventions
- Stadia are true for the current camera FOV:
  - `px_per_mil = 0.001 / tan(fov/2) * H/2`;
  - `px_for(m, d) = m / d * 1000 * px_per_mil`.
- They are sized for the project's own targets: Player capsule height **1.8 m** and hurtbox width **0.7 m**.
- Range bands follow Lockout sightlines (roughly 15 to 75 m, per roster_balance).
- During the fade, the scale grows with the zoom, which reads as the optic coming up.

## 3. Identities

### SIDEARM (Service Pistol, 2.0x): compact, fast-read
- Aperture: small round eyepiece, r = 300 u (about 0.28 H), mask alpha 0.94. You see more of the world around it than with the other optics.
- Bezel: 16 u thick, with four rectangular clamp tabs (44 x 16 u) at the cardinals.
- Reticle, built for snap reads with no ranging:
  - a 6 u centre dot;
  - a broken inner ring, r = 34 u, 3 u wide, as four 57-degree arcs on the diagonals so the cardinals are open;
  - four heavy 5 u posts from 50 to 96 u.
- Readout: "2.0x" in amber, 26 u type, on the inside bottom of the glass.

### SERVICE_RIFLE (Standard Issue Rifle, 1.8x, BURST only): service burst optic with a simple ranging read
- Aperture: wide stadium (pill), 650 x 330 u half-extents, which suggests a squat battle-rifle sight box. Mask alpha 0.95.
- Bezel: 14 u, with rail-clamp tabs (120 x 14 u) top and bottom centre.
- Reticle:
  - split horizontal lines, 3 u wide, running 20 to 140 u from centre;
  - heavier 6 u outboard bars at 170 to 260 u;
  - a short 3 u lower post at 20 to 64 u;
  - a 5 u centre dot;
  - no top post, so heads stay clear.
- Ranging: three amber width bars under the post, 34 u apart, with small end hooks. Each bar's width equals a 0.7 m torso at **20 / 40 / 60 m** (labelled). Fit the target's shoulders to a bar to read its range.
- Readouts: "1.8x" (amber) and the fire mode, "BURST" (dim amber), at the ends of the flat bottom edge.

### MARKSMAN (Marksman Carbine, 2.5x): precision stadia and ranging ladder, plus mil ticks
- Aperture: large round tube, r = 470 u (about 0.44 H), mask alpha 0.97.
- Bezel: 20 u, with four triangular index notches (28 u wide) pointing in at the cardinals.
- Glass tint and scanlines are on this one only.
- Reticle: a duplex.
  - Heavy 7 u posts run from 0.36 r out to the bezel.
  - Thin 1.5 u inner lines start 8 u from centre and stop at 0.36 r.
  - A 4 u centre dot.
- Mil ticks:
  - On the thin lines, in true mils at the current FOV.
  - The step is auto-picked from 1/2/5/10/20/50 mil as the first that is at least 12 u apart. At 2.5x on a 75-degree base this is 10 mil.
  - Every fifth tick is major (16 u long) and labelled in mils ("50"). Minor ticks are 8 u long.
  - "MIL" is captioned at the right end of the inner line.
- Stadia ladder, lower-left quadrant: four amber posts on a common baseline. Each post is the height of a **1.8 m Spartan at 25 / 50 / 75 / 100 m**, with feet on the baseline, and is labelled underneath. Match the target's height to a post to read its range.
- Readout: "2.5x" in amber, lower-right of the glass.

### FIELD (default for any other zoomer)
- Aperture: chamfered octagon, 540 x 380 u half-extents with 130 u chamfers. Mask alpha 0.95. Bezel 14 u.
- Reticle:
  - a T-post: split horizontal lines (3 u, 18 to 120 u from centre) and a heavy lower post (6 u, 18 to 150 u);
  - an open centre circle, r = 10 u, 2 u wide.
- Readout: magnification, bottom centre.
- Purpose: a new zooming weapon gets a readable optic with zero setup. Give it a bespoke style once it has an identity.
- `ScopeStyle.NONE` opts a zoomer out. It keeps the hip crosshair and viewmodel and draws no overlay.

## 4. Implementation contract
- **WeaponData:**
  - New `enum ScopeStyle { NONE, FIELD, SIDEARM, SERVICE_RIFLE, MARKSMAN }`, stored as an int; append only.
  - New `@export var scope_style: ScopeStyle = ScopeStyle.FIELD`. It replaces `zoom_overlay`, which was removed from the script and from the three .tres files.
  - Values set: pistol 2, rifle 3, carbine 4.
- **ScopeOverlay** (Control, full rect, mouse ignore) is instanced as `HUD/Scope`. Each frame the HUD calls:

  ```
  show_scope(style, blend, camera.fov, magnification, fire_mode_name, reticle_on_target)
  ```

  The node hides itself at blend 0 or style NONE.
- **WeaponHolder:**
  - Owns the blend (`get_zoom_blend()`).
  - Hides the viewmodel by moving the active weapon's GeometryInstance3D descendants (the hands are children of the weapon) to `Player.HIDDEN_BODY_LAYER`, and restores their original layers.
  - Applies to the local player only (`not net_puppet`).
  - Restore runs on unzoom (signal), switch, death, respawn, and as a physics fallback.
- The crosshair is hidden when blend is at least 0.5 and the style isn't NONE.

## 5. Review checklist (in engine)
- [ ] Each zoomer at 1280x720, 1920x1080, 2560x1440 and 3440x1440: the aperture is the same relative size, lines never drop below 1 px, and text stays crisp.
- [ ] Rifle: zoom is only available in BURST. Toggling to AUTO while zoomed drops the overlay and restores the crosshair and viewmodel.
- [ ] Zoom, then reload / melee / take damage / switch / die / respawn: the viewmodel and crosshair come back every time, with no stale overlay.
- [ ] Pick up a weapon while zoomed: the dropped pickup's meshes are on layer 1 (visible to everyone).
- [ ] The marksman ladder's 50 post matches a standing player at 50 m (use the Lockout long lane).
- [ ] The reticle turns red on target.
- [ ] Muzzle flash light: lights aren't culled, so the flash still lights the world while scoped. Expected.
- [ ] Puppets and bots: no layer changes. Remote clients never see a hidden viewmodel.
