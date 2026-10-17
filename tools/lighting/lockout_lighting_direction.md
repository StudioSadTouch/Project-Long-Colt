# Lockout: Lighting and Sky Direction
Art Director, 2026-10-14. Branch `artdir/lockout-lighting` (local only, push freeze). Godot 4.7, Forward+.

**Sources**
- [AB]: `/workspace/artboard/long_colt_artboard.pdf` and `sources.md`.
  - Lighting/Palette note: "Practical in-world sources only: sodium lamps, floodlights, work lights … light should come from objects you can see. Desaturated base palettes with one accent per planet."
  - Planet note: "One climate and palette per planet … frozen blue-grey … rain only on one level."
  - Frozen blue-grey swatches: `#1d2630 #3e4c5a #6e8191 #a9b8c4 #dfe6ea`, accent `#c47a2c`.
  - Planet references: Reach *Winter Contingency* landscape concept and the McMurdo Dry Valleys photo.
- [DD]: design doc v0.3.
  - §2 Tone: multi-planet hard SF, early-2000s Halo 2 military feel.
  - v0.3: "rain specific to Forward Outpost 7," so Lockout has **no rain**.
- [Spec]: `tools/lockout/lockout_spec.md` (Lockout greybox; "Top Mid … centre hole/light").

## 1. Mood
- **The picture:** a brutalist military outpost on an original cold, high-altitude world.
  - Thin air: a deep blue zenith, a pale horizon and crisp distance.
  - Snow-capped alien ranges ring the horizon. A banded gas giant and a small moon hang in the sky.
  - Lockout's cold-peaks mood is the cue, but nothing is lifted from it: no Halo geometry, skybox or forerunner motifs.
- **Look:** Halo 2-style high-fidelity rendering with late-90s/early-2000s restraint.
  - Big, clear value shapes, hard sun shadows, honest bounce.
  - No neon, no colored rim-light gimmicks.
- **Color split:** daylight is cold. Interiors are warm or industrial from practicals: sodium amber is the board's one accent, plus cool fluorescent tubes.

## 2. Key light, sky, ambient, fog
**Sun (DirectionalLight3D)**
- From the **south-west at 35° elevation** (azimuth 225°, −Z is north). It rakes Top Mid and throws the BR tower's long shadow north-east across the map.
- Color (1.0, 0.95, 0.88), near-white with a hint of warmth against the cold sky. Energy **2.0**, harsh.
- Hard shadows (angular size 0, so no PCSS).
- PSSM 4 splits at 6% / 18% / 45% of 120 m, so the cascades break at about 7, 22, 54 and 120 m. Blend splits on. Bias 0.03, normal bias 1.0.
- `light_bake_mode = Dynamic`: the lightmap stores the sun's bounce, and direct sun and shadows stay realtime.

**Sky (custom `lockout_sky.gdshader`, original and procedural)**
- Gradient: zenith `#13213d` → upper `#385478` → horizon `#a8bacc` (the board's `#a9b8c4`).
- Sun disk with a tight glare.
- Two ridged-noise mountain rings, sampled on a circle so there's no seam:
  - Far range: hazy blue-grey rock (darkened board `#6e8191`).
  - Near range: dark.
  - Snow line on both: board `#dfe6ea`.
- Gas giant, radius 0.13 rad, in the north-east sky about 22° up, about 120° from the sun so it reads as a crescent.
- Small cratered moon in the north-west.
- The shader is static (no `TIME`), so the radiance map only re-renders when the sun moves.

**Ambient**
- Sky ambient, energy 0.7. Reflections from the sky.
- After the bake, the lightmap carries occluded sky and bounce for statics, and probes carry it for players and bots.

**Fog**
- Depth fog: density 0.002, cold color (0.60, 0.68, 0.76), aerial perspective 0.5, sky affect 0.25.
- Volumetric fog: density 0.004, length 48 m, anisotropy 0.35.
- Combined, that's about 15–20% haze at the 33 m BR3↔S3 sightline. It's thin air, not murk. Sodium and work lights get faint beams.

**Post**
- ACES tonemap, white 6.
- Glow intensity 0.5, HDR threshold 1.2, so only lamp lenses and the sun bloom.
- SSAO radius 1.2, intensity 1.8.

**GI choice: LightmapGI for statics, plus SSIL. Not SDFGI.**
- Lockout is small, static, boxy and indoor-heavy, which is exactly LightmapGI's case.
- SDFGI is built for large open worlds. It costs more every frame, leaks through the 0.3–0.5 m slabs and parapets, and duplicates what the lightmap already gives.
- SSIL (radius 3, intensity 0.6) adds cheap local bounce for dynamic objects and muzzle-flash scale lighting. It's the first post effect to drop on low settings.

## 3. Fixture vocabulary (reusable scenes in `scenes/props/lighting/`)
| Fixture | Scene | Light | Use |
|---|---|---|---|
| Fluorescent strip | `fixture_fluoro_strip` / `_long` | Spot down, 65°, range 5.5 / 8 m; cool (0.82, 0.93, 1.0) | Ceilings: tower interiors / ground-floor rooms |
| Sodium wall lamp | `fixture_sodium_wall` | Spot, 40° down, 55°, range 9 m; amber (1.0, 0.6, 0.26) | Walls, doors, catwalk parapets |
| Caged work light | `fixture_caged_worklight` | Spot, 38°, range 14 m; halogen (1.0, 0.88, 0.72), baked | Floods on parapets |
| Caged work light (hero) | `fixture_caged_worklight_shadowed` | As above, energy 6, range 16, **realtime shadows** | One per key interior |
| Emissive panel | `fixture_emissive_panel` | Soft spot, range 3.5 m; teal readout | Wall terminals, lift pad edges |
| Beacon | `fixture_beacon` | Emissive only | Tower tops, for skyline silhouettes |

- Every light comes from a visible fixture [AB].
- Housings are dark board steel `#3e4c5a`. Lenses are emissive (they glow under the glow pass, and they act as emitters in the bake).
- Lenses have UV2 and static GI. Housings are GI-dynamic, which saves lightmap atlas space.

## 4. Readability rules
1. **Silhouettes:** players and bots must read dark-on-light against the sky and the far range from every deck. Interiors must read light-on-dark against the sunlit doorways.
   - That's why ambient is never zero, and why the far mountains stay mid-value (hazed) rather than black.
   - Tower-top beacons mark the BR3 and S3 skylines.
2. **No pitch-black areas.** Every covered floor has a fixture over it.
   - I ran a crude coverage check on every covered rectangle, counting practicals only, with no ambient or bounce (`lockout_fixture_plot.png`).
   - Dark fraction is 0–7% in most rooms. Corners of BR2 are at 15%, and those are filled by sky through the open south edge plus bounce.
3. **No glare in sightlines.** Floods are mounted high (Top Blue parapets at 10 m, Library parapets) and aimed down. No light points along a main sightline at eye height.
4. **Weapon spots and the lift stay legible:** a hero work light over Bottom Mid, a hero work light over the Sword room, teal panels on the lift pad.

## 5. Performance budget (Forward+)
- **Realtime-shadowed lights: sun + 3 spots maximum** (Bottom Mid, Sword room, under Top Blue). Any new shadowed light needs sign-off.
- **31 baked (static) spots**, unshadowed. After the bake they cost nothing on statics. Before the bake they render realtime; Forward+ clustering handles that, but it's not the shipping state.
- Distance fade on all fixture lights: begins at 45 m, over 10 m.
- **Leak rule for unshadowed fixtures:** range must be less than the distance to the next floor below. That's why the strips come in two lengths: 5.5 m in towers, 8 m on ground floors.
- **Post cost order when trimming:** volumetric fog → SSIL → SSAO detail → glow.
- Sky: a 5-octave noise shader. Its cost is per sky pixel plus radiance updates, and radiance only updates when the sun moves.
- LightmapGI: quality High, 3 bounces, denoiser on, non-directional, probes at subdiv 8. Expect a small atlas for 62 boxes.

## 6. Assets and licenses
**No third-party assets.** The sky shader, fixture meshes (BoxMesh primitives), materials, environment and placement generator are all original work in this commit, procedural and project-owned. No CC0 or other external assets were needed. Colors come from the board's *proposed* (unsourced) swatches.

## 7. Open items
- **Not compiled or seen in engine:** the sky shader is unverified. A numpy port was checked visually (`lockout_sky_preview.png`).
- **The lightmap must be baked in the editor:** select `LightmapGI` in `arena_lockout.tscn` and `main_lockout.tscn`, then Bake.
- Fixtures have no collision, so players can clip through the parapet floods.
- If Lockout's geometry changes, re-run `tools/lighting/emit_lockout_lighting.py` and update the placements.
