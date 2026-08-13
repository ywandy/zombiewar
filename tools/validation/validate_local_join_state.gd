extends SceneTree

const DESCRIPTOR_PATH := "res://scripts/input/local_player_descriptor.gd"
const JOIN_STATE_PATH := "res://scripts/menu/local_player_join_state.gd"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(DESCRIPTOR_PATH), "LocalPlayerDescriptor script must exist", failures)
	_expect(ResourceLoader.exists(JOIN_STATE_PATH), "LocalPlayerJoinState script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var descriptor_script = load(DESCRIPTOR_PATH)
	var join_state_script = load(JOIN_STATE_PATH)
	var join_state = join_state_script.new()
	var kinds = descriptor_script.SourceKind
	_expect(join_state.try_join(kinds.KEYBOARD_ARROWS) == 0, "first source must join P1", failures)
	_expect(join_state.try_join(kinds.GAMEPAD, 2) == 1, "second source must join P2", failures)
	_expect(join_state.try_join(kinds.KEYBOARD_WASD) == 2, "third source must join P3", failures)
	_expect(join_state.find_player_index(kinds.KEYBOARD_ARROWS) == 0, "source lookup must find keyboard seat", failures)
	_expect(join_state.find_player_index(kinds.GAMEPAD, 2) == 1, "source lookup must match gamepad device id", failures)
	_expect(join_state.find_player_index(kinds.GAMEPAD, 9) == -1, "unknown gamepad must not resolve another seat", failures)
	_expect(join_state.try_join(kinds.GAMEPAD, 2) == -1, "duplicate gamepad id must be rejected", failures)
	_expect(join_state.try_join(kinds.GAMEPAD, 3) == 3, "fourth source must join P4", failures)
	_expect(join_state.try_join(kinds.GAMEPAD, 4) == -1, "fifth source must be rejected", failures)
	_expect(join_state.players.size() == 4, "join state must cap players at four", failures)
	for index in range(join_state.players.size()):
		_expect(join_state.players[index].player_index == index, "player descriptors must retain their slot index", failures)

	join_state.set_gamepad_online(2, false)
	_expect(not join_state.players[1].online, "disconnect must mark the matching gamepad offline", failures)
	_expect(join_state.players.size() == 4, "disconnect must preserve the occupied slot", failures)
	join_state.set_gamepad_online(2, true)
	_expect(join_state.players[1].online, "same gamepad id must restore online state", failures)

	join_state.clear()
	_expect(join_state.players.is_empty(), "clear must remove every joined player", failures)
	_expect(join_state.try_join(kinds.KEYBOARD_WASD) == 0, "joining after clear must restart at P1", failures)

	var invalid_kind = descriptor_script.new()
	invalid_kind.source_kind = 999
	_expect(invalid_kind.create_input_source() == null, "invalid source kind must not create input", failures)
	var invalid_gamepad = descriptor_script.new()
	invalid_gamepad.source_kind = kinds.GAMEPAD
	invalid_gamepad.gamepad_device_id = -1
	_expect(invalid_gamepad.create_input_source() == null, "negative gamepad id must not create input", failures)

	var session := root.get_node_or_null("GameSession")
	_expect(session != null, "GameSession autoload must exist", failures)
	if session != null:
		session.configure_local(join_state.players)
		_expect(session.local_players.size() == 1, "local session must copy joined descriptors", failures)
		join_state.clear()
		_expect(session.local_players.size() == 1, "session must not alias mutable join state", failures)
		session.clear()
		_expect(session.local_players.is_empty(), "clear must reset local session players", failures)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_join_state: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
