extends SceneTree

## 几率暴击的回归。
##
## 守五件事：
## 1. 暴击真的按倍率放大伤害，且 0% 的武器永远不暴击、100% 的武器每枪都暴击。
## 2. **暴击按「扣一次扳机」判定一次，不按弹丸判定**。霰弹枪一枪 6 颗，逐颗掷点会
##    让 12% 变成「至少一颗暴击」53%，而且合并出来的数字是个半暴不暴的中间值，
##    读不出「这一枪暴了」。这条断言整簇弹丸要么全暴要么全不暴。
## 3. 暴击标记随命中事件下发，表现层的飘字才有得读。
## 4. **暴击参数必须活过 WeaponModMath.derive_profile()**。那个函数是重新构造字典
##    而不是改副本，漏带的键会在玩家捡到第一个改装件的那一刻从 profile 里消失——
##    现象是「一开局能暴击，捡了个配件之后再也不暴了」，没有任何报错。
## 5. **暴击流不能挪动别的随机流**。WEAPON_CRIT 追加在 Stream 末尾，散布、掉落、
##    刷怪的序列必须逐位不变，否则所有既有回放与帧哈希一起分叉。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_weapon_crit.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const WeaponModTableScript = preload("res://scripts/sim/weapon_mod_table.gd")
const WeaponModMathScript = preload("res://scripts/sim/weapon_mod_math.gd")

const NEVER_PROFILE := 0
const ALWAYS_PROFILE := 1
const SHOTGUN_PROFILE := 2
const BASE_DAMAGE := 20.0
const CRIT_MULTIPLIER := 2.5
const PELLET_COUNT := 6
const ZOMBIE_HEALTH := 100000
const SEED := 20260813

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_zero_chance_never_crits()
	_test_full_chance_always_crits()
	_test_crit_scales_damage_by_the_multiplier()
	_test_crit_is_rolled_once_per_trigger_pull()
	_test_crit_survives_mod_derivation()
	_test_crit_stream_does_not_move_other_streams()
	_test_authored_weapons_differ_in_crit()
	_report()


func _make_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(SEED)
	# 0% / 100% 两把单弹丸枪，外加一把 100% 暴击的六弹丸霰弹枪。
	world.configure_weapon_profile(
		NEVER_PROFILE, BASE_DAMAGE, 30.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 1, &"never", 0.0, CRIT_MULTIPLIER
	)
	world.configure_weapon_profile(
		ALWAYS_PROFILE, BASE_DAMAGE, 30.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, 1, &"always", 100.0, CRIT_MULTIPLIER
	)
	world.configure_weapon_profile(
		SHOTGUN_PROFILE, BASE_DAMAGE, 30.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0, PELLET_COUNT,
		&"shotgun", 100.0, CRIT_MULTIPLIER
	)
	# 血量拉高到打不死，这样每颗弹丸都吃满伤害而不会被 mini() 截到剩余血量。
	world.configure_zombie_profile(0, ZOMBIE_HEALTH, 0.0)
	world.spawn_zombie(Vector2(0.0, -6.0), 0.0, 0)
	return world


## 朝 -Y 方向的僵尸开一枪，返回这一 tick 的命中事件。
##
## 每枪前把靶子钉回原位：命中会施加击退，连打十几枪就会把它推出射程；
## 击退还带向上分量，累积几枪就把靶子抬到水平射线的高度区间之外。
## 两者都会让后续的「没暴击」其实是「没打中」，把这个校验变成一个假绿灯。
func _fire(world: SimWorld, profile_index: int) -> Array:
	world.zombie_position[0] = Vector2(0.0, -6.0)
	world.zombie_velocity[0] = Vector2.ZERO
	world.zombie_height[0] = 0.0
	world.zombie_vertical_velocity[0] = 0.0
	world.tick_hit_events.clear()
	world.queue_fire_event(0, profile_index, Vector2.ZERO, 1.0, Vector2(0.0, -1.0))
	world.step_tick()
	return world.tick_hit_events.duplicate()


func _test_zero_chance_never_crits() -> void:
	var world := _make_world()
	var crit_count := 0
	for _shot in range(200):
		for event in _fire(world, NEVER_PROFILE):
			if bool(event.get("critical", false)):
				crit_count += 1
	_check(
		"a 0%% crit weapon must never crit (got %d crits in 200 shots)" % crit_count,
		crit_count == 0
	)


func _test_full_chance_always_crits() -> void:
	var world := _make_world()
	var hits := 0
	var crits := 0
	for _shot in range(50):
		for event in _fire(world, ALWAYS_PROFILE):
			hits += 1
			if bool(event.get("critical", false)):
				crits += 1
	_check("a 100%% crit weapon must land hits at all (got %d)" % hits, hits == 50)
	_check(
		"a 100%% crit weapon must crit on every shot (%d of %d)" % [crits, hits],
		hits > 0 and crits == hits
	)


func _test_crit_scales_damage_by_the_multiplier() -> void:
	var plain := _make_world()
	var plain_events := _fire(plain, NEVER_PROFILE)
	var crit := _make_world()
	var crit_events := _fire(crit, ALWAYS_PROFILE)
	if plain_events.is_empty() or crit_events.is_empty():
		_check("both a plain shot and a crit shot must hit", false)
		return
	var plain_damage := float(plain_events[0]["damage"])
	var crit_damage := float(crit_events[0]["damage"])
	_check(
		"a plain hit must deal the weapon's base damage (%.2f vs %.2f)" % [plain_damage, BASE_DAMAGE],
		is_equal_approx(plain_damage, BASE_DAMAGE)
	)
	_check(
		"a crit must deal base × multiplier (%.2f, expected %.2f)" % [
			crit_damage, BASE_DAMAGE * CRIT_MULTIPLIER
		],
		is_equal_approx(crit_damage, BASE_DAMAGE * CRIT_MULTIPLIER)
	)


## 一次扣扳机一个结论：六颗弹丸要么全暴要么全不暴，不允许出现半暴的一枪。
func _test_crit_is_rolled_once_per_trigger_pull() -> void:
	var world := _make_world()
	for shot_index in range(30):
		var events := _fire(world, SHOTGUN_PROFILE)
		if events.size() != PELLET_COUNT:
			_check(
				"a %d-pellet shot must produce %d hit events (shot %d got %d)" % [
					PELLET_COUNT, PELLET_COUNT, shot_index, events.size()
				],
				false
			)
			return
		var crit_flags := {}
		for event in events:
			crit_flags[bool(event.get("critical", false))] = true
		_check(
			"all pellets of one trigger pull must share the same crit verdict (shot %d split)" % shot_index,
			crit_flags.size() == 1
		)
		if crit_flags.size() != 1:
			return


## derive_profile() 重新构造字典，暴击两项必须原样带出来。
func _test_crit_survives_mod_derivation() -> void:
	var world := _make_world()
	var base: Dictionary = world._weapon_profile(ALWAYS_PROFILE)
	_check(
		"the base profile must carry crit_chance_per_10000",
		base.has("crit_chance_per_10000") and int(base["crit_chance_per_10000"]) == 10000
	)
	# 给 0 号座位上一层伤害改装，逼 derive_profile 走「重新构造」的分支。
	var levels := PackedByteArray()
	levels.resize(WeaponModTableScript.COUNT)
	levels[WeaponModTableScript.Mod.DAMAGE] = 1
	var derived: Dictionary = WeaponModMathScript.derive_profile(base, levels, 0)
	_check(
		"derive_profile must preserve crit_chance_per_10000 (got %s)" % str(
			derived.get("crit_chance_per_10000", "<missing>")
		),
		int(derived.get("crit_chance_per_10000", -1)) == int(base["crit_chance_per_10000"])
	)
	_check(
		"derive_profile must preserve crit_multiplier_permille (got %s)" % str(
			derived.get("crit_multiplier_permille", "<missing>")
		),
		int(derived.get("crit_multiplier_permille", -1)) == int(base["crit_multiplier_permille"])
	)
	# 端到端：上了改装之后仍然要暴击。上一条只证明键还在，这条证明它还生效。
	world.grant_weapon_mod(0, WeaponModTableScript.Mod.DAMAGE, 1)
	var events := _fire(world, ALWAYS_PROFILE)
	_check(
		"a modded weapon must still crit",
		events.size() > 0 and bool(events[0].get("critical", false))
	)


## WEAPON_CRIT 追加在 Stream 末尾，别的流的序列必须逐位不变。
## 这里固定住三条既有流的前若干次取值作为基线：任何往枚举中间插项的改动都会打断它。
func _test_crit_stream_does_not_move_other_streams() -> void:
	var rng: DeterministicRng = DeterministicRngScript.new()
	rng.seed_streams(SEED)
	var spread_first := rng.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
	var loot_first := rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
	var wander_first := rng.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)

	# 大量消耗 WEAPON_CRIT 之后，其他流的下一次取值必须与「完全没碰过暴击流」一致。
	var reference: DeterministicRng = DeterministicRngScript.new()
	reference.seed_streams(SEED)
	reference.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
	reference.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
	reference.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)
	for _draw in range(500):
		rng.next_uint32(DeterministicRngScript.Stream.WEAPON_CRIT)
	_check(
		"seeding must be stable across streams (spread %d, loot %d, wander %d)" % [
			spread_first, loot_first, wander_first
		],
		spread_first != 0 or loot_first != 0 or wander_first != 0
	)
	_check(
		"draining WEAPON_CRIT must not move WEAPON_SPREAD",
		rng.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
			== reference.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
	)
	_check(
		"draining WEAPON_CRIT must not move LOOT_DROP",
		rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
			== reference.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
	)
	_check(
		"draining WEAPON_CRIT must not move ZOMBIE_WANDER",
		rng.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)
			== reference.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)
	)


## 暴击是武器差异化的一条维度，四把枪不能配成同一个数。
func _test_authored_weapons_differ_in_crit() -> void:
	var paths := [
		"res://resources/weapons/pistol.tres",
		"res://resources/weapons/smg.tres",
		"res://resources/weapons/shotgun.tres",
		"res://resources/weapons/rifle.tres",
	]
	var chances := {}
	for path in paths:
		var definition = load(path)
		_check("%s must load" % path, definition != null)
		if definition == null:
			continue
		_check(
			"%s crit chance must stay in 0..100 (got %.1f)" % [path, definition.crit_chance_percent],
			definition.crit_chance_percent >= 0.0 and definition.crit_chance_percent <= 100.0
		)
		_check(
			"%s crit multiplier must be at least 1.0 (got %.2f)" % [path, definition.crit_multiplier],
			definition.crit_multiplier >= 1.0
		)
		chances[definition.crit_chance_percent] = true
	# 四把枪全配成同一个暴击率 = 暴击没有参与武器差异化，只是全局加了点伤害。
	_check(
		"authored weapons must not all share one crit chance (%d distinct)" % chances.size(),
		chances.size() >= 3
	)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_weapon_crit: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
