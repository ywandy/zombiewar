"""把 v7 的完整角色网格绑到现有 43 骨骼，保留 20 个动画，导出可用 GLB。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/rig_character_v7.py -- \
        --rig assets/characters/Characters_Lis_SingleWeapon.gltf \
        --character-glb <tripo.glb> --character male_gunner \
        --out assets/characters/generated/male_gunner.glb \
        --render qa.png --report qa.json

v7 的角色是一个已经穿好装备的完整网格，所以不需要装配：对齐尺度 -> 减面到预算 ->
从骨架自带 Body 网格按邻近度转移权重 -> 挂上 Armature 修改器 -> 导出。

权重转移能成立的前提是姿势接近：v7 提示词里逐字锁了"手臂略张 15-20 度，不是外张
30 度的 A-pose"，与骨架自带 Body 网格的姿势一致。这正是 v6 部件路线做不到的。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--rig", required=True)
    p.add_argument("--character-glb", required=True)
    p.add_argument("--character", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--render")
    p.add_argument("--report")
    p.add_argument("--budget", type=int, default=30000)
    return p.parse_args(argv)


def import_glb(path: str) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    pts = [o.matrix_world @ v.co for o in objects if o.type == "MESH" for v in o.data.vertices]
    if not pts:
        raise SystemExit("没有可用网格")
    return (
        Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))),
        Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts))),
    )


def fit_to(objects: list[bpy.types.Object], lo: Vector, hi: Vector) -> None:
    """按身高等比缩放，水平居中，脚底贴合骨架的地面高度。"""
    src_lo, src_hi = bounds(objects)
    scale = (hi.z - lo.z) / max(src_hi.z - src_lo.z, 1e-6)
    src_mid, dst_mid = (src_lo + src_hi) / 2, (lo + hi) / 2
    for ob in objects:
        ob.scale = tuple(s * scale for s in ob.scale)
        ob.location = (
            dst_mid.x + (ob.location.x - src_mid.x) * scale,
            dst_mid.y + (ob.location.y - src_mid.y) * scale,
            lo.z + (ob.location.z - src_lo.z) * scale,
        )
    bpy.context.view_layer.update()


def decimate(obj: bpy.types.Object, target: int) -> int:
    """减面到预算内。细节由 Tripo 烘出的法线贴图承担，不靠面数刻磨损。"""
    obj.data.calc_loop_triangles()
    current = len(obj.data.loop_triangles)
    if current <= target or current == 0:
        return current
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new("Decimate", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = max(target / current, 0.005)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def transfer_weights(target: bpy.types.Object, source: bpy.types.Object, armature: bpy.types.Object) -> None:
    """权重从骨架自带的 Body 网格按邻近度转移，保留已验证的 43 骨骼权重分布。"""
    for vg in list(target.vertex_groups):
        target.vertex_groups.remove(vg)
    for vg in source.vertex_groups:
        target.vertex_groups.new(name=vg.name)

    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    mod = target.modifiers.new("DataTransfer", "DATA_TRANSFER")
    mod.object = source
    mod.use_vert_data = True
    mod.data_types_verts = {"VGROUP_WEIGHTS"}
    mod.vert_mapping = "POLYINTERP_NEAREST"
    bpy.ops.object.datalayout_transfer(modifier=mod.name)
    bpy.ops.object.modifier_apply(modifier=mod.name)

    target.parent = armature
    target.matrix_parent_inverse = armature.matrix_world.inverted()
    target.modifiers.new("Armature", "ARMATURE").object = armature


def setup_render(target: bpy.types.Object, width: int = 700, height: int = 1000) -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x, scene.render.resolution_y = width, height
    scene.world = bpy.data.worlds.new("QAWorld")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs[0].default_value = (0.85, 0.85, 0.85, 1)
    scene.world.node_tree.nodes["Background"].inputs[1].default_value = 1.4

    lo, hi = bounds([target])
    span_z, span_x = hi.z - lo.z, hi.x - lo.x
    cx, cz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
    # ortho_scale 作用于较长边。竖幅下必须按 z 跨度换算，否则人物会被裁掉。
    ortho = max(span_z * 1.15, span_x * 1.15 * height / width)

    cam_data = bpy.data.cameras.new("QACam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho
    cam = bpy.data.objects.new("QACam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = (cx, lo.y - span_z * 3.0, cz)
    cam.rotation_euler = (1.5708, 0, 0)
    scene.camera = cam

    sun_data = bpy.data.lights.new("QASun", type="SUN")
    sun_data.energy = 3.5
    sun = bpy.data.objects.new("QASun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (0.9, 0.2, 0.5)


def main() -> None:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)

    rig_objects = import_glb(args.rig)
    armature = next((o for o in rig_objects if o.type == "ARMATURE"), None)
    if armature is None:
        raise SystemExit(f"{args.rig} 里没有骨架")
    rig_meshes = [o for o in rig_objects if o.type == "MESH"]
    rig_body = next((o for o in rig_meshes if o.vertex_groups), None)
    if rig_body is None:
        raise SystemExit(f"{args.rig} 里没有带权重的网格")
    # 骨架源文件自带 Axe/Guitar/Knife/Pistol/Rifle/Shotgun/SMG/Spear 等占位武器网格。
    # 只删 Body 会把它们一起导出去，成品里会挂着一把不属于这个角色的武器。
    for extra in rig_meshes:
        if extra is not rig_body:
            bpy.data.objects.remove(extra, do_unlink=True)
    bones = [b.name for b in armature.data.bones]
    actions = [a.name for a in bpy.data.actions]
    rig_lo, rig_hi = bounds([rig_body])

    char_objects = [o for o in import_glb(args.character_glb) if o.type == "MESH"]
    if not char_objects:
        raise SystemExit(f"{args.character_glb} 里没有网格")
    fit_to(char_objects, rig_lo, rig_hi)

    bpy.ops.object.select_all(action="DESELECT")
    for ob in char_objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = char_objects[0]
    if len(char_objects) > 1:
        bpy.ops.object.join()
    body = bpy.context.view_layer.objects.active
    body.name = "Body"

    before = len(body.data.loop_triangles) if body.data.loop_triangles else 0
    body.data.calc_loop_triangles()
    before = len(body.data.loop_triangles)
    # 减面必须在权重转移之前：转移后改拓扑会把权重打乱。
    after = decimate(body, args.budget)
    transfer_weights(body, rig_body, armature)

    bpy.data.objects.remove(rig_body, do_unlink=True)

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=args.out, export_format="GLB", export_animations=True, export_skins=True
    )

    report = {
        "character": args.character,
        "bones": len(bones),
        "actions": len(actions),
        "action_names": actions,
        "triangles_before": before,
        "triangles_after": after,
        "budget": args.budget,
        "within_budget": after <= args.budget,
        "out": args.out,
    }
    print("###REPORT###" + json.dumps(report, ensure_ascii=False))
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    if args.render:
        for arm in bpy.data.objects:
            if arm.type == "ARMATURE":
                if arm.animation_data:
                    arm.animation_data.action = None
                arm.data.pose_position = "REST"
        bpy.context.view_layer.update()
        setup_render(body)
        Path(args.render).parent.mkdir(parents=True, exist_ok=True)
        bpy.context.scene.render.filepath = args.render
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
