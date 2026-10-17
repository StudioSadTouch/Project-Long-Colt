#!/usr/bin/env python3
"""
Generate visceral, punchy, realistic 16-bit 44.1kHz mono gunshot sounds for all
weapons in Project Long Colt sourced from CC0 and open studio audio libraries:
  - The Free Firearm Sound Library by Ben Jaszczak (CC0)
  - Tabasco Field Gunshots by Vincent Sevedge (CC-BY 3.0)
  - Kenney Sci-Fi & Impact Sounds (CC0)
  - 25 CC0 Bang / Firework SFX by rubberduck (CC0)

Replaces thin, gated, low-energy placeholder clips with layered near-distance
supersonic muzzle cracks, tactile mechanical slide/bolt cycling, reinforced
low-frequency chest thump (60-180Hz), and smooth outdoor acoustic decay tails.
"""

import os
import subprocess
import urllib.request
import wave
import zipfile
import numpy as np

RATE = 44100
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OUT_DIR = os.path.join(PROJECT_ROOT, "assets/audio/weapons")
CACHE_DIR = "/tmp/audio_library"

URLS = {
    "D_32P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/AR-15/D_32P.wav",
    "W_29P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/Tikka/W_29P.wav",
    "W_13.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Master%20Tracks/Tikka/W_13.wav",
    "M_21P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/Mosin%20Nagant/M_21P.wav",
    "C_27P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/AK-47/C_27P.wav",
    "O_21P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/Nova/O_21P.wav",
    "O_6.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Master%20Tracks/Nova/O_6.wav",
    "N_30P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/Mossberg/N_30P.wav",
    "X_39P.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Prepared%20SFX/Walther%20PPQ/X_39P.wav",
    "bang_sfx.zip": "https://opengameart.org/sites/default/files/25-CC0-bang-sfx.zip",
    "thruster_fire_000.ogg": "https://raw.githubusercontent.com/Boyquotes/kenney-sci-fi-sounds-for-godot/main/addons/kenney%20sci-fi%20sounds/thruster_fire_000.ogg",
    "tabasco_sounds.zip": "https://opengameart.org/sites/default/files/tabasco_sounds.zip",
}


def ensure_dependencies():
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    ext_dir = os.path.join(CACHE_DIR, "extracted")
    os.makedirs(ext_dir, exist_ok=True)

    for filename, url in URLS.items():
        dest = os.path.join(CACHE_DIR, filename)
        if not os.path.exists(dest):
            print(f"Downloading {filename}...")
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (GodotGameDev)"})
            with urllib.request.urlopen(req) as resp, open(dest, "wb") as f:
                f.write(resp.read())

    # Extract zips
    bang_dest = os.path.join(ext_dir, "bang")
    if not os.path.exists(bang_dest):
        os.makedirs(bang_dest, exist_ok=True)
        with zipfile.ZipFile(os.path.join(CACHE_DIR, "bang_sfx.zip"), "r") as zf:
            zf.extractall(bang_dest)

    tabasco_dest = os.path.join(ext_dir, "tabasco")
    if not os.path.exists(tabasco_dest):
        os.makedirs(tabasco_dest, exist_ok=True)
        with zipfile.ZipFile(os.path.join(CACHE_DIR, "tabasco_sounds.zip"), "r") as zf:
            zf.extractall(tabasco_dest)


def load_audio(path, start=None, dur=None, rate=RATE):
    """Load audio file slice as mono float32 array in [-1.0, 1.0]."""
    cmd = ["ffmpeg", "-y"]
    if start is not None:
        cmd += ["-ss", str(start)]
    cmd += ["-i", path]
    if dur is not None:
        cmd += ["-t", str(dur)]
    cmd += ["-f", "s16le", "-ac", "1", "-ar", str(rate), "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    raw, _ = proc.communicate()
    sig = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return sig


def apply_fade(sig, fade_in_sec=0.001, fade_out_sec=0.03, rate=RATE):
    """Apply smooth linear attack and release fades."""
    sig = sig.copy()
    in_samples = int(fade_in_sec * rate)
    out_samples = int(fade_out_sec * rate)
    if in_samples > 0 and in_samples < len(sig):
        sig[:in_samples] *= np.linspace(0.0, 1.0, in_samples, dtype=np.float32)
    if out_samples > 0 and out_samples < len(sig):
        sig[-out_samples:] *= np.linspace(1.0, 0.0, out_samples, dtype=np.float32)
    return sig


def bass_boost(sig, cutoff_hz=160, boost=0.6, rate=RATE):
    """Reinforce low-frequency body and chest thump using a single-pole IIR lowpass filter."""
    alpha = float(2.0 * np.pi * cutoff_hz / rate)
    low = np.zeros_like(sig)
    for i in range(1, len(sig)):
        low[i] = low[i-1] + alpha * (sig[i] - low[i-1])
    return sig + low * boost


def soft_saturate(sig, drive=1.4):
    """Analog-style hyperbolic tangent soft saturation to increase RMS punch without harsh clipping."""
    return np.tanh(sig * drive) / np.tanh(drive)


def normalize_peak(sig, target_db=-0.3):
    """Normalize peak amplitude to target decibels relative to full scale (dBFS)."""
    peak = np.max(np.abs(sig))
    if peak <= 1e-6:
        return sig
    target = 10.0 ** (target_db / 20.0)
    return sig * (target / peak)


def write_wav(sig, out_path, rate=RATE):
    """Write 16-bit PCM mono WAV file."""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    sig_int16 = (np.clip(sig, -1.0, 1.0) * 32767.0).astype(np.int16)
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(sig_int16.tobytes())


def mix_into(total_len_sec, layers):
    """Mix multiple audio layers at designated offsets into a fixed-length buffer."""
    total_samples = int(total_len_sec * RATE)
    out = np.zeros(total_samples, dtype=np.float32)
    for sig, weight, offset_sec in layers:
        start = int(offset_sec * RATE)
        if start >= total_samples:
            continue
        length = min(len(sig), total_samples - start)
        out[start:start+length] += sig[:length] * weight
    return out


# ==============================================================================
# WEAPON GENERATORS
# ==============================================================================

def gen_standard_issue_rifle():
    """
    Standard Issue Rifle (0.42s):
    High-velocity AR-15 5.56x45 near-distance crack transient (D_32P) layered
    with SKS 7.62x39 concussive body (sks.wav), reinforced low-end punch at 150Hz,
    and soft saturation. Clean natural decay tail suited for 10 rps cyclic rate.
    """
    dur = 0.42
    crack = load_audio(f"{CACHE_DIR}/D_32P.wav", start=5.648, dur=dur)
    body = load_audio(f"{CACHE_DIR}/extracted/tabasco/sounds/sks.wav", start=13.457, dur=dur)
    mech = load_audio(f"{CACHE_DIR}/C_27P.wav", start=0.275, dur=0.08)

    crack = crack / max(1e-6, np.max(np.abs(crack)))
    body = body / max(1e-6, np.max(np.abs(body)))
    mech = mech / max(1e-6, np.max(np.abs(mech)))

    t = np.linspace(0, len(body)/RATE, len(body))
    body_env = np.exp(-t / 0.16)
    body_shaped = body * body_env

    mix = mix_into(dur, [
        (crack, 0.65, 0.0),
        (body_shaped, 0.55, 0.0),
        (mech, 0.25, 0.015),
    ])
    mix = bass_boost(mix, cutoff_hz=150, boost=0.65)
    sat = soft_saturate(mix, drive=1.35)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.035)
    return normalize_peak(out, -0.3)


def gen_marksman_carbine():
    """
    Marksman Carbine (0.72s):
    High-power Tikka T3 .30-06 supersonic crack (W_29P) fused with Mosin Nagant
    7.62x54 near-distance punch (M_21P) and outdoor acoustic bloom (mosin.wav).
    Rich 130Hz resonant body with authoritative reverberant decay.
    """
    dur = 0.72
    crack = load_audio(f"{CACHE_DIR}/W_29P.wav", start=0.587, dur=dur)
    mosin_near = load_audio(f"{CACHE_DIR}/M_21P.wav", start=5.023, dur=dur)
    mosin_field = load_audio(f"{CACHE_DIR}/extracted/tabasco/sounds/mosin.wav", start=8.863, dur=dur)

    crack = crack / max(1e-6, np.max(np.abs(crack)))
    mosin_near = mosin_near / max(1e-6, np.max(np.abs(mosin_near)))
    mosin_field = mosin_field / max(1e-6, np.max(np.abs(mosin_field)))

    t = np.linspace(0, len(mosin_field)/RATE, len(mosin_field))
    field_env = np.exp(-t / 0.28)
    mosin_field_shaped = mosin_field * field_env

    mix = mix_into(dur, [
        (crack, 0.55, 0.0),
        (mosin_near, 0.40, 0.0),
        (mosin_field_shaped, 0.45, 0.0),
    ])
    mix = bass_boost(mix, cutoff_hz=130, boost=0.75)
    sat = soft_saturate(mix, drive=1.4)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.05)
    return normalize_peak(out, -0.3)


def gen_combat_shotgun():
    """
    Combat Shotgun (0.85s):
    Benelli Nova 12-gauge close-mic concussive blast (O_21P) layered with Mossberg 190
    (N_30P) and close-mic field blast (shotty.wav). Reinforced 90Hz sub-bass pressure wave
    and deep, cavernous low-end reverb tail.
    """
    dur = 0.85
    nova = load_audio(f"{CACHE_DIR}/O_21P.wav", start=0.432, dur=dur)
    moss = load_audio(f"{CACHE_DIR}/N_30P.wav", start=4.961, dur=dur)
    field = load_audio(f"{CACHE_DIR}/extracted/tabasco/sounds/shotty.wav", start=0.164, dur=dur)

    nova = nova / max(1e-6, np.max(np.abs(nova)))
    moss = moss / max(1e-6, np.max(np.abs(moss)))
    field = field / max(1e-6, np.max(np.abs(field)))

    t_field = np.linspace(0, len(field)/RATE, len(field))
    env_field = np.exp(-t_field / 0.25)
    field_shaped = field * env_field

    mix = mix_into(dur, [
        (nova, 0.50, 0.0),
        (moss, 0.45, 0.0),
        (field_shaped, 0.50, 0.0),
    ])
    mix = bass_boost(mix, cutoff_hz=90, boost=0.95)
    mix = bass_boost(mix, cutoff_hz=160, boost=0.40)
    sat = soft_saturate(mix, drive=1.5)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.06)
    return normalize_peak(out, -0.3)


def gen_combat_shotgun_pump():
    """
    Combat Shotgun Pump (0.55s):
    Real Benelli Nova 12-gauge full pump cycle with loaded magazine (O_6) featuring
    tactile steel slide rack-back and heavy lock-forward, augmented with Tikka mechanical
    locking sear (W_13).
    """
    dur = 0.55
    pump = load_audio(f"{CACHE_DIR}/O_6.wav", start=1.08, dur=dur)
    tikka_lock = load_audio(f"{CACHE_DIR}/W_13.wav", start=0.0, dur=0.20)
    pump = pump / max(1e-6, np.max(np.abs(pump)))
    tikka_lock = tikka_lock / max(1e-6, np.max(np.abs(tikka_lock)))

    mix = mix_into(dur, [
        (pump, 0.90, 0.0),
        (tikka_lock, 0.35, 0.28),
    ])
    mix = bass_boost(mix, cutoff_hz=250, boost=0.3)
    sat = soft_saturate(mix, drive=1.2)
    out = apply_fade(sat, fade_in_sec=0.002, fade_out_sec=0.04)
    return normalize_peak(out, -0.4)


def gen_service_pistol():
    """
    Service Pistol (0.48s):
    Walther PPQ 9mm near-distance shot (X_39P) combined with CZ-52 Tokarev 7.62x25
    field take (cz.wav) for a sharp mechanical slide snap and punchy 180Hz low-mid bark.
    """
    dur = 0.48
    ppq = load_audio(f"{CACHE_DIR}/X_39P.wav", start=10.660, dur=dur)
    cz = load_audio(f"{CACHE_DIR}/extracted/tabasco/sounds/cz.wav", start=0.293, dur=dur)
    ppq = ppq / max(1e-6, np.max(np.abs(ppq)))
    cz = cz / max(1e-6, np.max(np.abs(cz)))

    t = np.linspace(0, len(cz)/RATE, len(cz))
    cz_env = np.exp(-t / 0.18)
    cz_shaped = cz * cz_env

    mix = mix_into(dur, [
        (ppq, 0.60, 0.0),
        (cz_shaped, 0.50, 0.0),
    ])
    mix = bass_boost(mix, cutoff_hz=180, boost=0.55)
    sat = soft_saturate(mix, drive=1.3)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.035)
    return normalize_peak(out, -0.3)


def gen_der_rocket():
    """
    Rocket Launcher / Directed Energy Rifle (0.95s):
    Heavy artillery cannon launch detonation (cannon_04 + cannon_01) combined with
    deep rocket thruster ignition roar (thruster_fire_000). 70Hz sub-bass concussive thump.
    """
    dur = 0.95
    cannon = load_audio(f"{CACHE_DIR}/extracted/bang/cannon_04.ogg", start=0.170, dur=dur)
    cannon_sub = load_audio(f"{CACHE_DIR}/extracted/bang/cannon_01.ogg", start=0.085, dur=dur)
    thruster = load_audio(f"{CACHE_DIR}/thruster_fire_000.ogg", start=0.0, dur=dur)
    cannon = cannon / max(1e-6, np.max(np.abs(cannon)))
    cannon_sub = cannon_sub / max(1e-6, np.max(np.abs(cannon_sub)))
    thruster = thruster / max(1e-6, np.max(np.abs(thruster)))

    t_thruster = np.linspace(0, len(thruster)/RATE, len(thruster))
    thruster_env = (1.0 - np.exp(-t_thruster / 0.04)) * np.exp(-t_thruster / 0.60)
    thruster_shaped = thruster * thruster_env

    mix = mix_into(dur, [
        (cannon, 0.55, 0.0),
        (cannon_sub, 0.40, 0.0),
        (thruster_shaped, 0.50, 0.0),
    ])
    mix = bass_boost(mix, cutoff_hz=70, boost=1.1)
    mix = bass_boost(mix, cutoff_hz=140, boost=0.5)
    sat = soft_saturate(mix, drive=1.45)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.08)
    return normalize_peak(out, -0.3)


def gen_der_charged():
    """
    DER Charged Fire (0.85s):
    Concussive supercharged launch detonation using cannon_02 + cannon_04 + thruster
    with deep sub-bass resonance.
    """
    dur = 0.85
    cannon = load_audio(f"{CACHE_DIR}/extracted/bang/cannon_02.ogg", start=0.008, dur=dur)
    cannon_punch = load_audio(f"{CACHE_DIR}/extracted/bang/cannon_04.ogg", start=0.170, dur=dur)
    thruster = load_audio(f"{CACHE_DIR}/thruster_fire_000.ogg", start=0.0, dur=dur)
    cannon = cannon / max(1e-6, np.max(np.abs(cannon)))
    cannon_punch = cannon_punch / max(1e-6, np.max(np.abs(cannon_punch)))
    thruster = thruster / max(1e-6, np.max(np.abs(thruster)))

    t_thruster = np.linspace(0, len(thruster)/RATE, len(thruster))
    thruster_env = (1.0 - np.exp(-t_thruster / 0.03)) * np.exp(-t_thruster / 0.50)
    thruster_shaped = thruster * thruster_env

    mix = mix_into(dur, [
        (cannon, 0.50, 0.0),
        (cannon_punch, 0.45, 0.0),
        (thruster_shaped, 0.45, 0.0),
    ])
    mix = bass_boost(mix, cutoff_hz=60, boost=1.2)
    sat = soft_saturate(mix, drive=1.4)
    out = apply_fade(sat, fade_in_sec=0.0005, fade_out_sec=0.07)
    return normalize_peak(out, -0.3)


def main():
    print("=== Generating Master Weapon Audio SFX ===")
    ensure_dependencies()

    weapons = {
        "standard_issue_rifle_fire.wav": gen_standard_issue_rifle(),
        "marksman_carbine_fire.wav": gen_marksman_carbine(),
        "combat_shotgun_fire.wav": gen_combat_shotgun(),
        "combat_shotgun_pump.wav": gen_combat_shotgun_pump(),
        "service_pistol_fire.wav": gen_service_pistol(),
        "der_fire.wav": gen_der_rocket(),
        "der_charged_fire.wav": gen_der_charged(),
    }

    print("\nWriting mastered audio files to assets/audio/weapons/:")
    for filename, sig in weapons.items():
        out_path = os.path.join(OUT_DIR, filename)
        write_wav(sig, out_path)
        rms = np.sqrt(np.mean(sig**2))
        dur = len(sig) / RATE
        peak = np.max(np.abs(sig))
        dbfs = 20 * np.log10(rms + 1e-9)
        print(f"  -> {filename:30s} dur={dur:.3f}s | peak={peak:.3f} | RMS={dbfs:6.1f} dBFS")

    print("\nAudio generation complete! All weapon sounds upgraded successfully.")


if __name__ == "__main__":
    main()
