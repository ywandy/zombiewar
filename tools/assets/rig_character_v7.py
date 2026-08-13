"""把 v7 的完整角色网格绑到现有 43 骨骼，保留 20 个动画，导出可用 GLB。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/rig_character_v7.py -- \
        --rig assets/characters/Characters_Lis_SingleWeapon.gltf \
        --character-glb <tripo.glb> --character male_gunner \
        --out assets/characters/generated/male_gunner.glb \
        --render qa.png --report qa.json

v7 的角色是一个已经穿好装备的完整网格，所以不需要装配：对齐尺度 -> 减面到预算 ->
从骨架自带 Body 网格按邻近度转移权重 -> 挂上 Armature 修改器 -> 导出。

权重转移能成立的前提是网格处在骨架的 rest pose 上，这是蒙皮的硬性要求，不是近似。
实测骨架自带的 Lis 网格 X=2.043 / Z=1.718，宽度大于身高，是标准 T-pose，因此源图
必须按 T-pose 出（见 gen_dressed_prompts_v7.py 的姿势约定）。

首版曾按"手臂略张 15-20 度"出图并误判为与骨架一致，实际差 70 多度，会把手臂顶点
的权重映射到躯干骨上，20 个动画的手臂形变全错。
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector, kdtree


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


def align_facing(objects: list[bpy.types.Object]) -> dict:
    """把角色转到与骨架同朝向：骨架面朝 -Y，臂展落在 X 轴。

    分两步，因为 Tripo 对不同角色输出的朝向并不一致，实测同一批里既有面朝 X 的
    也有面朝 +Y 的：

    1. 轴向：T-pose 下臂展必然是最宽的水平轴，所以最宽的水平轴就该是 X。
       这条判据只在 T-pose 下成立。
    2. 前后：脚尖朝前。取最低一段高度的顶点当脚部，其质心相对全身质心的 Y 偏移
       指向角色正面。骨架面朝 -Y，所以脚尖若指向 +Y 就要再转 180 度。

    只做第 1 步会漏掉 180 度的情况——首版就漏了，10 个角色里有的正面有的背面，
    进 Godot 后会背对移动方向。
    """
    def rotate(deg: float) -> None:
        lo, hi = bounds(objects)
        pivot = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0.0))
        mat = Matrix.Rotation(math.radians(deg), 4, "Z")
        for ob in objects:
            ob.matrix_world = (
                Matrix.Translation(pivot) @ mat @ Matrix.Translation(-pivot) @ ob.matrix_world
            )
        bpy.context.view_layer.update()

    lo, hi = bounds(objects)
    yaw = 0.0
    if (hi.y - lo.y) > (hi.x - lo.x):
        rotate(-90.0)
        yaw = -90.0

    pts = [ob.matrix_world @ v.co for ob in objects if ob.type == "MESH" for v in ob.data.vertices]
    lo, hi = bounds(objects)
    foot_cut = lo.z + (hi.z - lo.z) * 0.08
    feet = [p for p in pts if p.z <= foot_cut]
    flipped = False
    if feet:
        body_y = sum(p.y for p in pts) / len(pts)
        foot_y = sum(p.y for p in feet) / len(feet)
        if foot_y > body_y:  # 脚尖指向 +Y，而骨架面朝 -Y
            rotate(180.0)
            yaw += 180.0
            flipped = True
    return {"yaw_deg": yaw, "flipped_180": flipped}


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


FINGER_STEMS = ("Thumb", "Index", "Middle", "Ring", "Pinky")


def deform_segments(armature: bpy.types.Object) -> list[tuple[str, Vector, Vector]]:
    """可用作绑定目标的骨骼线段。手指骨折叠到所属手掌骨。

    减面到 30000 面后手部只剩几十个顶点，撑不起 15 根手指骨；而俯视射击也不需要
    单指动画。不折叠的话，躯干上离手指骨略近的顶点会被整块绑过去，动画里拽出一片
    撕裂的面。
    """
    world = armature.matrix_world
    collapse: dict[str, str] = {}
    for bone in armature.data.bones:
        if any(stem in bone.name for stem in FINGER_STEMS):
            parent = bone.parent
            while parent is not None and any(stem in parent.name for stem in FINGER_STEMS):
                parent = parent.parent
            if parent is not None:
                collapse[bone.name] = parent.name

    segments: dict[str, tuple[Vector, Vector]] = {}
    for bone in armature.data.bones:
        if not bone.use_deform or bone.name in collapse:
            continue
        segments[bone.name] = (world @ bone.head_local, world @ bone.tail_local)
    return [(name, a, b) for name, (a, b) in segments.items()], collapse


def bind_weights_geometric(target: bpy.types.Object, armature: bpy.types.Object,
                           influences: int = 4, power: float = 2.0,
                           smooth_iterations: int = 12) -> str:
    """按顶点到骨骼线段的距离刷权重，再做拉普拉斯平滑。

    前两种方法都失败过：
    - DataTransfer 从 Lis 抄权重：体型差太多（4 头身瘦子 vs 3.5 头身重甲），上半身
      含双臂 2211 个顶点 100% 落到 Head 骨，动画里手臂完全不动；
    - 骨骼热扩散自动权重：headless 下 parent_set 不报错但一个顶点组都不生成。

    显式几何计算不依赖参考网格体型，也不依赖算子 context。但纯最近距离的权重太硬，
    单个顶点只要离错骨略近就被整块拽走，动画里拉出撕裂的面。因此在网格邻接图上做
    若干轮拉普拉斯平滑，把孤立错绑抹平，并让关节处产生连续过渡。
    """
    for vg in list(target.vertex_groups):
        target.vertex_groups.remove(vg)

    segments, _ = deform_segments(armature)
    if not segments:
        raise SystemExit("骨架里没有可用的 deform 骨骼")
    names = [name for name, _, _ in segments]
    index_of = {name: i for i, name in enumerate(names)}

    def dist_to_segment(p: Vector, a: Vector, b: Vector) -> float:
        ab = b - a
        denom = ab.length_squared
        if denom < 1e-12:
            return (p - a).length
        t = max(0.0, min(1.0, (p - a).dot(ab) / denom))
        return (p - (a + ab * t)).length

    mesh = target.data
    tm = target.matrix_world
    weights: list[dict[int, float]] = []
    for vert in mesh.vertices:
        world = tm @ vert.co
        ranked = sorted(
            ((dist_to_segment(world, a, b), index_of[name]) for name, a, b in segments),
            key=lambda item: item[0],
        )[:influences]
        raw = {i: 1.0 / max(d, 1e-4) ** power for d, i in ranked}
        total = sum(raw.values()) or 1.0
        weights.append({i: w / total for i, w in raw.items()})

    # 平滑用空间邻域而不是边邻接：Tripo 输出是上百个互不相连的碎壳（实测 122 个），
    # 权重沿边传不过壳与壳之间的缝，相邻两片拿到不同权重，形变时就沿缝撕开。
    # 按空间距离取邻居能跨过缝隙，把整个体表当成一个连续的权重场。
    coords = [tm @ v.co for v in mesh.vertices]
    zs = [c.z for c in coords]
    radius = max((max(zs) - min(zs)) * 0.025, 1e-4)
    tree = kdtree.KDTree(len(coords))
    for i, c in enumerate(coords):
        tree.insert(c, i)
    tree.balance()
    neighbors: list[list[int]] = []
    for i, c in enumerate(coords):
        found = [idx for (_, idx, _) in tree.find_range(c, radius) if idx != i]
        if not found:
            found = [idx for (_, idx, _) in tree.find_n(c, 5) if idx != i]
        neighbors.append(found)

    # 迭代中不截断影响数。每轮都截到 top-N 会把刚扩散过来的影响立刻砍掉，权重场
    # 在相邻顶点间不连续，形变时沿这些不连续处撕开。截断只在收敛后做一次。
    for _ in range(smooth_iterations):
        updated: list[dict[int, float]] = []
        for vi, current in enumerate(weights):
            acc: dict[int, float] = dict(current)
            adj = neighbors[vi]
            for nb in adj:
                for k, v in weights[nb].items():
                    acc[k] = acc.get(k, 0.0) + v
            denom = 1.0 + len(adj)
            updated.append({k: v / denom for k, v in acc.items()})
        weights = updated

    trimmed: list[dict[int, float]] = []
    for per_vertex in weights:
        top = sorted(per_vertex.items(), key=lambda kv: -kv[1])[:influences]
        total = sum(v for _, v in top) or 1.0
        trimmed.append({k: v / total for k, v in top})
    weights = trimmed

    # UV 接缝处存在同位置的重复顶点。它们在邻接图上不相连，平滑后权重会有细微差异，
    # 形变时沿接缝裂开成白缝。这里按位置分桶，强制同位置顶点共用同一份权重。
    buckets: dict[tuple[int, int, int], list[int]] = {}
    for vi, vert in enumerate(mesh.vertices):
        key = tuple(round(c * 1e5) for c in vert.co)
        buckets.setdefault(key, []).append(vi)
    welded = 0
    for members in buckets.values():
        if len(members) < 2:
            continue
        welded += len(members)
        merged: dict[int, float] = {}
        for vi in members:
            for k, v in weights[vi].items():
                merged[k] = merged.get(k, 0.0) + v
        total = sum(merged.values()) or 1.0
        shared = {k: v / total for k, v in merged.items()}
        for vi in members:
            weights[vi] = dict(shared)
    print(f"[weld] 同位置顶点 {welded} 个，权重已统一", flush=True)

    groups = {name: target.vertex_groups.new(name=name) for name in names}
    for vi, per_vertex in enumerate(weights):
        for bone_index, w in per_vertex.items():
            if w > 1e-4:
                groups[names[bone_index]].add([vi], w, "REPLACE")

    target.parent = armature
    target.matrix_parent_inverse = armature.matrix_world.inverted()
    target.modifiers.new("Armature", "ARMATURE").object = armature
    return "geometric_smoothed"


def bind_weights(target: bpy.types.Object, source: bpy.types.Object, armature: bpy.types.Object) -> str:
    """给角色刷权重。优先骨骼热扩散自动权重，失败再退回从参考网格转移。

    先试过 DataTransfer 从骨架自带的 Lis 网格按邻近度抄权重，结果整个上半身
    （含双臂 2211 个顶点）100% 落到 Head 骨上，动画里手臂完全不动。原因是体型
    差太多：Lis 是 4 头身瘦小角色，这批角色是 3.5 头身穿重甲，邻近度映射在上半身
    整体失效。腿部因为形状接近才侥幸正确。

    自动权重直接从骨骼位置做热扩散，不依赖参考网格的体型，是这里正确的方法。
    """
    for vg in list(target.vertex_groups):
        target.vertex_groups.remove(vg)

    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature
    try:
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        if any(v.groups for v in target.data.vertices):
            return "auto"
    except RuntimeError as exc:
        # 热扩散在非流形或有内部面的网格上会失败，这是 Tripo 输出的常见形态。
        print(f"[warn] 自动权重失败，退回 DataTransfer: {exc}", flush=True)

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
    return "datatransfer"


def weight_regions(target: bpy.types.Object) -> list[dict]:
    """按区域统计主导骨骼，用来挡住"手臂权重落到 Head"这类整段错绑。"""
    gname = {i: g.name for i, g in enumerate(target.vertex_groups)}
    pts = [target.matrix_world @ v.co for v in target.data.vertices]
    if not pts:
        return []
    xs, zs = [p.x for p in pts], [p.z for p in pts]
    cx, half = (min(xs) + max(xs)) / 2, max((max(xs) - min(xs)) / 2, 1e-6)
    zlo, zspan = min(zs), max(max(zs) - min(zs), 1e-6)

    def stat(name: str, pred) -> dict:
        idx = [i for i, p in enumerate(pts) if pred(p)]
        counts: dict[str, int] = {}
        for i in idx:
            for g in target.data.vertices[i].groups:
                if g.weight > 0.15:
                    counts[gname[g.group]] = counts.get(gname[g.group], 0) + 1
        top = sorted(counts.items(), key=lambda kv: -kv[1])[:3]
        return {"region": name, "verts": len(idx), "top_bones": top}

    return [
        stat("arm_left", lambda p: (p.x - cx) > half * 0.60),
        stat("arm_right", lambda p: (p.x - cx) < -half * 0.60),
        stat("torso", lambda p: abs(p.x - cx) < half * 0.25 and p.z > zlo + zspan * 0.45),
        stat("legs", lambda p: p.z < zlo + zspan * 0.40),
    ]


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
    facing = align_facing(char_objects)
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
    weight_method = bind_weights_geometric(body, armature)

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
        "weight_method": weight_method,
        "facing": facing,
        "within_budget": after <= args.budget,
        "weight_regions": weight_regions(body),
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
