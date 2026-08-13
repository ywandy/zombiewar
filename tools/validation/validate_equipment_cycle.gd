extends SceneTree

const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const PlaceableEquipment = preload("res://scripts/player/placeable_equipment.gd")
const PlayerEquipmentLabel = preload("res://scripts/ui/player_equipment_label.gd")
const FakeEquipmentItem = preload("res://tools/validation/support/fake_equipment_item.gd")
const FakePlaceItemService = preload("res://tools/validation/support/fake_place_item_service.gd")
const OilBarrelEquipmentScene = preload("res://scenes/player/equipment/OilBarrelEquipment.tscn")
const PistolScene = preload("res://scenes/weapons/Pistol.tscn")
const SmgScene = preload("res://scenes/weapons/Smg.tscn")
const KnifeScene = preload("res://scenes/weapons/Knife.tscn")

func _init() -> void:
	var failures: Array[String] = []
	_test_cycle_skips_empty_items(failures)
	_test_depletion_switches_to_next_item(failures)
	_test_placeable_inventory_changes_only_on_success(failures)
	_test_placeable_direction_configuration(failures)
	_test_oil_barrel_rear_direction_configuration(failures)
	_test_smg_pickup_grants_owner_ammo_and_auto_equips(failures)
	_test_oil_barrel_pickup_caps_per_player_inventory(failures)
	_test_equipment_label_count_text_contract(failures)
	_test_inventory_mirror_drives_equipment(failures)
	_test_local_shot_prediction_reconciles(failures)
	_test_demo_map_uses_place_item_service(failures)
	if failures.is_empty():
		print("validate_equipment_cycle: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_cycle_skips_empty_items(failures: Array[String]) -> void:
	var controller = _build_controller([
		_build_equipment_scene("手枪", -1, true),
		_build_equipment_scene("空物品", 0, false),
		_build_equipment_scene("刀", -1, true),
	], 0)
	_expect(controller.get_current_display_name() == "手枪", "starting equipment must be selected", failures)
	_expect(controller.equip_next(), "next equipment must be selectable", failures)
	_expect(controller.get_current_display_name() == "刀", "next must skip zero-count equipment", failures)
	_expect(controller.equip_previous(), "previous equipment must be selectable", failures)
	_expect(controller.get_current_display_name() == "手枪", "previous must wrap and skip zero-count equipment", failures)
	controller.free()

func _test_depletion_switches_to_next_item(failures: Array[String]) -> void:
	var controller = _build_controller([
		_build_equipment_scene("油桶", 1, true),
		_build_equipment_scene("手枪", -1, true),
	], 0)
	var depleted_item = controller.get_current_item()
	depleted_item.consume_last()
	_expect(controller.get_current_display_name() == "手枪", "depleted current item must switch automatically", failures)
	controller.free()

func _test_placeable_inventory_changes_only_on_success(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var placeable := PlaceableEquipment.new()
	var requester := CharacterBody3D.new()
	var visual_root := Node3D.new()
	var ray_origin := Marker3D.new()
	placeable.add_child(requester)
	placeable.add_child(visual_root)
	placeable.add_child(ray_origin)
	placeable.initial_count = 2
	placeable.item_scene = _build_node_scene()
	placeable.set_place_item_service(service)
	placeable.bind_context(requester, visual_root, ray_origin)
	# 装备节点自己不再扣数量、也不再直接落地：它只把「放哪一格」抬给上层走帧，
	# 扣账与建桶由竞技场按帧统一做（联机下各端必须放出同一个桶）。
	var raised: Array[Dictionary] = []
	placeable.set_sim_request_sink(func(request: Dictionary) -> void: raised.append(request))
	service.next_result = false
	placeable.set_use_input(false, true, Vector3.FORWARD)
	_expect(raised.is_empty(), "a rejected placement must not raise a request", failures)
	_expect(
		placeable.get_remaining_count() == 2,
		"a rejected placement must not touch the mirrored count",
		failures
	)
	service.next_result = true
	placeable.set_use_input(false, true, Vector3.FORWARD)
	_expect(raised.size() == 1, "an accepted placement must raise exactly one request", failures)
	if raised.size() == 1:
		_expect(
			raised[0].get("kind") == &"place_item" and raised[0].get("cell") == service.next_cell,
			"the placement request must carry the resolved grid cell",
			failures
		)
	_expect(
		placeable.get_remaining_count() == 2,
		"the placeable must not spend its own count -- the ledger owns it",
		failures
	)
	_expect(service.request_count == 2, "placeable must issue one request per use edge", failures)
	placeable.free()
	service.free()

func _test_placeable_direction_configuration(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var placeable := PlaceableEquipment.new()
	placeable.initial_count = 2
	placeable.item_scene = _build_node_scene()
	placeable.set_place_item_service(service)
	_expect(
		"placement_direction_scale" in placeable,
		"PlaceableEquipment must expose placement_direction_scale",
		failures
	)
	placeable.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(0.6, 0.0, -0.8)),
		"placeable equipment must preserve aim direction by default",
		failures
	)
	placeable.free()
	service.free()

func _test_oil_barrel_rear_direction_configuration(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var oil_barrel := OilBarrelEquipmentScene.instantiate() as PlaceableEquipment
	_expect(oil_barrel != null, "OilBarrelEquipment scene must instantiate as PlaceableEquipment", failures)
	if oil_barrel == null:
		service.free()
		return
	oil_barrel.set_place_item_service(service)
	oil_barrel.add_count(1)
	oil_barrel.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(-0.6, 0.0, 0.8)),
		"OilBarrelEquipment scene must reverse aim direction",
		failures
	)
	oil_barrel.free()
	service.free()

func _test_smg_pickup_grants_owner_ammo_and_auto_equips(
	failures: Array[String]
) -> void:
	var controller = _build_controller([
		PistolScene,
		SmgScene,
		KnifeScene,
		OilBarrelEquipmentScene,
	], 0)
	_expect(
		controller.has_method(&"get_item_by_id") and
		controller.has_method(&"grant_item") and
		controller.has_method(&"add_ammo"),
		"EquipmentController must expose item pickup and ammo entry points",
		failures
	)
	if not controller.has_method(&"get_item_by_id"):
		controller.free()
		return
	var smg = controller.call("get_item_by_id", &"smg")
	_expect(smg != null, "smg must retain a stable equipment item id", failures)
	if smg == null:
		controller.free()
		return
	_expect(not smg.is_available(), "smg must start unowned", failures)
	_expect(
		int(controller.call("add_ammo", &"smg", 30)) == 0,
		"unowned smg must reject ammo pickups",
		failures
	)
	_expect(
		bool(controller.call("grant_item", &"smg", 400, true)),
		"smg pickup must grant ownership or ammo",
		failures
	)
	_expect(smg.is_available(), "smg pickup must grant smg ownership", failures)
	_expect(
		controller.get_current_item() == smg,
		"auto-equipped smg pickup must select the smg slot",
		failures
	)
	_expect(
		smg.get_ammo_count() == 360,
		"smg pickup ammo must cap at the 360 round maximum",
		failures
	)
	_expect(
		not bool(controller.call("grant_item", &"smg", 1, false)),
		"full owned smg pickup must not report a consumed pickup",
		failures
	)
	controller.free()

func _test_oil_barrel_pickup_caps_per_player_inventory(
	failures: Array[String]
) -> void:
	var controller = _build_controller([OilBarrelEquipmentScene], 0)
	_expect(
		controller.has_method(&"get_item_by_id") and controller.has_method(&"grant_item"),
		"EquipmentController must expose item pickup lookup and grant entry points",
		failures
	)
	if not controller.has_method(&"get_item_by_id"):
		controller.free()
		return
	var oil_barrel = controller.call("get_item_by_id", &"oil_barrel")
	_expect(oil_barrel != null, "oil barrel must retain a stable equipment item id", failures)
	if oil_barrel == null:
		controller.free()
		return
	_expect(
		oil_barrel.get_remaining_count() == 0,
		"oil barrel inventory must start empty for each player",
		failures
	)
	_expect(
		bool(controller.call("grant_item", &"oil_barrel", 1000, false)),
		"oil barrel pickup must increase inventory",
		failures
	)
	_expect(
		oil_barrel.get_remaining_count() == 999,
		"oil barrel inventory must cap at 999 per player",
		failures
	)
	_expect(
		not bool(controller.call("grant_item", &"oil_barrel", 1, false)),
		"full oil barrel inventory must not report a consumed pickup",
		failures
	)
	controller.free()

func _test_equipment_label_count_text_contract(failures: Array[String]) -> void:
	var controller = _build_controller([
		PistolScene,
		SmgScene,
		KnifeScene,
		OilBarrelEquipmentScene,
	], 0)
	_expect(
		controller.has_method(&"get_current_count_text"),
		"EquipmentController must expose count text for HUD consumers",
		failures
	)
	if controller.has_method(&"get_current_count_text"):
		_expect(
			String(controller.call("get_current_count_text")) == "∞",
			"the default pistol label count must use the unlimited marker",
			failures
		)
	var smg = controller.get_item_by_id(&"smg")
	_expect(smg != null and smg.has_method(&"get_count_text"), "ranged weapons must expose count text", failures)
	if smg != null and smg.has_method(&"get_count_text"):
		smg.receive_pickup(12)
		_expect(
			smg.get_count_text() == "12",
			"finite ranged weapons must expose their current ammo as text",
			failures
		)
	var knife = controller.get_item_by_id(&"knife")
	_expect(knife.has_method(&"get_count_text"), "equipment items must expose count text", failures)
	if knife.has_method(&"get_count_text"):
		_expect(
			knife.get_count_text() == "—",
			"equipment without inventory must use the em dash marker",
			failures
		)
	var oil_barrel = controller.get_item_by_id(&"oil_barrel")
	_expect(oil_barrel.has_method(&"get_count_text"), "placeable equipment must expose count text", failures)
	if oil_barrel.has_method(&"get_count_text"):
		oil_barrel.receive_pickup(3)
		_expect(
			oil_barrel.get_count_text() == "3",
			"placeable equipment must expose its remaining inventory as text",
			failures
		)
	var label := PlayerEquipmentLabel.new()
	label.call("set_status", 0, "手枪", "∞")
	_expect(label.text == "P1 · 手枪:∞", "labels must append non-empty count text with a colon", failures)
	label.call("set_status", 3, "倒地", "")
	_expect(label.text == "P4 · 倒地", "labels must omit an empty count text", failures)
	label.free()
	controller.free()

## 装备节点不记账：拥有哪把枪、几发子弹、几个油桶全部由模拟层快照决定。
## profile 表与 SimWorld.configure_inventory_profiles() 吃的是同一种字典。
func _mirror_profiles() -> Array[Dictionary]:
	return [
		{"category": 0, "max_stack": 1, "weapon_id": &"pistol", "mod_id": -1},
		{"category": 0, "max_stack": 1, "weapon_id": &"smg", "mod_id": -1},
		{"category": 1, "max_stack": 360, "weapon_id": &"smg", "mod_id": -1},
		{"category": 1, "max_stack": 0, "weapon_id": &"pistol", "mod_id": -1},
		{"category": 2, "max_stack": 999, "weapon_id": &"", "mod_id": -1},
	]

func _test_inventory_mirror_drives_equipment(failures: Array[String]) -> void:
	var controller = _build_controller([
		PistolScene,
		SmgScene,
		KnifeScene,
		OilBarrelEquipmentScene,
	], 0)
	_expect(
		controller.has_method(&"bind_inventory_profiles")
		and controller.has_method(&"apply_inventory_snapshot"),
		"EquipmentController must accept a simulation inventory mirror",
		failures
	)
	if not controller.has_method(&"apply_inventory_snapshot"):
		controller.free()
		return
	controller.bind_inventory_profiles(_mirror_profiles())
	var smg = controller.get_item_by_id(&"smg")
	var oil = controller.get_item_by_id(&"oil_barrel")
	_expect(not smg.is_available(), "smg must start unowned before any snapshot", failures)

	# 槽位 0=手枪、1=SMG、2=SMG 弹药 30、3=油桶 2。其余为空。
	controller.apply_inventory_snapshot(
		PackedInt32Array([0, 1, 2, 4, -1, -1, -1, -1, -1, -1, -1, -1]),
		PackedInt32Array([1, 1, 30, 2, 0, 0, 0, 0, 0, 0, 0, 0])
	)
	_expect(smg.is_available(), "a weapon in the ledger must become owned", failures)
	_expect(smg.get_ammo_count() == 30, "ammo must follow the ledger", failures)
	_expect(oil.get_remaining_count() == 2, "oil must follow the ledger", failures)
	_expect(controller.equip_item(&"smg"), "a ledger-owned weapon must be equippable", failures)
	_expect(controller.get_current_item() == smg, "equipping must select the smg", failures)

	# 账本里没有 SMG 了：镜像必须把它收走，而不是留着上一份状态。
	# 它此刻正拿在手上，所以这一步同时守「手上的东西被收走要自动换枪」。
	controller.apply_inventory_snapshot(
		PackedInt32Array([0, -1, -1, 4, -1, -1, -1, -1, -1, -1, -1, -1]),
		PackedInt32Array([1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0])
	)
	_expect(not smg.is_available(), "a weapon missing from the ledger must be revoked", failures)
	_expect(
		controller.get_current_item() != smg,
		"a revoked weapon must not stay in hand",
		failures
	)
	var pistol = controller.get_item_by_id(&"pistol")
	_expect(
		pistol.get_count_text() == "∞",
		"an unlimited weapon must not be zeroed by its capacity-0 ammo profile",
		failures
	)
	controller.free()

## 本地开火先扣、模拟层兑现后抵消。没有这一步，扳机与数字之间会空一拍；
## 抵消错了则会一路少算，把玩家的子弹越显示越少。
func _test_local_shot_prediction_reconciles(failures: Array[String]) -> void:
	var controller = _build_controller([PistolScene, SmgScene], 0)
	controller.bind_inventory_profiles(_mirror_profiles())
	var smg = controller.get_item_by_id(&"smg")
	controller.apply_inventory_snapshot(
		PackedInt32Array([0, 1, 2, -1, -1, -1, -1, -1, -1, -1, -1, -1]),
		PackedInt32Array([1, 1, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	)
	_expect(
		smg.has_method(&"apply_authoritative_ammo"),
		"ranged weapons must accept an authoritative ammo count",
		failures
	)
	if not smg.has_method(&"apply_authoritative_ammo"):
		controller.free()
		return
	_expect(smg.try_consume_ammo(), "firing must be allowed with ammo in the ledger", failures)
	_expect(smg.get_ammo_count() == 29, "a local shot must show immediately", failures)
	# 这一枪还没进模拟层：账本仍是 30，显示值必须保持预扣后的 29。
	smg.apply_authoritative_ammo(30)
	_expect(
		smg.get_ammo_count() == 29,
		"an unresolved local shot must survive an unchanged ledger",
		failures
	)
	# 账本兑现了这一枪：预扣被抵消，不能再扣一次变成 28。
	smg.apply_authoritative_ammo(29)
	_expect(
		smg.get_ammo_count() == 29,
		"a resolved local shot must be cancelled, not counted twice",
		failures
	)
	smg.apply_authoritative_ammo(29)
	_expect(smg.get_ammo_count() == 29, "a settled ledger must stay put", failures)
	# 捡到子弹：账本上涨要照原样显示。
	smg.apply_authoritative_ammo(89)
	_expect(smg.get_ammo_count() == 89, "a ledger credit must show in full", failures)
	controller.free()

func _test_demo_map_uses_place_item_service(failures: Array[String]) -> void:
	var scene := load("res://scenes/maps/demo/DemoMap.tscn") as PackedScene
	_expect(scene != null, "DemoMap scene must load", failures)
	if scene == null:
		return
	var arena := scene.instantiate()
	_expect(arena.get_script() != null, "GameplayArena root script must compile", failures)
	_expect(
		arena.get_node_or_null("PlaceItemService") != null,
		"GameplayArena must expose PlaceItemService",
		failures
	)
	var detached_team_state := arena.get("local_team_state") as Node
	arena.free()
	if detached_team_state != null and is_instance_valid(detached_team_state):
		detached_team_state.free()

func _build_controller(loadout: Array[PackedScene], starting_slot: int):
	var controller := EquipmentController.new()
	var wielder := CharacterBody3D.new()
	var visual_root := Node3D.new()
	var ray_origin := Marker3D.new()
	controller.add_child(wielder)
	controller.add_child(visual_root)
	controller.add_child(ray_origin)
	controller.loadout = loadout
	controller.starting_slot = starting_slot
	controller.setup(wielder, visual_root, ray_origin)
	return controller

func _build_equipment_scene(name: String, count: int, available: bool) -> PackedScene:
	var item := FakeEquipmentItem.new()
	item.display_name = name
	item.remaining_count = count
	item.available = available
	var scene := PackedScene.new()
	scene.pack(item)
	item.free()
	return scene

func _build_node_scene() -> PackedScene:
	var node := Node3D.new()
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	return scene

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
