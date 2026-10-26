"""Geometry helpers for the Hospitaller generator (headless Blender 4.x).

Everything is authored in GODOT space: metres, +Y up, -Z forward, origin at the feet, the
character's left on -X. g2b() / b2g() convert to and from Blender space (+Z up; Godot -Z
forward == Blender +Y). The glTF exporter (export_yup) converts back, so the .glb lands in
Godot exactly as authored.

A part is built as a Geo: Godot-space vertices, faces and a material key per face. Material
keys: A armor (primary tint), X accent (shoulder accent tint), U undersuit, W webbing / pouches,
M frame steel, V visor.
"""
import math

import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree


def g2b(v):
    return Vector((v[0], -v[2], v[1]))


def b2g(v):
    return Vector((v[0], v[2], -v[1]))


def V3(*a):
    return Vector(a[0]) if len(a) == 1 else Vector(a)


def lerp(a, b, t):
    return a + (b - a) * t


def smooth01(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


class Geo:
    """Godot-space polygon soup with one material key per face."""

    def __init__(self):
        self.v = []
        self.f = []
        self.m = []
        self.sharp = 40.0  # auto-smooth angle (deg); flat-ish low-poly armour

    def add(self, verts, faces, mat):
        base = len(self.v)
        self.v += [Vector(p) for p in verts]
        for f in faces:
            self.f.append(tuple(base + i for i in f))
            self.m.append(mat)
        return self

    def extend(self, other, mat=None):
        base = len(self.v)
        self.v += [p.copy() for p in other.v]
        self.f += [tuple(base + i for i in f) for f in other.f]
        self.m += [mat or m for m in other.m]
        return self

    def transformed(self, mat4):
        g = Geo()
        g.v = [mat4 @ p for p in self.v]
        g.f = list(self.f)
        g.m = list(self.m)
        if mat4.determinant() < 0:
            g.f = [tuple(reversed(f)) for f in g.f]
        return g

    def mirrored_x(self):
        return self.transformed(Matrix.Scale(-1, 4, (1, 0, 0)))

    def tris(self):
        return sum(len(f) - 2 for f in self.f)


# ---- primitive builders (return Geo) --------------------------------------------------------
def frame(origin, x_axis, y_axis):
    """4x4 with columns x, y, z = x cross y (right-handed), translation origin."""
    x = Vector(x_axis).normalized()
    y = Vector(y_axis)
    y = (y - x * y.dot(x)).normalized()
    z = x.cross(y)
    m = Matrix.Identity(4)
    for i in range(3):
        m[i][0], m[i][1], m[i][2], m[i][3] = x[i], y[i], z[i], origin[i]
    return m


def box(c, s, mat="A", bevel=0.0):
    """Axis-aligned box centred at c, size s; bevel chamfers every edge."""
    hx, hy, hz = s[0] / 2, s[1] / 2, s[2] / 2
    vs = [(c[0] + sx * hx, c[1] + sy * hy, c[2] + sz * hz)
          for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    g = Geo().add(vs, faces, mat)
    if bevel > 0:
        g = bevel_geo(g, bevel)
    return g


def tbox(b_c, b_w, b_d, t_c, t_w, t_d, mat="A", bevel=0.0):
    """Tapered box: bottom face centred at b_c (w x d), top face centred at t_c."""
    vs = []
    for c, w, d in ((b_c, b_w, b_d), (t_c, t_w, t_d)):
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            vs.append((c[0] + sx * w / 2, c[1], c[2] + sz * d / 2))
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    g = Geo().add(vs, faces, mat)
    if bevel > 0:
        g = bevel_geo(g, bevel)
    return g


def obox(center, x_axis, y_axis, size, mat="A", bevel=0.0):
    """Oriented box: size along (x_axis, y_axis, x cross y)."""
    g = box((0, 0, 0), size, mat, bevel)
    return g.transformed(frame(center, x_axis, y_axis))


def cyl(p0, p1, r, n=10, mat="M", r1=None, bevel=0.0, cap=True, phase=0.5):
    """Cylinder (or cone with r1) from p0 to p1."""
    p0, p1 = Vector(p0), Vector(p1)
    ax = (p1 - p0)
    up = Vector((0, 1, 0)) if abs(ax.normalized().y) < 0.9 else Vector((1, 0, 0))
    u = ax.cross(up).normalized()
    w = ax.cross(u).normalized()
    r1 = r if r1 is None else r1
    vs = []
    for c, rr in ((p0, r), (p1, r1)):
        for i in range(n):
            a = 2 * math.pi * (i + phase) / n
            vs.append(c + (u * math.cos(a) + w * math.sin(a)) * rr)
    faces = []
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    if cap:
        faces.append(tuple(range(n - 1, -1, -1)))
        faces.append(tuple(range(n, 2 * n)))
    g = Geo().add(vs, faces, mat)
    if not _outward(g):
        g.f = [tuple(reversed(f)) for f in g.f]
    if bevel > 0:
        g = bevel_geo(g, bevel)
    return g


def disc(center, normal, r, depth, n=10, mat="M", bevel=0.0):
    c = Vector(center)
    nn = Vector(normal).normalized()
    return cyl(c - nn * depth / 2, c + nn * depth / 2, r, n, mat, bevel=bevel)


def _outward(g):
    """True if faces point away from the centroid (closed solids)."""
    if not g.f:
        return True
    c = sum(g.v, Vector()) / len(g.v)
    s = 0.0
    for f in g.f:
        pts = [g.v[i] for i in f]
        n = poly_normal(pts)
        fc = sum(pts, Vector()) / len(pts)
        s += n.dot(fc - c)
    return s >= 0


def poly_normal(pts):
    n = Vector()
    for i in range(len(pts)):
        a, b = pts[i], pts[(i + 1) % len(pts)]
        n.x += (a.y - b.y) * (a.z + b.z)
        n.y += (a.z - b.z) * (a.x + b.x)
        n.z += (a.x - b.x) * (a.y + b.y)
    return n.normalized() if n.length > 1e-12 else n


def ring_loft(rings, mat="A", cap0=True, cap1=True, closed=True):
    """Loft through rings of equal point count (lists of Vector). closed: rings are loops."""
    n = len(rings[0])
    vs = [Vector(p) for r in rings for p in r]
    faces = []
    span = n if closed else n - 1
    for k in range(len(rings) - 1):
        a, b = k * n, (k + 1) * n
        for i in range(span):
            j = (i + 1) % n
            faces.append((a + i, a + j, b + j, b + i))
    if closed and cap0:
        faces.append(tuple(range(n - 1, -1, -1)))
    if closed and cap1:
        last = (len(rings) - 1) * n
        faces.append(tuple(last + i for i in range(n)))
    g = Geo().add(vs, faces, mat)
    if closed and cap0 and cap1 and not _outward(g):
        g.f = [tuple(reversed(f)) for f in g.f]
    return g


def bevel_geo(g, width, segments=1, only_boundary=False, angle=30.0):
    """Chamfer edges sharper than `angle` with bmesh."""
    bm = to_bmesh(g)
    if only_boundary:
        edges = [e for e in bm.edges if e.is_boundary]
    else:
        edges = [e for e in bm.edges if e.is_manifold and e.calc_face_angle(0) > math.radians(angle)]
    if edges:
        bmesh.ops.bevel(bm, geom=edges, offset=width, segments=segments, affect="EDGES",
                        clamp_overlap=True, profile=0.5)
    return from_bmesh(bm)


def to_bmesh(g):
    bm = bmesh.new()
    vs = [bm.verts.new(p) for p in g.v]
    lay = bm.faces.layers.int.new("mat")
    for f, mk in zip(g.f, g.m):
        try:
            face = bm.faces.new([vs[i] for i in f])
        except ValueError:
            continue
        face[lay] = MAT_INDEX[mk]
    bm.normal_update()
    return bm


def from_bmesh(bm):
    lay = bm.faces.layers.int.get("mat")
    g = Geo()
    idx = {v: i for i, v in enumerate(bm.verts)}
    g.v = [v.co.copy() for v in bm.verts]
    for f in bm.faces:
        g.f.append(tuple(idx[v] for v in f.verts))
        g.m.append(MAT_KEYS[f[lay]] if lay is not None else "A")
    bm.free()
    return g


MAT_KEYS = ["A", "X", "U", "W", "M", "V"]
MAT_INDEX = {k: i for i, k in enumerate(MAT_KEYS)}


def solidify(g, thickness, mat_side=None):
    """Thicken an open shell inward (against its normals) by `thickness`; rim faces get
    mat_side (default: the face's own key)."""
    bm = to_bmesh(g)
    lay = bm.faces.layers.int.get("mat")
    before = set(bm.faces)
    bmesh.ops.solidify(bm, geom=list(bm.faces), thickness=thickness)
    if mat_side is not None:
        new = [f for f in bm.faces if f not in before]
        for f in new:
            # Rim quads have two verts from each side; the inner copy keeps the material.
            if len(f.verts) == 4:
                f[lay] = MAT_INDEX[mat_side]
    return from_bmesh(bm)


# ---- surface projection --------------------------------------------------------------------
class Surface:
    """BVH over a Godot-space mesh, for projecting armour onto the body or a helmet shell."""

    def __init__(self, verts, faces):
        self.verts = [Vector(v) for v in verts]
        self.faces = [tuple(f) for f in faces]
        self.bvh = BVHTree.FromPolygons(self.verts, self.faces)

    def ray(self, origin, direction, dist=5.0):
        return self.bvh.ray_cast(Vector(origin), Vector(direction).normalized(), dist)

    def nearest(self, p):
        return self.bvh.find_nearest(Vector(p))


def radial_plate(surf, axis_pt, rows, cols, offset, thickness, mat="A", rim=None, bevel=0.0,
                 smooth=1, min_r=0.0, bulge=None):
    """Plate conformed to `surf` by rays aimed at a vertical axis through axis_pt (x, z).

    rows: (y, ang_from, ang_to) top to bottom; angle 0 = front (-Z), +90 = +X (the
    character's right), -90 = -X (left). Good for visors, bands and belts that wrap round.
    min_r keeps the plate at least that far from the axis (bridges dips like the neck).
    """
    ax, az = axis_pt[0], axis_pt[1]
    grid = []
    for y, a0, a1 in rows:
        line = []
        for i in range(cols + 1):
            a = math.radians(lerp(a0, a1, i / cols))
            d = Vector((math.sin(a), 0.0, -math.cos(a)))
            c = Vector((ax, y, az))
            hit = surf.ray(c + d * 1.5, -d, 3.0)
            r = (hit[0] - c).length if hit[0] is not None else None
            line.append((c, d, r))
        fixed = []
        js = [j for j, (_c, _d, rr) in enumerate(line) if rr is not None]
        for i, (c, d, r) in enumerate(line):
            if r is None:  # a miss: borrow the nearest hit in this row
                r = line[min(js, key=lambda j: abs(j - i))][2] if js else min_r
            extra = bulge(math.degrees(math.atan2(d.x, -d.z)), c.y) if bulge else 0.0
            fixed.append(c + d * (max(r, min_r) + offset + extra))
        grid.append(fixed)
    for _ in range(smooth):
        new = [[p.copy() for p in line] for line in grid]
        for k in range(len(grid)):
            for i in range(len(grid[k])):
                nb = [grid[k2][i] for k2 in (k - 1, k + 1) if 0 <= k2 < len(grid)]
                nb += [grid[k][i2] for i2 in (i - 1, i + 1) if 0 <= i2 < len(grid[k])]
                c = Vector((ax, grid[k][i].y, az))
                r_cur = (grid[k][i] - c).length
                r_avg = sum((Vector((p.x, grid[k][i].y, p.z)) - c).length for p in nb) / len(nb)
                r_new = max(r_cur, 0.5 * r_cur + 0.5 * r_avg)
                new[k][i] = c + (grid[k][i] - c).normalized() * r_new
        grid = new
    n = cols + 1
    vs = [p for line in grid for p in line]
    faces = []
    for k in range(len(grid) - 1):
        for i in range(cols):
            a, b = k * n + i, (k + 1) * n + i
            faces.append((a, a + 1, b + 1, b))
    g = Geo().add(vs, faces, mat)
    f0 = [g.v[i] for i in g.f[len(g.f) // 2]]
    fc = sum(f0, Vector()) / len(f0)
    if poly_normal(f0).dot(Vector((fc.x - ax, 0, fc.z - az))) < 0:
        g.f = [tuple(reversed(f)) for f in g.f]
    g = solidify(g, thickness, rim)
    if bevel > 0:
        g = bevel_geo(g, bevel, angle=50)
    return g


def poly_prism(pts2d, center, normal, up, depth, mat="A", bevel=0.0):
    """Extrude a 2D outline (u, v) lying in the plane through `center` facing `normal`
    (u = up x normal ... right, v = up) by depth along the normal (back face at center)."""
    nn = Vector(normal).normalized()
    vv = Vector(up)
    vv = (vv - nn * vv.dot(nn)).normalized()
    uu = vv.cross(nn).normalized()
    c = Vector(center)
    n = len(pts2d)
    back = [c + uu * u + vv * v for u, v in pts2d]
    front = [p + nn * depth for p in back]
    faces = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n + j, n + i))
    g = Geo().add(back + front, faces, mat)
    if not _outward(g):
        g.f = [tuple(reversed(f)) for f in g.f]
    if bevel > 0:
        g = bevel_geo(g, bevel)
    return g


def octagon(r, n=8, phase=0.5):
    return [(r * math.cos(2 * math.pi * (i + phase) / n), r * math.sin(2 * math.pi * (i + phase) / n))
            for i in range(n)]


def rounded_rect(w, h, c, n_corner=1):
    """Chamfered rectangle outline (u, v) centred at 0: w x h, corner chamfer c."""
    hw, hh = w / 2, h / 2
    return [(-hw + c, -hh), (hw - c, -hh), (hw, -hh + c), (hw, hh - c), (hw - c, hh),
            (-hw + c, hh), (-hw, hh - c), (-hw, -hh + c)]


# ---- faceted armour (the prototype pieces' language: big flat planes, chamfers, rims) -------
def facet_tube(p0, p1, rows, ref=(0, 0, -1), keep=None, thickness=0.012, mat="A", cap0=False,
               cap1=False, mat_rim=None):
    """Chamfered-rectangle tube along p0 -> p1, flat-faceted like the user's cuirass / helmet.

    rows: (t, w, d, chamfer[, shift_ref]) with t along the bone (0 at p0, 1 at p1; may go past),
    w across (bone x ref), d along ref, the 45-deg chamfer, and an optional shift toward ref.
    keep: indices of the 8 section sides to keep (open shell); None = closed tube. Side order:
    0 away from ref, 1 corner, 2 the +side (bone x ref), 3 corner, 4 toward ref, 5 corner,
    6 the -side, 7 corner. The shell is solidified inward by thickness, so its cut edges show a
    rim like the prototype's plates.
    """
    p0, p1 = Vector(p0), Vector(p1)
    ax = (p1 - p0).normalized()
    r = Vector(ref)
    r = (r - ax * r.dot(ax)).normalized()
    s = ax.cross(r).normalized()
    rings = []
    for row in rows:
        t, w, d, ch = row[:4]
        shift = row[4] if len(row) > 4 else 0.0
        c = lerp(p0, p1, t) + r * shift
        rings.append([c + s * u + r * v for u, v in rounded_rect(w, d, ch)])
    n = 8
    vs = [p for ring in rings for p in ring]
    faces = []
    sides = range(n) if keep is None else keep
    for k in range(len(rings) - 1):
        a, b = k * n, (k + 1) * n
        for i in sides:
            j = (i + 1) % n
            faces.append((a + i, a + j, b + j, b + i))
    g = Geo().add(vs, faces, mat)
    if keep is None and (cap0 or cap1):
        if cap0:
            g.f.append(tuple(range(n - 1, -1, -1)))
            g.m.append(mat)
        if cap1:
            last = (len(rings) - 1) * n
            g.f.append(tuple(last + i for i in range(n)))
            g.m.append(mat)
    # Outward: away from the bone axis.
    f0 = [g.v[i] for i in g.f[0]]
    fc = sum(f0, Vector()) / len(f0)
    radial = fc - (p0 + ax * (fc - p0).dot(ax))
    if poly_normal(f0).dot(radial) < 0:
        g.f = [tuple(reversed(f)) for f in g.f]
    if thickness > 0 and not (keep is None and (cap0 or cap1)):
        g = solidify(g, thickness, mat_rim)
    g.sharp = 15.0
    return g


def facet_ring(center, w, d, ch, height, thickness, mat="W", ref=(0, 0, -1)):
    """A horizontal chamfered band (belts, collars) centred at `center`."""
    c = Vector(center)
    return facet_tube(c + Vector((0, height / 2, 0)), c - Vector((0, height / 2, 0)),
                      [(0, w, d, ch), (1, w, d, ch)], ref, None, thickness, mat)


def facet_box(c, size, ch, mat="A", x_axis=(1, 0, 0), y_axis=(0, 1, 0)):
    """Box with every edge chamfered (flat) along its long axis: an octagonal prism."""
    m = frame(c, x_axis, y_axis)
    w, h, d = size
    g = facet_tube((0, -h / 2, 0), (0, h / 2, 0), [(0, w, d, ch), (1, w, d, ch)], (0, 0, -1), None, 0.0,
                   mat, cap0=True, cap1=True)
    g = g.transformed(m)
    g.sharp = 15.0
    return g
