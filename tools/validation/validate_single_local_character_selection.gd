extends SceneTree

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const LocalPlayerDescriptorScript = preload("res://scripts/input/local_player_descriptor.gd")
const SELECTION_STATE_PATH := "res://scripts/menu/local_character_selection_state.gd"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(
		ResourceLoader.exists(SELECTION_STATE_PATH),
		"LocalCharacterSelectionState script must exist",
		failures
	)
	if not failures.is_empty():
		_finish(failures)
		return

	var selection_script = load(SELECTION_STATE_PATH)
	var catalog = ContentCatalogsScript.characters()
	var selection = selection_script.new(catalog)
	selection.initialize_single()
	_expect(selection.players.size() == 1, "single creates exactly P1", failures)
	_expect(
		selection.players[0].character_id == catalog.default_id(),
		"single gets default character",
		failures
	)

	selection.clear()
	_expect(
		selection.try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD) == 0,
		"WASD joins P1",
		failures
	)
	_expect(
		selection.try_join(LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS) == 1,
		"arrows join P2",
		failures
	)
	_expect(
		selection.find_player_index(
			LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS
		) == 1,
		"source lookup resolves its own seat",
		failures
	)
	selection.step_player(0, 1)
	_expect(
		selection.players[0].character_id != catalog.default_id(),
		"P1 cycles",
		failures
	)
	_expect(
		selection.players[1].character_id == catalog.default_id(),
		"P2 remains unchanged",
		failures
	)
	selection.players[1].character_id = selection.players[0].character_id
	_expect(selection.selection_error() == "", "duplicate choices are valid", failures)
	selection.players[1].character_id = &"missing_character"
	_expect(selection.selection_error() != "", "unknown character blocks start", failures)

	var session := root.get_node_or_null("GameSession")
	var lobby_scene := load("res://scenes/menu/LocalMultiplayerLobby.tscn") as PackedScene
	_expect(session != null, "GameSession autoload must exist", failures)
	_expect(lobby_scene != null, "unified character lobby must load", failures)
	if session != null and lobby_scene != null:
		session.begin_map_selection(session.Mode.SINGLE)
		var single_lobby = lobby_scene.instantiate()
		root.add_child(single_lobby)
		await process_frame
		_expect(single_lobby.is_single_mode, "single mode uses unified lobby", failures)
		_expect(
			single_lobby.selection_state.players.size() == 1,
			"single lobby auto-creates P1",
			failures
		)
		_expect(
			not single_lobby.get_node("LobbyWorld/Slots/P2").visible,
			"single lobby hides P2-P4",
			failures
		)
		single_lobby.queue_free()
		await process_frame

		session.begin_map_selection(session.Mode.LOCAL_MULTIPLAYER)
		var local_lobby = lobby_scene.instantiate()
		root.add_child(local_lobby)
		await process_frame
		_expect(not local_lobby.is_single_mode, "local mode keeps join lobby", failures)
		_expect(
			local_lobby.selection_state.players.is_empty(),
			"local lobby starts with empty seats",
			failures
		)
		_expect(
			local_lobby.get_node("LobbyWorld/Slots/P2").visible,
			"local lobby shows all four slots",
			failures
		)
		var a_down := InputEventKey.new()
		a_down.physical_keycode = KEY_A
		a_down.pressed = true
		local_lobby._handle_key(a_down)
		_expect(
			local_lobby.selection_state.players.size() == 1,
			"first A joins WASD",
			failures
		)
		_expect(
			local_lobby.selection_state.players[0].character_id == catalog.default_id(),
			"join event does not also cycle",
			failures
		)
		local_lobby._handle_key(a_down)
		_expect(
			local_lobby.selection_state.players[0].character_id ==
				catalog.next_id(catalog.default_id(), -1),
			"joined WASD A cycles only P1",
			failures
		)
		var right_down := InputEventKey.new()
		right_down.physical_keycode = KEY_RIGHT
		right_down.pressed = true
		local_lobby._handle_key(right_down)
		_expect(
			local_lobby.selection_state.players.size() == 2 and
				local_lobby.selection_state.players[1].character_id == catalog.default_id(),
			"first Right joins arrows without cycling",
			failures
		)
		var before_p1: StringName = local_lobby.selection_state.players[0].character_id
		var unassigned_rb := InputEventJoypadButton.new()
		unassigned_rb.device = 7
		unassigned_rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
		unassigned_rb.pressed = true
		local_lobby._handle_joypad_button(unassigned_rb)
		_expect(
			local_lobby.selection_state.players[0].character_id == before_p1,
			"unassigned gamepad cannot mutate keyboard seat",
			failures
		)
		var echo_d := InputEventKey.new()
		echo_d.physical_keycode = KEY_D
		echo_d.pressed = true
		echo_d.echo = true
		local_lobby._handle_key(echo_d)
		_expect(
			local_lobby.selection_state.players[0].character_id == before_p1,
			"keyboard echo does not cycle",
			failures
		)
		local_lobby.queue_free()
		await process_frame
		session.clear()

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_single_local_character_selection: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
