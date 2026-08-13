extends SceneTree

## 攻击弧护栏（方案②）。断言两件事：
##
##  1. **贴身隔障必须能打到**：玩家贴障（油桶 / 墙角）时，僵尸绕行贴身后必须在
##     合理 tick 内落地伤害。业界 swarm 的贴身攻击不靠理想视线——这条护栏锁住
##     「绕到贴身就能攻击」，防止哪天 `attack_path_clear` 被改回苛刻判定而围而不攻。
##
##  2. **实心密封必须打不到**：玩家被实心墙四面围死时，僵尸绝不能穿墙攻击。
##     任何对攻击判定的放宽都不得退化成「隔墙打人」。
##
## 背景：方案①（平滑流场 + 视线遮挡落回流场绕行）已让多数贴身几何能正常攻击，
## 本自测把它固化成回归护栏，而不是复现一个仍失败的 bug。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_zombie_attack_arc.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	# 贴身隔障 → 必须打到。
	_expect_can_hit("barrel-south", func(w):
		w.spawn_barrel(Vector2(0, 1.2), 0.0, Vector2(-0.45, 0.75), Vector2(0.45, 1.65), 3, 1, 0.12, 2.0, 50.0, 20.0)
		return Vector2(0.0, 5.0), failures)
	_expect_can_hit("player-corner-pocket", func(w):
		w.get_grid().set_blocked_world_rect(Vector2(-1.5, -1.5), Vector2(-0.5, 0.5), true)
		w.get_grid().set_blocked_world_rect(Vector2(-1.5, -1.5), Vector2(0.5, -0.5), true)
		return Vector2(4.0, 4.0), failures)
	_expect_can_hit("barrel-flank", func(w):
		w.spawn_barrel(Vector2(1.2, 0), 0.0, Vector2(0.75, -0.45), Vector2(1.65, 0.45), 3, 1, 0.12, 2.0, 50.0, 20.0)
		return Vector2(5.0, 0.0), failures)
	# 实心密封 → 必须打不到。
	_expect_cannot_hit("sealed-pocket", func(w):
		w.get_grid().set_blocked_world_rect(Vector2(-2.5, 0.5), Vector2(2.5, 2.5), true)
		w.get_grid().set_blocked_world_rect(Vector2(-2.5, -2.5), Vector2(-0.5, 0.5), true)
		w.get_grid().set_blocked_world_rect(Vector2(0.5, -2.5), Vector2(2.5, 0.5), true)
		w.get_grid().set_blocked_world_rect(Vector2(-2.5, -2.5), Vector2(2.5, -1.5), true)
		return Vector2(0.0, 6.0), failures)
	_finish(failures)

func _expect_can_hit(label: String, build: Callable, failures: Array[String]) -> void:
	var result := _scenario(build, 600)
	print(
		"%-22s final_d=%5.2f hits=%d sawATTACK=%s (must hit)"
		% [label, result["final_d"], result["hits"], result["saw_attack"]]
	)
	if result["hits"] <= 0:
		failures.append(
			"%s: zombie pressed against the obstacle but never landed a hit "
			+ "(final_d=%.2f, sawATTACK=%s): melee attack is starved by over-strict gating"
			% [label, result["final_d"], result["saw_attack"]]
		)

func _expect_cannot_hit(label: String, build: Callable, failures: Array[String]) -> void:
	var result := _scenario(build, 400)
	print(
		"%-22s final_d=%5.2f hits=%d (must NOT hit)"
		% [label, result["final_d"], result["hits"]]
	)
	if result["hits"] > 0:
		failures.append(
			"%s: zombie landed a hit on a player sealed behind solid walls — "
			+ "attack relaxation must not become wall-piercing" % label
		)

func _scenario(build: Callable, tick_limit: int) -> Dictionary:
	var world := SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260813)
	world.configure_zombie_profile(0, 50, 1.0)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)
	var player_pos := Vector2(0.0, 0.0)
	world.set_player_snapshot(0, player_pos, true, true)
	var zombie_spawn: Vector2 = build.call(world)
	var zombie_index := world.index_of_zombie(world.spawn_zombie(zombie_spawn, 0.0, 0))
	var hits := 0
	var saw_attack := false
	for _t in range(tick_limit):
		world.step_tick()
		if world.get_zombie_count() == 0:
			break
		if int(world.zombie_state[zombie_index]) == ZombieBehaviorMathScript.State.ATTACK:
			saw_attack = true
		for event in world.tick_player_damage_events:
			if event.get("kind", StringName()) == &"zombie_hit":
				hits += 1
	var final_d := (
		world.get_zombie_position(zombie_index).distance_to(player_pos)
		if world.get_zombie_count() > 0 else -1.0
	)
	return {"final_d": final_d, "hits": hits, "saw_attack": saw_attack}

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_attack_arc: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
