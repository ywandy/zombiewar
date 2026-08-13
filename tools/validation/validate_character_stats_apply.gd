extends SceneTree

## 验证角色三围能正确应用到 PlayerController。
##
## spawner 在 add_child（触发 _ready）之前调 apply_character_definition，
## 此时 health 仍为 null——本脚本复现这个时序：先 apply（health=null 分支），
## 再触发 _ready（_ensure_health_initialized 用新 max_health 建 Health），
## 最后断言 max_health / move_speed / health.current 符合角色数据。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_character_stats_apply.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.characters()
	_expect(catalog != null, "角色目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return

	# 防爆（male_riot）：生命 +40 → 140，移速 ×0.8 → 4.0
	var riot = catalog.get_by_id(&"male_riot")
	_expect(riot != null, "male_riot 必须存在于目录", failures)
	if riot != null:
		_check_player(riot, 140.0, 4.0, "防爆", failures)

	# 医疗（male_medic）：生命 -15 → 85，移速 ×1.05 → 5.25
	var medic = catalog.get_by_id(&"male_medic")
	_expect(medic != null, "male_medic 必须存在于目录", failures)
	if medic != null:
		_check_player(medic, 85.0, 5.25, "医疗", failures)

	# 突击（male_assault）：生命 +0 → 100，移速 ×0.92 → 4.6
	var assault = catalog.get_by_id(&"male_assault")
	_expect(assault != null, "male_assault 必须存在于目录", failures)
	if assault != null:
		_check_player(assault, 100.0, 4.6, "突击", failures)

	# 防爆减伤：防爆角色 apply_damage(100) 只掉 70%（100×0.7），剩 130/140。
	_check_blast_armor(catalog, failures)

	_finish(failures)

## 防爆甲：passive_strength=0.3 时，100 点伤害被减到 70，140 血剩 70。
func _check_blast_armor(catalog, failures: Array[String]) -> void:
	var riot = catalog.get_by_id(&"male_riot")
	if riot == null:
		_expect(false, "防爆减伤：male_riot 不存在", failures)
		return
	var player := PLAYER_SCENE.instantiate()
	player.apply_character_definition(riot)
	root.add_child(player)
	var before: float = player.health.current
	player.apply_damage(100.0, Vector3.ZERO)
	var expected: float = before - 100.0 * (1.0 - 0.3)
	_expect(
		is_equal_approx(player.health.current, expected),
		"防爆减伤：health.current 应为 %f，实际 %f" % [
			expected, player.health.current
		],
		failures
	)
	player.queue_free()

	# 对照：无 blast_armor 的角色吃满 100。
	var assault = catalog.get_by_id(&"male_assault")
	var control := PLAYER_SCENE.instantiate()
	control.apply_character_definition(assault)
	root.add_child(control)
	var control_before: float = control.health.current
	control.apply_damage(100.0, Vector3.ZERO)
	var control_expected: float = control_before - 100.0
	_expect(
		is_equal_approx(control.health.current, control_expected),
		"对照减伤：无防爆角色应掉满 100，实际掉 %f" % [
			control_before - control.health.current
		],
		failures
	)
	control.queue_free()

func _check_player(
	def: CharacterDefinition,
	expected_health: float,
	expected_speed: float,
	label: String,
	failures: Array[String]
) -> void:
	var player := PLAYER_SCENE.instantiate()
	_expect(player != null, "%s：Player.tscn 实例化失败" % label, failures)
	if player == null:
		return
	# 复现 spawner 时序：add_child（_ready）之前 apply。
	player.apply_character_definition(def)
	_expect(
		is_equal_approx(player.max_health, expected_health),
		"%s：apply 后 max_health 应为 %f，实际 %f" % [
			label, expected_health, player.max_health
		],
		failures
	)
	_expect(
		is_equal_approx(player.move_speed, expected_speed),
		"%s：apply 后 move_speed 应为 %f，实际 %f" % [
			label, expected_speed, player.move_speed
		],
		failures
	)
	# 触发 _ready：_ensure_health_initialized 用新 max_health 建 Health。
	root.add_child(player)
	_expect(
		player.health != null,
		"%s：_ready 后 health 必须已初始化" % label,
		failures
	)
	if player.health != null:
		_expect(
			is_equal_approx(player.health.maximum, expected_health),
			"%s：health.maximum 应为 %f，实际 %f" % [
				label, expected_health, player.health.maximum
			],
			failures
		)
		_expect(
			is_equal_approx(player.health.current, expected_health),
			"%s：health.current 应为满值 %f，实际 %f" % [
				label, expected_health, player.health.current
			],
			failures
		)
	player.queue_free()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_character_stats_apply: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_character_stats_apply: %s" % failure)
	printerr("validate_character_stats_apply: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
