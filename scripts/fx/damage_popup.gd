extends Label3D
class_name DamagePopup

## 伤害数字飘字。命中瞬间生成，弹入 + 上飘 + 淡出，纯表现、不进模拟。
##
## 【两条正交的通道】
## 颜色回答「这是什么伤害」（普通 / 暴击 / 燃烧 / 中毒…），
## 尺寸回答「这一发有多重」（占目标最大生命的比例）。
## 两者分开之后，加一种新伤害类型只要往 ELEMENT_COLORS 加一行，不用重排档位；
## 调数字大小只要动 BASE_SCALE 一个数，不用逐档改色。
##
## 【为什么尺寸按占比而不按绝对伤害】
## 绝对阈值在这个游戏里不成立：手枪 35、步枪 45 恒高于任何固定阈值，冲锋枪 14、
## 霰弹枪单颗 16 恒低于——那样分出来的不是「这一发有多重」，而是「玩家现在拿的是
## 哪把枪」，一整局都不会变。按占比分档之后同一个数字会随对手变化：冲锋枪打普通
## 僵尸是中号，打坦克是小号，飘字因此顺带回答了「这把枪是不是这只僵尸的正确解法」。

## 【整体大小就改这一个数】
## 它是「普通伤害」的屏幕尺寸，其余档位与 MISS 都按它的倍数派生。
##
## 参考：这个游戏是俯视角横扫僵尸潮，同屏可能有几十个数字在飘。飘字一旦接近
## 僵尸本身的高度，它就不再是叠加在战斗上的信息，而是挡住战斗的东西——
## 判断标准是「一眼扫过去先看见僵尸还是先看见数字」，应当是前者。
const BASE_SCALE := 0.0008

## 尺寸档：占目标最大生命的比例下界（从高到低匹配）+ BASE_SCALE 的倍数。
const TIER_CHIP := {"threshold": 0.0, "scale_mul": 0.85}
const TIER_NORMAL := {"threshold": 0.15, "scale_mul": 1.0}
const TIER_HEAVY := {"threshold": 0.35, "scale_mul": 1.2}
const TIER_BRUTAL := {"threshold": 0.7, "scale_mul": 1.45}
const TIERS := [TIER_BRUTAL, TIER_HEAVY, TIER_NORMAL, TIER_CHIP]
## 击杀只放大，**不换颜色**：颜色这条通道留给伤害类型。
## 「这只死了」本来就有尸体、死亡动画和顿帧在说，不需要飘字再说一遍。
##
## 放大倍率刻意压得比直觉低：它会和 KILL_POP_SCALE 相乘，1.6 × 1.4 = 2.24，
## 于是击杀那一帧的数字有基准的两倍多高，正好盖住僵尸本身。
## 两个倍率要一起看，不能各自单独调。
const KILL_SCALE_MUL := 1.35

## 伤害类型 -> 颜色。想加新类型就在这里加一行，再让命中事件带上对应的
## element 名即可，飘字这边不用改任何逻辑。
const ELEMENT_NORMAL: StringName = &"normal"
const ELEMENT_CRIT: StringName = &"crit"
const ELEMENT_FIRE: StringName = &"fire"
const ELEMENT_POISON: StringName = &"poison"
const ELEMENT_SHOCK: StringName = &"shock"
const ELEMENT_COLORS := {
	ELEMENT_NORMAL: Color(0.96, 0.97, 0.95),
	ELEMENT_CRIT: Color(1.0, 0.84, 0.18),
	# 以下三种是**预埋**：模拟层还没有元素伤害，命中事件也还不会带这些名字。
	# 等燃烧弹/毒/电击做出来时，只要在事件里填 element，这里立刻就有颜色。
	ELEMENT_FIRE: Color(1.0, 0.38, 0.16),
	ELEMENT_POISON: Color(0.56, 0.90, 0.30),
	ELEMENT_SHOCK: Color(0.45, 0.80, 1.0),
}

## 暴击：颜色由 ELEMENT_CRIT 给，尺寸在所属占比档上再放大并设下限。
##
## 不给暴击一个固定尺寸，是因为固定值必然和占比档打架：定得高了，冲锋枪暴击的
## 28 会比霰弹枪平砍的 192 还醒目，「越重的伤害数字越大」当场失效；定得低了，
## 暴击又淹没在普通伤害里。放大 + 下限同时满足两件事。
##
## 暴击只在 element 是 normal 时接管颜色：将来「燃烧弹暴击」应当仍然是红色，
## 那一发是不是暴击由放大和「!」后缀去说，而不是把伤害类型顶掉。
const CRIT_SCALE_BOOST := 1.2
const CRIT_MIN_SCALE_MUL := 1.15
const CRIT_SUFFIX := "!"

## 打空。灰、偏小、不飘那么高——它是「这一枪没打中」的确认，不是战果。
const MISS_TEXT := "MISS"
const MISS_SCALE_MUL := 0.8
const MISS_COLOR := Color(0.66, 0.70, 0.72)
const MISS_RISE_DISTANCE := 0.7
const MISS_LIFE_SECONDS := 0.45

## 描边宽度在场景里（outline_size = 7 @ font_size 64）。缩小飘字时描边要跟着收，
## 否则同样的描边在更小的字上会糊掉字形本身。
const OUTLINE_COLOR := Color(0.0, 0.0, 0.0, 0.8)

## 目标最大生命未知时的兜底基准（普通僵尸血量），保证占比永远算得出来。
const FALLBACK_REFERENCE_HEALTH := 50.0

## 飘升距离（世界单位），击杀与暴击飘得更高更久，留出读数时间。
const RISE_DISTANCE := 1.0
const LONG_RISE_DISTANCE := 1.4
## 存活总时长（秒）
const LIFE_SECONDS := 0.55
const LONG_LIFE_SECONDS := 0.8

## 弹入：出现瞬间放大再落回，让数字「砸」出来而不是淡淡浮现。
## 注意这些是**乘在档位倍率之上**的，峰值 = BASE_SCALE × 档位倍率 × 弹入倍率。
const POP_SECONDS := 0.11
const POP_SCALE := 1.15
const KILL_POP_SCALE := 1.25
const CRIT_POP_SCALE := 1.35

## 淡出前保持全不透明的时间比例。全程线性淡出会让数字在玩家视线转过来时
## 已经半透明了，读不到峰值。
const OPAQUE_RATIO := 0.45

## 同一只僵尸连续被打时（冲锋枪 10 发/秒）飘字会精确重叠成一坨。
## 按生成序号取横向偏移错开，纯表现层，不用随机数。
const LATERAL_OFFSETS := [0.0, 0.3, -0.24, 0.16, -0.36, 0.4, -0.12]
const SPAWN_HEIGHT_OFFSET := 1.2

var _life_remaining := 0.0
var _life_total := LIFE_SECONDS
var _rise_speed := 0.0
var _start_color := Color.WHITE
var _base_scale := BASE_SCALE
var _pop_scale := POP_SCALE
var _outline_alpha := OUTLINE_COLOR.a


## damage/max_health 都是显示单位（已除过 HEALTH_SCALE）。
## max_health <= 0 时退回基准血量；element 决定颜色，缺省即普通伤害；
## spawn_index 用于错开重叠飘字。
func setup(
	damage: float,
	world_position: Vector3,
	max_health: float,
	critical: bool,
	killed: bool,
	spawn_index: int = 0,
	element: StringName = ELEMENT_NORMAL
) -> void:
	_place(world_position, spawn_index)
	text = str(roundi(damage)) + (CRIT_SUFFIX if critical else "")

	var reference := max_health if max_health > 0.0 else FALLBACK_REFERENCE_HEALTH
	_base_scale = BASE_SCALE * _scale_multiplier(damage / reference, critical, killed)
	_start_color = _color_for(element, critical)

	if critical:
		_pop_scale = CRIT_POP_SCALE
	elif killed:
		_pop_scale = KILL_POP_SCALE
	else:
		_pop_scale = POP_SCALE

	# 暴击与击杀都延长停留：这两种是玩家要看清的那一次，0.55 秒读不完。
	var prominent := killed or critical
	_begin(
		LONG_LIFE_SECONDS if prominent else LIFE_SECONDS,
		LONG_RISE_DISTANCE if prominent else RISE_DISTANCE
	)


## 打空的飘字。没有伤害数值，也没有目标，落点是弹道终点。
func setup_miss(world_position: Vector3, spawn_index: int = 0) -> void:
	_place(world_position, spawn_index)
	text = MISS_TEXT
	_base_scale = BASE_SCALE * MISS_SCALE_MUL
	_start_color = MISS_COLOR
	_pop_scale = POP_SCALE
	_begin(MISS_LIFE_SECONDS, MISS_RISE_DISTANCE)


func _place(world_position: Vector3, spawn_index: int) -> void:
	var lateral: float = LATERAL_OFFSETS[posmod(spawn_index, LATERAL_OFFSETS.size())]
	global_position = world_position + Vector3(lateral, SPAWN_HEIGHT_OFFSET, 0.0)


func _begin(life_seconds: float, rise_distance: float) -> void:
	_life_total = life_seconds
	_life_remaining = life_seconds
	_rise_speed = rise_distance / life_seconds
	outline_modulate = OUTLINE_COLOR
	_outline_alpha = OUTLINE_COLOR.a
	modulate = _start_color
	pixel_size = _base_scale * _pop_scale


## 暴击只在普通伤害上接管颜色；带元素的伤害保留自己的颜色（见 CRIT_* 的说明）。
func _color_for(element: StringName, critical: bool) -> Color:
	var resolved := element
	if critical and resolved == ELEMENT_NORMAL:
		resolved = ELEMENT_CRIT
	return ELEMENT_COLORS.get(resolved, ELEMENT_COLORS[ELEMENT_NORMAL])


func _scale_multiplier(health_fraction: float, critical: bool, killed: bool) -> float:
	var multiplier := float(TIER_CHIP["scale_mul"])
	for tier in TIERS:
		if health_fraction >= float(tier["threshold"]):
			multiplier = float(tier["scale_mul"])
			break
	if killed:
		multiplier = maxf(multiplier, KILL_SCALE_MUL)
	if critical:
		multiplier = maxf(multiplier * CRIT_SCALE_BOOST, CRIT_MIN_SCALE_MUL)
	return multiplier


func _process(delta: float) -> void:
	if _life_remaining <= 0.0:
		return
	_life_remaining = maxf(_life_remaining - delta, 0.0)
	global_position.y += _rise_speed * delta
	var elapsed := _life_total - _life_remaining

	# 弹入：前 POP_SECONDS 从放大回落到基准尺寸。
	if elapsed < POP_SECONDS:
		pixel_size = _base_scale * lerpf(_pop_scale, 1.0, elapsed / POP_SECONDS)
	else:
		pixel_size = _base_scale

	# 先满亮持一段，再淡出；描边跟着一起淡，否则末尾会剩一圈黑边。
	var remaining_ratio := _life_remaining / _life_total
	var alpha := 1.0
	if remaining_ratio < OPAQUE_RATIO:
		alpha = remaining_ratio / OPAQUE_RATIO
	modulate = Color(_start_color.r, _start_color.g, _start_color.b, alpha)
	outline_modulate = Color(
		OUTLINE_COLOR.r, OUTLINE_COLOR.g, OUTLINE_COLOR.b, _outline_alpha * alpha
	)
	if _life_remaining <= 0.0:
		queue_free()
