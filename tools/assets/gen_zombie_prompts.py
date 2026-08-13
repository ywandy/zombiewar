#!/usr/bin/env python3
"""从 zombies-v1.json 展开僵尸出图提示词。

    python3 tools/assets/gen_zombie_prompts.py

产出:
    docs/assets/zombies/prompts/<zombie_id>_<view>.txt

姿势必须是 T-pose：僵尸骨架的 rest pose 实测臂展 1.888 大于身高 1.362，与玩家
骨架同约定。网格不处在 rest pose 上，蒙皮形变必然崩——这一点在玩家角色上已经
用 40 张图的返工代价验证过一次，这里不再重复踩。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "docs/assets/zombies/zombies-v1.json"
OUT = ROOT / "docs/assets/zombies/prompts"

VIEWS = ["front", "left", "back", "right"]
VIEW_CAMERA = {
    "front": "true orthographic exact front view",
    "left": "true orthographic exact left side view",
    "back": "true orthographic exact rear view",
    "right": "true orthographic exact right side view",
}

POSE = (
    "Pose: strict T-pose copied from Image 2. Both arms raised straight out to the sides and held "
    "HORIZONTAL at shoulder height, elbows straight, arm span wider than the figure is tall. Legs "
    "straight and slightly apart, feet flat on the same ground line. The undead character of the "
    "figure comes from the body shape, the hunch of the spine and the head angle, NOT from lowering "
    "or bending the arms — the arms must stay horizontal so the mesh can be skinned to the existing "
    "skeleton."
)

RENDERING = (
    "Rendering: rough uneven thick black ink outer line, scratchy internal ink, flat two-step cel "
    "shading with a hard shadow edge, hand-painted rot and grime. Bold inked cartoon game character, "
    "not a rendered product photo, not smooth low-poly flat colour."
)

BACKDROP = (
    "Backdrop: flat uniform light gray, no horizon, no floor, no cast shadow, no vignette, "
    "no gradient, no scenery, no text, no logo, no watermark."
)

AVOID = (
    "purple, violet, magenta, cute, friendly, mascot, smooth untextured low-poly flat colour, "
    "held weapon, photorealism, glossy 3D render, smooth vector art, soft airbrush, smooth gradient "
    "shading, three-quarter view, perspective distortion, dramatic action pose, arms hanging down, "
    "bent elbows, extra limbs, fused fingers, letters or typographic glyphs"
)


def palette_block(z: dict, shared: dict) -> str:
    p = z["palette"]
    return (
        f"Colours: {z['palette_note_en']} — skin {p['skin']}, clothing {p['clothing']}, dried blood "
        f"{p['accent']}. Decay language shared across the whole horde: {shared['decay']}. Absolutely "
        f"no purple, violet or magenta anywhere."
    )


def front_prompt(z: dict, shared: dict) -> str:
    return "\n".join(
        [
            "Use case: stylized-concept",
            "Asset type: front orthographic full character source art for image-to-3D",
            "Input images: Image 1 is the approved survivor art style and is authoritative for the "
            "ink weight, cel shading and hand-painted wear. Image 2 is the target rig rest pose and "
            "is authoritative for the T-pose arm angle.",
            f"Subject: ONE complete zombie, a single connected figure. {z['display_name']}.",
            f"Build: {z['build_en']}.",
            f"Clothing: {z['clothing_en']}.",
            palette_block(z, shared),
            f"Silhouette intent: {z['silhouette_en']}",
            POSE,
            RENDERING,
            f"Camera: {VIEW_CAMERA['front']}, eye level, no perspective, no tilt. Full body centered "
            "with generous padding.",
            BACKDROP,
            f"Avoid: {AVOID}.",
        ]
    )


def other_view_prompt(z: dict, shared: dict, view: str) -> str:
    return "\n".join(
        [
            "Use case: stylized-concept",
            f"Asset type: {view} orthographic full character source art for image-to-3D",
            f"Input images: Image 1 is the approved FRONT view of {z['id']}. It is the identity "
            "reference and must be matched exactly.",
            f"Subject: the same single zombie as Image 1, same body, same clothing, same wounds, "
            f"same colours, same height and same scale, redrawn seen from the {view}.",
            f"Build: {z['build_en']}.",
            palette_block(z, shared),
            POSE,
            RENDERING,
            f"Camera: {VIEW_CAMERA[view]}, eye level, no perspective, no tilt, identical scale and "
            "identical crop to Image 1. The figure must occupy exactly the same image height as in "
            "Image 1 so the four views register against each other.",
            BACKDROP,
            "Consistency: torn edges, wound positions, clothing remnants and colours must all match "
            "Image 1. Do not add, remove or restyle any part.",
            f"Avoid: {AVOID}, new parts not present in Image 1.",
        ]
    )


def main() -> None:
    spec = json.loads(SPEC.read_text(encoding="utf-8"))
    shared = spec["shared_style"]
    OUT.mkdir(parents=True, exist_ok=True)
    written = 0
    for z in spec["zombies"]:
        for view in VIEWS:
            body = front_prompt(z, shared) if view == "front" else other_view_prompt(z, shared, view)
            (OUT / f"{z['id']}_{view}.txt").write_text(body + "\n", encoding="utf-8")
            written += 1
    print(f"wrote {written} zombie prompts under {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
