extends SceneTree

## 角色目录的源码级校验。
##
## 目录里的 id 是**跨线传输**的：它会进 join / roster / start 三种消息。
## 一个重复的 id 意味着两台客户端把同一个字符串解析成不同的角色，
## 一个不合法的 id 会被服务端的形状校验静默丢弃——两种都不会当场报错，
## 只会在对局里表现成「别人的颜色和我看到的不一样」。所以在这里挡住。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_character_catalog.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

const EXPECTED_CHARACTER_IDS: Array[StringName] = [
	&"male_assault",
	&"female_assault",
	&"male_gunner",
	&"female_gunner",
	&"male_medic",
	&"female_medic",
	&"male_demolition",
	&"female_demolition",
	&"male_riot",
	&"female_riot",
]
const RETIRED_CHARACTER_IDS: Array[StringName] = [
	&"survivor_red", &"survivor_blue", &"survivor_amber", &"survivor_green",
]

## 允许的被动 id。与 character_definition.gd 的注释保持一致。
const VALID_PASSIVE_IDS := [&"", &"suppression", &"fortify", &"medic_aura", &"blast_armor"]
## 允许的本命武器 id。必须覆盖 resources/weapons/*.tres 的 weapon_id。
const VALID_SIGNATURE_WEAPONS := [&"", &"knife", &"pistol", &"smg", &"shotgun", &"rifle"]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.characters()
	_expect(catalog != null, "角色目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return

	_expect(
		catalog.entries.size() == EXPECTED_CHARACTER_IDS.size(),
		"角色目录必须恰好有 %d 个角色，实际 %d" % [
			EXPECTED_CHARACTER_IDS.size(), catalog.entries.size()
		],
		failures
	)

	var seen := {}
	var seen_colors := {}
	for definition in catalog.entries:
		_expect(definition != null, "角色目录里不允许有空条目", failures)
		if definition == null:
			continue
		var id := String(definition.character_id)
		_expect(
			LobbyProtocolScript.is_valid_content_id(id),
			"角色 id %s 不符合 ^[a-z0-9_]{1,%d}$" % [
				id, LobbyProtocolScript.CONTENT_ID_MAX_LENGTH
			],
			failures
		)
		_expect(not seen.has(id), "角色 id %s 重复" % id, failures)
		seen[id] = true
		_expect(
			definition.display_name.strip_edges() != "",
			"角色 %s 缺少显示名" % id,
			failures
		)
		_expect(
			definition.model_scene != null,
			"角色 %s 缺少 model_scene" % id,
			failures
		)
		# 配色是四个人在场上唯一的区分手段，撞色等于没做区分。
		var color_key := "%d_%d_%d" % [
			roundi(definition.accent_color.r * 255.0),
			roundi(definition.accent_color.g * 255.0),
			roundi(definition.accent_color.b * 255.0),
		]
		_expect(
			not seen_colors.has(color_key),
			"角色 %s 的配色与 %s 相同" % [id, seen_colors.get(color_key, "")],
			failures
		)
		seen_colors[color_key] = id
		# 三围与被动/本命武器合法性：这些值会进联机（角色各端从同一目录解析），
		# 非法值不报错只会在对局里表现成「技能不触发/武器没加成」。
		_expect(
			definition.move_speed_mult > 0.0 and definition.move_speed_mult <= 2.0,
			"角色 %s 的 move_speed_mult 超出 (0, 2]：%f" % [
				id, definition.move_speed_mult
			],
			failures
		)
		_expect(
			definition.signature_weapon_damage_mult >= 0.5 and definition.signature_weapon_damage_mult <= 3.0,
			"角色 %s 的 signature_weapon_damage_mult 超出 [0.5, 3]：%f" % [
				id, definition.signature_weapon_damage_mult
			],
			failures
		)
		_expect(
			VALID_PASSIVE_IDS.has(definition.passive_id),
			"角色 %s 的 passive_id '%s' 不在允许集合内" % [
				id, definition.passive_id
			],
			failures
		)
		_expect(
			VALID_SIGNATURE_WEAPONS.has(definition.signature_weapon_id),
			"角色 %s 的 signature_weapon_id '%s' 不是已知武器" % [
				id, definition.signature_weapon_id
			],
			failures
		)

	var actual_ids := catalog.ids()
	_expect(
		actual_ids == EXPECTED_CHARACTER_IDS,
		"角色目录顺序必须为 %s，实际 %s" % [EXPECTED_CHARACTER_IDS, actual_ids],
		failures
	)
	for retired_id in RETIRED_CHARACTER_IDS:
		_expect(
			catalog.get_by_id(retired_id) == null,
			"退役角色 id %s 必须返回 null" % retired_id,
			failures
		)

	_expect(
		catalog.has_id(catalog.default_id()),
		"默认角色 id %s 必须存在于目录中" % catalog.default_id(),
		failures
	)
	_expect(
		catalog.get_by_id(&"__missing__") == null,
		"未知 id 必须返回 null 而不是回退到默认角色",
		failures
	)

	# 循环切换必须能走遍每一个角色再回到起点，否则卡片上的左右箭头会漏掉角色。
	var walked := {}
	var cursor: StringName = catalog.default_id()
	for _index in range(catalog.entries.size()):
		walked[String(cursor)] = true
		cursor = catalog.next_id(cursor, 1)
	_expect(
		walked.size() == catalog.entries.size(),
		"next_id 循环只走到 %d 个角色，目录里有 %d 个" % [
			walked.size(), catalog.entries.size()
		],
		failures
	)
	_expect(
		cursor == catalog.default_id(),
		"next_id 走满一圈后必须回到起点",
		failures
	)
	_expect(
		catalog.next_id(catalog.default_id(), -1) == catalog.entries[catalog.entries.size() - 1].character_id,
		"next_id 向前一步必须从第一个角色绕到最后一个",
		failures
	)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_character_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_character_catalog: %s" % failure)
	printerr("validate_character_catalog: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
