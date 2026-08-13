extends Control
class_name ShopPanel

## 波间商店面板：血迹金属卡片布局。
##
## 顶部鎏金标题牌 + 当前材料牌，中间 3 张卡（金属奖章图标 + LV 徽标 + 名称 +
## 描述 + 价格条 + 选择按钮），底部提示条。买不起的卡整体压暗、价格转红、
## 按钮切禁用贴图并显示「材料不足」。
##
## arena 在 intermission_started 时 set_offers() + show()，wave_started 时 hide()。
## 购买发 buy_requested(offer_index)。
##
## 字体：根节点挂了带 default_font 的 Theme（见 ShopPanel.tscn 的 SubResource），
## 卡片是运行时 new 出来的，靠继承这个 Theme 拿字体——不要改成裸 Label 依赖
## 项目默认主题，project.godot 没有 [gui] 默认字体，Web 导出上会变豆腐块。
## 见 AGENTS.md「UI Font Coverage」。
##
## 装饰符号（分隔菱形、细线）一律用 ColorRect 画，不用字形：不用字形就不缺字形。

signal buy_requested(offer_index: int)

const ASSET_DIR := "res://assets/ui/shop/"

const CARD_SIZE := Vector2(256.0, 384.0)
## 奖章直径，以及它高出卡片上沿的量（参考图里奖章是骑在卡片顶边上的）。
const MEDAL_SIZE := Vector2(116.0, 116.0)
const MEDAL_OVERHANG := 32.0
## 卡片内容区避开奖章要留的上边距。
const CARD_PAD_TOP := 92
const CARD_PAD_SIDE := 26
const CARD_PAD_BOTTOM := 20
## 选择按钮：贴图是 3:1，这里 212×58 约 3.7:1，横向拉伸控制在两成以内。
const BUTTON_SIZE := Vector2(0.0, 58.0)

const COLOR_NAME := Color(0.96, 0.87, 0.62, 1.0)
const COLOR_DESC := Color(0.70, 0.68, 0.62, 1.0)
const COLOR_LV := Color(0.85, 0.80, 0.66, 1.0)
const COLOR_PRICE_OK := Color(0.95, 0.92, 0.85, 1.0)
const COLOR_PRICE_BAD := Color(0.87, 0.24, 0.19, 1.0)
const COLOR_BTN_TEXT := Color(0.95, 0.91, 0.80, 1.0)
const COLOR_BTN_TEXT_OFF := Color(0.55, 0.54, 0.52, 1.0)
## 买不起时整张卡的压暗量。
const CARD_DIM := Color(0.72, 0.72, 0.74, 1.0)

## 选中动画的三段时长（放大发光 / 火环绕行 / 闪光收束），总计 0.78s。
## 购买命令在动画**开始前**就发出去了，所以这段时间不吃波间窗口。
const SELECT_GROW_SECONDS := 0.26
const SELECT_RING_SECONDS := 0.34
const SELECT_FLASH_SECONDS := 0.18
const SELECT_CARD_SCALE := 1.16
## 动画期间其余卡片压到多暗。
const SELECT_OTHERS_DIM := Color(0.42, 0.42, 0.46, 1.0)
## 倒计时低于这个秒数就转红并闪烁。
const TIMER_WARN_SECONDS := 5.0

@onready var material_label: Label = $Layout/MaterialPlate/Content/AmountRow/AmountLabel
@onready var offers_container: HBoxContainer = $Layout/CardsRow
@onready var timer_bar: ProgressBar = $Layout/TimerRow/TimerBar
@onready var timer_label: Label = $Layout/TimerRow/TimerLabel

var _offers: Array[ShopOfferDefinition] = []
var _material := 0
var _cards: Array[CardView] = []
## 本次波间的总时长，用来算进度条比例。取见过的最大剩余秒数——开店那一帧就是它。
var _total_seconds := 0.0
var _seconds_remaining := 0.0
## 选中动画播放中：期间所有按钮禁用，且 _refresh_cards() 不去覆盖卡片 modulate。
var _animating := false
var _select_tween: Tween = null
## arena 在 buy_requested 的同步处理里回填「这一笔被拒了」的卡片下标。
var _rejected_index := -1

## 一张卡上会被 _refresh_cards() 改状态的几个节点。
## 用显式引用而不是按子节点下标去翻——布局一改下标就错位，且错得没有报错。
class CardView:
	var root: Control
	var button: Button
	var price: Label
	var level: Label

## 商品和材料数都先存进字段再落地，_ready 里补一次：调用方可能在面板进树之前
## 就喂数据（@onready 还没赋值），那时静默跳过会留下一个空商店。
func _ready() -> void:
	_rebuild_cards()
	_apply_material_label()
	set_seconds_remaining(_seconds_remaining)

func set_material_count(amount: int) -> void:
	_material = amount
	_apply_material_label()
	_refresh_cards()

func set_offers(offers: Array) -> void:
	# 上一波的选中动画可能还没播完就被 wave_started 关了店。不在这里掐掉的话
	# _animating 会一直是 true，下一波的 _rebuild_cards() 直接早退——商店开着但一张卡都没有。
	_cancel_select_animation()
	_offers.assign(offers)
	# 换一波重新标定倒计时进度条的满格值
	_total_seconds = 0.0
	_rebuild_cards()

## 波间剩余秒数。arena 逐帧喂进来（值来自模拟 tick，不是第二个计时器）。
func set_seconds_remaining(seconds: float) -> void:
	_seconds_remaining = maxf(seconds, 0.0)
	_total_seconds = maxf(_total_seconds, _seconds_remaining)
	if timer_label != null:
		timer_label.text = "%.1fs" % _seconds_remaining
		var warn := _seconds_remaining <= TIMER_WARN_SECONDS
		timer_label.add_theme_color_override(
			"font_color",
			COLOR_PRICE_BAD if warn else Color(0.85, 0.79, 0.62, 1.0)
		)
	if timer_bar != null:
		timer_bar.value = (
			_seconds_remaining / _total_seconds if _total_seconds > 0.0 else 0.0
		)

func _apply_material_label() -> void:
	if material_label == null:
		return
	material_label.text = str(_material)

func _rebuild_cards() -> void:
	if offers_container == null:
		return
	# 重建会连节点一起销毁正在播的选中动画，动画期间不重建（arena 侧也已经不再
	# 在每次购买后调 set_offers，见 GameplayArena._refresh_shop_material）。
	if _animating:
		return
	# 先 remove_child 再 queue_free：queue_free 是延迟的，只 free 不摘的话新旧卡片
	# 会同帧挂在同一个 HBoxContainer 上，被挤成六张窄卡闪一帧。
	# arena 每次购买后都会重调 set_offers()，这一帧闪烁会稳定复现。
	for child in offers_container.get_children():
		offers_container.remove_child(child)
		child.queue_free()
	_cards.clear()
	for index in range(_offers.size()):
		var offer := _offers[index]
		if offer == null:
			continue
		var view := _make_card(index, offer)
		offers_container.add_child(view.root)
		_cards.append(view)
	_refresh_cards()

## 做一张商品卡：血迹金属卡框 + 骑在顶边的奖章 + LV 徽标 + 名称/描述 + 价格条 + 按钮。
func _make_card(index: int, offer: ShopOfferDefinition) -> CardView:
	var view := CardView.new()

	var card := Control.new()
	card.custom_minimum_size = CARD_SIZE
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	view.root = card

	var frame := TextureRect.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.texture = _tex(_card_frame_file(offer))
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(frame)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", CARD_PAD_TOP)
	margin.add_theme_constant_override("margin_left", CARD_PAD_SIDE)
	margin.add_theme_constant_override("margin_right", CARD_PAD_SIDE)
	margin.add_theme_constant_override("margin_bottom", CARD_PAD_BOTTOM)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	vbox.add_child(_make_lv_badge(view, 1))
	vbox.add_child(_make_name_label(offer))
	vbox.add_child(_make_desc_label(offer))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	view.price = _make_price_label(offer)
	vbox.add_child(_make_cost_row(view.price))

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 10.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(gap)

	view.button = _make_select_button(index)
	vbox.add_child(view.button)

	# 奖章最后加，盖在卡框和内容之上，并高出卡片上沿 MEDAL_OVERHANG。
	var medal := TextureRect.new()
	medal.texture = _tex(_medal_file(offer))
	medal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	medal.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	medal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	medal.anchor_left = 0.5
	medal.anchor_right = 0.5
	medal.anchor_top = 0.0
	medal.anchor_bottom = 0.0
	medal.offset_left = -MEDAL_SIZE.x * 0.5
	medal.offset_right = MEDAL_SIZE.x * 0.5
	medal.offset_top = -MEDAL_OVERHANG
	medal.offset_bottom = MEDAL_SIZE.y - MEDAL_OVERHANG
	card.add_child(medal)

	return view

func _make_lv_badge(view: CardView, level: int) -> Control:
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.07, 0.85)
	style.border_color = Color(0.45, 0.40, 0.28, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 1.0
	style.content_margin_bottom = 1.0
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var label := Label.new()
	label.text = "LV.%d" % level
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", COLOR_LV)
	panel.add_child(label)
	view.level = label
	return center

## 每张卡买下去之后会到达的等级。arena 逐帧算好喂进来（改装件读当前层数 + 本商品层数）。
## 之前这里写死 LV.1，反复买同一个改装件卡面纹丝不动，看起来就像没生效。
func set_offer_levels(levels: PackedInt32Array) -> void:
	for index in range(_cards.size()):
		if index >= levels.size():
			break
		var label := _cards[index].level
		if label != null:
			label.text = "LV.%d" % maxi(levels[index], 1)

func _make_name_label(offer: ShopOfferDefinition) -> Label:
	var label := Label.new()
	label.text = offer.display_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", COLOR_NAME)
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label

func _make_desc_label(offer: ShopOfferDefinition) -> Label:
	var label := Label.new()
	label.text = _effect_text(offer)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_DESC)
	return label

func _make_price_label(offer: ShopOfferDefinition) -> Label:
	var label := Label.new()
	label.text = "%d 材料" % offer.price
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_PRICE_OK)
	return label

## 价格条：内凹深色底 + 材料箱图标 + 价格文本。
func _make_cost_row(price_label: Label) -> Control:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.045, 0.05, 0.62)
	style.border_color = Color(0.32, 0.30, 0.24, 0.85)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	panel.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)

	var crate := TextureRect.new()
	crate.texture = _tex("icon_material_crate.png")
	crate.custom_minimum_size = Vector2(24.0, 24.0)
	crate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	crate.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	crate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(crate)
	row.add_child(price_label)
	return panel

func _make_select_button(index: int) -> Button:
	var button := Button.new()
	button.text = "选择"
	button.custom_minimum_size = BUTTON_SIZE
	button.add_theme_stylebox_override("normal", _button_style("button_normal.png", Color(1.0, 1.0, 1.0, 1.0)))
	button.add_theme_stylebox_override("hover", _button_style("button_normal.png", Color(1.22, 1.18, 1.08, 1.0)))
	button.add_theme_stylebox_override("pressed", _button_style("button_normal.png", Color(0.78, 0.78, 0.76, 1.0)))
	button.add_theme_stylebox_override("disabled", _button_style("button_disabled.png", Color(1.0, 1.0, 1.0, 1.0)))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_color_override("font_color", COLOR_BTN_TEXT)
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.86, 1.0))
	button.add_theme_color_override("font_pressed_color", COLOR_BTN_TEXT)
	button.add_theme_color_override("font_disabled_color", COLOR_BTN_TEXT_OFF)
	button.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	button.add_theme_constant_override("shadow_offset_y", 2)
	button.pressed.connect(_on_card_pressed.bind(index))
	return button

## 先发购买、再播动画：动画是纯反馈，不该占用只有十几秒的波间窗口。
## buy_requested 是同步 emit，arena 在这一行里就把成交与否定了，所以下面能直接
## 按结果选播「买到了」还是「没买成」。
func _on_card_pressed(index: int) -> void:
	if _animating:
		return
	_rejected_index = -1
	buy_requested.emit(index)
	if _rejected_index == index:
		_play_reject_animation(index)
		return
	_play_select_animation(index)

## arena 在 buy_requested 处理过程中回调：这笔没成交。
func notify_purchase_rejected(index: int) -> void:
	_rejected_index = index

## 没买成的反馈：卡片左右急抖两下 + 价格条闪红。不放大、不出火环——
## 让「成交」和「没成交」在 0.2 秒内就能分辨，而不是都表现成什么都没发生。
func _play_reject_animation(index: int) -> void:
	if index < 0 or index >= _cards.size():
		return
	var card := _cards[index].root
	if card == null:
		return
	var origin := card.position
	var tween := create_tween()
	for offset in [10.0, -8.0, 5.0, -3.0, 0.0]:
		tween.tween_property(card, "position:x", origin.x + offset, 0.045) \
			.set_trans(Tween.TRANS_SINE)
	var price := _cards[index].price
	if price != null:
		price.add_theme_color_override("font_color", COLOR_PRICE_BAD)
	tween.finished.connect(func() -> void:
		if is_instance_valid(card):
			card.position = origin
		_refresh_cards()
	)

## 选中动画：卡片放大 + 暖光描边 → 火环绕行一圈 → 收成一道闪光，
## 同时其余卡片压暗。参考 docs 的演示视频。
func _play_select_animation(index: int) -> void:
	if index < 0 or index >= _cards.size():
		return
	var card := _cards[index].root
	if card == null or card.size == Vector2.ZERO:
		return
	_animating = true
	_refresh_cards()  # 立刻禁用全部按钮，避免动画期间连点

	card.pivot_offset = card.size * 0.5
	card.z_index = 10
	var center := card.size * 0.5
	var glow := _make_fx("fx_select_glow.png", card, center, card.size * 1.7)
	var ring := _make_fx("fx_select_ring.png", card, center, card.size * 1.28)
	var flash := _make_fx("fx_select_flash.png", card, center, Vector2.ONE * card.size.y * 1.5)
	card.move_child(glow, 0)
	card.move_child(ring, 1)
	glow.modulate.a = 0.0
	ring.modulate.a = 0.0
	flash.modulate.a = 0.0

	var tween := create_tween()
	_select_tween = tween
	tween.set_parallel(false)

	# 一、放大 + 亮起，其余卡压暗
	tween.tween_property(card, "scale", Vector2.ONE * SELECT_CARD_SCALE, SELECT_GROW_SECONDS) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(glow, "modulate:a", 0.9, SELECT_GROW_SECONDS)
	for other in range(_cards.size()):
		if other == index or _cards[other].root == null:
			continue
		tween.parallel().tween_property(
			_cards[other].root, "modulate", SELECT_OTHERS_DIM, SELECT_GROW_SECONDS
		)

	# 二、火环绕行一圈并收拢
	tween.parallel().tween_property(ring, "modulate:a", 1.0, SELECT_GROW_SECONDS)
	tween.tween_property(ring, "rotation", TAU, SELECT_RING_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.parallel().tween_property(ring, "scale", Vector2.ONE * 0.72, SELECT_RING_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(ring, "modulate:a", 0.0, SELECT_RING_SECONDS) \
		.set_delay(SELECT_RING_SECONDS * 0.55)

	# 三、收成一道闪光，卡片落回原位，其余卡恢复
	tween.tween_property(flash, "modulate:a", 1.0, SELECT_FLASH_SECONDS * 0.35)
	tween.parallel().tween_property(
		flash, "scale", Vector2.ONE * 1.45, SELECT_FLASH_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(card, "scale", Vector2.ONE, SELECT_FLASH_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(glow, "modulate:a", 0.0, SELECT_FLASH_SECONDS)
	tween.tween_property(flash, "modulate:a", 0.0, SELECT_FLASH_SECONDS * 0.65)

	tween.finished.connect(_on_select_animation_finished.bind(card, [glow, ring, flash]))

## 中途掐掉动画（换波关店时）。卡片节点马上要被 _rebuild_cards() 整排销毁，
## 所以这里只负责把 _animating 放回去，不去动那些即将失效的节点。
func _cancel_select_animation() -> void:
	if _select_tween != null and _select_tween.is_valid():
		_select_tween.kill()
	_select_tween = null
	_animating = false

func _on_select_animation_finished(card: Control, effects: Array) -> void:
	_select_tween = null
	for effect in effects:
		var node := effect as Node
		if is_instance_valid(node):
			node.queue_free()
	if is_instance_valid(card):
		card.scale = Vector2.ONE
		card.z_index = 0
	_animating = false
	# 动画期间 _refresh_cards() 不碰 modulate，结束后统一按当前材料数重算一遍——
	# 包括把动画压暗的其余卡片恢复回去。
	for view in _cards:
		if view.root != null:
			view.root.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_refresh_cards()

## 一个居中的加色混合特效贴图。素材画在纯黑底上，加色混合下黑=透明，
## 比对火焰这种带辉光的东西做抠图干净得多。
##
## 用 STRETCH_SCALE 而不是 KEEP_ASPECT：贴图是正方形而卡片是 2:3，保持长宽比
## 会让火环缩到卡片宽度那一圈，上下两段跑到卡外、看起来像两根火柱而不是一个环。
## 拉成椭圆才是「绕着这张卡转」。
func _make_fx(file: String, parent: Control, center: Vector2, span: Vector2) -> Control:
	var rect := TextureRect.new()
	rect.texture = _tex(file)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.size = span
	rect.position = center - span * 0.5
	rect.pivot_offset = span * 0.5
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	rect.material = material
	parent.add_child(rect)
	return rect

## 按钮贴图是整块画好的定尺图，没有可平铺的中段：StyleBoxTexture 的九宫格边角
## 按贴图原始像素画、不跟着按钮缩放，在 212×58 的按钮上会把边框撑得过粗。
## 所以 texture_margin 全留 0，整图跟着按钮矩形缩放（BUTTON_SIZE 已按贴图的
## 3:1 选过，横向只多拉约两成，圆角看不出变形）。
func _button_style(file: String, modulate_color: Color) -> StyleBox:
	var texture := _tex(file)
	if texture == null:
		var fallback := StyleBoxFlat.new()
		fallback.bg_color = Color(0.24, 0.30, 0.20, 0.95) * modulate_color
		fallback.set_corner_radius_all(6)
		return fallback
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.modulate_color = modulate_color
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style

## 卡框配色：三张卡同屏时按类型错开，和参考图一致（移速绿 / 伤害琥珀 / 生命钢灰）。
func _card_frame_file(offer: ShopOfferDefinition) -> String:
	match offer.offer_type:
		ShopOfferDefinition.OfferType.STAT:
			match offer.stat_index:
				0:
					return "card_frame_amber.png"
				1:
					return "card_frame_steel.png"
				2:
					return "card_frame_green.png"
		ShopOfferDefinition.OfferType.HEAL:
			return "card_frame_steel.png"
		ShopOfferDefinition.OfferType.WEAPON:
			return "card_frame_amber.png"
		ShopOfferDefinition.OfferType.PASSIVE:
			return "card_frame_green.png"
		ShopOfferDefinition.OfferType.AMMO:
			return "card_frame_amber.png"
		ShopOfferDefinition.OfferType.WEAPON_MOD:
			return "card_frame_steel.png"
		ShopOfferDefinition.OfferType.OIL:
			return "card_frame_green.png"
	return "card_frame_steel.png"

## 奖章图标：STAT 按 stat_index 细分；武器/弹药按 weapon_id、被动按 passive_id
## 各自认到具体物品（medal_weapon_smg / medal_ammo_shotgun / medal_passive_medic_aura …）。
## 目录里加了新武器又还没配奖章时，回落到该类型的通用奖章而不是变成空图。
func _medal_file(offer: ShopOfferDefinition) -> String:
	match offer.offer_type:
		ShopOfferDefinition.OfferType.STAT:
			match offer.stat_index:
				0:
					return "medal_damage.png"
				1:
					return "medal_health.png"
				2:
					return "medal_speed.png"
		ShopOfferDefinition.OfferType.HEAL:
			return "medal_heal.png"
		ShopOfferDefinition.OfferType.WEAPON:
			return _medal_for_id("medal_weapon_%s.png" % offer.weapon_id, "medal_weapon.png")
		ShopOfferDefinition.OfferType.PASSIVE:
			return _medal_for_id("medal_passive_%s.png" % offer.passive_id, "medal_passive.png")
		ShopOfferDefinition.OfferType.AMMO:
			return _medal_for_id("medal_ammo_%s.png" % offer.weapon_id, "medal_ammo.png")
		ShopOfferDefinition.OfferType.WEAPON_MOD:
			return _medal_for_id("medal_mod_%s.png" % offer.weapon_mod_id, "medal_mod.png")
		ShopOfferDefinition.OfferType.OIL:
			return "medal_oil.png"
	return "medal_damage.png"

func _medal_for_id(specific: String, generic: String) -> String:
	return specific if ResourceLoader.exists(ASSET_DIR + specific) else generic

## 描述行说的是「这一类强化改什么」，具体数值由 display_name 承担，两行不重复。
## 商品自带 effect_text 时优先用它——改装件的负面代价必须原样显示出来，
## 否则玩家只会觉得"我买了个东西然后变菜了"（同 PickupDefinition.effect_text 的规矩）。
func _effect_text(offer: ShopOfferDefinition) -> String:
	if not offer.effect_text.is_empty():
		return offer.effect_text
	match offer.offer_type:
		ShopOfferDefinition.OfferType.STAT:
			match offer.stat_index:
				0:
					return "所有伤害提升"
				1:
					return "生命上限提升"
				2:
					return "移动速度提升"
		ShopOfferDefinition.OfferType.HEAL:
			return "立即恢复生命"
		ShopOfferDefinition.OfferType.WEAPON:
			return "获得一件武器"
		ShopOfferDefinition.OfferType.PASSIVE:
			return "获得一个被动"
		ShopOfferDefinition.OfferType.AMMO:
			return "补充弹药储备"
		ShopOfferDefinition.OfferType.WEAPON_MOD:
			return "武器改装升级"
		ShopOfferDefinition.OfferType.OIL:
			return "可放置的油桶"
	return ""

## 缓存加载贴图（每次刷新都会重建卡片，不缓存就是每波几十次 load）。
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

## 买得起才可点；买不起的卡整体压暗、价格转红、按钮切禁用贴图并改文案。
func _refresh_cards() -> void:
	for index in range(_cards.size()):
		if index >= _offers.size():
			break
		var view := _cards[index]
		var offer := _offers[index]
		var affordable := offer.price <= _material
		# 动画期间全部禁用，防止连点把第二笔购买挤进同一波
		view.button.disabled = _animating or not affordable
		view.button.text = "选择" if affordable else "材料不足"
		view.price.add_theme_color_override(
			"font_color", COLOR_PRICE_OK if affordable else COLOR_PRICE_BAD
		)
		# 动画自己在补间 modulate，这里不要每帧覆盖回去（arena 逐帧调 set_material_count）
		if not _animating:
			view.root.modulate = Color(1.0, 1.0, 1.0, 1.0) if affordable else CARD_DIM
