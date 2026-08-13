extends Resource
class_name PickupDefinition

const InventoryProfile = preload("res://scripts/gameplay/inventory/inventory_profile.gd")

enum RewardMode { EQUIPMENT, AMMO, WEAPON_MOD }

@export var reward_mode := RewardMode.EQUIPMENT
@export var item_id: StringName
@export_range(1, 9999, 1) var amount := 1
@export var auto_equip := false
@export var display_name := "补给"
@export var marker_color := Color.WHITE

@export_group("Inventory")
## 这些字段是稳定的 UI 身份；它们不等同于 MapRuntime 按资源路径建立的
## reward_profile_index。后者只在当前地图运行期存在并进入模拟。
@export var inventory_category := InventoryProfile.Category.WEAPON
@export var inventory_key: StringName = &""
@export_range(0, 9999, 1) var inventory_max_stack := 1
@export var inventory_weapon_id: StringName = &""
@export var inventory_mod_id: StringName = &""

@export_group("Weapon Mod")
## 改装件 id，必须是 WeaponModTable.MOD_IDS 里的一项。
## 只有 reward_mode == WEAPON_MOD 时才读；效果由模拟层在拾取判定当场施加，
## 表现层不参与兑现（见 grant_to 的说明）。
@export var weapon_mod_id: StringName = &""
@export_range(1, 8, 1) var weapon_mod_stacks := 1

@export_group("Presentation")
## 地上掉落物的外观。留空则用默认的补给箱模型。
## 纯表现字段：模拟层只认 reward_profile_index，永远不读这里。
## **必须是 res://assets/ 下的资源** —— docs/ 被 Web 导出排除，引用它会在编辑器和
## headless 里一路通过、却在导出的 pck 里丢失模型（validate 会挡下）。
@export var view_scene: PackedScene
@export_range(0.3, 4.0, 0.05) var view_scale := 1.0
## 地面标签上跟在名字后面的一行效果说明。带代价的改装件必须把代价写进来，
## 否则玩家只会觉得"我捡了个东西然后变菜了"。
@export_multiline var effect_text := ""

func is_weapon_mod() -> bool:
	return reward_mode == RewardMode.WEAPON_MOD and not weapon_mod_id.is_empty()

func get_inventory_category() -> int:
	return inventory_category

func get_inventory_key() -> StringName:
	return inventory_key

func get_inventory_max_stack() -> int:
	return inventory_max_stack

## 竞技场的拾取路径**不再走这里**：奖励由 SimWorld.accept_reward() 记进背包账本，
## 再由背包镜像落到装备节点上（见 EquipmentController.apply_inventory_snapshot）。
## 本方法只留给不带模拟层的工具与校验脚本，改它不会影响正常对局。
func grant_to(player: PlayerController, amount_override: int = -1) -> bool:
	# 改装件的效果已经由 SimWorld._resolve_chest_claims() 在拾取判定当场施加了，
	# 表现层这里什么都不做。这条路径顺带绕开了一个历史坑：表现层兑现是「可能失败
	# 而模拟层不知情」的（SimWorld 刻意不提供 release_chest），把 gameplay 效果挂
	# 在这里必然让各端分叉。返回 true 只是告诉调用方"这次拾取有效"。
	if is_weapon_mod():
		return true
	var grant_amount := amount if amount_override < 0 else amount_override
	if player == null or not player.is_alive() or item_id.is_empty() or grant_amount <= 0:
		return false
	match reward_mode:
		RewardMode.EQUIPMENT:
			return player.receive_equipment_pickup(item_id, grant_amount, auto_equip)
		RewardMode.AMMO:
			return player.receive_ammo_pickup(item_id, grant_amount)
	return false

func get_label_text(amount_override: int = -1) -> String:
	if is_weapon_mod():
		if effect_text.is_empty():
			return display_name
		return "%s\n%s" % [display_name, effect_text]
	var label_amount := amount if amount_override < 0 else amount_override
	return "%s +%d" % [display_name, label_amount]
