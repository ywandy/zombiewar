extends Control

const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

@export_file("*.tscn") var map_selection_scene_path := \
	"res://scenes/menu/MapSelection.tscn"
@export_file("*.tscn") var online_lobby_scene_path := "res://scenes/menu/OnlineLobby.tscn"
@export_file("*.tscn") var leaderboard_scene_path := "res://scenes/menu/LeaderboardPanel.tscn"

@onready var start_button: Button = %StartButton
@onready var local_button: Button = %LocalButton
@onready var online_button: Button = %OnlineButton
@onready var leaderboard_button: Button = %LeaderboardButton
@onready var codex_button: Button = %CodexButton
@onready var upgrade_button: Button = %UpgradeButton
@onready var settings_button: Button = %SettingsButton
@onready var material_value: Label = %MaterialValue
@onready var hero_tex: TextureRect = %HeroTex
@onready var toast_label: Label = %ToastLabel
@onready var exit_dialog: Control = %ExitDialog
@onready var confirm_exit_button: Button = %ConfirmExitButton
@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var select_audio: AudioStreamPlayer = $SelectAudio
@onready var confirm_audio: AudioStreamPlayer = $ConfirmAudio
@onready var back_audio: AudioStreamPlayer = $BackAudio

var flow := MenuFlow.new()
var _toast_tween: Tween = null

func _ready() -> void:
	_refresh_material()
	start_button.grab_focus()
	MenuEntrance.play(self, _entrance_elements(), 0)
	_breathe_hero()

func _entrance_elements() -> Array:
	return [
		material_value, codex_button, upgrade_button, settings_button,
		local_button, online_button, leaderboard_button,
		hero_tex, start_button,
	]

func _refresh_material() -> void:
	var meta := get_node_or_null("/root/MetaProgression")
	material_value.text = str(meta.get_banked_material() if meta != null else 0)

## 主角轻微上下浮动，让静态画面不至于死板。
func _breathe_hero() -> void:
	var base := hero_tex.position.y
	var t := create_tween().set_loops()
	t.tween_property(hero_tex, "position:y", base - 8.0, 1.8) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(hero_tex, "position:y", base, 1.8) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## 占位入口：图鉴/升级/设置尚未实现，点击提示「敬请期待」。
func _show_toast(message: String) -> void:
	toast_label.text = message
	toast_label.modulate.a = 0.0
	toast_label.show()
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_label, "modulate:a", 1.0, 0.15)
	_toast_tween.tween_interval(1.2)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.4)

# ---- 导航 ----

func _on_start_button_pressed() -> void:
	if not flow.request_single():
		return
	GameSession.begin_map_selection(GameSessionState.Mode.SINGLE)
	_start_transition(map_selection_scene_path)

func _on_local_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)
	_start_transition(map_selection_scene_path)

func _on_online_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.clear()
	_start_transition(online_lobby_scene_path)

func _on_leaderboard_button_pressed() -> void:
	if flow.state != MenuFlow.State.READY:
		return
	confirm_audio.play()
	get_tree().change_scene_to_file(leaderboard_scene_path)

func _on_codex_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("图鉴 · 敬请期待")

func _on_upgrade_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("升级 · 敬请期待")

func _on_settings_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("设置 · 敬请期待")

func _start_transition(scene_path: String) -> void:
	confirm_audio.play()
	start_button.disabled = true
	local_button.disabled = true
	online_button.disabled = true
	leaderboard_button.disabled = true
	var tween := create_tween()
	tween.tween_property(fade_overlay, "color:a", 1.0, 0.32)
	await tween.finished
	get_tree().change_scene_to_file(scene_path)

# ---- 退出 ----

func _on_quit_requested() -> void:
	if not flow.request_exit():
		return
	confirm_audio.play()
	exit_dialog.show()
	confirm_exit_button.grab_focus()

func _on_confirm_exit_button_pressed() -> void:
	if flow.confirm_exit():
		get_tree().quit()

func _on_cancel_exit_button_pressed() -> void:
	if not flow.cancel_exit():
		return
	back_audio.play()
	exit_dialog.hide()

func _unhandled_input(event: InputEvent) -> void:
	var joy_button := event as InputEventJoypadButton
	var joy_a := joy_button != null and joy_button.pressed and \
		joy_button.button_index == JOY_BUTTON_A
	var joy_b := joy_button != null and joy_button.pressed and \
		joy_button.button_index == JOY_BUTTON_B
	if (event.is_action_pressed("ui_cancel") or joy_b) and \
			flow.state == MenuFlow.State.EXIT_CONFIRM:
		_on_cancel_exit_button_pressed()
		get_viewport().set_input_as_handled()
	elif joy_a and _activate_focused_button():
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and flow.state == MenuFlow.State.READY:
		_on_quit_requested()
		get_viewport().set_input_as_handled()

func _activate_focused_button() -> bool:
	var focused_button := get_viewport().gui_get_focus_owner() as Button
	if focused_button == null or focused_button.disabled:
		return false
	focused_button.pressed.emit()
	return true

func _on_action_focused() -> void:
	if not select_audio.playing:
		select_audio.play()
