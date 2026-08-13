extends Node
class_name GameSessionState

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)

enum Mode {
	SINGLE,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}

var mode := Mode.SINGLE
var local_players: Array = []
var last_error := ""
## 地图有两条并存的选择路径，服务不同的流程，不要合并成一个：
##
## - map_id：**联机**用。内容 id 由服务端的 start 消息下发，各端据此解析同一张图。
##   竞技场只读这个值、绝不自己挑图——各端各挑一张就是一次静默的分叉。
## - selected_map_scene_path：**本地**用（主菜单与本地多人的地图选择、地图编辑器）。
##   直接指向一个场景路径，不经过内容 id，因此只在单机路径上成立。
##
## 判据很简单：凡是会被别的客户端看见的选择，必须走 map_id。

## 本局要加载的地图。联机下由服务端的 start 消息决定；单机与本地多人取目录默认值。
var map_id: StringName = &""

var map_selection_mode := Mode.SINGLE
var selected_map_scene_path := ""

func begin_map_selection(target_mode: Mode) -> void:
	map_selection_mode = target_mode
	selected_map_scene_path = ""
	local_players.clear()
	last_error = ""

func select_map_scene(scene_path: String) -> void:
	selected_map_scene_path = scene_path

func selected_game_scene_path(fallback: String) -> String:
	return fallback if selected_map_scene_path.is_empty() else selected_map_scene_path

func configure_single(player = null) -> void:
	mode = Mode.SINGLE
	var resolved = player
	if resolved == null:
		resolved = LocalPlayerDescriptorScript.new()
		resolved.character_id = ContentCatalogsScript.characters().default_id()
	local_players = [resolved]
	map_id = ContentCatalogsScript.maps().default_id()
	last_error = ""

func configure_local(players: Array) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	map_id = ContentCatalogsScript.maps().default_id()
	last_error = ""

## 联机与本地多人共用同一份玩家名单：名单里的描述符决定每个座位的输入源，
## 而「输入从哪来」是联机唯一需要分叉的地方。
##
## 地图是第二个必须由外部传入的东西：它来自房间，不来自本机。
func configure_online(players: Array, selected_map_id: StringName) -> void:
	mode = Mode.ONLINE_MULTIPLAYER
	local_players = players.duplicate()
	map_id = selected_map_id
	last_error = ""

func clear() -> void:
	configure_single()
	local_players.clear()
	map_selection_mode = Mode.SINGLE
	selected_map_scene_path = ""
