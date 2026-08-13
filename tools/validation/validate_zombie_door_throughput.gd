extends SceneTree

## 门口拥挤护栏（方案③）。背景：方案③调查阶段，用三档应力场景都**无法复现**
## 「尸群挤门口谁也不动」的拥挤死锁——分离推挤（`SimCollision.accumulate_separation`
## + `resolve_blocker`）是收敛的，尸群只是排队通过窄门，最后一只也能穿过。
##
## 因此这里不修产品代码（不为复现不了的 bug 写修复），而是把应力场景固化成回归
## 护栏：若哪天改动分离/推挤/流场逻辑引入了真死锁（最后一只僵尸永远卡在门外），
## 这道护栏会立刻红。
##
## 判定：30 只僵尸挤过一道居中单格门（对称夹击、最易挤死的情形），所有僵尸必须
## 在宽裕的 tick 上限内全部穿到门的另一侧。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_zombie_door_throughput.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []

	var world := SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260813)
	world.configure_zombie_profile(0, 50, 1.0)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)
	# 玩家在门北侧。
	var player_pos := Vector2(0.0, -3.0)
	world.set_player_snapshot(0, player_pos, true, true)
	# 横墙 z=0 行，缺口 cell(24,19)（x=-0.5..+0.5），正压尸群中轴线：对称夹击。
	world.get_grid().set_blocked_world_rect(Vector2(-10.5, -0.5), Vector2(-0.5, 0.5), true)
	world.get_grid().set_blocked_world_rect(Vector2(0.5, -0.5), Vector2(10.5, 0.5), true)
	# 30 只僵尸在门南侧密集排成 5 行 6 列。
	var indices: Array[int] = []
	for row in range(5):
		for col in range(6):
			var x := -2.5 + float(col) * 1.0
			var z := 3.0 + float(row) * 1.0
			indices.append(world.index_of_zombie(world.spawn_zombie(Vector2(x, z), 0.0, 0)))

	var crossed_at := {}
	for idx in indices:
		crossed_at[idx] = -1
	var tick_limit := 1200  # 24 秒：排队过单格门的宽裕上限（实测最后一只 ~t=640）。
	for t in range(tick_limit):
		world.step_tick()
		for idx in indices:
			if crossed_at[idx] >= 0 or world.get_zombie_count() <= idx:
				continue
			if world.get_zombie_position(idx).y < -0.5:
				crossed_at[idx] = t

	var crossed := 0
	var last_cross := -1
	var stuck: Array[int] = []
	for idx in indices:
		if crossed_at[idx] >= 0:
			crossed += 1
			last_cross = maxi(last_cross, crossed_at[idx])
		else:
			stuck.append(idx)
	print(
		"door-throughput: %d/%d crossed, last at t=%d (limit %d)"
		% [crossed, indices.size(), last_cross, tick_limit]
	)
	if not stuck.is_empty():
		failures.append(
			"door-throughput: %d zombie(s) never crossed the single-width door %s — "
			+ "congestion deadlock: separation/push no longer lets the crowd file through"
			% [stuck.size(), stuck]
		)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_door_throughput: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
