"""按真实类型标定武器尺寸，并对齐原点与前向。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/calibrate_weapon_scale.py -- \
        --glb <tripo.glb> --weapon ak47 --out assets/weapons/generated/ak47.glb

Tripo 把每个模型都归一化到最长边 1.0，所以手雷和 M249 在 3D 里一样大。实测 15 件
武器最长边全部是 1.000。不标定的话，手枪会被拉成步枪，手雷会大得像油桶。

标定三件事：
1. 尺寸：按 WEAPON_LENGTHS 的真实长度缩放。参照物是骨架身高 1.718，与真人身高
   同量级，因此直接用米。
2. 原点：移到握把位置而不是包围盒中心，这样挂到手部骨骼上时握持点才对。
   长条武器的握把在长轴靠后约 30% 处，近战与投掷物在中心。
3. 前向：最长轴对齐 -Z（Godot 前向），枪口朝前。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

# 真实全长（米）。折叠枪托的按展开态取值，游戏里角色持枪是展开的。
WEAPON_LENGTHS = {
    "hk45c": 0.19,
    "tactical_knife": 0.30,
    "frag_grenade": 0.11,
    "mp5": 0.60,
    "spas12": 0.85,
    "m4a1": 0.80,
    "ak47": 0.87,
    "m249": 1.04,
    "svd_sniper": 1.23,
    "rpg": 0.95,
    "flamethrower": 0.90,
    "chainsaw": 0.75,
    "landmine": 0.32,
    "fuel_barrel": 0.88,
    "sentry_turret": 0.90,
}

# 握把在长轴上的相对位置（0 = 最后端，1 = 枪口）。原点落在这里，挂点才对得上手。
TRIANGLE_BUDGET = 5000
# 放置类武器用地面挂点而不是枪口挂点
GROUND_SOCKET_WEAPONS = {"landmine", "fuel_barrel", "frag_grenade"}

GRIP_ALONG_AXIS = {
    "hk45c": 0.35,
    "mp5": 0.30,
    "spas12": 0.28,
    "m4a1": 0.30,
    "ak47": 0.30,
    "m249": 0.28,
    "svd_sniper": 0.28,
    "rpg": 0.35,
    "flamethrower": 0.30,
    "chainsaw": 0.20,
    "tactical_knife": 0.15,
}
# 未列出的（手雷、地雷、油桶、炮塔）原点取几何中心：它们是投掷物或放置物，
# 不存在握把，原点在中心才便于放置和旋转。


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--glb", required=True)
    p.add_argument("--weapon", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--report")
    return p.parse_args(argv)


def main() -> None:
    args = parse_args()
    if args.weapon not in WEAPON_LENGTHS:
        raise SystemExit(f"未登记的武器 {args.weapon}，请先在 WEAPON_LENGTHS 里给出真实长度")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data.vertices]
    if not meshes:
        raise SystemExit(f"{args.glb} 里没有网格")

    def bounds() -> tuple[Vector, Vector]:
        pts = [o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
        return (
            Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))),
            Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts))),
        )

    lo, hi = bounds()
    size = hi - lo
    axis = max(range(3), key=lambda i: size[i])
    before = round(size[axis], 4)

    # 1. 前向：把最长轴转到 Z，武器沿 Z 摆放，再整体转成 Godot 的 -Z 前向
    if axis != 2:
        rot = Matrix.Rotation(1.5707963, 4, "Y" if axis == 0 else "X")
        for ob in meshes:
            ob.matrix_world = rot @ ob.matrix_world
        bpy.context.view_layer.update()
        lo, hi = bounds()
        size = hi - lo

    # 2. 尺寸：缩放到登记的真实长度
    target = WEAPON_LENGTHS[args.weapon]
    scale = target / max(size.z, 1e-6)
    for ob in meshes:
        ob.matrix_world = Matrix.Scale(scale, 4) @ ob.matrix_world
    bpy.context.view_layer.update()
    lo, hi = bounds()

    # 3. 原点：移到握把处（长武器）或几何中心（投掷与放置物）
    grip_t = GRIP_ALONG_AXIS.get(args.weapon, 0.5)
    origin = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z + (hi.z - lo.z) * grip_t))
    for ob in meshes:
        ob.matrix_world = Matrix.Translation(-origin) @ ob.matrix_world
    bpy.context.view_layer.update()

    # 4. 减面：main 的武器校验要求每件不超过 5000 三角面
    tris_before = 0
    for ob in meshes:
        ob.data.calc_loop_triangles()
        tris_before += len(ob.data.loop_triangles)
    if tris_before > TRIANGLE_BUDGET:
        for ob in meshes:
            ob.data.calc_loop_triangles()
            cur = len(ob.data.loop_triangles)
            if cur <= 0:
                continue
            share = max(int(TRIANGLE_BUDGET * cur / tris_before), 32)
            if cur <= share:
                continue
            bpy.context.view_layer.objects.active = ob
            mod = ob.modifiers.new("Decimate", "DECIMATE")
            mod.decimate_type = "COLLAPSE"
            mod.ratio = max(share / cur, 0.002)
            bpy.ops.object.modifier_apply(modifier=mod.name)
    tris_after = 0
    for ob in meshes:
        ob.data.calc_loop_triangles()
        tris_after += len(ob.data.loop_triangles)

    # 5. 挂点：枪械要 MuzzleSocket（枪口，用于火光与曳光起点），地雷要 GroundSocket。
    #    没有挂点，main 的武器表现系统会把火光挂在原点上，飘在枪身外面。
    lo, hi = bounds()
    socket_name = "GroundSocket" if args.weapon in GROUND_SOCKET_WEAPONS else "MuzzleSocket"
    socket = bpy.data.objects.new(socket_name, None)
    socket.empty_display_size = 0.02
    bpy.context.collection.objects.link(socket)
    # 枪口在长轴正前端；地面挂点在最低处中心
    socket.location = (
        (0.0, 0.0, hi.z) if socket_name == "MuzzleSocket"
        else ((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z)
    )
    bpy.context.view_layer.update()

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB")

    report = {
        "weapon": args.weapon,
        "length_before": before,
        "length_after": round((hi - lo).z, 4),
        "target_length": target,
        "scale": round(scale, 5),
        "grip_along_axis": grip_t,
        "origin_offset": [round(v, 4) for v in origin],
        "triangles_before": tris_before,
        "triangles_after": tris_after,
        "socket": socket_name,
        "out": args.out,
    }
    print("###REPORT###" + json.dumps(report, ensure_ascii=False))
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
