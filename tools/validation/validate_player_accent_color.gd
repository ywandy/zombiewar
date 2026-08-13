extends SceneTree

## 场上角色配色的校验。
##
## 四个人共用同一个模型，脚下光环是场上唯一分得清谁是谁的东西。
## 它必须是纯展示件：不带碰撞、不进物理层——多一个碰撞体就会被
## 玩家生成时的空位探测撞上，四个人会挤不进出生点。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_player_accent_color.gd

const PLAYER_SCENE_PATH := "res://scenes/player/Player.tscn"
const PlayerFixture := preload("res://tools/validation/support/player_fixture.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	var player = scene.instantiate()
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	await process_frame

	var ring := player.get_node_or_null("AccentRing") as MeshInstance3D
	_expect(ring != null, "Player 必须有 AccentRing 节点", failures)
	if ring == null:
		player.queue_free()
		await process_frame
		_finish(failures)
		return

	_expect(
		ring.find_children("*", "CollisionShape3D", true, false).is_empty(),
		"光环不能带碰撞体——出生点空位探测会撞上它",
		failures
	)
	_expect(
		ring.material_override is StandardMaterial3D,
		"光环必须有自己的材质，否则四个玩家会共用同一份颜色",
		failures
	)

	var accent := Color(0.243, 0.553, 0.925, 1.0)
	player.set_accent_color(accent)
	var material := ring.material_override as StandardMaterial3D
	_expect(
		material.albedo_color.is_equal_approx(accent),
		"配色必须落到光环材质上",
		failures
	)
	_expect(
		material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"光环必须是 unshaded，否则夜间场景里看不出颜色",
		failures
	)

	# 第二个玩家换色不能把第一个的颜色一起改掉——材质必须是每实例一份。
	var other = scene.instantiate()
	PlayerFixture.apply_default_character(other)
	root.add_child(other)
	await process_frame
	other.set_accent_color(Color(0.906, 0.263, 0.212, 1.0))
	_expect(
		material.albedo_color.is_equal_approx(accent),
		"两个玩家必须各有一份光环材质",
		failures
	)

	player.queue_free()
	other.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_player_accent_color: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_player_accent_color: %s" % failure)
	printerr("validate_player_accent_color: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
