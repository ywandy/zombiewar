@tool
extends SceneTree

## 校验爆破型僵尸：死亡入队爆炸、连锁不在同一 tick 递归、结果逐位可复现。
##
## 这是模拟层改动，联机不同步在本地测不出来，所以必须在这里锁住三件事：
## 1. 爆炸只在 explodes_on_death 的档案上触发，普通僵尸死亡不产生爆炸；
## 2. 爆炸走 pending_events，下一 tick 才结算——连锁引爆不会在本 tick 内递归；
## 3. 同一初始状态跑两遍，帧哈希序列完全一致。

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")

const NORMAL_PROFILE := 0
const EXPLODER_PROFILE := 1


func _init() -> void:
	var failures: PackedStringArray = []

	_check_normal_death_does_not_explode(failures)
	_check_exploder_death_explodes(failures)
	_check_chain_is_deferred(failures)
	_check_deterministic_replay(failures)

	if failures.is_empty():
		print("validate_zombie_exploder: 通过")
		quit(0)
		return
	for line in failures:
		printerr(line)
	printerr("validate_zombie_exploder: 失败 %d 项" % failures.size())
	quit(1)


func _make_world() -> Object:
	var world = SimWorldScript.new()
	world.configure_zombie_profile(NORMAL_PROFILE, 50, 1.0)
	world.configure_zombie_profile(EXPLODER_PROFILE, 30, 1.0, true, 4.0, 80.0, 25.0)
	return world


func _kill(world: Object, index: int) -> void:
	world.apply_zombie_damage(
		index,
		world.get_zombie_max_health(index),
		world.get_zombie_position(index),
		world.get_zombie_height(index),
		Vector2.RIGHT,
		&"body"
	)


func _check_normal_death_does_not_explode(failures: PackedStringArray) -> void:
	var world: Object = _make_world()
	world.spawn_zombie(Vector2.ZERO, 0.0, NORMAL_PROFILE)
	var before: int = world.pending_events.size()
	_kill(world, 0)
	var added: int = world.pending_events.size() - before
	var explosions := 0
	for event in world.pending_events:
		if event.get("kind") == &"explosion":
			explosions += 1
	if explosions != 0:
		failures.append("普通僵尸死亡不应产生爆炸，实际入队 %d 个（本次新增事件 %d）"
			% [explosions, added])


func _check_exploder_death_explodes(failures: PackedStringArray) -> void:
	var world: Object = _make_world()
	world.spawn_zombie(Vector2(2.0, 3.0), 0.0, EXPLODER_PROFILE)
	_kill(world, 0)
	var found := {}
	for event in world.pending_events:
		if event.get("kind") == &"explosion":
			found = event
			break
	if found.is_empty():
		failures.append("爆破僵尸死亡未入队爆炸事件")
		return
	if not is_equal_approx(float(found.get("radius", 0.0)), 4.0):
		failures.append("爆炸半径应为档案配置的 4.0，实际 %s" % found.get("radius"))
	if not is_equal_approx(float(found.get("center_damage", 0.0)), 80.0):
		failures.append("爆心伤害应为 80.0，实际 %s" % found.get("center_damage"))
	var origin: Vector2 = found.get("origin", Vector2.ZERO)
	if not origin.is_equal_approx(Vector2(2.0, 3.0)):
		failures.append("爆炸原点应为僵尸位置 (2,3)，实际 %s" % origin)


func _check_chain_is_deferred(failures: PackedStringArray) -> void:
	# 两只爆破僵尸挨在一起。第一只死亡时爆炸必须只入队一个事件，
	# 而不是在同一 tick 内递归引爆第二只——递归会让不同客户端的
	# 事件顺序发散，是最典型的不同步来源。
	var world: Object = _make_world()
	world.spawn_zombie(Vector2.ZERO, 0.0, EXPLODER_PROFILE)
	world.spawn_zombie(Vector2(0.5, 0.0), 0.0, EXPLODER_PROFILE)
	_kill(world, 0)
	var explosions := 0
	for event in world.pending_events:
		if event.get("kind") == &"explosion":
			explosions += 1
	if explosions != 1:
		failures.append("同一 tick 内应只入队 1 个爆炸事件，实际 %d 个（连锁必须延到下一 tick）"
			% explosions)


func _check_deterministic_replay(failures: PackedStringArray) -> void:
	var hashes: Array[PackedStringArray] = []
	for run in 2:
		var world: Object = _make_world()
		world.spawn_zombie(Vector2.ZERO, 0.0, EXPLODER_PROFILE)
		world.spawn_zombie(Vector2(1.0, 0.0), 0.0, EXPLODER_PROFILE)
		world.spawn_zombie(Vector2(2.5, 0.0), 0.0, NORMAL_PROFILE)
		_kill(world, 0)
		var seq: PackedStringArray = []
		for _tick in 12:
			world.step_tick()
			seq.append(SimHasherScript.hash_world(world))
		hashes.append(seq)
	if hashes[0] != hashes[1]:
		failures.append("同一初始状态两次运行的帧哈希序列不一致，存在非确定性")
