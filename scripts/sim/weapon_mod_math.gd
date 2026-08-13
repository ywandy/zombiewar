extends RefCounted
class_name WeaponModMath

## 把「基础武器档案 + 某个座位的改装层数」派生成「这个座位实际生效的武器档案」。
##
## 纯函数、零副作用、只做整数运算。属于模拟层，禁用 sin/cos/atan2/pow。
##
## 【为什么按 mod_id 升序叠加，而不是按获取顺序】
## 玩家 A 先捡穿甲后捡分裂、玩家 B 反过来，两人身上的改装件集合相同，就必须
## 打出完全相同的伤害。按获取历史累乘会让两人结果不同——而这在单人测试里
## 100% 测不出来，只有联机对局里两个人对着同一只僵尸打出不同血量时才暴露。
## 层数存的是「有几层」而不是「按什么顺序拿的」，正是为了消除这个自由度。
##
## 【为什么整数千分比而不是浮点】
## 浮点连乘的结合律不跨平台保证，`pow()` 走平台 libm。千分比整数乘除在所有
## 平台上逐位一致，代价只是精度截断——而截断本身是确定的，因此无害。

const WeaponModTableScript = preload("res://scripts/sim/weapon_mod_table.gd")

## 千分比缩放。整数运算，截断方向固定为向零取整。
static func _scale_permille(value: int, permille: int) -> int:
	return value * permille / 1000


## 派生一个座位实际生效的武器档案。
##
## base   —— SimWorld.configure_weapon_profile() 产出的那个字典，键必须完整。
## levels —— SimWorld.player_mod_level，展平的 [slot * COUNT + mod_id] 字节数组。
## offset —— slot * COUNT。
##
## 返回值与 base **同构**（同样的键、同样的值类型）。没有任何改装时返回 base 本身，
## 这既是零开销的快路径，也是「装了改装系统但没捡到东西时行为逐位不变」的依据。
static func derive_profile(
	base: Dictionary,
	levels: PackedByteArray,
	offset: int
) -> Dictionary:
	if base.is_empty():
		return base
	var count := WeaponModTableScript.COUNT
	if levels.size() < offset + count:
		return base
	var any_level := false
	for mod_id in range(count):
		if levels[offset + mod_id] > 0:
			any_level = true
			break
	if not any_level:
		return base

	# 转成整数中间量。散布三项用毫度（1 度 = 1000），伤害与射程用千分比基数。
	var damage_permille := int(round(float(base["damage"]) * 1000.0))
	var range_permille := int(round(float(base["attack_range"]) * 1000.0))
	var base_spread_mdeg := int(round(float(base["base_spread_degrees"]) * 1000.0))
	var max_spread_mdeg := int(round(float(base["max_spread_degrees"]) * 1000.0))
	var increase_mdeg := int(round(float(base["spread_increase_degrees"]) * 1000.0))
	var recovery_mdeg := int(round(
		float(base["spread_recovery_degrees_per_second"]) * 1000.0
	))
	var pellet_count := int(base["pellet_count"])
	var penetration_count := int(base["max_penetration_count"])
	var penetration_coef_permille := int(round(
		float(base["penetration_damage_coefficient"]) * 1000.0
	))

	for mod_id in range(count):
		var level := int(levels[offset + mod_id])
		if level <= 0:
			continue
		level = mini(level, WeaponModTableScript.MAX_STACKS[mod_id])
		for _stack in range(level):
			damage_permille = _scale_permille(
				damage_permille, WeaponModTableScript.DAMAGE_PERMILLE[mod_id]
			)
			range_permille = _scale_permille(
				range_permille, WeaponModTableScript.RANGE_PERMILLE[mod_id]
			)
			base_spread_mdeg = _scale_permille(
				base_spread_mdeg, WeaponModTableScript.BASE_SPREAD_PERMILLE[mod_id]
			)
			max_spread_mdeg = _scale_permille(
				max_spread_mdeg, WeaponModTableScript.MAX_SPREAD_PERMILLE[mod_id]
			)
			increase_mdeg = _scale_permille(
				increase_mdeg, WeaponModTableScript.INCREASE_PERMILLE[mod_id]
			)
			recovery_mdeg = _scale_permille(
				recovery_mdeg, WeaponModTableScript.RECOVERY_PERMILLE[mod_id]
			)
			base_spread_mdeg += WeaponModTableScript.BASE_SPREAD_ADD_MDEG[mod_id]
			pellet_count += WeaponModTableScript.PELLET_ADD[mod_id]
			penetration_count += WeaponModTableScript.PENETRATION_ADD[mod_id]
			# 穿透衰减单独处理：多数武器基础系数为 0，纯乘法永远抬不起来。
			if WeaponModTableScript.PENETRATION_ADD[mod_id] > 0:
				if penetration_coef_permille < WeaponModTableScript.PENETRATION_COEF_FLOOR:
					penetration_coef_permille = WeaponModTableScript.PENETRATION_COEF_FLOOR
				else:
					penetration_coef_permille += WeaponModTableScript.PENETRATION_COEF_ADD

	# 还原并重新施加 configure_weapon_profile 的全部夹取。
	# max_spread 那条不能漏：CHOKE 压 max、MATCHED 压 base，两者叠加会让上限低于
	# 基础值，散布状态机会在一个倒挂的区间里演化。
	var derived_base_spread := maxf(float(base_spread_mdeg) / 1000.0, 0.0)
	var derived_max_spread := maxf(float(max_spread_mdeg) / 1000.0, derived_base_spread)
	return {
		"damage": maxf(float(damage_permille) / 1000.0, 0.0),
		"attack_range": maxf(float(range_permille) / 1000.0, 0.0),
		"base_spread_degrees": derived_base_spread,
		"max_spread_degrees": derived_max_spread,
		"spread_increase_degrees": maxf(float(increase_mdeg) / 1000.0, 0.0),
		"spread_recovery_degrees_per_second": maxf(float(recovery_mdeg) / 1000.0, 0.0),
		"max_penetration_count": clampi(penetration_count, 0, 16),
		"penetration_damage_coefficient": clampf(
			float(penetration_coef_permille) / 1000.0, 0.0, 1.0
		),
		"pellet_count": clampi(pellet_count, 1, 32),
		# 暂时没有改装件影响暴击，但这两项**必须原样带出来**：这个函数是重新
		# 构造字典而不是改副本，漏掉的键会在玩家捡到第一个改装件的那一刻从
		# profile 里消失，现象是「一开局能暴击，捡了个配件之后再也不暴了」。
		"crit_chance_per_10000": int(base.get("crit_chance_per_10000", 0)),
		"crit_multiplier_permille": int(base.get("crit_multiplier_permille", 1000)),
	}
