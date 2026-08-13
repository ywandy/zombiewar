extends SceneTree

const MAP_SELECTION_SCENE_PATH := "res://scenes/menu/MapSelection.tscn"
const CHARACTER_SELECTION_SCENE_PATH := "res://scenes/menu/LocalMultiplayerLobby.tscn"
const DEMO_MAP_SCENE_PATH := "res://scenes/maps/demo/DemoMap.tscn"

var failures: Array[String] = []
var scene_change_count := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var session = root.get_node("GameSession")
	session.begin_map_selection(GameSessionState.Mode.SINGLE)
	var scene := load(MAP_SELECTION_SCENE_PATH) as PackedScene
	_check("map selection scene loads", scene != null)
	if scene == null:
		_finish()
		return
	var selection := scene.instantiate()
	root.add_child(selection)
	current_scene = selection
	await process_frame
	selection.tree_exiting.connect(_on_selection_tree_exiting)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	selection._unhandled_input(enter)
	_check("Enter is marked handled before the old scene leaves the tree", root.is_input_handled())
	await process_frame
	await process_frame
	await process_frame
	_check("Enter changes scene exactly once", scene_change_count == 1)
	_check("Enter launches character selection", current_scene != null)
	var character_selection = current_scene
	if character_selection != null:
		_check(
			"character selection is running",
			character_selection.scene_file_path == CHARACTER_SELECTION_SCENE_PATH
		)
		character_selection._handle_key(enter)
		await process_frame
		await process_frame
		await process_frame
	_check("character confirmation changes scene once", scene_change_count == 1)
	_check("character confirmation launches the selected demo map", current_scene != null)
	if current_scene != null:
		_check("selected demo map is running", current_scene.scene_file_path == DEMO_MAP_SCENE_PATH)
		_check("gameplay spawns one player", current_scene.get_node_or_null("Players/P1") != null)
	_check("gameplay startup reports no session error", String(session.last_error).is_empty())
	_finish()

func _on_selection_tree_exiting() -> void:
	scene_change_count += 1

func _finish() -> void:
	if failures.is_empty():
		print("validate_enter_game_start: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
