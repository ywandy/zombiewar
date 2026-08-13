extends SceneTree

const MENU_BACKDROP_SCENE_PATH := "res://scenes/menu/MenuBackdrop.tscn"
const DEFAULT_PLAYER_MODEL_PATH := "res://assets/characters/generated/male_assault.glb"

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := load(MENU_BACKDROP_SCENE_PATH) as PackedScene
	_check("MenuBackdrop scene loads", scene != null)
	if scene == null:
		_finish()
		return
	var backdrop := scene.instantiate()
	root.add_child(backdrop)
	await process_frame
	await process_frame
	var player_hero := backdrop.get_node_or_null("SetDressing/PlayerHero") as Node3D
	_check("menu backdrop exposes PlayerHero", player_hero != null)
	if player_hero != null:
		var character_model := player_hero.get_node_or_null("CharacterModel") as Node3D
		_check(
			"menu backdrop loads the default catalog character",
			character_model != null and
			character_model.scene_file_path == DEFAULT_PLAYER_MODEL_PATH
		)
		var socket := player_hero.find_child("WeaponHandSocket", true, false) as Node3D
		_check("menu player exposes WeaponHandSocket", socket != null)
		var smg := player_hero.find_child("mp5Visual", true, false) as Node3D
		_check("menu player shows an independently bound SMG", smg != null and smg.visible)
		_check(
			"menu SMG is parented to WeaponHandSocket",
			socket != null and smg != null and smg.get_parent() == socket
		)
	backdrop.queue_free()
	await process_frame
	_finish()

func _finish() -> void:
	if failures.is_empty():
		print("validate_menu_backdrop_player_binding: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
