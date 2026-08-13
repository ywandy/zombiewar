extends SceneTree

const SCENE_PATH := "res://scenes/menu/MapSelection.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load(SCENE_PATH) as PackedScene
	_expect(scene != null, "map selection scene loads", failures)
	if scene == null:
		_finish(failures)
		return
	var selection = scene.instantiate()
	root.add_child(selection)
	await process_frame
	for node_path in [
		"MenuLayer/Root/Cover",
		"MenuLayer/Root/MapName",
		"MenuLayer/Root/Description",
		"MenuLayer/Root/PositionLabel",
		"MenuLayer/Root/Actions/PreviousButton",
		"MenuLayer/Root/Actions/ConfirmButton",
		"MenuLayer/Root/Actions/NextButton",
		"MenuLayer/Root/BackButton",
		"MenuLayer/Root/ErrorLabel",
	]:
		_expect(selection.get_node_or_null(node_path) != null, "node %s" % node_path, failures)
	_expect(selection.state.entries.size() >= 1, "catalog entries loaded", failures)
	_expect(selection.state.selected_entry().map_id == &"demo", "demo initial selection", failures)
	_expect(
		not String(
			(selection.get_node("MenuLayer/Root/MapName") as Label).text
		).is_empty(),
		"font coverage copy present",
		failures
	)
	var source := FileAccess.get_file_as_string("res://scripts/menu/map_selection.gd")
	_expect(
		source.contains("change_scene_to_file(LOCAL_LOBBY_PATH)"),
		"both local modes must continue from map selection to the character lobby",
		failures
	)
	_expect(
		not source.contains("GameSession.configure_single()"),
		"map selection must not configure single gameplay before character choice",
		failures
	)
	selection.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_selection_scene: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
