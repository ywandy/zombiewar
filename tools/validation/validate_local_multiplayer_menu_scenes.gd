extends SceneTree

const MenuFlowScript = preload("res://scripts/menu/menu_flow.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var single_flow = MenuFlowScript.new()
	_expect(single_flow.has_method("request_single"), "MenuFlow must expose request_single", failures)
	if single_flow.has_method("request_single"):
		_expect(single_flow.request_single(), "ready flow must accept single-player start", failures)
		_expect(not single_flow.request_single(), "starting flow must reject duplicate single-player start", failures)
	var local_flow = MenuFlowScript.new()
	_expect(local_flow.has_method("request_local"), "MenuFlow must expose request_local", failures)
	if local_flow.has_method("request_local"):
		_expect(local_flow.request_local(), "ready flow must accept local multiplayer start", failures)
		_expect(not local_flow.request_local(), "starting flow must reject duplicate local start", failures)

	var main_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_expect(main_scene != null, "MainMenu scene must load", failures)
	if main_scene != null:
		var main = main_scene.instantiate()
		var start_button := main.get_node_or_null("UILayer/StartButton") as Button
		var local_button := main.get_node_or_null("UILayer/LeftRail/LocalButton") as Button
		var online_button := main.get_node_or_null("UILayer/LeftRail/OnlineButton") as Button
		var leaderboard_button := main.get_node_or_null("UILayer/RightRail/LeaderboardButton") as Button
		_expect(start_button != null, "MainMenu must contain StartButton", failures)
		_expect(local_button != null, "MainMenu must contain LocalButton", failures)
		_expect(online_button != null, "MainMenu must contain OnlineButton", failures)
		_expect(leaderboard_button != null, "MainMenu must contain LeaderboardButton", failures)
		# 焦点链必须是一条不断的链：手柄用户只有方向键，链上少一环就等于
		# 那个按钮在手柄下不可达。逐段断言而不是只测两端。
		var focus_chain: Array = [local_button, online_button]
		var chain_is_complete := true
		for button in focus_chain:
			if button == null:
				chain_is_complete = false
		if chain_is_complete:
			for index in range(focus_chain.size() - 1):
				var upper: Button = focus_chain[index]
				var lower: Button = focus_chain[index + 1]
				_expect(
					upper.focus_neighbor_bottom == upper.get_path_to(lower),
					"%s focus must move down to %s" % [upper.name, lower.name],
					failures
				)
				_expect(
					lower.focus_neighbor_top == lower.get_path_to(upper),
					"%s focus must move up to %s" % [lower.name, upper.name],
					failures
				)
		main.free()

	var map_selection_scene := load("res://scenes/menu/MapSelection.tscn") as PackedScene
	_expect(map_selection_scene != null, "MapSelection scene must load", failures)
	if map_selection_scene != null:
		var map_selection = map_selection_scene.instantiate()
		_expect(
			map_selection.has_method("_on_confirm_button_pressed"),
			"MapSelection must expose a confirmation flow",
			failures
		)
		var map_selection_source := FileAccess.get_file_as_string(
			"res://scripts/menu/map_selection.gd"
		)
		_expect(
			map_selection_source.contains("LOCAL_LOBBY_PATH") and
			map_selection_source.contains("GameSession.map_selection_mode"),
			"MapSelection must route local multiplayer to the device join lobby",
			failures
		)
		map_selection.free()

	var lobby_scene := load("res://scenes/menu/LocalMultiplayerLobby.tscn") as PackedScene
	_expect(lobby_scene != null, "LocalMultiplayerLobby scene must load", failures)
	if lobby_scene != null:
		var lobby = lobby_scene.instantiate()
		_expect(lobby.get("join_state") != null, "lobby must own a join state", failures)
		for player_number in range(1, 5):
			_expect(lobby.get_node_or_null("LobbyWorld/Slots/P%d" % player_number) is Marker3D, "lobby must contain world slot P%d" % player_number, failures)
			_expect(lobby.get_node_or_null("MenuLayer/StatusRoot/P%dStatus" % player_number) is Label, "lobby must contain status label P%d" % player_number, failures)
		_expect(lobby.get_node_or_null("MenuLayer/P1Hint") is Label, "lobby must contain fixed P1 operation hint", failures)
		lobby.free()

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_multiplayer_menu_scenes: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
