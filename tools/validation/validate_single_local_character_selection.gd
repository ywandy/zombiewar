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
