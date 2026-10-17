#!/usr/bin/env python3
"""
===============================================================================
Project Long Colt — CC0 PBR Texture Fetcher & Material Importer
===============================================================================
Downloads high-quality public domain (CC0) PBR material sets (Albedo, Roughness,
NormalGL, Metallic, Ambient Occlusion) from public repositories (ambientCG API)
and automatically generates triplanar Godot 4.7 StandardMaterial3D resources.

Usage:
    python3 fetch_cc0_pbr.py --list
    python3 fetch_cc0_pbr.py --asset Concrete019 --res 1K
    python3 fetch_cc0_pbr.py --curated-all
===============================================================================
"""

import os
import sys
import json
import zipfile
import argparse
import urllib.request
import urllib.error
from typing import Dict, Optional, List

# Recommended curated CC0 assets matching Project Long Colt's aesthetic
RECOMMENDED_ASSETS = {
    "Concrete019": {
        "category": "concrete",
        "description": "Dark weathered reinforced concrete with aggregate pitting",
        "aesthetic": "Industrial bunker / subterranean facility",
    },
    "Metal032": {
        "category": "metal",
        "description": "Galvanized sheet metal with subtle wear and rivets",
        "aesthetic": "Structural framework / hangar plating",
    },
    "MetalPlates006": {
        "category": "metal",
        "description": "Industrial bolted metal deck plates",
        "aesthetic": "Maintenance walkways / floor decking",
    },
    "Steel001": {
        "category": "metal",
        "description": "Brushed industrial steel alloy",
        "aesthetic": "Weapon test fixtures / machinery housing",
    },
    "Ground037": {
        "category": "terrain",
        "description": "Crushed rock, gravel, and packed dirt",
        "aesthetic": "Zanzibar shoreline / outdoor firing range base",
    },
}

AMBIENTCG_API_URL = "https://ambientcg.com/api/v2/full_json"
AMBIENTCG_DOWNLOAD_URL = "https://ambientcg.com/get?file={asset_id}_{res}-PNG.zip"

def fetch_asset_metadata(asset_id: str) -> Optional[Dict]:
    """Queries ambientCG API for asset metadata."""
    url = f"{AMBIENTCG_API_URL}?id={asset_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "ProjectLongColt-AssetPipeline/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("foundAssets") and len(data["foundAssets"]) > 0:
                return data["foundAssets"][0]
    except Exception as e:
        print(f"[-] API query notice ({asset_id}): {e}")
    return None

def download_and_extract(asset_id: str, resolution: str, target_dir: str) -> List[str]:
    """
    Downloads and extracts a CC0 PBR texture zip from ambientCG.
    Filters maps: Color/Albedo, Roughness, NormalGL, Metalness.
    """
    os.makedirs(target_dir, exist_ok=True)
    zip_url = AMBIENTCG_DOWNLOAD_URL.format(asset_id=asset_id, res=resolution)
    zip_path = os.path.join(target_dir, f"{asset_id}_{resolution}.zip")

    print(f"[*] Downloading {asset_id} ({resolution}) from: {zip_url}")
    req = urllib.request.Request(zip_url, headers={"User-Agent": "ProjectLongColt-AssetPipeline/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp, open(zip_path, "wb") as out_f:
            chunk = resp.read(65536)
            while chunk:
                out_f.write(chunk)
                chunk = resp.read(65536)
    except urllib.error.URLError as e:
        print(f"[-] Download failed: {e}")
        return []

    extracted_files = []
    print(f"[*] Extracting PBR texture maps...")
    with zipfile.ZipFile(zip_path, "r") as zf:
        for name in zf.namelist():
            lower = name.lower()
            # Only extract key PBR maps
            if any(k in lower for k in ["color", "roughness", "normalgl", "metalness", "displacement"]):
                dest_path = os.path.join(target_dir, os.path.basename(name))
                with zf.open(name) as src, open(dest_path, "wb") as dst:
                    dst.write(src.read())
                extracted_files.append(dest_path)
                print(f"    + Extracted: {os.path.basename(dest_path)}")

    # Clean up zip
    if os.path.exists(zip_path):
        os.remove(zip_path)

    return extracted_files

def generate_material_for_asset(asset_id: str, target_mat_dir: str, target_tex_dir: str,
                                relative_res_dir: str = "res://assets/textures/environment") -> str:
    """Generates Godot StandardMaterial3D (.tres) matching the downloaded PBR textures."""
    os.makedirs(target_mat_dir, exist_ok=True)
    mat_name = f"mat_{asset_id.lower()}"
    mat_path = os.path.join(target_mat_dir, f"{mat_name}.tres")

    # Map files
    albedo_file = None
    rough_file = None
    normal_file = None
    metal_file = None

    for fname in os.listdir(target_tex_dir):
        if not fname.startswith(asset_id):
            continue
        lower = fname.lower()
        if "color" in lower:
            albedo_file = fname
        elif "roughness" in lower:
            rough_file = fname
        elif "normalgl" in lower:
            normal_file = fname
        elif "metalness" in lower:
            metal_file = fname

    if not albedo_file:
        print(f"[-] Warning: Albedo texture not found for {asset_id}")
        return ""

    ext_res = []
    body_lines = []
    ext_id = 1

    # Albedo
    ext_res.append(f'[ext_resource type="Texture2D" path="{relative_res_dir}/{albedo_file}" id="{ext_id}_alb"]')
    body_lines.append(f'albedo_texture = ExtResource("{ext_id}_alb")')
    ext_id += 1

    # Roughness
    if rough_file:
        ext_res.append(f'[ext_resource type="Texture2D" path="{relative_res_dir}/{rough_file}" id="{ext_id}_rgh"]')
        body_lines.append('roughness = 1.0')
        body_lines.append(f'roughness_texture = ExtResource("{ext_id}_rgh")')
        ext_id += 1

    # Metallic
    if metal_file:
        ext_res.append(f'[ext_resource type="Texture2D" path="{relative_res_dir}/{metal_file}" id="{ext_id}_met"]')
        body_lines.append('metallic = 1.0')
        body_lines.append(f'metallic_texture = ExtResource("{ext_id}_met")')
        ext_id += 1

    # Normal
    if normal_file:
        ext_res.append(f'[ext_resource type="Texture2D" path="{relative_res_dir}/{normal_file}" id="{ext_id}_nrm"]')
        body_lines.append('normal_enabled = true')
        body_lines.append('normal_scale = 1.0')
        body_lines.append(f'normal_texture = ExtResource("{ext_id}_nrm")')
        ext_id += 1

    body_lines.append('uv1_scale = Vector3(1.0, 1.0, 1.0)')
    body_lines.append('uv1_triplanar = true')
    body_lines.append('uv1_world_triplanar = true')
    body_lines.append('texture_filter = 5')

    load_steps = len(ext_res) + 1
    content = f'[gd_resource type="StandardMaterial3D" load_steps={load_steps} format=3]\n\n'
    content += "\n".join(ext_res) + "\n\n"
    content += f'[resource]\nresource_name = "{mat_name}"\n' + "\n".join(body_lines) + "\n"

    with open(mat_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[+] Material written: {mat_path}")
    return mat_path

def main():
    parser = argparse.ArgumentParser(description="Fetch and configure CC0 PBR textures for Project Long Colt")
    parser.add_argument("--list", action="store_true", help="List recommended curated CC0 assets")
    parser.add_argument("--asset", type=str, help="Asset ID from ambientCG (e.g. Concrete019, Metal032)")
    parser.add_argument("--res", type=str, default="1K", choices=["1K", "2K", "4K"], help="Resolution")
    parser.add_argument("--curated-all", action="store_true", help="Fetch all recommended curated assets")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))

    if args.list:
        print("\n=======================================================")
        print("Curated CC0 PBR Assets for Project Long Colt (ambientCG)")
        print("=======================================================")
        for aid, info in RECOMMENDED_ASSETS.items():
            print(f"  * {aid:<16} [{info['category']}]")
            print(f"      Description: {info['description']}")
            print(f"      Aesthetic:   {info['aesthetic']}")
        print("=======================================================\n")
        return

    tex_env_dir = os.path.join(project_root, "assets", "textures", "environment")
    mat_env_dir = os.path.join(project_root, "resources", "materials", "environment")

    assets_to_fetch = []
    if args.curated_all:
        assets_to_fetch = list(RECOMMENDED_ASSETS.keys())
    elif args.asset:
        assets_to_fetch = [args.asset]

    if not assets_to_fetch:
        parser.print_help()
        return

    for aid in assets_to_fetch:
        files = download_and_extract(aid, args.res, tex_env_dir)
        if files:
            generate_material_for_asset(aid, mat_env_dir, tex_env_dir)

if __name__ == "__main__":
    main()
