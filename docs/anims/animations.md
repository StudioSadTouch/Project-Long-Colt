# Animations

Two generated sets, one procedural layer. Edit the generators, never the `.tres` outputs.

## Third person (players, bots, puppets)
- Generator: `tools/character_anims/gen_character_anims.py` (numpy; `PYTHONPATH` needs it) →
  `assets/characters/player/anims/character_anims.tres`. `--check` runs the head-hitbox,
  floor, waist-seam and IK checks without writing. Output is deterministic.
- Driven only by `CharacterAnimState` (`CharacterAnimDriver`), so local, remote and AI bodies
  animate the same. New in v1.4:
  - `turn_l` / `turn_r`: idle step in place after `turn_threshold_deg` (35) of standing yaw.
    Twist is tracked both ways, so turning back unwinds before it steps the other way.
  - `throw_rifle` / `throw_pistol`: `Action.THROW`, from `GrenadeThrower.throw_started`
    (fires on offline, host and client throws).
  - `death_crouch_<dir>`: picked when the body was crouched or sliding (smoothed crouch
    amount, because Player clears crouch/slide on the death tick). Before, a crouched death
    started from the standing pose and popped up 0.6 m.
  - `fire_carbine`, `fire_shotgun` (kick + pump rack), `fire_heavy` (rocket): chosen by
    `CharacterAnimState.MODEL_FIRE[weapon_model]`, else `fire_<class>`.
- `weapon_model` / `holster_model` (`WeaponModel`, keyed by the weapon data / scene file
  name) are on the wire (PROTOCOL 8). `CharacterWeaponProps` shows the real mesh: before,
  every rifle-class weapon (carbine, shotgun, rocket) showed the assault rifle. The New
  Ottoman weapons have their own ids since PROTOCOL 13 (the sabre and yatağan take the sword
  hold and hip holster).
- v1.5 run (super-soldier): forward runs drive the knee high and kick the heel (`RUN["roll"]`
  knee / kick), the pelvis twists 9 deg, and `run_pump_*` hunches the chest 7 deg with the
  head held level, a 7 deg shoulder counter-swing and a heavier weapon bob. The hips' height
  and lean are unchanged (head-hitbox rule). Unarmed sprint arms swing 28 deg, elbows bent.
- Steady upper body (`CharacterAnimDriver.steady_upper_body`): the upper layer rides on the
  locomotion pelvis, which leans 8 deg into the run and twists with each stride, so the
  weapon dipped 8 deg and swung +-9 deg while running. After each mix the abdomen is
  counter-rotated by the pelvis rotation (standing locomotion only), so the gun stays on the
  aim line and the visible head stays 4 cm (was 10.6 cm) from its hitbox. A shot also steadies
  the run pump for `pump_fire_hold`.
- Rocket launcher prop sits on the shoulder (`CharacterWeaponProps.rocket_shoulder_offset`);
  the arms still use the rifle poses.
- v1.6 melee classes (`WeaponType.SWORD` / `HAMMER`, clips `aim_/crouch_upper_/run_pump_/
  switch_/throw_<w>`): the longsword at a side guard (hilt low at the right hip, blade up and
  forward), the gravity hammer at port arms across the body. Swings are keyed in model space
  and joined by a Catmull-Rom spline (speed carries through the strike): `melee_sword`
  (forehand diagonal) and `melee_sword_b` (backhand flat cut) alternate by the synced action
  counter; `melee_hammer` is an overhead slam landing at the 0.25 s smash. Out-of-reach swing
  targets are pulled onto the arm's reach (both hands together for the hammer).
- v1.7 bladed stance, all upper-body clips: the chest turns right of the aim line, left shoulder
  forward (`STANCE`: rifle 22, pistol 14, sword 28, hammer 20 deg, unarmed square). Hands keep
  their aim-frame holds, so guns still point down the aim line; the head keeps facing it.
  Standing idle / settle / land / turn root the right foot back with its toes out and the left
  foot forward, hips turned 10 deg (`FEET_STAND`, `STANCE_HIP_YAW`); crouch idle blades the
  feet too. Walk / run / crouch-walk keep an even stride. Upper-body clips are authored on
  square hips (`ref_stand`): the driver's steady upper body cancels the hip turn for the upper
  layer, so what is authored is what plays.
- v1.7 RESET is no longer the T-pose: per joint, the orientation nearest every pose that joint
  takes in the clips that drive it (`centre_reset`). AnimationMixer blends rotations relative
  to RESET along the shortest path; against the T-pose the held-weapon hands sat near 180 deg,
  where "shortest" flips on a tiny change (the rifle whipped round mid aim-blend). Additive
  clips are written on top of RESET (Godot reads an additive key as RESET * delta).
- v1.7 holsters: rifle-class weapons slung diagonally across the back (grip behind the right
  shoulder, muzzle toward the left hip), the hammer across the back (head behind the left
  shoulder), the longsword from the hip (blade down and back). `CharacterWeaponProps` reads
  `holster_sword` / `holster_hammer` metadata for the melee weapons.
- v1.8 run: an operator's stride - compact and low (no heel kick, a touch of knee), softer
  heel-toe roll, half the hip twist and bob, 6 deg lean; the run pump keeps the shoulders
  square and the rifle quiet on the aim line.
- Bench: `scenes/characters/character_anim_preview.tscn` (G throw, M cycle the weapon in hand, Q/E turn,
  4 then K crouched death).

## First person
- Hand-keyed in their scenes: rifle and pistol reload / melee clips.
- Generator: `tools/viewmodel_anims/gen_viewmodel_anims.py` (no deps) →
  `assets/weapons/viewmodel/*.tres`:
  - carbine, shotgun, rocket launcher: full sets (`reload_tactical`, `reload_empty`,
    `melee`, `fire`, `fire_empty`). Carbine clips are the rifle's, retargeted. Shotgun loads
    four shells then racks the pump on empty. Rocket swaps the pack at the rear.
  - longsword / gravity hammer (`tools/melee_weapons` scenes): RESET, idle, melee (and the
    longsword's `melee_b` backhand; `ViewmodelMelee` alternates when a `<clip>_b` exists). The
    longsword's rest is the side guard, blade rising at the right of the view.
  - rifle / pistol: an `fx` library with `fire` (bolt / slide cycle) and `fire_empty` (locks
    back on the last round, the pose their `reload_empty` starts from).
  - New Ottoman weapons (`assets/weapons/viewmodel/new_ottoman/`): the four rifles reload and
    butt-stroke with the rifle's clips retargeted (the glaive rifle thrusts its bayonet
    instead); the long rifle works its bolt after each shot; the humbara swaps its drum and
    indexes it per shot; the kılıç and yatağan use the longsword's swings
    (`docs/weapons/new_ottoman_weapons.md`).
  - Checks: reload length = `reload_time`, `sfx_mag_seat` at `reload_insert_fraction`, melee
    hit key at 0.1, clips start and end on the rest pose.
- `ViewmodelFire` (weapon child) plays `fire` / `fire_empty` per shot; never cuts reload/melee.
- `ViewmodelMotion` (Player child) moves the `WeaponHolder`, under every weapon clip: bob,
  look sway, strafe roll, air, crouch/slide, breath, equip raise, and spring kicks for fire
  (scaled by `recoil_pitch`), landing and grenade throws. Zoom damps it. `intensity` scales it.

## Over-the-shoulder camera
`ThirdPersonCamera` (Player child) is a second, view-only camera: weapons, AimAssist,
grenades and the netcode keep aiming from the eye `Camera3D`. It converges on the eye ray's
hit (so the crosshair is where shots land), sweeps a sphere to stay out of walls, hides the
viewmodel, draws your tracers from the body's gun (NetFx), and falls back to first person
while zoomed or in a vehicle. Settings `third_person` / `left_shoulder` (menu and pause
pages); `action_camera_view` (T, d-pad down) and `action_camera_shoulder` (B, d-pad right).
Test: `tests/third_person_camera_self_test.gd`.

## Tests
`tests/anim_self_test.gd` drives the body and player scenes headless: turn steps, throw,
crouched death, fire clip per model, props, every weapon's viewmodel set, motion bounds, and
that the running body keeps its gun level and its head on the hitbox.

## v1.8 (Hospitaller fit, 2026-10-25)
Rifle hold pushed out to a shouldered grip (R 36 cm / L 55 cm from the shoulder line, elbows
out) and the crouch re-posed (pelvis 0.38, lean 38 deg; crouch idle = right-knee kneel) so the
bulky Hospitaller armor does not scrunch. Head windows, floor and IK checks unchanged and
passing. See docs/characters/hospitaller.md.
