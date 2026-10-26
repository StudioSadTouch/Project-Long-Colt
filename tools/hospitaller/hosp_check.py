"""Fit checks for the Hospitaller: floating pieces and BDU clipping through armour.

Everything runs on the Godot-space rest pose (Part.geo is world space at rest; the undersuit
arrays come from hosp_body.build_undersuit).

* Clipping: the BDU must stay under the armour. A BDU edge that crosses an armour or core
  surface is a poke-through; fix_bdu_clipping() pulls such edges' ends in toward their bone
  axis until no loadout (every variant of every slot, with the other slots at their defaults)
  has a crossing.
* Floating: every connected piece of every part (a pouch, a bolt, a strut) must touch the BDU or
  another visible piece within FLOAT_TOL; float_report() lists those that do not.
"""
from mathutils import Vector
from mathutils.bvhtree import BVHTree

import hosp_armor
import hosp_body

FLOAT_TOL = 0.006
MAX_PULL = 0.025  # the most the BDU may be pulled in under armour (m)
MAX_SNAP = 0.012  # loose pieces farther than this are reported, not dragged (fix them by hand)


def related_joints(joint):
    """The joint, its parent and its children: armour on these can touch that region."""
    out = {joint}
    parent = hosp_body.JOINTS.get(joint, (None, None))[1]
    if parent:
        out.add(parent)
    for name, (_pivot, par) in hosp_body.JOINTS.items():
        if par == joint:
            out.add(name)
    return out


def bone_joint(bone):
    return hosp_body.BONES[bone][0]


def loadouts():
    """Every variant of every slot once, the other slots at their defaults."""
    base = {slot: variants[0][0] for slot, variants in hosp_armor.CATALOGUE.items()}
    out = [dict(base)]
    for slot, variants in hosp_armor.CATALOGUE.items():
        for vid, _n, _f in variants[1:]:
            lo = dict(base)
            lo[slot] = vid
            out.append(lo)
    return out


def visible(parts, lo):
    out = []
    for p in parts:
        bits = p.name.split("_")
        if bits[0] == "CORE" or lo.get(bits[1]) == bits[2]:
            out.append(p)
    return out


def _bvh(parts):
    vs, fs, owner = [], [], []
    for k, p in enumerate(parts):
        base = len(vs)
        vs += p.geo.v
        for f in p.geo.f:
            fs.append(tuple(base + i for i in f))
            owner.append(k)
    return BVHTree.FromPolygons(vs, fs), owner


def _edges(faces):
    es = set()
    for f in faces:
        for i in range(len(f)):
            a, b = f[i], f[(i + 1) % len(f)]
            es.add((min(a, b), max(a, b)))
    return sorted(es)


def crossings(verts, edges, bvh, normals, axes, face_joint=None, vert_joint=None):
    """BDU edges that pass through an armour wall. Faces whose normal runs along the limb
    (boot / glove / collar caps the BDU tucks into) do not count, nor armour on joints
    unrelated to the edge's region (a hanging bracer against the thigh is a rest-pose touch,
    not clipping)."""
    bad = []
    for a, b in edges:
        d = verts[b] - verts[a]
        n = d.length
        if n < 1e-7:
            continue
        hit = bvh.ray_cast(verts[a], d / n, n)
        if hit[0] is None:
            continue
        h, t = axes[a]
        ax = (t - h).normalized()
        if abs(hit[1].dot(ax)) > 0.7:
            continue
        # Only a plate's outer wall shows a poke-through (its normal faces away from the limb);
        # cloth inside a plate's thickness is hidden.
        rel = hit[0] - h
        radial = rel - ax * rel.dot(ax)
        if hit[1].dot(radial) <= 0.0:
            continue
        if face_joint is not None and face_joint[hit[2]] not in related_joints(vert_joint[a]):
            continue
        bad.append((a, b, hit[2]))
    return bad


def fix_bdu_clipping(parts, verts, faces, wts, step=0.002, rounds=14):
    """Pull poking BDU vertices in toward their bone axis (at most MAX_PULL) until no loadout
    clips. Returns the fixed vertices and a report line per loadout still clipping."""
    verts = [Vector(v) for v in verts]
    start = [Vector(v) for v in verts]
    edges = _edges(faces)
    los = loadouts()
    trees = []
    for lo in los:
        vis = visible(parts, lo)
        tree, owner = _bvh(vis)
        trees.append((tree, [vis[k].joint for k in owner], vis, owner, lo))
    axis, vjoint = [], []
    for w in wts:
        bone = max(w.items(), key=lambda kv: kv[1])[0]
        axis.append((Vector(hosp_body.BONES[bone][1]), Vector(hosp_body.BONES[bone][2])))
        vjoint.append(bone_joint(bone))
    for _ in range(rounds):
        moved = set()
        for tree, fj, _vis, _owner, _lo in trees:
            for a, b, _f in crossings(verts, edges, tree, None, axis, fj, vjoint):
                moved.add(a)
                moved.add(b)
        if not moved:
            break
        for i in moved:
            if (verts[i] - start[i]).length >= MAX_PULL:
                continue
            h, t = axis[i]
            ax = (t - h).normalized()
            rel = verts[i] - h
            radial = rel - ax * rel.dot(ax)
            if radial.length > step * 2:
                verts[i] -= radial.normalized() * step
    report = []
    for tree, fj, vis, owner, lo in trees:
        bad = crossings(verts, edges, tree, None, axis, fj, vjoint)
        if bad:
            per = {}
            for a, b, f in bad:
                per.setdefault(vis[owner[f]].name, []).append((verts[a] + verts[b]) / 2)
            detail = ", ".join("%s %d @y%.2f" % (n, len(ps), sum(p.y for p in ps) / len(ps))
                               for n, ps in sorted(per.items()))
            report.append("CLIP %d BDU edges: %s (loadout %s)" % (len(bad), detail, lo))
    return verts, report


def pieces(geo, tol=FLOAT_TOL):
    """Rigid groups of a Geo: connected components merged when they touch (within tol), so a
    pouch and its flap or a drum and its bolt plate move together."""
    comps = components(geo)
    if len(comps) < 2:
        return comps
    trees = []
    for comp in comps:
        cs = set(comp)
        remap = {i: n for n, i in enumerate(comp)}
        fs = [tuple(remap[i] for i in f) for f in geo.f if f[0] in cs]
        trees.append(BVHTree.FromPolygons([geo.v[i] for i in comp], fs))
    parent = list(range(len(comps)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a in range(len(comps)):
        for b in range(a + 1, len(comps)):
            if find(a) == find(b):
                continue
            if any(trees[b].find_nearest(geo.v[i], tol)[0] is not None for i in comps[a]):
                parent[find(b)] = find(a)
    groups = {}
    for k, comp in enumerate(comps):
        groups.setdefault(find(k), []).extend(comp)
    return [sorted(g) for g in groups.values()]


def components(geo):
    """Connected pieces of a Geo: lists of vertex indices."""
    parent = list(range(len(geo.v)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for f in geo.f:
        r = find(f[0])
        for i in f[1:]:
            parent[find(i)] = r
    groups = {}
    for f in geo.f:
        for i in f:
            groups.setdefault(find(i), set()).add(i)
    return [sorted(g) for g in groups.values()]


def _module(name):
    bits = name.split("_")
    return "core" if bits[0] == "CORE" else bits[1] + "_" + bits[2]


def _targets(parts, bdu_verts, bdu_faces, module, skip):
    """BVH over the BDU, the core parts and the module's own pieces except `skip`
    (part index, component vertex set); returns (tree, owner) with owner = part index or -1."""
    vs = list(bdu_verts)
    fs = [tuple(f) for f in bdu_faces]
    owner = [-1] * len(fs)
    for k, p in enumerate(parts):
        m = _module(p.name)
        if m != "core" and m != module:
            continue
        base = len(vs)
        vs += p.geo.v
        for f in p.geo.f:
            if k == skip[0] and f[0] in skip[1]:
                continue
            fs.append(tuple(base + i for i in f))
            owner.append(k)
    return BVHTree.FromPolygons(vs, fs)


def snap_floating(parts, bdu_verts, bdu_faces, rounds=3):
    """Seat every loose piece (a pouch, a plate, a bolt) on its module, the core or the BDU:
    a piece farther than FLOAT_TOL from all of them slides straight onto the nearest one.
    Returns a line per piece moved."""
    log = []
    for _ in range(rounds):
        moved = False
        for k, p in enumerate(parts):
            if p.name.startswith("CORE_"):
                continue  # core parts are fixed to their joints (boot soles on the floor)
            for comp in pieces(p.geo):
                cs = set(comp)
                tree = _targets(parts, bdu_verts, bdu_faces, _module(p.name), (k, cs))
                best = None
                for i in comp:
                    hit = tree.find_nearest(p.geo.v[i])
                    if hit[0] is not None and (best is None or hit[3] < best[0]):
                        best = (hit[3], hit[0] - p.geo.v[i])
                if best is None or best[0] <= FLOAT_TOL:
                    continue
                if best[0] > MAX_SNAP:
                    c = sum((p.geo.v[i] for i in comp), Vector()) / len(comp)
                    log.append("FARFLOAT %s piece at (%.3f, %.3f, %.3f) %.1f mm from its module "
                               "(not moved)" % (p.name, c.x, c.y, c.z, best[0] * 1000))
                    continue
                shift = best[1].normalized() * (best[0] - 0.0015)
                for i in comp:
                    p.geo.v[i] = p.geo.v[i] + shift
                moved = True
                c = sum((p.geo.v[i] for i in comp), Vector()) / len(comp)
                log.append("SNAP %s piece at (%.3f, %.3f, %.3f) moved %.1f mm"
                           % (p.name, c.x, c.y, c.z, shift.length * 1000))
        if not moved:
            break
    return log


def float_report(parts, bdu_verts, bdu_faces):
    """Pieces still farther than FLOAT_TOL from their module, the core and the BDU."""
    out = []
    for k, p in enumerate(parts):
        if p.name.startswith("CORE_"):
            continue
        for comp in pieces(p.geo):
            cs = set(comp)
            tree = _targets(parts, bdu_verts, bdu_faces, _module(p.name), (k, cs))
            d = min(tree.find_nearest(p.geo.v[i])[3] for i in comp)
            if d > FLOAT_TOL:
                c = sum((p.geo.v[i] for i in comp), Vector()) / len(comp)
                out.append("FLOAT %s piece at (%.3f, %.3f, %.3f): %.1f mm" % (p.name, c.x, c.y, c.z, d * 1000))
    return out


def armour_clash_report(parts, min_edges=6):
    """Pieces of different modules crossing each other (edges of one through faces of the
    other), per loadout; small touches (< min_edges) are left out."""
    out = set()
    for lo in loadouts():
        vis = visible(parts, lo)
        trees = {}
        for k, p in enumerate(vis):
            trees[k] = BVHTree.FromPolygons(p.geo.v, p.geo.f)
        for i, a in enumerate(vis):
            ea = _edges(a.geo.f)
            for j, b in enumerate(vis):
                if j <= i or _module(a.name) == _module(b.name):
                    continue
                if b.joint not in related_joints(a.joint):
                    continue
                n = 0
                for u, v in ea:
                    d = a.geo.v[v] - a.geo.v[u]
                    if d.length < 1e-7:
                        continue
                    if trees[j].ray_cast(a.geo.v[u], d.normalized(), d.length)[0] is not None:
                        n += 1
                if n >= min_edges:
                    out.add("CLASH %s x %s: %d edges" % (a.name, b.name, n))
    return sorted(out)
