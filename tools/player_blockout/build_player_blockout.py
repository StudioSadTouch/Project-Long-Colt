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


def visor():
    """One-piece Mk VI-style wrap visor: wide and short, bottom edge dipping toward the cheeks."""
    cols = 7
    hw = 0.12
    vs = []
    for i in range(cols):
        x = -hw + 2 * hw * i / (cols - 1)
        t = (x / hw) ** 2
        zf = -0.20 + 2.0 * x * x          # wraps back ~3 cm at the edges
        zb = zf + 0.025
        top = 1.672 - 0.012 * t
        bot = 1.535 - 0.015 * t
        vs += [(x, bot, zf), (x, top, zf), (x, top, zb), (x, bot, zb)]
    faces = []
    for i in range(cols - 1):
        a, b = 4 * i, 4 * (i + 1)
        faces += [(a, b, b + 1, a + 1),          # front
                  (a + 1, b + 1, b + 2, a + 2),  # top
                  (a + 2, b + 2, b + 3, a + 3),  # back
                  (a + 3, b + 3, b, a)]          # bottom
    last = 4 * (cols - 1)
    faces += [(0, 1, 2, 3)[::-1], (last, last + 1, last + 2, last + 3)]
    return vs, faces


# ---- part table ----------------------------------------------------------------------------
# name, material, builder result, pivot (world, Godot), parent name, chamfer (m)
PARTS = []


def part(name, mat, geo, pivot, parent, chamfer=0.0):
    PARTS.append((name, mat, geo, pivot, parent, chamfer))


def side_parts(s):
    """s = -1 left (character's left is -X when facing -Z), +1 right."""
    L = "L" if s < 0 else "R"
    x = lambda v: s * v  # noqa: E731
    shoulder, elbow, wrist = (x(0.25), 1.36, 0.0), (x(0.275), 1.00, 0.0), (x(0.29), 0.80, 0.0)
    hip, knee, ankle = (x(0.11), 0.88, 0.0), (x(0.11), 0.51, 0.0), (x(0.11), 0.12, 0.0)
    # Arm chain (child of chest). Slight A-pose via offset joint x. Bulk-up v2: heavier
    # gauntlets, bigger rounder pauldrons overhanging the upper arm.
    part(f"PB_UpperArm_{L}", "U", cyl((x(0.265), 0.96, 0), (x(0.255), 1.33, 0), 0.052, 0.052, 8), shoulder, "PB_Chest")
    part(f"PB_Bicep_{L}", "A", hexa((x(0.292), 1.06, 0), 0.03, 0.10, (x(0.285), 1.24, 0), 0.03, 0.11), shoulder, f"PB_UpperArm_{L}")
    part(f"PB_Pauldron_{L}", "X" if s < 0 else "A",
         hexa((x(0.24), 1.27, 0), 0.18, 0.23, (x(0.235), 1.46, 0), 0.15, 0.19), shoulder, f"PB_UpperArm_{L}", 0.045)
    part(f"PB_Forearm_{L}", "A", hexa((x(0.275), 0.81, -0.005), 0.14, 0.145, (x(0.27), 0.98, 0), 0.15, 0.15), elbow, f"PB_UpperArm_{L}", 0.02)
    if s < 0:
        part("PB_WristDisplay_L", "U", box((x(0.275), 0.88, -0.085), (0.075, 0.065, 0.025)), elbow, "PB_Forearm_L")
    part(f"PB_Hand_{L}", "U", box((x(0.28), 0.745, -0.005), (0.10, 0.10, 0.11)), wrist, f"PB_Forearm_{L}", 0.012)
    part(f"PB_Thumb_{L}", "U", box((x(0.235), 0.765, -0.05), (0.035, 0.055, 0.04)), wrist, f"PB_Hand_{L}")
    # Leg chain (child of pelvis). Bulk-up v2: thicker thighs and shins.
    part(f"PB_Thigh_{L}", "A", hexa((x(0.11), 0.56, -0.01), 0.16, 0.17, (x(0.11), 0.87, 0.0), 0.18, 0.20), hip, "PB_Pelvis", 0.025)
    part(f"PB_Shin_{L}", "A", hexa((x(0.11), 0.15, 0.0), 0.12, 0.14, (x(0.11), 0.47, -0.005), 0.14, 0.16), knee, f"PB_Thigh_{L}", 0.02)
    part(f"PB_KneeJoint_{L}", "U", cyl((x(0.11), 0.45, 0), (x(0.11), 0.59, 0), 0.06, 0.06, 8), knee, f"PB_Shin_{L}")
    part(f"PB_Knee_{L}", "A", box((x(0.11), 0.51, -0.085), (0.14, 0.10, 0.09)), knee, f"PB_Shin_{L}", 0.018)
    part(f"PB_Boot_{L}", "A", box((x(0.11), 0.09, -0.02), (0.14, 0.10, 0.23)), ankle, f"PB_Shin_{L}", 0.015)
    part(f"PB_Sole_{L}", "U", box((x(0.11), 0.02, -0.03), (0.15, 0.04, 0.29)), ankle, f"PB_Boot_{L}")
    part(f"PB_Toe_{L}", "A", hexa((x(0.11), 0.04, -0.13), 0.14, 0.07, (x(0.11), 0.10, -0.115), 0.13, 0.03), ankle, f"PB_Boot_{L}")


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
# NeckMesh
part("PB_Neck", "U", cyl((0, 1.40, 0), (0, 1.54, 0), 0.075, 0.075, 10), NECK, "NeckMesh")
# Neck seal: a fat undersuit ring between collar and helmet so no thin stalk reads.
part("PB_NeckSeal", "U", cyl((0, 1.44, -0.005), (0, 1.495, -0.005), 0.11, 0.10, 10), NECK, "PB_Neck")
# HelmetMesh: every helmet piece is a child of PB_Helmet, which pivots at the neck joint.
part("PB_Helmet", "A", box((0, 1.665, -0.02), (0.28, 0.29, 0.31)), NECK, "HelmetMesh", 0.05)
part("PB_HelmetChin", "A", hexa((0, 1.51, -0.13), 0.14, 0.08, (0, 1.545, -0.15), 0.20, 0.07), NECK, "PB_Helmet")
part("PB_HelmetEar_L", "A", box((-0.15, 1.62, 0.0), (0.04, 0.10, 0.12)), NECK, "PB_Helmet", 0.01)
part("PB_HelmetEar_R", "A", box((0.15, 1.62, 0.0), (0.04, 0.10, 0.12)), NECK, "PB_Helmet", 0.01)
part("PB_HelmetSensor_R", "U", box((0.155, 1.72, -0.03), (0.03, 0.04, 0.10)), NECK, "PB_Helmet")
part("PB_HelmetStripe_L", "X", box((-0.142, 1.70, -0.02), (0.01, 0.03, 0.22)), NECK, "PB_Helmet")
part("PB_HelmetFlap", "A", hexa((0, 1.49, 0.13), 0.16, 0.03, (0, 1.56, 0.12), 0.20, 0.04), NECK, "PB_Helmet")
# VisorMesh: pivots at the same neck joint as PB_Helmet, so posing both identically keeps them seated.
part("PB_Visor", "V", visor(), NECK, "VisorMesh")

GROUPS = {"BodyMesh": (0, 0, 0), "NeckMesh": (0, 0, 0), "HelmetMesh": (0, 1.64, 0), "VisorMesh": (0, 0, 0)}

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

for name, mk, (vs, faces), pivot, parent, chamfer in PARTS:
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

# ---- simple crouch pose at eye 0.95 (preview only, not exported) ---------------------------------
L1, L2 = 0.37, 0.39  # hip->knee, knee->ankle
for g in ("NeckMesh", "HelmetMesh", "VisorMesh"):
    ob = objs[g]
    mw = ob.matrix_world.copy()
    ob.parent = objs["PB_Chest"]
    ob.matrix_parent_inverse = objs["PB_Chest"].matrix_world.inverted()
    ob.matrix_world = mw
LEAN = math.radians(-25)
objs["PB_Abdomen"].rotation_euler.x = LEAN
# Neck counter-rotation keeps the head level (helmet and visor share the neck pivot).
objs["PB_Helmet"].rotation_euler.x = -LEAN
objs["PB_Visor"].rotation_euler.x = -LEAN
bpy.context.view_layer.update()


def visor_centre():
    w = world_verts(objs["PB_Visor"])
    c = sum(w, Vector()) / len(w)
    return Vector((c.x, c.z, -c.y))  # Godot space


# Iterate: pose legs for the current pelvis, then move the pelvis so the visor sits at eye 0.95
# with the face over the feet (the lowered head hitboxes only move straight down).
for _ in range(6):
    bpy.context.view_layer.update()
    vc = visor_centre()
    objs["PB_Pelvis"].location += g2b((0, 0.95 - vc.y, -0.19 - vc.z))
    bpy.context.view_layer.update()
    pw = objs["PB_Pelvis"].matrix_world.translation
    hip_y, hip_z = pw.z - 0.05, -pw.y
    best = None
    for i in range(300, 1000):
        t1 = math.radians(i / 10.0)
        c2 = (hip_y - 0.12 - L1 * math.cos(t1)) / L2
        if abs(c2) > 1:
            continue
        t2 = math.acos(c2)
        az = hip_z - L1 * math.sin(t1) + L2 * math.sin(t2)
        err = abs(az - (hip_z - 0.12))  # feet a little ahead of the hips
        if best is None or err < best[3]:
            best = (t1, t2, az, err)
    t1, t2, az, _e = best
    for s in ("L", "R"):
        objs[f"PB_Thigh_{s}"].rotation_euler.x = t1
        objs[f"PB_Shin_{s}"].rotation_euler.x = -t2 - t1
        objs[f"PB_Boot_{s}"].rotation_euler.x = t2
        objs[f"PB_UpperArm_{s}"].rotation_euler.x = math.radians(35)
        objs[f"PB_Forearm_{s}"].rotation_euler.x = math.radians(45)
bpy.context.view_layer.update()
vc = visor_centre()
soles = [(o.matrix_world @ v.co).z for s in ("L", "R") for o in (objs[f"PB_Sole_{s}"],) for v in o.data.vertices]
print("CROUCH lean %.0f deg, hip y %.3f z %.3f, thigh %.1f deg, shin %.1f deg, ankle z %.3f, visor y %.3f z %.3f, sole min y %.3f" % (
    math.degrees(LEAN), hip_y, hip_z, math.degrees(t1), -math.degrees(t2), az, vc.y, vc.z, min(soles)))
drop = 1.62 - 0.95
build_overlay(drop=drop, cap_h=1.15, hurt_h=max(1.4 - drop, 0.7))
model_alpha(0.45)
for v in ("side", "three_quarter"):
    set_view(v)
    render(os.path.join(PREVIEWS, f"player_blockout_crouch_{v}_overlay.png"))
model_alpha(1.0)
