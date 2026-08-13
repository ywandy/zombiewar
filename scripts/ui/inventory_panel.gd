extends Control
class_name InventoryPanel

## 背包面板：血迹金属边框 + 左侧角色属性 + 右侧分类物品格。
##
## 全屏铁框压在压暗的战场上（内层只有半透明暗板，所以打开背包时还能看见后面
## 打到哪了）。左侧是角色名牌与属性牌（生命/移速/伤害/被动/本命武器），右侧是
## 分类页签 + 铁丝网格子，格子下面一条说明栏显示鼠标悬停的物品。
##
## 数据从 SimWorld 逐玩家背包槽位 + 玩家属性读（确定性），表现层只读不改。
## B 键开关由 arena 控制；面板自己只额外提供右上角关闭按钮和分类页签点击。
##
## 键盘不做快捷键：背包打开时游戏没有暂停，而 Q/E/空格 这些键是
## KeyboardWasdInputSource 每帧 poll 的战斗输入，面板拦不住（poll 不看事件是否
## 被 set_input_as_handled）。给页签配 Q/E 只会让玩家一边翻背包一边换枪。
##
## 字体：根节点挂了带 default_font 的 Theme（见 InventoryPanel.tscn 的
## SubResource），运行时 new 出来的控件靠继承这个 Theme 拿字体——项目
## project.godot 没有 [gui] 默认字体，裸 Label 在 Web 导出上是豆腐块。
## 见 AGENTS.md「UI Font Coverage」。装饰符号一律用 ColorRect 画，不用字形。

const ASSET_DIR := "res://assets/ui/backpack/"
const PORTRAIT_PREFIX := "portrait_"

const SLOT_COUNT := 12
const GRID_COLUMNS := 6
const SLOT_SIZE := Vector2(118.0, 118.0)
const ICON_SIZE := Vector2(90.0, 90.0)
## 铁丝网边框自身占掉的一圈，格子底板要缩进这么多才不会盖住铁丝。
const SLOT_INSET := 9.0

const COLOR_TAB_ON := Color(0.95, 0.62, 0.18, 1.0)
const COLOR_TAB_OFF := Color(0.55, 0.53, 0.49, 1.0)
const COLOR_STAT_LABEL := Color(0.87, 0.85, 0.80, 1.0)
const COLOR_STAT_VALUE := Color(0.97, 0.96, 0.93, 1.0)
const COLOR_STAT_PASSIVE := Color(0.42, 0.72, 0.93, 1.0)
const COLOR_STAT_WEAPON := Color(0.95, 0.68, 0.24, 1.0)
const COLOR_SEPARATOR := Color(0.45, 0.38, 0.32, 0.5)
const COLOR_SLOT_BACK := Color(0.055, 0.058, 0.062, 0.72)

const CATEGORY_TABS := [
	{"category": InventoryProfile.Category.WEAPON, "label": "武器", "icon": "icon_cat_weapon.png"},
	{"category": InventoryProfile.Category.AMMO, "label": "弹药", "icon": "icon_cat_ammo.png"},
	{"category": InventoryProfile.Category.OIL, "label": "油桶", "icon": "icon_cat_oil.png"},
	{"category": InventoryProfile.Category.WEAPON_MOD, "label": "改装", "icon": "icon_cat_mod.png"},
]

const PASSIVE_NAMES := {
	&"blast_armor": "防爆甲",
	&"medic_aura": "医疗光环",
	&"fortify": "加固",
	&"suppression": "压制",
}

@onready var atlas_texture: Texture2D = preload("res://assets/ui/inventory/inventory_atlas.png")
@onready var material_label: Label = $MaterialTag/MaterialLabel
@onready var name_label: Label = $NameCard/NameLabel
@onready var accent_shape: ColorRect = $NameCard/Accent
@onready var portrait: TextureRect = $NameCard/Portrait
@onready var stats_box: VBoxContainer = $StatsPanel/StatsBox
@onready var tab_row: HBoxContainer = $TabRow
@onready var grid: GridContainer = $Grid
@onready var detail_name: Label = $Detail/DetailBox/DetailName
@onready var detail_desc: Label = $Detail/DetailBox/DetailDesc
@onready var close_button: TextureButton = $CloseButton

var _sim_world = null
var _player_slot := 0
var _profile_catalog: Array[InventoryProfile] = []
var _player: PlayerController = null
var _active_category: int = InventoryProfile.Category.WEAPON
var _tab_buttons: Array[Button] = []
var _cells: Array[SlotCell] = []
## 当前页签下要显示的物品，格子和底部说明栏都按这个数组的下标取。
var _visible_items: Array[Dictionary] = []

## 一个格子上会被刷新改到的几个节点。用显式引用而不是按子节点下标去翻——
## 布局一改下标就错位，且错得没有报错。
class SlotCell:
	var root: Control
	var frame: TextureRect
	var icon: TextureRect
	var count: Label

func _ready() -> void:
	grid.columns = GRID_COLUMNS
	_build_tabs()
	_build_cells()
	close_button.pressed.connect(hide)
	close_button.mouse_entered.connect(func() -> void:
		close_button.modulate = Color(1.25, 1.12, 0.95, 1.0))
	close_button.mouse_exited.connect(func() -> void:
		close_button.modulate = Color(1.0, 1.0, 1.0, 1.0))
	_clear_detail()
	_refresh()

func setup(
	sim_world,
	player_slot: int,
	profile_catalog: Array[InventoryProfile]
) -> void:
	_sim_world = sim_world
	_player_slot = player_slot
	_profile_catalog = profile_catalog
	# 玩家对象从 arena 的 players 数组读（避免 setup 签名变更的缓存问题）。
	# arena 挂在场景根，名字可能是 DemoMap 或 GameplayArena，用 find 兜底。
	_player = _find_player(player_slot)
	_refresh()

func _find_player(slot: int) -> PlayerController:
	# 从场景树找 arena（GameplayArena 或 DemoMap），读它的 players 数组。
	if not is_inside_tree():
		return null
	var root := get_tree().root
	for child in root.get_children():
		if child is Node3D and child.get("players") != null:
			var players: Array = child.get("players")
			if slot >= 0 and slot < players.size():
				return players[slot] as PlayerController
	return null

func _refresh() -> void:
	# 调用方可能在面板进树之前就喂数据（@onready 还没赋值），那一趟静默跳过，
	# 数据留在字段里，_ready 里会再刷一次。
	if stats_box == null:
		return
	_refresh_character()
	_refresh_stats()
	_refresh_items()

## ---- 左侧：名牌 ----
func _refresh_character() -> void:
	var definition: CharacterDefinition = null
	if _player != null:
		definition = _player.character_definition
	if definition == null:
		name_label.text = "幸存者"
		portrait.texture = null
		return
	name_label.text = definition.display_name
	accent_shape.color = definition.accent_color
	portrait.texture = _portrait_for(definition.character_id)

func _portrait_for(character_id: StringName) -> Texture2D:
	if character_id == &"":
		return null
	return _tex("%s%s.png" % [PORTRAIT_PREFIX, character_id])

## ---- 左侧：角色属性 ----
func _refresh_stats() -> void:
	for child in stats_box.get_children():
		stats_box.remove_child(child)
		child.queue_free()
	if _player == null:
		_add_stat_row("icon_hp.png", "生命", "--", COLOR_STAT_VALUE)
		return
	_add_stat_row(
		"icon_hp.png",
		"生命",
		"%d / %d" % [roundi(_player.health.current), roundi(_player.health.maximum)],
		COLOR_STAT_VALUE
	)
	stats_box.add_child(_make_separator())
	_add_stat_row("icon_speed.png", "移速", "%.1f" % _player.move_speed, COLOR_STAT_VALUE)
	stats_box.add_child(_make_separator())
	# 伤害倍率（商店成长），和商店里的 STAT_DAMAGE 同一份数据。
	var damage_scale := 1.0
	if _sim_world != null:
		damage_scale = _sim_world.get_upgrade_scale(_player_slot, 0)
	_add_stat_row("icon_damage.png", "伤害", "%.0f%%" % (damage_scale * 100.0), COLOR_STAT_VALUE)
	stats_box.add_child(_make_separator())
	var passive_text := "无"
	var passive_id := _player.effective_passive_id()
	if passive_id != &"":
		passive_text = String(PASSIVE_NAMES.get(passive_id, String(passive_id)))
	_add_stat_row("icon_passive.png", "被动", passive_text, COLOR_STAT_PASSIVE)
	stats_box.add_child(_make_separator())
	_add_stat_row("icon_cat_weapon.png", "本命", _signature_weapon_text(), COLOR_STAT_WEAPON)

## 本命武器：名字 + 该武器的专属伤害加成（1.0 时不显示倍率，免得写一行废话）。
func _signature_weapon_text() -> String:
	if _player == null or _player.character_definition == null:
		return "无"
	var definition := _player.character_definition
	if definition.signature_weapon_id == &"":
		return "无"
	var weapon_name := _weapon_display_name(definition.signature_weapon_id)
	if is_equal_approx(definition.signature_weapon_damage_mult, 1.0):
		return weapon_name
	return "%s ×%.2f" % [weapon_name, definition.signature_weapon_damage_mult]

func _weapon_display_name(weapon_id: StringName) -> String:
	for profile in _profile_catalog:
		if profile == null:
			continue
		if profile.category == InventoryProfile.Category.WEAPON and profile.weapon_id == weapon_id:
			return profile.display_name
	return String(weapon_id)

func _add_stat_row(icon_file: String, label: String, value: String, value_color: Color) -> void:
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var icon := TextureRect.new()
	icon.texture = _tex(icon_file)
	icon.custom_minimum_size = Vector2(40.0, 40.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var label_node := Label.new()
	label_node.text = label
	label_node.add_theme_font_size_override("font_size", 19)
	label_node.add_theme_color_override("font_color", COLOR_STAT_LABEL)
	label_node.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	label_node.add_theme_constant_override("shadow_offset_y", 2)
	label_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label_node)

	var value_node := Label.new()
	value_node.text = value
	value_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_node.add_theme_font_size_override("font_size", 19)
	value_node.add_theme_color_override("font_color", value_color)
	value_node.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	value_node.add_theme_constant_override("shadow_offset_y", 2)
	value_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value_node)

	stats_box.add_child(row)

func _make_separator() -> Control:
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0.0, 1.0)
	line.color = COLOR_SEPARATOR
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line

## ---- 右侧：分类页签 ----
func _build_tabs() -> void:
	_tab_buttons.clear()
	for child in tab_row.get_children():
		tab_row.remove_child(child)
		child.queue_free()
	for index in range(CATEGORY_TABS.size()):
		var spec: Dictionary = CATEGORY_TABS[index]
		var button := Button.new()
		button.text = spec["label"]
		# 图标贴图是 128×128 的方图，靠 icon_max_width 缩到 26；不要用 expand_icon：
		# 它把图标的最小尺寸算成 0，而 HBoxContainer 只给按钮最小宽度，图标会被压没。
		button.icon = _tex(spec["icon"])
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(0.0, 38.0)
		button.add_theme_font_size_override("font_size", 20)
		button.add_theme_constant_override("h_separation", 8)
		button.add_theme_constant_override("icon_max_width", 26)
		# 页签直接压在半透明的战场上（背包不暂停游戏），描边保证亮底也读得清。
		button.add_theme_constant_override("outline_size", 4)
		button.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		var category: int = spec["category"]
		button.pressed.connect(func() -> void: _select_category(category))
		tab_row.add_child(button)
		_tab_buttons.append(button)
	_apply_tab_state()

func _select_category(category: int) -> void:
	if _active_category == category:
		return
	_active_category = category
	_apply_tab_state()
	_refresh_items()
	_clear_detail()

## 选中的页签：琥珀色字 + 底部一条实心下划线；其余压暗。
func _apply_tab_state() -> void:
	for index in range(_tab_buttons.size()):
		var button := _tab_buttons[index]
		var active: bool = CATEGORY_TABS[index]["category"] == _active_category
		var color := COLOR_TAB_ON if active else COLOR_TAB_OFF
		button.add_theme_color_override("font_color", color)
		button.add_theme_color_override("font_hover_color", COLOR_TAB_ON)
		button.add_theme_color_override("font_pressed_color", COLOR_TAB_ON)
		button.add_theme_color_override("icon_normal_color", color)
		button.add_theme_color_override("icon_hover_color", COLOR_TAB_ON)
		button.add_theme_color_override("icon_pressed_color", COLOR_TAB_ON)
		button.add_theme_stylebox_override("normal", _tab_style(active))
		button.add_theme_stylebox_override("hover", _tab_style(active))
		button.add_theme_stylebox_override("pressed", _tab_style(active))

func _tab_style(active: bool) -> StyleBox:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.07, 0.05, 0.55) if active else Color(0.0, 0.0, 0.0, 0.0)
	style.border_color = COLOR_TAB_ON
	style.border_width_bottom = 3 if active else 0
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style

## ---- 右侧：物品格 ----
## 12 个格子建一次，之后只改内容：每次重建会在同一帧里挂新旧两批格子，
## GridContainer 会先按两倍数量排一帧（queue_free 是延迟的）。
func _build_cells() -> void:
	_cells.clear()
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	for index in range(SLOT_COUNT):
		var cell := _make_cell(index)
		grid.add_child(cell.root)
		_cells.append(cell)

func _make_cell(index: int) -> SlotCell:
	var cell := SlotCell.new()

	var root := Control.new()
	root.custom_minimum_size = SLOT_SIZE
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	cell.root = root

	var back := ColorRect.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.offset_left = SLOT_INSET
	back.offset_top = SLOT_INSET
	back.offset_right = -SLOT_INSET
	back.offset_bottom = -SLOT_INSET
	back.color = COLOR_SLOT_BACK
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(back)

	var frame := TextureRect.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(frame)
	cell.frame = frame

	var icon := TextureRect.new()
	icon.set_anchors_preset(Control.PRESET_CENTER)
	icon.offset_left = -ICON_SIZE.x * 0.5
	icon.offset_right = ICON_SIZE.x * 0.5
	icon.offset_top = -ICON_SIZE.y * 0.5
	icon.offset_bottom = ICON_SIZE.y * 0.5
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(icon)
	cell.icon = icon

	var count := Label.new()
	count.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	count.offset_top = -34.0
	count.offset_left = 10.0
	count.offset_right = -12.0
	count.offset_bottom = -10.0
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 17)
	count.add_theme_color_override("font_color", Color(0.98, 0.96, 0.92, 1.0))
	count.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.95))
	count.add_theme_constant_override("shadow_offset_x", 1)
	count.add_theme_constant_override("shadow_offset_y", 2)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	cell.count = count

	root.mouse_entered.connect(func() -> void: _show_detail(index))
	root.mouse_exited.connect(_clear_detail)
	return cell

## 当前页签下的物品：按槽位顺序取该分类的物品，摆满前面的格子，其余留空。
func _refresh_items() -> void:
	_visible_items.clear()
	if _sim_world != null:
		for slot_index in range(SLOT_COUNT):
			var profile_index: int = _sim_world.get_inventory_slot_profile(_player_slot, slot_index)
			var amount: int = _sim_world.get_inventory_slot_amount(_player_slot, slot_index)
			if profile_index < 0 or amount <= 0:
				continue
			var profile := _profile_for_index(profile_index)
			if profile == null or profile.category != _active_category:
				continue
			_visible_items.append({"profile": profile, "amount": amount})
		material_label.text = "材料 %d" % _sim_world.get_player_material(_player_slot)
	else:
		material_label.text = "材料 0"
	for index in range(_cells.size()):
		_apply_cell(_cells[index], index)

func _apply_cell(cell: SlotCell, index: int) -> void:
	if index >= _visible_items.size():
		cell.frame.texture = _tex("slot_empty.png")
		cell.icon.texture = null
		cell.count.text = ""
		cell.root.tooltip_text = ""
		return
	var entry: Dictionary = _visible_items[index]
	var profile: InventoryProfile = entry["profile"]
	var amount: int = entry["amount"]
	cell.frame.texture = _tex("slot_active.png")
	cell.icon.texture = _icon_for(profile)
	cell.count.text = "×%d" % amount if amount > 1 else ""
	cell.root.tooltip_text = profile.display_name

func _icon_for(profile: InventoryProfile) -> Texture2D:
	if profile.icon_region.size.x <= 0.0:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = atlas_texture
	atlas.region = profile.icon_region
	return atlas

func _profile_for_index(profile_index: int) -> InventoryProfile:
	if profile_index < 0 or profile_index >= _profile_catalog.size():
		return null
	return _profile_catalog[profile_index]

## ---- 底部说明栏 ----
func _show_detail(index: int) -> void:
	if index >= _visible_items.size():
		_clear_detail()
		return
	var profile: InventoryProfile = _visible_items[index]["profile"]
	detail_name.text = profile.display_name
	detail_desc.text = profile.description

func _clear_detail() -> void:
	detail_name.text = "物品详情"
	detail_desc.text = "把鼠标移到格子上查看物品"

## 贴图缓存：格子刷新每次都要取铁丝网贴图，不缓存就是每次开背包几十次 load。
static var _texture_cache: Dictionary = {}

func _tex(file: String) -> Texture2D:
	if _texture_cache.has(file):
		return _texture_cache[file]
	var path := ASSET_DIR + file
	var texture: Texture2D = null
	if ResourceLoader.exists(path):
		texture = load(path) as Texture2D
	_texture_cache[file] = texture
	return texture
