"""检查 Tripo 重建产物是否够格进装配：面数、分件、贴图、尺度。

    /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
        --python tools/assets/inspect_tripo_glb.py -- <glb> [<glb> ...]

重建结果有三种典型废品，都要在装配前挡掉：
- 分件粘连成一坨：kit 的各部件本该是分离的连通块，粘连后无法逐件对齐到骨骼；
- 面数超预算：角色 30000 三角面、武器 5000 三角面；
- 贴图没烘上：只有顶点色或纯白材质。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def connected_components(mesh: bpy.types.Mesh) -> int:
    """按顶点连通性数独立块。kit 的分件数应该和源图上的部件数大致对得上。"""
    parent = list(range(len(mesh.vertices)))

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for edge in mesh.edges:
        a, b = find(edge.vertices[0]), find(edge.vertices[1])
        if a != b:
            parent[a] = b
    return len({find(i) for i in range(len(mesh.vertices))})


def inspect(path: str) -> dict:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)

    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    tris = 0
    islands = 0
    for ob in meshes:
        ob.data.calc_loop_triangles()
        tris += len(ob.data.loop_triangles)
        islands += connected_components(ob.data)

    images = [i.name for i in bpy.data.images if i.size[0]]
    pts = [ob.matrix_world @ v.co for ob in meshes for v in ob.data.vertices]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))

    return {
        "file": Path(path).name,
        "meshes": len(meshes),
        "triangles": tris,
        "islands": islands,
        "textures": images,
        "materials": len(bpy.data.materials),
        "size": [round(v, 4) for v in (hi - lo)],
    }


def main() -> None:
    paths = sys.argv[sys.argv.index("--") + 1 :]
    results = [inspect(p) for p in paths]
    print("###JSON###" + json.dumps(results, ensure_ascii=False))


if __name__ == "__main__":
    main()
