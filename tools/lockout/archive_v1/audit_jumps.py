#!/usr/bin/env python3
"""Lockout jump/traversal audit. Re-run after editing build_lockout.py:  python3 tools/lockout/audit_jumps.py

Movement model (scripts/player/player.gd + project.godot):
  gravity 22, jump_height 2.2 -> v0 = sqrt(2 g h); run 7.5; slide 9.2; air_accel 18 (cannot exceed 7.5 by
  steering, but keeps slide speed); coyote 0.1 s; capsule r 0.35, h 1.8; floor_max_angle 50 deg; snap 0.3.
  No auto-step: CharacterBody3D move_and_slide does not climb steps and floor_snap only pulls DOWN, so every
  rise is a ramp (<= 40 deg design limit) or a jump.
Ledge criterion: feet above the lip when the capsule centre reaches the lip line. Takeoff is counted from the
centre at the takeoff lip (no takeoff bonus); landing credits one capsule radius (capsule edge catches the lip
and the hemispherical bottom rides up onto it). Margin = (reach - gap) / gap, or height margin for vertical gates.
Verdicts: walk/ramp/drop; easy jump (margin >= 15% or standing jump works); skill jump (needs a running jump,
margin 0-15%); impossible.
"""
import ast, math
from pathlib import Path

G, H, RUN, SLIDE, AIR, COYOTE, R = 22.0, 2.2, 7.5, 9.2, 18.0, 0.1, 0.35
V0 = math.sqrt(2 * G * H)
SRC = Path(__file__).with_name("build_lockout.py")
L = {n.targets[0].id: ast.literal_eval(n.value) for n in ast.parse(SRC.read_text()).body
     if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("P", "RAMPS")}
BOX = {p[0]: p for p in L["P"]}
RAMP = {r[0]: r for r in L["RAMPS"]}


def t_at(h):
    """Time until feet are back down to h above takeoff (descending), None if apex < h."""
    d = V0 * V0 - 2 * G * h
    return None if d < 0 else (V0 + math.sqrt(d)) / G


def drift(t, v_start=0.0):
    """Horizontal distance with air steering from v_start toward RUN."""
    if v_start >= RUN:
        return v_start * t
    ta = (RUN - v_start) / AIR
    if t <= ta:
        return v_start * t + 0.5 * AIR * t * t
    return v_start * ta + 0.5 * AIR * ta * ta + RUN * (t - ta)


def jump(h, gap):
    t = t_at(h)
    if t is None:
        return dict(reach=0, stand=0, expert=0, ok=False)
    # expert: coyote takeoff (+0.75 m at run, lose 0.11 m height) and slide speed
    te = t_at(h + 0.5 * G * COYOTE ** 2) or 0
    return dict(reach=RUN * t + R, stand=drift(t) + R, expert=SLIDE * (COYOTE + te) + R, ok=True)


def top(n):
    return BOX[n][5] if n in BOX else None


def ramp_row(name):
    _n, (x0, z0, y0), (x1, z1, y1), w, _t, _g = RAMP[name]
    run = math.hypot(x1 - x0, z1 - z0)
    ang = math.degrees(math.atan2(y1 - y0, run))
    ok = ang <= 40 and w >= 1.8
    return y1 - y0, run, f"ramp {ang:.1f} deg, {w} m wide", "<=40 deg, >=1.8 m", "-", "ramp" if ok else "TOO STEEP/NARROW"


# (label, kind, a, b, gap_m)  kind: walk | ramp(name) | drop | jump | lift
C = [
 ("Bottom Mid <-> Green Hall", "walk", "BotMid_Floor", "GreenHall_Floor", 0),
 ("Green Hall -> Bottom Blue (west stairs)", "ramp", "BottomBlue_StairsW", None, 0),
 ("Bottom Blue <-> Top Mid (Blue Ramp)", "ramp", "BlueRamp", None, 0),
 ("Bottom Blue -> Left Mag", "ramp", "LeftMag_Ramp", None, 0),
 ("Bottom Blue -> Right Mag", "ramp", "RightMag_Ramp", None, 0),
 ("Green Hall -> Top Blue (grav lift)", "lift", "BlueLift_Pad", "TopBlue_Deck", 0),
 ("Top Blue -> Top Mid (drop over 3.4 m)", "drop", "TopBlue_Deck", "TopMid_Deck", 3.4),
 ("Mags -> Bottom Blue (drop)", "drop", "RightMag", "BottomBlue_Ledge", 0),
 ("Bottom Blue -> Elbow South", "walk", "BottomBlue_Ledge", "Elbow_South", 0),
 ("Elbow South -> Elbow North", "ramp", "Elbow_North", None, 0),
 ("ELBOW JUMP: Elbow North lip -> S1", "jump", ("Elbow_North", 2.7), "S1_Floor", 4.75),
 ("Top Mid <-> S1 (link)", "walk", "TopMid_Deck", "S1_TopMid_Link", 0),
 ("S1 -> S2 (inner stairs)", "ramp", "S1_S2_Stairs", None, 0),
 ("S2 -> S3 (Snipe Ramp, outside)", "ramp", "SnipeRamp", None, 0),
 ("Top Mid <-> BR1 (link)", "walk", "TopMid_Deck", "BR1_TopMid_Link", 0),
 ("BR1 -> BR2 (inner stairs, spiral 1)", "ramp", "BR1_BR2_Stairs", None, 0),
 ("BR2 -> BR3 (inner stairs, spiral 2)", "ramp", "BR2_BR3_Stairs", None, 0),
 ("Courtyard -> BR1 (Open Ramp)", "ramp", "OpenRamp", None, 0),
 ("OPEN RAMP JUMP: Open Ramp top -> BR2 west ledge", "jump", "OpenRamp_Top", "BR2_WestLedge", 4.3),
 ("BR2 west ledge -> BR2 bridge link (hop)", "jump", "BR2_WestLedge", "BR2_BridgeLink", 0.3),
 ("BR2 <-> Library (BR Bridge)", "walk", "BR2_BridgeLink", "BR_Bridge", 0),
 ("Library -> Top Mid (window drop, over parapet)", "drop", "Library_Floor", "TopMid_Deck", 2.3),
 ("Bottom Mid <-> Sword hall (door)", "walk", "BotMid_Floor", "Sword_Hall_Floor", 0),
 ("Sword hall <-> Sword room", "ramp", "Sword_Ramp", None, 0),
 ("Bottom Mid -> Top Mid (no stairs: jump)", "jump", "BotMid_Floor", "TopMid_Deck", 0.5),
 ("Green Hall -> Bottom Blue (direct jump)", "jump", "GreenHall_Floor", "BottomBlue_Ledge", 0.5),
]


def lift():
    v = 12.0  # GravLift.lift_speed
    pad, deck = BOX["BlueLift_Pad"], BOX["TopBlue_Deck"]
    vol_top = deck[5] + 1.0
    coast = v * v / (2 * G)
    t_land = (v + math.sqrt(v * v + 2 * G * (vol_top - deck[5]))) / G
    rise_t = (vol_top - pad[5]) / v
    edge_gap = (pad[2] - pad[4] / 2) - (deck[2] + deck[4] / 2)
    return dict(v=v, vol_top=vol_top, apex=vol_top + coast, t_land=t_land, rise_t=rise_t,
                drift_exit=drift(t_land), edge_gap=edge_gap,
                drift_total=drift(rise_t + t_land), deck_depth=deck[4],
                v_needed=math.sqrt(2 * G * (deck[5] + R - pad[5])))


def main():
    print(f"v0 = {V0:.3f} m/s, apex {H} m, air time (flat) {2*V0/G:.3f} s, flat reach {RUN*2*V0/G:.2f} m "
          f"(+{R} capsule = {RUN*2*V0/G+R:.2f}), slide reach {SLIDE*2*V0/G+R:.2f} m\n")
    print("| Connection | dY (m) | Gap (m) | Required | Available | Margin | Verdict |\n|---|---|---|---|---|---|---|")
    for label, kind, a, b, gap in C:
        if kind == "ramp":
            dy, run, req, av, m, v = ramp_row(a)
            print(f"| {label} | {dy:+.2f} | {run:.1f} run | {av} | {req} | {m} | {v} |")
            continue
        ya = a[1] if isinstance(a, tuple) else top(a)
        yb = top(b)
        dy = yb - ya
        if kind == "walk":
            print(f"| {label} | {dy:+.2f} | 0 | level | level | - | walk |")
        elif kind == "drop":
            t = math.sqrt(2 * -dy / G)
            print(f"| {label} | {dy:+.2f} | {gap} | walk-off reach {gap} m | {RUN*t+R:.2f} m | "
                  f"{(RUN*t+R)/gap-1 if gap else 0:+.0%} | drop |")
        elif kind == "lift":
            l = lift()
            print(f"| {label} | {dy:+.2f} | {l['edge_gap']:.1f} | exit v >= {l['v_needed']:.2f} m/s | "
                  f"{l['v']} m/s (apex {l['apex']:.2f} m) | {(l['apex']-yb)/(yb-ya):+.0%} height | lift |")
        else:
            j = jump(dy, gap)
            if not j["ok"]:
                print(f"| {label} | {dy:+.2f} | {gap} | feet > {dy:.2f} m | apex {H} m | - | impossible |")
                continue
            m = (j["reach"] - gap) / gap
            hm = (H - dy) / dy if dy > 0 else 9
            mm = min(m, hm)
            v = ("impossible" if mm < 0 else "easy jump" if (mm >= 0.15 or j["stand"] >= gap)
                 else "skill jump (running)")
            print(f"| {label} | {dy:+.2f} | {gap} | {gap} m at feet>{dy:.2f} | run {j['reach']:.2f} / stand "
                  f"{j['stand']:.2f} / slide+coyote {j['expert']:.2f} m | {m:+.1%} (height {hm:+.0%}) | {v} |")
    l = lift()
    print(f"\nGrav lift: lift_speed {l['v']} m/s, volume to y={l['vol_top']}, coast apex {l['apex']:.2f} m, "
          f"{l['rise_t']:.2f} s in column + {l['t_land']:.2f} s exit->deck; column->deck edge gap {l['edge_gap']:.2f} m; "
          f"air drift after exit {l['drift_exit']:.2f} m (deck depth {l['deck_depth']} m, north parapet catches overshoot); "
          f"minimum exit speed to clear the deck lip from the pad {l['v_needed']:.2f} m/s.")


if __name__ == "__main__":
    main()
