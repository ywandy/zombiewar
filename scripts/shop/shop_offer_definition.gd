extends Resource
class_name ShopOfferDefinition

## 波间商店的一个可售项。
##
## offer_type 决定购买时走模拟（stat/heal/weapon_mod）还是表现层（weapon/passive/ammo/oil）：
##   stat       —— 属性升级，进模拟成长表（确定性）
##   heal       —— 回血，进模拟 tick_player_heal_events
##   weapon     —— 买武器，走 SimWorld.accept_inventory 落账本
##   passive    —— 买被动，表现层 PlayerController.runtime_passive_id
##   ammo       —— 补弹药，走 SimWorld.accept_inventory 落账本
##   weapon_mod —— 买改装件，进模拟 grant_weapon_mod（层数进帧哈希，必须走模拟）
##   oil        —— 买油桶，走 SimWorld.accept_inventory 落账本
## 类型字段按 offer_type 各读各的，其余忽略。
##
## **OfferType 只能末尾追加。** 枚举值以整数存进 shop_catalog.tres，往中间插一项
## 会让已存的所有商品静默变成另一种类型——不报错，只是玩家买属性买到了武器。

enum OfferType { STAT, HEAL, WEAPON, PASSIVE, AMMO, WEAPON_MOD, OIL }

@export var offer_type := OfferType.STAT
## 属性升级用的统计种类（offer_type == STAT 时读）：
## 0=伤害  1=最大生命  2=移速
@export var stat_index := 0
## 属性升级的倍率（伤害/移速）或加值（生命），与 character 的成长语义一致。
@export var stat_amount := 1.0
## 回血量（offer_type == HEAL 时读）。
@export var heal_amount := 10.0
## 武器 id（offer_type == WEAPON / AMMO 时读，对应 resources/weapons/*.tres 的 weapon_id）。
@export var weapon_id: StringName = &""
## 被动 id（offer_type == PASSIVE 时读，同 character passive_id 的允许集合）。
@export var passive_id: StringName = &""
## 弹药量（offer_type == AMMO 时读）。
@export var ammo_amount := 20
## 改装件 id（offer_type == WEAPON_MOD 时读），必须是 WeaponModTable.MOD_IDS 里的一项。
@export var weapon_mod_id: StringName = &""
## 改装件层数（offer_type == WEAPON_MOD 时读）。
@export_range(1, 8, 1) var weapon_mod_stacks := 1
## 油桶数量（offer_type == OIL 时读）。
@export var oil_amount := 30
## 售价（材料）。
@export_range(1, 9999, 1) var price := 10
@export var display_name := ""
## 卡面第二行的效果说明。改装件带负面代价时**必须**写进来，否则玩家只会觉得
## "我买了个东西然后变菜了"——和 PickupDefinition.effect_text 是同一条规矩。
## 留空时商店按 offer_type 给一句通用文案。
@export_multiline var effect_text := ""

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if price <= 0:
		errors.append("price must be positive")
	if display_name.is_empty():
		errors.append("display_name is required")
	match offer_type:
		OfferType.STAT:
			if stat_index < 0 or stat_index > 2:
				errors.append("stat_index must be 0(damage)/1(max_health)/2(move_speed)")
			if stat_amount <= 0.0:
				errors.append("stat_amount must be positive")
		OfferType.HEAL:
			if heal_amount <= 0.0:
				errors.append("heal_amount must be positive")
		OfferType.WEAPON:
			if weapon_id.is_empty():
				errors.append("weapon_id is required")
		OfferType.PASSIVE:
			if passive_id.is_empty():
				errors.append("passive_id is required")
		OfferType.AMMO:
			if ammo_amount <= 0:
				errors.append("ammo_amount must be positive")
		OfferType.WEAPON_MOD:
			if weapon_mod_id.is_empty():
				errors.append("weapon_mod_id is required")
			elif WeaponModTable.MOD_IDS.find(weapon_mod_id) < 0:
				errors.append("weapon_mod_id is not in WeaponModTable.MOD_IDS: %s" % weapon_mod_id)
			if weapon_mod_stacks <= 0:
				errors.append("weapon_mod_stacks must be positive")
		OfferType.OIL:
			if oil_amount <= 0:
				errors.append("oil_amount must be positive")
		_:
			errors.append("offer_type is invalid")
	return errors

## 改装件在 WeaponModTable 里的下标；不是改装件或 id 不认识时返回 -1。
## SimWorld.grant_weapon_mod() 认的是下标，商品存的是稳定的 StringName 身份。
func weapon_mod_index() -> int:
	if offer_type != OfferType.WEAPON_MOD:
		return -1
	return WeaponModTable.MOD_IDS.find(weapon_mod_id)
