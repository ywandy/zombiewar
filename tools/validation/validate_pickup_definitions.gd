extends SceneTree

const PICKUP_DEFINITION_PATH := "res://scripts/gameplay/pickup_definition.gd"
const PICKUP_CHEST_SCENE_PATH := "res://scenes/gameplay/PickupChest.tscn"

class RecordingPlayer extends PlayerController:
	var equipment_calls: Array[Dictionary] = []
	var ammo_calls: Array[Dictionary] = []
	var alive := true

	func is_alive() -> bool:
		return alive

	func receive_equipment_pickup(
		item_id: StringName,
		amount: int,
		auto_equip: bool = false
	) -> bool:
		equipment_calls.append({
			"item_id": item_id,
			"amount": amount,
			"auto_equip": auto_equip,
		})
		return true

	func receive_ammo_pickup(item_id: StringName, amount: int) -> bool:
		ammo_calls.append({"item_id": item_id, "amount": amount})
		return true

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(
		ResourceLoader.exists(PICKUP_DEFINITION_PATH),
		"PickupDefinition script must exist",
		failures
	)
	_expect(
		ResourceLoader.exists(PICKUP_CHEST_SCENE_PATH),
		"PickupChest scene must exist",
		failures
	)
	if not failures.is_empty():
		_finish(failures)
		return
	var definition_script = load(PICKUP_DEFINITION_PATH)
	var chest_scene := load(PICKUP_CHEST_SCENE_PATH) as PackedScene
	_expect(definition_script != null, "PickupDefinition script must load", failures)
	_expect(chest_scene != null, "PickupChest scene must load", failures)
	if definition_script == null or chest_scene == null:
		_finish(failures)
		return
	_test_amount_override_contract(definition_script, chest_scene, failures)
	_test_equipment_definition_grants_configured_reward(definition_script, failures)
	_test_ammo_definition_grants_configured_reward(definition_script, failures)
	await _test_chest_configuration_and_empty_definition(definition_script, chest_scene, failures)
	await _test_chest_view_claim_lifecycle(definition_script, chest_scene, failures)
	_finish(failures)

func _test_amount_override_contract(
	definition_script,
	chest_scene: PackedScene,
	failures: Array[String]
) -> void:
	var definition = definition_script.new()
	definition.reward_mode = definition.RewardMode.EQUIPMENT
	definition.item_id = &"oil_barrel"
	definition.amount = 30
	definition.display_name = "油桶"
	var player := RecordingPlayer.new()
	if _method_argument_count(definition, &"grant_to") != 2:
		failures.append("PickupDefinition.grant_to must accept an amount override")
	elif _method_argument_count(definition, &"get_label_text") != 1:
		failures.append("PickupDefinition.get_label_text must accept an amount override")
	else:
		_expect(
			bool(definition.callv(&"grant_to", [player, 7])),
			"amount override must remain grantable",
			failures
		)
		_expect(
			player.equipment_calls == [{
				"item_id": &"oil_barrel",
				"amount": 7,
				"auto_equip": false,
			}],
			"amount override must replace the Definition amount",
			failures
		)
		_expect(
			definition.callv(&"get_label_text", [7]) == "油桶 +7",
			"amount override must replace the label amount",
			failures
		)
	var chest = chest_scene.instantiate()
	if _method_argument_count(chest, &"configure") != 2:
		failures.append("PickupChest.configure must accept an amount override")
	else:
		chest.callv(&"configure", [definition, 7])
		_expect(
			"reward_amount" in chest and chest.reward_amount == 7,
			"PickupChest must retain the simulated reward amount",
			failures
		)
		_expect(
			chest.get_reward_label_text() == "油桶 +7",
			"PickupChest label must use the simulated reward amount",
			failures
		)
	chest.free()
	player.free()

func _method_argument_count(object: Object, method_name: StringName) -> int:
	for method in object.get_method_list():
		if method.get("name") == method_name:
			return (method.get("args", []) as Array).size()
	return -1

func _test_equipment_definition_grants_configured_reward(
	definition_script,
	failures: Array[String]
) -> void:
	var definition = definition_script.new()
	definition.reward_mode = definition.RewardMode.EQUIPMENT
	definition.item_id = &"smg"
	definition.amount = 60
	definition.auto_equip = true
	definition.display_name = "冲锋枪"
	var player := RecordingPlayer.new()
	_expect(
		definition.grant_to(player),
		"equipment Definition must grant its configured reward",
		failures
	)
	_expect(
		player.equipment_calls == [{
			"item_id": &"smg",
			"amount": 60,
			"auto_equip": true,
		}],
		"equipment Definition must forward item id, amount, and auto-equip",
		failures
	)
	_expect(player.ammo_calls.is_empty(), "equipment Definition must not grant ammo", failures)
	_expect(
		definition.get_label_text() == "冲锋枪 +60",
		"Definition label must use display name and amount",
		failures
	)
	player.free()

func _test_ammo_definition_grants_configured_reward(
	definition_script,
	failures: Array[String]
) -> void:
	var definition = definition_script.new()
	definition.reward_mode = definition.RewardMode.AMMO
	definition.item_id = &"smg"
	definition.amount = 30
	var player := RecordingPlayer.new()
	_expect(
		definition.grant_to(player),
		"ammo Definition must grant its configured reward",
		failures
	)
	_expect(
		player.ammo_calls == [{"item_id": &"smg", "amount": 30}],
		"ammo Definition must forward item id and amount",
		failures
	)
	_expect(player.equipment_calls.is_empty(), "ammo Definition must not grant equipment", failures)
	player.free()

func _test_chest_configuration_and_empty_definition(
	definition_script,
	chest_scene: PackedScene,
	failures: Array[String]
) -> void:
	var definition = definition_script.new()
	definition.item_id = &"oil_barrel"
	definition.amount = 2
	definition.display_name = "油桶"
	definition.marker_color = Color(0.20, 0.90, 0.35, 1.0)
	var chest = chest_scene.instantiate()
	_expect("definition" in chest, "PickupChest must expose definition", failures)
	_expect(chest.has_method("configure"), "PickupChest must expose configure", failures)
	if not ("definition" in chest) or not chest.has_method("configure"):
		chest.free()
		return
	chest.configure(definition)
	_expect(chest.definition == definition, "configure must retain the Definition", failures)
	_expect(
		chest.get_reward_label_text() == "油桶 +2",
		"configured chest must expose the Definition label",
		failures
	)
	root.add_child(chest)
	await process_frame
	_expect(
		chest.reward_label.modulate.is_equal_approx(definition.marker_color),
		"configured chest label must use Definition marker color",
		failures
	)
	var empty_chest = chest_scene.instantiate()
	_expect(
		empty_chest.get_reward_label_text() == "未配置补给",
		"unconfigured chest must show an explicit label",
		failures
	)
	empty_chest.free()
	chest.queue_free()
	await process_frame

func _test_chest_view_claim_lifecycle(
	definition_script,
	chest_scene: PackedScene,
	failures: Array[String]
) -> void:
	var definition = definition_script.new()
	definition.item_id = &"smg"
	definition.amount = 1
	definition.auto_equip = true
	var chest = chest_scene.instantiate()
	chest.configure(definition, 4)
	root.add_child(chest)
	await process_frame
	var player := RecordingPlayer.new()
	var monitoring_disabled_on_exit := [false]
	var claim_area: Area3D = chest.claim_area
	claim_area.tree_exiting.connect(
		func() -> void: monitoring_disabled_on_exit[0] = not claim_area.monitoring
	)
	_expect(
		not claim_area.monitoring,
		"PickupChest view must not decide claims from physics overlaps",
		failures
	)
	# 连调两次：第二次必须是空操作（claim_locked），否则一个箱子能被领两回。
	chest.claim_by(player)
	chest.claim_by(player)
	# 领取的货已经由 SimWorld.accept_reward() 记进背包账本，表现层再发一次就是
	# 第二本账——「捡满弹药后再也捡不到子弹」正是两本账各自演化的结果。
	_expect(
		player.equipment_calls.is_empty() and player.ammo_calls.is_empty(),
		"simulated claim must not grant rewards outside the simulation ledger",
		failures
	)
	_expect(chest.claim_locked, "simulated claim must lock the view", failures)
	_expect(
		chest.is_queued_for_deletion(),
		"simulated claim must queue the view for deletion",
		failures
	)
	await process_frame
	_expect(
		not is_instance_valid(chest),
		"claimed chest view must be freed after the presentation lifecycle completes",
		failures
	)
	_expect(
		monitoring_disabled_on_exit[0],
		"claimed view must keep claim-area monitoring disabled through cleanup",
		failures
	)
	player.free()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_pickup_definitions: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
