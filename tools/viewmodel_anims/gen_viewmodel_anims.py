#!/usr/bin/env python3
"""Generate first-person viewmodel AnimationLibraries.

    python3 tools/viewmodel_anims/gen_viewmodel_anims.py [--check]

Writes assets/weapons/viewmodel/<weapon>.tres. Pure python, no Godot, no numpy.

* marksman_carbine, combat_shotgun, directed_energy_rifle (rocket launcher): the full set the
  weapon scene's AnimationPlayer uses as its default library: RESET, idle, reload_tactical,
  reload_empty, melee (ViewmodelReload / ViewmodelMelee contract) and fire / fire_empty
  (ViewmodelFire).
* longsword, gravity_hammer: RESET, idle and melee only (the longsword also melee_b, the
  backhand; ViewmodelMelee alternates the two). Their trigger swings through
  Weapon.melee(), so the melee clip is the attack: the sword slashes across, the hammer comes
  up overhead and slams down (its windup is stretched to WeaponData.smash_delay by
  ViewmodelMelee, which scales the 0 .. MELEE_HIT windup to the time to hit).
* standard_issue_rifle, service_pistol: an "fx" library with only fire / fire_empty (their
  reload and melee clips are hand-keyed inside their scenes). fire_empty locks the bolt / slide
  back on the last round, which is the pose their reload_empty clips start from.

Rest poses are read from the weapon scenes, so moving a part in the scene moves its clips.
The carbine reloads and butt-strokes like the rifle: its clips are the rifle scene's clips
retargeted (each key moved by the part's rest difference, times scaled to reload_time).
Every clip keys every animated property (like the hand-keyed clips), so any clip played from
any other lands in a known pose. Rules checked by --check (and on every write):
  * reload clip length == WeaponData.reload_time
  * the sfx_mag_seat (or last sfx_shell_insert) key sits at reload_insert_fraction * length
  * melee has its ViewmodelMelee _on_hit_frame key at MELEE_HIT
  * every clip starts and ends on the rest pose (fire_empty / reload_empty excepted where
    the locked part is the point)
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = "assets/weapons/viewmodel"
FPS = 30.0
MELEE_HIT = 0.1  # ViewmodelMelee.hit_time on every weapon scene


# ---------------------------------------------------------------- scene / resource reading
def read(rel):
    with open(os.path.join(REPO, rel)) as f:
        return f.read()


def floats(s):
    return [float(x) for x in s.split(",")]


def scene_rest(rel):
    """{node: (origin, visible)} for the root's direct children, plus "." (root origin)."""
    text = read(rel)
    rest = {}
    for m in re.finditer(r'\[node name="(\w+)" type="\w+"( parent="([^"]*)")?.*\]\n((?:[^\[\n].*\n|\n)*)', text):
        name, parent, body = m.group(1), m.group(3), m.group(4)
        t = re.search(r"transform = Transform3D\(([^)]*)\)", body)
        origin = tuple(floats(t.group(1))[9:12]) if t else (0.0, 0.0, 0.0)
        vis = not re.search(r"^visible = false", body, re.M)
        if parent is None:
            rest["."] = (origin, True)
        elif parent == ".":
            rest[name] = (origin, vis)
    return rest


def weapon_data(name):
    text = read("resources/weapons/%s.tres" % name)
    get = lambda k: float(re.search(r"^%s = ([\d.]+)" % k, text, re.M).group(1))
    return {"reload_time": get("reload_time"), "insert": get("reload_insert_fraction")}


def scene_clips(rel):
    """Hand-keyed clips of a scene: {clip: {"length", "tracks": {path: [(t, value)]},
    "methods": {node: [(t, method, args)]}}}. Values: tuples (Vector3) or bools."""
    text = read(rel)
    clips = {}
    for m in re.finditer(r'\[sub_resource type="Animation" id="Animation_(\w+)"\](.*?)(?=\n\[)', text, re.S):
        body = m.group(2)
        clip = {"length": float(re.search(r"length = ([\d.]+)", body).group(1)), "tracks": {}, "methods": {}}
        for tm in re.finditer(r'tracks/\d+/type = "(\w+)".*?path = NodePath\("([^"]+)"\).*?keys = \{(.*?)\n\}\n', body + "\n", re.S):
            kind, path, keys = tm.groups()
            times = floats(re.search(r'"times": PackedFloat32Array\(([^)]*)\)', keys).group(1))
            if kind == "method":
                calls = re.findall(r'"args": \[(.*?)\],\s*"method": &"(\w+)"', keys, re.S)
                clip["methods"][path] = [(t, meth, args) for t, (args, meth) in zip(times, calls)]
                continue
            vals = re.search(r'"values": \[(.*)\]', keys, re.S).group(1)
            if "Vector3" in vals:
                vs = [tuple(floats(v)) for v in re.findall(r"Vector3\(([^)]*)\)", vals)]
            else:
                vs = [v.strip() == "true" for v in vals.split(",")]
            clip["tracks"][path] = list(zip(times, vs))
        clips[m.group(1)] = clip
    return clips


# ---------------------------------------------------------------- clip building
def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


class Clip:
    """keys: {path: [(t, value)]}. Vector3 tracks are eased (smoothstep between keys, resampled
    at FPS); bool tracks are discrete. methods: {node: [(t, method, args_text)]}."""

    def __init__(self, name, length):
        self.name = name
        self.length = length
        self.keys = {}
        self.methods = {}
        self.linear = False  # True: keys are already the timing (retargeted), no easing

    def key(self, path, t, value):
        self.keys.setdefault(path, []).append((t, value))
        return self

    def event(self, node, t, method, args):
        self.methods.setdefault(node, []).append((t, method, args))
        return self

    def sfx(self, t, name, kick=0.0, node="ViewmodelReload"):
        return self.event(node, t, "_anim_event", '&"%s", %s' % (name, fmt(kick)))

    def renamed(self, name):
        self.name = name
        return self


def ease_sample(keys, length, linear=False):
    keys = sorted(keys, key=lambda k: k[0])
    if len(keys) == 1:
        return keys
    times = sorted(set([min(i / FPS, length) for i in range(int(round(length * FPS)) + 1)] + [k[0] for k in keys]))
    out = []
    for t in times:
        if t <= keys[0][0]:
            out.append((t, keys[0][1]))
            continue
        for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
            if t <= t1:
                u = (t - t0) / (t1 - t0) if t1 > t0 else 1.0
                u = u if linear else smooth(u)
                out.append((t, tuple(a + (b - a) * u for a, b in zip(v0, v1))))
                break
        else:
            out.append((t, keys[-1][1]))
    # drop keys that are collinear repeats of their neighbours (constant spans)
    slim = [out[0]]
    for i in range(1, len(out) - 1):
        if not (out[i][1] == slim[-1][1] == out[i + 1][1]):
            slim.append(out[i])
    slim.append(out[-1])
    return slim


def fmt(x):
    if isinstance(x, bool):
        return "true" if x else "false"
    if abs(x) < 1e-7:
        return "0"
    s = "%.5g" % x
    return "0" if s in ("-0", "0") else s


def v3(v):
    return "Vector3(%s)" % ", ".join(fmt(x) for x in v)


def fill_rest(clips, rest, paths):
    """Every clip keys every path in `paths`; missing ones hold the rest value."""
    for c in clips:
        for path in paths:
            if path not in c.keys:
                node, prop = path.split(":")
                origin, vis = rest[node]
                val = vis if prop == "visible" else (origin if prop == "position" else (0.0, 0.0, 0.0))
                c.key(path, 0.0, val).key(path, c.length, val)


def write_library(rel, clips):
    out = ['[gd_resource type="AnimationLibrary" load_steps=%d format=3]' % (len(clips) + 1), ""]
    for c in clips:
        out += ['[sub_resource type="Animation" id="Animation_%s"]' % c.name,
                'resource_name = &"%s"' % c.name, "length = %s" % fmt(c.length)]
        ti = 0
        for path in sorted(c.keys):
            ks = c.keys[path]
            discrete = isinstance(ks[0][1], bool)
            ks = sorted(ks, key=lambda k: k[0]) if discrete else ease_sample(ks, c.length, c.linear)
            out += ['tracks/%d/type = "value"' % ti, "tracks/%d/imported = false" % ti,
                    "tracks/%d/enabled = true" % ti, 'tracks/%d/path = NodePath("%s")' % (ti, path),
                    "tracks/%d/interp = 1" % ti, "tracks/%d/loop_wrap = true" % ti,
                    "tracks/%d/keys = {" % ti,
                    '"times": PackedFloat32Array(%s),' % ", ".join(fmt(t) for t, _ in ks),
                    '"transitions": PackedFloat32Array(%s),' % ", ".join("1" for _ in ks),
                    '"update": %d,' % (1 if discrete else 0),
                    '"values": [%s]' % ", ".join(fmt(v) if discrete else v3(v) for _, v in ks), "}"]
            ti += 1
        for node in sorted(c.methods):
            ev = sorted(c.methods[node], key=lambda e: e[0])
            out += ['tracks/%d/type = "method"' % ti, "tracks/%d/imported = false" % ti,
                    "tracks/%d/enabled = true" % ti, 'tracks/%d/path = NodePath("%s")' % (ti, node),
                    "tracks/%d/interp = 1" % ti, "tracks/%d/loop_wrap = true" % ti,
                    "tracks/%d/keys = {" % ti,
                    '"times": PackedFloat32Array(%s),' % ", ".join(fmt(e[0]) for e in ev),
                    '"transitions": PackedFloat32Array(%s),' % ", ".join("1" for _ in ev),
                    '"values": [%s]' % ", ".join('{\n"args": [%s],\n"method": &"%s"\n}' % (e[2], e[1]) for e in ev),
                    "}"]
            ti += 1
        out.append("")
    out.append("[resource]")
    out.append("_data = {")
    out.append(",\n".join('&"%s": SubResource("Animation_%s")' % (c.name, c.name) for c in clips))
    out.append("}")
    path = os.path.join(REPO, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def rest_clip(name, rest, paths):
    c = Clip(name, 0.001)
    fill_rest([c], rest, paths)
    for path in c.keys:  # one key is enough for a pose clip
        c.keys[path] = c.keys[path][:1]
    return c


# ---------------------------------------------------------------- carbine (retargeted rifle)
RIFLE_SCENE = "scenes/weapons/standard_issue_rifle.tscn"


def retarget(src, name, rest_src, rest_dst, paths, scale=1.0, length=None):
    """Copy a rifle clip onto another weapon: positions move by the rest difference, times
    scale. Tracks for parts the target lacks are dropped."""
    c = Clip(name, length if length is not None else src["length"] * scale)
    for path, ks in src["tracks"].items():
        node, prop = path.split(":")
        if node not in rest_dst or path not in paths:
            continue
        for t, v in ks:
            if prop == "position":
                v = add(sub(v, rest_src[node][0]), rest_dst[node][0])
            c.key(path, t * scale, v)
    for node, ev in src["methods"].items():
        for t, meth, args in ev:
            c.event(node, t * scale, meth, args)
    c.linear = True
    return c


def carbine():
    scene = "scenes/weapons/marksman_carbine.tscn"
    rest, rifle_rest = scene_rest(scene), scene_rest(RIFLE_SCENE)
    data = weapon_data("marksman_carbine")
    rifle = scene_clips(RIFLE_SCENE)
    paths = [".:position", ".:rotation", "Magazine:position", "Magazine:visible", "LeftHand:position",
             "ChargingHandle:position"]
    k = data["reload_time"] / rifle["reload_empty"]["length"]
    clips = [retarget(rifle["reload_tactical"], "reload_tactical", rifle_rest, rest, paths, k),
             retarget(rifle["reload_empty"], "reload_empty", rifle_rest, rest, paths, k),
             retarget(rifle["melee"], "melee", rifle_rest, rest, paths)]
    # Bolt-action feel for a semi-auto DMR: the off hand stays, the gun bucks and settles.
    clips.append(Clip("fire", 0.3).key(".:rotation", 0.0, (0, 0, 0)).key(".:rotation", 0.04, (0.05, 0.0, -0.02))
                 .key(".:rotation", 0.3, (0, 0, 0)))
    clips.append(Clip("fire_empty", 0.3).key(".:rotation", 0.0, (0, 0, 0))
                 .key(".:rotation", 0.04, (0.05, 0.0, -0.02)).key(".:rotation", 0.3, (0, 0, 0)))
    return finish(clips, rest, paths, data)


# ---------------------------------------------------------------- shotgun
def shotgun():
    scene = "scenes/weapons/combat_shotgun.tscn"
    rest = scene_rest(scene)
    data = weapon_data("combat_shotgun")
    L = data["reload_time"]
    seat = data["insert"] * L
    R = rest["."][0]
    hand, pump, shell = rest["LeftHand"][0], rest["Pump"][0], rest["Shell"][0]
    belt = (-0.12, -0.42, 0.06)          # off hand at the shell caddy (weapon space)
    port = (0.0, -0.085, -0.02)          # loading port under the receiver
    tilt_pos, tilt_rot = (0.15, -0.215, -0.36), (0.12, 0.08, -0.5)
    paths = [".:position", ".:rotation", "LeftHand:position", "Pump:position", "Shell:position", "Shell:visible"]

    def reload(name, empty):
        c = Clip(name, L)
        c.key(".:position", 0, R).key(".:position", 0.28, tilt_pos)
        c.key(".:rotation", 0, (0, 0, 0)).key(".:rotation", 0.28, tilt_rot)
        c.key("LeftHand:position", 0, hand).key("LeftHand:position", 0.22, add(hand, (-0.03, -0.08, 0.06)))
        c.key("Shell:visible", 0, False).key("Shell:position", 0, shell)
        # Four shells, the last one seated on the insert key.
        n, step = 4, 0.36
        first = seat - 0.24 - (n - 1) * step
        for i in range(n):
            t0 = first + i * step
            c.key("LeftHand:position", t0, belt)
            c.key("Shell:position", t0, add(belt, (0.0, 0.035, -0.03)))
            c.key("Shell:visible", t0, True)
            c.key("LeftHand:position", t0 + 0.17, add(port, (0.0, -0.05, 0.0)))
            c.key("Shell:position", t0 + 0.17, add(port, (0.0, -0.02, -0.03)))
            c.key("LeftHand:position", t0 + 0.24, add(port, (0.0, -0.035, 0.03)))
            c.key("Shell:position", t0 + 0.24, add(port, (0.0, 0.0, 0.0)))
            c.key("Shell:visible", t0 + 0.245, False)
            c.key("Shell:position", t0 + 0.245, shell)
            c.key(".:position", t0 + 0.24, add(tilt_pos, (0, 0.006, 0)))
            c.key(".:position", t0 + 0.3, tilt_pos)
            c.sfx(t0 + 0.05, "sfx_shell_grab")
            c.sfx(t0 + 0.24, "sfx_shell_insert" if i < n - 1 else "sfx_mag_seat", 0.35 if i < n - 1 else 0.6)
        back = seat + 0.18
        c.key("LeftHand:position", back, hand)
        c.key(".:position", back - 0.1, tilt_pos).key(".:rotation", back - 0.1, tilt_rot)
        c.key(".:position", back + 0.12, R).key(".:rotation", back + 0.12, (0, 0, 0))
        c.sfx(back, "sfx_regrip")
        if empty:
            # Chamber a round: rack the pump.
            r0 = back + 0.16
            c.key("Pump:position", 0, pump).key("Pump:position", r0, pump)
            c.key("Pump:position", r0 + 0.12, add(pump, (0, 0, 0.09)))
            c.key("Pump:position", r0 + 0.24, pump)
            c.key("LeftHand:position", r0, hand)
            c.key("LeftHand:position", r0 + 0.12, add(hand, (0, 0, 0.09)))
            c.key("LeftHand:position", r0 + 0.24, hand)
            c.key(".:rotation", r0 + 0.12, (0.03, 0.0, 0.03))
            c.key(".:rotation", r0 + 0.3, (0, 0, 0))
            c.sfx(r0 + 0.1, "sfx_pump_back").sfx(r0 + 0.24, "sfx_pump_forward", 0.5)
        c.key("LeftHand:position", L, hand).key(".:position", L, R).key(".:rotation", L, (0, 0, 0))
        c.key("Shell:visible", L, False)
        return c

    def fire(name):
        # WeaponFx plays the pump sound at cycle_delay 0.3 s: the rack lands on it.
        c = Clip(name, 0.62)
        for path, base in (("Pump:position", pump), ("LeftHand:position", hand)):
            c.key(path, 0, base).key(path, 0.26, base).key(path, 0.36, add(base, (0, 0, 0.09)))
            c.key(path, 0.47, base).key(path, 0.62, base)
        c.key(".:rotation", 0, (0, 0, 0)).key(".:rotation", 0.36, (0.04, 0.0, 0.05)).key(".:rotation", 0.62, (0, 0, 0))
        return c

    melee = Clip("melee", 0.8)
    for t, p, r in ((0, R, (0, 0, 0)), (0.067, add(R, (0.04, 0.02, 0.05)), (0.14, 0.22, -0.2)),
                    (MELEE_HIT, add(R, (-0.11, 0.06, -0.15)), (0.26, -0.72, 0.62)),
                    (0.15, add(R, (-0.105, 0.058, -0.14)), (0.25, -0.68, 0.58)),
                    (0.32, add(R, (-0.02, 0.01, -0.03)), (0.06, -0.16, 0.12)),
                    (0.55, add(R, (0.003, -0.003, 0.004)), (-0.02, 0.04, -0.04)), (0.8, R, (0, 0, 0))):
        melee.key(".:position", t, p).key(".:rotation", t, r)
    melee.event("ViewmodelMelee", MELEE_HIT, "_on_hit_frame", "")
    clips = [reload("reload_tactical", False), reload("reload_empty", True), melee, fire("fire"), fire("fire_empty")]
    return finish(clips, rest, paths, data)


# ---------------------------------------------------------------- rocket launcher
def rocket():
    scene = "scenes/weapons/directed_energy_rifle.tscn"
    rest = scene_rest(scene)
    data = weapon_data("directed_energy_rifle")
    L = data["reload_time"]
    seat = data["insert"] * L
    R = rest["."][0]
    hand, pack, tip = rest["LeftHand"][0], rest["ReloadRocket"][0], rest["RocketTip"][0]
    rear = (0.0, 0.02, 0.34)
    show_pos, show_rot = (0.06, -0.12, -0.52), (0.05, -0.62, 0.12)  # rear swung into view
    paths = [".:position", ".:rotation", "LeftHand:position", "ReloadRocket:position", "ReloadRocket:visible",
             "RocketTip:visible"]

    def reload(name, empty):
        c = Clip(name, L)
        c.key(".:position", 0, R).key(".:position", 0.32, show_pos).key(".:position", seat + 0.25, show_pos)
        c.key(".:position", seat + 0.5, R).key(".:position", L, R)
        c.key(".:rotation", 0, (0, 0, 0)).key(".:rotation", 0.32, show_rot).key(".:rotation", seat + 0.25, show_rot)
        c.key(".:rotation", seat + 0.5, (0, 0, 0)).key(".:rotation", L, (0, 0, 0))
        c.key("RocketTip:visible", 0, not empty).key("RocketTip:visible", seat, True)
        c.key("ReloadRocket:visible", 0, False)
        # Pull the spent pack out of the rear, drop it, bring a fresh one up, seat it.
        c.key("LeftHand:position", 0, hand).key("LeftHand:position", 0.38, add(rear, (-0.05, -0.08, 0.08)))
        c.key("ReloadRocket:position", 0, rear).key("ReloadRocket:visible", 0.4, True)
        c.key("LeftHand:position", 0.62, add(rear, (-0.04, -0.07, 0.24)))
        c.key("ReloadRocket:position", 0.4, rear).key("ReloadRocket:position", 0.62, add(rear, (0, 0, 0.18)))
        c.key("LeftHand:position", 0.82, (-0.16, -0.5, 0.42))
        c.key("ReloadRocket:position", 0.82, (-0.12, -0.46, 0.44))
        c.key("ReloadRocket:visible", 0.84, False).key("ReloadRocket:position", 0.84, (-0.16, -0.48, 0.5))
        c.key("LeftHand:position", 1.12, (-0.18, -0.52, 0.5))
        c.key("ReloadRocket:visible", 1.14, True)
        c.key("ReloadRocket:position", 1.14, (-0.15, -0.46, 0.52))
        c.key("LeftHand:position", seat - 0.32, add(rear, (-0.04, -0.07, 0.24)))
        c.key("ReloadRocket:position", seat - 0.32, add(rear, (0, 0, 0.2)))
        c.key("LeftHand:position", seat, add(rear, (-0.05, -0.08, 0.06)))
        c.key("ReloadRocket:position", seat, rear)
        c.key("ReloadRocket:visible", seat + 0.01, False).key("ReloadRocket:position", seat + 0.01, pack)
        c.key("LeftHand:position", seat + 0.16, (0.06, 0.01, 0.12))  # slap the latch
        c.key("LeftHand:position", seat + 0.42, hand).key("LeftHand:position", L, hand)
        c.key("ReloadRocket:visible", L, False).key("RocketTip:visible", L, True)
        c.sfx(0.4, "sfx_mag_release").sfx(0.62, "sfx_mag_out").sfx(0.84, "sfx_mag_drop")
        c.sfx(1.14, "sfx_mag_pouch").sfx(seat, "sfx_mag_seat", 1.0).sfx(seat + 0.16, "sfx_bolt_release", 0.6)
        c.sfx(seat + 0.42, "sfx_regrip")
        return c

    def fire(name, empty):
        c = Clip(name, 0.45)
        c.key(".:rotation", 0, (0, 0, 0)).key(".:rotation", 0.05, (0.07, 0.0, -0.03)).key(".:rotation", 0.45, (0, 0, 0))
        if empty:
            c.key("RocketTip:visible", 0, True).key("RocketTip:visible", 0.01, False)
        return c

    melee = Clip("melee", 0.8)  # forward shove with the tube's front rim
    for t, p, r in ((0, R, (0, 0, 0)), (0.067, add(R, (0.03, 0.03, 0.06)), (0.1, 0.1, 0.05)),
                    (MELEE_HIT, add(R, (-0.06, 0.04, -0.2)), (-0.05, -0.3, 0.35)),
                    (0.15, add(R, (-0.058, 0.038, -0.19)), (-0.045, -0.28, 0.33)),
                    (0.35, add(R, (-0.01, 0.005, -0.03)), (0.0, -0.05, 0.06)), (0.8, R, (0, 0, 0))):
        melee.key(".:position", t, p).key(".:rotation", t, r)
    melee.event("ViewmodelMelee", MELEE_HIT, "_on_hit_frame", "")
    clips = [reload("reload_tactical", False), reload("reload_empty", True), melee, fire("fire", False),
             fire("fire_empty", True)]
    return finish(clips, rest, paths, data)


# ---------------------------------------------------------------- melee weapons
def swing(scene, sets):
    """Melee-only set from {clip name: (length, [(t, offset from rest, rotation)])}: root
    position / rotation keys, the hit at MELEE_HIT. Big arcs with anticipation before the hit
    and an overshoot after it, so the swing reads as weight moving, not a slide between poses."""
    rest = scene_rest(scene)
    R = rest["."][0]
    clips = []
    for name, (length, keys) in sets.items():
        c = Clip(name, length)
        for t, off, rot in keys:
            c.key(".:position", t, add(R, off)).key(".:rotation", t, rot)
        c.event("ViewmodelMelee", MELEE_HIT, "_on_hit_frame", "")
        clips.append(c)
    return finish(clips, rest, [".:position", ".:rotation"], {"reload_time": 0.0, "insert": 1.0})


def sword(scene="scenes/weapons/longsword.tscn"):
    # Rest is the side guard (blade up at the right). melee: forehand - cocked high right, cut
    # down and across to the left, overshoot, settle back to guard. melee_b (ViewmodelMelee
    # alternates): backhand - wound to the left, a flat cut out to the right.
    return swing(scene, {
        "melee": (0.7, [
            (0.0, (0, 0, 0), (0, 0, 0)),
            (0.067, (0.1, 0.16, 0.1), (0.45, -0.45, -0.85)),
            (MELEE_HIT, (-0.24, -0.04, -0.2), (-0.6, 0.85, 0.95)),
            (0.16, (-0.32, -0.13, -0.1), (-0.85, 1.1, 1.1)),
            (0.3, (-0.14, -0.08, 0.0), (-0.35, 0.45, 0.45)),
            (0.7, (0, 0, 0), (0, 0, 0))]),
        "melee_b": (0.7, [
            (0.0, (0, 0, 0), (0, 0, 0)),
            (0.067, (-0.24, 0.08, 0.06), (0.2, 0.85, 0.55)),
            (MELEE_HIT, (0.1, 0.0, -0.26), (-0.2, -0.75, -0.55)),
            (0.16, (0.18, -0.05, -0.12), (-0.3, -1.05, -0.75)),
            (0.3, (0.07, -0.03, 0.0), (-0.1, -0.4, -0.3)),
            (0.7, (0, 0, 0), (0, 0, 0))]),
    })


def hammer():
    # Hauled up and back over the head, slammed down and forward, a bounce off the floor, the
    # weight held a beat, hauled back up. (The windup stretches to WeaponData.smash_delay.)
    return swing("scenes/weapons/gravity_hammer.tscn", {
        "melee": (1.0, [
            (0.0, (0, 0, 0), (0, 0, 0)),
            (0.067, (0.0, 0.26, 0.24), (0.95, 0.05, 0.15)),
            (MELEE_HIT, (0.02, -0.2, -0.3), (-0.95, 0.05, 0.3)),
            (0.15, (0.02, -0.15, -0.27), (-0.8, 0.05, 0.28)),
            (0.22, (0.02, -0.19, -0.29), (-0.9, 0.05, 0.3)),
            (0.42, (0.02, -0.18, -0.28), (-0.86, 0.05, 0.28)),
            (0.7, (0.0, -0.03, -0.03), (-0.12, 0.0, 0.05)),
            (1.0, (0, 0, 0), (0, 0, 0))]),
    })


# ---------------------------------------------------------------- New Ottoman issue weapons
# Scenes from tools/new_ottoman_weapons/gen_new_ottoman_weapon_scenes.py. The four rifles
# reload and butt-stroke like the rifle (retargeted, as the carbine; their LeftHand sits the
# rifle's 0.14 m ahead of the magazine so the hand meets it). Each gets its own fire clip.
NOE = "scenes/weapons/new_ottoman/%s.tscn"
NOE_RIFLE_PATHS = [".:position", ".:rotation", "Magazine:position", "Magazine:visible", "LeftHand:position",
                   "ChargingHandle:position"]


def noe_rifle(name, fire, fire_empty, melee=None, extra_paths=()):
    scene = NOE % name
    rest, rifle_rest = scene_rest(scene), scene_rest(RIFLE_SCENE)
    data = weapon_data("new_ottoman/" + name)
    rifle = scene_clips(RIFLE_SCENE)
    paths = NOE_RIFLE_PATHS + list(extra_paths)
    k = data["reload_time"] / rifle["reload_empty"]["length"]
    clips = [retarget(rifle["reload_tactical"], "reload_tactical", rifle_rest, rest, paths, k),
             retarget(rifle["reload_empty"], "reload_empty", rifle_rest, rest, paths, k),
             melee(rest) if melee else retarget(rifle["melee"], "melee", rifle_rest, rest, paths)]
    clips += [fire(rest).renamed("fire"), fire_empty(rest).renamed("fire_empty")]
    return finish(clips, rest, paths, data)


def buck(length, pitch, roll=0.0, peak=0.04):
    """Recoil rock of the whole gun (ViewmodelMotion adds the camera-side kick)."""
    return (Clip("fire", length).key(".:rotation", 0.0, (0, 0, 0)).key(".:rotation", peak, (pitch, 0.0, roll))
            .key(".:rotation", length, (0, 0, 0)))


def blowback(c, rest, travel, back=0.025, home=0.07):
    """The charging handle kicks back with the bolt and returns."""
    h = rest["ChargingHandle"][0]
    c.key("ChargingHandle:position", 0.0, h).key("ChargingHandle:position", back, add(h, (0, 0, travel)))
    c.key("ChargingHandle:position", home, h).key("ChargingHandle:position", c.length, h)
    return c


def tufek_lib():
    # Heavy semi-auto: a big buck and the handle slamming back.
    return noe_rifle("tufek", lambda r: blowback(buck(0.35, 0.065, -0.025), r, 0.04, home=0.09),
                     lambda r: blowback(buck(0.35, 0.065, -0.025), r, 0.04, home=0.09))


def long_rifle_lib():
    # Bolt action: the right hand leaves the grip, lifts the bolt, draws it, runs it home,
    # turns it down and goes back (0.8 s inside the 1.1 s between shots). The last round
    # doesn't cycle (the empty reload works the bolt).
    def fire(rest):
        c = buck(0.8, 0.06, -0.02, peak=0.045)
        h, hand = rest["ChargingHandle"][0], rest["RightHand"][0]
        knob = add(h, (0.03, -0.03, 0.0))  # hand box centre around the knob
        for t, dh in ((0.0, (0, 0, 0)), (0.3, (0, 0, 0)), (0.36, (0, 0.012, 0)), (0.46, (0, 0.012, 0.065)),
                      (0.55, (0, 0.012, 0)), (0.61, (0, 0, 0)), (0.8, (0, 0, 0))):
            c.key("ChargingHandle:position", t, add(h, dh))
            if 0.3 <= t <= 0.61:
                c.key("RightHand:position", t, add(knob, dh))
        c.key("RightHand:position", 0.0, hand).key("RightHand:position", 0.16, hand)
        c.key("RightHand:position", 0.75, hand).key("RightHand:position", 0.8, hand)
        c.key(".:rotation", 0.46, (0.01, 0.0, 0.05))
        return c

    def fire_empty(rest):
        return buck(0.35, 0.06, -0.02, peak=0.045)

    return noe_rifle("long_rifle", fire, fire_empty, extra_paths=["RightHand:position"])


def glaive_rifle_lib():
    # Light semi-auto; the melee is the bayonet: a straight thrust into the middle of the view
    # with the blade leading (the 5 m lunge carries the body in behind it).
    def melee(rest):
        R = rest["."][0]
        c = Clip("melee", 0.8)
        for t, p, r in ((0, R, (0, 0, 0)), (0.067, add(R, (0.025, -0.01, 0.08)), (0.05, 0.06, -0.04)),
                        (MELEE_HIT, add(R, (-0.075, 0.05, -0.27)), (-0.04, 0.13, 0.06)),
                        (0.15, add(R, (-0.072, 0.048, -0.26)), (-0.035, 0.125, 0.055)),
                        (0.32, add(R, (-0.02, 0.012, -0.07)), (-0.01, 0.03, 0.015)), (0.8, R, (0, 0, 0))):
            c.key(".:position", t, p).key(".:rotation", t, r)
        c.event("ViewmodelMelee", MELEE_HIT, "_on_hit_frame", "")
        return c

    fire = lambda r: blowback(buck(0.22, 0.04, -0.015, peak=0.03), r, 0.03)
    return noe_rifle("glaive_rifle", fire, fire, melee)


def raider_carbine_lib():
    # Automatic: only the handle cycles (each shot restarts the clip).
    fire = lambda r: blowback(Clip("fire", 0.09), r, 0.03, home=0.07)
    return noe_rifle("raider_carbine", fire, fire)


def humbara_lib():
    # Drum launcher. Reload: roll the gun, pull the drum down and out, toss it, fetch a full
    # one from the belt, seat it (the insert key at reload_insert_fraction), slap it home; the
    # empty reload also cocks the lever. Fire: the drum indexes a quarter turn (four chambers,
    # so the start at +90 deg is the same picture as rest).
    scene = NOE % "humbara_launcher"
    rest = scene_rest(scene)
    data = weapon_data("new_ottoman/humbara_launcher")
    L = data["reload_time"]
    seat = data["insert"] * L
    R = rest["."][0]
    hand, drum, lever = rest["LeftHand"][0], rest["Drum"][0], rest["ChargingHandle"][0]
    belt = (-0.15, -0.44, 0.1)
    tilt_pos, tilt_rot = add(R, (-0.02, 0.03, 0.0)), (0.1, 0.08, -0.45)
    paths = [".:position", ".:rotation", "LeftHand:position", "Drum:position", "Drum:visible", "Drum:rotation",
             "ChargingHandle:position"]

    def reload(name, empty):
        c = Clip(name, L)
        back = seat + 0.2
        c.key(".:position", 0, R).key(".:position", 0.28, tilt_pos).key(".:position", back, tilt_pos)
        c.key(".:rotation", 0, (0, 0, 0)).key(".:rotation", 0.28, tilt_rot).key(".:rotation", back, tilt_rot)
        c.key(".:position", back + 0.22, R).key(".:position", L, R)
        c.key(".:rotation", back + 0.22, (0, 0, 0)).key(".:rotation", L, (0, 0, 0))
        under = add(drum, (-0.045, -0.075, 0.0))  # hand box centre cupping the drum
        c.key("LeftHand:position", 0, hand).key("LeftHand:position", 0.24, under)
        c.key("Drum:position", 0, drum).key("Drum:position", 0.3, drum)
        c.key("Drum:position", 0.44, add(drum, (-0.05, -0.1, 0.01)))
        c.key("LeftHand:position", 0.44, add(under, (-0.05, -0.1, 0.01)))
        c.key("Drum:position", 0.56, add(drum, (-0.13, -0.32, 0.06)))
        c.key("Drum:visible", 0, True).key("Drum:visible", 0.57, False)
        c.key("Drum:position", 0.58, belt)
        c.key("LeftHand:position", 0.6, add(under, (-0.09, -0.2, 0.04)))
        c.key("LeftHand:position", 0.86, add(belt, (-0.045, -0.075, 0.0)))
        c.key("Drum:position", 0.9, belt).key("Drum:visible", 0.9, True)
        lift = add(drum, (-0.04, -0.11, 0.02))
        c.key("Drum:position", seat - 0.36, lift)
        c.key("LeftHand:position", seat - 0.36, add(lift, (-0.045, -0.075, 0.0)))
        c.key("Drum:position", seat, drum).key("LeftHand:position", seat, under)
        c.key("LeftHand:position", seat + 0.1, add(under, (0.0, 0.012, 0.0)))  # slap it home
        c.key("LeftHand:position", seat + 0.16, under)
        c.key("LeftHand:position", back + 0.15, hand).key("LeftHand:position", L, hand)
        c.key("Drum:position", L, drum).key("Drum:visible", L, True)
        c.sfx(0.26, "sfx_mag_release", 0.3).sfx(0.44, "sfx_mag_out").sfx(0.62, "sfx_mag_drop")
        c.sfx(0.9, "sfx_mag_pouch").sfx(seat, "sfx_mag_seat", 1.0).sfx(back + 0.12, "sfx_regrip")
        if empty:
            c0 = back + 0.04
            c.key("ChargingHandle:position", 0, lever).key("ChargingHandle:position", c0, lever)
            c.key("ChargingHandle:position", c0 + 0.08, add(lever, (0, 0, 0.05)))
            c.key("ChargingHandle:position", c0 + 0.16, lever).key("ChargingHandle:position", L, lever)
            c.sfx(c0 + 0.16, "sfx_bolt_release", 0.5)
        return c

    def fire(name):
        c = buck(0.45, 0.09, -0.03, peak=0.05).renamed(name)
        c.key("Drum:rotation", 0.0, (0, 0, 0)).key("Drum:rotation", 0.001, (0, 0, math.pi * 0.5))
        c.key("Drum:rotation", 0.12, (0, 0, math.pi * 0.5)).key("Drum:rotation", 0.3, (0, 0, 0))
        c.key("Drum:rotation", 0.45, (0, 0, 0))
        return c

    rifle_rest, rifle = scene_rest(RIFLE_SCENE), scene_clips(RIFLE_SCENE)
    clips = [reload("reload_tactical", False), reload("reload_empty", True),
             retarget(rifle["melee"], "melee", rifle_rest, rest, paths), fire("fire"), fire("fire_empty")]
    return finish(clips, rest, paths, data)


def noe_blade(name):
    # Sabre and yatagan are built on the longsword's frame and rest, so its swings fit them.
    return sword(NOE % name)


# ---------------------------------------------------------------- rifle / pistol fx
def rifle_fx():
    rest = scene_rest(RIFLE_SCENE)
    bolt, cover = rest["Bolt"][0], rest["PortCover"][0]
    fire = Clip("fire", 0.08)
    fire.key("Bolt:position", 0, bolt).key("Bolt:position", 0.025, add(bolt, (0, 0, 0.035))).key("Bolt:position", 0.07, bolt)
    fire.key("Bolt:position", 0.08, bolt)
    # Bolt locked back + port cover open: reload_empty's first frame (rifle scene).
    empty = Clip("fire_empty", 0.06)
    empty.key("Bolt:position", 0, bolt).key("Bolt:position", 0.025, add(bolt, (0, 0, 0.035)))
    empty.key("Bolt:position", 0.06, add(bolt, (0, 0, 0.035)))
    empty.key("PortCover:position", 0, cover).key("PortCover:position", 0.02, (0.04, -0.002, 0))
    empty.key("PortCover:rotation", 0, (0, 0, 0)).key("PortCover:rotation", 0.02, (0, 0, -1.396))
    return [fire, empty]


def pistol_fx():
    slide = scene_rest("scenes/weapons/service_pistol.tscn")["Slide"][0]
    fire = Clip("fire", 0.1)
    fire.key("Slide:position", 0, slide).key("Slide:position", 0.025, add(slide, (0, 0, 0.03)))
    fire.key("Slide:position", 0.08, slide).key("Slide:position", 0.1, slide)
    # Slide locked back: reload_empty's first frame (pistol scene).
    empty = Clip("fire_empty", 0.06)
    empty.key("Slide:position", 0, slide).key("Slide:position", 0.025, add(slide, (0, 0, 0.035)))
    empty.key("Slide:position", 0.06, add(slide, (0, 0, 0.035)))
    return [fire, empty]


# ---------------------------------------------------------------- checks
FAILS = []


def finish(clips, rest, paths, data):
    for c in clips:
        if c.name.startswith("reload_") and abs(c.length - data["reload_time"]) > 1e-6:
            FAILS.append("%s length %.3f != reload_time %.3f" % (c.name, c.length, data["reload_time"]))
        if c.name.startswith("reload_"):
            seat = data["insert"] * c.length
            seats = [t for t, m, a in c.methods.get("ViewmodelReload", []) if "sfx_mag_seat" in a]
            if not seats or abs(seats[-1] - seat) > 0.011:
                FAILS.append("%s seat key %s, want %.3f" % (c.name, seats, seat))
        if c.name in ("melee", "melee_b"):
            hits = [t for t, m, a in c.methods.get("ViewmodelMelee", []) if m == "_on_hit_frame"]
            if hits != [MELEE_HIT]:
                FAILS.append("melee hit keys %s, want [%s]" % (hits, MELEE_HIT))
    fill_rest(clips, rest, paths)
    for c in clips:
        for path, ks in c.keys.items():
            ks.sort(key=lambda k: k[0])
            node, prop = path.split(":")
            want = rest[node][1] if prop == "visible" else (rest[node][0] if prop == "position" else (0.0, 0.0, 0.0))
            for t, v in (ks[0], ks[-1]):
                locked = c.name.endswith("_empty") and (
                    (t == ks[0][0] and c.name.startswith("reload") and path == "RocketTip:visible")
                    or (t == ks[-1][0] and c.name.startswith("fire")))
                same = v == want if isinstance(v, bool) else max(abs(a - b) for a, b in zip(v, want)) < 1e-4
                if not same and not locked:
                    FAILS.append("%s %s at %.3f is %s, rest %s" % (c.name, path, t, v, want))
    return [rest_clip("RESET", rest, paths), rest_clip("idle", rest, paths)] + clips


def main():
    libs = {
        "marksman_carbine": carbine(),
        "combat_shotgun": shotgun(),
        "directed_energy_rifle": rocket(),
        "standard_issue_rifle_fx": rifle_fx(),
        "service_pistol_fx": pistol_fx(),
        "longsword": sword(),
        "gravity_hammer": hammer(),
        "new_ottoman/tufek": tufek_lib(),
        "new_ottoman/long_rifle": long_rifle_lib(),
        "new_ottoman/glaive_rifle": glaive_rifle_lib(),
        "new_ottoman/raider_carbine": raider_carbine_lib(),
        "new_ottoman/humbara_launcher": humbara_lib(),
        "new_ottoman/kilij": noe_blade("kilij"),
        "new_ottoman/yatagan": noe_blade("yatagan"),
    }
    for name, clips in libs.items():
        print("%-26s %s" % (name, ", ".join("%s %.2fs" % (c.name, c.length) for c in clips)))
    if FAILS:
        print("CHECK FAILED:\n  " + "\n  ".join(FAILS))
        sys.exit(1)
    print("viewmodel checks passed")
    if "--check" in sys.argv:
        return
    for name, clips in libs.items():
        write_library("%s/%s.tres" % (OUT, name), clips)
        print("wrote %s/%s.tres" % (OUT, name))


if __name__ == "__main__":
    main()
