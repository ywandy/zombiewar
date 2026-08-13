@tool
extends SceneTree

## 校验 v7 生成的十个角色模型在 Godot 侧真正可用。
##
## Blender 侧达标不等于 Godot 侧可用：GLTF 导入器对骨骼命名、动画名和材质的处理
## 与 Blender 不同，必须在引擎里实测。这里逐个实例化并断言骨架、动画名、面数与
## 朝向，任何一项不满足就退出码 1。

const CHARACTER_IDS := [
	&"male_gunner", &"female_gunner",
	&"male_assault", &"female_assault",
	&"male_medic", &"female_medic",
	&"male_demolition", &"female_demolition",
	&"male_riot", &"female_riot",
]

## 玩家骨架的 20 个动画，缺一个都会让对应玩法表现失效。
const REQUIRED_ACTIONS := [
	"Death", "Duck", "HitReact", "Idle", "Idle_Gun", "Jump", "Jump_Idle", "Jump_Land",
	"No", "Punch", "Run", "Run_Gun", "Run_Slash", "Run_Stab", "Slash", "Stab",
	"Walk", "Walk_Gun", "Wave", "Yes",
]

const EXPECTED_BONES := 43
const TRIANGLE_BUDGET := 30000


func _init() -> void:
	var failures: PackedStringArray = []

	for id in CHARACTER_IDS:
		var path := "res://assets/characters/generated/%s.glb" % id
		if not ResourceLoader.exists(path):
			failures.append("%s: 模型文件不存在 %s" % [id, path])
			continue

		var packed := load(path) as PackedScene
		if packed == null:
			failures.append("%s: 无法作为 PackedScene 加载" % id)
			continue

		var root := packed.instantiate()
		if root == null:
			failures.append("%s: 实例化失败" % id)
			continue

		var skeleton := _find_skeleton(root)
		if skeleton == null:
			failures.append("%s: 没有 Skeleton3D" % id)
		elif skeleton.get_bone_count() != EXPECTED_BONES:
			failures.append("%s: 骨骼数 %d，期望 %d" % [id, skeleton.get_bone_count(), EXPECTED_BONES])

		var player := _find_animation_player(root)
		if player == null:
			failures.append("%s: 没有 AnimationPlayer" % id)
		else:
			var present := player.get_animation_list()
			for action in REQUIRED_ACTIONS:
				if not present.has(action):
					failures.append("%s: 缺少动画 %s" % [id, action])

		var tris := _count_triangles(root)
		if tris > TRIANGLE_BUDGET:
			failures.append("%s: 三角面 %d 超预算 %d" % [id, tris, TRIANGLE_BUDGET])

		var mesh := _find_mesh(root)
		if mesh == null:
			failures.append("%s: 没有 MeshInstance3D" % id)
		else:
			# 骨架与它的 20 个动画面朝 -Z（Godot 前向）。模型朝向错了，游戏里角色会
			# 背对移动方向，而这在静态截图上看不出来。
			var aabb := mesh.get_aabb()
			if aabb.size.x < aabb.size.z:
				failures.append("%s: 朝向可疑，AABB 宽 %.2f 小于厚 %.2f，T-pose 下臂展应是最宽轴"
					% [id, aabb.size.x, aabb.size.z])

		root.free()

	if failures.is_empty():
		print("validate_generated_character_models: 通过，%d 个角色" % CHARACTER_IDS.size())
		quit(0)
		return

	for line in failures:
		printerr(line)
	printerr("validate_generated_character_models: 失败 %d 项" % failures.size())
	quit(1)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _count_triangles(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
				if indices != null and indices.size() > 0:
					total += indices.size() / 3
				else:
					var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
					if verts != null:
						total += verts.size() / 3
	for child in node.get_children():
		total += _count_triangles(child)
	return total
