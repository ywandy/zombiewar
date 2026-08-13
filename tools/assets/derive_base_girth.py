"""从已有基体网格派生体型变体，只改围度，不动身高和关节位置。

出图派生体型不可靠：male_heavy 一次就对，female_slim 连试三次都被模型画成
5-6 头身的写实修长身材（"slim/thin/wiry" 在这个画风下有强先验，提示词压不住）。
围度变体本来就是确定性几何操作，交给 Blender 比交给模型稳。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/derive_base_girth.py -- \
        --glb female_base_tripo.glb --factor 0.88 --out female_slim.glb --render qa.png

沿 X/Y 向中轴缩放顶点，Z 一律不动，所以总身高、头身比、以及后续骨骼要落的
肩/肘/腕/髋/膝/踝高度全部保持不变。头部和靴底按高度加权豁免，避免大头被缩小
或者靴子离地。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bpy
from mathutils import Vector

# 按归一化高度 t 划分：头顶 -> 颈 -> 身体 -> 脚踝 -> 靴底
HEAD_KEEP = 0.72   # t 以上完全不缩，保住大头
NECK_BLEND = 0.66  # HEAD_KEEP 与此之间平滑过渡
ANKLE_BLEND = 0.06  # 此以下渐回 1.0，靴底不变形


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--glb", required=True)
    p.add_argument("--factor", type=float, required=True, help="<1 收窄，>1 加粗")
    p.add_argument("--out", required=True)
    p.add_argument("--render")
    return p.parse_args(argv)


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge0 == edge1:
        return 0.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def girth_factor(t: float, factor: float) -> float:
    """t 是顶点的归一化高度，返回该高度应用的围度系数。"""
    if t >= HEAD_KEEP:
        return 1.0
    if t > NECK_BLEND:
        return 1.0 + (factor - 1.0) * (1.0 - smoothstep(NECK_BLEND, HEAD_KEEP, t))
    if t < ANKLE_BLEND:
        return 1.0 + (factor - 1.0) * smoothstep(0.0, ANKLE_BLEND, t)
    return factor


def main() -> None:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit(f"{args.glb} 里没有网格")

    # 全体网格共用同一套 Z 范围和中轴，否则各部件会被按各自包围盒错位缩放。
    all_world = [o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
    z_lo = min(p.z for p in all_world)
    z_hi = max(p.z for p in all_world)
    cx = (min(p.x for p in all_world) + max(p.x for p in all_world)) / 2.0
    cy = (min(p.y for p in all_world) + max(p.y for p in all_world)) / 2.0
    span = z_hi - z_lo
    if span <= 0:
        raise SystemExit("模型高度为 0，无法归一化")

    moved = 0
    for ob in meshes:
        mw = ob.matrix_world
        inv = mw.inverted()
        for v in ob.data.vertices:
            world = mw @ v.co
            f = girth_factor((world.z - z_lo) / span, args.factor)
            if f == 1.0:
                continue
            world.x = cx + (world.x - cx) * f
            world.y = cy + (world.y - cy) * f
            v.co = inv @ world
            moved += 1
        ob.data.update()

    print(f"围度系数 {args.factor}，调整顶点 {moved}，Z 范围保持 {z_lo:.4f}..{z_hi:.4f}")

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB", use_selection=False)
    print(f"导出 {args.out}")

    if args.render:
        scene = bpy.context.scene
        scene.render.engine = "BLENDER_EEVEE_NEXT"
        scene.render.resolution_x, scene.render.resolution_y = 512, 768
        scene.world = bpy.data.worlds.new("QAWorld")
        scene.world.use_nodes = True
        scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.85, 0.85, 0.85, 1)

        cam_data = bpy.data.cameras.new("QACam")
        cam_data.type = "ORTHO"
        cam_data.ortho_scale = span * 1.2
        cam = bpy.data.objects.new("QACam", cam_data)
        bpy.context.collection.objects.link(cam)
        cam.location = (cx, cy - span * 2.0, (z_lo + z_hi) / 2.0)
        cam.rotation_euler = (1.5708, 0, 0)
        scene.camera = cam

        sun_data = bpy.data.lights.new("QASun", type="SUN")
        sun_data.energy = 3.0
        sun = bpy.data.objects.new("QASun", sun_data)
        bpy.context.collection.objects.link(sun)
        sun.rotation_euler = (0.9, 0.2, 0.5)

        Path(args.render).parent.mkdir(parents=True, exist_ok=True)
        scene.render.filepath = args.render
        bpy.ops.render.render(write_still=True)
        print(f"渲染 {args.render}")


if __name__ == "__main__":
    main()
