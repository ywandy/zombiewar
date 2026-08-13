extends Control
class_name InventoryPanel

## 背包面板：Brotato 式左侧角色属性 + 右侧分区物品。
##
## 遮罩层压暗背景。左侧显示角色属性（生命/移速/伤害/被动），
## 右侧按分类分区（武器/弹药/油桶/改装），每格图标 + 数量角标。
## 数据从 SimWorld 逐玩家背包槽位 + 玩家属性读（确定性），表现层只读不改。
## B 键打开/关闭由 arena 控制。

const SLOT_COUNT := 12
const ATLAS_COLUMNS := 5

const CATEGORY_LABELS := {
	0: "武器",
	1: "弹药",
	2: "油桶",
	3: "改装",
}

@onready var atlas_texture: Texture2D = preload("res://assets/ui/inventory/inventory_atlas.png")
@onready var title_label: Label = $Margin/Panel/VBox/TitleLabel
@onready var material_label: Label = $Margin/Panel/VBox/MaterialLabel
@onready var content_box: HBoxContainer = $Margin/Panel/VBox/Content
@onready var stats_box: VBoxContainer = $Margin/Panel/VBox/Content/StatsPanel/StatsBox
@onready var sections_box: VBoxContainer = $Margin/Panel/VBox/Content/Sections

var _sim_world = null
var _player_slot := 0
var _profile_catalog: Array[InventoryProfile] = []
var _player: PlayerController = null

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
	var root := get_tree().root
	for child in root.get_children():
		if child is Node3D and child.get("players") != null:
			var players: Array = child.get("players")
			if slot >= 0 and slot < players.size():
				return players[slot] as PlayerController
	return null

func _refresh() -> void:
	if _sim_world == null:
		return
	_refresh_stats()
	_refresh_items()

## ---- 左侧：角色属性 ----
func _refresh_stats() -> void:
	if stats_box == null:
		return
	for child in stats_box.get_children():
		child.queue_free()
	# 材料数（顶部已显示，这里只列属性）
	if _player == null:
		_add_stat_line("角色", "未知")
		return
	# 角色名（职业）
	var char_name := "幸存者"
	if _player.character_definition != null:
		char_name = _player.character_definition.display_name
	_add_stat_line("角色", char_name, Color(0.95, 0.93, 0.89))
	# 生命
	_add_stat_line("生命", "%d / %d" % [roundi(_player.health.current), roundi(_player.health.maximum)])
	# 移速
	_add_stat_line("移速", "%.1f" % _player.move_speed)
	# 伤害倍率（本命武器 + 商店成长）
	var damage_scale := 1.0
	if _sim_world != null:
		damage_scale = _sim_world.get_upgrade_scale(_player_slot, 0)  # STAT_DAMAGE
	_add_stat_line("伤害", "%.0f%%" % (damage_scale * 100.0))
	# 被动
	var passive_text := "无"
	var passive_id := _player.effective_passive_id()
	if passive_id != &"":
		passive_text = _passive_display_name(passive_id)
	_add_stat_line("被动", passive_text, Color(0.5, 0.8, 0.9))

func _add_stat_line(label: String, value: String, color: Color = Color(0.75, 0.78, 0.72)) -> void:
	var hbox := HBoxContainer.new()
	var label_node := Label.new()
	label_node.text = label
	label_node.add_theme_font_size_override("font_size", 14)
	label_node.add_theme_color_override("font_color", Color(0.6, 0.65, 0.58, 1.0))
	label_node.custom_minimum_size = Vector2(48, 0)
	hbox.add_child(label_node)
	var value_node := Label.new()
	value_node.text = value
	value_node.add_theme_font_size_override("font_size", 14)
	value_node.add_theme_color_override("font_color", color)
	hbox.add_child(value_node)
	stats_box.add_child(hbox)

func _passive_display_name(passive_id: StringName) -> String:
	match passive_id:
		&"blast_armor":
			return "防爆甲"
		&"medic_aura":
			return "医疗光环"
		&"fortify":
			return "加固"
		&"suppression":
			return "压制"
	return String(passive_id)

## ---- 右侧：分区物品 ----
func _refresh_items() -> void:
	if sections_box == null:
		return
	for child in sections_box.get_children():
		child.queue_free()
	# 收集 12 槽的物品，按分类分组
	var by_category := {}
	for i in range(SLOT_COUNT):
		var profile_index: int = _sim_world.get_inventory_slot_profile(_player_slot, i)
		var amount: int = _sim_world.get_inventory_slot_amount(_player_slot, i)
		if profile_index < 0 or amount <= 0:
			continue
		var profile := _profile_for_index(profile_index)
		if profile == null:
			continue
		var cat: int = profile.category
		if not by_category.has(cat):
			by_category[cat] = []
		by_category[cat].append({"profile": profile, "amount": amount})
	# 材料数（顶部）
	if material_label != null:
		material_label.text = "材料 %d" % _sim_world.get_player_material(_player_slot)
	# 按分类顺序渲染分区
	for cat in [0, 1, 2, 3]:
		if not by_category.has(cat):
			continue
		var section := _make_section(cat, by_category[cat])
		sections_box.add_child(section)

func _make_section(category: int, items: Array) -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = CATEGORY_LABELS.get(category, "其他")
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.95, 0.66, 0.0, 1.0))
	vbox.add_child(label)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	for item in items:
		grid.add_child(_make_item_cell(item["profile"], item["amount"]))
	vbox.add_child(grid)
	return vbox

func _make_item_cell(profile: InventoryProfile, amount: int) -> Control:
	var cell := PanelContainer.new()
	cell.custom_minimum_size = Vector2(64, 64)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.08, 0.95)
	style.border_color = Color(0.3, 0.35, 0.28, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	cell.add_theme_stylebox_override("panel", style)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if profile.icon_region != null and profile.icon_region.size.x > 0.0:
		var atlas := AtlasTexture.new()
		atlas.atlas = atlas_texture
		atlas.region = profile.icon_region
		icon.texture = atlas
	cell.add_child(icon)
	var count := Label.new()
	count.text = "×%d" % amount if amount > 1 else ""
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_font_size_override("font_size", 12)
	count.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	cell.add_child(count)
	cell.tooltip_text = profile.display_name
	return cell

func _profile_for_index(profile_index: int) -> InventoryProfile:
	if profile_index < 0 or profile_index >= _profile_catalog.size():
		return null
	return _profile_catalog[profile_index]
