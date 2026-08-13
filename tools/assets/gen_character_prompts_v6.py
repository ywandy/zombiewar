#!/usr/bin/env python3
"""从 palette-v6.json 展开 v6 全批角色出图提示词。

用法:
    python3 tools/assets/gen_character_prompts_v6.py

产出:
    docs/assets/player-characters/prompts-v6/bases/<base_id>_<view>.txt   新基体 (2 套 x 4 视图)
    docs/assets/player-characters/prompts-v6/kits/<char_id>_<view>.txt    兵种分件 (10 x 4 视图)

配色、脸、分件全部来自 palette-v6.json；改配色只改 JSON，不改这里。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PALETTE = ROOT / "docs/assets/player-characters/palette-v6.json"
OUT = ROOT / "docs/assets/player-characters/prompts-v6"

# Tripo3D multiview_to_model 的接口顺序，不是 UI 展示顺序。
VIEWS = ["front", "left", "back", "right"]

VIEW_CAMERA = {
    "front": "true orthographic exact front view",
    "left": "true orthographic exact left side view",
    "back": "true orthographic exact rear view",
    "right": "true orthographic exact right side view",
}

BACKDROP = (
    "Backdrop: flat uniform light gray, no horizon, no floor, no cast shadow, "
    "no vignette, no gradient, no scenery, no text, no logo, no watermark."
)

RENDERING = (
    "Rendering: rough uneven black ink outer line, scratchy internal ink, flat two-step "
    "cel shading, hand-painted grime, scratches and stitched repairs, angular simplified "
    "readable shapes. Match the drawing effect of the style reference, not its character."
)

# v5 全批的失败点就是这一条被写死成 purple-black + red，v6 起颜色只能来自角色配色。
NO_PURPLE = (
    "Color discipline: this character's palette is listed above and is the only palette "
    "allowed. Absolutely no purple, violet, magenta or lavender anywhere on the garments, "
    "armor, straps or accessories."
)

COMMON_AVOID = (
    "photorealism, realistic military photography, glossy 3D render, smooth vector art, "
    "soft airbrush, three-quarter view, perspective distortion, dramatic pose, extra limbs, "
    "fused fingers, floating debris, letters or typographic glyphs"
)


def build_palette_block(character: dict, neutrals: dict) -> str:
    main = character["main"]
    secondary = character["secondary"]
    accent = character["accent"]
    return (
        f"Color identity (unique to this character): main garment is {main['name']} {main['hex']}, "
        f"covering the large coat, vest and armor surfaces and reading as roughly 40-50 percent of "
        f"the kit area; secondary is {secondary['name']} {secondary['hex']}; accent is "
        f"{accent['name']} {accent['hex']}, used only on straps, tape and small identifiers. "
        f"Shared neutrals across the whole roster: cream off-white {neutrals['cream']} leather and "
        f"webbing, dark brown {neutrals['leather_brown']} belts, gray {neutrals['metal_gray']} metal "
        f"fittings, near-black {neutrals['ink_black']} ink lines."
    )


def kit_front(character: dict, data: dict) -> str:
    cls = character["class"]
    sex = "male" if character["id"].startswith("male") else "female"
    palette = build_palette_block(character, data["shared_style"]["neutrals"])
    return "\n".join(
        [
            "Use case: stylized-concept",
            "Asset type: front orthographic separated equipment kit for image-to-3D",
            "Input images: Image 1 is the user's supplied Zombie War menu screenshot and Image 2 is "
            "the approved v5 style gate. Use both only as drawing-style references. Do not reuse the "
            "colors of any previously generated character.",
            f"Subject: only the separated {sex} {cls} equipment components, laid out with clear gaps "
            f"around an invisible {data['proportion'].split(' (')[0]} A-pose. No base body, no torso, "
            "no limbs, no bare skin below the neck, no weapon.",
            f"Parts: {data['class_parts'][cls]}.",
            f"Head and identity: {character['face']}.",
            palette,
            f"Motif: {data['class_motifs'][cls]}, used sparingly and at most three times across the "
            "whole kit.",
            f"Silhouette intent: {data['class_silhouette'][cls]}.",
            RENDERING,
            f"Camera: {VIEW_CAMERA['front']}, eye level, no perspective, no tilt. All parts drawn at "
            "one consistent scale with generous padding.",
            BACKDROP,
            NO_PURPLE,
            f"Avoid: purple, violet, magenta, base body, bare torso, held weapon, {COMMON_AVOID}.",
        ]
    )


def kit_other_view(character: dict, data: dict, view: str) -> str:
    cls = character["class"]
    sex = "male" if character["id"].startswith("male") else "female"
    palette = build_palette_block(character, data["shared_style"]["neutrals"])
    return "\n".join(
        [
            "Use case: stylized-concept",
            f"Asset type: {view} orthographic separated equipment kit for image-to-3D",
            f"Input images: Image 1 is the approved v6 FRONT kit sheet for {character['id']}. It is "
            "the identity reference and must be matched exactly.",
            f"Subject: the same {sex} {cls} kit as Image 1, same parts, same part count, same colors, "
            f"same wear marks and same scale, redrawn seen from the {view}. No base body, no weapon.",
            f"Parts: {data['class_parts'][cls]}.",
            f"Head and identity: {character['face']}. The head must be the same person as Image 1.",
            palette,
            f"Motif: {data['class_motifs'][cls]}, in the same places as Image 1 where visible from "
            f"the {view}.",
            RENDERING,
            f"Camera: {VIEW_CAMERA[view]}, eye level, no perspective, no tilt, identical scale and "
            "identical crop to Image 1.",
            BACKDROP,
            NO_PURPLE,
            "Consistency: garment seams, pouch count, buckle count, damage marks and colors must all "
            "match Image 1. Do not add, remove or restyle any part.",
            f"Avoid: purple, violet, magenta, base body, bare torso, held weapon, new parts not "
            f"present in Image 1, {COMMON_AVOID}.",
        ]
    )


def base_front(base: dict, data: dict) -> str:
    undersuit = data["base_undersuit_source"]["target"]
    sibling = "male_standard" if base["sex"] == "male" else "female_standard"
    return "\n".join(
        [
            "Use case: stylized-concept",
            "Asset type: front orthographic character base body for image-to-3D",
            "Input images: Image 1 is the user's supplied Zombie War menu screenshot and Image 2 is "
            f"the approved {sibling} base body. Image 2 fixes the head size, total height, head-to-body "
            "ratio and joint positions; only the body volume may differ.",
            f"Subject: one original {base['sex']} survivor base body wearing a plain seamless undersuit "
            "and ordinary worn combat boots. No equipment, no pouches, no armor, no weapon, no straps.",
            f"Build: {base['body']}. {base['build_constraint']}",
            f"Proportion: {data['proportion'].split(' (')[0]} tall, low center of gravity, short torso and "
            "short legs. The head, hands, forearms and boots stay in natural coordinated proportion; "
            "no single body part is oversized.",
            f"Undersuit color: {undersuit}. This is a tintable source asset, so keep the hue flat and "
            "desaturated and carry all the character through value, wear and hand-painted texture. "
            "Do not use purple, violet or magenta.",
            "Pose: exact neutral symmetrical A-pose for 3D reconstruction; upright torso; arms about 30 "
            "degrees away from the body; elbows straight; fingers separated; feet parallel; no held object.",
            RENDERING,
            f"Camera: {VIEW_CAMERA['front']}, eye level, no perspective, no tilt. Full body centered "
            "with generous padding.",
            BACKDROP,
            f"Avoid: purple, violet, magenta, equipment, armor, pouches, straps, weapon, tall silhouette, "
            f"long legs, fashion-model body, 4-head-plus anatomy, oversized head, bobblehead, superhero "
            f"muscles, {COMMON_AVOID}.",
        ]
    )


def base_other_view(base: dict, data: dict, view: str) -> str:
    undersuit = data["base_undersuit_source"]["target"]
    return "\n".join(
        [
            "Use case: stylized-concept",
            f"Asset type: {view} orthographic character base body for image-to-3D",
            f"Input images: Image 1 is the approved v6 FRONT base body for {base['id']}. It is the "
            "identity reference and must be matched exactly.",
            f"Subject: the same {base['sex']} base body as Image 1, same build, same undersuit, same "
            f"boots, same height and same scale, redrawn seen from the {view}. No equipment, no weapon.",
            f"Build: {base['body']}.",
            f"Undersuit color: {undersuit}, matching Image 1 exactly. No purple, violet or magenta.",
            "Pose: identical neutral symmetrical A-pose to Image 1; arms about 30 degrees away from the "
            "body; elbows straight; fingers separated; feet parallel.",
            RENDERING,
            f"Camera: {VIEW_CAMERA[view]}, eye level, no perspective, no tilt, identical scale and "
            "identical crop to Image 1.",
            BACKDROP,
            "Consistency: total height, head size, shoulder width, waist, limb thickness, boot shape and "
            "wear marks must match Image 1.",
            f"Avoid: purple, violet, magenta, equipment, armor, pouches, weapon, changed proportion, "
            f"{COMMON_AVOID}.",
        ]
    )


def main() -> None:
    data = json.loads(PALETTE.read_text(encoding="utf-8"))

    base_dir = OUT / "bases"
    kit_dir = OUT / "kits"
    base_dir.mkdir(parents=True, exist_ok=True)
    kit_dir.mkdir(parents=True, exist_ok=True)

    written = 0

    for base in data["bases"]:
        if base["source"] != "generate_new":
            continue
        for view in VIEWS:
            body = base_front(base, data) if view == "front" else base_other_view(base, data, view)
            (base_dir / f"{base['id']}_{view}.txt").write_text(body + "\n", encoding="utf-8")
            written += 1

    for character in data["characters"]:
        for view in VIEWS:
            if view == "front":
                body = kit_front(character, data)
            else:
                body = kit_other_view(character, data, view)
            (kit_dir / f"{character['id']}_{view}.txt").write_text(body + "\n", encoding="utf-8")
            written += 1

    print(f"wrote {written} prompts under {OUT.relative_to(ROOT)}")
    print(f"  bases: {len(list(base_dir.glob('*.txt')))}  kits: {len(list(kit_dir.glob('*.txt')))}")


if __name__ == "__main__":
    main()
