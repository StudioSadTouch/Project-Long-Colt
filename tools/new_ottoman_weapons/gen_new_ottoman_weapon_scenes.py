#!/usr/bin/env python3
"""Generate the New Ottoman issue weapon scenes (greybox primitives, their own models).

    python3 tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py

Writes scenes/weapons/new_ottoman/<weapon>.tscn for the seven weapons the enemies carry and
drop (docs/weapons/new_ottoman_weapons.md), and the shared grain texture
assets/textures/weapons/noe_grain.png. Edit this script, not the scenes. Then run
tools/viewmodel_anims/gen_viewmodel_anims.py, which reads these scenes' rest poses.

Same contract as the player's gun scenes, so the player, the pickups and the third-person
props use them like any other weapon:
  * root Node3D with weapon.gd + its WeaponData (the scene path is the weapon's network id, so
    files keep their names); root position = first-person rest pose, root rotation zero
  * "Grip" mesh where the hand holds it (CharacterWeaponProps puts that on the third-person
    hand); RightHand / LeftHand, the muzzle light and every script node are viewmodel_only
  * guns: Magazine, LeftHand and ChargingHandle are direct children at the rifle's offsets
    (LeftHand 0.14 m ahead of the magazine), because their reloads are the rifle's clips
    retargeted; WeaponFx carries the gunfire sound enemies are heard by (WeaponAudio)
  * blades: built along the longsword's blade frame (side guard), which
    tools/character_anims/gen_character_anims.py SWORD_TILT holds in third person; no WeaponFx
    (a blade has no gunfire)
Palette and materials follow the New Ottoman board: lacquered gunmetal, oxblood lacquer,
worn wood and leather, steel, tombak nowhere (officers only), no glow anywhere (the sensor slit
is the faction's only light, and the yatagan warns by its hum).
"""
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
GRAIN = "assets/textures/weapons/noe_grain.png"


# ---------------------------------------------------------------- 3x3 math (row-major)
def rx(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((1, 0, 0), (0, c, -s), (0, s, c))


def ry(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((c, 0, s), (0, 1, 0), (-s, 0, c))


def rz(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((c, -s, 0), (s, c, 0), (0, 0, 1))


I3 = ((1, 0, 0), (0, 1, 0), (0, 0, 1))
ALONG_Z = rx(90.0)  # a CylinderMesh (built along Y) lying along the barrel
ALONG_X = rz(90.0)


def matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def apply(m, v):
    return tuple(sum(m[r][c] * v[c] for c in range(3)) for r in range(3))


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def mul(v, k):
    return tuple(x * k for x in v)


def fnum(x):
    if abs(x) < 1e-7:
        return "0"
    s = "%.6g" % x
    return "0" if s == "-0" else s


def xf(basis, origin):
    # .tscn Transform3D(...) lists the basis ROW by row, then the origin (checked:
    # str_to_var("Transform3D(1, 2, 3, ...)").basis.x is (1, 4, 7)). Matrices here are row-major.
    b = basis
    vals = [b[0][0], b[0][1], b[0][2], b[1][0], b[1][1], b[1][2], b[2][0], b[2][1], b[2][2]] + list(origin)
    return "Transform3D(%s)" % ", ".join(fnum(v) for v in vals)


def hex_color(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


# ---------------------------------------------------------------- materials
# id: (albedo, roughness, metallic, texture, triplanar scale). Board palette (section 6).
TEXTURES = {"grain": ("res://" + GRAIN, "tex_grain"),
            "trim": ("res://assets/textures/prototype/scifi_trim_albedo.png", "tex_trim")}
MATERIALS = {
    "gunmetal": (hex_color("3a3f46"), 0.42, 0.55, "grain", 14),
    "gunmetal_dark": (hex_color("23262b"), 0.6, 0.4, "grain", 16),
    "gunmetal_worn": ((0.3, 0.32, 0.35), 0.62, 0.45, "grain", 14),    # Akinji: looted, rubbed bare
    "steel": (hex_color("8a9099"), 0.32, 0.6, None, 0),
    "blade": ((0.8, 0.82, 0.86), 0.26, 0.5, None, 0),                 # the longsword's steel
    "lacquer": (hex_color("6e1f22"), 0.28, 0.12, "grain", 9),         # Janissary oxblood, polished
    "wood": (hex_color("4a3423"), 0.75, 0.0, "grain", 9),             # Azab issue furniture
    "wood_worn": ((0.4, 0.3, 0.21), 0.82, 0.0, "grain", 9),           # Akinji, handled smooth
    "leather": (hex_color("3b2a20"), 0.85, 0.0, "grain", 18),
    "cloth_red": (hex_color("9c2f2c"), 0.95, 0.0, "grain", 22),       # the Azab red
    "cloth_oxblood": (hex_color("6e1f22"), 0.95, 0.0, "grain", 22),   # Akinji raider coat
    "cobalt": (hex_color("2f4f9a"), 0.7, 0.0, "grain", 22),           # Okcu / marksman cobalt
    "bone": ((0.86, 0.82, 0.74), 0.5, 0.0, "grain", 12),              # yatagan hilt
    "hose": (hex_color("9c2f2c"), 0.5, 0.0, None, 0),                 # Janissary hydraulics
    "glass": (hex_color("1d2f5e"), 0.06, 0.3, None, 0),               # dark lens, never lit
    "bore": ((0.03, 0.03, 0.035), 0.9, 0.0, None, 0),
    "skin": ((0.72, 0.55, 0.42), 0.8, 0.0, "trim", 10),               # the player's hands
}


class Scene:
    """One weapon scene. Parts are named nodes; meshes are de-duplicated by shape."""

    def __init__(self, root_name, data_rel, lib_rel, root_pos):
        self.root_name = root_name
        self.data_rel = data_rel
        self.lib_rel = lib_rel
        self.root_pos = root_pos
        self.mats = []
        self.meshes = {}
        self.nodes = []
        self.names = set()

    def _mat(self, mid):
        if mid not in self.mats:
            self.mats.append(mid)
        return "Mat_" + mid

    def _mesh(self, kind, mat, dims):
        key = (kind, mat) + tuple(round(d, 5) for d in dims)
        if key not in self.meshes:
            self._mat(mat)
            self.meshes[key] = "Mesh_%d" % (len(self.meshes) + 1)
        return self.meshes[key]

    def _node(self, name, kind, parent, basis, origin, vm_only, extra):
        assert name not in self.names, name
        self.names.add(name)
        group = ' groups=["viewmodel_only"]' if vm_only else ""
        lines = ['[node name="%s" type="%s" parent="%s"%s]' % (name, kind, parent, group)]
        if basis != I3 or any(abs(o) > 1e-9 for o in origin):
            lines.append("transform = %s" % xf(basis, origin))
        self.nodes.append("\n".join(lines + extra))

    def box(self, name, mat, size, pos=(0, 0, 0), basis=I3, parent=".", vm_only=False):
        mesh = self._mesh("box", mat, size)
        self._node(name, "MeshInstance3D", parent, basis, pos, vm_only,
                   ["cast_shadow = 0", 'mesh = SubResource("%s")' % mesh])

    def cyl(self, name, mat, radius, length, pos=(0, 0, 0), basis=ALONG_Z, parent=".", sides=14, top=None,
            vm_only=False):
        mesh = self._mesh("cyl", mat, (radius, length, sides, radius if top is None else top))
        self._node(name, "MeshInstance3D", parent, basis, pos, vm_only,
                   ["cast_shadow = 0", 'mesh = SubResource("%s")' % mesh])

    def torus(self, name, mat, inner, outer, pos=(0, 0, 0), basis=I3, parent="."):
        mesh = self._mesh("torus", mat, (inner, outer))
        self._node(name, "MeshInstance3D", parent, basis, pos, False,
                   ["cast_shadow = 0", 'mesh = SubResource("%s")' % mesh])

    def group(self, name, pos=(0, 0, 0), basis=I3, parent="."):
        """A plain Node3D: an animated part whose meshes need their own rotations (its rest
        rotation stays zero, the viewmodel clips key rotation from zero)."""
        self._node(name, "Node3D", parent, basis, pos, False, [])

    def raw(self, text):
        self.nodes.append(text)

    # ------------------------------------------------------------ shared rigs
    def hands_rifle(self, left=(-0.005, -0.055, -0.2)):
        """The rifle's hands: right on the grip, left on the fore-end (rifle offsets)."""
        self.box("Grip", self.grip_mat, (0.03, 0.09, 0.04), (0, -0.07, 0.1), rx(-15))
        self.box("RightHand", "skin", (0.05, 0.05, 0.09), (0.01, -0.08, 0.13), rx(-15), vm_only=True)
        self.box("LeftHand", "skin", (0.05, 0.05, 0.09), left, vm_only=True)

    def muzzle(self, at, energy=2.5, color=(1, 0.8, 0.55), light_range=2.5):
        self.raw('[node name="Muzzle" type="Marker3D" parent="."]\ntransform = %s' % xf(I3, at))
        self.raw('[node name="MuzzleLight" type="OmniLight3D" parent="Muzzle" groups=["viewmodel_only"]]\n'
                 "visible = false\nlight_color = Color(%s, 1)\nlight_energy = %s\nomni_range = %s"
                 % (", ".join(fnum(c) for c in color), fnum(energy), fnum(light_range)))
        self.flash_energy = energy

    grip_mat = "wood"
    fire_sound = None
    pitch_jitter = 0.03
    flash_energy = 2.5
    flash_time = 0.05
    impact_kick = 1.2
    gun = True

    def write(self, rel):
        res = ['[ext_resource type="Script" path="res://scripts/weapons/weapon.gd" id="1_weapon"]',
               '[ext_resource type="Resource" path="res://%s" id="2_data"]' % self.data_rel,
               '[ext_resource type="AnimationLibrary" path="res://%s" id="3_lib"]' % self.lib_rel,
               '[ext_resource type="Script" path="res://scripts/weapons/viewmodel_melee.gd" id="4_melee"]']
        if self.gun:
            res += ['[ext_resource type="Script" path="res://scripts/weapons/viewmodel_reload.gd" id="5_reload"]',
                    '[ext_resource type="Script" path="res://scripts/weapons/viewmodel_fire.gd" id="6_fire"]',
                    '[ext_resource type="Script" path="res://scripts/weapons/weapon_fx.gd" id="7_fx"]',
                    '[ext_resource type="AudioStream" path="res://%s" id="8_sound"]' % self.fire_sound]
        used_tex = []
        for mid in self.mats:
            tex = MATERIALS[mid][3]
            if tex and tex not in used_tex:
                used_tex.append(tex)
        for tex in used_tex:
            res.append('[ext_resource type="Texture2D" path="%s" id="%s"]' % TEXTURES[tex])
        subs = []
        for mid in self.mats:
            albedo, rough, metal, tex, scale = MATERIALS[mid]
            lines = ['[sub_resource type="StandardMaterial3D" id="Mat_%s"]' % mid,
                     "albedo_color = Color(%s, 1)" % ", ".join(fnum(c) for c in albedo)]
            if tex:
                lines += ['albedo_texture = ExtResource("%s")' % TEXTURES[tex][1], "uv1_triplanar = true",
                          "uv1_scale = Vector3(%d, %d, %d)" % (scale, scale, scale)]
            if metal:
                lines.append("metallic = %s" % fnum(metal))
            lines.append("roughness = %s" % fnum(rough))
            subs.append("\n".join(lines))
        for (kind, mat, *dims), mid in self.meshes.items():
            if kind == "box":
                body = "size = Vector3(%s)" % ", ".join(fnum(d) for d in dims)
                subs.append('[sub_resource type="BoxMesh" id="%s"]\nmaterial = SubResource("Mat_%s")\n%s'
                            % (mid, mat, body))
            elif kind == "cyl":
                radius, length, sides, top = dims
                subs.append('[sub_resource type="CylinderMesh" id="%s"]\nmaterial = SubResource("Mat_%s")\n'
                            "top_radius = %s\nbottom_radius = %s\nheight = %s\nradial_segments = %d\nrings = 1"
                            % (mid, mat, fnum(top), fnum(radius), fnum(length), sides))
            else:
                inner, outer = dims
                subs.append('[sub_resource type="TorusMesh" id="%s"]\nmaterial = SubResource("Mat_%s")\n'
                            "inner_radius = %s\nouter_radius = %s\nrings = 16\nring_segments = 6"
                            % (mid, mat, fnum(inner), fnum(outer)))
        out = ["[gd_scene load_steps=%d format=3]" % (len(res) + len(subs) + 1), ""] + res + [""]
        out += ["; GENERATED by tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py - edit the script, "
                "not this file.", ""]
        for s in subs:
            out += [s, ""]
        out += ['[node name="%s" type="Node3D"]' % self.root_name, "transform = %s" % xf(I3, self.root_pos),
                'script = ExtResource("1_weapon")', 'data = ExtResource("2_data")', ""]
        for n in self.nodes:
            out += [n, ""]
        if self.gun:
            out += ['[node name="WeaponFx" type="Node" parent="." groups=["viewmodel_only"] '
                    'node_paths=PackedStringArray("muzzle_light")]',
                    'script = ExtResource("7_fx")', 'fire_sound = ExtResource("8_sound")',
                    'muzzle_light = NodePath("../Muzzle/MuzzleLight")', "pitch_jitter = %s" % fnum(self.pitch_jitter),
                    "flash_time = %s" % fnum(self.flash_time), "flash_energy = %s" % fnum(self.flash_energy), ""]
        out += ['[node name="AnimationPlayer" type="AnimationPlayer" parent="." groups=["viewmodel_only"]]',
                "libraries = {", '&"": ExtResource("3_lib")', "}", ""]
        if self.gun:
            out += ['[node name="ViewmodelReload" type="Node" parent="." groups=["viewmodel_only"] '
                    'node_paths=PackedStringArray("animation_player")]',
                    'script = ExtResource("5_reload")', 'animation_player = NodePath("../AnimationPlayer")', ""]
        out += ['[node name="ViewmodelMelee" type="Node" parent="." groups=["viewmodel_only"] '
                'node_paths=PackedStringArray("animation_player")]',
                'script = ExtResource("4_melee")', 'animation_player = NodePath("../AnimationPlayer")',
                "hit_time = 0.1", "impact_kick_deg = %s" % fnum(self.impact_kick), ""]
        if self.gun:
            out += ['[node name="ViewmodelFire" type="Node" parent="." groups=["viewmodel_only"] '
                    'node_paths=PackedStringArray("animation_player")]',
                    'script = ExtResource("6_fire")', 'animation_player = NodePath("../AnimationPlayer")', ""]
        path = os.path.join(REPO, rel)
        with open(path, "w") as f:
            f.write("\n".join(out))
        print("wrote", rel)


def gun(name, root_name, root_pos=(0.17, -0.19, -0.38)):
    return Scene(root_name, "resources/weapons/new_ottoman/%s.tres" % name,
                 "assets/weapons/viewmodel/new_ottoman/%s.tres" % name, root_pos)


SOUND_RIFLE = "assets/audio/weapons/standard_issue_rifle_fire.wav"
SOUND_CARBINE = "assets/audio/weapons/marksman_carbine_fire.wav"
SOUND_HUMBARA = "assets/audio/enemies/new_ottoman/humbara_fire.wav"


def stock(s, mat, wrist_z, butt_z, butt_len, butt_h, plate="steel", drop=0.035):
    """Straight wrist from wrist_z back into a tall, narrow butt (the Ottoman musket line),
    with a butt plate."""
    back = butt_z - butt_len * 0.5 + 0.02
    s.box("Wrist", mat, (0.04, 0.058, back - wrist_z), (0, -0.012, (wrist_z + back) * 0.5))
    s.box("Butt", mat, (0.045, butt_h, butt_len), (0, -drop, butt_z))
    s.box("ButtPlate", plate, (0.048, butt_h + 0.006, 0.014), (0, -drop, butt_z + butt_len * 0.5 + 0.006))


# ---------------------------------------------------------------- the guns
def tufek():
    """Janissary heavy rifle. Long heavy barrel in a full-length oxblood-lacquered stock held
    by steel bands, a muzzle brake, a long low tube sight, polished like everything a Janissary
    carries."""
    s = gun("tufek", "Tufek")
    s.grip_mat = "lacquer"
    s.fire_sound = SOUND_CARBINE
    s.box("Receiver", "gunmetal", (0.058, 0.08, 0.3), (0, 0, 0))
    s.box("ReceiverTop", "gunmetal_dark", (0.044, 0.014, 0.26), (0, 0.046, 0))
    s.box("ForeStock", "lacquer", (0.05, 0.05, 0.4), (0, -0.022, -0.35))
    s.box("NoseCap", "steel", (0.052, 0.052, 0.02), (0, -0.018, -0.555))
    s.box("Barrel", "steel", (0.026, 0.026, 0.56), (0, 0.016, -0.43))
    for i, z in enumerate((-0.27, -0.44)):
        s.box("Band%d" % (i + 1), "steel", (0.056, 0.074, 0.014), (0, -0.006, z))
    s.box("MuzzleBrake", "gunmetal_dark", (0.042, 0.042, 0.07), (0, 0.016, -0.73))
    for i, z in enumerate((-0.715, -0.745)):
        s.box("BrakePort%d" % (i + 1), "bore", (0.044, 0.016, 0.01), (0, 0.016, z))
    s.box("FrontSight", "gunmetal_dark", (0.008, 0.026, 0.01), (0, 0.04, -0.69))
    # Tube sight on two clamps.
    s.cyl("Scope", "gunmetal_dark", 0.016, 0.2, (0, 0.072, -0.05))
    s.cyl("ScopeBell", "gunmetal_dark", 0.021, 0.05, (0, 0.072, -0.17), top=0.016)
    s.cyl("ScopeLens", "glass", 0.018, 0.004, (0, 0.072, -0.196))
    s.cyl("ScopeEye", "gunmetal", 0.018, 0.024, (0, 0.072, 0.062))
    for i, z in enumerate((0.04, -0.09)):
        s.box("ScopeClamp%d" % (i + 1), "gunmetal", (0.026, 0.03, 0.022), (0, 0.054, z))
    s.box("Magazine", "gunmetal_dark", (0.036, 0.078, 0.062), (0, -0.085, -0.06), rx(-8))
    s.box("MagPlate", "steel", (0.04, 0.008, 0.066), (0, -0.042, 0), parent="Magazine")
    s.box("ChargingHandle", "steel", (0.024, 0.016, 0.026), (0.04, 0.02, 0.06))
    s.box("TriggerGuard", "steel", (0.008, 0.008, 0.07), (0, -0.05, 0.05))
    stock(s, "lacquer", 0.12, 0.31, 0.2, 0.11)
    s.box("Inlay", "steel", (0.047, 0.006, 0.17), (0, 0.0, 0.31))  # a bright line down the butt
    s.hands_rifle()
    s.muzzle((0, 0.016, -0.77), energy=2.8)
    s.write("scenes/weapons/new_ottoman/tufek.tscn")


def long_rifle():
    """Akinji marksman rifle. Looted and layered: a worn gunmetal action with a bolt handle on
    the right, a long slim barrel, handled-smooth wood, the marksman's cobalt cloth wound round
    the fore-end, a leather cheek wrap tied with cord, and a long scope with a leather hood
    (the glint the enemy gives away before each shot)."""
    s = gun("long_rifle", "LongRifle")
    s.grip_mat = "wood_worn"
    s.fire_sound = SOUND_CARBINE
    s.box("Receiver", "gunmetal_worn", (0.05, 0.07, 0.28), (0, 0, 0))
    s.box("ForeEnd", "wood_worn", (0.044, 0.046, 0.32), (0, -0.024, -0.3))
    s.box("Wrap", "cobalt", (0.05, 0.052, 0.09), (0, -0.022, -0.21))
    for i, z in enumerate((-0.17, -0.25)):
        s.box("WrapCord%d" % (i + 1), "leather", (0.052, 0.054, 0.008), (0, -0.022, z))
    s.box("Barrel", "gunmetal_dark", (0.02, 0.02, 0.56), (0, 0.012, -0.42))
    s.box("MuzzleCrown", "gunmetal_dark", (0.026, 0.026, 0.03), (0, 0.012, -0.69))
    s.cyl("Scope", "gunmetal_dark", 0.019, 0.3, (0, 0.074, -0.04))
    s.cyl("ScopeHood", "leather", 0.024, 0.07, (0, 0.074, -0.22))
    s.cyl("ScopeLens", "glass", 0.02, 0.004, (0, 0.074, -0.19))
    s.cyl("ScopeEye", "leather", 0.023, 0.04, (0, 0.074, 0.12))
    s.box("ScopeTurret", "gunmetal_dark", (0.02, 0.02, 0.022), (0, 0.098, -0.03))
    for i, z in enumerate((0.04, -0.1)):
        s.box("ScopeMount%d" % (i + 1), "gunmetal_worn", (0.022, 0.03, 0.02), (0, 0.05, z))
    s.box("Magazine", "gunmetal_dark", (0.03, 0.05, 0.06), (0, -0.07, -0.06))
    # Bolt: the handle sticks out to the right with a round knob (the fire clip cycles it).
    s.box("ChargingHandle", "steel", (0.044, 0.01, 0.012), (0.045, 0.012, 0.07))
    s.cyl("BoltKnob", "steel", 0.011, 0.02, (0.022, 0, 0), ALONG_X, parent="ChargingHandle", sides=10)
    s.box("TriggerGuard", "gunmetal_dark", (0.008, 0.008, 0.07), (0, -0.048, 0.05))
    stock(s, "wood_worn", 0.12, 0.3, 0.2, 0.1, plate="leather")
    s.box("CheekWrap", "leather", (0.05, 0.03, 0.13), (0, 0.025, 0.28))
    for i, z in enumerate((0.225, 0.335)):
        s.box("CheekCord%d" % (i + 1), "cloth_red" if i else "leather", (0.052, 0.112, 0.008), (0, -0.033, z))
    s.hands_rifle()
    s.muzzle((0, 0.012, -0.71), energy=2.6)
    s.write("scenes/weapons/new_ottoman/long_rifle.tscn")


def glaive_rifle():
    """Azab line rifle: cheap stamped receiver, plain issue wood with a field-repair strap, and
    a glaive-length blade fixed under the barrel, its socket wound with Azab red cloth. The
    blade is the silhouette: in a packed line they stand up over the caps."""
    s = gun("glaive_rifle", "GlaiveRifle")
    s.fire_sound = SOUND_RIFLE
    s.impact_kick = 1.6
    s.box("Receiver", "gunmetal", (0.055, 0.075, 0.3), (0, 0, 0))
    for i, z in enumerate((-0.09, 0.0, 0.09)):
        s.box("Rib%d" % (i + 1), "gunmetal_dark", (0.058, 0.006, 0.012), (0, 0.02, z))  # stamped ribs
    s.box("ForeEnd", "wood", (0.046, 0.048, 0.3), (0, -0.022, -0.3))
    s.box("Barrel", "gunmetal_dark", (0.024, 0.024, 0.4), (0, 0.014, -0.35))
    s.box("Band", "steel", (0.05, 0.07, 0.012), (0, -0.006, -0.42))
    s.box("FrontSight", "gunmetal_dark", (0.006, 0.024, 0.008), (0, 0.036, -0.52))
    s.box("RearSight", "gunmetal_dark", (0.024, 0.016, 0.012), (0, 0.044, 0.1))
    # Blade: socket under the muzzle, the red tie, then a long single-edged glaive (spine up,
    # edge down) widening toward its point. The mount is canted 20 deg about the bore so the
    # flat faces the shooter's eye (seen straight down the barrel it would be a sliver); at port
    # arms the cant doesn't show.
    s.group("Glaive", (0, 0.014, -0.5), rz(-20))
    s.box("Socket", "gunmetal_dark", (0.03, 0.036, 0.09), (0, -0.04, 0), parent="Glaive")
    s.box("Tie", "cloth_red", (0.036, 0.044, 0.035), (0, -0.04, 0.03), parent="Glaive")
    s.box("TieTail", "cloth_red", (0.006, 0.05, 0.016), (-0.019, -0.074, 0.038), rx(-12), parent="Glaive")
    s.box("BladeBase", "blade", (0.012, 0.06, 0.14), (0, -0.047, -0.11), parent="Glaive")
    s.box("BladeMid", "blade", (0.012, 0.078, 0.16), (0, -0.056, -0.26), parent="Glaive")
    s.box("BladeTip", "blade", (0.012, 0.045, 0.045), (0, -0.05, -0.355), rx(45), parent="Glaive")
    s.box("BladeSpine", "steel", (0.014, 0.008, 0.33), (0, -0.017, -0.2), parent="Glaive")
    s.box("Magazine", "gunmetal_dark", (0.032, 0.09, 0.055), (0, -0.09, -0.06), rx(-10))
    s.box("ChargingHandle", "steel", (0.022, 0.012, 0.02), (0.037, 0.02, 0.06))
    stock(s, "wood", 0.12, 0.29, 0.18, 0.095)
    s.box("RepairStrap", "gunmetal_dark", (0.046, 0.064, 0.03), (0, -0.012, 0.16))
    s.hands_rifle()
    s.muzzle((0, 0.014, -0.56))
    s.write("scenes/weapons/new_ottoman/glaive_rifle.tscn")


def raider_carbine():
    """Akinji raider's short carbine, a horseman's gun: slotted barrel shroud, curved magazine,
    a saddle ring on the left, leather-wrapped wrist and grip, oxblood coat cloth tied on."""
    s = gun("raider_carbine", "RaiderCarbine", (0.17, -0.19, -0.37))
    s.grip_mat = "leather"
    s.fire_sound = SOUND_RIFLE
    s.box("Receiver", "gunmetal_worn", (0.054, 0.072, 0.26), (0, 0, 0.01))
    s.box("Shroud", "gunmetal_dark", (0.036, 0.04, 0.2), (0, 0.012, -0.22))
    for i, z in enumerate((-0.16, -0.21, -0.26)):
        s.box("ShroudSlot%d" % (i + 1), "bore", (0.038, 0.012, 0.022), (0, 0.016, z))
    s.box("Barrel", "gunmetal_dark", (0.02, 0.02, 0.1), (0, 0.012, -0.36))
    s.box("FrontSight", "gunmetal_dark", (0.02, 0.026, 0.014), (0, 0.04, -0.31))
    s.box("Handguard", "wood_worn", (0.046, 0.04, 0.17), (0, -0.026, -0.2))
    s.box("Tie", "cloth_oxblood", (0.05, 0.046, 0.03), (0, -0.022, -0.27))
    # Curved magazine: two sections, the lower one swept forward.
    s.box("Magazine", "gunmetal_dark", (0.032, 0.06, 0.05), (0, -0.075, -0.06), rx(8))
    s.box("MagLower", "gunmetal_dark", (0.032, 0.06, 0.05), (0, -0.05, -0.012), rx(18), parent="Magazine")
    s.box("ChargingHandle", "steel", (0.022, 0.012, 0.022), (0.036, 0.022, 0.04))
    s.box("SaddleBar", "steel", (0.006, 0.008, 0.07), (-0.03, 0.0, 0.05))
    s.torus("SaddleRing", "steel", 0.012, 0.017, (-0.036, -0.014, 0.05), ALONG_X)
    s.box("Wrist", "leather", (0.042, 0.058, 0.09), (0, -0.012, 0.175))
    s.box("Butt", "wood_worn", (0.044, 0.085, 0.11), (0, -0.03, 0.27))
    s.box("ButtPlate", "steel", (0.047, 0.091, 0.012), (0, -0.03, 0.331))
    s.hands_rifle()
    s.muzzle((0, 0.012, -0.415), energy=2.0)
    s.pitch_jitter = 0.05
    s.write("scenes/weapons/new_ottoman/raider_carbine.tscn")


def humbara_launcher():
    """Okcu lobbing launcher (a humbara is a grenade): a stubby wide bore over a four-chamber
    drum, a tall ladder sight for the lob, the Okcu's cobalt band, an issue-wood stock with a
    thick recoil pad. Reloads by swapping the drum (Drum is a Node3D so the clips can turn it)."""
    s = gun("humbara_launcher", "HumbaraLauncher", (0.17, -0.2, -0.4))
    s.fire_sound = SOUND_HUMBARA
    s.pitch_jitter = 0.04
    s.flash_time = 0.08
    s.impact_kick = 1.4
    bore_y = 0.006
    drum_at = (0, bore_y - 0.034, -0.07)
    s.box("Frame", "gunmetal", (0.05, 0.064, 0.17), (0, -0.02, 0.07))
    s.box("TopStrap", "gunmetal", (0.03, 0.016, 0.2), (0, bore_y + 0.045, -0.06))
    s.box("BottomStrap", "gunmetal_dark", (0.024, 0.02, 0.24), (0, -0.105, -0.12))
    s.group("Drum", drum_at)
    s.cyl("DrumBody", "gunmetal_dark", 0.062, 0.13, parent="Drum", sides=16)
    s.cyl("Axle", "steel", 0.012, 0.15, parent="Drum", sides=8)
    for k in range(4):
        a = math.radians(90 * k)  # chamber 2 sits under the bore
        s.cyl("Chamber%d" % (k + 1), "bore", 0.019, 0.006, (0.034 * math.cos(a), 0.034 * math.sin(a), -0.066),
              parent="Drum", sides=10)
        b = math.radians(45 + 90 * k)
        s.box("Flute%d" % (k + 1), "steel", (0.012, 0.012, 0.11), (0.058 * math.cos(b), 0.058 * math.sin(b), 0),
              rz(45 + 90 * k), parent="Drum")
    s.cyl("Barrel", "gunmetal", 0.042, 0.3, (0, bore_y, -0.29))
    s.cyl("Band", "cobalt", 0.0445, 0.045, (0, bore_y, -0.24))
    s.cyl("MuzzleRing", "steel", 0.047, 0.03, (0, bore_y, -0.43))
    s.cyl("Bore", "bore", 0.031, 0.004, (0, bore_y, -0.4455))
    s.box("ForeGrip", "wood", (0.04, 0.05, 0.13), (0, -0.07, -0.3))
    # Ladder sight: base, two rails leaning back, three rungs.
    s.box("LadderBase", "gunmetal_dark", (0.034, 0.01, 0.03), (0, bore_y + 0.047, -0.16))
    lean = rx(18)
    for i, x in enumerate((-0.013, 0.013)):
        s.box("LadderRail%d" % (i + 1), "gunmetal_dark", (0.004, 0.075, 0.004),
              add((x, bore_y + 0.05, -0.16), apply(lean, (0, 0.037, 0))), lean)
    for i, h in enumerate((0.03, 0.05, 0.072)):
        s.box("LadderRung%d" % (i + 1), "steel", (0.03, 0.004, 0.004),
              add((0, bore_y + 0.05, -0.16), apply(lean, (0, h, 0))), lean)
    s.box("ChargingHandle", "steel", (0.012, 0.022, 0.04), (0.031, -0.01, 0.05))  # cocking lever
    s.box("TriggerGuard", "gunmetal_dark", (0.008, 0.008, 0.07), (0, -0.06, 0.07))
    s.box("Wrist", "wood", (0.04, 0.056, 0.12), (0, -0.024, 0.2))
    s.box("Butt", "wood", (0.046, 0.1, 0.15), (0, -0.04, 0.32))
    s.box("RecoilPad", "gunmetal_dark", (0.05, 0.106, 0.03), (0, -0.04, 0.41))
    s.hands_rifle(left=(-0.005, -0.07, -0.3))
    s.muzzle((0, bore_y, -0.46), energy=3.0, color=(1, 0.6, 0.25), light_range=3.0)
    s.write("scenes/weapons/new_ottoman/humbara_launcher.tscn")


# ---------------------------------------------------------------- the blades
# The longsword's blade frame (tools/melee_weapons): -Z' along the blade, Y' across it (spine
# +Y', edge -Y'), X' the flat. In the side guard +Y' points up and back, so the edge faces the
# enemy. gen_character_anims.py SWORD_TILT holds this frame in third person.
F = matmul(ry(-6.0), rx(50.0))
GUARD_Z = -0.02


def blade_scene(name, root_name):
    s = Scene(root_name, "resources/weapons/new_ottoman/%s.tres" % name,
              "assets/weapons/viewmodel/new_ottoman/%s.tres" % name, (0.3, -0.4, -0.4))
    s.gun = False
    s.impact_kick = 1.6
    return s


def at(local):
    return apply(F, local)


def rot(b):
    return matmul(F, b)


def curved_blade(s, length, segments, bend, width, thick=0.011, mat="blade", prefix="Blade", start=GUARD_Z - 0.015):
    """Blade as short straight segments along a curve. bend(u) is the angle (radians) of the
    blade at u (0 at the hilt, 1 at the tip) toward +Y' (the spine) - negative curves toward
    the edge. width(u) -> (width, offset toward the spine). Returns the tip point and angle."""
    seg = length / segments
    p = (0.0, 0.0, start)
    for k in range(segments):
        u = (k + 0.5) / segments
        a = bend(u)
        d = (0.0, math.sin(a), -math.cos(a))
        w, off = width(u)
        c = add(add(p, mul(d, seg * 0.5)), (0.0, off * math.cos(a), off * math.sin(a)))
        s.box("%s%d" % (prefix, k + 1), mat, (thick, w, seg * 1.12), at(c), rot(rx(math.degrees(a))))
        p = add(p, mul(d, seg))
    return p, bend(1.0)


def hilt_rig(s, grip_mat, grip_len=0.13):
    s.box("Grip", grip_mat, (0.03, 0.034, grip_len), at((0, 0, GUARD_Z + 0.02 + grip_len * 0.5)), rot(I3))
    s.box("RightHand", "skin", (0.05, 0.05, 0.09), at((0, -0.005, GUARD_Z + 0.09)), rot(I3), vm_only=True)


def kilij():
    """Akinji sabre: a kilij. Curved, single-edged, the last third flared into the yelman
    (the widened back edge), crossguard with ball quillons and a langet, a short grip and an
    angled pommel cap."""
    s = blade_scene("kilij", "Kilij")
    length = 0.74

    def width(u):
        if u > 0.66:  # the yelman: widens on the spine side
            return 0.05, 0.007
        return 0.04 - 0.008 * u, 0.0

    tip, a = curved_blade(s, length, 8, lambda u: 0.44 * u * u, width)
    d = (0.0, math.sin(a), -math.cos(a))
    s.box("Tip", "blade", (0.011, 0.034, 0.034), at(add(tip, mul(d, 0.004))), rot(rx(math.degrees(a) + 45)))
    s.box("Fuller", "steel", (0.012, 0.006, 0.36), at((0, 0.006, GUARD_Z - 0.2)), rot(I3))
    s.box("Guard", "gunmetal_worn", (0.024, 0.15, 0.026), at((0, 0, GUARD_Z)), rot(I3))
    for i, y in enumerate((-0.078, 0.078)):
        s.box("Quillon%d" % (i + 1), "gunmetal_worn", (0.03, 0.026, 0.03), at((0, y, GUARD_Z)), rot(I3))
    s.box("Langet", "gunmetal_worn", (0.016, 0.03, 0.05), at((0, 0, GUARD_Z - 0.035)), rot(I3))
    hilt_rig(s, "leather", 0.12)
    s.box("Pommel", "gunmetal_worn", (0.034, 0.05, 0.036), at((0, -0.012, GUARD_Z + 0.165)), rot(rx(-25)))
    s.raw('[node name="Muzzle" type="Marker3D" parent="."]\ntransform = %s' % xf(I3, at(tip)))
    s.write("scenes/weapons/new_ottoman/kilij.tscn")


def yatagan():
    """Janissary vibro-blade: a yatagan. Forward-curved (toward the edge), no guard, a gunmetal
    drive unit on the spine by the hilt with an oxblood hydraulic hose (the hum comes from
    there; it never glows), a steel bolster and a bone hilt flaring into the eared pommel."""
    s = blade_scene("yatagan", "Yatagan")
    length = 0.76
    tip, a = curved_blade(s, length, 8, lambda u: -0.36 * u ** 1.4, lambda u: (0.042 - 0.012 * u, 0.0))
    d = (0.0, math.sin(a), -math.cos(a))
    s.box("Tip", "blade", (0.011, 0.03, 0.03), at(add(tip, mul(d, 0.004))), rot(rx(math.degrees(a) + 45)))
    # Drive unit on the spine by the hilt (follows the curve's first segments).
    hp = (0.0, 0.0, GUARD_Z - 0.015)
    for k in range(2):
        u = (k + 0.5) / 8
        a2 = -0.36 * u ** 1.4
        dd = (0.0, math.sin(a2), -math.cos(a2))
        c = add(add(hp, mul(dd, length / 16)), (0.0, 0.024 * math.cos(a2), 0.024 * math.sin(a2)))
        s.box("Housing%d" % (k + 1), "gunmetal", (0.014, 0.014, length / 8 * 1.1), at(c), rot(rx(math.degrees(a2))))
        hp = add(hp, mul(dd, length / 8))
    s.box("Bolster", "steel", (0.028, 0.052, 0.03), at((0, 0, GUARD_Z)), rot(I3))
    s.cyl("Hose", "hose", 0.006, 0.12, at((0.012, 0.03, GUARD_Z + 0.03)), rot(rx(-80)), sides=6)
    hilt_rig(s, "bone", 0.12)
    s.box("GripBand", "steel", (0.032, 0.036, 0.012), at((0, 0, GUARD_Z + 0.03)), rot(I3))
    for i, sign in enumerate((-1, 1)):
        s.box("Ear%d" % (i + 1), "bone", (0.03, 0.036, 0.05),
              at((0, sign * 0.026, GUARD_Z + 0.17)), rot(rx(sign * 38)))
    s.raw('[node name="Muzzle" type="Marker3D" parent="."]\ntransform = %s' % xf(I3, at(tip)))
    s.write("scenes/weapons/new_ottoman/yatagan.tscn")


# ---------------------------------------------------------------- texture
def grain_texture():
    """512 px tileable grey grain (streaks along one axis plus fine noise), bright (mean ~0.86)
    so it only breaks up the palette colours: wood grain on the stocks, brushing on metal,
    weave on cloth, depending on each material's triplanar scale."""
    from PIL import Image, ImageFilter

    n = 512
    rng = random.Random(1453)
    waves = [(k, rng.uniform(0, 1), rng.uniform(0.3, 1.0) / k ** 0.6, rng.randint(1, 3), rng.uniform(0, 1))
             for k in (3, 5, 8, 13, 21, 34, 55, 89)]
    noise = Image.new("L", (n, n))
    noise.putdata([rng.randint(0, 255) for _ in range(n * n)])
    tiled = Image.new("L", (n * 3, n * 3))
    for i in range(3):
        for j in range(3):
            tiled.paste(noise, (i * n, j * n))
    fine = tiled.filter(ImageFilter.GaussianBlur(1.2)).crop((n, n, 2 * n, 2 * n))
    fpx = fine.load()
    img = Image.new("L", (n, n))
    px = img.load()
    total = sum(w[2] for w in waves)
    for y in range(n):
        for x in range(n):
            v = 0.0
            for k, ph, amp, wob, wph in waves:
                v += amp * math.sin(2 * math.pi * (k * y / n + ph + 0.04 * math.sin(2 * math.pi * (wob * x / n + wph))))
            v = v / total
            g = 0.86 + 0.07 * v + 0.05 * (fpx[x, y] / 255.0 - 0.5)
            px[x, y] = max(0, min(255, int(round(g * 255))))
    path = os.path.join(REPO, GRAIN)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=False)
    print("wrote", GRAIN)


if __name__ == "__main__":
    grain_texture()
    tufek()
    long_rifle()
    glaive_rifle()
    raider_carbine()
    humbara_launcher()
    kilij()
    yatagan()
