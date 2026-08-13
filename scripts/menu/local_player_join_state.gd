extends RefCounted
class_name LocalPlayerJoinState

const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)
const MAX_PLAYERS := 4

var players: Array = []

func try_join(source_kind: int, device_id: int = -1) -> int:
	if players.size() >= MAX_PLAYERS:
		return -1
	if not _is_valid_source(source_kind, device_id):
		return -1
	if find_player_index(source_kind, device_id) >= 0:
		return -1
	var descriptor = LocalPlayerDescriptorScript.new()
	descriptor.player_index = players.size()
	descriptor.source_kind = source_kind
	descriptor.gamepad_device_id = device_id
	descriptor.online = true
	players.append(descriptor)
	return descriptor.player_index

func find_player_index(source_kind: int, device_id: int = -1) -> int:
	for index in range(players.size()):
		var player = players[index]
		if player.source_kind != source_kind:
			continue
		if (
			source_kind != LocalPlayerDescriptorScript.SourceKind.GAMEPAD or
			player.gamepad_device_id == device_id
		):
			return index
	return -1

func set_gamepad_online(device_id: int, online: bool) -> void:
	for player in players:
		if (
			player.source_kind == LocalPlayerDescriptorScript.SourceKind.GAMEPAD and
			player.gamepad_device_id == device_id
		):
			player.online = online
			return

func clear() -> void:
	players.clear()

func _is_valid_source(source_kind: int, device_id: int) -> bool:
	match source_kind:
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD, LocalPlayerDescriptorScript.SourceKind.KEYBOARD_ARROWS:
			return true
		LocalPlayerDescriptorScript.SourceKind.GAMEPAD:
			return device_id >= 0
		_:
			return false
