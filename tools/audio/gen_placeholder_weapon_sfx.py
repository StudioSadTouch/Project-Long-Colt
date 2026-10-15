#!/usr/bin/env python3
"""Generate the PLACEHOLDER weapon sounds in assets/audio/weapons/ (pure Python, deterministic).

Each new roster gun gets one recognisable hook until real recordings exist:
  marksman_carbine_fire   sharp high crack with a long ringing tail (the "distinct report")
  combat_shotgun_fire     low, wide boom with a chest thump
  combat_shotgun_pump     rack back + forward (played after the blast)
  der_fire                descending energy zap
  der_charge              rising whine over the 0.75 s charge
  der_charged_fire        big, longer zap with a sub drop
  der_overheat            vent hiss
Run from the repo root:  python3 tools/audio/gen_placeholder_weapon_sfx.py
"""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parents[2] / "assets/audio/weapons"


def write(name, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s / peak * 0.9)) * 32767)) for s in samples)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)


def n(seconds):
    return int(seconds * RATE)


def lowpass(samples, alpha):
    out, y = [], 0.0
    for s in samples:
        y += alpha * (s - y)
        out.append(y)
    return out


def highpass(samples, alpha):
    low = lowpass(samples, alpha)
    return [s - l for s, l in zip(samples, low)]


def carbine(rng):
    length = n(0.9)
    noise = [rng.uniform(-1, 1) for _ in range(length)]
    crack = highpass(noise, 0.25)
    out = []
    for i in range(length):
        t = i / RATE
        body = crack[i] * math.exp(-t * 60.0)
        ring = 0.35 * math.sin(2 * math.pi * 1850 * t) * math.exp(-t * 9.0)
        tail = 0.25 * lowpass_noise_val(noise, i) * math.exp(-t * 4.0)
        echo = 0.3 * crack[i - n(0.12)] * math.exp(-(t - 0.12) * 40.0) if t > 0.12 else 0.0
        out.append(body + ring + tail + echo)
    return out


_lp_cache = {}


def lowpass_noise_val(noise, i):
    key = id(noise)
    if key not in _lp_cache:
        _lp_cache[key] = lowpass(noise, 0.05)
    return _lp_cache[key][i]


def shotgun(rng):
    length = n(0.7)
    noise = lowpass([rng.uniform(-1, 1) for _ in range(length)], 0.18)
    out = []
    for i in range(length):
        t = i / RATE
        blast = noise[i] * math.exp(-t * 9.0)
        thump = 0.9 * math.sin(2 * math.pi * (70 - 30 * t) * t) * math.exp(-t * 12.0)
        out.append(blast + thump)
    return out


def click(rng, at, length, out, gain, tone):
    for i in range(n(length)):
        t = i / RATE
        j = n(at) + i
        if j < len(out):
            out[j] += gain * (rng.uniform(-1, 1) * 0.6 + math.sin(2 * math.pi * tone * t)) * math.exp(-t * 90.0)


def pump(rng):
    out = [0.0] * n(0.45)
    click(rng, 0.0, 0.08, out, 1.0, 900)
    click(rng, 0.04, 0.12, out, 0.4, 300)  # slide rattle
    click(rng, 0.24, 0.08, out, 1.0, 1200)
    return out


def sweep(f0, f1, seconds, decay, harsh, rng):
    out, phase = [], 0.0
    for i in range(n(seconds)):
        t = i / RATE
        f = f0 + (f1 - f0) * (t / seconds)
        phase += 2 * math.pi * f / RATE
        tone = math.sin(phase) + 0.4 * math.copysign(1.0, math.sin(phase * 2.01))
        out.append((tone + harsh * rng.uniform(-1, 1)) * math.exp(-t * decay))
    return out


def charge(rng):
    out, phase = [], 0.0
    seconds = 0.8
    for i in range(n(seconds)):
        t = i / RATE
        f = 260 + 1100 * (t / seconds) ** 1.5
        phase += 2 * math.pi * f / RATE
        wobble = 1.0 + 0.3 * math.sin(2 * math.pi * 18 * t)
        out.append((math.sin(phase) + 0.2 * rng.uniform(-1, 1)) * min(1.0, t * 6) * wobble * 0.6)
    return out


def charged_fire(rng):
    zap = sweep(1600, 120, 0.55, 5.0, 0.35, rng)
    for i in range(len(zap)):
        t = i / RATE
        zap[i] += 0.8 * math.sin(2 * math.pi * (55 - 20 * t) * t) * math.exp(-t * 6.0)
    return zap


def vent(rng):
    length = n(1.4)
    noise = highpass([rng.uniform(-1, 1) for _ in range(length)], 0.3)
    return [noise[i] * min(1.0, i / n(0.05)) * math.exp(-(i / RATE) * 1.8) for i in range(length)]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(1405)
    write("marksman_carbine_fire", carbine(rng))
    write("combat_shotgun_fire", shotgun(rng))
    write("combat_shotgun_pump", pump(rng))
    write("der_fire", sweep(1400, 380, 0.16, 18.0, 0.15, rng))
    write("der_charge", charge(rng))
    write("der_charged_fire", charged_fire(rng))
    write("der_overheat", vent(rng))
    print("wrote", sorted(p.name for p in OUT.glob("*.wav")))


if __name__ == "__main__":
    main()
