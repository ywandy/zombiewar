extends SceneTree

const REGISTRY_PATH := "res://scripts/gameplay/player_registry.gd"
const SELECTOR_PATH := "res://scripts/combat/zombie_target_selector.gd"
const PlayerScene := preload("res://scenes/player/Player.tscn")
const PlayerFixture := preload("res://tools/validation/support/player_fixture.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(REGISTRY_PATH), "PlayerRegistry script must exist", failures)
	_expect(ResourceLoader.exists(SELECTOR_PATH), "ZombieTargetSelector script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return
	var selector = load(SELECTOR_PATH)
	var registry = load(REGISTRY_PATH).new()
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	root.add_child(registry)
	var near_player = _player_at(Vector3(3.0, 0.0, 0.0))
	var far_player = _player_at(Vector3(8.0, 0.0, 0.0))
	var outside_player = _player_at(Vector3(12.0, 0.0, 0.0))
	registry.register_player(near_player)
	registry.register_player(far_player)
	registry.register_player(outside_player)
	registry.register_player(near_player)
	_expect(registry.get_players().size() == 3, "registry must reject duplicate players", failures)
	var selected = selector.select_target(Vector3.ZERO, null, registry.get_players(), 10.0, 0.5)
	_expect(selected == near_player, "selector must choose the nearest living player", failures)
	near_player.defeated = true
	selected = selector.select_target(Vector3.ZERO, null, registry.get_players(), 10.0, 0.5)
	_expect(selected == far_player, "selector must exclude defeated players and out-of-range players", failures)

	var offline_player = _player_at(Vector3(2.0, 0.0, 0.0))
	offline_player.set_input_source(null)
	var offline_candidates: Array[PlayerController] = [offline_player]
	selected = selector.select_target(Vector3.ZERO, null, offline_candidates, 10.0, 0.5)
	_expect(selected == offline_player, "offline but living players must remain valid zombie targets", failures)

	var current = _player_at(Vector3(5.0, 0.0, 0.0))
	var barely_closer = _player_at(Vector3(4.9, 0.0, 0.0))
	var close_candidates: Array[PlayerController] = [current, barely_closer]
	selected = selector.select_target(Vector3.ZERO, current, close_candidates, 10.0, 0.5)
	_expect(selected == current, "target only 0.1 closer must not overcome switch margin", failures)
	var clearly_closer = _player_at(Vector3(4.4, 0.0, 0.0))
	var switch_candidates: Array[PlayerController] = [current, clearly_closer]
	selected = selector.select_target(Vector3.ZERO, current, switch_candidates, 10.0, 0.5)
	_expect(selected == clearly_closer, "target 0.6 closer must overcome switch margin", failures)

	for player in [near_player, far_player, outside_player, offline_player, current, barely_closer, clearly_closer]:
		player.free()
	registry.queue_free()
	camera.queue_free()
	await process_frame
	_finish(failures)

func _player_at(position: Vector3):
	var player = PlayerScene.instantiate()
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	player.set_physics_process(false)
	player.position = position
	return player

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_target_selector: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
