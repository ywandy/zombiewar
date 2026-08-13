"""把基体 + 兵种分件装配成一个带 43 骨骼和 20 个动画的角色 GLB。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/assemble_character.py -- \
        --rig assets/characters/Characters_Lis_SingleWeapon.gltf \
        --base <base_tripo.glb> --kit <kit_tripo.glb> \
        --character male_gunner --out assets/characters/generated/male_gunner.glb \
        --render qa.png

## 为什么不是"把 kit 整体套到 body 上"

现有 10 个 GLB 的 kit 比身体宽 29%，根因是上游三方姿势互不一致：骨架 rest 是
T-pose（上臂与竖直夹角 92.5 度），基体图手臂近乎下垂，kit 图是外张 30 度的
A-pose。整体套用必然错位，而且靠调提示词让三者对齐并不可靠。

这里改为绕开姿势问题：kit 按顶点连通性拆成独立部件，每个部件按自身在归一化人体
坐标里的位置找到归属骨骼，然后刚性绑定到该骨骼。硬质护具本来就该刚性绑定（设计
文档同样要求"硬质背包、腰包和武器优先通过对应骨骼挂点刚性绑定"），刚性绑定后部件
跟着骨骼走，源图手臂是 15 度还是 30 度都不再影响结果。

基体是贴身且随关节变形的，仍然走蒙皮，权重从原始骨架自带的 Body 网格转移，
不用自动权重，以保留已验证过的 43 骨骼权重分布。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector

# 部件质心落在归一化人体高度的哪一段，就归属哪根骨骼。
# 归一化 t = (z - z_min) / height，左右由 x 的符号决定。
BONE_ZONES = [
    (0.88, 1.01, "Head", "Head"),
    (0.78, 0.88, "Neck", "Neck"),
    (0.62, 0.78, "Shoulder", "Torso"),
    (0.50, 0.62, "Torso", "Torso"),
    (0.40, 0.50, "Abdomen", "Abdomen"),
    (0.30, 0.40, "Hips", "Hips"),
    (0.15, 0.30, "UpperLeg", "Hips"),
    (0.05, 0.15, "LowerLeg", "Hips"),
    (-0.01, 0.05, "Foot", "Hips"),
]

# 侧向偏离中轴超过这个比例的部件，改判为手臂链上的骨骼（护肘、护腕、手套）。
LATERAL_ARM_THRESHOLD = 0.30


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--rig", required=True, help="提供 43 骨骼与 20 个动画的源 GLTF")
    p.add_argument("--base", required=True)
    p.add_argument("--kit")
    p.add_argument("--character", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--render")
    p.add_argument("--report", help="把装配统计写成 JSON")
    p.add_argument("--budget", type=int, default=30000, help="整个角色的三角面预算")
    p.add_argument("--base-share", type=float, default=0.55, help="基体占预算的比例，其余给分件")
    p.add_argument("--cluster-radius", type=float, default=0.06,
                   help="碎块聚类半径，按身高比例；弹链这类由多颗子弹组成的部件靠它并回整体")
    return p.parse_args(argv)


def import_glb(path: str) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def mesh_bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    pts = [o.matrix_world @ v.co for o in objects if o.type == "MESH" for v in o.data.vertices]
    if not pts:
        raise SystemExit("没有可用网格")
    return (
        Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))),
        Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts))),
    )


def fit_to(objects: list[bpy.types.Object], lo: Vector, hi: Vector) -> None:
    """把一组物体等比缩放并平移到目标包围盒：以身高对齐，水平居中，脚底贴合。"""
    src_lo, src_hi = mesh_bounds(objects)
    src_h = src_hi.z - src_lo.z
    dst_h = hi.z - lo.z
    if src_h <= 0:
        raise SystemExit("源高度为 0")
    scale = dst_h / src_h
    src_mid = (src_lo + src_hi) / 2
    dst_mid = (lo + hi) / 2
    for ob in objects:
        ob.scale = (ob.scale.x * scale, ob.scale.y * scale, ob.scale.z * scale)
        ob.location = (
            dst_mid.x + (ob.location.x - src_mid.x) * scale,
            dst_mid.y + (ob.location.y - src_mid.y) * scale,
            lo.z + (ob.location.z - src_lo.z) * scale,
        )
    bpy.context.view_layer.update()


def centroid(obj: bpy.types.Object) -> Vector:
    pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    return sum(pts, Vector()) / len(pts)


def split_parts(obj: bpy.types.Object, cluster_radius: float) -> list[bpy.types.Object]:
    """拆成逻辑部件：先按连通性拆散，再把空间上挨着的碎块并回去。

    直接按连通性拆会拆过头——弹链上每颗子弹、每个扣具都是独立连通块，各自绑到不同
    骨骼后弹链会散架。所以拆完再按质心距离做一次并查集聚类，半径取身高的一个比例，
    让"一条弹链"重新成为一个整体。
    """
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    before = set(bpy.data.objects)
    bpy.ops.mesh.separate(type="LOOSE")
    islands = [o for o in ([obj] + [o for o in bpy.data.objects if o not in before]) if o.data.vertices]
    if len(islands) <= 1:
        return islands

    centers = [centroid(o) for o in islands]
    parent = list(range(len(islands)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i in range(len(islands)):
        for j in range(i + 1, len(islands)):
            if (centers[i] - centers[j]).length <= cluster_radius:
                a, b = find(i), find(j)
                if a != b:
                    parent[a] = b

    groups: dict[int, list[bpy.types.Object]] = {}
    for idx, ob in enumerate(islands):
        groups.setdefault(find(idx), []).append(ob)

    merged: list[bpy.types.Object] = []
    for members in groups.values():
        if len(members) == 1:
            merged.append(members[0])
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for ob in members:
            ob.select_set(True)
        bpy.context.view_layer.objects.active = members[0]
        bpy.ops.object.join()
        merged.append(bpy.context.view_layer.objects.active)
    return merged


def decimate(obj: bpy.types.Object, target_tris: int) -> int:
    """减面到预算内。细节由 Tripo 烘出的法线贴图承担，不靠高面数刻磨损。"""
    obj.data.calc_loop_triangles()
    current = len(obj.data.loop_triangles)
    if current <= target_tris or current == 0:
        return current
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new("Decimate", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = max(target_tris / current, 0.005)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def pick_bone(part: bpy.types.Object, lo: Vector, hi: Vector, bones: set[str]) -> str:
    """按部件质心在归一化人体坐标里的位置选归属骨骼。"""
    pts = [part.matrix_world @ v.co for v in part.data.vertices]
    c = sum(pts, Vector()) / len(pts)
    height = hi.z - lo.z
    t = (c.z - lo.z) / height if height > 0 else 0.5
    half_width = max((hi.x - lo.x) / 2, 1e-6)
    lateral = (c.x - (lo.x + hi.x) / 2) / half_width
    side = "L" if lateral > 0 else "R"

    # 高度落在躯干段但明显偏离中轴的，是护肘护腕手套一类，归到手臂链。
    if abs(lateral) > LATERAL_ARM_THRESHOLD and t > 0.35:
        for stem in ("LowerArm", "UpperArm", "Shoulder"):
            if f"{stem}.{side}" in bones:
                return f"{stem}.{side}"

    for lo_t, hi_t, stem, fallback in BONE_ZONES:
        if lo_t <= t < hi_t:
            for cand in (f"{stem}.{side}", stem, fallback):
                if cand in bones:
                    return cand
    return "Torso" if "Torso" in bones else next(iter(bones))


def rigid_bind(part: bpy.types.Object, armature: bpy.types.Object, bone: str) -> None:
    """整块绑到一根骨骼：硬质护具跟着骨骼走，不参与形变。"""
    for vg in list(part.vertex_groups):
        part.vertex_groups.remove(vg)
    group = part.vertex_groups.new(name=bone)
    group.add(range(len(part.data.vertices)), 1.0, "REPLACE")
    part.parent = armature
    part.matrix_parent_inverse = armature.matrix_world.inverted()
    mod = part.modifiers.new("Armature", "ARMATURE")
    mod.object = armature


def transfer_weights(target: bpy.types.Object, source: bpy.types.Object, armature: bpy.types.Object) -> None:
    """基体权重从骨架自带的 Body 网格转移，保留已验证的 43 骨骼权重分布。"""
    for vg in list(target.vertex_groups):
        target.vertex_groups.remove(vg)
    for vg in source.vertex_groups:
        target.vertex_groups.new(name=vg.name)

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
    arm_mod = target.modifiers.new("Armature", "ARMATURE")
    arm_mod.object = armature


def main() -> None:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)

    # 1. 骨架：43 骨骼与 20 个动画的唯一来源
    rig_objects = import_glb(args.rig)
    armature = next((o for o in rig_objects if o.type == "ARMATURE"), None)
    if armature is None:
        raise SystemExit(f"{args.rig} 里没有骨架")
    rig_body = next((o for o in rig_objects if o.type == "MESH" and o.vertex_groups), None)
    if rig_body is None:
        raise SystemExit(f"{args.rig} 里没有带权重的网格，无法转移权重")
    bones = {b.name for b in armature.data.bones}
    actions = [a.name for a in bpy.data.actions]
    rig_lo, rig_hi = mesh_bounds([rig_body])

    # 2. 基体：对齐到骨架尺度后蒙皮
    base_objects = [o for o in import_glb(args.base) if o.type == "MESH"]
    if not base_objects:
        raise SystemExit(f"{args.base} 里没有网格")
    fit_to(base_objects, rig_lo, rig_hi)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in base_objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = base_objects[0]
    if len(base_objects) > 1:
        bpy.ops.object.join()
    base = bpy.context.view_layer.objects.active
    base.name = "Body"
    body_budget = int(args.budget * args.base_share)
    base_tris = decimate(base, body_budget)
    # 减面必须在权重转移之前：转移后再改拓扑会把权重打乱。
    transfer_weights(base, rig_body, armature)

    report = {
        "character": args.character,
        "bones": len(bones),
        "actions": len(actions),
        "base_triangles": base_tris,
        "budget": args.budget,
        "parts": [],
    }

    # 3. 兵种分件：拆块 -> 按归一化位置认领骨骼 -> 刚性绑定
    if args.kit:
        kit_objects = [o for o in import_glb(args.kit) if o.type == "MESH"]
        if kit_objects:
            fit_to(kit_objects, rig_lo, rig_hi)
            radius = (rig_hi.z - rig_lo.z) * args.cluster_radius
            parts: list[bpy.types.Object] = []
            for ob in kit_objects:
                parts.extend(split_parts(ob, radius))
            parts = [p for p in parts if p.data.vertices]
            # 分件预算按各自当前面数占比分配，大件多分，小扣具不会被削没。
            for p in parts:
                p.data.calc_loop_triangles()
            total_kit = sum(len(p.data.loop_triangles) for p in parts) or 1
            kit_budget = args.budget - base_tris
            for idx, part in enumerate(parts):
                share = len(part.data.loop_triangles) / total_kit
                decimate(part, max(int(kit_budget * share), 24))
                bone = pick_bone(part, rig_lo, rig_hi, bones)
                part.name = f"{args.character}_part{idx:02d}_{bone}"
                rigid_bind(part, armature, bone)
                part.data.calc_loop_triangles()
                report["parts"].append(
                    {"name": part.name, "bone": bone, "triangles": len(part.data.loop_triangles)}
                )

    base.data.calc_loop_triangles()
    report["total_triangles"] = report["base_triangles"] + sum(p["triangles"] for p in report["parts"])
    report["part_count"] = len(report["parts"])

    # 4. 清掉骨架自带的旧网格，只留新角色
    bpy.data.objects.remove(rig_body, do_unlink=True)

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=args.out, export_format="GLB", export_animations=True, export_skins=True
    )
    report["out"] = args.out
    print("###REPORT###" + json.dumps(report, ensure_ascii=False))

    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
