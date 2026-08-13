extends SceneTree

## Brotato 对比自测：跑 5 波，输出每波的材料/伤害/击杀，验证成长曲线是否"滚雪球"。
##
## Brotato 的爽感核心是复利成长（每波自动变强 + 材料滚雪球）。这个脚本用真实
## 模拟层跑 5 波，输出每波的量化指标，直接对标 Brotato 的成长形态。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/selftest_brotato_curve.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== Brotato 对比：5 波成长曲线 ===")
	print("波次 | 击杀 | 累计材料 | 伤害倍率 | 材料/击杀")
	print("----|------|---------|---------|----------")

	var world := SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260807)
	world.configure_zombie_profile(0, 50, 1.0)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)
	world.configure_zombie_death_groups(0, [
		{
			"group_id": &"common_drop",
			"trigger_chance_per_10000": 6000,
			"events": [
				{"event_type": 1, "weight": 3, "material_drop_min": 8, "material_drop_max": 12},
				{"event_type": 1, "weight": 2, "material_drop_min": 13, "material_drop_max": 18},
			],
		},
	])
	world.configure_weapon_profile(0, 35.0, 24.0, 0.35, 3.0, 0.8, 1.8, 0, 0.0, 1)
	world.set_player_snapshot(0, Vector2.ZERO, true, true)

	# 5 波递增（demo_map 的节奏）
	var waves: Array[Dictionary] = []
	for w in range(5):
		waves.append({
			"spawn_interval_ticks": maxi(10 - w, 4),
			"entries": [{"profile_index": 0, "count": 12 + w * 8, "spawn_point_index": 0}],
		})
	world.configure_wave_schedule(
		waves,
		[{"spawn_id": &"c", "position": Vector2(0.0, -8.0), "radius": 4.0, "spacing": 0.9}],
		1, 300, 300
	)
	world.start_wave_schedule()

	var total_kills := 0
	var current_wave := 0
	var wave_kills := 0
	var ticks := 0

	while current_wave < 5 and ticks < 6000:
		world.step_tick()
		ticks += 1
		# 玩家每 3 tick 开火
		if ticks % 3 == 0 and world.get_zombie_count() > 0:
			var target_pos := world.get_zombie_position(0)
			var aim := (target_pos - Vector2.ZERO).normalized()
			if aim.length_squared() < 0.5:
				aim = Vector2(0.0, -1.0)
			world.queue_fire_event(0, 0, Vector2.ZERO, 1.0, aim)
		wave_kills += world.tick_death_events.size()
		# 波间：买最便宜的升级（伤害）
		for ev in world.tick_wave_events:
			if ev.get("kind", StringName()) == &"intermission_started":
				var material := world.get_player_material(0)
				if material >= 12:
					world.queue_shop_purchase(0, &"stat", SimWorldScript.STAT_DAMAGE, 1.12, 12)
					world.step_tick()
				# 输出本波数据
				var mat := world.get_player_material(0)
				var dmg := world.get_upgrade_scale(0, SimWorldScript.STAT_DAMAGE)
				var per_kill := float(mat) / maxf(float(total_kills + wave_kills), 1.0)
				print("%4d | %4d | %8d | %7.2f | %8.1f" % [
					current_wave + 1, wave_kills, mat, dmg, per_kill
				])
				total_kills += wave_kills
				wave_kills = 0
				current_wave += 1

	print("=== 自测完成 ===")
	quit(0)
