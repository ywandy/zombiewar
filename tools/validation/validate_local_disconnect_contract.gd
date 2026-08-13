extends SceneTree

const GamepadInputSourceScript = preload("res://scripts/input/gamepad_input_source.gd")
const PlayerRegistryScript = preload("res://scripts/gameplay/player_registry.gd")
const ZombieTargetSelectorScript = preload("res://scripts/combat/zombie_target_selector.gd")
const PlayerScene = preload("res://scenes/player/Player.tscn")
const PlayerFixture = preload("res://tools/validation/support/player_fixture.gd")
const SmgScene = preload("res://scenes/weapons/Smg.tscn")
const KnifeScene = preload("res://scenes/weapons/Knife.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var disconnected_device_id := 999999
	var source = GamepadInputSourceScript.new(disconnected_device_id)
	_expect(source.has_method("get_device_id"), "gamepad input source must expose its retained device id", failures)
	if source.has_method("get_device_id"):
		_expect(source.get_device_id() == disconnected_device_id, "offline source must retain its original device id", failures)
	_expect(source.get_source_key() == StringName("gamepad_%d" % disconnected_device_id), "offline source key must retain device identity", failures)
	_expect(not source.is_online(), "unknown gamepad id must report offline", failures)
	var state = source.sample()
	_expect(state.move_vector == Vector2.ZERO, "offline gamepad movement must be zero", failures)
	_expect(not state.previous_equipment_just_pressed and not state.next_equipment_just_pressed, "offline gamepad equipment edges must be zero", failures)
	_expect(not state.use_pressed and not state.use_just_pressed and not state.confirm_just_pressed, "offline gamepad actions must be zero", failures)

	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	var registry = PlayerRegistryScript.new()
	root.add_child(registry)
	var player = PlayerScene.instantiate() as PlayerController
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	player.set_physics_process(false)
	player.set_input_source(source)
	registry.register_player(player)
	var selected = ZombieTargetSelectorScript.select_target(
		Vector3.ZERO,
		null,
		registry.get_players(),
		10.0,
		0.5
	)
	_expect(selected == player, "offline but living registered player must remain targetable", failures)
	_expect(registry.get_players().has(player), "disconnect must not release the player registry slot", failures)

	var smg = SmgScene.instantiate()
	var knife = KnifeScene.instantiate()
	_expect((smg.definition.hit_collision_mask & 2) == 0, "smg query must exclude player collision layer 2", failures)
	_expect((knife.definition.hit_collision_mask & 2) == 0, "melee weapon query must exclude player collision layer 2", failures)
	smg.free()
	knife.free()
	player.queue_free()
	registry.queue_free()
	camera.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_disconnect_contract: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
