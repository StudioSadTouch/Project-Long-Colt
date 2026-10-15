#!/usr/bin/env python3
"""Generate the third-person AnimationLibrary for the player block-out (PB_* node rig).

    python3 tools/character_anims/gen_character_anims.py [--check]

Writes assets/characters/player/anims/character_anims.tres. Pure python + numpy, no Godot.
Rig: the unskinned glb node chain from assets/characters/player/README.md (block-out v4,
0bdacbb). Node-transform tracks (rotation_3d on every joint, position_3d on PB_Pelvis), with
paths relative to the PlayerModel root ("Blockout/BodyMesh/PB_Pelvis/..."). Rest rotations
are identity, so RESET is identity everywhere and additive clips store plain deltas.
Legs and arms are solved with two-bone IK so feet stay planted and hands stay on the weapon.
See /workspace/anims/thirdperson_plan.md for direction and timings. --check prints FK/IK
sanity numbers (crouch head height, IK reach errors) without writing.
"""
import math
import os
import sys

import numpy as np

FPS = 30.0
ROOT = "Blockout/BodyMesh"
P = {
    "Pelvis": ROOT + "/PB_Pelvis",
}
P["Abdomen"] = P["Pelvis"] + "/PB_Abdomen"
P["Chest"] = P["Abdomen"] + "/PB_Chest"
P["Neck"] = P["Chest"] + "/PB_Neck"
P["Head"] = P["Neck"] + "/PB_Head"
for s in "LR":
    P["UpperArm_" + s] = P["Chest"] + "/PB_UpperArm_" + s
    P["Forearm_" + s] = P["UpperArm_" + s] + "/PB_Forearm_" + s
    P["Hand_" + s] = P["Forearm_" + s] + "/PB_Hand_" + s
    P["Thigh_" + s] = P["Pelvis"] + "/PB_Thigh_" + s
    P["Shin_" + s] = P["Thigh_" + s] + "/PB_Shin_" + s
    P["Boot_" + s] = P["Shin_" + s] + "/PB_Boot_" + s

UPPER = ["Abdomen", "Chest", "Neck", "Head", "UpperArm_L", "Forearm_L", "Hand_L",
         "UpperArm_R", "Forearm_R", "Hand_R"]
LOWER = ["Pelvis", "Thigh_L", "Shin_L", "Boot_L", "Thigh_R", "Shin_R", "Boot_R"]
ALL = LOWER[:1] + UPPER + LOWER[1:]

# Local rest offsets (child pivot in parent space), from the glb.
OFF = {
    "Abdomen": (0, 0.07, 0), "Chest": (0, 0.12, 0), "Neck": (0, 0.37, 0), "Head": (0, 0.05, 0),
    "UpperArm_L": (-0.25, 0.24, 0), "Forearm_L": (-0.025, -0.36, 0), "Hand_L": (-0.015, -0.2, 0),
    "UpperArm_R": (0.25, 0.24, 0), "Forearm_R": (0.025, -0.36, 0), "Hand_R": (0.015, -0.2, 0),
    "Thigh_L": (-0.11, -0.05, 0), "Shin_L": (0, -0.37, 0), "Boot_L": (0, -0.39, 0),
    "Thigh_R": (0.11, -0.05, 0), "Shin_R": (0, -0.37, 0), "Boot_R": (0, -0.39, 0),
}
OFF = {k: np.array(v, float) for k, v in OFF.items()}
MARK = {"L": np.array([0.01, -0.055, -0.01]), "R": np.array([-0.01, -0.055, -0.01])}
PELVIS_REST = np.array([0.0, 0.93, 0.0])
HELMET_FROM_HEAD = np.array([0.0, 0.10, 0.0])  # HelmetMesh origin (1.64) above PB_Head (1.54)
EYE_FROM_HEAD = np.array([0.0, 0.08, -0.15])

I3 = np.eye(3)
REPORT = {"ik_err": 0.0, "ik_where": "", "clip": "", "per_clip": {}}


# ---------------------------------------------------------------- math
def rx(d):
    a = math.radians(d); c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def ry(d):
    a = math.radians(d); c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rz(d):
    a = math.radians(d); c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def eul(x=0.0, y=0.0, z=0.0):
    """Godot YXZ order: Ry * Rx * Rz."""
    return ry(y) @ rx(x) @ rz(z)


def axis_angle(axis, deg):
    axis = np.asarray(axis, float); n = np.linalg.norm(axis)
    if n < 1e-9:
        return I3.copy()
    k = axis / n; a = math.radians(deg)
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return I3 + math.sin(a) * K + (1 - math.cos(a)) * K @ K


def norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def min_rot(a, b):
    a = norm(a); b = norm(b); v = np.cross(a, b); c = float(np.dot(a, b))
    if c < -0.9999:
        perp = norm(np.cross(a, [1, 0, 0] if abs(a[0]) < 0.9 else [0, 1, 0]))
        return axis_angle(perp, 180)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return I3 + K + K @ K / (1 + c)


def frame(u, v):
    u = norm(u); v = norm(v - np.dot(v, u) * u); w = np.cross(u, v)
    return np.column_stack([u, v, w])


def quat(m):
    t = np.trace(m)
    if t > 0:
        s = math.sqrt(t + 1.0) * 2
        w = 0.25 * s; x = (m[2, 1] - m[1, 2]) / s; y = (m[0, 2] - m[2, 0]) / s; z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        w = (m[2, 1] - m[1, 2]) / s; x = 0.25 * s; y = (m[0, 1] + m[1, 0]) / s; z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        w = (m[0, 2] - m[2, 0]) / s; x = (m[0, 1] + m[1, 0]) / s; y = 0.25 * s; z = (m[1, 2] + m[2, 1]) / s
    else:
        s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        w = (m[1, 0] - m[0, 1]) / s; x = (m[0, 2] + m[2, 0]) / s; y = (m[1, 2] + m[2, 1]) / s; z = 0.25 * s
    q = np.array([x, y, z, w]); q /= np.linalg.norm(q)
    return q if q[3] >= 0 else -q


def qmat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def slerp_m(a, b, t):
    qa, qb = quat(a), quat(b)
    if np.dot(qa, qb) < 0:
        qb = -qb
    d = float(np.clip(np.dot(qa, qb), -1, 1))
    if d > 0.9995:
        q = qa + t * (qb - qa)
    else:
        th = math.acos(d); q = (math.sin((1 - t) * th) * qa + math.sin(t * th) * qb) / math.sin(th)
    return qmat(q / np.linalg.norm(q))


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def curve(keys, t):
    """keys: [(time, value)], value float or array; smoothstep between keys, clamped."""
    if t <= keys[0][0]:
        return np.array(keys[0][1], float) if not np.isscalar(keys[0][1]) else keys[0][1]
    for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
        if t <= t1:
            u = smooth((t - t0) / (t1 - t0)) if t1 > t0 else 1.0
            if np.isscalar(v0):
                return v0 + (v1 - v0) * u
            return np.array(v0, float) + (np.array(v1, float) - np.array(v0, float)) * u
    v = keys[-1][1]
    return np.array(v, float) if not np.isscalar(v) else v


# ---------------------------------------------------------------- IK
def two_bone(S, Pw, r1, r2, T, rest_pole, pole_bias, where):
    """Root joint at S with parent world rot Pw. Returns (root_local, mid_local, mid_world_rot)."""
    L1, L2 = np.linalg.norm(r1), np.linalg.norm(r2)
    D = T - S; d = np.linalg.norm(D)
    lo, hi = abs(L1 - L2) + 1e-3, L1 + L2 - 1e-3
    err = max(0.0, d - hi, lo - d)
    if err > REPORT["ik_err"]:
        REPORT["ik_err"] = err; REPORT["ik_where"] = where + " in " + REPORT["clip"]
    pc = REPORT["per_clip"]
    if err > 0.005:
        pc[REPORT["clip"] + ":" + where] = max(pc.get(REPORT["clip"] + ":" + where, 0.0), err)
    d = min(max(d, lo), hi); dh = norm(D)
    u_rest = Pw @ norm(r1)
    natural = min_rot(u_rest, dh) @ (Pw @ rest_pole)
    pole = natural + np.asarray(pole_bias, float)
    n = norm(pole - np.dot(pole, dh) * dh)
    a = math.acos(np.clip((L1 * L1 + d * d - L2 * L2) / (2 * L1 * d), -1, 1))
    M = S + L1 * (math.cos(a) * dh + math.sin(a) * n)
    Tc = S + d * dh
    F0 = frame(Pw @ norm(r1), Pw @ rest_pole)
    F1 = frame(M - S, n)
    root_w = F1 @ F0.T @ Pw  # world rotation of the root bone
    a2 = root_w @ norm(r2)
    mid_w = min_rot(a2, Tc - M) @ root_w
    end = M + mid_w @ r2
    solved = np.linalg.norm(end - T)
    if solved - err > REPORT.get("solve_err", 0.0):
        REPORT["solve_err"] = solved - err; REPORT["solve_where"] = where + " in " + REPORT["clip"]
    return Pw.T @ root_w, root_w.T @ mid_w, mid_w


class Pose:
    """Local rotations (3x3) per joint plus the pelvis position (model space)."""

    def __init__(self):
        self.rot = {j: I3.copy() for j in ALL}
        self.pelvis = PELVIS_REST.copy()

    def world(self):
        W = {"Pelvis": (self.rot["Pelvis"], self.pelvis.copy())}
        order = ["Abdomen", "Chest", "Neck", "Head", "UpperArm_L", "Forearm_L", "Hand_L",
                 "UpperArm_R", "Forearm_R", "Hand_R", "Thigh_L", "Shin_L", "Boot_L",
                 "Thigh_R", "Shin_R", "Boot_R"]
        parent = {"Abdomen": "Pelvis", "Chest": "Abdomen", "Neck": "Chest", "Head": "Neck",
                  "UpperArm_L": "Chest", "Forearm_L": "UpperArm_L", "Hand_L": "Forearm_L",
                  "UpperArm_R": "Chest", "Forearm_R": "UpperArm_R", "Hand_R": "Forearm_R",
                  "Thigh_L": "Pelvis", "Shin_L": "Thigh_L", "Boot_L": "Shin_L",
                  "Thigh_R": "Pelvis", "Shin_R": "Thigh_R", "Boot_R": "Shin_R"}
        for j in order:
            Rp, pp = W[parent[j]]
            W[j] = (Rp @ self.rot[j], pp + Rp @ OFF[j])
        return W


# ---------------------------------------------------------------- body solvers
def solve_legs(pose, ankles, foot_rots=(None, None), knee_out=0.15):
    W = pose.world()
    Rp, _ = W["Pelvis"]
    for i, s in enumerate("LR"):
        S = W["Thigh_" + s][1]
        side = -1 if s == "L" else 1
        bias = np.array([side * knee_out, 0, 0])
        th, sh, mid_w = two_bone(S, Rp, OFF["Shin_" + s], OFF["Boot_" + s], np.asarray(ankles[i], float),
                                 np.array([0, 0, -1.0]), bias, "leg_" + s)
        pose.rot["Thigh_" + s] = th
        pose.rot["Shin_" + s] = sh
        fr = foot_rots[i] if foot_rots[i] is not None else I3
        pose.rot["Boot_" + s] = mid_w.T @ fr


def set_spine(pose, ab, ch):
    pose.rot["Abdomen"] = ab
    pose.rot["Chest"] = ch


def look(pose, head_world):
    W = pose.world()
    rel = W["Chest"][0].T @ head_world
    neck = slerp_m(I3, rel, 0.5)
    pose.rot["Neck"] = neck
    pose.rot["Head"] = neck.T @ rel


def solve_arm(pose, s, attach_target, hand_world, pole_bias):
    W = pose.world()
    Rc, _ = W["Chest"]
    S = W["UpperArm_" + s][1]
    hand_pivot = np.asarray(attach_target, float) - hand_world @ MARK[s]
    ua, fa, mid_w = two_bone(S, Rc, OFF["Forearm_" + s], OFF["Hand_" + s], hand_pivot,
                             np.array([0, 0, 1.0]), pole_bias, "arm_" + s)
    pose.rot["UpperArm_" + s] = ua
    pose.rot["Forearm_" + s] = fa
    pose.rot["Hand_" + s] = mid_w.T @ hand_world


def relax_arms(pose, swing=0.0, flare=8.0):
    for s in "LR":
        side = -1 if s == "L" else 1
        pose.rot["UpperArm_" + s] = eul(x=6 + swing * side, z=side * flare)
        pose.rot["Forearm_" + s] = eul(x=18)
        pose.rot["Hand_" + s] = I3.copy()


def shoulder_mid(pose):
    W = pose.world()
    return (W["UpperArm_L"][1] + W["UpperArm_R"][1]) * 0.5


# Weapon holds in the aim frame (origin = shoulder midpoint, -Z along the aim).
HOLDS = {
    "rifle": {"R": (0.14, -0.08, -0.22), "L": (0.05, -0.06, -0.40), "pole_R": (0.5, -0.7, 0.2),
              "pole_L": (-0.2, -1.0, 0.1), "roll_L": -20.0, "mag": (0.0, -0.17, -0.06),
              "handle": (0.06, 0.02, 0.0)},
    "pistol": {"R": (0.07, -0.10, -0.40), "L": (0.03, -0.11, -0.38), "pole_R": (0.6, -0.8, 0.1),
               "pole_L": (-0.6, -0.8, 0.1), "roll_L": -10.0, "mag": (0.0, -0.13, 0.075)},
}
POUCH_W = np.array([-0.17, 0.98, -0.12])  # left front belt pouch, model space (stand)


def upper_aim(pose, weapon, pitch, hold_rot=None, hold_pos=(0, 0, 0), r_override=None,
              l_target=None, l_weight=0.0, head_extra=None, spine_extra=(I3, I3), lower=0.0):
    """Aim pose. pitch degrees (+ up). hold_rot/hold_pos move the weapon in the aim frame.
    r_override: (attach_world, hand_world, weight) blend for the right hand (holster).
    l_target: off-hand world point (blended in with l_weight; None = stay on the weapon)."""
    ab = rx(0.25 * pitch) @ spine_extra[0]
    ch = rx(0.40 * pitch) @ spine_extra[1]
    set_spine(pose, ab, ch)
    A = rx(pitch)
    hw = head_extra if head_extra is not None else I3
    look(pose, A @ hw)
    if weapon == "none":
        relax_arms(pose)
        return
    h = HOLDS[weapon]
    Hr = hold_rot if hold_rot is not None else I3
    O = shoulder_mid(pose) + np.array([0, -lower, 0])
    Wr = A @ Hr
    base = O + A @ np.asarray(hold_pos, float)
    r_att = base + Wr @ np.array(h["R"])
    r_rot = Wr
    if r_override is not None:
        att, rot, w = r_override
        r_att = r_att + (np.asarray(att, float) - r_att) * w
        r_rot = slerp_m(r_rot, rot, w)
    solve_arm(pose, "R", r_att, r_rot, h["pole_R"])
    l_att = base + Wr @ np.array(h["L"])
    l_rot = Wr @ rz(h["roll_L"])
    if l_target is not None and l_weight > 0.0:
        l_att = l_att + (np.asarray(l_target, float) - l_att) * l_weight
    solve_arm(pose, "L", l_att, l_rot, h["pole_L"])


def weapon_point(pose, weapon, pitch, local, hold_rot=None, hold_pos=(0, 0, 0)):
    """World point at `local` (weapon frame, relative to the right-hand attach) for current hold."""
    h = HOLDS[weapon]
    A = rx(pitch); Hr = hold_rot if hold_rot is not None else I3; Wr = A @ Hr
    O = shoulder_mid(pose)
    base = O + A @ np.asarray(hold_pos, float)
    return base + Wr @ (np.array(h["R"]) + np.asarray(local, float))


# ---------------------------------------------------------------- stances
STAND_H = 0.91
FEET_STAND = (np.array([-0.13, 0.12, -0.05]), np.array([0.13, 0.12, 0.07]))
FEET_LOCO = (np.array([-0.12, 0.12, 0.0]), np.array([0.12, 0.12, 0.0]))
CROUCH_PELVIS = np.array([0.0, 0.30, 0.22])
CROUCH_LEAN = -22.0
FEET_CROUCH = (np.array([-0.15, 0.12, -0.06]), np.array([0.15, 0.12, 0.04]))
CROUCH_SPINE = (I3, I3)  # 22 deg torso lean from the pelvis; head ends in the crouch hitbox


def stand_lower(pose, dy=0.0, dx=0.0, dz=0.0, tilt=I3):
    pose.pelvis = np.array([dx, STAND_H + dy, dz])
    pose.rot["Pelvis"] = tilt
    solve_legs(pose, FEET_STAND)


def crouch_lower(pose, dy=0.0, dx=0.0, extra=I3, feet=FEET_CROUCH):
    pose.pelvis = CROUCH_PELVIS + np.array([dx, dy, 0])
    pose.rot["Pelvis"] = rx(CROUCH_LEAN) @ extra
    solve_legs(pose, feet, knee_out=0.3)


def ref_stand():
    p = Pose(); stand_lower(p); return p


def ref_crouch():
    p = Pose(); crouch_lower(p); return p


# ---------------------------------------------------------------- clip container
class Clip:
    def __init__(self, name, length, loop=False, tracks=None, additive=False):
        self.name = name; self.length = length; self.loop = loop
        self.tracks = tracks if tracks is not None else ALL
        self.additive = additive
        self.frames = []  # (t, Pose)

    def sample(self, fn):
        REPORT["clip"] = self.name
        n = max(1, int(round(self.length * FPS)))
        for i in range(n + 1):
            t = min(i / FPS, self.length)
            self.frames.append((t, fn(t)))
        if self.loop:  # exact wrap
            self.frames[-1] = (self.length, self.frames[0][1])
        return self


def clip_from(name, length, fn, loop=False, tracks=None, additive=False):
    return Clip(name, length, loop, tracks, additive).sample(fn)


# ---------------------------------------------------------------- locomotion
DIRS = {"f": 0, "fr": 45, "r": 90, "br": 135, "b": 180, "bl": -135, "l": -90, "fl": -45}
CYCLE = 0.6  # walk, run and crouch-walk share one cycle length so blendspaces stay in phase


def move_dir(deg):
    a = math.radians(deg)
    return np.array([math.sin(a), 0.0, -math.cos(a)])


def gait(t, d, speed, beta, lift, feet, pelvis_fn, foot_pitch=12.0):
    lateral = abs(d[0])
    stride = speed * beta * CYCLE * (1.0 - 0.45 * lateral)
    ankles, rots = [], []
    for i, off in enumerate((0.0, 0.5)):
        ph = (t / CYCLE + off) % 1.0
        base = feet[i] + np.array([(-1 if i == 0 else 1) * 0.04 * lateral, 0, 0])
        if ph < beta:
            s = ph / beta; rel = (0.5 - s) * stride; up = 0.0; pitch = 0.0
        else:
            s = (ph - beta) / (1 - beta); rel = (-0.5 + smooth(s)) * stride
            up = lift * math.sin(math.pi * s); pitch = foot_pitch * math.sin(math.pi * s)
        ankles.append(base + d * rel + np.array([0, up, 0]))
        rots.append(rx(pitch))
    pose = Pose()
    pelvis_fn(pose, t)
    solve_legs(pose, ankles, rots)
    return pose


def stand_gait_pelvis(d, bob, sway, yaw, lean, h):
    k = np.array([-d[2], 0, d[0]])

    def fn(pose, t):
        w = 2 * math.pi * t / CYCLE
        pose.pelvis = np.array([sway * math.cos(w), h + bob * math.cos(2 * w), 0.0])
        pose.rot["Pelvis"] = ry(yaw * math.sin(w)) @ axis_angle(k, -lean) @ rz(1.5 * math.cos(w))
    return fn


def loco_clip(name, deg, speed, beta, lift, h, bob, sway, yaw, lean):
    d = move_dir(deg)

    def fn(t):
        p = gait(t, d, speed, beta, lift, FEET_LOCO, stand_gait_pelvis(d, bob, sway, yaw, lean, h))
        upper_aim(p, "rifle", 0.0)
        return p
    return clip_from(name, CYCLE, fn, loop=True)


def crouch_loco_clip(name, deg):
    d = move_dir(deg)

    def pel(pose, t):
        w = 2 * math.pi * t / CYCLE
        pose.pelvis = CROUCH_PELVIS + np.array([0.012 * math.cos(w), 0.02 + 0.006 * math.cos(2 * w), 0])
        pose.rot["Pelvis"] = rx(CROUCH_LEAN) @ ry(3 * math.sin(w))

    def fn(t):
        p = gait(t, d, 3.2, 0.31, 0.06, FEET_CROUCH, pel, foot_pitch=8.0)
        upper_aim(p, "rifle", 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
        return p
    return clip_from(name, CYCLE, fn, loop=True)


# ---------------------------------------------------------------- full-body one-offs
def idle_fn(t):
    p = Pose()
    w = 2 * math.pi * t / 2.0
    stand_lower(p, dy=0.004 * math.sin(2 * w), dx=0.012 * math.sin(w), tilt=rz(-0.8 * math.sin(w)))
    upper_aim(p, "rifle", 0.0, spine_extra=(I3, rx(0.6 * math.sin(2 * w))))
    return p


def crouch_idle_fn(t):
    p = Pose()
    w = 2 * math.pi * t / 2.0
    crouch_lower(p, dy=0.004 * math.sin(2 * w), dx=0.008 * math.sin(w))
    upper_aim(p, "rifle", 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
    return p


def stop_fn(t):
    p = Pose()
    dy = curve([(0, -0.03), (0.12, -0.035), (0.3, 0.0)], t)
    tilt = curve([(0, -4.0), (0.12, 2.0), (0.22, -0.5), (0.3, 0.0)], t)
    stand_lower(p, dy=dy, dz=curve([(0, -0.03), (0.12, 0.01), (0.3, 0.0)], t), tilt=rx(tilt))
    upper_aim(p, "rifle", 0.0)
    return p


def jump_fn(t):
    p = Pose()
    h = curve([(0, STAND_H), (0.06, 0.84), (0.2, 0.95)], t)
    p.pelvis = np.array([0, h, 0]); p.rot["Pelvis"] = rx(curve([(0, 0.0), (0.06, -6.0), (0.2, 2.0)], t))
    lift = curve([(0, 0.0), (0.12, 0.0), (0.2, 0.18)], t)
    tuck = curve([(0.12, 0.0), (0.2, 0.06)], t)
    feet = (FEET_STAND[0] + np.array([0, lift, -tuck]), FEET_STAND[1] + np.array([0, lift * 0.8, 0.02]))
    solve_legs(p, feet, (rx(-25 * min(1, t / 0.12)) if t < 0.14 else rx(10), None))
    upper_aim(p, "rifle", 0.0)
    return p


def fall_fn(t):
    p = Pose()
    w = 2 * math.pi * t / 0.6
    p.pelvis = np.array([0, 0.95, 0]); p.rot["Pelvis"] = rx(3.0)
    feet = (np.array([-0.12, 0.38 + 0.02 * math.sin(w), -0.14 + 0.02 * math.cos(w)]),
            np.array([0.12, 0.33 - 0.02 * math.sin(w), 0.06 - 0.02 * math.cos(w)]))
    solve_legs(p, feet, (rx(12), rx(-8)))
    upper_aim(p, "rifle", 0.0, spine_extra=(rx(-3), I3))
    return p


def land_fn(t):
    p = Pose()
    stand_lower(p, dy=curve([(0, -0.04), (0.08, -0.12), (0.25, 0.0)], t),
                tilt=rx(curve([(0, -3.0), (0.08, -7.0), (0.25, 0.0)], t)))
    upper_aim(p, "rifle", 0.0, spine_extra=(rx(curve([(0, -2.0), (0.08, 3.0), (0.25, 0.0)], t)), I3))
    return p


def slide_fn(t):
    p = Pose()
    e = smooth(t / 0.13)
    pel = np.array([0, STAND_H, 0]) + (np.array([0.0, 0.44, 0.06]) - np.array([0, STAND_H, 0])) * e
    p.pelvis = pel; p.rot["Pelvis"] = rx(16 * e) @ ry(-12 * e)
    feet_a = FEET_STAND
    feet_b = (np.array([-0.08, 0.14, -0.58]), np.array([0.17, 0.13, 0.22]))
    feet = tuple(feet_a[i] + (feet_b[i] - feet_a[i]) * e for i in range(2))
    solve_legs(p, feet, (rx(28 * e), rx(-40 * e)), knee_out=0.35)
    upper_aim(p, "rifle", 0.0, spine_extra=(rx(-10 * e) @ ry(8 * e), rx(-6 * e)))
    return p


DEATH = {
    # name: (pelvis end pos, pelvis end rot, arm flare sign)
    "front": (np.array([0.0, 0.15, 0.78]), rx(86) @ rz(8)),
    "back": (np.array([0.0, 0.17, -0.78]), rx(-86) @ rz(-6)),
    "left": (np.array([0.78, 0.17, 0.05]), rz(-86) @ rx(6)),
    "right": (np.array([-0.78, 0.17, 0.05]), rz(86) @ rx(-6)),
}
DEATH_LEN = {"front": 0.45, "back": 0.45, "left": 0.4, "right": 0.4}


def death_clip(key):
    end_pos, end_rot = DEATH[key]
    start = idle_fn(0.0)
    length = DEATH_LEN[key]
    end_locals = {
        "Abdomen": rx(-6 if key == "front" else 6), "Chest": rx(-4 if key == "front" else 5),
        "Neck": ry(15), "Head": ry(20) @ rx(-10),
        "UpperArm_L": eul(x=40, z=-55), "Forearm_L": eul(x=25), "Hand_L": I3,
        "UpperArm_R": eul(x=-20, z=60), "Forearm_R": eul(x=35), "Hand_R": I3,
    }
    if key in ("left", "right"):  # lying on a side: arms reach forward along the ground, not into it
        down = "R" if key == "left" else "L"
        up = "L" if down == "R" else "R"
        sd = 1 if down == "R" else -1
        end_locals.update({"UpperArm_" + down: eul(x=20, z=sd * 165), "Forearm_" + down: eul(x=35),
                           "UpperArm_" + up: eul(x=55, z=-sd * 10), "Forearm_" + up: eul(x=40)})
    end_locals.update({
        "Thigh_L": eul(x=18, z=-6), "Shin_L": eul(x=-30), "Boot_L": eul(x=20),
        "Thigh_R": eul(x=4, z=8), "Shin_R": eul(x=-10), "Boot_R": eul(x=15),
    })

    legs = [j for j in LOWER if j != "Pelvis"]

    def fn(t):
        p = Pose()
        buckle = smooth(t / 0.12)
        fall = (min(max((t - 0.08) / (length - 0.1), 0.0), 1.0)) ** 2  # gravity ease-in
        settle = math.sin(math.pi * min(max((t - (length - 0.04)) / 0.04, 0), 1)) * 0.015
        ang = fall * 90.0
        y0 = STAND_H - 0.14 * buckle
        y = end_pos[1] + (y0 - end_pos[1]) * math.cos(math.radians(ang)) + settle
        h = end_pos * math.sin(math.radians(ang))
        p.pelvis = np.array([h[0], y, h[2]])
        p.rot["Pelvis"] = slerp_m(start.rot["Pelvis"], end_rot, fall)
        # Knees buckle with the feet still planted, then the legs go limp as the body topples.
        planted = Pose(); planted.pelvis = p.pelvis.copy(); planted.rot["Pelvis"] = p.rot["Pelvis"]
        saved = dict(REPORT, per_clip=dict(REPORT["per_clip"]))
        solve_legs(planted, FEET_STAND)  # may over-reach while toppling; blended out, so don't report it
        REPORT.update(saved)
        limp = min(1.0, fall * 1.6)
        for j, m in end_locals.items():
            if j in legs:
                p.rot[j] = slerp_m(planted.rot[j], m, limp)
            else:
                p.rot[j] = slerp_m(start.rot[j], m, min(1.0, 0.4 * buckle + 0.6 * fall))
        lift_clear(p)
        return p
    return clip_from("death_" + key, length, fn)


def lift_clear(p, clearance=0.03):
    """Raise the pelvis so no joint (boots: soles) dips below the floor."""
    W = p.world()
    low = min((pos + R @ np.array([0, -0.12, 0]))[1] if j.startswith("Boot") else pos[1]
              for j, (R, pos) in W.items())
    if low < clearance:
        p.pelvis = p.pelvis + np.array([0, clearance - low, 0])


# ---------------------------------------------------------------- upper-body sets
def aim_clip(weapon, name, pitch):
    def fn(t):
        p = ref_stand(); upper_aim(p, weapon, pitch); return p
    return clip_from(name, 1.0 / FPS, fn, tracks=UPPER)


AIM_PITCH = 70.0  # pose pitch at blend +-1 (driver maps aim pitch / 70 deg, clamped)


def crouch_additive(weapon):
    s = ref_stand(); upper_aim(s, weapon, 0.0)
    c = ref_crouch(); upper_aim(c, weapon, 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
    d = Pose()
    for j in UPPER:
        d.rot[j] = s.rot[j].T @ c.rot[j]
    return clip_from("crouch_upper_" + weapon, 1.0 / FPS, lambda t: d, tracks=UPPER, additive=True)


def additive_clip(name, length, peak, deltas):
    """deltas: {joint: (x, y, z) degrees at peak}; rises to peak, decays to zero."""
    def fn(t):
        p = Pose()
        if t <= peak:
            k = smooth(t / peak)
        else:
            k = 1.0 - smooth((t - peak) / (length - peak))
        for j, (x, y, z) in deltas.items():
            p.rot[j] = eul(x * k, y * k, z * k)
        return p
    return clip_from(name, length, fn, tracks=list(deltas.keys()), additive=True)


def reload_clip(weapon, empty):
    L = 2.1 if weapon == "rifle" else 1.2
    name = "reload_%s%s" % (weapon, "_empty" if empty else "")
    h = HOLDS[weapon]
    if weapon == "rifle":
        roll = [(0, 0), (0.3, 28), (1.75, 28), (2.0, 0)]
        pitch = [(0, 0), (0.3, -12), (1.75, -12), (2.0, 0)]
        pos = [(0, (0, 0, 0)), (0.3, (-0.03, -0.06, 0.05)), (1.75, (-0.03, -0.06, 0.05)), (2.0, (0, 0, 0))]
        head = [(0, 0), (0.35, -22), (1.6, -22), (1.95, 0)]
        mag = np.array(h["mag"])
        if empty:
            lkeys = [(0.0, ("hold",)), (0.25, ("hold",)), (0.55, ("b", POUCH_W)), (0.75, ("w", mag + [-0.05, -0.2, 0.03])),
                     (1.05, ("w", mag + [0, -0.06, -0.01])), (1.26, ("w", mag)), (1.29, ("w", mag)),
                     (1.5, ("w", np.array(h["handle"]) + [0.04, 0.0, 0.0])), (1.62, ("w", np.array(h["handle"]) + [0.04, 0.0, 0.07])),
                     (1.68, ("w", np.array(h["handle"]) + [0.05, 0.02, 0.06])), (1.9, ("hold",)), (2.1, ("hold",))]
        else:
            lkeys = [(0.0, ("hold",)), (0.35, ("w", mag)), (0.65, ("w", mag + [-0.04, -0.16, 0.02])), (0.8, ("b", POUCH_W)),
                     (1.0, ("w", mag + [-0.05, -0.2, 0.03])), (1.15, ("w", mag + [0, -0.06, -0.01])), (1.26, ("w", mag)),
                     (1.29, ("w", mag)), (1.45, ("w", mag + [0, -0.02, 0])), (1.75, ("hold",)), (2.1, ("hold",))]
    else:
        roll = [(0, 0), (0.12, 30), (0.95, 30), (1.1, 0)]
        pitch = [(0, 0), (0.12, 8), (0.95, 8), (1.1, 0)]
        pos = [(0, (0, 0, 0)), (0.12, (0.0, -0.03, 0.08)), (0.95, (0.0, -0.03, 0.08)), (1.1, (0, 0, 0))]
        head = [(0, 0), (0.15, -15), (0.9, -15), (1.1, 0)]
        mag = np.array(h["mag"])
        if empty:
            lkeys = [(0.0, ("hold",)), (0.12, ("hold",)), (0.35, ("b", POUCH_W)), (0.45, ("w", mag + [-0.04, -0.16, 0.02])),
                     (0.62, ("w", mag + [0, -0.04, 0])), (0.744, ("w", mag)), (0.777, ("w", mag)),
                     (1.0, ("hold",)), (1.2, ("hold",))]
        else:
            lkeys = [(0.0, ("hold",)), (0.15, ("w", mag)), (0.33, ("w", mag + [-0.03, -0.14, 0.02])), (0.4, ("b", POUCH_W)),
                     (0.45, ("w", mag + [-0.04, -0.16, 0.02])), (0.62, ("w", mag + [0, -0.04, 0])), (0.744, ("w", mag)),
                     (0.777, ("w", mag)), (0.95, ("hold",)), (1.2, ("hold",))]

    def left_point(p, key, Hr, hp):
        if key[0] == "hold":
            return None
        if key[0] == "b":
            return np.asarray(key[1], float)
        return weapon_point(p, weapon, 0.0, key[1], Hr, hp)

    def fn(t):
        p = ref_stand()
        Hr = rx(curve(pitch, t)) @ rz(-curve(roll, t)); hp = curve(pos, t)
        # temporarily solve to get the shoulder frame for weapon points
        upper_aim(p, weapon, 0.0, Hr, hp, head_extra=rx(curve(head, t)))
        for (t0, k0), (t1, k1) in zip(lkeys, lkeys[1:]):
            if t <= t1:
                u = smooth((t - t0) / (t1 - t0)) if t1 > t0 else 1.0
                a = left_point(p, k0, Hr, hp); b = left_point(p, k1, Hr, hp)
                hold_pt = weapon_point(p, weapon, 0.0, np.array(h["L"]) - np.array(h["R"]), Hr, hp)
                a = hold_pt if a is None else a; b = hold_pt if b is None else b
                target = a + (b - a) * u
                upper_aim(p, weapon, 0.0, Hr, hp, l_target=target, l_weight=1.0, head_extra=rx(curve(head, t)))
                break
        return p
    return clip_from(name, L, fn, tracks=UPPER)


def melee_clip(weapon):
    if weapon == "rifle":
        yaw = [(0, 0), (0.067, 25), (0.1, -55), (0.15, -52), (0.4, -10), (0.55, 3), (0.7, 0)]
        pit = [(0, 0), (0.067, 10), (0.1, 12), (0.15, 12), (0.4, 3), (0.7, 0)]
        rol = [(0, 0), (0.067, -10), (0.1, 35), (0.15, 33), (0.4, 6), (0.7, 0)]
        pos = [(0, (0, 0, 0)), (0.067, (0.08, 0.04, 0.08)), (0.1, (-0.15, 0.05, -0.2)), (0.15, (-0.14, 0.05, -0.19)),
               (0.4, (-0.03, 0.01, -0.03)), (0.7, (0, 0, 0))]
        ab = [(0, 0), (0.067, 10), (0.1, -25), (0.15, -24), (0.4, -5), (0.7, 0)]
        lrel = None
    else:
        yaw = [(0, 0), (0.067, 8), (0.1, -15), (0.15, -14), (0.3, -3), (0.55, 0)]
        pit = [(0, 0), (0.067, 25), (0.1, -50), (0.15, -48), (0.3, -8), (0.42, 2), (0.55, 0)]
        rol = [(0, 0), (0.1, 20), (0.15, 19), (0.3, 4), (0.55, 0)]
        pos = [(0, (0, 0, 0)), (0.067, (0.02, 0.08, 0.05)), (0.1, (-0.05, -0.05, -0.06)), (0.15, (-0.05, -0.05, -0.055)),
               (0.3, (-0.01, 0, -0.02)), (0.55, (0, 0, 0))]
        ab = [(0, 0), (0.067, 6), (0.1, -15), (0.15, -14), (0.3, -3), (0.55, 0)]
        lrel = [(0, 0.0), (0.067, 1.0), (0.3, 1.0), (0.45, 0.0)]

    def fn(t):
        p = ref_stand()
        Hr = ry(curve(yaw, t)) @ rx(curve(pit, t)) @ rz(-curve(rol, t))
        se = (ry(curve(ab, t)), ry(0.5 * curve(ab, t)))
        if lrel is None:
            upper_aim(p, weapon, 0.0, Hr, curve(pos, t), spine_extra=se)
        else:
            upper_aim(p, weapon, 0.0, Hr, curve(pos, t), spine_extra=se,
                      l_target=np.array([-0.2, 1.18, -0.22]), l_weight=curve(lrel, t))
        return p
    return clip_from("melee_" + weapon, 0.8, fn, tracks=UPPER)


HOLSTER = {
    # attach point and hand orientation at the holster (model space, stand)
    "rifle": (np.array([0.14, 1.66, 0.06]), rx(80) @ rz(-25)),
    "pistol": (np.array([0.22, 0.86, 0.02]), rx(-75)),
}


def switch_clip(weapon):
    L = 0.5 if weapon == "rifle" else 0.3
    att, rot = HOLSTER[weapon]
    w = [(0, 0.0), (0.5 * L, 1.0), (0.55 * L, 1.0), (L, 0.0)]
    lw = [(0, 0.0), (0.2 * L, 1.0), (0.8 * L, 1.0), (L, 0.0)]

    def fn(t):
        p = ref_stand()
        upper_aim(p, weapon, 0.0, r_override=(att, rot, curve(w, t)),
                  l_target=np.array([-0.2, 1.05, -0.12]), l_weight=curve(lw, t),
                  head_extra=rx(-10 * curve(w, t)))
        return p
    return clip_from("switch_" + weapon, L, fn, tracks=UPPER)


# ---------------------------------------------------------------- writer
def fmt(x):
    s = "%.5g" % x
    return "0" if s in ("-0", "0") else s


def write(clips, path):
    out = []
    ids = []
    for c in clips:
        cid = "Animation_" + c.name
        ids.append((c.name, cid))
        out.append('[sub_resource type="Animation" id="%s"]' % cid)
        out.append('resource_name = &"%s"' % c.name)
        out.append("length = %s" % fmt(c.length))
        if c.loop:
            out.append("loop_mode = 1")
        ti = 0
        tracks = list(c.tracks)
        if "Pelvis" in tracks and not c.additive:
            vals = [(t, p.pelvis) for t, p in c.frames]
            if all(np.allclose(v, vals[0][1], atol=1e-5) for _, v in vals):
                vals = vals[:1]
            flat = []
            for t, v in vals:
                flat += [fmt(t), "1", fmt(v[0]), fmt(v[1]), fmt(v[2])]
            out += _track(ti, "position_3d", P["Pelvis"], flat); ti += 1
        for j in tracks:
            qs = [(t, quat(p.rot[j])) for t, p in c.frames]
            for k in range(1, len(qs)):  # keep hemisphere continuity
                if np.dot(qs[k][1], qs[k - 1][1]) < 0:
                    qs[k] = (qs[k][0], -qs[k][1])
            if all(np.allclose(q, qs[0][1], atol=1e-5) for _, q in qs):
                qs = qs[:1]
            flat = []
            for t, q in qs:
                flat += [fmt(t), "1"] + [fmt(x) for x in q]
            out += _track(ti, "rotation_3d", P[j], flat); ti += 1
        out.append("")
    out.append("[resource]")
    out.append("_data = {")
    out.append(",\n".join('&"%s": SubResource("%s")' % (n, i) for n, i in ids))
    out.append("}")
    head = '[gd_resource type="AnimationLibrary" load_steps=%d format=3]\n\n' % (len(clips) + 1)
    text = head + "\n".join(out) + "\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return len(text)


def _track(i, kind, path, flat):
    return ['tracks/%d/type = "%s"' % (i, kind), "tracks/%d/imported = false" % i,
            "tracks/%d/enabled = true" % i, 'tracks/%d/path = NodePath("%s")' % (i, path),
            "tracks/%d/interp = 1" % i, "tracks/%d/loop_wrap = true" % i,
            "tracks/%d/keys = PackedFloat32Array(%s)" % (i, ", ".join(flat))]


def build():
    clips = [clip_from("RESET", 1.0 / FPS, lambda t: Pose())]
    clips.append(clip_from("idle", 2.0, idle_fn, loop=True))
    for k, deg in DIRS.items():
        clips.append(loco_clip("walk_" + k, deg, 3.5, 0.24, 0.09, 0.88, 0.008, 0.02, 4.0, 2.0))
    for k, deg in DIRS.items():
        clips.append(loco_clip("run_" + k, deg, 7.5, 0.12, 0.16, 0.84, 0.015, 0.015, 6.0, 5.0))
    clips.append(clip_from("stop_settle", 0.3, stop_fn))
    clips.append(clip_from("crouch_idle", 2.0, crouch_idle_fn, loop=True))
    for k, deg in DIRS.items():
        clips.append(crouch_loco_clip("crouch_walk_" + k, deg))
    clips.append(clip_from("jump_start", 0.2, jump_fn))
    clips.append(clip_from("fall", 0.6, fall_fn, loop=True))
    clips.append(clip_from("land", 0.25, land_fn))
    clips.append(clip_from("slide", 0.5, slide_fn))
    for w in ("rifle", "pistol", "none"):
        clips.append(aim_clip(w, "aim_%s_up" % w, AIM_PITCH))
        clips.append(aim_clip(w, "aim_%s_mid" % w, 0.0))
        clips.append(aim_clip(w, "aim_%s_down" % w, -AIM_PITCH))
        clips.append(crouch_additive(w))
    clips.append(additive_clip("fire_rifle", 0.1, 0.02, {"Chest": (2.5, 0, 0), "Hand_R": (3, 0, 0),
                                                          "Hand_L": (2, 0, 0)}))
    clips.append(additive_clip("fire_pistol", 0.2, 0.03, {"Forearm_R": (4, 0, 0), "Forearm_L": (4, 0, 0),
                                                           "Hand_R": (10, 0, 0), "Hand_L": (10, 0, 0)}))
    for w in ("rifle", "pistol"):
        clips.append(reload_clip(w, False))
        clips.append(reload_clip(w, True))
        clips.append(melee_clip(w))
        clips.append(switch_clip(w))
    flinch = {"front": {"Abdomen": (3, 0, 0), "Chest": (6, 0, 0), "Head": (5, 0, 0)},
              "back": {"Abdomen": (-3, 0, 0), "Chest": (-6, 0, 0), "Head": (-5, 0, 0)},
              "left": {"Abdomen": (0, -2, -2), "Chest": (0, -4, -5), "Head": (0, 0, -6)},
              "right": {"Abdomen": (0, 2, 2), "Chest": (0, 4, 5), "Head": (0, 0, 6)}}
    for k, v in flinch.items():
        clips.append(additive_clip("flinch_" + k, 0.18, 0.05, v))
    for k in ("front", "back", "left", "right"):
        clips.append(death_clip(k))
    return clips


def check():
    c = ref_crouch(); upper_aim(c, "rifle", 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
    W = c.world()
    R, hp = W["Head"]
    print("crouch: pelvis", np.round(c.pelvis, 3), "helmet centre", np.round(hp + R @ HELMET_FROM_HEAD, 3),
          "eye", np.round(hp + R @ EYE_FROM_HEAD, 3), "(target helmet 0.97, eye 0.95)")
    s = ref_stand(); upper_aim(s, "rifle", 0.0); W = s.world(); R, hp = W["Head"]
    print("stand : helmet centre", np.round(hp + R @ HELMET_FROM_HEAD, 3), "(rest 1.64)")
    lean = math.degrees(math.atan2(-(W["Neck"][1] - W["Abdomen"][1])[2], (W["Neck"][1] - W["Abdomen"][1])[1]))
    W = c.world()
    v = W["Neck"][1] - W["Abdomen"][1]
    print("crouch torso lean (deg fwd):", round(math.degrees(math.atan2(-v[2], v[1])), 1), "stand:", round(lean, 1))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.normpath(os.path.join(here, "..", ".."))
    clips = build()
    check()
    print("max IK reach error %.3f m at %s" % (REPORT["ik_err"], REPORT["ik_where"]))
    print("max IK solve error %.4f m at %s" % (REPORT.get("solve_err", 0.0), REPORT.get("solve_where", "")))
    for k, v in sorted(REPORT["per_clip"].items()):
        print("  IK clamp %.3f m  %s" % (v, k))
    if "--check" in sys.argv:
        return
    path = os.path.join(repo, "assets/characters/player/anims/character_anims.tres")
    size = write(clips, path)
    print("wrote %s (%d clips, %.0f KB)" % (path, len(clips), size / 1024))
    for c in clips:
        print("  %-22s %5.3f s %s%s" % (c.name, c.length, "loop" if c.loop else "", " additive" if c.additive else ""))


if __name__ == "__main__":
    main()
