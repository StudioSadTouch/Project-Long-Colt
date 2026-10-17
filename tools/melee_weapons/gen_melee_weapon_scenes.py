#!/usr/bin/env python3
"""Generate the longsword and gravity hammer weapon scenes (greybox primitives).

    python3 tools/melee_weapons/gen_melee_weapon_scenes.py

Writes scenes/weapons/longsword.tscn and scenes/weapons/gravity_hammer.tscn. Edit this
script, not the scenes. Same contract as the gun scenes:
  * root Node3D with weapon.gd + its WeaponData; root position = first-person rest pose, root
    rotation zero (gen_viewmodel_anims.py keys rotation from zero)
  * "Grip" mesh = where the hand holds it (CharacterWeaponProps puts that on the third-person
    hand), RightHand / LeftHand are viewmodel_only
  * AnimationPlayer (library from tools/viewmodel_anims/gen_viewmodel_anims.py) and
    ViewmodelMelee: the trigger swings through Weapon.melee(), so the melee clip is the attack.
The hammer is built along a tilted shaft (head up and to the left of the right hand), so the
same tilt reads as "carried across the body" on the third-person prop.
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))


def norm(v):
    n = math.sqrt(sum(x * x for x in v))
    return tuple(x / n for x in v)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def mul(v, k):
    return tuple(x * k for x in v)


def rx(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((1, 0, 0), (0, c, -s), (0, s, c))


def ry(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return ((c, 0, s), (0, 1, 0), (-s, 0, c))


I3 = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


def matmul(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def cols(x, y, z):
    """Basis from column vectors."""
    return tuple((x[i], y[i], z[i]) for i in range(3))


def fnum(x):
    if abs(x) < 1e-7:
        return "0"
    s = "%.6g" % x
    return "0" if s in ("-0",) else s


def xf(basis, origin):
    # .tscn Transform3D(...) lists the basis ROW by row (basis.rows[0..2]), then the origin.
    # (Checked: str_to_var("Transform3D(1, 2, 3, ...)").basis.x is (1, 4, 7).) Matrices here are
    # row-major, so they are written as they are.
    b = basis
    vals = [b[0][0], b[0][1], b[0][2], b[1][0], b[1][1], b[1][2], b[2][0], b[2][1], b[2][2]] + list(origin)
    return "Transform3D(%s)" % ", ".join(fnum(v) for v in vals)


class Scene:
    def __init__(self, root_name, data_id, lib_name, root_pos):
        self.root_name = root_name
        self.data_id = data_id
        self.lib_name = lib_name
        self.root_pos = root_pos
        self.mats = []
        self.meshes = []
        self.nodes = []

    def mat(self, mid, albedo, rough=0.6, metal=0.0, emission=None, energy=1.0):
        lines = ['[sub_resource type="StandardMaterial3D" id="Mat_%s"]' % mid,
                 "albedo_color = Color(%s, 1)" % ", ".join(fnum(c) for c in albedo)]
        if metal:
            lines.append("metallic = %s" % fnum(metal))
        lines.append("roughness = %s" % fnum(rough))
        if emission is not None:
            lines += ["emission_enabled = true", "emission = Color(%s, 1)" % ", ".join(fnum(c) for c in emission),
                      "emission_energy_multiplier = %s" % fnum(energy)]
        self.mats.append("\n".join(lines))

    def box(self, mid, mat, size):
        self.meshes.append('[sub_resource type="BoxMesh" id="Mesh_%s"]\nmaterial = SubResource("Mat_%s")\n'
                           "size = Vector3(%s)" % (mid, mat, ", ".join(fnum(v) for v in size)))

    def cyl(self, mid, mat, radius, height, sides=12):
        self.meshes.append('[sub_resource type="CylinderMesh" id="Mesh_%s"]\nmaterial = SubResource("Mat_%s")\n'
                           "top_radius = %s\nbottom_radius = %s\nheight = %s\nradial_segments = %d"
                           % (mid, mat, fnum(radius), fnum(radius), fnum(height), sides))

    def mesh_node(self, name, mesh, basis, origin, viewmodel_only=False):
        group = ' groups=["viewmodel_only"]' if viewmodel_only else ""
        self.nodes.append('[node name="%s" type="MeshInstance3D" parent="."%s]\ntransform = %s\ncast_shadow = 0\n'
                          'mesh = SubResource("Mesh_%s")' % (name, group, xf(basis, origin), mesh))

    def raw(self, text):
        self.nodes.append(text)

    impact_kick = 1.6

    def write(self, rel, data_path):
        res = ['[ext_resource type="Script" path="res://scripts/weapons/weapon.gd" id="1_weapon"]',
               '[ext_resource type="Resource" path="%s" id="2_data"]' % data_path,
               '[ext_resource type="Script" path="res://scripts/weapons/viewmodel_melee.gd" id="3_melee"]',
               '[ext_resource type="AnimationLibrary" path="res://assets/weapons/viewmodel/%s.tres" id="4_lib"]'
               % self.lib_name]
        subs = self.mats + self.meshes
        out = ["[gd_scene load_steps=%d format=3]" % (len(res) + len(subs) + 1), ""] + res + [""]
        out += ["; GENERATED by tools/melee_weapons/gen_melee_weapon_scenes.py - edit the script, not this file.", ""]
        for s in subs:
            out += [s, ""]
        out += ['[node name="%s" type="Node3D"]' % self.root_name, "transform = %s" % xf(I3, self.root_pos),
                'script = ExtResource("1_weapon")', 'data = ExtResource("2_data")', ""]
        for n in self.nodes:
            out += [n, ""]
        out += ['[node name="AnimationPlayer" type="AnimationPlayer" parent="." groups=["viewmodel_only"]]',
                "libraries = {", '&"": ExtResource("4_lib")', "}", "",
                '[node name="ViewmodelMelee" type="Node" parent="." groups=["viewmodel_only"] '
                'node_paths=PackedStringArray("animation_player")]',
                'script = ExtResource("3_melee")', 'animation_player = NodePath("../AnimationPlayer")',
                "hit_time = 0.1", "impact_kick_deg = %s" % fnum(self.impact_kick), ""]
        path = os.path.join(REPO, rel)
        with open(path, "w") as f:
            f.write("\n".join(out))
        print("wrote", rel)


GRIP_TILT = rx(15.0)  # the gun scenes' Grip / RightHand tilt (0.966, 0.259)


def sword():
    """A cruciform steel longsword: straight double-edged blade with a point, a straight
    crossguard, leather grip and pommel. Built along a blade frame tipped up and in, so it reads
    as held at the ready in first person and on the third-person hand alike."""
    s = Scene("Longsword", "2_data", "longsword", (0.3, -0.4, -0.4))
    s.mat("steel", (0.8, 0.82, 0.86), rough=0.3, metal=0.45)  # bright without reflections
    s.mat("guard", (0.5, 0.47, 0.42), rough=0.4, metal=0.4)
    s.mat("leather", (0.24, 0.15, 0.08), rough=0.85)
    s.mat("skin", (0.72, 0.55, 0.42), rough=0.8)
    # Blade frame: -Z' along the blade - the side guard: 50 deg up, 6 deg out to the right, so
    # first person sees the blade rise at the right of the view. The blade's width is vertical
    # (first person sees its flat). gen_character_anims.py SWORD_TILT must match.
    F = matmul(ry(-6.0), rx(50.0))

    def at(local):
        return tuple(sum(F[r][c] * local[c] for c in range(3)) for r in range(3))

    def rot(B):
        return matmul(F, B)

    blade_len = 0.78
    s.box("blade", "steel", (0.012, 0.05, blade_len))          # width vertical, edges up / down
    s.box("tip", "steel", (0.012, 0.0354, 0.0354))             # a square turned 45 deg: the point
    s.box("guard", "guard", (0.028, 0.24, 0.034))              # the cross, along the edges
    s.box("grip", "leather", (0.032, 0.032, 0.15))
    s.box("pommel", "guard", (0.05, 0.05, 0.045))
    s.box("hand", "skin", (0.05, 0.05, 0.09))
    guard_z = -0.02
    s.mesh_node("Blade", "blade", rot(I3), at((0, 0, guard_z - 0.017 - blade_len * 0.5)))
    s.mesh_node("Tip", "tip", rot(rx(45.0)), at((0, 0, guard_z - 0.017 - blade_len)))
    s.mesh_node("Guard", "guard", rot(I3), at((0, 0, guard_z)))
    s.mesh_node("Grip", "grip", rot(I3), at((0, 0, guard_z + 0.092)))
    s.mesh_node("Pommel", "pommel", rot(I3), at((0, 0, guard_z + 0.19)))
    s.mesh_node("RightHand", "hand", rot(I3), at((0, -0.005, guard_z + 0.09)), viewmodel_only=True)
    s.raw('[node name="Muzzle" type="Marker3D" parent="."]\ntransform = %s'
          % xf(I3, at((0, 0, guard_z - 0.017 - blade_len))))
    s.write("scenes/weapons/longsword.tscn", "res://resources/weapons/longsword.tres")


def hammer():
    s = Scene("GravityHammer", "2_data", "gravity_hammer", (0.3, -0.46, -0.5))
    s.impact_kick = 4.0  # the slam shakes the view
    s.mat("shaft", (0.18, 0.19, 0.21), rough=0.5, metal=0.5)
    s.mat("head", (0.3, 0.28, 0.34), rough=0.45, metal=0.7)
    s.mat("glow", (0.55, 0.75, 1.0), rough=0.3, emission=(0.4, 0.6, 1.0), energy=3.0)
    s.mat("skin", (0.72, 0.55, 0.42), rough=0.8)
    # Shaft frame: Y' up the shaft (up, to the left, a little forward), Z' the striking axis.
    y = norm((-0.12, 0.95, -0.28))
    z = norm(add((0.0, 0.0, 1.0), mul(y, -dot((0.0, 0.0, 1.0), y))))
    x = cross(y, z)
    B = cols(x, y, z)
    grip = (0.0, 0.0, 0.0)

    def at(dist, side=(0.0, 0.0, 0.0)):
        return add(add(grip, mul(y, dist)), add(mul(x, side[0]), mul(z, side[2])))

    s.cyl("shaft", "shaft", 0.02, 0.86)
    s.box("grip", "shaft", (0.042, 0.13, 0.042))
    s.box("head", "head", (0.14, 0.14, 0.3))
    s.box("face", "glow", (0.15, 0.15, 0.022))
    s.box("spike", "head", (0.05, 0.05, 0.13))
    s.cyl("band", "glow", 0.03, 0.035)
    s.box("pommel", "head", (0.06, 0.08, 0.06))
    s.box("hand", "skin", (0.05, 0.05, 0.09))
    s.mesh_node("Shaft", "shaft", B, at(0.26))
    s.mesh_node("Grip", "grip", B, at(0.0))
    s.mesh_node("Pommel", "pommel", B, at(-0.18))
    s.mesh_node("Band", "band", B, at(0.44))
    s.mesh_node("Head", "head", B, at(0.72))
    # Striking face forward (-Z'), a spike out the back.
    s.mesh_node("Face", "face", B, at(0.72, (0, 0, -0.16)))
    s.mesh_node("Spike", "spike", B, at(0.72, (0, 0, 0.21)))
    s.mesh_node("RightHand", "hand", B, at(-0.06), viewmodel_only=True)
    s.mesh_node("LeftHand", "hand", B, at(0.3), viewmodel_only=True)
    s.raw('[node name="Glow" type="OmniLight3D" parent="." groups=["viewmodel_only"]]\n'
          "transform = %s\nlight_color = Color(0.45, 0.65, 1, 1)\nlight_energy = 0.6\nomni_range = 2.0"
          % xf(I3, at(0.72, (0, 0, -0.22))))
    s.raw('[node name="Muzzle" type="Marker3D" parent="."]\ntransform = %s' % xf(I3, at(0.72, (0, 0, -0.17))))
    s.write("scenes/weapons/gravity_hammer.tscn", "res://resources/weapons/gravity_hammer.tres")


if __name__ == "__main__":
    sword()
    hammer()
