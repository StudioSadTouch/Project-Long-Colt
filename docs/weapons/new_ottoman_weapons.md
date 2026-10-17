# New Ottoman issue weapons: player models

The seven weapons the New Ottoman enemies carry (`docs/enemies/new_ottoman.md`) drop when they
die, and the player can pick them up. They used to borrow a player gun's viewmodel (the tüfek
looked like the marksman carbine, the glaive rifle like the service rifle, and so on). Each now
has its own greybox model in first person, in third person on a player's body, on pickups, and
on the Weapon Range rack. Stats are unchanged (`resources/weapons/new_ottoman/*.tres`).

## Files

| What | Where |
|---|---|
| Scenes (generated) | `scenes/weapons/new_ottoman/<weapon>.tscn` by `tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py` |
| Grain texture (generated) | `assets/textures/weapons/noe_grain.png` (same script; VRAM + mipmaps in its `.import`) |
| First-person clips (generated) | `assets/weapons/viewmodel/new_ottoman/<weapon>.tres` by `tools/viewmodel_anims/gen_viewmodel_anims.py` |
| Third-person model ids | `CharacterAnimState.WeaponModel` `TUFEK` .. `YATAGAN` (PROTOCOL 13) |
| Third-person props | `CharacterWeaponProps.NEW_OTTOMAN_SCENES` (loaded on first use) |
| Range rack | second rack row in `tools/range/build_range.py` (`NOE_RACK_Z`) |
| Self-test | `tests/new_ottoman_weapons_self_test.gd` |
| Visual check | `tests/new_ottoman_weapons_render.gd` (needs a display, see below) |

To change a model, edit the scene generator, then run both generators (the clip generator
reads the scenes' rest poses):

```
python3 tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py
python3 tools/viewmodel_anims/gen_viewmodel_anims.py
```

## The models

Palette and materials follow the board: lacquered gunmetal, oxblood lacquer, issue wood,
leather, steel. There's no tombak (officers only) and nothing glows (the sensor slit is the
faction's only light; the yatağan warns by its hum). The thin grain texture breaks up the flat
colours: grain on wood, brushing on metal, weave on cloth.

| Weapon | Model | First person |
|---|---|---|
| Tüfek (Janissary) | long heavy barrel in a full-length oxblood-lacquered stock with steel bands and nose cap, muzzle brake, long low tube sight, tall narrow butt with a steel inlay | rifle reloads retargeted; heavy buck and the handle slamming back per shot |
| Long rifle (Akinji marksman) | worn gunmetal bolt action, long slim barrel, handled-smooth wood, cobalt cloth on the fore-end, leather cheek wrap tied with cord, long scope with a leather hood | rifle reloads; the right hand works the bolt after every shot (not the last) |
| Glaive rifle (Azab) | stamped receiver, plain issue wood with a field-repair strap, a glaive-length single-edged blade under the barrel with an Azab-red tie at the socket | rifle reloads; the melee is a bayonet thrust into the middle of the view |
| Raider carbine (Akinji) | short slotted shroud, curved magazine, saddle ring on the left, leather-wrapped wrist and grip, oxblood coat cloth tied on | rifle reloads; the handle cycles per shot |
| Humbara launcher (Okçu) | stubby wide bore over a four-chamber drum, tall ladder sight for the lob, Okçu cobalt band, issue-wood stock with a thick recoil pad | swaps the drum (out, toss, fresh one from the belt, seat at the insert fraction, slap; the empty reload also cocks the lever); the drum indexes a quarter turn per shot |
| Kılıç (Akinji sabre) | curved single-edged blade that flares into the yelman near the tip, crossguard with ball quillons and a langet, short leather grip, angled pommel | the longsword's forehand / backhand |
| Yatağan (Janissary) | forward-curved blade, no guard, a gunmetal drive unit on the spine by the hilt with an oxblood hydraulic hose, steel bolster, bone hilt with the eared pommel | the longsword's forehand / backhand |

Design choices worth knowing:

- **Glaive cant.** The glaive blade is canted 20 degrees about the bore, so its flat faces the
  shooter's eye. Seen straight down the barrel, a vertical blade is a sliver. At port arms the
  cant doesn't show.
- **Rifle offsets.** The four rifles keep the rifle's part offsets (`LeftHand` 0.14 m ahead
  of `Magazine`, `ChargingHandle` beside the receiver), so the rifle's hand-keyed reload
  carries over and the left hand meets the magazine.
- **Drum node.** The humbara's `Drum` is a `Node3D` (rest rotation zero) so its clips can key
  its rotation; the cylinder meshes under it carry their own orientation.
- **Blade frame.** The blades are built on the longsword's blade frame (`ry(-6) * rx(50)`, the
  side guard), so `gen_character_anims.py` `SWORD_TILT` holds them in third person and they
  hang at the hip from the longsword's holster transform.
- **Length.** The long guns are longer than the service rifle. In third person (props at 1.4x)
  the tüfek is about 1.65 m and the glaive rifle with its blade about 1.75 m: the board's
  "long-barrelled heavy rifle" and the forest of steel.

## Third person

`CharacterAnimState.MODEL_SCENES` maps each weapon's file name to its own `WeaponModel`, so
players and bots resolve the same id. The ids are appended to the enum, which is synced as
ints, hence PROTOCOL 13. `CharacterWeaponProps` loads the scene the first time a body shows
it. The rifle-class weapons are held like the rifle and holstered on the back. The kılıç and
yatağan count as swords (`_is_sword`): sword hold, hip holster. Fire clips: the tüfek and long
rifle use `fire_carbine`, the humbara `fire_heavy`, the rest `fire_rifle`.

## Checks

- `tests/new_ottoman_weapons_self_test.gd` (headless). Scene contract: own data, a Grip,
  viewmodel-only hands, the clip set, every clip track resolving to a node, gunfire on the
  guns and none on the blades, no emissive material, a unique third-person model drawn from
  this scene. In a player's hands: the gun fires and plays `fire`, reloads with
  `reload_tactical` and refills, then returns to idle; the blade swings with its clip; the
  third-person prop shows. Pickups show the model without the hands.
- `tests/range_self_test.gd`: every rack weapon, the New Ottoman row included, can be taken.
- `tests/new_ottoman_weapons_render.gd`: first-person poses (idle, mid-reload, seat, melee hit,
  fire), each model from four sides, and the third-person props on the player body. It needs
  a display:
  `DISPLAY=:0 flatpak run org.godotengine.Godot --path . --script res://tests/new_ottoman_weapons_render.gd`
  writes PNGs to `res://.noe_render/` (Godot skips dot folders; delete it after).

## Not done

- **Enemy props.** Enemies still hold `EnemyRig`'s own two- or three-box weapon props, so what
  an enemy carries doesn't match the drop yet. Using these scenes there means placing them on
  the rig's arms (port arms, the Akinji low ready, the swings) and adds about 20 to 30 mesh
  nodes per enemy, so it wants a merged-mesh copy for Horde-sized crowds.
- **Yatağan hum.** The yatağan's hum (`hum.wav`) only plays on Janissaries, not in the
  player's hand.
- **Reload sounds.** No reload sounds (same as every other weapon: `ViewmodelReload.sounds` is
  empty).
