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
        self.tr = {}  # joint -> extra translation in the parent's space (Abdomen, Chest)

    def copy(self):
        p = Pose(); p.pelvis = self.pelvis.copy(); p.rot = dict(self.rot); p.tr = dict(self.tr)
        return p

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
            off = OFF[j] + self.tr[j] if j in self.tr else OFF[j]
            W[j] = (Rp @ self.rot[j], pp + Rp @ off)
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


def look(pose, head_world, neck_share=0.5):
    W = pose.world()
    rel = W["Chest"][0].T @ head_world
    neck = slerp_m(I3, rel, neck_share)
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
    # v1.6 melee holds. "rot": the hand's turn in the aim frame (the prop's -Z follows it);
    # "pitch_share": how much of the aim pitch the hold follows (a guard stays a guard).
    # Longsword side guard: sword hand low at the right hip, blade angled up and forward and a
    # little out; the off hand up in a loose fist guard in front of the left chest.
    "sword": {"R": (0.25, -0.50, -0.16), "L": (-0.13, -0.24, -0.30), "pole_R": (0.9, -0.4, 0.4),
              "pole_L": (-0.7, -0.7, 0.1), "roll_L": 0.0, "rot": None,  # set from SWORD_TILT below
              "pitch_share": 0.35, "free_L": True},
    # Gravity hammer at port arms: two hands on the haft across the body, head up by the left
    # shoulder. "L" is filled in below from the prop's haft line.
    "hammer": {"R": (0.17, -0.46, -0.22), "L": (0.0, 0.0, 0.0), "pole_R": (0.7, -0.7, 0.2),
               "pole_L": (-0.4, -1.0, 0.2), "roll_L": 0.0, "rot": rz(38.0) @ rx(-8.0),
               "pitch_share": 0.5},
}
# The hammer prop's haft runs up this line from the grip (tools/melee_weapons: (-0.12, 0.95,
# -0.28) normalised), and the third-person prop is scaled 1.4: the off hand sits 0.45 m up it.
HAMMER_HAFT = np.array([-0.12, 0.95, -0.28]) / np.linalg.norm([-0.12, 0.95, -0.28])
HAMMER_L_UP = 0.45
HOLDS["hammer"]["L"] = tuple(np.array(HOLDS["hammer"]["R"]) + HOLDS["hammer"]["rot"] @ (HAMMER_HAFT * HAMMER_L_UP))
# Longsword side guard: the blade ends 51 deg up and 8 deg out; the scene already tilts it by
# SWORD_TILT (its first-person rest), so the hand turns by the rest.
SWORD_GUARD = ry(-12.0) @ rx(42.0) @ ry(4.0) @ rx(9.0)
SWORD_TILT = ry(-6.0) @ rx(50.0)  # tools/melee_weapons: the scene's blade frame (side guard)
HOLDS["sword"]["rot"] = SWORD_GUARD @ SWORD_TILT.T
POUCH_W = np.array([-0.17, 0.98, -0.12])  # left front belt pouch, model space (stand)

# v1.7 bladed stance (right-handed): the chest turns right of the aim line, left shoulder
# forward, by this many degrees per weapon (abdomen STANCE_AB_SHARE of it, chest the rest).
# The hands keep their aim-frame holds, so guns still point down the aim line; the head keeps
# facing it. A shouldered rifle blades the most, a two-hand pistol less, the sword guard most.
STANCE = {"rifle": 22.0, "pistol": 14.0, "sword": 28.0, "hammer": 20.0, "none": 0.0}
STANCE_AB_SHARE = 0.4


def stance_spine(weapon):
    """(abdomen, chest) yaw rotations of the bladed stance for `weapon`."""
    y = -STANCE.get(weapon, 0.0)  # negative yaw turns right: left shoulder forward
    return ry(STANCE_AB_SHARE * y), ry((1.0 - STANCE_AB_SHARE) * y)


# v1.3 aim pitch: a share of the pitch goes into the spine (abdomen AIM_SPLIT, chest the
# rest), the remainder into neck (AIM_NECK_SHARE) and head. Pitching the spine moves PB_Head,
# so the pitched poses counter-translate PB_Abdomen / PB_Chest (position tracks) to pitch the
# spine about a pivot at the head: the head keeps its pelvis-space position, which holds for
# any pelvis lean the lower body brings (run 8 deg, crouch 22 deg); a vertical-only fix does
# not, it misses by the horizontal head shift times sin(lean). The vertical part is split
# between abdomen and chest so the waist seams stay closed, the horizontal part goes on the
# chest within what its bigger box keeps covering over the abdomen (block-out overlaps:
# abdomen bottom 3 cm into the pelvis, chest bottom 2 cm into the abdomen; chest box overhangs
# the abdomen 8.4 cm in front, 1.7 cm behind, 7.6 cm per side). Whatever the chest can't take
# stays as residual. Up and down shares are searched separately at build time
# (find_aim_spine_share): the largest share whose combined worst case (combined_report) passes.
AIM_SPLIT = 0.4
TRANSLATED = ("Abdomen", "Chest")  # joints with position tracks besides the pelvis
AIM_NECK_SHARE = 0.15
AIM_SPINE_SHARE = {"up": 0.0, "down": 0.0}  # set by find_aim_spine_share()
PELVIS_TOP, AB_BOTTOM, AB_TOP, CHEST_BOTTOM = 0.07, -0.03, 0.14, 0.0  # mesh extents, local y
AB_FOOT = [(x, z) for x in (-0.152, 0.152) for z in (-0.11, 0.11)]  # abdomen box footprint
CHEST_SHIFT_Z = (-0.017, 0.084)  # chest shift over the abdomen (abdomen space) that stays covered
CHEST_SHIFT_X = 0.076
# How far a single layer may slide the chest back over the abdomen to keep the head on its
# pivot (waist shear). The rest of the horizontal head shift stays, and with a pelvis lean it
# turns into a little height change, which the combined check bounds.
CHEST_SHEAR_BACK = 0.06


def seam_openings(pose):
    """(pelvis/abdomen, abdomen/chest, chest coverage) in m: >0 means a box lifts off the one
    below, or the chest no longer covers the abdomen top."""
    Ra, ta = pose.rot["Abdomen"], pose.tr.get("Abdomen", np.zeros(3))
    Rc, tc = pose.rot["Chest"], pose.tr.get("Chest", np.zeros(3))
    oa = max((OFF["Abdomen"] + ta + Ra @ np.array([x, AB_BOTTOM, z]))[1] for x, z in AB_FOOT) - PELVIS_TOP
    oc = max((OFF["Chest"] + tc + Rc @ np.array([x, CHEST_BOTTOM, z]))[1] for x, z in AB_FOOT) - AB_TOP
    cov = max(tc[2] - CHEST_SHIFT_Z[1], CHEST_SHIFT_Z[0] - tc[2], abs(tc[0]) - CHEST_SHIFT_X, 0.0)
    return oa, oc, cov


def head_in_pelvis(pose):
    W = pose.world()
    Rp, pp = W["Pelvis"]
    return Rp.T @ (W["Head"][1] - pp)


def compensate_head(pose, target):
    """Translate PB_Abdomen / PB_Chest so PB_Head is back at `target` (pelvis space)."""
    pose.tr.pop("Abdomen", None); pose.tr.pop("Chest", None)
    d = np.asarray(target, float) - head_in_pelvis(pose)
    if np.linalg.norm(d) < 1e-6:
        return
    Ra = pose.rot["Abdomen"]
    dz = min(max(d[2], CHEST_SHIFT_Z[0]), CHEST_SHEAR_BACK)
    best = None
    for k in np.linspace(0.0, 1.0, 41):
        q = pose.copy()
        q.tr["Abdomen"] = np.array([0.0, d[1] * k, 0.0])
        q.tr["Chest"] = Ra.T @ np.array([0.0, d[1] * (1 - k), dz])
        m = max(seam_openings(q)[:2])
        if best is None or m < best[0]:
            best = (m, q.tr["Abdomen"], q.tr["Chest"])
    pose.tr["Abdomen"], pose.tr["Chest"] = best[1], best[2]


def find_aim_spine_share(lower, pump, crouch_delta):
    """Per direction, the largest spine share (1 % steps, every smaller share passing too) whose
    aim at half and full pitch, for every weapon hold, passes the combined worst case on the
    given lower-body clips (head windows, seams)."""
    for key, sg in (("up", 1.0), ("down", -1.0)):
        best = 0.0
        for k in range(0, 61):
            AIM_SPINE_SHARE[key] = k * 0.01
            aims = []
            # Every weapon's hold (v1.7: they blade by different amounts, which moves the head
            # differently), so the share found is safe for all of them.
            for weapon in ("rifle", "pistol", "none", "sword", "hammer"):
                for x in (0.5, 1.0):
                    p = ref_stand(); upper_aim(p, weapon, sg * x * AIM_PITCH); aims.append((sg * x, p))
            res = combined_eval(lower, aims, crouch_delta, pump)
            if not res["ok"]:
                break
            best = k * 0.01
        AIM_SPINE_SHARE[key] = best
    return AIM_SPINE_SHARE


def upper_aim(pose, weapon, pitch, hold_rot=None, hold_pos=(0, 0, 0), r_override=None,
              l_target=None, l_weight=0.0, head_extra=None, spine_extra=(I3, I3), lower=0.0,
              stance=None):
    """Aim pose. pitch degrees (+ up). hold_rot/hold_pos move the weapon in the aim frame.
    r_override: (attach_world, hand_world, weight) blend for the right hand (holster).
    l_target: off-hand world point (blended in with l_weight; None = stay on the weapon)."""
    share = AIM_SPINE_SHARE["up" if pitch > 0.0 else "down"]
    hw = head_extra if head_extra is not None else I3
    st_ab, st_ch = stance_spine(stance if stance is not None else weapon)
    if pitch != 0.0:
        ref = pose.copy()
        set_spine(ref, st_ab @ spine_extra[0], st_ch @ spine_extra[1])
        look(ref, hw, 0.5)
        target = head_in_pelvis(ref)
    ab = st_ab @ rx(AIM_SPLIT * share * pitch) @ spine_extra[0]
    ch = st_ch @ rx((1 - AIM_SPLIT) * share * pitch) @ spine_extra[1]
    set_spine(pose, ab, ch)
    A = rx(pitch)
    look(pose, A @ hw, AIM_NECK_SHARE if pitch != 0.0 else 0.5)
    if pitch != 0.0:
        compensate_head(pose, target)
    if weapon == "none":
        relax_arms(pose)
        return
    h = HOLDS[weapon]
    Hr = hold_rot if hold_rot is not None else I3
    O = shoulder_mid(pose) + np.array([0, -lower, 0])
    A = rx(pitch * h.get("pitch_share", 1.0))
    Wr = A @ Hr @ h.get("rot", I3)
    base = O + A @ np.asarray(hold_pos, float)
    r_att = base + A @ Hr @ np.array(h["R"])
    r_rot = Wr
    if r_override is not None:
        att, rot, w = r_override
        r_att = r_att + (np.asarray(att, float) - r_att) * w
        r_rot = slerp_m(r_rot, rot, w)
    solve_arm(pose, "R", r_att, r_rot, h["pole_R"])
    l_att = base + A @ Hr @ np.array(h["L"])
    l_rot = (A @ Hr if h.get("free_L") else Wr) @ rz(h["roll_L"])
    if l_target is not None and l_weight > 0.0:
        l_att = l_att + (np.asarray(l_target, float) - l_att) * l_weight
    solve_arm(pose, "L", l_att, l_rot, h["pole_L"])


def weapon_point(pose, weapon, pitch, local, hold_rot=None, hold_pos=(0, 0, 0)):
    """World point at `local` (weapon frame, relative to the right-hand attach) for current hold."""
    h = HOLDS[weapon]
    A = rx(pitch * h.get("pitch_share", 1.0)); Hr = hold_rot if hold_rot is not None else I3; Wr = A @ Hr
    O = shoulder_mid(pose)
    base = O + A @ np.asarray(hold_pos, float)
    return base + Wr @ (np.array(h["R"]) + np.asarray(local, float))


# ---------------------------------------------------------------- stances
STAND_H = 0.915  # v1.2: was 0.91; PB_Head 1.525 standing (rest 1.54), knees still soft
# v1.7 bladed stance: left foot forward, right foot rooted back with its toes turned out (the
# stance a right-handed shooter or swordsman takes). Idle-type clips also turn the hips part way
# (STANCE_HIP_YAW); the upper body's own twist is STANCE. Walk / run / crouch-walk keep their
# even FEET_LOCO / FEET_CROUCH_LOCO stride.
FEET_STAND = (np.array([-0.12, 0.12, -0.13]), np.array([0.15, 0.12, 0.15]))
FEET_STAND_ROT = (ry(-8.0), ry(-30.0))
STANCE_HIP_YAW = -10.0
FEET_LOCO = (np.array([-0.12, 0.12, 0.0]), np.array([0.12, 0.12, 0.0]))
CROUCH_PELVIS = np.array([0.0, 0.30, 0.22])
CROUCH_LEAN = -22.0
FEET_CROUCH = (np.array([-0.15, 0.12, -0.13]), np.array([0.16, 0.12, 0.13]))
FEET_CROUCH_ROT = (ry(-8.0), ry(-28.0))
FEET_CROUCH_LOCO = (np.array([-0.15, 0.12, -0.06]), np.array([0.15, 0.12, 0.04]))
CROUCH_SPINE = (I3, I3)  # 22 deg torso lean from the pelvis; head ends in the crouch hitbox


def stand_lower(pose, dy=0.0, dx=0.0, dz=0.0, tilt=I3, hip_yaw=0.0):
    """hip_yaw: the idle-type clips pass STANCE_HIP_YAW. ref_stand (the pose every upper-body
    clip is authored on) keeps square hips: in game CharacterAnimDriver's steady upper body
    cancels the hips' turn for the upper layer, so authoring on square hips is what plays."""
    pose.pelvis = np.array([dx, STAND_H + dy, dz])
    pose.rot["Pelvis"] = ry(hip_yaw) @ tilt
    solve_legs(pose, FEET_STAND, FEET_STAND_ROT)


def crouch_lower(pose, dy=0.0, dx=0.0, extra=I3, feet=FEET_CROUCH, foot_rots=FEET_CROUCH_ROT):
    pose.pelvis = CROUCH_PELVIS + np.array([dx, dy, 0])
    pose.rot["Pelvis"] = rx(CROUCH_LEAN) @ extra
    solve_legs(pose, feet, foot_rots, knee_out=0.3)


# v1.7 RESET. AnimationMixer blends every rotation track relative to the RESET pose along the
# shortest path. Against the rig's T-pose the held-weapon hands sat near 180 deg (a hold turns
# the hand about half a turn), where "shortest" flips side on a tiny change: the rifle whipped
# round mid aim-blend. RESET is now chosen per joint: the orientation nearest (minimax) all the
# poses that joint takes in the clips that drive it in game - upper joints from the aim and
# action clips, lower joints from locomotion and deaths - with the always-blended ones (aim,
# locomotion) weighted first. Action clips may still swing far from it mid-motion; that is
# harmless, a one-shot fades in and out near the guard pose and is at full weight in between.
CONTINUOUS = ("aim_", "idle", "walk_", "run_", "crouch_idle", "crouch_walk", "stop_", "land",
              "turn_", "jump_", "fall", "slide")
UPPER_SOURCES = ("aim_", "melee_", "switch_", "throw_", "reload_")


def centre_reset(clips):
    """Replace clips[0] (RESET) with the per-joint minimax pose; returns the worst angles."""
    base = reset_pose()
    centre = base.copy()
    worst = {}
    joints = sorted({j for c in clips if not c.additive for _, p in c.frames for j in p.rot})
    for j in joints:
        upper = j in UPPER
        qs, cont = [], []
        for c in clips[1:]:
            if c.additive:
                continue
            drives = c.name.startswith(UPPER_SOURCES) if upper else not c.name.startswith(UPPER_SOURCES)
            if not drives:
                continue
            for _, p in c.frames:
                if j in p.rot:
                    qs.append(quat(p.rot[j]))
                    cont.append(c.name.startswith(CONTINUOUS))
        if not qs:
            continue
        Q = np.array(qs)
        ang = 2.0 * np.degrees(np.arccos(np.clip(np.abs(Q @ Q.T), 0.0, 1.0)))
        mask = np.array(cont)
        score = (ang[:, mask].max(axis=1) if mask.any() else 0.0) * 1000.0 + ang.max(axis=1)
        i = int(np.argmin(score))
        centre.rot[j] = qmat(Q[i])
        worst[j] = (float(ang[i, mask].max()) if mask.any() else 0.0, float(ang[i].max()))
    clips[0] = clip_from("RESET", 1.0 / FPS, lambda t: centre)
    cj = max(worst, key=lambda k: worst[k][0])
    print("RESET (per-joint centre): worst always-blended pose %.0f deg from it (%s)" % (worst[cj][0], cj))
    return worst


def reset_pose():
    p = ref_stand()
    upper_aim(p, "rifle", 0.0)
    return p


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
        self.events = []  # (t, node path relative to PlayerModel, method): method-call track
        self.extra_times = []  # exact key times besides the 30 fps grid (event frames)

    def sample(self, fn):
        REPORT["clip"] = self.name
        n = max(1, int(round(self.length * FPS)))
        times = sorted(set([min(i / FPS, self.length) for i in range(n + 1)]
                           + [t for t in self.extra_times if 0.0 < t < self.length]))
        for t in times:
            self.frames.append((t, fn(t)))
        if self.loop:  # exact wrap
            self.frames[-1] = (self.length, self.frames[0][1])
        return self


def clip_from(name, length, fn, loop=False, tracks=None, additive=False, extra_times=()):
    c = Clip(name, length, loop, tracks, additive)
    c.extra_times = list(extra_times)
    return c.sample(fn)


# ---------------------------------------------------------------- locomotion
DIRS = {"f": 0, "fr": 45, "r": 90, "br": 135, "b": 180, "bl": -135, "l": -90, "fl": -45}
CYCLE = 0.6  # walk, run and crouch-walk share one cycle length so blendspaces stay in phase
# Speeds the clips are authored for, and the sideways stride reduction (strafes take a shorter
# stride: 1 - LATERAL_STRIDE_CUT * |sideways component|). CharacterAnimDriver mirrors these to
# scale playback to the real velocity, so keep them in sync with its exports.
WALK_SPEED, RUN_SPEED, CROUCH_SPEED = 3.5, 7.5, 3.2
LATERAL_STRIDE_CUT = 0.45
CROUCH_BETA = 0.31
# Run v1.1 (polish): heavy and driven, not springy. Contact 17 % of the cycle per foot (was
# 12 %), pelvis 0.80 (was 0.84) for the reach that needs, 3.5 cm pelvis travel with the low
# point at mid-stance (loading) instead of the high point at contact, 8 cm foot clearance.
# v1.2 (head-hitbox rule): PB_Head must stay within +-3 cm of standing in every non-crouch
# clip, so the hip can't drop for reach. Run: pelvis 0.91-0.93 (was 0.80, travel 2 cm),
# with a heel-toe roll (gait_roll) for the contact phase: 15 % of the cycle per foot
# (v1.1 17 %, v1 12 %), hard 55 deg toe-off, 25 deg toes-up strike; heavier read from an
# 8 deg pelvis pitch, the toe-off drive and low foot recovery (5 cm swing lift, ~10 cm sole clearance with the roll).
# v1.5 (super-soldier): forward runs drive the knee high and kick the heel up behind (both
# scaled by the forward share of the direction, so strafes and backpedals stay grounded),
# and the pelvis swings harder. The pelvis height and lean are unchanged (head-hitbox rule):
# the aggression lives in the legs' swing and the run_pump upper body.
# v1.8 (operator): the v1.5 knee drive and heel kick read as goofy. The run is now a compact,
# gliding tactical stride: feet low and quick (no kick, a touch of knee), a softer heel-toe
# roll, half the hip twist and bob, a slight lean; the upper body (run_pump) stays quiet and
# square with the rifle on the aim line.
RUN = {"speed": RUN_SPEED, "beta": 0.15, "lift": 0.055, "h": 0.92, "bob": 0.005, "lean": 6.0,
       "low_at": 0.075, "yaw": 4.0,
       "roll": {"strike": 14.0, "off": 32.0, "center": -0.02, "knee": 0.03, "kick": 0.0}}
WALK = {"speed": WALK_SPEED, "beta": 0.24, "lift": 0.07, "h": 0.912, "bob": 0.006, "lean": 2.0,
        "roll": {"strike": 15.0, "off": 30.0, "center": -0.02}}


def move_dir(deg):
    a = math.radians(deg)
    return np.array([math.sin(a), 0.0, -math.cos(a)])


def gait(t, d, speed, beta, lift, feet, pelvis_fn, foot_pitch=12.0):
    lateral = abs(d[0])
    stride = speed * beta * CYCLE * (1.0 - LATERAL_STRIDE_CUT * lateral)
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


HEEL_Z, TOE_Z, SOLE_Y = 0.115, -0.175, -0.12  # boot-local heel / toe contact edges (PB_Sole box)


def on_floor(ankle, R):
    """Raise an ankle target so no sole corner is below the floor (toe push-offs, rolls)."""
    low = min(q[1] for q in sole_points(np.asarray(ankle, float), R))
    return np.asarray(ankle, float) + np.array([0, max(0.0, -low), 0])


def sole_points(ankle, R):
    """The four bottom corners of the PB_Sole box (world), for floor checks."""
    return [ankle + R @ np.array([x, SOLE_Y, z]) for z in (HEEL_Z, TOE_Z) for x in (-0.075, 0.075)]


SOLE_HALF_W = 0.075


def sole_support(v):
    """Sole point furthest along ground direction v (a heel/toe edge or corner)."""
    x = math.copysign(SOLE_HALF_W, v[0]) if abs(v[0]) > 1e-6 else 0.0
    z = (TOE_Z if v[2] < 0 else HEEL_Z) if abs(v[2]) > 1e-6 else 0.0
    return np.array([x, SOLE_Y, z])


def gait_roll(t, d, speed, beta, lift, feet, pelvis_fn, strike=15.0, off=30.0, a=0.2, b=0.5,
              center=0.0, side_scale=0.6, knee=0.0, kick=0.0):
    """Stance with a heel-toe roll (v1.2). The foot is rigid and fixed in ground space for the
    whole stance. After strike it pivots on its trailing edge with the leading edge up
    (`strike` deg, until a), lies flat, then pivots on its leading edge with the trailing edge
    up (`off` deg, from b). Forward travel rolls heel to toe, backward travel toe to heel and
    strafes roll edge to edge at side_scale of the angles. Rolling keeps the contact phase long
    with the hip high, so the head stays at standing height. `center` shifts the stance along
    the travel direction. knee / kick (v1.5, metres, forward runs only): extra swing height
    under the body (knee drive) and early in the swing, behind (heel kick)."""
    lateral = abs(d[0])
    fwd = max(0.0, -d[2])
    stride = speed * beta * CYCLE * (1.0 - LATERAL_STRIDE_CUT * lateral)
    w = min(1.0, abs(d[2]) + side_scale * abs(d[0]))
    axis = np.cross(d, np.array([0.0, 1.0, 0.0]))
    p_strike, p_off = sole_support(-d), sole_support(d)
    R_strike, R_off = axis_angle(axis, strike * w), axis_angle(axis, -off * w)

    def stance(base, s):
        F = base + d * (0.5 * stride + center) - d * stride * s
        if s < a:
            R, pz = slerp_m(R_strike, I3, smooth(s / a)), p_strike
        elif s > b:
            R, pz = slerp_m(I3, R_off, smooth((s - b) / (1.0 - b))), p_off
        else:
            R, pz = I3, p_off
        return F + pz - R @ pz, R

    ankles, rots = [], []
    for i, off_ph in enumerate((0.0, 0.5)):
        ph = (t / CYCLE + off_ph) % 1.0
        base = feet[i] + np.array([(-1 if i == 0 else 1) * 0.04 * lateral, 0, 0])
        if ph < beta:
            A, R = stance(base, ph / beta)
        else:
            u = (ph - beta) / (1 - beta)
            A1, R1 = stance(base, 1.0)
            A0, R0 = stance(base, 0.0)
            k = smooth(u)
            up = lift * math.sin(math.pi * u)
            up += fwd * knee * math.sin(math.pi * u) ** 2
            up += fwd * kick * math.sin(math.pi * min(1.0, u / 0.55)) * (1.0 - u)
            A = A1 + (A0 - A1) * k + np.array([0, up, 0])
            R = slerp_m(R1, R0, k)
            low = min(q[1] for q in sole_points(A, R))
            if low < 0.0:  # never drag a toe or heel through the floor
                A = A + np.array([0, -low, 0])
        ankles.append(A)
        rots.append(R)
    pose = Pose()
    pelvis_fn(pose, t)
    solve_legs(pose, ankles, rots)
    return pose


def stand_gait_pelvis(d, bob, sway, yaw, lean, h, low_at=None):
    """low_at: phase (0..1 of the cycle) of the pelvis low point after each contact; None keeps
    the original walk phasing (high at contact)."""
    k = np.array([-d[2], 0, d[0]])
    phase = 0.0 if low_at is None else math.pi + 4 * math.pi * low_at

    def fn(pose, t):
        w = 2 * math.pi * t / CYCLE
        pose.pelvis = np.array([sway * math.cos(w), h + bob * math.cos(2 * w - phase), 0.0])
        pose.rot["Pelvis"] = ry(yaw * math.sin(w)) @ axis_angle(k, -lean) @ rz(1.5 * math.cos(w))
    return fn


def loco_clip(name, deg, speed, beta, lift, h, bob, sway, yaw, lean, low_at=None, roll=None):
    d = move_dir(deg)
    roll = roll or {}

    def fn(t):
        p = gait_roll(t, d, speed, beta, lift, FEET_LOCO,
                      stand_gait_pelvis(d, bob, sway, yaw, lean, h, low_at), **roll)
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
        p = gait(t, d, CROUCH_SPEED, CROUCH_BETA, 0.06, FEET_CROUCH_LOCO, pel, foot_pitch=8.0)
        upper_aim(p, "rifle", 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
        return p
    return clip_from(name, CYCLE, fn, loop=True)


# ---------------------------------------------------------------- full-body one-offs
def idle_fn(t):
    p = Pose()
    w = 2 * math.pi * t / 2.0
    stand_lower(p, dy=0.004 * math.sin(2 * w), dx=0.012 * math.sin(w), tilt=rz(-0.8 * math.sin(w)),
                hip_yaw=STANCE_HIP_YAW)
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
    dy = curve([(0, -0.008), (0.12, -0.01), (0.3, 0.0)], t)  # v1.2: was -0.035 (head rule)
    tilt = curve([(0, -4.0), (0.12, 2.0), (0.22, -0.5), (0.3, 0.0)], t)
    stand_lower(p, dy=dy, dz=curve([(0, -0.03), (0.12, 0.01), (0.3, 0.0)], t), tilt=rx(tilt),
                hip_yaw=STANCE_HIP_YAW * curve([(0, 0.0), (0.3, 1.0)], t))
    upper_aim(p, "rifle", 0.0)
    return p


def jump_fn(t):
    p = Pose()
    h = curve([(0, STAND_H), (0.06, STAND_H - 0.008), (0.2, 0.945)], t)  # v1.2: dip was 0.84
    p.pelvis = np.array([0, h, 0]); p.rot["Pelvis"] = rx(curve([(0, 0.0), (0.06, -6.0), (0.2, 2.0)], t))
    lift = curve([(0, 0.0), (0.12, 0.0), (0.2, 0.18)], t)
    tuck = curve([(0.12, 0.0), (0.2, 0.06)], t)
    feet = (FEET_STAND[0] + np.array([0, lift, -tuck]), FEET_STAND[1] + np.array([0, lift * 0.8, 0.02]))
    rots = (rx(-25 * min(1, t / 0.12)) if t < 0.14 else rx(10), I3)
    solve_legs(p, tuple(on_floor(feet[i], rots[i]) for i in range(2)), rots)
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
    # v1.2: the knee absorb was 12 cm (head rule); the weight now reads through a short
    # 1 cm dip and a pelvis pitch forward that recovers past neutral.
    stand_lower(p, dy=curve([(0, -0.006), (0.07, -0.01), (0.25, 0.0)], t),
                tilt=rx(curve([(0, -4.0), (0.07, -7.0), (0.17, 1.5), (0.25, 0.0)], t)),
                hip_yaw=STANCE_HIP_YAW * curve([(0, 0.0), (0.25, 1.0)], t))
    upper_aim(p, "rifle", 0.0, spine_extra=(rx(curve([(0, -2.0), (0.08, 3.0), (0.25, 0.0)], t)), I3))
    return p


def slide_fn(t):
    """v1.2: sliding sets crouched (crouch hitbox), so the slide stays at crouch head height
    for the whole clip (PB_Head ~0.87): low seat, lead leg out front, trailing knee up."""
    p = Pose()
    e = smooth(t / 0.13)
    start, end = np.array([0.0, 0.27, 0.10]), np.array([0.0, 0.28, 0.06])
    p.pelvis = start + (end - start) * e
    p.rot["Pelvis"] = rx(16 * e) @ ry(-12 * e)
    feet_a = (np.array([-0.15, 0.12, -0.30]), np.array([0.18, 0.12, -0.12]))
    feet_b = (np.array([-0.08, 0.17, -0.66]), np.array([0.21, 0.12, -0.15]))
    feet = tuple(feet_a[i] + (feet_b[i] - feet_a[i]) * e for i in range(2))
    rots = (rx(28 * e), I3)
    solve_legs(p, tuple(on_floor(feet[i], rots[i]) for i in range(2)), rots, knee_out=0.35)
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


# v1.4: crouched / sliding deaths start from crouch_idle. The standing clips start at the
# standing pelvis (0.915), so a crouched body used to pop up 0.6 m before it fell. From the
# crouch the pelvis is already low and forward, so the body travels less before it lies flat.
CROUCH_DEATH_REACH = 0.5   # share of the standing clip's horizontal pelvis travel
CROUCH_DEATH_LEN = 0.34


def death_clip(key, crouch=False):
    end_pos, end_rot = DEATH[key]
    start = crouch_idle_fn(0.0) if crouch else idle_fn(0.0)
    length = CROUCH_DEATH_LEN if crouch else DEATH_LEN[key]
    if crouch:
        end_pos = np.array([end_pos[0] * CROUCH_DEATH_REACH, end_pos[1], end_pos[2] * CROUCH_DEATH_REACH])
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

    start_xz = np.array([start.pelvis[0], 0.0, start.pelvis[2]])
    buckle_drop = 0.04 if crouch else 0.14
    lead = 0.04 if crouch else 0.08  # buckle time before the topple starts

    def fn(t):
        p = Pose()
        buckle = smooth(t / 0.12)
        fall = (min(max((t - lead) / (length - lead - 0.02), 0.0), 1.0)) ** 2  # gravity ease-in
        settle = math.sin(math.pi * min(max((t - (length - 0.04)) / 0.04, 0), 1)) * 0.015
        ang = fall * 90.0
        y0 = start.pelvis[1] - buckle_drop * buckle
        y = end_pos[1] + (y0 - end_pos[1]) * math.cos(math.radians(ang)) + settle
        h = start_xz + (end_pos - start_xz) * math.sin(math.radians(ang)) if crouch \
            else end_pos * math.sin(math.radians(ang))
        p.pelvis = np.array([h[0], y, h[2]])
        p.rot["Pelvis"] = slerp_m(start.rot["Pelvis"], end_rot, fall)
        # Knees buckle with the feet still planted, then the legs go limp as the body topples.
        planted = Pose(); planted.pelvis = p.pelvis.copy(); planted.rot["Pelvis"] = p.rot["Pelvis"]
        saved = dict(REPORT, per_clip=dict(REPORT["per_clip"]))
        # may over-reach while toppling; blended out, so don't report it
        if crouch:
            solve_legs(planted, FEET_CROUCH, FEET_CROUCH_ROT, knee_out=0.3)
        else:
            solve_legs(planted, FEET_STAND, FEET_STAND_ROT)
        REPORT.update(saved)
        # From a crouch the pelvis starts near the floor: limp legs (the lying pose) would dig
        # in and lift_clear would heave the whole body up, so the feet stay planted until the
        # body is most of the way down.
        limp = smooth((fall - 0.55) / 0.45) if crouch else min(1.0, fall * 1.6)
        for j, m in end_locals.items():
            if j in legs:
                p.rot[j] = slerp_m(planted.rot[j], m, limp)
            else:
                p.rot[j] = slerp_m(start.rot[j], m, min(1.0, 0.4 * buckle + 0.6 * fall))
        lift_clear(p)
        return p
    return clip_from(("death_crouch_" if crouch else "death_") + key, length, fn)


def lift_clear(p, clearance=0.03):
    """Raise the pelvis so no joint (boots: soles) dips below the floor."""
    W = p.world()
    low = min(min(q[1] for q in sole_points(pos, R)) if j.startswith("Boot") else pos[1]
              for j, (R, pos) in W.items())
    if low < clearance:
        p.pelvis = p.pelvis + np.array([0, clearance - low, 0])


# ---------------------------------------------------------------- upper-body sets
def aim_clip(weapon, name, pitch):
    def fn(t):
        p = ref_stand(); upper_aim(p, weapon, pitch); return p
    return clip_from(name, 1.0 / FPS, fn, tracks=UPPER)


AIM_PITCH = 70.0  # pose pitch at blend +-1 (driver maps aim pitch / 70 deg, clamped)
# Aim blendspace points (driver aim_<w> BS1D). v1.3 adds the +-35 deg half points: the spine
# counter-translation is not linear in pitch, so a 3-point blend would lift the head ~1 cm
# mid-way; with the half points the in-between error is a few mm.
AIM_POINTS = (("down", -1.0), ("down_half", -0.5), ("mid", 0.0), ("up_half", 0.5), ("up", 1.0))


# v1.3: crouch and slide heads run 0.863-0.894 against the 0.838-0.898 crouch window (crouch
# walk carries the pelvis higher), so the crouch layer sinks the torso this much into the
# pelvis (abdomen translation; deeper overlap, no seam) to centre them before aim pitch.
CROUCH_SINK = 0.01


def crouch_additive(weapon):
    s = ref_stand(); upper_aim(s, weapon, 0.0)
    c = ref_crouch(); upper_aim(c, weapon, 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
    d = Pose()
    d.tr["Abdomen"] = np.array([0.0, -CROUCH_SINK, 0.0])
    for j in UPPER:
        d.rot[j] = s.rot[j].T @ c.rot[j]
    return clip_from("crouch_upper_" + weapon, 1.0 / FPS, lambda t: d, tracks=UPPER, additive=True)


# v1.3 run pump: additive upper-body loop (CYCLE long, phase-locked by the driver to the
# locomotion cycle; left foot strikes at t=0, right at CYCLE/2, mid-stance low at RUN low_at).
# Weighted by synced speed (walk -> run), off when crouched/sliding/airborne and faded out under
# reload/melee/switch. Content: forward pitch, chest counter-yaw (shoulder forward with the
# opposite foot) and a dip toward the stance side, the weapon riding a little of the shoulder
# motion plus a small bob twice per cycle. The weapon keeps its world orientation (aim
# direction) and the hands re-solve onto it; the head keeps its world orientation and height
# (abdomen/chest counter-translation as for aim pitch).
# v1.5 (super-soldier): hunched further over the gun (head held level and steady, so the
# visor stays locked forward), bigger shoulder counter-swing, the weapon riding the shoulders
# with a heavier bob. The weapon stays aimed (no low-ready dip: the gun must keep pointing where
# the player aims while moving). CharacterAnimDriver steadies it for a moment after every shot.
PUMP_PITCH = 4.0     # deg forward, abdomen AIM_SPLIT share, chest the rest
# The run clips' head sits at the bottom of its window (1.512-1.535: hip height is capped by
# leg reach, the 8 deg drive lean lowers it). At full pump weight the torso rises this much out
# of the hips (abdomen translation, inside the 3 cm pelvis overlap) to re-centre the run head
# and leave room for aim pitch on top.
PUMP_LIFT = 0.012
PUMP_YAW = 2.5       # deg chest yaw amplitude (abdomen counter-yaws by half)
PUMP_ROLL = 1.0      # deg chest roll amplitude toward the stance side
PUMP_FOLLOW = 0.3    # share of the shoulder displacement the weapon follows
PUMP_BOB = 0.004     # m weapon bob amplitude (2x per cycle, low at mid-stance)
PUMP_SWING = 28.0    # deg arm swing for the unarmed variant



def pump_clip(weapon):
    base = ref_stand(); upper_aim(base, weapon, 0.0)
    Wb = base.world()
    head_t = head_in_pelvis(base)
    hands = {s: (Wb["Hand_" + s][1] + Wb["Hand_" + s][0] @ MARK[s], Wb["Hand_" + s][0]) for s in "LR"}
    low = RUN["low_at"]

    def fn(t):
        ph = 2 * math.pi * t / CYCLE
        yaw = PUMP_YAW * math.cos(ph)
        roll = PUMP_ROLL * math.cos(ph - 2 * math.pi * low / CYCLE)
        bob = -PUMP_BOB * math.cos(2 * (ph - 2 * math.pi * low / CYCLE))
        p = ref_stand()
        st_ab, st_ch = stance_spine(weapon)
        set_spine(p, st_ab @ rx(-AIM_SPLIT * PUMP_PITCH) @ ry(-0.5 * yaw),
                  st_ch @ rx(-(1 - AIM_SPLIT) * PUMP_PITCH) @ ry(yaw) @ rz(roll))
        look(p, I3, 0.5)
        compensate_head(p, head_t)
        p.tr["Abdomen"] = p.tr["Abdomen"] + np.array([0.0, PUMP_LIFT, 0.0])
        if weapon == "none":
            relax_arms(p, swing=PUMP_SWING * math.cos(ph))
            for side in "LR":  # sprinter's arms: elbows bent hard
                p.rot["Forearm_" + side] = eul(x=55)
        else:
            h = HOLDS[weapon]
            off = PUMP_FOLLOW * (shoulder_mid(p) - shoulder_mid(base)) + np.array([0, bob, 0])
            for s in "RL":
                att, rot = hands[s]
                solve_arm(p, s, att + off, rot, h["pole_" + s])
        d = Pose()
        for j in UPPER:
            d.rot[j] = base.rot[j].T @ p.rot[j]
        for j in TRANSLATED:
            if j in p.tr:
                d.tr[j] = p.tr[j] - base.tr.get(j, np.zeros(3))
        return d
    return clip_from("run_pump_" + weapon, CYCLE, fn, loop=True, tracks=UPPER, additive=True)


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


# v1.6 melee weapon swings (longsword, gravity hammer). Keyed in model space (standing, facing
# -Z, right = +X): the sword hand's attach point and blade direction, the off hand, and the
# torso twist / lean. Keys are joined by a Catmull-Rom spline, not eased one by one, so the
# swing carries its speed through the strike instead of stopping on every key. The head keeps
# its world facing (look()) and its height (compensate_head), so the hitbox rule holds while the
# torso winds up and whips through.
MELEE_SWORD_LEN = 0.78
MELEE_HAMMER_LEN = 1.0
HAMMER_IMPACT = 0.25  # WeaponData.smash_delay


def spline(keys, t):
    """Catmull-Rom through [(time, value)] (value float or array), clamped at the ends."""
    ts = [k[0] for k in keys]
    vs = [np.atleast_1d(np.array(k[1], float)) for k in keys]
    scalar = np.isscalar(keys[0][1])
    if t <= ts[0]:
        out = vs[0]
    elif t >= ts[-1]:
        out = vs[-1]
    else:
        i = max(j for j in range(len(ts) - 1) if ts[j] <= t)
        u = (t - ts[i]) / (ts[i + 1] - ts[i])
        p0, p1, p2 = vs[max(i - 1, 0)], vs[i], vs[i + 1]
        p3 = vs[min(i + 2, len(vs) - 1)]
        u2, u3 = u * u, u * u * u
        out = 0.5 * (2 * p1 + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
                     + (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
    return float(out[0]) if scalar else out


def look_rot(fwd, up=(0.0, 1.0, 0.0)):
    """Rotation whose -Z points along fwd (model space), +Y as close to `up` as it can."""
    z = -np.asarray(fwd, float) / np.linalg.norm(fwd)
    x = np.cross(np.asarray(up, float), z)
    if np.linalg.norm(x) < 1e-4:
        x = np.cross(np.array([0.0, 0.0, 1.0]), z)
    x /= np.linalg.norm(x)
    return np.column_stack([x, np.cross(z, x), z])


def _attach_of(pose):
    W = pose.world()
    Rh, ph = W["Hand_R"]
    return ph + Rh @ MARK["R"], Rh


ARM_REACH = 0.92  # share of the full arm length a swing target may sit from its shoulder


def _melee_pose(weapon, att, rot, l_att, yaw, lean, head_t, two_handed=False):
    """Upper body for one swing frame: torso twist / lean, head held, arms on the targets.
    Targets out of reach of the (twisted) shoulders are pulled in onto the reach sphere; a
    two-handed weapon moves both hands together, so they stay on the haft."""
    se = (ry(0.4 * yaw) @ rx(-0.4 * lean), ry(0.6 * yaw) @ rx(-0.6 * lean))
    att = np.asarray(att, float)
    l_att = np.asarray(l_att, float)
    p = ref_stand()
    # Torso first (arms relaxed, no IK), to know where the shoulders are.
    upper_aim(p, "none", 0.0, spine_extra=se, stance=weapon)
    compensate_head(p, head_t)
    for _ in range(3):
        W = p.world()
        moved = False
        for side, target in (("R", att), ("L", l_att)):
            arm = np.linalg.norm(OFF["Forearm_" + side]) + np.linalg.norm(OFF["Hand_" + side])
            shoulder = W["UpperArm_" + side][1]
            hand_rot = rot if side == "R" else W["Hand_L"][0]
            pivot = target - hand_rot @ MARK[side]
            v = pivot - shoulder
            excess = np.linalg.norm(v) - ARM_REACH * arm
            if excess > 1e-4:
                shift = -v / np.linalg.norm(v) * excess
                if side == "R" or two_handed:
                    att = att + shift
                if side == "L" or two_handed:
                    l_att = l_att + shift
                moved = True
        if not moved:
            break
    upper_aim(p, weapon, 0.0, r_override=(att, rot, 1.0), l_target=l_att, l_weight=1.0, spine_extra=se)
    return p


def melee_sword_clip(name, keys):
    """keys: [(t, attach, blade_dir, off_hand, yaw_deg, lean_deg)] between the guard poses."""
    base = ref_stand(); upper_aim(base, "sword", 0.0)
    head_t = head_in_pelvis(base)
    att0, rot0 = _attach_of(base)
    blade0 = rot0 @ SWORD_TILT @ np.array([0.0, 0.0, -1.0])
    l0 = base.world()["Hand_L"][1] + base.world()["Hand_L"][0] @ MARK["L"]
    full = [(0.0, att0, blade0, l0, 0.0, 0.0)] + keys + [(MELEE_SWORD_LEN, att0, blade0, l0, 0.0, 0.0)]

    def fn(t):
        att = spline([(k[0], k[1]) for k in full], t)
        blade = spline([(k[0], k[2]) for k in full], t)
        l_att = spline([(k[0], k[3]) for k in full], t)
        yaw = spline([(k[0], k[4]) for k in full], t)
        lean = spline([(k[0], k[5]) for k in full], t)
        rot = look_rot(blade) @ SWORD_TILT.T
        return _melee_pose("sword", att, rot, l_att, yaw, lean, head_t)
    return clip_from(name, MELEE_SWORD_LEN, fn, tracks=UPPER)


def melee_sword_clips():
    # A: forehand diagonal - cocked over the right shoulder, cut down across to the left hip.
    a = melee_sword_clip("melee_sword", [
        (0.14, (0.34, 1.62, 0.02), (0.25, 0.55, 0.80), (-0.12, 1.32, -0.40), 28.0, -6.0),
        (0.24, (0.02, 1.32, -0.58), (-0.55, -0.15, -0.82), (-0.30, 1.16, -0.05), -18.0, 10.0),
        (0.32, (-0.32, 1.00, -0.36), (-0.75, -0.50, -0.40), (-0.36, 1.12, 0.05), -38.0, 12.0),
        (0.50, (-0.12, 1.02, -0.30), (-0.40, -0.20, -0.90), (-0.24, 1.16, -0.18), -18.0, 5.0),
    ])
    # B: backhand - wound over the left shoulder, a flat cut out to the right.
    b = melee_sword_clip("melee_sword_b", [
        (0.14, (-0.24, 1.48, -0.12), (-0.60, 0.50, 0.62), (-0.05, 1.30, -0.30), -30.0, -4.0),
        (0.24, (0.12, 1.30, -0.60), (0.70, 0.05, -0.71), (-0.34, 1.15, -0.10), 20.0, 8.0),
        (0.32, (0.42, 1.18, -0.28), (0.92, -0.15, 0.36), (-0.38, 1.15, -0.05), 38.0, 10.0),
        (0.50, (0.34, 1.08, -0.22), (0.50, 0.40, -0.60), (-0.26, 1.18, -0.20), 18.0, 4.0),
    ])
    return [a, b]


def melee_hammer_clip():
    """Overhead slam: hammer up over the head, down onto the floor in front at HAMMER_IMPACT
    (the smash), held a beat, hauled back up to port arms."""
    base = ref_stand(); upper_aim(base, "hammer", 0.0)
    head_t = head_in_pelvis(base)
    att0, rot0 = _attach_of(base)
    # Hand frame from the haft line (local HAMMER_HAFT) and the striking face (local -Z').
    hl = HAMMER_HAFT
    zl = np.array([0.0, 0.0, 1.0]) - hl * hl[2]
    zl /= np.linalg.norm(zl)
    local = np.column_stack([np.cross(hl, zl), hl, zl])

    def hand_rot(haft, face):
        y = np.asarray(haft, float) / np.linalg.norm(haft)
        z = -np.asarray(face, float)
        z = z - y * np.dot(z, y)
        z /= np.linalg.norm(z)
        return np.column_stack([np.cross(y, z), y, z]) @ local.T

    haft0 = rot0 @ hl
    face0 = rot0 @ -zl
    keys = [
        (0.0, att0, haft0, face0, 0.0, 0.0),
        (0.17, (0.10, 1.86, 0.10), (0.05, 0.35, 0.94), (0.0, 0.94, -0.35), 10.0, -10.0),
        (HAMMER_IMPACT, (0.05, 1.02, -0.55), (0.0, -0.25, -0.97), (0.0, -1.0, 0.0), -4.0, 16.0),
        (0.45, (0.05, 1.00, -0.53), (0.0, -0.27, -0.96), (0.0, -1.0, 0.0), -4.0, 16.0),
        (0.72, (0.12, 1.22, -0.36), (-0.25, 0.85, -0.45), (0.0, 0.3, -0.95), 0.0, 5.0),
        (MELEE_HAMMER_LEN, att0, haft0, face0, 0.0, 0.0),
    ]

    def fn(t):
        att = spline([(k[0], k[1]) for k in keys], t)
        haft = spline([(k[0], k[2]) for k in keys], t)
        face = spline([(k[0], k[3]) for k in keys], t)
        yaw = spline([(k[0], k[4]) for k in keys], t)
        lean = spline([(k[0], k[5]) for k in keys], t)
        rot = hand_rot(haft, face)
        l_att = att + rot @ (hl * HAMMER_L_UP)
        return _melee_pose("hammer", att, rot, l_att, yaw, lean, head_t, two_handed=True)
    return clip_from("melee_hammer", MELEE_HAMMER_LEN, fn, tracks=UPPER, extra_times=[HAMMER_IMPACT])


HOLSTER = {
    # attach point and hand orientation at the holster (model space, stand). v1.1: the rifle
    # grab point moved back behind the helmet (was 0.14, 1.66, 0.06) so the prop swap happens
    # out of sight from the front, and onto the holstered rifle's real position.
    "rifle": (np.array([0.10, 1.68, 0.18]), rx(80) @ rz(-25)),
    "pistol": (np.array([0.22, 0.86, 0.02]), rx(-75)),
}
# The longsword hangs where the pistol does, the hammer goes on the back like the rifle
# (CharacterWeaponProps holsters by those two places).
# v1.7 holsters. Rifle class: slung diagonally across the back, the grip just behind the right
# shoulder, muzzle down toward the left hip, lying flat on the back (was: grip at helmet height,
# standing up over the head). Hammer: across the back the other way, grip at the right hip,
# head up behind the left shoulder. Longsword: hangs from the right hip, blade down and back.
HOLSTER["rifle"] = (np.array([0.10, 1.40, 0.24]), look_rot((-0.48, -0.86, 0.12), up=(0.0, 0.0, 1.0)))


def _hammer_holster_rot():
    hl = HAMMER_HAFT
    zl = np.array([0.0, 0.0, 1.0]) - hl * hl[2]
    zl /= np.linalg.norm(zl)
    local = np.column_stack([np.cross(hl, zl), hl, zl])
    y = np.array([-0.3, 0.95, 0.05]); y /= np.linalg.norm(y)       # haft up to the left shoulder
    z = np.array([0.0, 0.0, 1.0]) - y * y[2]; z /= np.linalg.norm(z)  # face flat against the back
    return np.column_stack([np.cross(y, z), y, z]) @ local.T


HOLSTER["hammer"] = (np.array([0.15, 0.64, 0.22]), _hammer_holster_rot())
HOLSTER["sword"] = (np.array([0.25, 0.98, 0.04]), look_rot((0.06, -0.68, 0.73)) @ SWORD_TILT.T)


SWAP_FRACTION = 0.5  # switch clips: the hand reaches the holster here; props swap on this key
HOLSTER_PARENT = {"rifle": "Chest", "pistol": "Thigh_R", "sword": "Pelvis", "hammer": "Chest"}
HOLSTER_PROPS = "CharacterWeaponProps"  # node (relative to PlayerModel) that gets the swap call
HOLSTER_META = {}  # weapon -> 4x4 grip transform in its holster parent's space (library metadata)


def switch_clip(weapon):
    L = 0.5 if weapon in ("rifle", "hammer") else 0.3
    att, rot = HOLSTER[weapon]
    ts = SWAP_FRACTION * L
    w = [(0, 0.0), (ts, 1.0), (ts + 0.05 * L, 1.0), (L, 0.0)]
    lw = [(0, 0.0), (0.2 * L, 1.0), (0.8 * L, 1.0), (L, 0.0)]

    def fn(t):
        p = ref_stand()
        upper_aim(p, weapon, 0.0, r_override=(att, rot, curve(w, t)),
                  l_target=np.array([-0.2, 1.05, -0.12]), l_weight=curve(lw, t),
                  head_extra=rx(-10 * curve(w, t)))
        return p
    c = clip_from("switch_" + weapon, L, fn, tracks=UPPER, extra_times=[ts])
    c.events.append((ts, HOLSTER_PROPS, "anim_swap_weapon"))
    # Holstered prop = exactly where the hand's WeaponAttach_R is on the swap key, in the
    # holster parent's space, so the drawn weapon leaves the holster without a jump.
    pose = dict(c.frames)[ts]
    W = pose.world()
    Rh, ph = W["Hand_R"]
    Rp, pp = W[HOLSTER_PARENT[weapon]]
    m = np.eye(4)
    m[:3, :3] = Rp.T @ Rh
    m[:3, 3] = Rp.T @ (ph + Rh @ MARK["R"] - pp)
    HOLSTER_META[weapon] = m
    REPORT["holster_err_" + weapon] = float(np.linalg.norm(ph + Rh @ MARK["R"] - att))
    return c


# v1.4 grenade throw (Halo: off hand, overhand, weapon stays up in the right hand). Upper body
# only, played as an action one-shot at its authored length. The grenade leaves the hand the
# moment the button is pressed in game, so the windup is short and the release lands early.
# The torso winds up turning left (left shoulder back), then whips right through the release.
THROW_LEN = 0.55
THROW_RELEASE = 0.17
THROW_KEYS = {
    # model space, standing: windup behind the left shoulder, release up and out in front,
    # follow-through low across the body.
    "hand": [(0.0, None), (0.09, (-0.30, 1.56, 0.10)), (THROW_RELEASE, (-0.16, 1.52, -0.46)),
             (0.30, (-0.07, 1.22, -0.36)), (0.48, None)],
    "yaw": [(0, 0.0), (0.09, 16.0), (THROW_RELEASE, -12.0), (0.30, -8.0), (THROW_LEN, 0.0)],
    "dip": [(0, 0.0), (0.07, 1.0), (0.34, 1.0), (0.5, 0.0)],
}
THROW_DIP = {"rifle": ((0.03, -0.08, 0.05), 18.0, -8.0), "pistol": ((0.04, -0.09, 0.10), 16.0, -14.0),
             "sword": ((0.02, -0.05, 0.06), 10.0, -6.0), "hammer": ((0.03, -0.06, 0.05), 12.0, -6.0)}


def throw_clip(weapon):
    h = HOLDS[weapon]
    dip_pos, dip_roll, dip_pitch = THROW_DIP[weapon]
    keys = THROW_KEYS["hand"]

    def fn(t):
        p = ref_stand()
        d = curve(THROW_KEYS["dip"], t)
        Hr = rx(dip_pitch * d) @ rz(-dip_roll * d)
        hp = np.array(dip_pos) * d
        yaw = curve(THROW_KEYS["yaw"], t)
        se = (ry(0.4 * yaw), ry(0.6 * yaw))
        upper_aim(p, weapon, 0.0, Hr, hp, spine_extra=se)
        hold_pt = weapon_point(p, weapon, 0.0, np.array(h["L"]) - np.array(h["R"]), Hr, hp)
        for (t0, a), (t1, b) in zip(keys, keys[1:]):
            if t <= t1:
                u = smooth((t - t0) / (t1 - t0))
                a = hold_pt if a is None else np.array(a)
                b = hold_pt if b is None else np.array(b)
                upper_aim(p, weapon, 0.0, Hr, hp, spine_extra=se, l_target=a + (b - a) * u, l_weight=1.0)
                break
        return p
    return clip_from("throw_" + weapon, THROW_LEN, fn, tracks=UPPER, extra_times=[THROW_RELEASE])


# v1.4 turn in place. The body yaw follows the view rigidly, so an idle body that keeps turning
# used to skate its feet round. The driver plays turn_l / turn_r after enough idle yaw: a quick
# two-step shuffle, lead foot first (left for a left turn). Each foot lifts, toes out toward the
# turn mid-air and replants on its stance spot, so the clip starts and ends on the idle stance
# and blends without a pop. Lower body only matters (the upper layer owns the rest).
TURN_LEN = 0.5
TURN_STEP = 0.24      # each foot's swing time
TURN_TOE = 24.0       # deg the swinging foot yaws toward the turn at mid-swing
TURN_LIFT = 0.06


def turn_clip(sign):
    """sign +1 = turn left (yaw increases), -1 = turn right."""
    lead = 0 if sign > 0 else 1  # FEET_STAND index: 0 left, 1 right

    def fn(t):
        p = Pose()
        sway = math.sin(math.pi * min(t / TURN_LEN, 1.0))
        stand_lower(p, dy=-0.006 * sway, dx=-sign * 0.012 * sway, tilt=ry(sign * 5.0 * sway),
                    hip_yaw=STANCE_HIP_YAW)
        ankles, rots = [], []
        for i in range(2):
            t0 = 0.02 if i == lead else 0.02 + TURN_LEN - TURN_STEP - 0.04
            u = min(max((t - t0) / TURN_STEP, 0.0), 1.0)
            arc = math.sin(math.pi * u)
            side = -1 if i == 0 else 1
            out = np.array([side * 0.03 * arc, TURN_LIFT * arc, 0.0])
            R = ry(sign * TURN_TOE * arc) @ FEET_STAND_ROT[i]
            ankles.append(on_floor(FEET_STAND[i] + out, R))
            rots.append(R)
        solve_legs(p, ankles, rots)
        upper_aim(p, "rifle", 0.0)
        return p
    return clip_from("turn_l" if sign > 0 else "turn_r", TURN_LEN, fn)


def additive_keys(name, length, keys):
    """keys: {joint: [(t, (x, y, z) degrees)]} smoothstepped; first and last keys should be 0."""
    def fn(t):
        p = Pose()
        for j, ks in keys.items():
            x, y, z = curve(ks, t)
            p.rot[j] = eul(x, y, z)
        return p
    return clip_from(name, length, fn, tracks=list(keys.keys()), additive=True)


def fire_clips():
    z = (0, 0, 0)
    return [
        # Marksman carbine: one heavier semi-auto shot than the rifle's burst kick.
        additive_clip("fire_carbine", 0.16, 0.025, {"Chest": (3.5, 0, 0), "Hand_R": (5, 0, 0),
                                                     "Hand_L": (4, 0, 0)}),
        # Shotgun: hard shoulder kick, then the off hand racks the pump (forearm back, forward).
        additive_keys("fire_shotgun", 0.6, {
            "Abdomen": [(0, z), (0.03, (2, 0, 0)), (0.2, z)],
            "Chest": [(0, z), (0.03, (5, -2, 0)), (0.22, z)],
            "Hand_R": [(0, z), (0.03, (9, 0, 0)), (0.2, z)],
            "Hand_L": [(0, z), (0.03, (7, 0, 0)), (0.2, z), (0.6, z)],
            "UpperArm_L": [(0, z), (0.22, z), (0.33, (12, 0, 0)), (0.45, z), (0.6, z)],
            "Forearm_L": [(0, z), (0.22, z), (0.33, (-22, 0, 0)), (0.45, z), (0.6, z)],
        }),
        # Rocket launcher: big slow shove back through the whole torso.
        additive_keys("fire_heavy", 0.5, {
            "Abdomen": [(0, z), (0.04, (3, 0, 0)), (0.5, z)],
            "Chest": [(0, z), (0.04, (6, 0, 0)), (0.5, z)],
            "Head": [(0, z), (0.04, (-3, 0, 0)), (0.5, z)],
            "Hand_R": [(0, z), (0.04, (6, 0, 0)), (0.4, z)],
            "Hand_L": [(0, z), (0.04, (6, 0, 0)), (0.4, z)],
        }),
    ]


# ---------------------------------------------------------------- writer
def fmt(x):
    if abs(x) < 1e-9:
        return "0"
    s = "%.5g" % x
    return "0" if s in ("-0", "0") else s


def write(clips, path):
    out = []
    ids = []
    # Godot reads an additive track's key as RESET * delta (it adds init^-1 * value). Our
    # additive clips hold the bare deltas, so they are written on top of the RESET pose (v1.7:
    # RESET is no longer the identity T-pose).
    reset = next((c.frames[0][1] for c in clips if c.name == "RESET"), Pose())
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
        for j in TRANSLATED:
            # v1.3: spine counter-translation. RESET carries the rest offsets so clips without
            # these tracks blend to rest and additive clips' values are deltas against it.
            if j not in tracks or not (c.name == "RESET" or any(j in p.tr for _, p in c.frames)):
                continue
            base_tr = reset.tr.get(j, np.zeros(3)) if c.additive else np.zeros(3)
            vals = [(t, OFF[j] + base_tr + p.tr.get(j, np.zeros(3))) for t, p in c.frames]
            if all(np.allclose(v, vals[0][1], atol=1e-6) for _, v in vals):
                vals = vals[:1]
            flat = []
            for t, v in vals:
                flat += [fmt(t), "1", fmt(v[0]), fmt(v[1]), fmt(v[2])]
            out += _track(ti, "position_3d", P[j], flat); ti += 1
        for j in tracks:
            if c.additive:
                R0 = reset.rot.get(j, I3)
                qs = [(t, quat(R0 @ p.rot[j])) for t, p in c.frames]
            else:
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
        for t, node, method in c.events:
            out += ['tracks/%d/type = "method"' % ti, "tracks/%d/imported = false" % ti,
                    "tracks/%d/enabled = true" % ti, 'tracks/%d/path = NodePath("%s")' % (ti, node),
                    "tracks/%d/interp = 1" % ti, "tracks/%d/loop_wrap = true" % ti,
                    "tracks/%d/keys = {" % ti, '"times": PackedFloat32Array(%s),' % fmt(t),
                    '"transitions": PackedFloat32Array(1),',
                    '"values": [{', '"args": [],', '"method": &"%s"' % method, "}]", "}"]
            ti += 1
        out.append("")
    out.append("[resource]")
    out.append("_data = {")
    out.append(",\n".join('&"%s": SubResource("%s")' % (n, i) for n, i in ids))
    out.append("}")
    for w, m in sorted(HOLSTER_META.items()):
        # Godot Transform3D text order: basis rows, then origin.
        vals = [m[r, k] for r in range(3) for k in range(3)] + list(m[:3, 3])
        out.append("metadata/holster_%s = Transform3D(%s)" % (w, ", ".join(fmt(v) for v in vals)))
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
    clips = [clip_from("RESET", 1.0 / FPS, lambda t: reset_pose())]  # replaced by centre_reset
    clips.append(clip_from("idle", 2.0, idle_fn, loop=True))
    for k, deg in DIRS.items():
        clips.append(loco_clip("walk_" + k, deg, WALK["speed"], WALK["beta"], WALK["lift"], WALK["h"],
                               WALK["bob"], 0.02, 4.0, WALK["lean"], roll=WALK["roll"]))
    for k, deg in DIRS.items():
        clips.append(loco_clip("run_" + k, deg, RUN["speed"], RUN["beta"], RUN["lift"], RUN["h"],
                               RUN["bob"], 0.015, RUN["yaw"], RUN["lean"], low_at=RUN["low_at"],
                               roll=RUN["roll"]))
    clips.append(clip_from("stop_settle", 0.3, stop_fn))
    clips.append(clip_from("crouch_idle", 2.0, crouch_idle_fn, loop=True))
    for k, deg in DIRS.items():
        clips.append(crouch_loco_clip("crouch_walk_" + k, deg))
    clips.append(clip_from("jump_start", 0.2, jump_fn))
    clips.append(clip_from("fall", 0.6, fall_fn, loop=True))
    clips.append(clip_from("land", 0.25, land_fn))
    clips.append(clip_from("slide", 0.5, slide_fn))
    clips.append(turn_clip(1))
    clips.append(turn_clip(-1))
    find_aim_spine_share({c.name: c for c in clips}, pump_clip("rifle"),
                         crouch_additive("rifle").frames[0][1])
    for w in ("rifle", "pistol", "none", "sword", "hammer"):
        for suffix, k in AIM_POINTS:
            clips.append(aim_clip(w, "aim_%s_%s" % (w, suffix), k * AIM_PITCH))
        clips.append(crouch_additive(w))
        clips.append(pump_clip(w))
    clips.append(additive_clip("fire_rifle", 0.1, 0.02, {"Chest": (2.5, 0, 0), "Hand_R": (3, 0, 0),
                                                          "Hand_L": (2, 0, 0)}))
    clips.append(additive_clip("fire_pistol", 0.2, 0.03, {"Forearm_R": (4, 0, 0), "Forearm_L": (4, 0, 0),
                                                           "Hand_R": (10, 0, 0), "Hand_L": (10, 0, 0)}))
    clips += fire_clips()
    for w in ("rifle", "pistol"):
        clips.append(reload_clip(w, False))
        clips.append(reload_clip(w, True))
        clips.append(melee_clip(w))
        clips.append(switch_clip(w))
        clips.append(throw_clip(w))
    # v1.6 melee weapons: no reload, no fire kick; their own swings.
    for w in ("sword", "hammer"):
        clips.append(switch_clip(w))
        clips.append(throw_clip(w))
    clips += melee_sword_clips()
    clips.append(melee_hammer_clip())
    flinch = {"front": {"Abdomen": (3, 0, 0), "Chest": (6, 0, 0), "Head": (5, 0, 0)},
              "back": {"Abdomen": (-3, 0, 0), "Chest": (-6, 0, 0), "Head": (-5, 0, 0)},
              "left": {"Abdomen": (0, -2, -2), "Chest": (0, -4, -5), "Head": (0, 0, -6)},
              "right": {"Abdomen": (0, 2, 2), "Chest": (0, 4, 5), "Head": (0, 0, 6)}}
    for k, v in flinch.items():
        clips.append(additive_clip("flinch_" + k, 0.18, 0.05, v))
    for k in ("front", "back", "left", "right"):
        clips.append(death_clip(k))
    for k in ("front", "back", "left", "right"):
        clips.append(death_clip(k, crouch=True))
    REPORT["reset"] = centre_reset(clips)
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


HEAD_STAND = 1.54   # PB_Head world height standing (rest pose)
HEAD_CROUCH = 0.868  # PB_Head under the approved crouch helmet (0.968)
HEAD_TOL = 0.03


def head_class(name):
    """'crouch' (crouch hitbox: crouch_* and slide, which sets crouched), 'exempt' or 'stand'."""
    if name.startswith("death_") or name == "RESET":
        return "exempt"
    if name.startswith("crouch_") or name == "slide":
        return "crouch"
    return "stand"


def _apply_additive(base, delta, weight=1.0):
    p = base.copy()
    for j, m in delta.rot.items():
        p.rot[j] = base.rot[j] @ (m if weight == 1.0 else slerp_m(I3, m, weight))
    for j, v in delta.tr.items():
        p.tr[j] = p.tr.get(j, np.zeros(3)) + weight * v
    return p


def head_report(clips):
    """PB_Head world height per clip as the game shows it. Upper-only clips carry their stand
    lower body; additive clips are applied on the stand (fire, flinch) or crouch (crouch_upper)
    rifle/pistol mid aim. Full-body clips are measured with their own upper body and with the
    in-game upper layer (mid aim) on top; min/max cover both. Returns the failing clips."""
    fails = []
    stand_up = ref_stand(); upper_aim(stand_up, "rifle", 0.0)
    crouch_up = ref_crouch(); upper_aim(crouch_up, "rifle", 0.0, spine_extra=CROUCH_SPINE, lower=0.03)
    crouch_up.tr["Abdomen"] = np.array([0.0, -CROUCH_SINK, 0.0])
    runtime_upper = {"stand": stand_up, "crouch": crouch_up}
    print("head height (PB_Head world y), stand %.3f / crouch %.3f, tolerance +-%.2f m:"
          % (HEAD_STAND, HEAD_CROUCH, HEAD_TOL))
    for c in clips:
        cls = head_class(c.name)
        if cls == "exempt":
            continue
        ys = []
        if c.additive:
            weapon = "rifle"
            for w in ("pistol", "none", "sword", "hammer"):
                if c.name.endswith("_" + w):
                    weapon = w
            if c.name.startswith("crouch_upper_"):
                base = ref_crouch()
            else:
                base = ref_stand()
            upper_aim(base, weapon, 0.0)
            for _, d in c.frames:
                ys.append(_apply_additive(base, d).world()["Head"][1][1])
        else:
            ys = [p.world()["Head"][1][1] for _, p in c.frames]
            if c.tracks is not UPPER:
                # In game the upper-body layer replaces this clip's spine/arms with the mid aim
                # pose (plus the crouch additive in crouch/slide): count that version too.
                up = runtime_upper[cls]
                for _, p in c.frames:
                    q = Pose(); q.pelvis = p.pelvis; q.rot = dict(p.rot); q.tr = dict(up.tr)
                    q.rot.update({j: up.rot[j] for j in UPPER})
                    ys.append(q.world()["Head"][1][1])
        ref = HEAD_CROUCH if cls == "crouch" else HEAD_STAND
        lo, hi = min(ys), max(ys)
        ok = lo >= ref - HEAD_TOL - 1e-4 and hi <= ref + HEAD_TOL + 1e-4
        if not ok:
            fails.append(c.name)
        print("  %-20s %-6s min %.3f  max %.3f  %s" % (c.name, cls, lo, hi, "ok" if ok else "FAIL"))
    return fails


def floor_report(clips, tol=0.001):
    """Lowest point per full-body clip (joint pivots; boots: the four sole corners). Returns
    the clips that go through the floor."""
    bad = []
    for c in clips:
        if c.additive or c.tracks is UPPER or c.name == "RESET":
            continue
        low = min(min(min(q[1] for q in sole_points(pos, R)) if j.startswith("Boot") else pos[1]
                      for j, (R, pos) in p.world().items()) for _, p in c.frames)
        if low < -tol:
            bad.append("%s (%.3f m)" % (c.name, low))
    print("floor check:", "ok" if not bad else "BELOW FLOOR " + ", ".join(bad))
    return bad


def _blend(a, b, k):
    p = a.copy()
    for j in UPPER:
        p.rot[j] = slerp_m(a.rot[j], b.rot[j], k)
    for j in TRANSLATED:
        va, vb = a.tr.get(j, np.zeros(3)), b.tr.get(j, np.zeros(3))
        p.tr[j] = va + (vb - va) * k
    return p


def aim_blend(by, weapon, x):
    """The aim_<w> BlendSpace1D at blend x in [-1, 1] (linear between neighbouring points)."""
    pts = [(k, by["aim_%s_%s" % (weapon, n)].frames[0][1]) for n, k in AIM_POINTS]
    for (k0, p0), (k1, p1) in zip(pts, pts[1:]):
        if x <= k1 + 1e-9:
            return _blend(p0, p1, (x - k0) / (k1 - k0))
    return pts[-1][1]


COMBINED_STAND = ["idle", "stop_settle", "jump_start", "fall", "land", "turn_l", "turn_r"] \
    + ["walk_" + k for k in DIRS] \
    + ["run_" + k for k in DIRS]
COMBINED_CROUCH = ["crouch_idle", "slide"] + ["crouch_walk_" + k for k in DIRS]
SEAM_LIMIT = 0.001


def combined_eval(lower, aims, crouch_delta, pump):
    """Head height and seams for every frame of the lower-body clips with each (blend, aim
    upper pose) on top, plus the crouch additive (crouch/slide) or the run pump (run clips: at
    weight 1, same frame = phase-locked; plus weight 0 at mid aim for the action case)."""
    res = {"seam": 0.0, "ok": True}
    mid = ref_stand(); upper_aim(mid, "rifle", 0.0)
    for cls, fams in (("stand", COMBINED_STAND), ("crouch", COMBINED_CROUCH)):
        ref = HEAD_CROUCH if cls == "crouch" else HEAD_STAND
        lo, hi, wlo, whi = 9.0, -9.0, "", ""
        for fam in fams:
            c = lower[fam]
            run = fam.startswith("run_")
            for i, (t, lp) in enumerate(c.frames):
                pd = pump.frames[i % (len(pump.frames) - 1)][1] if run else None
                for x, up in aims + ([(0.0, mid)] if run else []):
                    u = _apply_additive(up, crouch_delta) if cls == "crouch" else up
                    # Run speed means full pump, except under reload/melee/switch, which fade
                    # it out and own the upper body at mid aim: that case is the extra mid entry.
                    for wgt in ((1.0,) if run and up is not mid else (0.0,)):
                        q = _apply_additive(u, pd, wgt) if wgt > 0.0 else u
                        r = lp.copy(); r.tr = dict(q.tr)
                        r.rot.update({j: q.rot[j] for j in UPPER})
                        y = r.world()["Head"][1][1]
                        res["seam"] = max(res["seam"], *seam_openings(r))
                        if y < lo or y > hi:
                            tag = "%s t=%.2f aim %+.0f%s" % (fam, t, x * AIM_PITCH, " +pump" if wgt else "")
                            if y < lo:
                                lo, wlo = y, tag
                            if y > hi:
                                hi, whi = y, tag
        ok = lo >= ref - HEAD_TOL - 1e-4 and hi <= ref + HEAD_TOL + 1e-4
        res[cls] = (lo, hi, wlo, whi, ok)
        res["ok"] = res["ok"] and ok
    res["ok"] = res["ok"] and res["seam"] <= SEAM_LIMIT
    return res


def combined_report(clips):
    """Worst cases as the game layers them: locomotion lower body + aim BS1D at every 0.1 of
    the +-70 deg range (incl. the extremes and the in-between blends) + crouch additive or run
    pump. PB_Head must stay in its window and the waist seams closed. Returns failures."""
    by = {c.name: c for c in clips}
    blends = [round(-1.0 + 0.1 * i, 3) for i in range(21)]
    fails, seam = [], 0.0
    worst = {"stand": [9.0, -9.0], "crouch": [9.0, -9.0]}
    print("combined worst cases (locomotion + aim +-%d deg + crouch / run pump additive):" % AIM_PITCH)
    for weapon in ("rifle", "pistol", "none", "sword", "hammer"):
        aims = [(x, aim_blend(by, weapon, x)) for x in blends]
        res = combined_eval(by, aims, by["crouch_upper_" + weapon].frames[0][1], by["run_pump_" + weapon])
        seam = max(seam, res["seam"])
        for cls in ("stand", "crouch"):
            lo, hi, wlo, whi, ok = res[cls]
            worst[cls] = [min(worst[cls][0], lo), max(worst[cls][1], hi)]
            if not ok:
                fails.append("combined %s %s" % (cls, weapon))
            print("  %-6s %-6s head min %.3f (%s)  max %.3f (%s)  %s"
                  % (cls, weapon, lo, wlo, hi, whi, "ok" if ok else "FAIL"))
    print("  overall: stand %.3f-%.3f (window %.2f-%.2f), crouch %.3f-%.3f (window %.3f-%.3f)"
          % (worst["stand"][0], worst["stand"][1], HEAD_STAND - HEAD_TOL, HEAD_STAND + HEAD_TOL,
             worst["crouch"][0], worst["crouch"][1], HEAD_CROUCH - HEAD_TOL, HEAD_CROUCH + HEAD_TOL))
    print("  max waist seam opening / chest uncover %.1f mm (limit %.0f mm)" % (1000 * seam, 1000 * SEAM_LIMIT))
    if seam > SEAM_LIMIT:
        fails.append("seams")
    return fails


def gait_report(clips):
    """Per locomotion family: pelvis height and vertical travel; per-foot ground contact (any
    sole corner on the floor, so heel/toe rolls count) as a share of the cycle; worst slip of
    the lowest sole corner while in contact against the clip's authored ground speed (incl. the
    strafe cut); lowest sole; highest swing clearance of the sole."""
    fam = {"walk": WALK_SPEED, "run": RUN_SPEED, "crouch_walk": CROUCH_SPEED}
    by_name = {c.name: c for c in clips}
    eps = 0.003
    for f, speed in fam.items():
        travel, contact, pel, slip, sole, lift = [], [], [], 0.0, 9.0, 0.0
        for k, deg in DIRS.items():
            c = by_name[f + "_" + k]
            d = move_dir(deg)
            ground = -d * speed * (1.0 - LATERAL_STRIDE_CUT * abs(d[0]))
            ys = [p.pelvis[1] for _, p in c.frames]
            pel += ys
            travel.append(max(ys) - min(ys))
            n = hits = 0
            worlds = [(t, p.world()) for t, p in c.frames]
            for (t0, w0), (t1, w1) in zip(worlds, worlds[1:]):
                for s in "LR":
                    q0 = sole_points(w0["Boot_" + s][1], w0["Boot_" + s][0])
                    q1 = sole_points(w1["Boot_" + s][1], w1["Boot_" + s][0])
                    i0 = min(range(4), key=lambda i: q0[i][1])
                    low0, low1 = q0[i0][1], min(q[1] for q in q1)
                    sole = min(sole, low0)
                    lift = max(lift, low0)
                    n += 1
                    if low0 < eps and low1 < eps:
                        hits += 1
                        if q1[i0][1] < eps:  # same corner still down: it must ride the ground
                            slip = max(slip, float(np.linalg.norm(q1[i0] - q0[i0] - ground * (t1 - t0))))
            contact.append(hits / n)
        design = {"walk": WALK["beta"], "run": RUN["beta"], "crouch_walk": CROUCH_BETA}[f]
        print("%-11s pelvis %.3f-%.3f (travel %.1f cm) | foot contact %.0f%% of cycle by design "
              "(%.3f s/step), %.0f%% of sampled frame pairs | "
              "max contact slip %.1f mm/frame | lowest sole %.3f m | max sole clearance %.1f cm"
              % (f, min(pel), max(pel), 100 * max(travel), 100 * design, design * CYCLE,
                 100 * np.mean(contact), 1000 * slip, sole, 100 * lift))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.normpath(os.path.join(here, "..", ".."))
    clips = build()
    check()
    gait_report(clips)
    fails = head_report(clips)
    fails += combined_report(clips)
    by = {c.name: c for c in clips}
    for n in ("aim_rifle_up", "aim_rifle_down", "run_pump_rifle"):
        trs = [p.tr for _, p in by[n].frames]
        print("%-15s abdomen shift max %s cm, chest shift max %s cm (parent space; + = up / back)"
              % (n, np.round(100 * np.max([np.abs(t.get("Abdomen", np.zeros(3))) for t in trs], axis=0), 1),
                 np.round(100 * np.max([np.abs(t.get("Chest", np.zeros(3))) for t in trs], axis=0), 1)))
    for key in ("up", "down"):
        sh = AIM_SPINE_SHARE[key]
        print("aim spine share at %s %d deg: %.0f %% = %.1f deg (abdomen %.0f %% / chest %.0f %% of it), "
              "neck %.1f %%, head %.1f %%" % (key, AIM_PITCH, 100 * sh, sh * AIM_PITCH, 100 * AIM_SPLIT,
                                              100 * (1 - AIM_SPLIT), 100 * (1 - sh) * AIM_NECK_SHARE,
                                              100 * (1 - sh) * (1 - AIM_NECK_SHARE)))
    fails += floor_report(clips)
    print("max IK reach error %.3f m at %s" % (REPORT["ik_err"], REPORT["ik_where"]))
    print("max IK solve error %.4f m at %s" % (REPORT.get("solve_err", 0.0), REPORT.get("solve_where", "")))
    for w, m in sorted(HOLSTER_META.items()):
        print("holster_%s (grip in %s space, swap key %.3f of switch): origin %s basis rows %s | "
              "hand-to-holster error %.4f m" % (w, HOLSTER_PARENT[w], SWAP_FRACTION,
                                                 np.round(m[:3, 3], 4), np.round(m[:3, :3], 4).tolist(),
                                                 REPORT["holster_err_" + w]))
    for k, v in sorted(REPORT["per_clip"].items()):
        print("  IK clamp %.3f m  %s" % (v, k))
    if fails:
        print("CHECK FAILED: %s" % ", ".join(fails))
        sys.exit(1)
    print("head and floor checks passed")
    if "--check" in sys.argv:
        return
    path = os.path.join(repo, "assets/characters/player/anims/character_anims.tres")
    size = write(clips, path)
    print("wrote %s (%d clips, %.0f KB)" % (path, len(clips), size / 1024))
    for c in clips:
        print("  %-22s %5.3f s %s%s" % (c.name, c.length, "loop" if c.loop else "", " additive" if c.additive else ""))


if __name__ == "__main__":
    main()
