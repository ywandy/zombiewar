extends SceneTree

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const PROBE_SCENE := preload("res://tools/fixtures/character_model_probe.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	_expect(player != null, "Player.tscn must instantiate", failures)
	if player == null:
		_finish(failures)
		return

	var definition := CharacterDefinition.new()
	definition.model_scene = PROBE_SCENE
	player.apply_character_definition(definition)
	# 夹具只验证初始化顺序，不需要推进移动与动画状态机。
	player.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(player)
	await process_frame
	await process_frame

	var host := player.get_node_or_null("VisualRoot") as Node3D
	_expect(host != null, "VisualRoot must exist", failures)
	var current_model := host.get("current_model") as Node3D if host != null else null
	_expect(
		current_model != null,
		"model_scene must install before equipment setup",
		failures
	)
	if current_model != null:
		_expect(
			current_model.name == "CharacterModel",
			"installed model has stable name",
			failures
		)
		_expect(
			current_model.get_node_or_null("WeaponHandSocket") != null,
			"socket survives install",
			failures
		)
	_expect(
		player.animation_player != null,
		"animation lookup runs against installed model",
		failures
	)

	player.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_character_model_switching: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_character_model_switching: %s" % failure)
	printerr("validate_character_model_switching: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
