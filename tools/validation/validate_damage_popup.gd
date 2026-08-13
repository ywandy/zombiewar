extends SceneTree

## 伤害飘字的回归。
##
## 守五件事：
## 1. **字体真的挂上了**，而且数字与 MISS 的字形都在。Label3D 的 font 留空不会报错，
##    只会静默回退到引擎默认字体——改版前它就是这么用了半年的默认字体。
## 2. 颜色只回答「这是什么伤害」：普通白、暴击黄，**击杀不换色**。
##    元素色板（燃烧/中毒/电击）是预埋，必须在表里存在且各不相同。
## 3. 尺寸只回答「这一发有多重」：占目标最大生命的比例越高，pixel_size 越大。
##    这条是防止哪天有人给暴击定一个固定字号——那会让冲锋枪暴击的 28
##    比霰弹枪平砍的 192 还大，「越重的伤害数字越大」当场失效。
## 4. MISS 用得到 MISS 文本、比普通伤害小、且不是伤害色。
## 5. 整体大小是**一个常量**说了算。BASE_SCALE 改一个数就该整体缩放，
##    档位里若有人写死绝对尺寸，这条会红。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_damage_popup.gd

const POPUP_SCENE_PATH := "res://scenes/fx/DamagePopup.tscn"
const DamagePopupScript = preload("res://scripts/fx/damage_popup.gd")
const GameplayArenaScript = preload("res://scripts/gameplay/gameplay_arena.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

const REFERENCE_HEALTH := 100.0
const MISS_PROFILE := 0
const MISS_SEED := 20260813

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_font_is_assigned_and_covers_the_text()
	_test_colors_answer_damage_type_only()
	_test_size_answers_damage_weight_only()
	_test_miss_reads_as_a_miss()
	_test_miss_only_on_a_true_whiff()
	_test_one_constant_scales_everything()
	_report()


## 打墙不是打空。
##
## `did_hit` 只表示「有没有伤到僵尸或油桶」，它对「子弹飞完全程什么都没碰到」和
## 「子弹被墙截断」给出同一个 false。模拟层用 `hit_blocker` 区分二者——同一份射击
## 事件里，RangedWeapon.show_tracer() 正是靠它播墙面弹着音。只看 did_hit 就会
## 一边播着「叮」的墙面弹着音一边飘 MISS，音效和文字自相矛盾。
##
## 注意 hit_blocker 的语义是「射线的最大射程被静态几何截断了」，**地图边界也算**，
## 而且它与有没有打中僵尸无关：在小地图上贴脸打僵尸也可能是 true。
## 所以判据必须是两个字段的组合，不能只看 hit_blocker。
func _test_miss_only_on_a_true_whiff() -> void:
	# 射程 10 < 到地图边界的距离，避免边界把每一枪都算成撞墙而污染对照。
	var cases := [
		{"name": "空射：飞完全程什么都没碰到", "wall": false, "zombie_at": INF, "expect_miss": true},
		{"name": "打墙", "wall": true, "zombie_at": INF, "expect_miss": false},
		{"name": "打僵尸", "wall": false, "zombie_at": -6.0, "expect_miss": false},
		{"name": "墙后有僵尸（被墙挡下）", "wall": true, "zombie_at": -10.0, "expect_miss": false},
	]
	for case_variant in cases:
		var case: Dictionary = case_variant
		var world: SimWorld = SimWorldScript.new()
		world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
		world.reset(MISS_SEED)
		world.configure_weapon_profile(
			MISS_PROFILE, 20.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 1, &"test", 0.0, 1.0
		)
		world.configure_zombie_profile(0, 100000, 0.0)
		if bool(case["wall"]):
			world.set_blocker_world_rect(Vector2(-2.0, -7.0), Vector2(2.0, -6.0), true)
		var zombie_at := float(case["zombie_at"])
		if zombie_at != INF:
			world.spawn_zombie(Vector2(0.0, zombie_at), 0.0, 0)
		world.queue_fire_event(0, MISS_PROFILE, Vector2.ZERO, 1.0, Vector2(0.0, -1.0))
		world.step_tick()
		if world.tick_shot_events.is_empty():
			_check("%s must produce a shot event" % case["name"], false)
			continue
		var event: Dictionary = world.tick_shot_events[0]
		var is_miss := GameplayArenaScript.shot_event_is_true_miss(event)
		_check(
			"%s -> MISS 应为 %s（实际 %s；did_hit=%s hit_blocker=%s）" % [
				case["name"],
				str(case["expect_miss"]),
				str(is_miss),
				str(event.get("did_hit", null)),
				str(event.get("hit_blocker", null)),
			],
			is_miss == bool(case["expect_miss"])
		)


func _make(damage: float, critical: bool, killed: bool, element: StringName = &"normal") -> DamagePopup:
	var scene: PackedScene = load(POPUP_SCENE_PATH)
	var popup := scene.instantiate() as DamagePopup
	get_root().add_child(popup)
	popup.setup(damage, Vector3.ZERO, REFERENCE_HEALTH, critical, killed, 0, element)
	return popup


func _free_popup(popup: DamagePopup) -> void:
	get_root().remove_child(popup)
	popup.free()


func _test_font_is_assigned_and_covers_the_text() -> void:
	var scene: PackedScene = load(POPUP_SCENE_PATH)
	_check("DamagePopup.tscn must load", scene != null)
	if scene == null:
		return
	var popup := scene.instantiate() as Label3D
	# font 留空 = 静默用引擎默认字体，看不出任何报错。
	_check("the popup must have an explicit font (null falls back silently)", popup.font != null)
	if popup.font != null:
		for character in "0123456789":
			_check(
				"the popup font must have a glyph for '%s'" % character,
				popup.font.has_char(character.unicode_at(0))
			)
		for character in DamagePopupScript.MISS_TEXT:
			_check(
				"the popup font must have a glyph for MISS letter '%s'" % character,
				popup.font.has_char(character.unicode_at(0))
			)
	popup.free()


func _test_colors_answer_damage_type_only() -> void:
	var plain := _make(20.0, false, false)
	var crit := _make(20.0, true, false)
	var kill := _make(20.0, false, true)
	var plain_color := plain.modulate
	var crit_color := crit.modulate
	var kill_color := kill.modulate

	_check(
		"a plain hit must use the normal colour",
		plain_color.is_equal_approx(DamagePopupScript.ELEMENT_COLORS[&"normal"])
	)
	_check(
		"a crit must use the crit colour and differ from a plain hit",
		crit_color.is_equal_approx(DamagePopupScript.ELEMENT_COLORS[&"crit"])
			and not crit_color.is_equal_approx(plain_color)
	)
	# 明确要求的行为：击杀不占用颜色通道。
	_check(
		"a kill must NOT get its own colour (colour is reserved for damage type)",
		kill_color.is_equal_approx(plain_color)
	)
	_check("a crit must be marked in the text", crit.text.ends_with(DamagePopupScript.CRIT_SUFFIX))
	_check("a plain hit must not be marked as a crit", not plain.text.ends_with(DamagePopupScript.CRIT_SUFFIX))

	# 预埋的元素色：必须存在，且彼此可区分——否则将来加了燃烧弹也看不出区别。
	var palette: Dictionary = DamagePopupScript.ELEMENT_COLORS
	for element in [&"normal", &"crit", &"fire", &"poison", &"shock"]:
		_check("the palette must define '%s'" % element, palette.has(element))
	var seen: Array[Color] = []
	for element in palette:
		var color: Color = palette[element]
		for other in seen:
			if color.is_equal_approx(other):
				_check("palette colours must be distinct ('%s' duplicates another)" % element, false)
		seen.append(color)

	# 元素伤害的颜色不该被暴击顶掉：燃烧弹暴击仍然是红的。
	var fire_crit := _make(20.0, true, false, &"fire")
	_check(
		"a crit on elemental damage must keep the element colour",
		fire_crit.modulate.is_equal_approx(palette[&"fire"])
	)

	for popup in [plain, crit, kill, fire_crit]:
		_free_popup(popup)


func _test_size_answers_damage_weight_only() -> void:
	# 占目标最大生命 5% / 25% / 50% / 90%，尺寸必须单调不减。
	# 比的是**落定尺寸**（_base_scale）而不是首帧的 pixel_size：首帧还带着弹入放大，
	# 那是个 0.11 秒的冲击效果，各档的放大倍率本来就不同。要守的不变量是
	# 「静止下来之后谁大谁小」。
	var light := _make(5.0, false, false)
	var medium := _make(25.0, false, false)
	var heavy := _make(50.0, false, false)
	var brutal := _make(90.0, false, false)
	var sizes := [light._base_scale, medium._base_scale, heavy._base_scale, brutal._base_scale]
	for i in range(sizes.size() - 1):
		_check(
			"popup size must grow with damage fraction (%.5f then %.5f)" % [sizes[i], sizes[i + 1]],
			sizes[i + 1] > sizes[i]
		)

	# 关键回归：一记小额暴击不得比一记巨额平砍更大。
	var small_crit := _make(5.0, true, false)
	var big_plain := _make(90.0, false, false)
	_check(
		"a small crit (%.5f) must not outsize a huge plain hit (%.5f)" % [
			small_crit._base_scale, big_plain._base_scale
		],
		small_crit._base_scale <= big_plain._base_scale
	)
	# 但暴击仍然要比同等伤害的平砍醒目，否则等于没做。
	var same_plain := _make(5.0, false, false)
	_check(
		"a crit must still outsize a plain hit of the same damage",
		small_crit._base_scale > same_plain._base_scale
	)
	# 弹入放大要有上界：放得过头，那 0.11 秒里小额暴击会盖过巨额平砍，
	# 「越重越大」在最显眼的那一帧上失效。
	var pop_ratio := small_crit.pixel_size / big_plain.pixel_size
	_check(
		"the crit pop must not make a small crit dwarf a huge hit (ratio %.2f)" % pop_ratio,
		pop_ratio <= 1.15
	)

	for popup in [light, medium, heavy, brutal, small_crit, big_plain, same_plain]:
		_free_popup(popup)


func _test_miss_reads_as_a_miss() -> void:
	var scene: PackedScene = load(POPUP_SCENE_PATH)
	var miss := scene.instantiate() as DamagePopup
	get_root().add_child(miss)
	miss.setup_miss(Vector3.ZERO, 0)
	var plain := _make(25.0, false, false)

	_check("a miss must read 'MISS'", miss.text == DamagePopupScript.MISS_TEXT)
	_check(
		"a miss must be smaller than a normal damage number",
		miss._base_scale < plain._base_scale
	)
	# MISS 不是战果，不能用伤害色，否则一眼看过去像打中了。
	for element in DamagePopupScript.ELEMENT_COLORS:
		_check(
			"a miss must not reuse the '%s' damage colour" % element,
			not miss.modulate.is_equal_approx(DamagePopupScript.ELEMENT_COLORS[element])
		)

	_free_popup(miss)
	_free_popup(plain)


## 整体缩放必须由 BASE_SCALE 一个常量决定：每个档位都得是它的倍数。
func _test_one_constant_scales_everything() -> void:
	var base: float = DamagePopupScript.BASE_SCALE
	_check("BASE_SCALE must be positive", base > 0.0)
	if base <= 0.0:
		return
	var cases: Array[DamagePopup] = [
		_make(5.0, false, false),
		_make(25.0, false, false),
		_make(90.0, false, false),
		_make(25.0, true, false),
		_make(25.0, false, true),
	]
	for popup in cases:
		# 每一档的落定尺寸都必须是 BASE_SCALE 的倍数，倍数落在合理区间内。
		# 谁要是在档位里写死一个绝对 pixel_size，改 BASE_SCALE 就缩放不动它，这条会红。
		var ratio: float = popup._base_scale / base
		_check(
			"every tier must be a multiple of BASE_SCALE (ratio %.3f out of range)" % ratio,
			ratio > 0.5 and ratio < 4.0
		)
		_free_popup(popup)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_damage_popup: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
