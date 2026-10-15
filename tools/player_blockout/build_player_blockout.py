"""Build the Long Colt player block-out (.glb) and preview renders with headless Blender.

Usage (from the repo root):
  blender -b --factory-startup --python tools/player_blockout/build_player_blockout.py -- \
      [--glb assets/models/characters/player_blockout.glb] [--previews /tmp/previews] [--no-render]

All part data below is authored in GODOT space: metres, +Y up, -Z forward, origin at the feet.
g2b() converts to Blender space (+Z up, -Y forward in Godot == +Y in Blender); the glTF
exporter (export_yup) converts back, so the .glb lands in Godot exactly as authored here.

Each PB_ object's origin sits on its joint (rotation and scale are applied, translation is the
pivot), and objects are parented along the joint chain, so the parts can be posed or rigged
later. Top-level groups match dummy_rig.tscn slots: BodyMesh, NeckMesh, HelmetMesh
(origin at the HeadArmored node, y 1.64) and VisorMesh (origin at HeadUnarmored, y 0).
"""
import math
import os
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _arg(name, default):
    return argv[argv.index(name) + 1] if name in argv else default


GLB = _arg("--glb", "assets/models/characters/player_blockout.glb")
PREVIEWS = _arg("--previews", "")
RENDER = "--no-render" not in argv and PREVIEWS != ""


def g2b(v):
    return Vector((v[0], -v[2], v[1]))


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    h = h.lstrip("#")
    return tuple(srgb_to_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


# ---- materials: exactly four, flat matte (Art Director section 5) -------------------------
MATS = {
    "A": ("mat_armor", "#4a5039"),
    "U": ("mat_undersuit", "#2e2f31"),
    "V": ("mat_visor", "#a87a1e"),
    "X": ("mat_accent", "#b3261e"),  # team accent, tinted in Godot via accent_color
}


def make_material(name, hx):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = hexcol(hx)
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    m.diffuse_color = hexcol(hx)
    return m


# ---- geometry builders (Godot-space world coordinates) ------------------------------------
def hexa(b_c, b_w, b_d, t_c, t_w, t_d):
    """Tapered box: bottom face centred at b_c (w x d), top face centred at t_c."""
    vs = []
    for c, w, d in ((b_c, b_w, b_d), (t_c, t_w, t_d)):
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            vs.append((c[0] + sx * w / 2, c[1], c[2] + sz * d / 2))
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return vs, faces


def loft(rings):
    """Stack of rectangular rings (y, cz, w, d), bottom to top, centred on x 0."""
    vs = []
    for y, cz, w, d in rings:
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            vs.append((sx * w / 2, y, cz + sz * d / 2))
    n = len(rings)
    faces = [(0, 3, 2, 1), tuple(4 * (n - 1) + k for k in range(4))]
    for r in range(n - 1):
        a, b = 4 * r, 4 * (r + 1)
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append((a + k, a + k2, b + k2, b + k))
    return vs, faces


def box(c, s):
    return hexa((c[0], c[1] - s[1] / 2, c[2]), s[0], s[2], (c[0], c[1] + s[1] / 2, c[2]), s[0], s[2])


def cyl(b_c, t_c, rx, rz, n=8):
    """Vertical (optionally sheared) elliptical cylinder from b_c to t_c."""
    vs = []
    for c in (b_c, t_c):
        for i in range(n):
            a = 2 * math.pi * (i + 0.5) / n
            vs.append((c[0] + rx * math.cos(a), c[1], c[2] + rz * math.sin(a)))
    faces = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    return vs, faces


def arc_strip(zf, radius, half_deg, y_bot, y_top, thick, segs):
    """Curved strip on a vertical arc: front face at z = zf on the centreline, wrapping back
    around a centre at z = zf + radius; ends turned half_deg from facing -Z. y_bot / y_top
    take u in [-1, 1] (left to right). Thickness runs radially inward."""
    zc = zf + radius
    vs = []
    for i in range(segs + 1):
        u = -1 + 2 * i / segs
        a = math.radians(half_deg) * u
        yb, yt = y_bot(u), y_top(u)
        f = (radius * math.sin(a), zc - radius * math.cos(a))
        k = ((radius - thick) * math.sin(a), zc - (radius - thick) * math.cos(a))
        vs += [(f[0], yb, f[1]), (f[0], yt, f[1]), (k[0], yt, k[1]), (k[0], yb, k[1])]
    faces = []
    for i in range(segs):
        a, b = 4 * i, 4 * (i + 1)
        faces += [(a, b, b + 1, a + 1), (a + 1, b + 1, b + 2, a + 2),
                  (a + 2, b + 2, b + 3, a + 3), (a + 3, b + 3, b, a)]
    last = 4 * segs
    faces += [(3, 2, 1, 0), (last, last + 1, last + 2, last + 3)]
    return vs, faces


def visor():
    """One-piece Mk VI-style visor centred on the eye line (y 1.600 at the centreline): 0.24 wide,
    0.13 tall, ends wrapped back 28 deg onto the helmet's front corners."""
    return arc_strip(-0.185, 0.256, 28.0, lambda u: 1.535 - 0.004 * u * u,
                     lambda u: 1.665 - 0.004 * u * u, 0.025, 8)


def brow():
    """v4 armour brow: a tight, thick ridge (3.5 cm tall, 5.5 cm deep), front at z -0.19 (0.5 cm
    proud of the visor face), laps 1 cm down over the visor top; top at 1.69."""
    return arc_strip(-0.19, 0.27, 30.0, lambda u: 1.655, lambda u: 1.69, 0.055, 6)


# ---- part table ----------------------------------------------------------------------------
# name, material, builder result, pivot (world, Godot), parent name, chamfer (m)
PARTS = []


def part(name, mat, geo, pivot, parent, chamfer=0.0):
    PARTS.append((name, mat, geo, pivot, parent, chamfer))


def empty(name, pos, parent):
    """Pivot, slot group or marker: exported as a plain glTF node (Node3D in Godot)."""
    PARTS.append((name, None, None, pos, parent, 0.0))


def side_parts(s):
    """s = -1 left (character's left is -X when facing -Z), +1 right."""
    L = "L" if s < 0 else "R"
    x = lambda v: s * v  # noqa: E731
    shoulder, elbow, wrist = (x(0.25), 1.36, 0.0), (x(0.275), 1.00, 0.0), (x(0.29), 0.80, 0.0)
    hip, knee, ankle = (x(0.11), 0.88, 0.0), (x(0.11), 0.51, 0.0), (x(0.11), 0.12, 0.0)
    # Arm chain (child of chest). Slight A-pose via offset joint x. Bulk-up v2: heavier
    # gauntlets, bigger rounder pauldrons overhanging the upper arm.
    part(f"PB_UpperArm_{L}", "U", cyl((x(0.265), 0.96, 0), (x(0.258), 1.33, 0), 0.056, 0.056, 8), shoulder, "PB_Chest")
    # v3: full upper-arm plate (0.13 x 0.135) so the arm is no longer the thinnest mass.
    part(f"PB_UpperArmPlate_{L}", "A", hexa((x(0.264), 1.055, 0), 0.13, 0.13, (x(0.26), 1.25, 0), 0.13, 0.135), shoulder, f"PB_UpperArm_{L}", 0.02)
    part(f"PB_Pauldron_{L}", "X" if s < 0 else "A",
         hexa((x(0.24), 1.22, 0), 0.18, 0.23, (x(0.235), 1.46, 0), 0.15, 0.19), shoulder, f"PB_UpperArm_{L}", 0.045)
    part(f"PB_Forearm_{L}", "A", hexa((x(0.275), 0.81, -0.005), 0.14, 0.145, (x(0.27), 0.98, 0), 0.15, 0.15), elbow, f"PB_UpperArm_{L}", 0.02)
    if s < 0:
        part("PB_WristDisplay_L", "U", box((x(0.275), 0.88, -0.085), (0.075, 0.065, 0.025)), elbow, "PB_Forearm_L")
    part(f"PB_Hand_{L}", "U", box((x(0.28), 0.745, -0.005), (0.11, 0.11, 0.115)), wrist, f"PB_Forearm_{L}", 0.012)
    part(f"PB_Thumb_{L}", "U", box((x(0.23), 0.765, -0.052), (0.035, 0.055, 0.04)), wrist, f"PB_Hand_{L}")
    # Leg chain (child of pelvis). Bulk-up v2: thicker thighs and shins.
    part(f"PB_Thigh_{L}", "A", hexa((x(0.11), 0.56, -0.01), 0.16, 0.17, (x(0.11), 0.87, 0.0), 0.18, 0.20), hip, "PB_Pelvis", 0.025)
    part(f"PB_Shin_{L}", "A", hexa((x(0.11), 0.15, 0.0), 0.12, 0.14, (x(0.11), 0.47, -0.005), 0.14, 0.16), knee, f"PB_Thigh_{L}", 0.02)
    part(f"PB_KneeJoint_{L}", "U", cyl((x(0.11), 0.45, 0), (x(0.11), 0.59, 0), 0.06, 0.06, 8), knee, f"PB_Shin_{L}")
    part(f"PB_Knee_{L}", "A", box((x(0.11), 0.51, -0.085), (0.14, 0.10, 0.09)), knee, f"PB_Shin_{L}", 0.018)
    # v3: ankle cuff to 0.17, thicker sole, wider and longer toe: the silhouette ends in weight.
    part(f"PB_Boot_{L}", "A", box((x(0.11), 0.11, -0.015), (0.15, 0.12, 0.23)), ankle, f"PB_Shin_{L}", 0.015)
    part(f"PB_Sole_{L}", "U", box((x(0.11), 0.025, -0.03), (0.16, 0.05, 0.31)), ankle, f"PB_Boot_{L}")
    part(f"PB_Toe_{L}", "A", hexa((x(0.11), 0.05, -0.14), 0.155, 0.09, (x(0.11), 0.12, -0.125), 0.145, 0.04), ankle, f"PB_Boot_{L}", 0.01)


PELVIS, WAIST, CHEST, NECK = (0, 0.93, 0), (0, 1.00, 0), (0, 1.12, 0), (0, 1.47, 0)
# BodyMesh: pelvis is the root of the body chain.
part("PB_Pelvis", "U", hexa((0, 0.87, 0.0), 0.41, 0.25, (0, 1.00, 0.0), 0.39, 0.24), PELVIS, "BodyMesh")
part("PB_Codpiece", "A", hexa((0, 0.80, -0.115), 0.11, 0.04, (0, 0.92, -0.125), 0.20, 0.05), PELVIS, "PB_Pelvis")
part("PB_ButtPlate", "A", hexa((0, 0.82, 0.12), 0.20, 0.04, (0, 0.93, 0.125), 0.28, 0.05), PELVIS, "PB_Pelvis")
part("PB_Pouch_L", "U", box((-0.15, 0.925, -0.14), (0.09, 0.10, 0.06)), PELVIS, "PB_Pelvis", 0.01)
part("PB_Pouch_R", "U", box((0.15, 0.925, -0.14), (0.09, 0.10, 0.06)), PELVIS, "PB_Pelvis", 0.01)
part("PB_Knife_R", "U", box((0.212, 0.86, 0.03), (0.03, 0.16, 0.05)), PELVIS, "PB_Pelvis")
part("PB_Abdomen", "U", cyl((0, 0.97, 0), (0, 1.14, 0), 0.16, 0.11, 10), WAIST, "PB_Pelvis")
# Ab plate: covers the front of the abdomen gap; the sides stay dark so the waist still reads.
part("PB_AbPlate", "A", hexa((0, 0.985, -0.115), 0.20, 0.04, (0, 1.13, -0.13), 0.26, 0.04), WAIST, "PB_Abdomen", 0.01)
# Chest: deeper plate, forward slope at the pecs (front peaks at y 1.31), back under the pack.
part("PB_Chest", "A", loft([(1.12, -0.02, 0.40, 0.24), (1.31, -0.035, 0.46, 0.33), (1.40, -0.02, 0.44, 0.27)]),
     CHEST, "PB_Abdomen", 0.02)
part("PB_Collar", "A", cyl((0, 1.38, -0.02), (0, 1.46, -0.02), 0.16, 0.14, 10), CHEST, "PB_Chest")
part("PB_Pack", "A", box((0, 1.23, 0.155), (0.30, 0.30, 0.09)), CHEST, "PB_Chest", 0.02)
part("PB_Antenna", "U", box((-0.10, 1.45, 0.17), (0.02, 0.14, 0.02)), CHEST, "PB_Chest")
side_parts(-1)
side_parts(1)
# Third-person markers (v4): -Z along the barrel / forward, +Y up, at the fist centre.
empty("WeaponAttach_R", (0.28, 0.745, -0.01), "PB_Hand_R")
empty("OffHand_L", (-0.28, 0.745, -0.01), "PB_Hand_L")
# v4 head chain: PB_Chest > PB_Neck (neck base, y 1.49) > PB_Head (skull base, y 1.54).
# The dummy_rig slot groups keep their names and global transforms but now nest in the chain.
NECK_BASE, HEAD = (0, 1.49, 0), (0, 1.54, 0)
empty("PB_Neck", NECK_BASE, "PB_Chest")
empty("NeckMesh", (0, 0, 0), "PB_Neck")
part("PB_NeckCore", "U", cyl((0, 1.40, 0), (0, 1.54, 0), 0.075, 0.075, 10), NECK_BASE, "NeckMesh")
# Neck seal: a fat undersuit ring between collar and helmet so no thin stalk reads.
part("PB_NeckSeal", "U", cyl((0, 1.44, -0.005), (0, 1.495, -0.005), 0.11, 0.10, 10), NECK_BASE, "NeckMesh")
empty("PB_Head", HEAD, "PB_Neck")
empty("HelmetMesh", (0, 1.64, 0), "PB_Head")
# v4: shell front pulled back to z -0.155 (depth 0.29) so the visor, now proud to -0.185, wraps
# its ends over the shell instead of the shell's face showing through them.
part("PB_Helmet", "A", box((0, 1.66, -0.01), (0.28, 0.30, 0.29)), HEAD, "HelmetMesh", 0.05)
# Mk VI read: brow ridge over the visor, jaw/cheek mass below it, comms blocks low.
part("PB_HelmetBrow", "A", brow(), HEAD, "PB_Helmet")
part("PB_HelmetJaw", "A", hexa((0, 1.48, -0.10), 0.17, 0.16, (0, 1.54, -0.105), 0.25, 0.17), HEAD, "PB_Helmet", 0.015)
part("PB_HelmetEar_L", "A", box((-0.15, 1.555, 0.01), (0.04, 0.09, 0.12)), HEAD, "PB_Helmet", 0.01)
part("PB_HelmetEar_R", "A", box((0.15, 1.555, 0.01), (0.04, 0.09, 0.12)), HEAD, "PB_Helmet", 0.01)
part("PB_HelmetSensor_R", "U", box((0.155, 1.72, -0.03), (0.03, 0.04, 0.10)), HEAD, "PB_Helmet")
part("PB_HelmetStripe_L", "X", box((-0.142, 1.70, -0.02), (0.01, 0.03, 0.22)), HEAD, "PB_Helmet")
part("PB_HelmetFlap", "A", hexa((0, 1.49, 0.13), 0.16, 0.03, (0, 1.56, 0.12), 0.20, 0.04), HEAD, "PB_Helmet")
empty("VisorMesh", (0, 0, 0), "PB_Head")
part("PB_Visor", "V", visor(), HEAD, "VisorMesh")

GROUPS = {"BodyMesh": (0, 0, 0)}

# ---- build ----------------------------------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
mats = {k: make_material(n, h) for k, (n, h) in MATS.items()}
model_col = bpy.data.collections.new("PlayerBlockout")
scene.collection.children.link(model_col)

objs, world_pivot = {}, {}
for gname, gpos in GROUPS.items():
    e = bpy.data.objects.new(gname, None)
    e.empty_display_size = 0.05
    e.location = g2b(gpos)
    model_col.objects.link(e)
    objs[gname], world_pivot[gname] = e, gpos

for name, mk, geo, pivot, parent, chamfer in PARTS:
    if geo is None:
        e = bpy.data.objects.new(name, None)
        e.empty_display_size = 0.03
        model_col.objects.link(e)
        e.parent = objs[parent]
        e.location = g2b(Vector(pivot) - Vector(world_pivot[parent]))
        objs[name], world_pivot[name] = e, pivot
        continue
    vs, faces = geo
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bverts = [bm.verts.new(g2b(Vector(v) - Vector(pivot))) for v in vs]
    for f in faces:
        bm.faces.new([bverts[i] for i in f])
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if chamfer > 0:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=chamfer, segments=1, affect="EDGES",
                        clamp_overlap=True, profile=0.5)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mats[mk])
    ob = bpy.data.objects.new(name, me)
    model_col.objects.link(ob)
    ob.parent = objs[parent]
    ob.location = g2b(Vector(pivot) - Vector(world_pivot[parent]))
    objs[name], world_pivot[name] = ob, pivot
    # Flat shading: the block-out reads as planes.
    for p in me.polygons:
        p.use_smooth = False

bpy.context.view_layer.update()

# ---- stats & checks ---------------------------------------------------------------------------
def world_verts(ob):
    return [ob.matrix_world @ v.co for v in ob.data.vertices]


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


mesh_objs = [o for o in model_col.objects if o.type == "MESH"]
helmet_objs = [o for o in mesh_objs if o.name.startswith("PB_Helmet") or o.name == "PB_Visor"]
allv = [v for o in mesh_objs for v in world_verts(o)]
# back to Godot space: x, y=bz, z=-by
gv = [(v.x, v.z, -v.y) for v in allv]
print("STAT primitives", len(mesh_objs))
print("STAT tris_total", sum(tri_count(o) for o in mesh_objs))
print("STAT tris_helmet_incl_visor", sum(tri_count(o) for o in helmet_objs))
print("STAT bbox_x %.3f %.3f" % (min(p[0] for p in gv), max(p[0] for p in gv)))
print("STAT bbox_y %.3f %.3f" % (min(p[1] for p in gv), max(p[1] for p in gv)))
print("STAT bbox_z %.3f %.3f (-Z forward)" % (min(p[2] for p in gv), max(p[2] for p in gv)))
for o in mesh_objs:
    w = [(v.x, v.z, -v.y) for v in world_verts(o)]
    out = []
    for x, y, z in w:
        r = math.hypot(x, z)
        if 0.35 <= y <= 1.45:
            d = r - 0.35
        else:
            cy = 0.35 if y < 0.35 else 1.45
            d = math.sqrt(r * r + (y - cy) ** 2) - 0.35
        out.append(d)
    if max(out) > 0.002:
        print("CAPSULE_OUT %-22s %.3f m" % (o.name, max(out)))
for o in helmet_objs:
    w = [(v.x, v.z, -v.y) for v in world_verts(o)]
    print("HEAD %-20s x[%.3f,%.3f] y[%.3f,%.3f] z[%.3f,%.3f]" % (
        o.name, min(p[0] for p in w), max(p[0] for p in w), min(p[1] for p in w),
        max(p[1] for p in w), min(p[2] for p in w), max(p[2] for p in w)))
mats_used = sorted({o.data.materials[0].name for o in mesh_objs})
print("STAT materials", mats_used)
for o in mesh_objs:
    print("PART %-20s %-14s parent=%s" % (o.name, o.data.materials[0].name, o.parent.name))

def print_tree(ob, depth=0):
    gp = ob.matrix_world.translation
    kind = "mesh" if ob.type == "MESH" else "node"
    print("TREE " + "  " * depth + "%s [%s] pivot(%.3f, %.3f, %.3f)" % (ob.name, kind, gp.x, gp.z, -gp.y))
    for c in sorted(ob.children, key=lambda o: o.name):
        print_tree(c, depth + 1)


for root in [o for o in model_col.objects if o.parent is None]:
    print_tree(root)

# ---- export ---------------------------------------------------------------------------------
os.makedirs(os.path.dirname(os.path.abspath(GLB)), exist_ok=True)
for o in bpy.data.objects:
    o.select_set(False)
bpy.ops.export_scene.gltf(filepath=os.path.abspath(GLB), export_format="GLB", export_yup=True,
                          export_apply=True, export_cameras=False, export_lights=False,
                          export_materials="EXPORT", export_extras=False, export_normals=True,
                          export_texcoords=True, use_selection=False)
print("EXPORTED", os.path.abspath(GLB))

if not RENDER:
    sys.exit(0)

# ---- preview renders ----------------------------------------------------------------------------
os.makedirs(PREVIEWS, exist_ok=True)
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 24
scene.cycles.use_denoising = False
scene.render.film_transparent = False
scene.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("W")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.21, 0.21, 0.21, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
scene.world = world

sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy = 3.5
sun.rotation_euler = (math.radians(50), 0, math.radians(-35))
scene.collection.objects.link(sun)
fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
fill.data.energy = 1.2
fill.rotation_euler = (math.radians(70), 0, math.radians(150))
scene.collection.objects.link(fill)

cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
scene.collection.objects.link(cam)
scene.camera = cam


def aim(pos_g, target_g=(0, 0.92, 0), ortho=True, scale=2.05):
    cam.location = g2b(pos_g)
    d = g2b(target_g) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO" if ortho else "PERSP"
    cam.data.ortho_scale = scale
    cam.data.lens = 70
    cam.data.clip_end = 100


VIEWS = {
    "front": ((0, 0.92, -6), True),
    "side": ((6, 0.92, 0), True),          # character's right side
    "back": ((0, 0.92, 6), True),
    "three_quarter": ((3.4, 1.55, -4.2), False),        # front-right
    "three_quarter_left": ((-3.4, 1.55, -4.2), False),  # front-left (accent pauldron)
}


def render(path, w=800, h=1000):
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def set_view(v):
    pos, ortho = VIEWS[v]
    aim(pos, ortho=ortho, scale=2.05 if ortho else 1.0)


for v in VIEWS:
    set_view(v)
    render(os.path.join(PREVIEWS, f"player_blockout_{v}.png"))

# ---- overlay: capsule + hitboxes as wireframes, model semi-transparent ------------------------
def emit_mat(name, rgb):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs[0].default_value = rgb + (1,)
    em.inputs[1].default_value = 3.0
    nt.links.new(em.outputs[0], out.inputs[0])
    return m


overlay_col = bpy.data.collections.new("Overlay")
scene.collection.children.link(overlay_col)


def wire_obj(name, vs, faces, mat, thick=0.006):
    me = bpy.data.meshes.new(name)
    me.from_pydata([g2b(v) for v in vs], [], faces)
    ob = bpy.data.objects.new(name, me)
    overlay_col.objects.link(ob)
    me.materials.append(mat)
    mod = ob.modifiers.new("w", "WIREFRAME")
    mod.thickness = thick
    mod.use_replace = True
    return ob


def capsule_geo(r, h, cy, seg=16, rings=4):
    vs, faces = [], []
    half = h / 2 - r
    rows = []
    for k in range(-rings, rings + 1):
        a = (math.pi / 2) * k / rings
        y = cy + (half if k >= 0 else -half) + r * math.sin(a)
        rows.append((y, r * math.cos(a)))
        if k == 0:
            rows.insert(len(rows) - 1, (cy - half, r))
    for y, rr in rows:
        for i in range(seg):
            a = 2 * math.pi * i / seg
            vs.append((rr * math.cos(a), y, rr * math.sin(a)))
    for j in range(len(rows) - 1):
        for i in range(seg):
            a, b = j * seg + i, j * seg + (i + 1) % seg
            faces.append((a, b, b + seg, a + seg))
    return vs, faces


def hit_boxes(drop=0.0, hurt_h=1.4):
    out = []
    out.append(("Hurtbox", box((0, hurt_h / 2, 0), (0.7, hurt_h, 0.4)), (0.1, 0.9, 0.2)))
    out.append(("Helmet_hitbox", box((0, 1.64 - drop, 0), (0.36, 0.34, 0.36)), (1.0, 0.15, 0.1)))
    out.append(("Visor_hitbox", box((0, 1.60 - drop, -0.2), (0.24, 0.14, 0.04)), (1.0, 0.9, 0.1)))
    out.append(("Neck_hitbox", box((0, 1.435 - drop, 0), (0.16, 0.07, 0.16)), (1.0, 0.5, 0.0)))
    return out


def build_overlay(drop=0.0, cap_h=1.8, hurt_h=1.4):
    for o in list(overlay_col.objects):
        bpy.data.objects.remove(o)
    cv, cf = capsule_geo(0.35, cap_h, cap_h / 2)
    wire_obj("Capsule", cv, cf, emit_mat("cyan", (0.1, 0.8, 1.0)), 0.004)
    for n, (vs, fs), rgb in hit_boxes(drop, hurt_h):
        wire_obj(n, vs, fs, emit_mat(n, rgb), 0.006)


def model_alpha(alpha):
    for m in mats.values():
        bsdf = m.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Alpha"].default_value = alpha


build_overlay()
model_alpha(0.45)
for v in ("front", "side", "three_quarter"):
    set_view(v)
    render(os.path.join(PREVIEWS, f"player_blockout_{v}_hitbox_overlay.png"))
model_alpha(1.0)

# ---- squint test: flat black silhouettes on mid-grey --------------------------------------------
for o in list(overlay_col.objects):
    bpy.data.objects.remove(o)
black = emit_mat("black", (0.0, 0.0, 0.0))
black.node_tree.nodes["Emission"].inputs[1].default_value = 0.0
saved = {o.name: o.data.materials[0] for o in mesh_objs}
for o in mesh_objs:
    o.data.materials[0] = black
world.node_tree.nodes["Background"].inputs[0].default_value = (0.215, 0.215, 0.215, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
scene.cycles.samples = 8
for v in ("front", "side", "back", "three_quarter"):
    set_view(v)
    render(os.path.join(PREVIEWS, f"silhouette_{v}.png"), 400, 500)
for o in mesh_objs:
    o.data.materials[0] = saved[o.name]
world.node_tree.nodes["Background"].inputs[0].default_value = (0.21, 0.21, 0.21, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
scene.cycles.samples = 24

# ---- crouch clip check: pelvis 0.62, visor centre (eye) 0.95 (preview only, not exported) ----
from mathutils.bvhtree import BVHTree  # noqa: E402

L1, L2 = 0.37, 0.39  # hip->knee, knee->ankle
PELVIS_Y, EYE_Y, FACE_Z = 0.62, 0.95, -0.19
DROP = 1.62 - EYE_Y  # player.gd lowers the Rig by STAND_EYE - eye
HURT_H = max(1.4 - DROP, 0.7)
CAP_H = 1.15


def visor_centre():
    w = world_verts(objs["PB_Visor"])
    c = sum(w, Vector()) / len(w)
    return Vector((c.x, c.z, -c.y))  # Godot space


def gverts(ob):
    return [Vector((v.x, v.z, -v.y)) for v in world_verts(ob)]


def penetrations():
    """Pairs of meshes that intersect, with the max depth of either's vertices inside the other
    (closest-point + normal test; exact for the convex parts, approximate for the arcs)."""
    dg = bpy.context.evaluated_depsgraph_get()
    trees = {}
    for o in mesh_objs:
        bm = bmesh.new()
        bm.from_mesh(o.data)
        bm.transform(o.matrix_world)
        trees[o.name] = (BVHTree.FromBMesh(bm), [v.co.copy() for v in bm.verts])
        bm.free()
    out = {}
    names = [o.name for o in mesh_objs]
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            ta, va = trees[a]
            tb, vb = trees[b]
            if not ta.overlap(tb):
                continue
            depth = 0.0
            for src, tgt in ((va, tb), (vb, ta)):
                for v in src:
                    loc, nrm, _idx, dist = tgt.find_nearest(v)
                    if loc is not None and (v - loc).dot(nrm) < 0:
                        depth = max(depth, dist)
            out[(a, b)] = depth
    return out


rest_pen = penetrations()

# 1. pelvis down to 0.62
objs["PB_Pelvis"].location.z += PELVIS_Y - 0.93
bpy.context.view_layer.update()


def set_lean(lean):
    objs["PB_Abdomen"].rotation_euler.x = lean * 0.5
    objs["PB_Chest"].rotation_euler.x = lean * 0.5
    objs["PB_Neck"].rotation_euler.x = -lean * 0.5   # keep the head level
    objs["PB_Head"].rotation_euler.x = -lean * 0.5
    bpy.context.view_layer.update()


# 2. bisection on the spine lean so the visor centre lands on the eye height
lo, hi = math.radians(-89), 0.0
for _ in range(40):
    mid = (lo + hi) / 2
    set_lean(mid)
    if visor_centre().y > EYE_Y:
        hi = mid
    else:
        lo = mid
LEAN = (lo + hi) / 2
set_lean(LEAN)
# 3. slide the body back so the face is over the feet / inside the lowered head hitbox
vc = visor_centre()
objs["PB_Pelvis"].location += g2b((0, 0, FACE_Z - vc.z))
bpy.context.view_layer.update()
pw = objs["PB_Pelvis"].matrix_world.translation
hip_y, hip_z = pw.z - 0.05, -pw.y
# 4. two-bone leg IK, knees forward, ankles at y 0.12 under the body centre, feet flat
ankle_y, ankle_z = 0.12, 0.0
dy, dz = hip_y - ankle_y, hip_z - ankle_z
D = min(math.hypot(dy, dz), L1 + L2 - 1e-4)
phi = math.atan2(dz, dy)  # >0 when the ankle is forward (-Z) of the hip
alpha = math.acos((L1 * L1 + D * D - L2 * L2) / (2 * L1 * D))
t1 = phi + alpha
ky, kz = hip_y - L1 * math.cos(t1), hip_z - L1 * math.sin(t1)
t2 = math.atan2(kz - ankle_z, ky - ankle_y)
for sd in ("L", "R"):
    objs[f"PB_Thigh_{sd}"].rotation_euler.x = t1
    objs[f"PB_Shin_{sd}"].rotation_euler.x = t2 - t1
    objs[f"PB_Boot_{sd}"].rotation_euler.x = -t2
    objs[f"PB_UpperArm_{sd}"].rotation_euler.x = math.radians(35)
    objs[f"PB_Forearm_{sd}"].rotation_euler.x = math.radians(45)
bpy.context.view_layer.update()

vc = visor_centre()
soles = min(v.y for sd in ("L", "R") for v in gverts(objs[f"PB_Sole_{sd}"]))
print("CROUCH pelvis y %.3f, spine lean %.1f deg (abdomen + chest halves), head counter %.1f deg, "
      "hip (%.3f, %.3f), thigh %.1f deg, shin %.1f deg (from vertical), visor centre y %.3f z %.3f, "
      "sole min y %.3f" % (objs["PB_Pelvis"].matrix_world.translation.z, math.degrees(LEAN),
                           -math.degrees(LEAN), hip_y, hip_z, math.degrees(t1), math.degrees(t2),
                           vc.y, vc.z, soles))

# capsule (crouched) and lowered hitboxes
for o in mesh_objs:
    worst = 0.0
    for v in gverts(o):
        r = math.hypot(v.x, v.z)
        lo_c, hi_c = 0.35, CAP_H - 0.35
        if lo_c <= v.y <= hi_c:
            d = r - 0.35
        else:
            cy = lo_c if v.y < lo_c else hi_c
            d = math.sqrt(r * r + (v.y - cy) ** 2) - 0.35
        worst = max(worst, d)
    if worst > 0.005:
        print("CROUCH_CAPSULE_OUT %-22s %.3f m" % (o.name, worst))


def out_of_box(o, c, size):
    worst = 0.0
    for v in gverts(o):
        for k in range(3):
            worst = max(worst, abs(v[k] - c[k]) - size[k] / 2)
    return worst


helm_c, helm_s = (0, 1.64 - DROP, 0), (0.36, 0.34, 0.36)
for o in helmet_objs:
    print("CROUCH_HEAD %-20s outside lowered helmet hitbox by %.3f m" % (o.name, max(0, out_of_box(o, helm_c, helm_s))))
print("CROUCH_VISOR outside lowered visor hitbox by %.3f m" % max(0, out_of_box(objs["PB_Visor"], (0, 1.60 - DROP, -0.2), (0.24, 0.14, 0.04))))
body_out = []
for o in mesh_objs:
    if o in helmet_objs:
        continue
    d = out_of_box(o, (0, HURT_H / 2, 0), (0.7, HURT_H, 0.4))
    if d > 0.005:
        body_out.append((o.name, d))
for n, d in sorted(body_out, key=lambda t: -t[1]):
    print("CROUCH_HURTBOX_OUT %-22s %.3f m (hurtbox %.2f tall)" % (n, d, HURT_H))

crouch_pen = penetrations()
for (a, b), d in sorted(crouch_pen.items(), key=lambda t: -t[1]):
    base = rest_pen.get((a, b), 0.0)
    if d > 0.01 and d > base + 0.005:
        print("CROUCH_CLIP %-20s x %-20s %.3f m (rest %.3f)" % (a, b, d, base))

build_overlay(drop=DROP, cap_h=CAP_H, hurt_h=HURT_H)
model_alpha(0.45)
for v in ("side", "three_quarter"):
    set_view(v)
    render(os.path.join(PREVIEWS, f"player_blockout_crouch_{v}_overlay.png"))
model_alpha(1.0)
