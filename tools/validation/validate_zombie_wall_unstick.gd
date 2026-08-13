extends SceneTree

## 复现「贴墙死角卡死」（方案综述里的模式①）。
##
## 场景：玩家在开阔处，玩家正下方紧贴一道开口朝 +Z 的 U 型墙。一只僵尸从玩家的
## -Z 方向、墙体中轴线上追过来。旧实现里流场每格只存**坡度最陡的单个量化方向**，
## 死角正上方的 cell 方向几乎直指玩家、正对墙面；碰撞 `resolve_blocker()` 又是纯径向
## 推离、不提供任何切向滑动。两者叠加，僵尸被顶在墙面上原地抖，绕不出开口。
##
## 判定：给僵尸远超其绕墙所需的 tick 数。修复后它应能绕进 U 型开口、与玩家会合
## （剩余距离压到 attack_range 内）；旧实现则停在墙外 > 2.5 格。这是一个**集成**自测，
## 跑真实 SimWorld，而不是只断言某个中间量。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_zombie_wall_unstick.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_round_thin_wall(failures)
	_check_player_backed_to_wall(failures)
	_finish(failures)

## 场景一：玩家在开阔处，一面薄墙挡在僵尸与玩家之间，僵尸须从墙端绕行。
## 这是基础「隔墙绕路」，验证平滑流场 + 绕行不会在途中卡死。
func _check_round_thin_wall(failures: Array[String]) -> void:
	var world := _make_world()
	var player_pos := Vector2(0.0, 0.0)
	world.set_player_snapshot(0, player_pos, true, true)
	# 薄墙：一格厚，从玩家东侧 x=+0.5 延伸到 x=+8.5，僵尸必须从 +X 端绕行。
	world.get_grid().set_blocked_world_rect(
		Vector2(0.5, 0.5), Vector2(8.5, 1.5), true
	)
	var zombie_index := world.index_of_zombie(
		world.spawn_zombie(Vector2(4.0, 4.0), 0.0, 0)
	)
	_assert_reaches_player(world, zombie_index, player_pos, "round-thin-wall", failures)

## 场景二：玩家背贴一面横贯场地的长墙（玩家头顶也被压住），僵尸从正对面追。
## 旧实现里僵尸在 DIRECT_CHASE_RANGE 内**无视视线**直冲，贴到墙上后被纯径向推离
## 顶住，前进与推离抵消、又不查流场——永久死锁在墙外。修复后僵尸发现视线被挡会
## 落回流场，绕到墙端。这是模式②的死锁回归护栏。
func _check_player_backed_to_wall(failures: Array[String]) -> void:
	var world := _make_world()
	var player_pos := Vector2(0.0, 0.0)
	world.set_player_snapshot(0, player_pos, true, true)
	# 长墙：横贯场地宽，一格厚，紧贴玩家南侧，玩家头顶（x=0）也在墙正上方。
	world.get_grid().set_blocked_world_rect(
		Vector2(-10.5, 0.5), Vector2(10.5, 1.5), true
	)
	var zombie_index := world.index_of_zombie(
		world.spawn_zombie(Vector2(0.0, 4.0), 0.0, 0)
	)
	_assert_reaches_player(world, zombie_index, player_pos, "player-backed-to-wall", failures)

func _make_world() -> SimWorld:
	var world := SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260813)
	world.configure_zombie_profile(0, 50, 1.0)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)
	return world

func _assert_reaches_player(
	world: SimWorld,
	zombie_index: int,
	player_pos: Vector2,
	label: String,
	failures: Array[String]
) -> void:
	var tick_limit := 800  # 16 秒：绕一道横贯场地的长墙需要 ~21 格路程，留足余量。
	# 通过阈值取攻击圈：僵尸必须真的贴身到能攻击玩家，才算「绕过墙」。这能区分
	# 「直线撞墙死锁」（旧实现，停在墙外 > 1.9）与「绕行收拢」（修复后）。
	var reach_distance := SimWorldScript.ZOMBIE_ATTACK_RANGE
	var ticks := 0
	var final_distance := INF
	while ticks < tick_limit:
		world.step_tick()
		ticks += 1
		if world.get_zombie_count() > 0:
			final_distance = (
				world.get_zombie_position(zombie_index).distance_to(player_pos)
			)
			if final_distance <= reach_distance:
				break
	print(
		"%s: ticks=%d final_distance=%.3f reach_distance=%.2f"
		% [label, ticks, final_distance, reach_distance]
	)
	if world.get_zombie_count() == 0:
		failures.append("%s: zombie died or despawned" % label)
	elif final_distance > reach_distance:
		failures.append(
			(
				"%s: zombie never got off the wall (final_distance=%.3f): "
				+ "it is pinned against the wall instead of steering around"
			)
			% [label, final_distance]
		)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_wall_unstick: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
