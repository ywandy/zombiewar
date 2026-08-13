extends SceneTree

const PLAYER_SCENE_PATH := "res://scenes/player/Player.tscn"
const PLAYER_VISUAL_SCENE_PATH := "res://scenes/player/PlayerVisual.tscn"
const CHARACTER_MODEL_PATH := "res://assets/characters/decoupled/Lis_WeaponSocket_L.gltf"
const SOCKET_NAME := "WeaponSocket.L"
const WEAPON_MODEL_PATHS := {
	"pistol": "res://assets/weapons/decoupled/Pistol/Pistol.gltf",
	"smg": "res://assets/weapons/decoupled/SMG/SMG.gltf",
	"shotgun": "res://assets/weapons/decoupled/Shotgun/Shotgun.gltf",
	"rifle": "res://assets/weapons/decoupled/Rifle/Rifle.gltf",
	"knife": "res://assets/weapons/decoupled/Knife/Knife.gltf",
}
const DEFINITION_PATHS := {
	"pistol": "res://resources/weapons/pistol.tres",
	"smg": "res://resources/weapons/smg.tres",
	"shotgun": "res://resources/weapons/shotgun.tres",
	"rifle": "res://resources/weapons/rifle.tres",
	"knife": "res://resources/weapons/knife.tres",
}

var failures: Array[String] = []

func _init() -> void:
	for path in [PLAYER_SCENE_PATH, PLAYER_VISUAL_SCENE_PATH, CHARACTER_MODEL_PATH]:
		_check("resource exists: %s" % path, ResourceLoader.exists(path))
	for weapon_id in WEAPON_MODEL_PATHS:
		var model_path: String = WEAPON_MODEL_PATHS[weapon_id]
		var definition_path: String = DEFINITION_PATHS[weapon_id]
		_check("%s model exists" % weapon_id, ResourceLoader.exists(model_path))
		var definition := load(definition_path) as WeaponDefinition
		_check("%s definition loads" % weapon_id, definition != null)
		if definition == null:
			continue
		_check("%s uses WeaponSocket.L" % weapon_id, definition.visual_socket_name == StringName(SOCKET_NAME))
		_check("%s model scene is assigned" % weapon_id, definition.visual_model_scene != null)
		_check("%s model path matches definition" % weapon_id, definition.visual_model_scene.resource_path == model_path)
	var player_scene := load(PLAYER_SCENE_PATH) as PackedScene
	if player_scene != null:
		var player := player_scene.instantiate()
		root.add_child(player)
		await process_frame
		await process_frame
		var socket := player.find_child(SOCKET_NAME, true, false)
		if socket == null:
			socket = player.find_child(SOCKET_NAME.replace(".", "_"), true, false)
		_check("runtime player exposes WeaponSocket.L", socket != null)
		var equipment := player.get_node_or_null("EquipmentController")
		_check("runtime player exposes EquipmentController", equipment != null)
		if equipment != null:
			for weapon_id in WEAPON_MODEL_PATHS:
				var item = equipment.get_item_by_id(StringName(weapon_id))
				_check("runtime item exists: %s" % weapon_id, item != null)
				if item != null:
					_check("runtime visual bound: %s" % weapon_id, item.visual_anchor != null)
		player.queue_free()
	if failures.is_empty():
		print("validate_decoupled_player_binding: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
