extends SceneTree

const TEAM_STATE_PATH := "res://scripts/gameplay/local_team_state.gd"
const PlayerScene := preload("res://scenes/player/Player.tscn")
const PlayerFixture := preload("res://tools/validation/support/player_fixture.gd")
const SinglePlayerInputSourceScript = preload("res://scripts/input/single_player_input_source.gd")
const TouchInputSourceScript = preload("res://scripts/input/touch_input_source.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(TEAM_STATE_PATH), "LocalTeamState script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	var players: Array[PlayerController] = []
	for index in range(4):
		var player = PlayerScene.instantiate() as PlayerController
		player.player_index = index
		PlayerFixture.apply_default_character(player)
		root.add_child(player)
		player.set_physics_process(false)
		players.append(player)
	var team = load(TEAM_STATE_PATH).new()
	root.add_child(team)
	var defeat_count := [0]
	team.all_players_defeated.connect(func() -> void: defeat_count[0] += 1)
	team.setup(players)

	players[0].defeated = true
	players[0].died.emit()
	_expect(not team.is_all_defeated(), "one defeated player must not end a four-player run", failures)
	_expect(defeat_count[0] == 0, "partial defeat must not emit all_players_defeated", failures)
	for index in range(1, 4):
		players[index].defeated = true
		players[index].died.emit()
	_expect(team.is_all_defeated(), "last defeated player must end the run", failures)
	_expect(defeat_count[0] == 1, "all_players_defeated must emit exactly once", failures)
	players[3].died.emit()
	_expect(defeat_count[0] == 1, "duplicate death signals must not repeat team defeat", failures)

	players[1].last_input_state.confirm_just_pressed = true
	_expect(not team.sample_restart_requested(), "P2 confirm must not restart local multiplayer", failures)
	players[1].last_input_state.confirm_just_pressed = false
	players[0].last_input_state.confirm_just_pressed = true
	_expect(team.sample_restart_requested(), "P1 confirm must restart after team defeat", failures)

	var single_player = PlayerScene.instantiate() as PlayerController
	PlayerFixture.apply_default_character(single_player)
	root.add_child(single_player)
	single_player.set_physics_process(false)
	single_player.defeated = true
	var single_source = SinglePlayerInputSourceScript.new()
	var touch_source = TouchInputSourceScript.new()
	single_source.set_touch_source(touch_source)
	single_player.set_input_source(single_source)
	touch_source.set_game_over_active(true)
	touch_source.set_use_pressed(true)
	single_player._physics_process(0.016)
	var single_team = load(TEAM_STATE_PATH).new()
	root.add_child(single_team)
	var single_players: Array[PlayerController] = [single_player]
	single_team.setup(single_players)
	_expect(single_team.sample_restart_requested(), "single-player touch Use must confirm restart during game over", failures)

	for player in players:
		player.queue_free()
	single_player.queue_free()
	team.queue_free()
	single_team.queue_free()
	camera.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_team_state: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
