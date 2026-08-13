"""在 headless Blender 里给单个角色 GLB 重上色，并渲一张正视图验证。

不要连 Blender MCP 跑这个——那个实例可能正被别人用着。用独立进程：

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/recolor_character_glb.py -- \
        --glb <in.glb> --character male_gunner --out-glb <out.glb> --render <out.png>

装配后的 GLB 里基体和 kit 是两个独立网格、各自独立贴图，所以能分开上色：
Body 用 palette-v6.json 的 undersuit_tint，Kit 用 main.hex。皮肤、头发、靴子、
米白皮件色相不在紫色窗口内，不受影响。

实际的像素改色调用 tools/assets/tint_base_albedo.py（宿主 python，带 PIL），
Blender 只负责拆包贴图、装回去、导出和渲染。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import bpy
from mathutils import Vector

HOST_PYTHON = os.environ.get("HOST_PYTHON", "/opt/homebrew/anaconda3/bin/python3")


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--glb", required=True)
    parser.add_argument("--character", required=True)
    parser.add_argument("--palette", required=True)
    parser.add_argument("--tint-tool", required=True)
    parser.add_argument("--out-glb", required=True)
    parser.add_argument("--render")
    return parser.parse_args(argv)


def albedo_images_of(obj: bpy.types.Object) -> list[bpy.types.Image]:
    """取出该网格材质里接到 Base Color 的贴图。"""
    found: list[bpy.types.Image] = []
    for mat in obj.data.materials:
        if mat is None or not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None:
                # Tripo 输出里 Color_* 是 albedo，NormalGL_*/ORM_* 不能碰。
                if node.image.name.startswith("Color"):
                    found.append(node.image)
    return found


def recolor_image(image: bpy.types.Image, target_hex: str, tint_tool: str, workdir: Path) -> bool:
    src = workdir / f"{image.name}_src.png"
    dst = workdir / f"{image.name}_tinted.png"

    image.filepath_raw = str(src)
    image.file_format = "PNG"
    image.save()

    result = subprocess.run(
        [HOST_PYTHON, tint_tool, str(src), "--target", target_hex, "-o", str(dst)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not dst.exists():
        print(f"  !! 上色失败 {image.name}: {result.stderr.strip()[:200]}")
        return False
    print(f"  {image.name} -> {target_hex}  {result.stdout.strip()}")

    image.filepath = str(dst)
    image.source = "FILE"
    image.reload()
    image.pack()
    return True


def setup_render(target: bpy.types.Object) -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 512
    scene.render.resolution_y = 768
    scene.render.film_transparent = False
    scene.world = bpy.data.worlds.new("QAWorld")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.85, 0.85, 0.85, 1)
    scene.world.node_tree.nodes["Background"].inputs[1].default_value = 1.2

    corners = [target.matrix_world @ Vector(c) for c in target.bound_box]
    lo = [min(v) for v in zip(*corners)]
    hi = [max(v) for v in zip(*corners)]
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
    height = hi[2] - lo[2]

    cam_data = bpy.data.cameras.new("QACam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = height * 1.25
    cam = bpy.data.objects.new("QACam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (cx, lo[1] - height * 2.0, cz)
    cam.rotation_euler = (1.5708, 0, 0)
    scene.camera = cam

    sun_data = bpy.data.lights.new("QASun", type="SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("QASun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (0.9, 0.2, 0.5)


def main() -> None:
    args = parse_args()
    palette = json.loads(Path(args.palette).read_text(encoding="utf-8"))
    character = next((c for c in palette["characters"] if c["id"] == args.character), None)
    if character is None:
        raise SystemExit(f"palette 里没有角色 {args.character!r}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)

    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data.materials]
    body = next((o for o in meshes if o.name.lower().startswith("body")), None)
    kits = [o for o in meshes if o is not body]
    if body is None:
        raise SystemExit(f"{args.glb} 里找不到 Body 网格，实际网格: {[o.name for o in meshes]}")

    print(f"[{args.character}] Body={body.name} Kit={[o.name for o in kits]}")

    workdir = Path(tempfile.mkdtemp(prefix=f"recolor_{args.character}_"))
    ok = True

    # 基体：底衣色
    for image in albedo_images_of(body):
        ok &= recolor_image(image, character["undersuit_tint"], args.tint_tool, workdir)

    # 兵种分件：主色
    seen: set[str] = set()
    for kit in kits:
        for image in albedo_images_of(kit):
            if image.name in seen:
                continue
            seen.add(image.name)
            ok &= recolor_image(image, character["main"]["hex"], args.tint_tool, workdir)

    if not ok:
        raise SystemExit(f"[{args.character}] 有贴图上色失败，不导出")

    Path(args.out_glb).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=args.out_glb,
        export_format="GLB",
        export_animations=True,
        export_skins=True,
        use_selection=False,
    )
    print(f"[{args.character}] 导出 {args.out_glb}")

    if args.render:
        # 渲 rest pose：清 action 不够，姿势骨骼会停在当前值，蒙皮件和非蒙皮件会错位。
        for armature in bpy.data.objects:
            if armature.type != "ARMATURE":
                continue
            if armature.animation_data:
                armature.animation_data.action = None
            armature.data.pose_position = "REST"
        bpy.context.view_layer.update()
        setup_render(body)
        Path(args.render).parent.mkdir(parents=True, exist_ok=True)
        bpy.context.scene.render.filepath = args.render
        bpy.ops.render.render(write_still=True)
        print(f"[{args.character}] 渲染 {args.render}")


if __name__ == "__main__":
    main()
