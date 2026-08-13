extends SceneTree

const MENU_BACKDROP_SCENE_PATH := "res://scenes/menu/MenuBackdrop.tscn"
const PLAYER_VISUAL_SCENE_PATH := "res://scenes/player/PlayerVisual.tscn"
const OLD_PLAYER_MODEL_PATH := "res://assets/characters/Characters_Lis_SingleWeapon.gltf"

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
		_check(
			"menu backdrop uses the reusable decoupled player visual",
			player_hero.scene_file_path == PLAYER_VISUAL_SCENE_PATH
		)
		var socket := player_hero.find_child("WeaponSocket.L", true, false) as Node3D
		_check("menu player exposes the corrected WeaponSocket.L", socket != null)
		if socket != null:
			_check(
				"corrected socket follows a hand bone attachment",
				socket.get_parent() is BoneAttachment3D
			)
		var smg := player_hero.find_child("SMGVisual", true, false) as Node3D
		_check("menu player shows an independently bound SMG", smg != null and smg.visible)
		_check(
			"menu SMG is parented to the corrected hand socket",
			socket != null and smg != null and smg.get_parent() == socket
		)
	_check(
		"old merged player model has been deleted",
		not FileAccess.file_exists(OLD_PLAYER_MODEL_PATH)
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
