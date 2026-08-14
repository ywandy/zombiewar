@tool
extends SceneTree

## 校验六个生成僵尸模型在 Godot 侧可用。
##
## 写这个脚本的直接原因：绑定脚本此前取「第一个带顶点组的网格」当参考身体，僵尸
## 骨架里 Eyelid（146 顶点的眼皮）也带权重，于是整只僵尸被按眼皮的包围盒缩小约
## 11 倍，权重落到面部骨上，动画里手臂完全不动。渲染因为按模型自身包围盒自动
## 取景，反而看不出来。尺寸断言就是为了挡住这类"看起来正常"的错误。

const ZOMBIE_IDS := [
	&"zombie_normal_civilian", &"zombie_normal_worker", &"zombie_normal_police",
	&"zombie_runner", &"zombie_tank", &"zombie_exploder",
]
const REQUIRED_ACTIONS := [
	"Crawl", "Death", "HitReact", "Idle", "Idle_Attack", "Jump", "Jump_Idle",
	"Jump_Land", "No", "Punch", "Run", "Run_Arms", "Run_Attack", "Walk", "Wave", "Yes",
]
const EXPECTED_BONES := 50
const TRIANGLE_BUDGET := 16000
## 参照骨架自带 Zombie 网格的高度 1.362。低于下限说明尺度对齐取错了参考网格。
const MIN_HEIGHT := 0.9
const MAX_HEIGHT := 2.2


func _init() -> void:
	var failures: PackedStringArray = []
	for id in ZOMBIE_IDS:
		var path := "res://assets/enemies/generated/%s.glb" % id
		if not ResourceLoader.exists(path):
			failures.append("%s: 模型不存在" % id)
			continue
		var packed := load(path) as PackedScene
		if packed == null:
			failures.append("%s: 无法作为 PackedScene 加载" % id)
			continue
		var root := packed.instantiate()

		var skeleton := root.find_children("*", "Skeleton3D", true, false)
		if skeleton.is_empty():
			failures.append("%s: 没有 Skeleton3D" % id)
		elif (skeleton[0] as Skeleton3D).get_bone_count() != EXPECTED_BONES:
			failures.append("%s: 骨骼数 %d，期望 %d"
				% [id, (skeleton[0] as Skeleton3D).get_bone_count(), EXPECTED_BONES])

		var player := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if player == null:
			failures.append("%s: 没有 AnimationPlayer" % id)
		else:
			for action in REQUIRED_ACTIONS:
				if not player.has_animation(action):
					failures.append("%s: 缺少动画 %s" % [id, action])

		var total := 0
		var height := 0.0
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := node as MeshInstance3D
			if mesh_instance.mesh == null:
				continue
			height = maxf(height, mesh_instance.get_aabb().size.y)
			for surface in mesh_instance.mesh.get_surface_count():
				var arrays := mesh_instance.mesh.surface_get_arrays(surface)
				var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
				total += indices.size() / 3 if indices.size() > 0 else 0
		if total > TRIANGLE_BUDGET:
			failures.append("%s: 三角面 %d 超预算 %d" % [id, total, TRIANGLE_BUDGET])
		if height < MIN_HEIGHT or height > MAX_HEIGHT:
			failures.append("%s: 高度 %.3f 不在 [%.1f, %.1f]，尺度对齐可能取错了参考网格"
				% [id, height, MIN_HEIGHT, MAX_HEIGHT])

		root.free()

	if failures.is_empty():
		print("validate_generated_zombie_models: 通过，%d 个僵尸" % ZOMBIE_IDS.size())
		quit(0)
		return
	for line in failures:
		printerr(line)
	printerr("validate_generated_zombie_models: 失败 %d 项" % failures.size())
	quit(1)
