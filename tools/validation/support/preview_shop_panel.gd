extends SceneTree

## 离屏渲染一张 ShopPanel 截图，用来肉眼核对排版（不是自动化校验，跑完即可删）。
## 用法：/Applications/Godot.app/Contents/MacOS/Godot --path . --script \
##   tools/validation/support/preview_shop_panel.gd -- <输出绝对路径>

const WARMUP_FRAMES := 20
## variant == "anim" 时，在这些帧号（相对动画开始）各存一张，用来看动画的几个节拍。
const ANIM_CAPTURE_FRAMES := [3, 10, 18, 26, 34, 42, 50, 56]

var _frames := 0
var _out_path := "/tmp/shop_preview.png"
var _variant := "stat"
var _panel: ShopPanel = null
var _anim_started := false
var _anim_frame := 0
var _captured := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_path = args[0]
	_variant = args[1] if args.size() > 1 else "stat"
	var scene := load("res://scenes/ui/ShopPanel.tscn") as PackedScene
	_panel = scene.instantiate() as ShopPanel
	root.add_child(_panel)
	_panel.visible = true
	match _variant:
		"gear":
			_panel.set_offers(_gear_offers())
		"mod":
			_panel.set_offers(_mod_offers())
		_:
			_panel.set_offers(_sample_offers())
	_panel.set_material_count(42)
	_panel.set_seconds_remaining(11.4)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	if _variant != "anim":
		_save(_out_path)
		return true
	if not _anim_started:
		_anim_started = true
		# 直接按第二张卡（伤害提升 +25%）的选择按钮，走真实的信号链路
		_press_card_button(1)
		return false
	_anim_frame += 1
	if _captured < ANIM_CAPTURE_FRAMES.size() and _anim_frame >= ANIM_CAPTURE_FRAMES[_captured]:
		_save(_out_path.get_basename() + "_%d.png" % _captured)
		_captured += 1
	return _captured >= ANIM_CAPTURE_FRAMES.size()

func _save(path: String) -> void:
	var image := root.get_texture().get_image()
	image.save_png(path)
	print("shop preview saved: %s (%dx%d)" % [path, image.get_width(), image.get_height()])

## 顺着场景树找第 index 张卡的 Button 并 emit pressed——比直接调私有方法更接近真实点击。
func _press_card_button(index: int) -> void:
	var row := _panel.get_node("Layout/CardsRow")
	if index < 0 or index >= row.get_child_count():
		return
	for node in row.get_child(index).find_children("*", "Button", true, false):
		(node as Button).pressed.emit()
		return

## 复刻参考图那一屏：移速 25 / 伤害 35 / 生命 50，材料 42（第三张买不起）。
func _sample_offers() -> Array:
	var speed := ShopOfferDefinition.new()
	speed.offer_type = ShopOfferDefinition.OfferType.STAT
	speed.stat_index = 2
	speed.stat_amount = 1.08
	speed.price = 25
	speed.display_name = "移速 +8%"

	var damage := ShopOfferDefinition.new()
	damage.offer_type = ShopOfferDefinition.OfferType.STAT
	damage.stat_index = 0
	damage.stat_amount = 1.25
	damage.price = 35
	damage.display_name = "伤害提升 +25%"

	var health := ShopOfferDefinition.new()
	health.offer_type = ShopOfferDefinition.OfferType.STAT
	health.stat_index = 1
	health.stat_amount = 60.0
	health.price = 50
	health.display_name = "最大生命 +60"

	return [speed, damage, health]

## 另一屏：武器 / 被动 / 弹药——用来看长名称换行和另外几枚奖章。
func _gear_offers() -> Array:
	var weapon := ShopOfferDefinition.new()
	weapon.offer_type = ShopOfferDefinition.OfferType.WEAPON
	weapon.weapon_id = &"shotgun"
	weapon.price = 55
	weapon.display_name = "散弹枪"

	var passive := ShopOfferDefinition.new()
	passive.offer_type = ShopOfferDefinition.OfferType.PASSIVE
	passive.passive_id = &"medic_aura"
	passive.price = 60
	passive.display_name = "医疗光环"

	var ammo := ShopOfferDefinition.new()
	ammo.offer_type = ShopOfferDefinition.OfferType.AMMO
	ammo.weapon_id = &"smg"
	ammo.ammo_amount = 60
	ammo.price = 12
	ammo.display_name = "冲锋枪弹药 ×60"

	return [weapon, passive, ammo]

## 第三屏：改装件 / 油桶——这些以前只能靠击杀掉落，现在挪进了商店。
## 带负面代价的改装件要看 effect_text 有没有把代价显示出来。
func _mod_offers() -> Array:
	var mod_pierce := ShopOfferDefinition.new()
	mod_pierce.offer_type = ShopOfferDefinition.OfferType.WEAPON_MOD
	mod_pierce.weapon_mod_id = &"pierce"
	mod_pierce.weapon_mod_stacks = 1
	mod_pierce.price = 35
	mod_pierce.display_name = "破甲镐"
	mod_pierce.effect_text = "穿透 +1 个目标"

	var mod_hollow := ShopOfferDefinition.new()
	mod_hollow.offer_type = ShopOfferDefinition.OfferType.WEAPON_MOD
	mod_hollow.weapon_mod_id = &"hollow_point"
	mod_hollow.weapon_mod_stacks = 1
	mod_hollow.price = 45
	mod_hollow.display_name = "空尖弹"
	mod_hollow.effect_text = "伤害 +35%，代价：穿透 -1"

	var oil := ShopOfferDefinition.new()
	oil.offer_type = ShopOfferDefinition.OfferType.OIL
	oil.oil_amount = 30
	oil.price = 20
	oil.display_name = "油桶 ×30"
	oil.effect_text = "可放置的爆炸桶"

	return [mod_pierce, mod_hollow, oil]
