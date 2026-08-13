extends SceneTree

## 离屏渲染一张 InventoryPanel 截图，用来肉眼核对排版（不是自动化校验）。
## 用法：/Applications/Godot.app/Contents/MacOS/Godot --path . --script \
##   tools/validation/support/preview_inventory_panel.gd -- <输出绝对路径> [角色id] [分类序号]

const WARMUP_FRAMES := 30
const PANEL_SCENE := preload("res://scenes/ui/InventoryPanel.tscn")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const PROFILE_CATALOG := preload("res://resources/inventory/inventory_profiles.tres")
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

## 面板从场景树里找「带 players 数组的 Node3D」当 arena，这里给它一个假的。
class FakeArena extends Node3D:
	var players: Array = []

## 面板只读这四个查询，模拟层不必真跑起来。
class FakeSim:
	var entries: Array = []
	var material := 0

	func get_inventory_slot_profile(_slot: int, index: int) -> int:
		if index < 0 or index >= entries.size():
			return -1
		return entries[index]["profile"]

	func get_inventory_slot_amount(_slot: int, index: int) -> int:
		if index < 0 or index >= entries.size():
			return 0
		return entries[index]["amount"]

	func get_player_material(_slot: int) -> int:
		return material

	func get_upgrade_scale(_slot: int, _stat_index: int) -> float:
		return 1.0

var _frames := 0
var _out_path := "/tmp/inventory_preview.png"
var _panel: InventoryPanel = null
var _sim: FakeSim = null
var _category := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_path = args[0]
	var character_id := StringName(args[1]) if args.size() > 1 else &"male_assault"
	_category = int(args[2]) if args.size() > 2 else 0

	var arena := FakeArena.new()
	root.add_child(arena)
	var player := PLAYER_SCENE.instantiate()
	var definition = ContentCatalogsScript.characters().get_by_id(character_id)
	if definition != null:
		player.apply_character_definition(definition)
	player.visible = false
	arena.add_child(player)
	arena.players = [player]

	_sim = FakeSim.new()
	_sim.material = 0
	_sim.entries = _sample_entries()

	_panel = PANEL_SCENE.instantiate() as InventoryPanel
	root.add_child(_panel)
	_panel.visible = true

func _process(_delta: float) -> bool:
	_frames += 1
	# setup() 要走 get_tree() 找 arena，_initialize() 里节点还没真正进树，
	# 所以喂数据推迟到第一帧。
	if _frames == 1:
		_panel.setup(_sim, 0, _profiles())
		_panel._select_category(_category)
	if _frames < WARMUP_FRAMES:
		return false
	var image := root.get_texture().get_image()
	image.save_png(_out_path)
	print("inventory preview saved: %s (%dx%d)" % [_out_path, image.get_width(), image.get_height()])
	return true

func _profiles() -> Array[InventoryProfile]:
	var result: Array[InventoryProfile] = []
	result.append_array(PROFILE_CATALOG.profiles)
	return result

## 复刻参考图那一屏：冲锋枪 + 手枪各一把，另加弹药/油桶/改装各一份用来翻页签。
func _sample_entries() -> Array:
	var by_id := {}
	var profiles := _profiles()
	for index in range(profiles.size()):
		by_id[profiles[index].profile_id] = index
	return [
		{"profile": by_id.get(&"weapon_smg", -1), "amount": 1},
		{"profile": by_id.get(&"weapon_pistol", -1), "amount": 1},
		{"profile": by_id.get(&"ammo_smg", -1), "amount": 120},
		{"profile": by_id.get(&"oil_barrel", -1), "amount": 2},
		{"profile": by_id.get(&"mod_damage", -1), "amount": 1},
		{"profile": by_id.get(&"mod_pierce", -1), "amount": 1},
	]
