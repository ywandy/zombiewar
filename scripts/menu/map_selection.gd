extends Node3D
class_name MapSelection

const CATALOG_PATH := "res://resources/maps/catalogs/map_catalog.tres"
const MAIN_MENU_PATH := "res://scenes/menu/MainMenu.tscn"
const LOCAL_LOBBY_PATH := "res://scenes/menu/LocalMultiplayerLobby.tscn"
const PLACEHOLDER_COVER := preload("res://assets/ui/map_cover_placeholder.svg")

var state := MapSelectionState.new()

@onready var cover: TextureRect = %Cover
@onready var map_name: Label = %MapName
@onready var description: Label = %Description
@onready var position_label: Label = %PositionLabel
@onready var previous_button: Button = %PreviousButton
@onready var confirm_button: Button = %ConfirmButton
@onready var next_button: Button = %NextButton
@onready var error_label: Label = %ErrorLabel

func _ready() -> void:
	var catalog := load(CATALOG_PATH) as MapCatalog
	state.set_catalog(catalog)
	_refresh_selection()
	confirm_button.grab_focus()

func _refresh_selection() -> void:
	if state.entries.is_empty():
		cover.texture = PLACEHOLDER_COVER
		map_name.text = "地图目录为空"
		description.text = ""
		position_label.text = "0 / 0"
		previous_button.disabled = true
		confirm_button.disabled = true
		next_button.disabled = true
		error_label.hide()
		return

	var entry := state.selected_entry()
	cover.texture = entry.cover if entry.cover != null else PLACEHOLDER_COVER
	map_name.text = entry.display_name
	description.text = entry.description
	position_label.text = "%d / %d" % [state.selected_index + 1, state.entries.size()]
	previous_button.disabled = false
	next_button.disabled = false
	var scene_is_missing := entry.entry_scene == null
	confirm_button.disabled = scene_is_missing
	error_label.visible = scene_is_missing

func _select_previous() -> void:
	if state.entries.is_empty():
		return
	state.move_selection(-1)
	_refresh_selection()

func _select_next() -> void:
	if state.entries.is_empty():
		return
	state.move_selection(1)
	_refresh_selection()

func _on_confirm_button_pressed() -> void:
	var scene_path := state.selected_scene_path()
	if scene_path.is_empty():
		error_label.show()
		return
	GameSession.select_map_scene(scene_path)
	get_tree().change_scene_to_file(LOCAL_LOBBY_PATH)

func _on_back_button_pressed() -> void:
	GameSession.clear()
	get_tree().change_scene_to_file(MAIN_MENU_PATH)

func _on_previous_button_pressed() -> void:
	_select_previous()

func _on_next_button_pressed() -> void:
	_select_next()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed("ui_left"):
		_select_previous()
	elif event.is_action_pressed("ui_right"):
		_select_next()
	elif event.is_action_pressed("ui_accept") or _is_joy_button_pressed(event, JOY_BUTTON_A):
		_on_confirm_button_pressed()
	elif event.is_action_pressed("ui_cancel") or _is_joy_button_pressed(event, JOY_BUTTON_B):
		_on_back_button_pressed()
	else:
		return
	get_viewport().set_input_as_handled()

func _is_joy_button_pressed(event: InputEvent, button: JoyButton) -> bool:
	var joy_button := event as InputEventJoypadButton
	return joy_button != null and joy_button.pressed and joy_button.button_index == button
