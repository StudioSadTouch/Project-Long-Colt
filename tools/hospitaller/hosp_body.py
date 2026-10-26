"""Hospitaller undersuit: the prototype's base body refit onto the Long Colt joint layout.

The base mesh is "Low-poly Male Base Mesh" by decodigo (Sketchfab, CC-BY-4.0), already in
the user's prototype .blend (object Cube_Material.001_0). It stands in an A-pose at ~4 m.

1. Uniform transform U (proto -> Godot space): x mirrored (proto faces -Y, left on +X),
   scale 0.432, hip line 2.0 -> 0.90. That alone lands the eye line on 1.60 and the shoulders
   on 1.36, the player block-out's heights.
2. Bone-heat weights on a source skeleton placed on the base mesh's own joints (A-pose).
3. Each bone gets an affine map from its source segment to the block-out's joint pivots
   (rotation + stretch along the bone); vertices move by the weighted blend of those maps.
   Arms drop from the A-pose to hanging, legs close to x +-0.11.
4. Hands, feet and head are cut away: gloves, boots and helmets replace them.
5. A target armature (bones B_* with heads on the PB_* pivots) skins the result.

The PB_* joint pivots below are the contract with the animation library
(tools/character_anims/gen_character_anims.py OFF table) and must not move.
"""
import bmesh
import bpy
from mathutils import Vector

from hosp_geo import g2b

S = 0.432
Z0 = 2.0
Y0 = 0.90
ZOFF = -0.013


def proto_to_g(p):
    return Vector((-p[0] * S, (p[2] - Z0) * S + Y0, p[1] * S + ZOFF))


# ---- the block-out joint layout (Godot space). name: (pivot, parent) ---------------------------
JOINTS = {
    "BodyMesh": ((0, 0, 0), None),
    "PB_Pelvis": ((0, 0.93, 0), "BodyMesh"),
    "PB_Abdomen": ((0, 1.00, 0), "PB_Pelvis"),
    "PB_Chest": ((0, 1.12, 0), "PB_Abdomen"),
    "PB_Neck": ((0, 1.49, 0), "PB_Chest"),
    "PB_Head": ((0, 1.54, 0), "PB_Neck"),
}
for _s, _L in ((-1, "L"), (1, "R")):
    JOINTS[f"PB_UpperArm_{_L}"] = ((_s * 0.25, 1.36, 0), "PB_Chest")
    JOINTS[f"PB_Forearm_{_L}"] = ((_s * 0.275, 1.00, 0), f"PB_UpperArm_{_L}")
    JOINTS[f"PB_Hand_{_L}"] = ((_s * 0.29, 0.80, 0), f"PB_Forearm_{_L}")
    JOINTS[f"PB_Thigh_{_L}"] = ((_s * 0.11, 0.88, 0), "PB_Pelvis")
    JOINTS[f"PB_Shin_{_L}"] = ((_s * 0.11, 0.51, 0), f"PB_Thigh_{_L}")
    JOINTS[f"PB_Boot_{_L}"] = ((_s * 0.11, 0.12, 0), f"PB_Shin_{_L}")

# Markers and slot groups (empties) kept from the block-out.
MARKERS = {
    "OffHand_L": ((-0.28, 0.745, -0.01), "PB_Hand_L"),
    "WeaponAttach_R": ((0.28, 0.745, -0.01), "PB_Hand_R"),
    "NeckMesh": ((0, 0, 0), "PB_Neck"),
    "HelmetMesh": ((0, 1.64, 0), "PB_Head"),
    "VisorMesh": ((0, 0, 0), "PB_Head"),
}

# Skin bones: name -> (joint it follows, target head, target tail, parent bone)
BONES = {
    "B_Pelvis": ("PB_Pelvis", (0, 0.93, 0), (0, 1.00, 0), None),
    "B_Abdomen": ("PB_Abdomen", (0, 1.00, 0), (0, 1.12, 0), "B_Pelvis"),
    "B_Chest": ("PB_Chest", (0, 1.12, 0), (0, 1.49, 0), "B_Abdomen"),
    "B_Neck": ("PB_Neck", (0, 1.49, 0), (0, 1.54, 0), "B_Chest"),
    "B_Head": ("PB_Head", (0, 1.54, 0), (0, 1.75, 0), "B_Neck"),
}
for _s, _L in ((-1, "L"), (1, "R")):
    BONES[f"B_UpperArm_{_L}"] = (f"PB_UpperArm_{_L}", (_s * 0.25, 1.36, 0), (_s * 0.275, 1.00, 0), "B_Chest")
    BONES[f"B_Forearm_{_L}"] = (f"PB_Forearm_{_L}", (_s * 0.275, 1.00, 0), (_s * 0.29, 0.80, 0), f"B_UpperArm_{_L}")
    BONES[f"B_Hand_{_L}"] = (f"PB_Hand_{_L}", (_s * 0.29, 0.80, 0), (_s * 0.285, 0.68, -0.01), f"B_Forearm_{_L}")
    BONES[f"B_Thigh_{_L}"] = (f"PB_Thigh_{_L}", (_s * 0.11, 0.88, 0), (_s * 0.11, 0.51, 0), "B_Pelvis")
    BONES[f"B_Shin_{_L}"] = (f"PB_Shin_{_L}", (_s * 0.11, 0.51, 0), (_s * 0.11, 0.12, 0), f"B_Thigh_{_L}")
    BONES[f"B_Boot_{_L}"] = (f"PB_Boot_{_L}", (_s * 0.11, 0.12, 0), (_s * 0.11, 0.035, -0.13), f"B_Shin_{_L}")

# Source joints on the base mesh (proto Blender coords, character's left = +X), measured from
# cross-sections and the front / side grid renders.
_SRC_L = {
    "hip": (0.19, 0.06, 1.98), "knee": (0.44, 0.13, 0.98), "ankle": (0.60, 0.16, 0.22),
    "toe": (0.64, -0.22, 0.05),
    "shoulder": (0.42, 0.07, 3.08), "elbow": (0.79, 0.09, 2.60), "wrist": (1.12, 0.0, 2.17),
    "handtip": (1.27, -0.06, 1.88),
}
_SRC_C = {
    "pelvis": (0, 0.03, 2.08), "abdomen": (0, 0.03, 2.25), "chest": (0, 0.03, 2.55),
    "neck": (0, 0.04, 3.32), "head": (0, 0.02, 3.45), "top": (0, 0.0, 3.97),
}


def _src(name, side):
    if name in _SRC_C:
        return proto_to_g(_SRC_C[name])
    p = _SRC_L[name]
    if side == "R":
        p = (-p[0], p[1], p[2])
    return proto_to_g(p)


def source_segments():
    seg = {
        "B_Pelvis": (_src("pelvis", ""), _src("abdomen", "")),
        "B_Abdomen": (_src("abdomen", ""), _src("chest", "")),
        "B_Chest": (_src("chest", ""), _src("neck", "")),
        "B_Neck": (_src("neck", ""), _src("head", "")),
        "B_Head": (_src("head", ""), _src("top", "")),
    }
    for L in ("L", "R"):
        seg[f"B_UpperArm_{L}"] = (_src("shoulder", L), _src("elbow", L))
        seg[f"B_Forearm_{L}"] = (_src("elbow", L), _src("wrist", L))
        seg[f"B_Hand_{L}"] = (_src("wrist", L), _src("handtip", L))
        seg[f"B_Thigh_{L}"] = (_src("hip", L), _src("knee", L))
        seg[f"B_Shin_{L}"] = (_src("knee", L), _src("ankle", L))
        seg[f"B_Boot_{L}"] = (_src("ankle", L), _src("toe", L))
    return seg


# Girth across each bone (Godot x, z scale about the bone axis). The base mesh's shoulders sit
# at x 0.18 against the block-out's 0.25 pivots, so the torso widens; the upper arm gains ~30 %
# length on the block-out's elbow and gets a little bulk back.
GIRTH = {
    "B_Pelvis": (1.12, 1.05), "B_Abdomen": (1.12, 1.06), "B_Chest": (1.22, 1.1),
    "B_Neck": (1.1, 1.05),
    "B_UpperArm_L": (1.12, 1.12), "B_UpperArm_R": (1.12, 1.12),
    "B_Forearm_L": (1.05, 1.05), "B_Forearm_R": (1.05, 1.05),
    "B_Thigh_L": (1.06, 1.06), "B_Thigh_R": (1.06, 1.06),
}


class BoneMap:
    """Takes the source segment onto the target one: rotate the direction onto the target's,
    stretch along it (only past the head: what lies above a joint is not stretched), scale
    across it by girth (x, z in the bone's frame, x = Godot x where the bone is vertical)."""

    def __init__(self, src, tgt, girth=(1.0, 1.0)):
        self.hs = Vector(src[0])
        ds = Vector(src[1]) - self.hs
        self.ht = Vector(tgt[0])
        dt = Vector(tgt[1]) - self.ht
        self.q = ds.normalized().rotation_difference(dt.normalized()).to_matrix()
        self.k = dt.length / ds.length
        self.d = dt.normalized()
        ref = Vector((1, 0, 0)) if abs(self.d.x) < 0.9 else Vector((0, 1, 0))
        self.ax = (ref - self.d * ref.dot(self.d)).normalized()
        self.az = self.d.cross(self.ax)
        self.g = girth

    def __call__(self, p):
        r = self.q @ (Vector(p) - self.hs)
        t = r.dot(self.d)
        x, z = r.dot(self.ax), r.dot(self.az)
        t = t * self.k if t > 0 else t
        return self.ht + self.d * t + self.ax * (x * self.g[0]) + self.az * (z * self.g[1])


def _make_armature(name, segs, collection):
    arm = bpy.data.armatures.new(name)
    ob = bpy.data.objects.new(name, arm)
    collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for bname, (h, t, parent) in segs.items():
        eb = arm.edit_bones.new(bname)
        eb.head, eb.tail = g2b(h), g2b(t)
        eb.roll = 0.0
    for bname, (h, t, parent) in segs.items():
        if parent:
            arm.edit_bones[bname].parent = arm.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return ob


def build_undersuit(proto_body, collection):
    """Returns (armature_object, undersuit_mesh_object) in the final rest pose."""
    # Source mesh in Godot space (U), as a Blender object for bone heat.
    src_me = proto_body.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
    mw = proto_body.matrix_world
    # The Sketchfab import splits vertices along UV seams (arms, hips, neck are separate
    # islands): weld them, or the bone maps tear the seams open.
    bm = bmesh.new()
    bm.from_mesh(src_me)
    proto_body.to_mesh_clear()
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4)
    bm.verts.index_update()
    verts_g = [proto_to_g(mw @ v.co) for v in bm.verts]
    faces = [tuple(v.index for v in f.verts) for f in bm.faces]
    bm.free()
    print("BODY welded verts:", len(verts_g), "faces:", len(faces))
    me = bpy.data.meshes.new("Undersuit")
    me.from_pydata([g2b(v) for v in verts_g], [], faces)
    me.update()
    body = bpy.data.objects.new("Undersuit", me)
    collection.objects.link(body)

    segs = source_segments()
    src_arm = _make_armature(
        "SourceRig", {b: (segs[b][0], segs[b][1], BONES[b][3]) for b in BONES}, collection)
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    body.select_set(True)
    src_arm.select_set(True)
    bpy.context.view_layer.objects.active = src_arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    weights = [{} for _ in me.vertices]
    names = {vg.index: vg.name for vg in body.vertex_groups}
    for v in me.vertices:
        for gr in v.groups:
            if gr.weight > 1e-4:
                weights[v.index][names[gr.group]] = gr.weight
    unweighted = [i for i, w in enumerate(weights) if not w]
    print("BODY unweighted verts after heat:", len(unweighted))
    # Fallback for any vertex heat missed: nearest source bone segment.
    for i in unweighted:
        p = verts_g[i]
        best = min(segs, key=lambda b: _seg_dist(p, *segs[b]))
        weights[i] = {best: 1.0}

    weights = _smooth_weights(weights, faces, iterations=1, keep=0.65)
    # glTF skins carry 4 influences per vertex: keep the strongest 4, so Godot deforms exactly
    # what this fit computed.
    weights = [dict(sorted(w.items(), key=lambda kv: -kv[1])[:4]) for w in weights]
    maps = {b: BoneMap(segs[b], (BONES[b][1], BONES[b][2]), GIRTH.get(b, (1.0, 1.0))) for b in BONES}
    out = []
    for i, p in enumerate(verts_g):
        tot = sum(weights[i].values())
        acc = Vector()
        for b, w in weights[i].items():
            acc += maps[b](p) * (w / tot)
        out.append(acc)

    # Cut hands, feet, head (replaced by gloves, boots, helmets).
    def owner(i):
        return max(weights[i].items(), key=lambda kv: kv[1])[0]

    cut_bones = {"B_Hand_L", "B_Hand_R", "B_Boot_L", "B_Boot_R", "B_Head"}
    keep_faces = []
    for f in faces:
        if all(owner(i) in cut_bones for i in f):
            continue
        # Feet and ankles: anything wholly inside the boot shaft goes too.
        if all(out[i].y < 0.2 for i in f):
            continue
        keep_faces.append(f)
    used = sorted({i for f in keep_faces for i in f})
    remap = {old: new for new, old in enumerate(used)}
    verts = [out[i] for i in used]
    tris = [tuple(remap[i] for i in f) for f in keep_faces]
    wts = [weights[i] for i in used]
    # The battle-dress layer: one subdivision for cloth folds, then the baggy BDU offsets.
    verts, tris, wts = _subdivide(verts, tris, wts)
    verts = _bdu(verts, tris, wts)
    wts = [dict(sorted(w.items(), key=lambda kv: -kv[1])[:4]) for w in wts]

    # Replace the object data with the deformed, trimmed, dressed mesh.
    bpy.data.objects.remove(body)
    bpy.data.objects.remove(src_arm)
    me2 = bpy.data.meshes.new("Undersuit")
    me2.from_pydata([g2b(v) for v in verts], [], tris)
    me2.update()
    body = bpy.data.objects.new("Undersuit", me2)
    collection.objects.link(body)
    for b in BONES:
        body.vertex_groups.new(name=b)
    for i, w in enumerate(wts):
        tot = sum(w.values())
        for b, x in w.items():
            body.vertex_groups[b].add([i], x / tot, "REPLACE")

    rig = _make_armature("HospSkeleton", {b: (BONES[b][1], BONES[b][2], BONES[b][3]) for b in BONES}, collection)
    body.parent = rig
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    for p in me2.polygons:
        p.use_smooth = True
    fit = Fit(verts_g, weights, maps)
    fit.bdu_weights = wts
    return rig, body, verts, tris, fit


def _subdivide(verts, faces, wts):
    """One linear Catmull-Clark-topology split (no smoothing): every n-gon becomes n quads
    round its centre. Weights are averaged like positions."""
    vs = [Vector(v) for v in verts]
    ws = [dict(w) for w in wts]

    def mix(ids):
        p = sum((vs[i] for i in ids), Vector()) / len(ids)
        w = {}
        for i in ids:
            for b, x in ws[i].items():
                w[b] = w.get(b, 0.0) + x / len(ids)
        vs.append(p)
        ws.append(w)
        return len(vs) - 1

    mids = {}
    out = []
    for f in faces:
        c = mix(list(f))
        em = []
        for k in range(len(f)):
            a, b = f[k], f[(k + 1) % len(f)]
            key = (min(a, b), max(a, b))
            if key not in mids:
                mids[key] = mix([a, b])
            em.append(mids[key])
        for k in range(len(f)):
            out.append((f[k], em[k], c, em[k - 1]))
    return vs, out, ws


# BDU bagginess per bone (m off the body): base ease, fold amplitude.
BDU = {
    # Torso and seat stay close: the vests, belts and thigh plates sit over them.
    "B_Pelvis": (0.012, 0.003), "B_Abdomen": (0.01, 0.003), "B_Chest": (0.006, 0.002),
    "B_Neck": (0.004, 0.0),
    "B_UpperArm_L": (0.022, 0.008), "B_UpperArm_R": (0.022, 0.008),
    "B_Forearm_L": (0.016, 0.006), "B_Forearm_R": (0.016, 0.006),
    "B_Thigh_L": (0.03, 0.009), "B_Thigh_R": (0.03, 0.009),
    "B_Shin_L": (0.024, 0.008), "B_Shin_R": (0.024, 0.008),
}
BOOT_TOP = 0.255  # trousers tuck in below this and blouse just above it


def _bdu(verts, faces, wts):
    """Baggy battle-dress uniform: push each vertex out along its normal by its bone's ease,
    ripple diagonal folds round the limbs, blouse the trousers over the boot tops and tuck
    them in below (the boots carry the legs from there)."""
    import math
    import random
    rnd = random.Random(7)
    normals = [Vector() for _ in verts]
    for f in faces:
        pts = [verts[i] for i in f]
        n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
        for i in f:
            normals[i] += n
    out = []
    for i, p in enumerate(verts):
        n = normals[i].normalized() if normals[i].length > 1e-9 else Vector((0, 0, 0))
        ease, amp = 0.0, 0.0
        for b, w in wts[i].items():
            e, a = BDU.get(b, (0.0, 0.0))
            ease += e * w
            amp += a * w
        bone = max(wts[i].items(), key=lambda kv: kv[1])[0]
        head = Vector(BONES[bone][1])
        tail = Vector(BONES[bone][2])
        axis = (tail - head).normalized()
        t = (p - head).dot(axis)
        radial = (p - head) - axis * t
        ang = math.atan2(radial.x, radial.z) if radial.length > 1e-6 else 0.0
        if bone.startswith("B_Thigh") or bone.startswith("B_UpperArm"):
            # Snug at the hip / shoulder (under the thigh plates' tops and the vest's
            # armholes), full bagginess further down the limb.
            k = 0.15 + 0.85 * max(0.0, min(1.0, (t - 0.03) / 0.16))
            ease *= k
            amp *= k
        fold = amp * math.sin(t / 0.085 * 2 * math.pi + 2.0 * ang)
        d = ease + fold + rnd.uniform(-0.0015, 0.0015)
        if p.y < BOOT_TOP + 0.08 and bone.startswith("B_Shin"):
            # Blousing: a roll of cloth over the boot top, tucked in below it.
            u = (p.y - BOOT_TOP) / 0.08
            d = 0.0 if p.y < BOOT_TOP - 0.01 else d + 0.016 * math.sin(max(0.0, min(1.0, u)) * math.pi)
        out.append(p + n * d)
    return out


class Fit:
    """Moves any source-space (U) point the way the body moved: it takes the bone weights of
    the nearest body vertex. Used to refit the user's prototype armour onto the new body."""

    def __init__(self, verts_g, weights, maps):
        from mathutils.kdtree import KDTree
        self.kd = KDTree(len(verts_g))
        for i, v in enumerate(verts_g):
            self.kd.insert(v, i)
        self.kd.balance()
        self.weights = weights
        self.maps = maps

    def weights_at(self, p, k=4):
        acc = {}
        hits = self.kd.find_n(p, k)
        tot_w = 0.0
        for co, i, d in hits:
            wd = 1.0 / max(d, 1e-3)
            tot_w += wd
            for b, w in self.weights[i].items():
                acc[b] = acc.get(b, 0.0) + w * wd
        return {b: w / tot_w for b, w in acc.items()}

    def deform(self, p, weights=None):
        w = weights or self.weights_at(p)
        tot = sum(w.values())
        acc = Vector()
        for b, x in w.items():
            acc += self.maps[b](p) * (x / tot)
        return acc


def _seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (a + ab * t - p).length


def _smooth_weights(weights, faces, iterations=2, keep=0.5):
    """Laplacian blur of bone weights over mesh edges (low-poly heat weights step hard)."""
    nb = [set() for _ in weights]
    for f in faces:
        for i in range(len(f)):
            a, b = f[i], f[(i + 1) % len(f)]
            nb[a].add(b)
            nb[b].add(a)
    for _ in range(iterations):
        new = []
        for i, w in enumerate(weights):
            acc = {k: v * keep for k, v in w.items()}
            share = (1 - keep) / max(1, len(nb[i]))
            for j in nb[i]:
                for k, v in weights[j].items():
                    acc[k] = acc.get(k, 0.0) + v * share
            tot = sum(acc.values())
            new.append({k: v / tot for k, v in acc.items() if v / tot > 0.01})
        weights = new
    return weights
