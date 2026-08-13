extends SceneTree

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const PROBE_SCENE := preload("res://tools/fixtures/character_model_probe.tscn")
const LocalPlayerSpawnerScript := preload(
	"res://scripts/gameplay/local_player_spawner.gd"
)
const LocalPlayerDescriptorScript := preload(
	"res://scripts/input/local_player_descriptor.gd"
)
const PlayerInputSourceScript := preload(
	"res://scripts/input/player_input_source.gd"
)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	await _test_missing_model_is_not_replaced_by_fallback(failures)
	await _test_unknown_character_id_rejects_spawn(failures)
	await _test_valid_model_installs_before_equipment(failures)
	_finish(failures)

func _test_missing_model_is_not_replaced_by_fallback(
	failures: Array[String]
) -> void:
	var player := PLAYER_SCENE.instantiate() as PlayerController
	_expect(player != null, "Player.tscn must instantiate without a definition", failures)
	if player == null:
		return
	player.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(player)
	await process_frame
	var host := player.get_node_or_null("VisualRoot") as Node3D
	var current_model := host.get("current_model") as Node3D if host != null else null
	_expect(
		current_model == null,
		"a missing character model must not install the legacy fallback",
		failures
	)
	var equipment := player.get_node_or_null("EquipmentController")
	_expect(
		equipment != null and equipment.get_children().is_empty(),
		"a player without a character model must stop before equipment setup",
		failures
	)
	player.queue_free()
	await process_frame

func _test_unknown_character_id_rejects_spawn(failures: Array[String]) -> void:
	var session := root.get_node_or_null("GameSession")
	_expect(session != null, "GameSession autoload must exist", failures)
	if session == null:
		return
	var descriptor := LocalPlayerDescriptorScript.new()
	descriptor.character_id = &"missing_character"
	session.configure_single(descriptor)

	var camera := Camera3D.new()
	camera.current = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 20.0
	camera.position = Vector3(0.0, 10.0, 10.0)
	root.add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)
	var container := Node3D.new()
	root.add_child(container)
	var marker := Marker3D.new()
	container.add_child(marker)
	var spawner := LocalPlayerSpawnerScript.new()
	root.add_child(spawner)
	await process_frame

	var players := spawner.spawn_players(
		container,
		[marker],
		null,
		PlayerInputSourceScript.new()
	)
	_expect(
		players.is_empty(),
		"an unknown character id must reject the whole spawn",
		failures
	)
	_expect(
		session.last_error.contains("missing_character"),
		"spawn rejection must identify the unknown character id",
		failures
	)

	spawner.queue_free()
	container.queue_free()
	camera.queue_free()
	session.clear()
	await process_frame

func _test_valid_model_installs_before_equipment(failures: Array[String]) -> void:
	var player := PLAYER_SCENE.instantiate() as PlayerController
	_expect(player != null, "Player.tscn must instantiate", failures)
	if player == null:
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
