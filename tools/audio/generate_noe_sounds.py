#!/usr/bin/env python3
"""
Download and process real, authentic library sound effects (OpenGameArt CC0,
Kenney CC0, Free Firearms SFX CC0) into visceral, punchy 16-bit 44.1kHz mono WAVs
for the New Ottoman enemies in Project Long Colt.

Eliminates all synthetic mathematical waveforms in favor of real acoustic studio
takes, firearm mechanics, heavy ordnance blasts, and physical Foley.
"""

import os
import subprocess
import urllib.request
import wave
import zipfile
import numpy as np

RATE = 44100
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
OUT_DIR = os.path.join(PROJECT_ROOT, "assets/audio/enemies/new_ottoman")
CACHE_DIR = "/tmp/audio_library"

URLS = {
    "war_horns.wav": "https://opengameart.org/sites/default/files/war_horns.wav",
    "100_sfx.zip": "https://opengameart.org/sites/default/files/100-CC0-SFX_0.zip",
    "wood_metal.zip": "https://opengameart.org/sites/default/files/100-CC0-wood-metal-SFX.zip",
    "bang_sfx.zip": "https://opengameart.org/sites/default/files/25-CC0-bang-sfx.zip",
    "breaking.zip": "https://opengameart.org/sites/default/files/sfx_breaking_and_falling.zip",
    "W_13.wav": "https://raw.githubusercontent.com/buddingmonkey/FreeFirearmsSFXLibrary/main/Master%20Tracks/Tikka/W_13.wav",
    "space_engine_low_000.ogg": "https://raw.githubusercontent.com/Boyquotes/kenney-sci-fi-sounds-for-godot/main/addons/kenney%20sci-fi%20sounds/space_engine_low_000.ogg",
    "thruster_fire_000.ogg": "https://raw.githubusercontent.com/Boyquotes/kenney-sci-fi-sounds-for-godot/main/addons/kenney%20sci-fi%20sounds/thruster_fire_000.ogg",
    "impact_plate_heavy_000.ogg": "https://raw.githubusercontent.com/Boyquotes/kenney-impact-sounds-for-godot/main/addons/kenney%20impact%20sounds/impact_plate_heavy_000.ogg",
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

    # Extract zips if not already extracted
    zip_mappings = {
        "100_sfx.zip": "100sfx",
        "wood_metal.zip": "metal",
        "bang_sfx.zip": "bang",
        "breaking.zip": "breaking",
    }
    for zip_name, sub in zip_mappings.items():
        sub_dir = os.path.join(ext_dir, sub)
        if not os.path.exists(sub_dir):
            os.makedirs(sub_dir, exist_ok=True)
            with zipfile.ZipFile(os.path.join(CACHE_DIR, zip_name), "r") as zf:
                zf.extractall(sub_dir)


def load_audio(path, rate=RATE):
    """Load any audio format as mono float array [-1.0, 1.0] at target rate."""
    cmd = [
        "ffmpeg", "-y", "-i", path,
        "-f", "s16le", "-ac", "1", "-ar", str(rate), "-"
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    raw, _ = proc.communicate()
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def normalize(sig, target_peak_db=-0.5):
    """Peak normalize float audio array."""
    peak = np.max(np.abs(sig))
    if peak <= 1e-6:
        return sig
    target = 10.0 ** (target_peak_db / 20.0)
    return sig * (target / peak)


def apply_fade(sig, fade_in_sec, fade_out_sec, rate=RATE):
    """Apply linear fade in / out."""
    sig = sig.copy()
    in_samples = int(fade_in_sec * rate)
    out_samples = int(fade_out_sec * rate)
    if in_samples > 0 and in_samples <= len(sig):
        sig[:in_samples] *= np.linspace(0.0, 1.0, in_samples, dtype=np.float32)
    if out_samples > 0 and out_samples <= len(sig):
        sig[-out_samples:] *= np.linspace(1.0, 0.0, out_samples, dtype=np.float32)
    return sig


def write_wav(sig, out_path, rate=RATE):
    """Write float32 array to 16-bit PCM WAV."""
    sig_int16 = (np.clip(sig, -1.0, 1.0) * 32767.0).astype(np.int16)
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(sig_int16.tobytes())
    dur = len(sig) / rate
    print(f"  [SAVED] {os.path.basename(out_path)} ({dur:.2f}s, peak {np.max(np.abs(sig_int16))})")


def make_horn_advance():
    # Eldritch Grim war_horns.wav (CC0)
    # 22.1s - 24.8s is the climactic rising brass war call
    war_horns = load_audio(os.path.join(CACHE_DIR, "war_horns.wav"))
    s = int(22.10 * RATE)
    e = int(24.65 * RATE)
    sig = war_horns[s:e]
    sig = apply_fade(sig, 0.03, 0.25)
    sig = normalize(sig, -0.3)
    write_wav(sig, os.path.join(OUT_DIR, "horn_advance.wav"))


def make_horn_withdraw():
    # Eldritch Grim war_horns.wav (CC0)
    # 9.75s - 12.10s is the solemn descending brass call
    war_horns = load_audio(os.path.join(CACHE_DIR, "war_horns.wav"))
    s = int(9.75 * RATE)
    e = int(12.05 * RATE)
    sig = war_horns[s:e]
    sig = apply_fade(sig, 0.04, 0.30)
    sig = normalize(sig, -0.3)
    write_wav(sig, os.path.join(OUT_DIR, "horn_withdraw.wav"))


def make_cymbal():
    # rubberduck gong_01.ogg (CC0) + metal_sheet_01.ogg layer for initial bronze bite
    gong = load_audio(os.path.join(CACHE_DIR, "extracted/100sfx/gong_01.ogg"))
    sheet = load_audio(os.path.join(CACHE_DIR, "extracted/metal/metal_sheet_01.ogg"))
    
    gong = gong[:int(1.4 * RATE)]
    gong = apply_fade(gong, 0.005, 0.25)
    
    out = np.zeros(len(gong), dtype=np.float32)
    out += gong
    sheet_len = min(len(sheet), len(out))
    out[:sheet_len] += sheet[:sheet_len] * 0.5
    
    out = normalize(out, -0.3)
    write_wav(out, os.path.join(OUT_DIR, "cymbal.wav"))


def make_glint():
    # Tikka T3 Dry Fire (W_13.wav, CC0 Free Firearms SFX)
    # Peak at 0.418s - razor sharp mechanical sear release & striker strike
    dry_fire = load_audio(os.path.join(CACHE_DIR, "W_13.wav"))
    s = int(0.412 * RATE)
    e = int((0.412 + 0.30) * RATE)
    sig = dry_fire[s:e]
    sig = apply_fade(sig, 0.001, 0.06)
    sig = normalize(sig, -0.2)
    write_wav(sig, os.path.join(OUT_DIR, "glint.wav"))


def make_hum():
    # Kenney space_engine_low_000.ogg (CC0)
    # Seamless low-frequency industrial turbine/motor vibration loop
    engine = load_audio(os.path.join(CACHE_DIR, "space_engine_low_000.ogg"))
    s = int(1.0 * RATE)
    dur = int(1.2 * RATE)
    sig = engine[s : s + dur].copy()
    
    xfade = int(0.15 * RATE)
    tail = sig[-xfade:].copy()
    head = sig[:xfade].copy()
    sig[:xfade] = head * np.linspace(0.0, 1.0, xfade) + tail * np.linspace(1.0, 0.0, xfade)
    sig = sig[:-xfade]
    
    sig = normalize(sig, -1.0)
    write_wav(sig, os.path.join(OUT_DIR, "hum.wav"))


def make_ricochet():
    # Rubberduck metal_hit_01.ogg + metal_sheet_01.ogg (CC0)
    hit = load_audio(os.path.join(CACHE_DIR, "extracted/metal/metal_hit_01.ogg"))
    sheet = load_audio(os.path.join(CACHE_DIR, "extracted/metal/metal_sheet_01.ogg"))
    
    out_len = int(0.38 * RATE)
    out = np.zeros(out_len, dtype=np.float32)
    
    hit_len = min(len(hit), out_len)
    out[:hit_len] += hit[:hit_len] * 0.9
    
    sheet_len = min(len(sheet), out_len)
    out[:sheet_len] += sheet[:sheet_len] * 0.6
    
    out = apply_fade(out, 0.001, 0.08)
    out = normalize(out, -0.2)
    write_wav(out, os.path.join(OUT_DIR, "ricochet.wav"))


def make_humbara_fire():
    # Rubberduck cannon_03.ogg + cannon_04.ogg (CC0)
    # Deep, heavy concussive cannon lob launch
    c3 = load_audio(os.path.join(CACHE_DIR, "extracted/bang/cannon_03.ogg"))
    c4 = load_audio(os.path.join(CACHE_DIR, "extracted/bang/cannon_04.ogg"))
    
    out_len = int(0.85 * RATE)
    out = np.zeros(out_len, dtype=np.float32)
    
    l3 = min(len(c3), out_len)
    out[:l3] += c3[:l3] * 0.7
    
    l4 = min(len(c4), out_len)
    out[:l4] += c4[:l4] * 0.6
    
    out = apply_fade(out, 0.002, 0.15)
    out = normalize(out, -0.2)
    write_wav(out, os.path.join(OUT_DIR, "humbara_fire.wav"))


def make_hydraulic_vent():
    # Kenney thruster_fire_000.ogg (CC0) + metal clank
    thruster = load_audio(os.path.join(CACHE_DIR, "thruster_fire_000.ogg"))
    hit = load_audio(os.path.join(CACHE_DIR, "extracted/metal/metal_hit_01.ogg"))
    
    out_len = int(0.75 * RATE)
    out = np.zeros(out_len, dtype=np.float32)
    
    h_len = min(len(hit), out_len)
    out[:h_len] += hit[:h_len] * 0.5
    
    t_len = min(len(thruster), out_len)
    env = np.ones(t_len, dtype=np.float32)
    env = apply_fade(env, 0.02, 0.35)
    out[:t_len] += thruster[:t_len] * env * 0.85
    
    out = normalize(out, -0.5)
    write_wav(out, os.path.join(OUT_DIR, "hydraulic_vent.wav"))


def make_armor_spall():
    # Rubberduck bfh1_rock_breaking_01.ogg + Kenney impact_plate_heavy_000.ogg (CC0)
    rock = load_audio(os.path.join(CACHE_DIR, "extracted/breaking/bfh1_rock_breaking_01.ogg"))
    plate = load_audio(os.path.join(CACHE_DIR, "impact_plate_heavy_000.ogg"))
    
    out_len = int(0.55 * RATE)
    out = np.zeros(out_len, dtype=np.float32)
    
    p_len = min(len(plate), out_len)
    out[:p_len] += plate[:p_len] * 0.8
    
    r_len = min(len(rock), out_len)
    out[:r_len] += rock[:r_len] * 0.7
    
    out = apply_fade(out, 0.002, 0.12)
    out = normalize(out, -0.3)
    write_wav(out, os.path.join(OUT_DIR, "armor_spall.wav"))


def main():
    print("Fetching dependencies and processing library sound effects for New Ottoman enemies...")
    ensure_dependencies()
    make_horn_advance()
    make_horn_withdraw()
    make_cymbal()
    make_glint()
    make_hum()
    make_ricochet()
    make_humbara_fire()
    make_hydraulic_vent()
    make_armor_spall()
    print("Done! All 9 sound effects processed from CC0 studio audio libraries.")


if __name__ == "__main__":
    main()
