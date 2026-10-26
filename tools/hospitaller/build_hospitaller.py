"""Build the Hospitaller player model (skinned undersuit + modular armour) with headless Blender.

Usage (from the repo root; Blender's bundled Python needs numpy for the glTF exporter):
  PYTHONPATH=~/.cache/claude-longcolt/pylibs blender -b --factory-startup \
      --python tools/hospitaller/build_hospitaller.py -- \
      --proto /mnt/drive3/Modeling/project-long-colt/Hospitaller/protypehos.blend \
      [--glb assets/models/characters/hospitaller.glb] \
      [--blend /mnt/drive3/Modeling/project-long-colt/Hospitaller/hospitaller.blend] \
      [--previews <dir>] [--only helmet] [--no-export]

The prototype .blend is the base: its body mesh becomes the undersuit, its helmet and cuirass
become the Hospitaller helmet and the Cuirass chest. It is read, never written; the finished
model is saved to --blend.

Output node tree (glb root = `Blockout` in player_model.tscn, so every existing node path holds):
  BodyMesh / PB_Pelvis / ... the block-out's joint empties (same names, pivots, hierarchy)
      armour parts AR_<slot>_<variant>_<piece> and CORE_<piece> hang under their joint
  HospSkeleton (Skeleton3D) / Undersuit (skinned; bones B_* follow the PB_* joints at runtime,
      see scripts/player/body_skin_sync.gd)
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hosp_armor  # noqa: E402
import hosp_body  # noqa: E402
import hosp_core  # noqa: E402
import hosp_geo  # noqa: E402
from hosp_geo import Geo, g2b  # noqa: E402

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _arg(name, default):
    return argv[argv.index(name) + 1] if name in argv else default


PROTO = _arg("--proto", "/mnt/drive3/Modeling/project-long-colt/Hospitaller/protypehos.blend")
GLB = _arg("--glb", "assets/models/characters/hospitaller.glb")
BLEND = _arg("--blend", "/mnt/drive3/Modeling/project-long-colt/Hospitaller/hospitaller.blend")
PREVIEWS = _arg("--previews", "")
ONLY = _arg("--only", "")
EXPORT = "--no-export" not in argv

# glTF material name, sRGB hex, Blender viewport roughness. Order = hosp_geo.MAT_KEYS.
MATERIALS = {
    "A": ("mat_armor", "#4a5039"),      # field olive, primary tint
    "X": ("mat_accent", "#b3261e"),     # stencil red, shoulder accent tint
    "U": ("mat_undersuit", "#2e2f31"),  # undersuit / rubber
    "W": ("mat_webbing", "#5c584c"),    # webbing, pouches, straps
    "M": ("mat_frame", "#6c7075"),      # worn steel exo frame, bolts
    "V": ("mat_visor", "#a87a1e"),      # amber visor
    "B": ("mat_bdu", "#34362d"),        # baggy battle-dress uniform (the skinned body)
}


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    h = h.lstrip("#")
    return tuple(srgb_to_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


def make_materials():
    out = {}
    for key, (name, hx) in MATERIALS.items():
        m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = m.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = hexcol(hx)
        bsdf.inputs["Roughness"].default_value = 0.85
        bsdf.inputs["Metallic"].default_value = 0.4 if key == "M" else 0.0
        m.diffuse_color = hexcol(hx)
        out[key] = m
    return out


# ---- open the prototype ------------------------------------------------------------------------
bpy.ops.wm.open_mainfile(filepath=PROTO)
scene = bpy.context.scene
proto_objs = {o.name: o for o in bpy.data.objects}
mats = make_materials()

# Everything new lives in collection "Hospitaller"; the prototype's own objects go into
# "Prototype" (hidden) so the finished .blend still carries the base for reference.
hosp_col = bpy.data.collections.new("Hospitaller")
scene.collection.children.link(hosp_col)
proto_col = bpy.data.collections.new("Prototype (base)")
scene.collection.children.link(proto_col)


def proto_geo(name):
    """A prototype object's evaluated mesh (modifiers applied) in Godot space via U."""
    o = proto_objs[name]
    me = o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
    vs = [hosp_body.proto_to_g(o.matrix_world @ v.co) for v in me.vertices]
    g = Geo().add(vs, [tuple(p.vertices) for p in me.polygons], "A")
    o.to_mesh_clear()
    return g


# The prototype helmet's visor (the user's markup): its whole front dome, outer faces forward of
# the side ear strips (z < -0.015) and above the bottom rim (y > 1.535), plus the strip running
# back over the crown and the narrow faces just ahead of the ear strips. Indices are faces of the
# prototype Helmet with its Mirror modifier applied (each side listed; the mirror adds 74).
VISOR_EXTRA = {0, 9, 7, 74, 83, 81}


def visor_face(g, index):
    f = g.f[index]
    pts = [g.v[i] for i in f]
    c = sum(pts, Vector()) / len(pts)
    outer = hosp_geo.poly_normal(pts).dot(c - Vector((0, 1.64, -0.01))) > 0
    return index in VISOR_EXTRA or (outer and c.z < -0.015 and c.y > 1.535)


# ---- 1. undersuit -------------------------------------------------------------------------------
rig, undersuit, body_v, body_f, fit = hosp_body.build_undersuit(proto_objs["Cube_Material.001_0"], hosp_col)
undersuit.data.materials.append(mats["B"])
body_surface = hosp_geo.Surface(body_v, body_f)

# ---- 2. the user's pieces, refit onto the new body ------------------------------------------
proto = {}
helmet = proto_geo("Helmet")
# Sit it on PB_Head (U puts the base head 1.1 cm low) and grow it 10 % about the visor line to
# the block-out's helmet mass (crown ~1.78, 0.28 wide).
helmet = helmet.transformed(Matrix.Translation((0, 1.60, -0.01)) @ Matrix.Scale(1.1, 4)
                            @ Matrix.Translation((0, -1.60 + 0.011, 0.01)))
helmet.m = ["V" if visor_face(helmet, i) else "A" for i in range(len(helmet.f))]
proto["helmet"] = helmet
# The two chest pieces are separate designs: "Cube" (visible in the prototype: the base chest)
# and "Chestplate" (hidden there: the Breastplate variant). Both are fitted rigidly (scale +
# offset only, so their facets stay as modelled): onto PB_Chest's line and widened like the
# undersuit's chest (hosp_body.GIRTH B_Chest).
CHEST_FIT = (Matrix.Translation((0, 1.12, 0.0)) @ Matrix.Diagonal((1.2, 1.06, 1.12, 1.0))
             @ Matrix.Translation((0, -1.1158, 0.0)))
for key, name in (("chest_vest", "Cube"), ("chest_plate", "Chestplate")):
    proto[key] = proto_geo(name).transformed(CHEST_FIT)

for o in list(proto_objs.values()):
    for c in list(o.users_collection):
        c.objects.unlink(o)
    proto_col.objects.link(o)
    o.hide_render = True
    o.hide_viewport = True
proto_col.hide_render = True

# ---- 3. joints, markers -------------------------------------------------------------------------
objs = {}


def add_empty(name, pivot, parent):
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_type = "PLAIN_AXES"
    ob.empty_display_size = 0.04
    hosp_col.objects.link(ob)
    if parent:
        ob.parent = objs[parent]
        ob.location = g2b(Vector(pivot) - pivot_of(parent))
    else:
        ob.location = g2b(pivot)
    objs[name] = ob
    return ob


_pivots = {}


def pivot_of(name):
    return Vector(_pivots[name])


for name, (pivot, parent) in hosp_body.JOINTS.items():
    _pivots[name] = pivot
    add_empty(name, pivot, parent)
for name, (pivot, parent) in hosp_body.MARKERS.items():
    _pivots[name] = pivot
    add_empty(name, pivot, parent)

# ---- 4. armour + core parts ----------------------------------------------------------------
only = None
if ONLY:
    only = {(s, v) for s, variants in hosp_armor.CATALOGUE.items() for v, _n, _f in variants
            if s == ONLY or f"{s}:{v}" in ONLY.split(",")}
ctx = hosp_armor.Ctx(body_surface, proto)
parts = hosp_core.build_core(ctx) + hosp_armor.build_all(ctx, only)


def make_part(part):
    g = part.geo
    pivot = Vector(part.pivot) if part.pivot is not None else pivot_of(part.joint)
    keys = sorted(set(g.m), key=hosp_geo.MAT_KEYS.index)
    me = bpy.data.meshes.new(part.name)
    me.from_pydata([g2b(p - pivot) for p in g.v], [], g.f)
    for k in keys:
        me.materials.append(mats[k])
    for poly, k in zip(me.polygons, g.m):
        poly.material_index = keys.index(k)
        poly.use_smooth = True
    me.validate()
    try:
        me.use_auto_smooth = True
        me.auto_smooth_angle = math.radians(g.sharp)
    except AttributeError:  # Blender 4.1+: smooth-by-angle happens at export via sharp edges
        pass
    me.update()
    ob = bpy.data.objects.new(part.name, me)
    hosp_col.objects.link(ob)
    ob.parent = objs[part.joint]
    if part.pivot is not None:
        ob.location = g2b(pivot - pivot_of(part.joint))
    return ob


# ---- fit checks: pull the BDU under every armour variant, list floating pieces -------------
import hosp_check  # noqa: E402

fixed, clip_report = hosp_check.fix_bdu_clipping(parts, body_v, body_f, fit.bdu_weights)
for i, v in enumerate(fixed):
    undersuit.data.vertices[i].co = g2b(v)
undersuit.data.update()
moved = sum(1 for a, b in zip(body_v, fixed) if (a - b).length > 1e-6)
print("CHECK BDU vertices pulled under armour:", moved)
for line in hosp_check.snap_floating(parts, fixed, body_f):
    print("CHECK", line)
for line in clip_report:
    print("CHECK", line)
for line in hosp_check.float_report(parts, fixed, body_f):
    print("CHECK", line)
for line in hosp_check.armour_clash_report(parts):
    print("CHECK", line)

part_objs = [make_part(p) for p in parts]


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


print("STAT undersuit tris", tris(undersuit))
by_module = {}
for o in part_objs:
    bits = o.name.split("_")
    key = "core" if bits[0] == "CORE" else f"{bits[1]}:{bits[2]}"
    by_module[key] = by_module.get(key, 0) + tris(o)
for k in sorted(by_module):
    print("STAT module %-24s %5d tris" % (k, by_module[k]))

# ---- 5. save + export ------------------------------------------------------------------------
if EXPORT:
    for o in bpy.data.objects:
        o.select_set(False)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND, copy=False)
    print("SAVED", BLEND)
    # Export only the Hospitaller collection.
    for o in hosp_col.all_objects:
        o.select_set(True)
    os.makedirs(os.path.dirname(os.path.abspath(GLB)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.abspath(GLB), export_format="GLB", export_yup=True,
                              export_apply=True, export_cameras=False, export_lights=False,
                              export_materials="EXPORT", export_extras=False, export_normals=True,
                              export_texcoords=True, use_selection=True, export_skins=True,
                              export_animations=False)
    print("EXPORTED", os.path.abspath(GLB))

# ---- 6. previews -------------------------------------------------------------------------------
if PREVIEWS:
    import hosp_render
    hosp_render.render_all(scene, hosp_col, part_objs, undersuit, PREVIEWS)
