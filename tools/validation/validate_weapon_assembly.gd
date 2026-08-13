extends SceneTree

## 武器装配矩阵的回归：每一把武器都跑同一组「枪做出来了，但装错了」的检查。
##
## 这一类缺陷的共同点是**静默**：代码路径全部跑通、伤害正常结算、也不报任何错，
## 只是画面上枪火飘在枪管外、或者换枪之后手里空着。单元测试抓不到，
## 「功能实现了吗」这个问题也答不出来，所以只能靠装配契约本身来守。
##
## 检查表来自 weapon-qa skill，全部是**几何与资源契约**，不做像素比对：
## 要判断枪火有没有对准枪口，必须先知道枪口的正确位置，而那个真值只能从
## 独立武器模型的 MuzzleSocket.global_transform 算出来——一旦算出来了，直接比 transform
## 就比截图更准，截图那一步只会引入分辨率、抗锯齿与粒子随机偏移的噪声。
##
## 武器清单取自 Player 的 EquipmentController.loadout，不是硬编码：
## 新增一把枪挂进 loadout 就自动纳入检查，这正是本脚本存在的意义。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_weapon_assembly.gd

const PlayerScene := preload("res://scenes/player/Player.tscn")
const PistolScene := preload("res://scenes/weapons/Pistol.tscn")
const CharacterProbeScene := preload("res://tools/fixtures/character_model_probe.tscn")
const ArenaScript := preload("res://scripts/gameplay/gameplay_arena.gd")
const CHARACTER_MODEL_PATH := "res://scenes/player/PlayerVisual.tscn"
const RangedWeaponDefinitionScript = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)

var failures: Array[String] = []


func _initialize() -> void:
	var player := PlayerScene.instantiate()
	root.add_child(player)
	# 等 @onready / _ready / bind_context 全部完成，武器才真正装配好。
	await process_frame
	await process_frame

	var equipment := player.get_node_or_null("EquipmentController")
	if equipment == null:
		failures.append("EquipmentController missing from Player")
		_report(player)
		return

	_test_loadout_is_authored(equipment)
	var model_node_names := _collect_character_model_node_names()
	_check(
		"character model node names must be readable",
		not model_node_names.is_empty()
	)

	var weapons := _collect_weapons(equipment)
	_check("player loadout must contain weapons", not weapons.is_empty())
	var independent_visual_probe := CharacterProbeScene.instantiate() as Node3D
	root.add_child(independent_visual_probe)
	for weapon in weapons:
		# Player.tscn 的 fallback 仍是只含内嵌武器的旧角色；它没有新角色契约里的
		# WeaponHandSocket。独立表现必须在带 socket 的角色上验证，legacy 表现则继续
		# 保持原绑定，以覆盖旧模型节点名的兼容路径。
		if weapon.definition != null and weapon.definition.visual_scene != null:
			weapon.bind_context(
				player,
				independent_visual_probe,
				player.get_node("FunctionalRayOrigin") as Marker3D
			)
		_test_weapon(weapon, model_node_names)
	_test_independent_visual_mount(player)
	_test_simulation_registration(weapons)
	independent_visual_probe.free()

	_report(player)


## 每一把能开火的枪都必须在竞技场的武器档案表里。
##
## 漏注册不会报任何错：get_weapon_profile_index() 返回 -1，_on_sim_request() 直接
## return，那把枪的每一次开火都被静默丢弃。而枪口火光与射击音是表现层自己播的，
## 照常出现——于是现象是「枪举得起来、有声有光、就是打不死任何东西」，
## 看起来像伤害数值配错了，实际上那一枪根本没进过模拟层。
func _test_simulation_registration(weapons: Array) -> void:
	var arena = ArenaScript.new()
	arena.register_weapon_profiles()
	for weapon in weapons:
		if not (weapon is RangedWeapon):
			continue
		var weapon_id: StringName = weapon.definition.weapon_id
		var profile_index: int = arena.get_weapon_profile_index(weapon_id)
		_check(
			"%s: weapon_id '%s' must be registered in GameplayArena.register_weapon_profiles()" % [
				weapon.name, weapon_id
			],
			profile_index >= 0
		)
	# arena 的团队状态是独立 Node，不跟着 free() 走。
	var detached_team_state = arena.get("local_team_state")
	arena.free()
	if detached_team_state != null and is_instance_valid(detached_team_state):
		detached_team_state.free()


func _test_loadout_is_authored(equipment: Node) -> void:
	var loadout: Array = equipment.get("loadout")
	_check("EquipmentController exposes a loadout", loadout != null)
	if loadout == null:
		return
	for index in loadout.size():
		_check("loadout[%d] must be assigned" % index, loadout[index] != null)


func _collect_weapons(equipment: Node) -> Array:
	var weapons: Array = []
	for child in equipment.get_children():
		if child is WeaponBase:
			weapons.append(child)
	return weapons


## 角色模型自带每把枪的视觉节点（Knife / Pistol / Rifle / Shotgun / SMG），
## 武器场景本身只有逻辑与特效锚点，因此「视觉节点名」是装配链的真正接头。
func _collect_character_model_node_names() -> Dictionary:
	var names := {}
	var model_scene := load(CHARACTER_MODEL_PATH) as PackedScene
	if model_scene == null:
		return names
	var probe := model_scene.instantiate()
	for node in probe.find_children("*", "", true, false):
		names[node.name] = true
	names[probe.name] = true
	probe.free()
	return names


func _test_weapon(weapon: WeaponBase, model_node_names: Dictionary) -> void:
	var label := weapon.name
	var definition = weapon.definition
	_check("%s must carry a definition" % label, definition != null)
	if definition == null:
		return
	_check(
		"%s: definition exposes visual_scene" % label,
		_has_property(definition, &"visual_scene")
	)
	if not _has_property(definition, &"visual_scene"):
		return

	# 新角色优先挂载生成武器；旧角色仍由 visual_model_scene + WeaponSocket.L 回退。
	if definition.visual_scene != null:
		_check(
			"%s: weapon exposes visual_instance" % label,
			_has_property(weapon, &"visual_instance")
		)
		if not _has_property(weapon, &"visual_instance"):
			return
		_check(
			"%s: independent visual is instanced" % label,
			weapon.visual_instance != null
		)
		_check(
			"%s: independent visual is parented to hand socket" % label,
			weapon.visual_instance != null and
			weapon.visual_instance.get_parent().name == "WeaponHandSocket"
		)
	else:
		_check(
			"%s: fallback model scene must be assigned" % label,
			definition.visual_model_scene != null
		)
		_check(
			"%s: fallback visual resolves" % label,
			weapon.visual_anchor != null and is_instance_valid(weapon.visual_anchor)
		)
	_check(
		"%s: weapon_id must be set" % label,
		not String(definition.weapon_id).is_empty()
	)

	if not (weapon is RangedWeapon):
		return
	_test_ranged_weapon(weapon as RangedWeapon, label, definition)


func _test_independent_visual_mount(player: CharacterBody3D) -> void:
	var character_probe := CharacterProbeScene.instantiate() as Node3D
	root.add_child(character_probe)
	_check(
		"character exposes WeaponHandSocket",
		character_probe.find_child("WeaponHandSocket", true, false) != null
	)
	var weapon := PistolScene.instantiate() as WeaponBase
	root.add_child(weapon)
	weapon.definition = weapon.definition.duplicate()
	_check(
		"weapon definition exposes independent visual fields",
		_has_property(weapon.definition, &"visual_scene") and
		_has_property(weapon.definition, &"visual_transform")
	)
	_check(
		"weapon exposes visual_instance",
		_has_property(weapon, &"visual_instance")
	)
	if (
		not _has_property(weapon.definition, &"visual_scene") or
		not _has_property(weapon.definition, &"visual_transform") or
		not _has_property(weapon, &"visual_instance")
	):
		weapon.free()
		character_probe.free()
		return
	weapon.definition.visual_scene = CharacterProbeScene
	weapon.definition.visual_transform = Transform3D(
		Basis.from_euler(Vector3(0.1, 0.2, 0.3)),
		Vector3(0.2, 0.3, 0.4)
	)
	weapon.bind_context(
		player,
		character_probe,
		player.get_node("FunctionalRayOrigin") as Marker3D
	)
	_check("independent visual is instanced", weapon.visual_instance != null)
	if weapon.visual_instance != null:
		_check(
			"independent visual uses authored transform",
			weapon.visual_instance.transform.is_equal_approx(
				weapon.definition.visual_transform
			)
		)
		_check(
			"independent visual is parented to hand socket",
			weapon.visual_instance.get_parent().name == "WeaponHandSocket"
		)
	weapon.free()
	character_probe.free()


func _test_ranged_weapon(
	weapon: RangedWeapon,
	label: String,
	definition
) -> void:
	# 装配接头 2：枪口锚点。
	var muzzle := weapon.get_node_or_null("Muzzle")
	_check("%s: must expose a Muzzle node" % label, muzzle != null)
	if muzzle == null:
		return
	_check("%s: Muzzle must be a Marker3D" % label, muzzle is Marker3D)

	var flash := muzzle.get_node_or_null("MuzzleFlash") as Node3D
	_check("%s: MuzzleFlash must hang off the Muzzle" % label, flash != null)
	if flash != null:
		# 火光挂在枪口下就必须**坐在**枪口上。任何本地偏移都会让火光离开枪管，
		# 而这正是编辑器里随手拖一下就会留下、且没有任何报错的那类偏差。
		_check(
			"%s: MuzzleFlash must sit exactly on the muzzle (local transform identity)" % label,
			flash.transform.is_equal_approx(Transform3D.IDENTITY)
		)

	# 装配接头 3：解耦后的枪火必须跟随独立武器模型自己的前端挂点。
	# 功能弹道仍从通用 WeaponCollision 胶囊出发；两者职责不同，不能再强制重合。
	var visual_socket: Node3D
	if weapon.visual_anchor != null and is_instance_valid(weapon.visual_anchor):
		visual_socket = weapon.visual_anchor.find_child(
			"MuzzleSocket",
			true,
			false
		) as Node3D
	_check("%s: visual model must expose MuzzleSocket" % label, visual_socket != null)
	var visual_origin: Vector3 = weapon._sync_muzzle_to_weapon_front()
	var ray_origin: Vector3 = weapon.get_ray_origin()
	_check("%s: ray origin must be finite" % label, ray_origin.is_finite())
	_check("%s: visual muzzle origin must be finite" % label, visual_origin.is_finite())
	if visual_socket != null:
		_check(
			"%s: muzzle flash origin must equal MuzzleSocket" % label,
			(muzzle as Marker3D).global_position.is_equal_approx(
				visual_socket.global_position
			)
		)

	# 装配接头 4：枪口朝向压平到水平，与模拟层的 WeaponMath.flat_direction 一致。
	var muzzle_forward := -(muzzle as Marker3D).global_basis.z
	_check(
		"%s: muzzle must aim flat to match simulated ballistics (y=%.4f)" % [label, muzzle_forward.y],
		absf(muzzle_forward.y) < 0.001
	)

	var ranged_definition = definition as RangedWeaponDefinitionScript
	if ranged_definition == null:
		failures.append("%s: ranged weapon must use a RangedWeaponDefinition" % label)
		return

	_test_shot_audio(weapon, label, ranged_definition)
	_test_tracer_pool(weapon, label, ranged_definition)


## 连发时每一枪的尾音都要放得完。复音数不足的表现不是「没声音」，
## 而是每一枪都被下一枪硬切，枪听起来短一截——很容易被当成「音效素材不好」。
func _test_shot_audio(
	weapon: RangedWeapon,
	label: String,
	ranged_definition
) -> void:
	var shot_audio := weapon.get_node_or_null("ShotAudio") as AudioStreamPlayer3D
	_check("%s: must expose ShotAudio" % label, shot_audio != null)
	if shot_audio == null:
		return
	_check("%s: ShotAudio must have a stream" % label, shot_audio.stream != null)
	if shot_audio.stream == null:
		return
	var attacks_per_second: float = ranged_definition.attacks_per_second
	var required_voices := ceili(shot_audio.stream.get_length() * attacks_per_second)
	_check(
		"%s: needs %d voices at %.1f shots/s over a %.2fs sample, has %d" % [
			label,
			required_voices,
			attacks_per_second,
			shot_audio.stream.get_length(),
			shot_audio.max_polyphony,
		],
		shot_audio.max_polyphony >= required_voices
	)


## 曳光是池化复用的：池子比「一条曳光存活期间能打出的子弹数」还小时，
## 高射速武器会自己覆盖自己，画面上表现为扫射时曳光断续闪烁。
func _test_tracer_pool(
	weapon: RangedWeapon,
	label: String,
	ranged_definition
) -> void:
	_check(
		"%s: tracer pool must be prewarmed" % label,
		not weapon.tracer_pool.is_empty()
	)
	if weapon.tracer_pool.is_empty():
		return
	var tracer_lifetime := _tracer_lifetime(weapon.tracer_pool[0])
	if tracer_lifetime <= 0.0:
		return
	# 每颗弹丸画一条曳光，所以池子要按「弹丸数 × 存活期内能打出的发数」算。
	# 只按射速算的话，多弹丸武器会自己覆盖自己：一枪六条线里只剩最后几条。
	var pellets: int = ranged_definition.pellet_count
	var required_tracers := ceili(
		tracer_lifetime * ranged_definition.attacks_per_second
	) * pellets
	_check(
		"%s: needs %d tracers (%d pellets at %.1f shots/s over a %.2fs tracer life), has %d" % [
			label,
			required_tracers,
			pellets,
			ranged_definition.attacks_per_second,
			tracer_lifetime,
			weapon.tracer_pool.size(),
		],
		weapon.tracer_pool.size() >= required_tracers
	)


func _tracer_lifetime(tracer) -> float:
	for property_name in ["lifetime", "LIFETIME", "duration", "fade_seconds"]:
		var value = tracer.get(property_name)
		if value != null and value is float and value > 0.0:
			return value
	var script := tracer.get_script() as GDScript
	if script == null:
		return 0.0
	for constant_name in ["LIFETIME", "LIFETIME_SECONDS", "FADE_SECONDS", "DURATION"]:
		var constants := script.get_script_constant_map()
		if constants.has(constant_name) and constants[constant_name] is float:
			return float(constants[constant_name])
	return 0.0


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if property.name == property_name:
			return true
	return false


func _report(player: Node) -> void:
	if player != null and is_instance_valid(player):
		for candidate in player.find_children("*", "AudioStreamPlayer3D", true, false):
			var audio := candidate as AudioStreamPlayer3D
			audio.stop()
			audio.stream = null
		root.remove_child(player)
		player.free()
	if failures.is_empty():
		print("validate_weapon_assembly: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
