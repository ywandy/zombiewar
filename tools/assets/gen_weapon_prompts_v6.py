#!/usr/bin/env python3
"""从 weapons-v6.json 展开武器出图提示词。

用法:
    python3 tools/assets/gen_weapon_prompts_v6.py

产出:
    docs/assets/player-characters/prompts-v6/weapons/<id>_<view>.txt

v5 的武器提示词逐字写死 "purple-black metal, restrained red paint"，和角色是同一个
毛病。v6 让武器读作真实器械：枪钢、发蓝钢、做旧木、裸露金属边缘，识别色只在小面积
点缀，指向它服务的兵种。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "docs/assets/player-characters/weapons-v6.json"
OUT = ROOT / "docs/assets/player-characters/prompts-v6/weapons"

VIEWS = ["front", "left", "back", "right"]

RENDERING = (
    "Rendering: rough uneven thick black ink outer line, scratchy internal ink, flat two-step "
    "cel shading, hand-painted grime, scratches, chipped paint and rust streaks, angular "
    "simplified readable shapes. Match the drawing effect of the style reference, not its props."
)

BACKDROP = (
    "Backdrop: flat uniform light gray, no horizon, no floor, no cast shadow, no vignette, "
    "no gradient, no scenery, no text, no logo, no watermark."
)

AVOID = (
    "purple, violet, magenta, purple-black metal, hands, arms, character, sling, loose "
    "ammunition, smoke, muzzle flash, photorealism, glossy 3D render, smooth vector art, soft "
    "airbrush, perspective distortion, three-quarter view, letters or typographic glyphs"
)


def material_block(weapon: dict, mats: dict) -> str:
    accent = weapon["accent"]
    return (
        f"Materials: {weapon['body']}. Read as a real, used piece of hardware, not painted "
        f"plastic. Shared material palette across the whole armoury: gunmetal {mats['gunmetal']}, "
        f"blued steel {mats['blued_steel']}, worn wood {mats['worn_wood']}, bare metal edges "
        f"{mats['bare_metal_edge']} where paint has rubbed through, black polymer "
        f"{mats['polymer_black']}, brass {mats['brass']} for cartridges. Identifier colour is "
        f"{accent['name']} {accent['hex']}, used on one small area only. Absolutely no purple, "
        f"violet or magenta anywhere."
    )


def front_prompt(weapon: dict, spec: dict) -> str:
    mats = spec["material_language"]
    lines = [
        "Use case: stylized-concept",
        "Asset type: broadside orthographic weapon source art for image-to-3D",
        "Input images: Image 1 is the user's supplied Zombie War menu screenshot and Image 2 is "
        "the approved v5 style gate. Use both only as drawing-style references. Do not reproduce "
        "their menu, logo, text, scene, characters or exact weapon meshes.",
        f"Subject: one original chunky stylized {weapon['name_en']} game prop, a single "
        "complete weapon and nothing else.",
        f"Gameplay role this silhouette must communicate: {weapon['role_en']}.",
        material_block(weapon, mats),
    ]
    if weapon.get("silhouette_en"):
        lines.append(f"Silhouette intent: {weapon['silhouette_en']}.")
    lines += [
        f"Camera: {spec['shared_view_spec']['front']}, eye level, no perspective, no tilt, "
        "centered with generous padding.",
        RENDERING,
        BACKDROP,
        f"Avoid: {AVOID}.",
    ]
    return "\n".join(lines)


def other_view_prompt(weapon: dict, spec: dict, view: str) -> str:
    mats = spec["material_language"]
    return "\n".join(
        [
            "Use case: stylized-concept",
            f"Asset type: {view} orthographic weapon source art for image-to-3D",
            f"Input images: Image 1 is the approved v6 broadside of {weapon['name_en']} and "
            "is authoritative for geometry, proportion, materials, wear and scale.",
            f"Subject: the same single weapon as Image 1, identical length, identical part count, "
            f"identical materials and identical wear marks, redrawn as the "
            f"{spec['shared_view_spec'][view]}.",
            material_block(weapon, mats),
            f"Camera: {spec['shared_view_spec'][view]}, eye level, no perspective, no tilt, "
            "identical scale and identical crop to Image 1.",
            RENDERING,
            BACKDROP,
            "Consistency: total length, receiver proportion, sight and grip placement, panel "
            "seams, rust and chipped-paint positions must all match Image 1. Do not add, remove "
            "or restyle any part.",
            f"Avoid: {AVOID}, new parts not present in Image 1.",
        ]
    )


def main() -> None:
    spec = json.loads(SPEC.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)

    weapons = spec["existing"] + spec["new"]
    written = 0
    for weapon in weapons:
        for view in VIEWS:
            body = front_prompt(weapon, spec) if view == "front" else other_view_prompt(weapon, spec, view)
            (OUT / f"{weapon['id']}_{view}.txt").write_text(body + "\n", encoding="utf-8")
            written += 1

    print(f"wrote {written} weapon prompts under {OUT.relative_to(ROOT)}")
    print(f"  重制 {len(spec['existing'])} 件 + 新增 {len(spec['new'])} 件 = {len(weapons)} 件 × 4 视图")


if __name__ == "__main__":
    main()
