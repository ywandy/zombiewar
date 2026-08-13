extends SceneTree

## 背包只有一本账：SimWorld 的槽位数组。
##
## 这个校验守的是**接线**，不是模拟层内部规则（那部分在 validate_inventory.gd）：
## 开局装备有没有记进账本、账本的变动有没有落到装备节点上、商店买的东西是不是
## 也走同一本账。这三处任何一处断掉，现象都不是崩溃，而是两份计数各自演化——
## 「捡满弹药后再也捡不到子弹」「买的枪不在背包里」都是这么来的。
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         --script res://tools/validation/validate_inventory_ledger_wiring.gd

const DEMO_MAP_PATH := "res://scenes/maps/demo/DemoMap.tscn"

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	# 新选角流程拒绝没有 character_id 的描述符；本校验只关心库存接线，
	# 因此显式建立一名目录默认角色，避免依赖其他校验留下的 GameSession 状态。
	var session = root.get_node_or_null("GameSession")
	if session != null:
		session.configure_single()
	var scene := load(DEMO_MAP_PATH) as PackedScene
	_check("DemoMap scene must load", scene != null)
	if scene == null:
		_finish()
		return
	var arena = scene.instantiate()
	root.add_child(arena)
	await process_frame
	await process_frame
	var world = arena.sim_world
	var players: Array = arena.players
	_check("arena must spawn at least one player", not players.is_empty())
	if players.is_empty():
		_finish()
		return
	var equipment = players[0].equipment

	_test_starting_loadout_is_seeded(world, equipment)
	_test_ledger_drives_equipment(arena, world, equipment)
	_test_firing_frees_pickup_capacity(arena, world, equipment)
	_test_shop_writes_the_ledger(arena, world, equipment)
	_test_placing_oil_debits_the_ledger(arena, world, equipment)
	_test_placement_arrives_over_the_frame_channel(arena, world, equipment)
	_finish()


## 开局自带的刀与手枪必须在账本里。漏了这一步，第一次镜像刷新就会把它们收走。
func _test_starting_loadout_is_seeded(world, equipment) -> void:
	for item_id in [&"pistol", &"knife"]:
		var profile_index: int = world.inventory_weapon_profile_index(item_id)
		_check("starting weapon '%s' must have an inventory profile" % item_id, profile_index >= 0)
		if profile_index < 0:
			continue
		_check(
			"starting weapon '%s' must be seeded into the ledger" % item_id,
			world.inventory_amount_of(0, profile_index) > 0
		)
		var item = equipment.get_item_by_id(item_id)
		_check("starting weapon '%s' must stay owned" % item_id, item != null and item.is_available())
	var smg = equipment.get_item_by_id(&"smg")
	_check("a weapon absent from the ledger must stay unowned", smg != null and not smg.is_available())


## 账本记一笔武器奖励，装备节点就该拿到枪和弹药——表现层不再自己发货。
func _test_ledger_drives_equipment(arena, world, equipment) -> void:
	var smg_profile: int = world.inventory_weapon_profile_index(&"smg")
	var ammo_profile: int = world.inventory_ammo_profile_index(&"smg")
	if smg_profile < 0 or ammo_profile < 0:
		_check("smg must have weapon and ammo inventory profiles", false)
		return
	world.accept_inventory(0, smg_profile, 60)
	arena._push_inventory_mirror(0)
	var smg = equipment.get_item_by_id(&"smg")
	_check("a credited weapon must become owned", smg.is_available())
	_check("a credited weapon must arrive with its ammo", smg.get_ammo_count() == 60)
	_check("the ledger must hold the same ammo", world.inventory_amount_of(0, ammo_profile) == 60)


## 用户报的那个 bug：捡满、打光之后必须还能再捡。
func _test_firing_frees_pickup_capacity(arena, world, equipment) -> void:
	var ammo_profile: int = world.inventory_ammo_profile_index(&"smg")
	var combat_profile: int = arena.get_weapon_profile_index(&"smg")
	_check("smg must be registered as a simulation weapon profile", combat_profile >= 0)
	if combat_profile < 0 or ammo_profile < 0:
		return
	world.accept_inventory(0, ammo_profile, 9999)
	arena._push_inventory_mirror(0)
	var smg = equipment.get_item_by_id(&"smg")
	var capacity: int = smg.get_max_ammo()
	_check("a full refill must reach the ledger cap", world.inventory_amount_of(0, ammo_profile) == capacity)
	_check("a full refill must reach the weapon", smg.get_ammo_count() == capacity)
	_check(
		"a full ammo stack must reject further pickups",
		not bool(world.accept_inventory(0, ammo_profile, 1).get("accepted", false))
	)
	world.queue_fire_event(0, combat_profile, Vector2.ZERO, 1.0, Vector2(0.0, -1.0))
	world.step_tick()
	arena._consume_sim_events()
	_check(
		"firing must debit the ledger, not only the weapon",
		world.inventory_amount_of(0, ammo_profile) == capacity - 1
	)
	_check(
		"a spent round must free capacity for the next pickup",
		bool(world.accept_inventory(0, ammo_profile, 1).get("accepted", false))
	)


## 商店买的枪与子弹也必须进账本，否则背包面板永远看不到它们。
func _test_shop_writes_the_ledger(arena, world, equipment) -> void:
	var weapon_profile: int = world.inventory_weapon_profile_index(&"shotgun")
	var ammo_profile: int = world.inventory_ammo_profile_index(&"shotgun")
	if weapon_profile < 0 or ammo_profile < 0:
		_check("shotgun must have weapon and ammo inventory profiles", false)
		return
	world.add_player_material(0, 1000)
	var material_before: int = world.get_player_material(0)
	var weapon_offer := ShopOfferDefinition.new()
	weapon_offer.offer_type = ShopOfferDefinition.OfferType.WEAPON
	weapon_offer.weapon_id = &"shotgun"
	weapon_offer.price = 100
	arena._buy_equipment_local(0, weapon_offer)
	var shotgun = equipment.get_item_by_id(&"shotgun")
	_check("a bought weapon must land in the ledger", world.inventory_amount_of(0, weapon_profile) > 0)
	_check("a bought weapon must reach the equipment", shotgun.is_available())
	_check("a bought weapon must be paid for", world.get_player_material(0) == material_before - 100)

	var ammo_before: int = world.inventory_amount_of(0, ammo_profile)
	var ammo_offer := ShopOfferDefinition.new()
	ammo_offer.offer_type = ShopOfferDefinition.OfferType.AMMO
	ammo_offer.weapon_id = &"shotgun"
	ammo_offer.ammo_amount = 20
	ammo_offer.price = 50
	arena._buy_equipment_local(0, ammo_offer)
	_check(
		"bought ammo must land in the ledger",
		world.inventory_amount_of(0, ammo_profile) == ammo_before + 20
	)
	_check("bought ammo must reach the weapon", shotgun.get_ammo_count() == ammo_before + 20)

	var material_after_ammo: int = world.get_player_material(0)
	arena._buy_equipment_local(0, weapon_offer)
	_check(
		"buying an owned weapon must not charge for a single round",
		world.get_player_material(0) == material_after_ammo
	)


## 放下去的油桶要从账本里扣，不能只扣手上那个计数。
func _test_placing_oil_debits_the_ledger(arena, world, equipment) -> void:
	var oil_profile: int = world.inventory_oil_profile_index()
	_check("oil must have an inventory profile", oil_profile >= 0)
	if oil_profile < 0:
		return
	world.accept_inventory(0, oil_profile, 3)
	arena._push_inventory_mirror(0)
	var oil = equipment.get_item_by_id(&"oil_barrel")
	_check("credited oil must reach the equipment", oil.get_remaining_count() == 3)
	oil.set_use_input(false, true, Vector3(0.0, 0.0, -1.0))
	_check("placing oil must debit the ledger", world.inventory_amount_of(0, oil_profile) == 2)
	arena._push_inventory_mirror(0)
	_check("the ledger must stay the source of the placed count", oil.get_remaining_count() == 2)


## 联机的收端：一条 place 事件从线上进来，必须在**事件点名的那一格**长出桶来，
## 并从那个座位的账本里扣掉一个。
##
## 这条路径最容易出的不是崩溃，而是静默错位：格子号是事件的全部载荷，任何一环
## 把 ci/cj 丢掉（服务端的字段白名单、打包、解包），桶都会一声不响地落在网格原点
## ——各端还都一致，所以帧哈希也不会报。
func _test_placement_arrives_over_the_frame_channel(arena, world, equipment) -> void:
	var grid = arena.get_node_or_null("World/Placement/PlaceItemGrid")
	var container = arena.get_node_or_null("World/PlacedItems")
	_check("arena must expose the placement grid and container", grid != null and container != null)
	if grid == null or container == null:
		return
	var oil_profile: int = world.inventory_oil_profile_index()
	world.accept_inventory(0, oil_profile, 2)
	arena._push_inventory_mirror(0)
	var oil_before: int = world.inventory_amount_of(0, oil_profile)
	var placed_before: int = container.get_child_count()
	# 挑一格离出生点足够远的空地，避免撞上地图自带的静态障碍。
	var target_cell := Vector2i(6, -5)
	var placeable_index: int = equipment.get_slot_for_item(&"oil_barrel")
	var event: Dictionary = LobbyProtocol.pack_place_item_event(placeable_index, target_cell)
	_check("a packed placement must name the frame event kind", int(event["k"]) == LobbyProtocol.EVENT_PLACE_ITEM)
	arena._queue_online_event(0, event)
	_check(
		"a placement from the wire must debit the placer's ledger",
		world.inventory_amount_of(0, oil_profile) == oil_before - 1
	)
	_check(
		"a placement from the wire must create exactly one item",
		container.get_child_count() == placed_before + 1
	)
	if container.get_child_count() != placed_before + 1:
		return
	var placed := container.get_child(container.get_child_count() - 1) as Node3D
	var expected_position: Vector3 = grid.cell_to_world(target_cell)
	_check(
		"a placement must land on the cell the frame named, not the grid origin",
		placed.global_position.is_equal_approx(expected_position)
	)
	_check(
		"a placed barrel must own its simulation entity",
		placed.has_method(&"get_sim_barrel_id") and int(placed.get_sim_barrel_id()) != 0
	)
	_check(
		"the placer's seat must ride along for the fortify passive",
		placed.has_meta("owner_slot") and int(placed.get_meta("owner_slot")) == 0
	)
	# 没有油桶了就不该再放得下：账本是唯一的闸门，否则一个桶能刷出好几个。
	world.spend_inventory(0, oil_profile, world.inventory_amount_of(0, oil_profile))
	arena._queue_online_event(
		0, LobbyProtocol.pack_place_item_event(placeable_index, Vector2i(7, -5))
	)
	_check(
		"a placement without oil in the ledger must be refused",
		container.get_child_count() == placed_before + 1
	)


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("validate_inventory_ledger_wiring: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
