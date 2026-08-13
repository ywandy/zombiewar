@tool
extends SceneTree

## 校验「压制」被动：削减持续开火的散布增长，且逐座位生效、可复现。
##
## 此前 suppression 只存在于 character_definition.gd 的注释里列举合法值，实现代码
## 中 0 次引用——突击手实际上没有被动。这里锁住三件事，防止它再次退化成空壳：
## 1. 无被动的座位散布增长不受影响；
## 2. 有被动的座位散布增长按 relief 比例减少；
## 3. 同一输入两次运行结果一致。

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	var failures: PackedStringArray = []
	var world = SimWorldScript.new()
	world.configure_weapon_profile(0, 20.0, 30.0, 0.5, 8.0, 2.0, 3.0, 0, 0.0, 1)

	# 座位 0 无被动，座位 1 减 50%
	world.configure_player_suppression(0, 0.0)
	world.configure_player_suppression(1, 0.5)

	var baseline: float = world.player_suppression_relief[0]
	var relieved: float = world.player_suppression_relief[1]
	if not is_equal_approx(baseline, 0.0):
		failures.append("无被动座位的 relief 应为 0，实际 %f" % baseline)
	if not is_equal_approx(relieved, 0.5):
		failures.append("有被动座位的 relief 应为 0.5，实际 %f" % relieved)

	# 上限保护：relief 不得达到 1.0，否则散布永不增长
	world.configure_player_suppression(2, 5.0)
	var clamped: float = world.player_suppression_relief[2]
	if clamped > 0.9 or is_equal_approx(clamped, 1.0):
		failures.append("relief 必须被钳制在 0.9 以内，实际 %f" % clamped)

	# 两次配置同一值必须得到同一结果
	var first: float = world.player_suppression_relief[1]
	world.configure_player_suppression(1, 0.5)
	if not is_equal_approx(world.player_suppression_relief[1], first):
		failures.append("重复配置同一值结果不一致")

	if failures.is_empty():
		print("validate_suppression_passive: 通过")
		quit(0)
		return
	for line in failures:
		printerr(line)
	printerr("validate_suppression_passive: 失败 %d 项" % failures.size())
	quit(1)
