#!/usr/bin/env python3
"""v7：出"已穿戴完整角色"四视图，取代 v6 的部件表路线。

    python3 tools/assets/gen_dressed_prompts_v7.py

产出:
    docs/assets/player-characters/prompts-v7/<character_id>_<view>.txt

## 为什么放弃部件表

v6 的 kit 源图是摊开的部件阵列，Tripo 忠实地把阵列重建成 3D。要把这些部件摆到
身体上需要"这块是护膝、那块是弹链"这种语义，位置启发式做不到——部件表里护膝在
画面底部，身体上却要贴到膝盖，两者之间没有稳定的坐标映射。这条路已经失败两次：
Codex 的版本 kit 比身体宽 29%，脚本装配的版本部件散落。

模块化在本项目没有运行时价值，设计文档写明"基体不会在运行时动态换装"，它只是
生产便利。既然最终交付就是十个烘焙好的独立 GLB，直接出穿好的角色、一次重建成
一个网格，装配步骤连同姿势不一致问题一起消失。

体型也不再需要独立基体：矮壮、精瘦直接写进提示词。

## 姿势约定：必须是 T-pose

蒙皮的绑定姿势就是骨架的 rest pose，网格不处在 rest pose 上，形变必然崩。实测骨架
自带的 Lis 网格尺寸 X=2.043 / Z=1.718，宽度大于身高，是标准 T-pose（手臂完全水平）。

首版 v7 按"手臂略张 15-20 度"出图，与 rest pose 差 70 多度，按邻近度转移权重会把
手臂顶点映射到躯干骨上，20 个动画的手臂形变全错。因此改为严格 T-pose，并把骨架
rest pose 的渲染图直接当姿势模板喂进去——姿势和比例靠文字压不住，必须用图锁，这
一点在 female_slim 三连败和女性角色比例上已经验证过两次。

代价：侧视图里手臂正对镜头，透视压缩严重，手臂的重建信息主要靠正视与背视承担。
这个代价必须接受，因为绑定正确性没有商量余地。
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PALETTE = ROOT / "docs/assets/player-characters/palette-v6.json"
OUT = ROOT / "docs/assets/player-characters/prompts-v7"

VIEWS = ["front", "left", "back", "right"]

VIEW_CAMERA = {
    "front": "true orthographic exact front view",
    "left": "true orthographic exact left side view",
    "back": "true orthographic exact rear view",
    "right": "true orthographic exact right side view",
}

# 体型直接写进提示词，不再需要单独出基体模型。
BUILD = {
    "male_gunner": "compact standard adult male build, moderate shoulders",
    "male_assault": "compact standard adult male build, moderate shoulders",
    "male_medic": "compact standard adult male build, moderate shoulders",
    "male_demolition": "compact heavy-set adult male build, broad thick shoulders, barrel chest, heavier thighs",
    "male_riot": "compact heavy-set adult male build, broad thick shoulders, barrel chest, heavier thighs",
    "female_gunner": "compact lean adult female build, narrower shoulders, wiry limbs",
    "female_medic": "compact lean adult female build, narrower shoulders, wiry limbs",
    "female_assault": "compact standard adult female build, moderate shoulders, defined waist",
    "female_demolition": "compact standard adult female build, moderate shoulders, defined waist",
    "female_riot": "compact standard adult female build, moderate shoulders, defined waist",
}

POSE = (
    "Pose: strict T-pose, copied from Image 2. Both arms raised straight out to the sides and "
    "held perfectly HORIZONTAL at shoulder height, elbows locked straight, arms fully extended so "
    "the total arm span is wider than the character is tall. Palms face down, fingers straight and "
    "separated. Torso upright and symmetrical, legs straight and slightly apart, feet parallel and "
    "flat on the same ground line. No held object, no weapon, no leaning, no action pose, arms must "
    "NOT hang down and must NOT be in a 30-degree A-pose."
)

RENDERING = (
    "Rendering: rough uneven thick black ink outer line, scratchy internal ink, flat two-step cel "
    "shading, hand-painted grime, scratches and stitched repairs, angular simplified readable "
    "shapes. Bold inked cartoon game character, not a rendered product photo."
)

BACKDROP = (
    "Backdrop: flat uniform light gray, no horizon, no floor, no cast shadow, no vignette, "
    "no gradient, no scenery, no text, no logo, no watermark."
)

AVOID = (
    "purple, violet, magenta, separated floating equipment pieces, exploded parts layout, "
    "held weapon, tall silhouette, long legs, fashion-model body, 4-head-plus anatomy, oversized "
    "head, bobblehead, superhero muscles, photorealism, glossy 3D render, smooth vector art, soft "
    "airbrush, smooth gradient shading, three-quarter view, perspective distortion, dramatic pose, "
    "extra limbs, fused fingers, floating accessories, letters or typographic glyphs"
)


def palette_block(c: dict, neutrals: dict) -> str:
    m, s, a = c["main"], c["secondary"], c["accent"]
    return (
        f"Color identity (unique to this character, the only palette allowed): main garment is "
        f"{m['name']} {m['hex']} covering the large coat, vest and armor surfaces; secondary is "
        f"{s['name']} {s['hex']}; accent is {a['name']} {a['hex']} on straps, tape and small "
        f"identifiers; the undersuit worn beneath the equipment is {c['undersuit_tint']}. Shared "
        f"neutrals across the roster: cream off-white {neutrals['cream']} leather and webbing, dark "
        f"brown {neutrals['leather_brown']} belts, gray {neutrals['metal_gray']} metal fittings. "
        f"Absolutely no purple, violet or magenta anywhere."
    )


def front_prompt(c: dict, data: dict) -> str:
    cls = c["class"]
    return "\n".join(
        [
            "Use case: stylized-concept",
            "Asset type: front orthographic full character source art for image-to-3D",
            f"Input images: Image 1 is the approved equipment design sheet for {c['id']} and is "
            "authoritative for the face, hair, equipment shapes, colors and wear. Image 2 is the "
            "target rig rest pose and is authoritative for the T-pose arm angle: the mesh must be "
            "built in this exact pose so it can be skinned onto the existing skeleton.",
            f"Subject: ONE complete {cls} survivor character, fully wearing every piece of equipment "
            "shown in Image 1, assembled onto the body. This is a single connected figure, NOT a "
            "layout of separated parts.",
            f"Build: {BUILD[c['id']]}. {data['proportion'].split(' (')[0]} tall, low center of "
            "gravity, short torso and short legs, head and hands in natural coordinated proportion.",
            f"Face and identity: {c['face']}. Must be the same person as Image 1.",
            f"Equipment worn: every part from Image 1 in its natural worn position on the body "
            f"({data['class_parts'][cls]}), sitting correctly on shoulders, chest, waist, arms and "
            "knees with no floating gaps.",
            palette_block(c, data["shared_style"]["neutrals"]),
            f"Motif: {data['class_motifs'][cls]}, used sparingly and at most three times.",
            f"Silhouette intent: {data['class_silhouette'][cls]}.",
            POSE,
            RENDERING,
            f"Camera: {VIEW_CAMERA['front']}, eye level, no perspective, no tilt. Full body centered "
            "with generous padding.",
            BACKDROP,
            f"Avoid: {AVOID}.",
        ]
    )


def other_view_prompt(c: dict, data: dict, view: str) -> str:
    return "\n".join(
        [
            "Use case: stylized-concept",
            f"Asset type: {view} orthographic full character source art for image-to-3D",
            f"Input images: Image 1 is the approved v7 FRONT view of {c['id']}. It is the identity "
            "reference and must be matched exactly.",
            f"Subject: the same single complete character as Image 1, same person, same equipment, "
            f"same part count, same colors, same wear marks, same height and same scale, redrawn "
            f"seen from the {view}.",
            f"Face and identity: {c['face']}. Same person as Image 1.",
            palette_block(c, data["shared_style"]["neutrals"]),
            POSE,
            RENDERING,
            f"Camera: {VIEW_CAMERA[view]}, eye level, no perspective, no tilt, identical scale and "
            "identical crop to Image 1. The figure must occupy exactly the same image height as in "
            "Image 1 so the four views register against each other.",
            BACKDROP,
            "Consistency: garment seams, pouch count, buckle count, damage marks, colors, hair and "
            "silhouette width must all match Image 1. Do not add, remove or restyle any part.",
            f"Avoid: {AVOID}, new parts not present in Image 1.",
        ]
    )


def main() -> None:
    data = json.loads(PALETTE.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    written = 0
    for c in data["characters"]:
        for view in VIEWS:
            body = front_prompt(c, data) if view == "front" else other_view_prompt(c, data, view)
            (OUT / f"{c['id']}_{view}.txt").write_text(body + "\n", encoding="utf-8")
            written += 1
    print(f"wrote {written} prompts under {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
