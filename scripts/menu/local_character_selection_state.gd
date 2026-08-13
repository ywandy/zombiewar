extends RefCounted
class_name LocalCharacterSelectionState

const LocalPlayerJoinStateScript = preload(
	"res://scripts/menu/local_player_join_state.gd"
)

var catalog: CharacterCatalog
var join_state = LocalPlayerJoinStateScript.new()
var players: Array:
	get:
		return join_state.players

func _init(source_catalog: CharacterCatalog) -> void:
	catalog = source_catalog

func initialize_single() -> void:
	clear()
	try_join(LocalPlayerDescriptor.SourceKind.KEYBOARD_WASD)

func try_join(source_kind: int, device_id: int = -1) -> int:
	var player_index: int = join_state.try_join(source_kind, device_id)
	if player_index < 0:
		return -1
	join_state.players[player_index].character_id = (
		catalog.default_id() if catalog != null else &""
	)
	return player_index

func find_player_index(source_kind: int, device_id: int = -1) -> int:
	return join_state.find_player_index(source_kind, device_id)

func step_player(player_index: int, step: int) -> bool:
	if catalog == null or player_index < 0 or player_index >= players.size():
		return false
	var player = players[player_index]
	if not catalog.has_id(player.character_id):
		return false
	player.character_id = catalog.next_id(player.character_id, step)
	return true

func selection_error(require_all_online: bool = true) -> String:
	if catalog == null or String(catalog.default_id()).is_empty():
		return "没有可用角色"
	if players.is_empty():
		return "没有玩家"
	for index in range(players.size()):
		var player = players[index]
		if require_all_online and not player.online:
			return "玩家 P%d 设备离线" % (index + 1)
		if not catalog.has_id(player.character_id):
			return "玩家 P%d 的角色 %s 不存在" % [
				index + 1,
				String(player.character_id),
			]
	return ""

func set_gamepad_online(device_id: int, online: bool) -> void:
	join_state.set_gamepad_online(device_id, online)

func clear() -> void:
	join_state.clear()
