extends SceneTree

const DEMO_MAP_PATH := "res://resources/maps/demo/demo_map.tres"
const DEMO_CONTENT_PATH := "res://scenes/maps/demo/DemoMapContent.tscn"
const GAMEPLAY_ARENA_SCRIPT_PATH := "res://scripts/gameplay/gameplay_arena.gd"
const GAMEPLAY_ARENA_SCENE_PATH := "res://scenes/gameplay/GameplayArena.tscn"
const GAME_MAP_RUNTIME_SCRIPT_PATH := "res://scripts/gameplay/map/game_map_runtime.gd"
const DEMO_MAP_SCENE_PATH := "res://scenes/maps/demo/DemoMap.tscn"
const ZOMBIE_DIFFICULTY_PATH := "res://resources/difficulty/zombie_normal.tres"
const DEFAULT_GAME_SCENE_PATH := "res://scenes/maps/demo/DemoMap.tscn"
## 联机的地图由房间的 map_id 决定，客户端不能自带一个默认答案：
## 硬指某张图意味着房主换了图而这一端还是跑原来那张。所以它进的是通用竞技场，
## 由 GameplayArena._resolve_map_definition() 按 GameSession.map_id 去目录里取。
const ROOM_ROUTED_ENTRY_SCRIPT_PATHS: PackedStringArray = [
	"res://scripts/menu/online_lobby.gd",
]
const GENERIC_ARENA_SCENE_PATH := "res://scenes/gameplay/GameplayArena.tscn"
## 单机路径没有房间、地图不来自任何协商，改为走地图选择界面，
## 由 GameSession.selected_map_scene_path 记住玩家挑的那张。
const MAP_SELECTION_SCENE_PATH := "res://scenes/menu/MapSelection.tscn"
const MAIN_MENU_SCRIPT_PATH := "res://scripts/menu/main_menu.gd"
const LOCAL_MULTIPLAYER_LOBBY_SCRIPT_PATH := "res://scripts/menu/local_multiplayer_lobby.gd"
const CURRENT_RUNTIME_ROOTS: PackedStringArray = [
	"res://scripts",
	"res://scenes",
	"res://resources",
]
const CURRENT_RUNTIME_EXTENSIONS: PackedStringArray = ["gd", "tscn", "tres"]
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(DEMO_MAP_PATH), "demo map resource must exist", failures)
	_expect(
		ResourceLoader.exists(GAMEPLAY_ARENA_SCRIPT_PATH),
		"generic gameplay arena script must exist",
		failures
	)
	_expect(
		ResourceLoader.exists(GAME_MAP_RUNTIME_SCRIPT_PATH),
		"game map runtime script must exist",
		failures
	)
	_expect(ResourceLoader.exists(DEMO_MAP_SCENE_PATH), "demo map wrapper must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var definition = load(DEMO_MAP_PATH)
	_expect(definition != null, "demo map resource must load", failures)
	if definition == null:
		_finish(failures)
		return
	_test_definition_values(definition, failures)
	_test_gameplay_entry_paths(failures)
	_test_current_runtime_names(failures)
	_test_architecture_contract(failures)
	_test_generic_arena_source(failures)
	_test_place_item_connections_wait_for_runtime(failures)
	await _test_non_default_place_grid_alignment(definition, failures)
	await _test_runtime_assembly(definition, failures)
	_finish(failures)

func _test_gameplay_entry_paths(failures: Array[String]) -> void:
	# 联机入口必须路由到通用竞技场，不能硬指某张图。
	for script_path in ROOM_ROUTED_ENTRY_SCRIPT_PATHS:
		var entry_script := load(script_path) as GDScript
		_expect(entry_script != null, "%s must load" % script_path, failures)
		if entry_script == null:
			continue
		var entry: Node = entry_script.new()
		_expect(
			entry.game_scene_path == GENERIC_ARENA_SCENE_PATH,
			"%s must route through %s, not hardcode a map" % [
				script_path, GENERIC_ARENA_SCENE_PATH
			],
			failures
		)
		entry.free()

	# 单机入口走地图选择界面。
	var main_menu_script := load(MAIN_MENU_SCRIPT_PATH) as GDScript
	_expect(main_menu_script != null, "%s must load" % MAIN_MENU_SCRIPT_PATH, failures)
	if main_menu_script != null:
		var main_menu: Node = main_menu_script.new()
		_expect(
			main_menu.map_selection_scene_path == MAP_SELECTION_SCENE_PATH,
			"%s must default map selection to %s" % [
				MAIN_MENU_SCRIPT_PATH, MAP_SELECTION_SCENE_PATH
			],
			failures
		)
		main_menu.free()

	var local_lobby_source := FileAccess.get_file_as_string(
		LOCAL_MULTIPLAYER_LOBBY_SCRIPT_PATH
	)
	_expect(
		local_lobby_source.contains("selected_game_scene_path(game_scene_path)"),
		"local multiplayer lobby must launch the selected game scene",
		failures
	)

func _test_current_runtime_names(failures: Array[String]) -> void:
	var retired_arena_name := "Demo" + "Arena"
	var files: Array[String] = []
	for root_path in CURRENT_RUNTIME_ROOTS:
		_collect_runtime_files(root_path, files)
	files.sort()
	for path in files:
		var source := FileAccess.get_file_as_string(path)
		_expect(not source.is_empty(), "%s must be readable" % path, failures)
		_expect(
			not source.contains(retired_arena_name),
			"%s must use GameplayArena/map runtime naming" % path,
			failures
		)

func _collect_runtime_files(path: String, files: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var child_path := path.path_join(entry)
			if directory.current_is_dir():
				_collect_runtime_files(child_path, files)
			elif entry.get_extension() in CURRENT_RUNTIME_EXTENSIONS:
				files.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()

func _test_architecture_contract(failures: Array[String]) -> void:
	var source := FileAccess.get_file_as_string("res://AGENTS.md")
	_expect(source.contains("## Map Runtime Architecture"), "map runtime architecture section", failures)
	for required_term in [
		"MapDefinition",
		"GameplayArena",
		"DemoMap",
		"content root",
		"place_item_obstacle",
		"SimWorld",
		"simulation tick",
		"Timer",
		"presentation-layer RNG",
	]:
		_expect(
			source.contains(required_term),
			"map runtime architecture must mention %s" % required_term,
			failures
		)

func _test_definition_values(definition, failures: Array[String]) -> void:
	_expect(definition.map_id == &"demo", "demo map id", failures)
	_expect(definition.display_name == "Demo 检查站", "demo display name", failures)
	_expect(
		definition.content_scene.resource_path == DEMO_CONTENT_PATH,
		"demo definition must retain authoring content scene",
		failures
	)
	_expect(definition.end_mode == MapDefinition.EndMode.LOOP, "demo loops", failures)
	_expect(definition.grid_origin == Vector2(-24.5, -19.5), "grid origin", failures)
	_expect(
		is_equal_approx(definition.grid_cell_size, 1.0),
		"grid cell size",
		failures
	)
	_expect(
		definition.grid_width == 49 and definition.grid_height == 39,
		"grid size",
		failures
	)
	_expect(
		definition.camera_bounds == Rect2(Vector2(-10.0, -7.0), Vector2(20.0, 14.0)),
		"camera bounds",
		failures
	)
	_expect(definition.maximum_active_zombies == 300, "active cap", failures)
	_expect(
		is_equal_approx(definition.zombie_perception_range, 60.0),
		"perception range",
		failures
	)
	_expect(definition.inter_wave_delay_ticks == 60, "inter-wave ticks", failures)
	_expect(
		definition.player_spawn_positions == [
			Vector3(-1.2, 0.0, 6.2),
			Vector3(1.2, 0.0, 6.2),
			Vector3(-1.2, 0.0, 4.2),
			Vector3(1.2, 0.0, 4.2),
		],
		"ordered player spawn positions",
		failures
	)

	_expect(definition.spawn_points.size() == 4, "four spawn points", failures)
	var expected_spawn_ids := [
		&"01_north_west",
		&"02_north_east",
		&"03_south_west",
		&"04_south_east",
	]
	var expected_spawn_positions := [
		Vector2(-19.0, -14.0),
		Vector2(19.0, -14.0),
		Vector2(-19.0, 14.0),
		Vector2(19.0, 14.0),
	]
	for index in mini(definition.spawn_points.size(), expected_spawn_ids.size()):
		var spawn_point = definition.spawn_points[index]
		_expect(spawn_point.spawn_id == expected_spawn_ids[index], "spawn id %d" % index, failures)
		_expect(
			spawn_point.position_xz == expected_spawn_positions[index],
			"spawn position %d" % index,
			failures
		)

	_test_wave_curve(definition, failures)

	_expect(definition.fixed_item_spawns.size() == 5, "five fixed pickups", failures)
	# 最后一列是 respawn_delay_ticks：霰弹枪刻意比其余三件稀缺得多，
	# 一并锁进期望值，免得有人「统一」成同一个数字时把稀缺性调没了。
	var expected_fixed := [
		[
			&"01_smg", Vector2(-4.5, 6.0),
			"res://resources/pickups/smg_pickup.tres", 60,
			PickupDefinition.RewardMode.EQUIPMENT, &"smg", 60, true, 60,
		],
		[
			&"02_smg_ammo", Vector2(0.0, 9.0),
			"res://resources/pickups/smg_ammo_pickup.tres", 90,
			PickupDefinition.RewardMode.AMMO, &"smg", 90, false, 60,
		],
		[
			&"03_oil", Vector2(4.5, 6.0),
			"res://resources/pickups/oil_barrel_pickup.tres", 30,
			PickupDefinition.RewardMode.EQUIPMENT, &"oil_barrel", 30, false, 60,
		],
		[
			&"04_shotgun", Vector2(0.0, -6.0),
			"res://resources/pickups/shotgun_pickup.tres", 16,
			PickupDefinition.RewardMode.EQUIPMENT, &"shotgun", 16, true, 600,
		],
		[
			&"05_rifle", Vector2(-8.0, -8.0),
			"res://resources/pickups/rifle_pickup.tres", 30,
			PickupDefinition.RewardMode.EQUIPMENT, &"rifle", 30, true, 600,
		],
	]
	for index in mini(definition.fixed_item_spawns.size(), expected_fixed.size()):
		var fixed_spawn = definition.fixed_item_spawns[index]
		var expected: Array = expected_fixed[index]
		_expect(fixed_spawn.spawn_id == expected[0], "fixed spawn id %d" % index, failures)
		_expect(fixed_spawn.position_xz == expected[1], "fixed spawn position %d" % index, failures)
		_expect(fixed_spawn.pickup.resource_path == expected[2], "fixed pickup %d" % index, failures)
		_expect(fixed_spawn.amount == expected[3], "fixed amount %d" % index, failures)
		_expect(
			fixed_spawn.respawn_delay_ticks == int(expected[8]),
			"fixed respawn %d" % index,
			failures
		)
		_expect_pickup_semantics(
			fixed_spawn.pickup,
			expected[2],
			int(expected[4]),
			expected[5],
			int(expected[6]),
			bool(expected[7]),
			"fixed pickup %d" % index,
			failures
		)

	# 六种：普通三个外观变体各算一种，加疾行、壮硕、爆破。旧的 normal 已不再被引用。
	_expect(definition.zombie_death_rules.size() == 6, "one death rule per zombie type", failures)
	var death_rules_by_type := {}
	for rule in definition.zombie_death_rules:
		if rule != null and rule.zombie != null:
			death_rules_by_type[rule.zombie.type_id] = rule
	for required_type in [
		&"normal_civilian", &"normal_worker", &"normal_police",
		&"runner", &"tank", &"exploder",
	]:
		_expect(
			death_rules_by_type.has(required_type),
			"every authored zombie type must have a death rule: %s" % required_type,
			failures
		)
	if death_rules_by_type.has(&"tank"):
		# 壮硕僵尸血量是普通僵尸的五倍以上，击杀成本高，因此掉落必须是确定的：
		# 让一个需要专门集火的目标掉不出东西，玩家下次就直接绕开它了。
		var tank_rule = death_rules_by_type[&"tank"]
		_expect(tank_rule.groups.size() == 1, "one tank drop group", failures)
		if tank_rule.groups.size() == 1:
			_expect(tank_rule.groups[0].group_id == &"tank_drop", "tank drop group id", failures)
			_expect(
				tank_rule.groups[0].trigger_chance_per_10000 == 10000,
				"a tank kill must always drop",
				failures
			)
	if death_rules_by_type.has(&"normal"):
		var death_rule = death_rules_by_type[&"normal"]
		_expect(death_rule.groups.size() == 1, "one common drop group", failures)
		if death_rule.groups.size() == 1:
			var group = death_rule.groups[0]
			_expect(group.group_id == &"common_drop", "common drop id", failures)
			_expect(group.trigger_chance_per_10000 == 3200, "common drop chance", failures)
			# 前五件是武器与弹药，后六件是改装件。下面的 expected_drops 只逐件核对
			# 前五件的语义；改装件那六件由 validate_weapon_mod_catalog.gd 与
			# validate_weapon_mods.gd 负责，在这里重复一遍只会让两处断言互相漂移。
			_expect(group.events.size() == 11, "eleven common drops", failures)
			var expected_drops := [
				[
					"res://resources/pickups/smg_pickup.tres",
					PickupDefinition.RewardMode.EQUIPMENT, &"smg", 60, true,
				],
				[
					"res://resources/pickups/smg_ammo_pickup.tres",
					PickupDefinition.RewardMode.AMMO, &"smg", 90, false,
				],
				[
					"res://resources/pickups/oil_barrel_pickup.tres",
					PickupDefinition.RewardMode.EQUIPMENT, &"oil_barrel", 30, false,
				],
				[
					"res://resources/pickups/shotgun_ammo_pickup.tres",
					PickupDefinition.RewardMode.AMMO, &"shotgun", 12, false,
				],
				[
					"res://resources/pickups/rifle_ammo_pickup.tres",
					PickupDefinition.RewardMode.AMMO, &"rifle", 24, false,
				],
			]
			for index in mini(group.events.size(), expected_drops.size()):
				var drop_event = group.events[index]
				var expected: Array = expected_drops[index]
				_expect(
					drop_event.event_type == DeathEventDefinition.EventType.DROP_ITEM,
					"drop event type %d" % index,
					failures
				)
				_expect(drop_event.weight == 1, "drop weight %d" % index, failures)
				_expect(drop_event.amount == expected[3], "drop amount %d" % index, failures)
				_expect_pickup_semantics(
					drop_event.pickup,
					expected[0],
					int(expected[1]),
					expected[2],
					int(expected[3]),
					bool(expected[4]),
					"death drop %d" % index,
					failures
				)

## 波次曲线契约。这里刻意不锁死具体数值——那是频繁调整的手感参数——而是锁死
## 「难度必须真的递增」这个设计意图：地图是 LOOP 的，排行榜排的是 team_wave，
## 一旦波次退回成同一波无限重复，「打到第 30 波」就重新变成熬时间而不是变强。
## 难度代理取每波总血量而不是僵尸数量：一只 260 血的壮硕僵尸比三只普通僵尸更难，
## 按个数比会把「换成更少但更硬的敌人」误判为降低难度。
func _test_wave_curve(definition, failures: Array[String]) -> void:
	_expect(definition.waves.size() >= 8, "demo must author a multi-wave curve", failures)
	if definition.waves.size() < 2:
		return
	var wave_threats: Array[int] = []
	var previous_interval := 1 << 30
	var seen_types := {}
	for index in definition.waves.size():
		var wave = definition.waves[index]
		_expect(
			wave.spawn_interval_ticks > 0,
			"wave %d must stream its spawns, not land the whole wave on one tick" % index,
			failures
		)
		_expect(
			wave.spawn_interval_ticks <= previous_interval,
			"wave %d must not spawn slower than the wave before it" % index,
			failures
		)
		previous_interval = wave.spawn_interval_ticks
		var threat := 0
		for entry in wave.zombie_entries:
			if entry.zombie == null:
				continue
			threat += entry.count * entry.zombie.max_health
			seen_types[entry.zombie.type_id] = true
		wave_threats.append(threat)
	for index in range(1, wave_threats.size()):
		_expect(
			wave_threats[index] > wave_threats[index - 1],
			"wave %d must be harder than wave %d (threat %d vs %d)" % [
				index, index - 1, wave_threats[index], wave_threats[index - 1]
			],
			failures
		)
	if not wave_threats.is_empty():
		_expect(
			wave_threats[wave_threats.size() - 1] >= wave_threats[0] * 4,
			"the final wave must be several times the opening wave, not a slow drift",
			failures
		)
	# 普通僵尸的三个外观变体共享同一套数值，多样性由波次编排决定而非运行时随机，
	# 因此三者都必须真的出现在波次里，否则人群仍然是克隆体。
	for required_type in [
		&"normal_civilian", &"normal_worker", &"normal_police",
		&"runner", &"tank", &"exploder",
	]:
		_expect(
			seen_types.has(required_type),
			"the wave curve must introduce every authored zombie type: %s" % required_type,
			failures
		)

func _expect_pickup_semantics(
	pickup,
	expected_path: String,
	expected_mode: int,
	expected_item_id: StringName,
	expected_amount: int,
	expected_auto_equip: bool,
	label: String,
	failures: Array[String]
) -> void:
	_expect(pickup != null, "%s resource" % label, failures)
	if pickup == null:
		return
	_expect(pickup.resource_path == expected_path, "%s path" % label, failures)
	_expect(pickup.reward_mode == expected_mode, "%s reward mode" % label, failures)
	_expect(pickup.item_id == expected_item_id, "%s item id" % label, failures)
	_expect(pickup.amount == expected_amount, "%s resource amount" % label, failures)
	_expect(pickup.auto_equip == expected_auto_equip, "%s auto equip" % label, failures)

func _test_generic_arena_source(failures: Array[String]) -> void:
	var source := FileAccess.get_file_as_string(GAMEPLAY_ARENA_SCRIPT_PATH)
	_expect(not source.is_empty(), "generic gameplay arena source must be readable", failures)
	for banned in [
		"SPAWN_POINT_NAMES",
		"minimum_zombies_per_corner",
		"maximum_zombies_per_corner",
		"ARENA_SIM_GRID_ORIGIN",
		"RandomPickup" + "DropManager",
		"World/Props/PickupSpawners",
		"_complete_map",
		"map_completed",
	]:
		_expect(not source.contains(banned), "gameplay arena must not contain %s" % banned, failures)

func _test_place_item_connections_wait_for_runtime(failures: Array[String]) -> void:
	var arena_scene := load(GAMEPLAY_ARENA_SCENE_PATH) as PackedScene
	_expect(arena_scene != null, "gameplay arena scene must load", failures)
	if arena_scene == null:
		return
	var arena := arena_scene.instantiate()
	var service := arena.get_node_or_null("PlaceItemService") as PlaceItemService
	_expect(service != null, "gameplay arena place item service", failures)
	if service != null:
		_expect(
			not service.item_placed.is_connected(Callable(arena, "_on_item_placed")),
			"item_placed must wait until map runtime wiring",
			failures
		)
		_expect(
			not service.item_removed.is_connected(Callable(arena, "_on_item_removed")),
			"item_removed must wait until map runtime wiring",
			failures
		)
	var detached_team_state := arena.get("local_team_state") as Node
	arena.free()
	if detached_team_state != null and is_instance_valid(detached_team_state):
		detached_team_state.free()

func _test_non_default_place_grid_alignment(
	definition,
	failures: Array[String]
) -> void:
	var arena_scene := load(GAMEPLAY_ARENA_SCENE_PATH) as PackedScene
	var difficulty = load(ZOMBIE_DIFFICULTY_PATH)
	_expect(arena_scene != null, "gameplay arena scene for grid alignment", failures)
	_expect(difficulty != null, "zombie difficulty for grid alignment", failures)
	if arena_scene == null or difficulty == null:
		return
	var arena := arena_scene.instantiate()
	var custom_definition = definition.duplicate(true)
	custom_definition.grid_origin = Vector2(-25.0, -20.0)
	custom_definition.grid_cell_size = 0.5
	custom_definition.grid_width = 100
	custom_definition.grid_height = 80
	arena.set("map_definition", custom_definition)
	arena.set("zombie_difficulty", difficulty)
	root.add_child(arena)
	await process_frame
	var place_grid := arena.get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	var world := arena.get("sim_world") as SimWorld
	var runtime = arena.get("map_runtime")
	_expect(place_grid != null, "place grid for non-default map", failures)
	_expect(world != null, "sim world for non-default map", failures)
	_expect(
		runtime != null and runtime.content_root != null,
		"non-default map must assemble successfully",
		failures
	)
	if place_grid != null and world != null:
		_expect(
			is_equal_approx(place_grid.cell_size, 0.5),
			"place grid must use MapDefinition.grid_cell_size",
			failures
		)
		_expect(
			place_grid.grid_origin == Vector3(-24.75, 0.0, -19.75),
			"place grid origin must be the first flow-field cell center",
			failures
		)
		var sample_cell := Vector2i(37, 29)
		var place_center := place_grid.cell_to_world(sample_cell)
		var flow_center := world.grid.cell_to_world(sample_cell)
		_expect(
			Vector2(place_center.x, place_center.z) == flow_center,
			"place and flow grids must resolve the same cell center",
			failures
		)
	arena.free()

func _test_runtime_assembly(definition, failures: Array[String]) -> void:
	var runtime_script = load(GAME_MAP_RUNTIME_SCRIPT_PATH)
	var difficulty = load(ZOMBIE_DIFFICULTY_PATH)
	_expect(runtime_script != null, "game map runtime must load", failures)
	_expect(difficulty != null, "zombie difficulty must load", failures)
	if runtime_script == null or difficulty == null:
		return
	var content_parent := Node3D.new()
	root.add_child(content_parent)
	var runtime = runtime_script.new()
	var world: SimWorld = SimWorldScript.new()
	var errors: PackedStringArray = runtime.load(
		definition, world, content_parent, difficulty, 20260811
	)
	_expect(errors.is_empty(), "; ".join(errors), failures)
	if errors.is_empty():
		_expect(runtime.content_root != null, "runtime content root", failures)
		# 六个：普通僵尸的三个外观变体各占一个档案（共享数值，多样性由波次编排决定），
		# 加上疾行、壮硕、爆破。旧的 normal 已不再被任何波次引用，因此不进运行时档案。
		_expect(runtime.zombie_definitions.size() == 6, "six runtime zombie profiles", failures)
		var profile_type_ids: Array[StringName] = []
		for zombie_definition in runtime.zombie_definitions:
			profile_type_ids.append(zombie_definition.type_id)
		_expect(
			profile_type_ids == [
				&"exploder", &"normal_civilian", &"normal_police",
				&"normal_worker", &"runner", &"tank",
			],
			"zombie profiles sorted by type id",
			failures
		)
		_expect(runtime.reward_definitions.size() == 13, "thirteen runtime reward profiles", failures)
		var reward_paths: Array[String] = []
		for reward in runtime.reward_definitions:
			reward_paths.append(reward.resource_path)
		# 这个顺序就是 reward_profile_index：模拟层只认这个 int，各端靠「同一份地图
		# 资源排出同一个序」才对得上。锁死整张表而不只是长度，是因为插入一件新奖励
		# 会把它后面每一件的下标整体挪位——那正是「捡到的东西和别人看到的不一样」。
		_expect(reward_paths == [
			"res://resources/mods/mod_compensator_1.tres",
			"res://resources/mods/mod_damage_1.tres",
			"res://resources/mods/mod_heavy_core.tres",
			"res://resources/mods/mod_hollow_point.tres",
			"res://resources/mods/mod_pierce_1.tres",
			"res://resources/mods/mod_split_1.tres",
			"res://resources/pickups/oil_barrel_pickup.tres",
			"res://resources/pickups/rifle_ammo_pickup.tres",
			"res://resources/pickups/rifle_pickup.tres",
			"res://resources/pickups/shotgun_ammo_pickup.tres",
			"res://resources/pickups/shotgun_pickup.tres",
			"res://resources/pickups/smg_ammo_pickup.tres",
			"res://resources/pickups/smg_pickup.tres",
		], "reward profiles sorted by resource path", failures)
		_expect(runtime.initial_chest_events.size() == 5, "five initial chest events", failures)
		_expect(runtime.scene_barrels().size() == 3, "three sorted scene barrels", failures)
		_expect(world.get_chest_count() == 5, "five simulated fixed chests", failures)
		_expect(world.grid.origin == definition.grid_origin, "world grid configured", failures)
		_test_failed_reload_is_atomic(
			definition,
			runtime,
			world,
			content_parent,
			difficulty,
			failures
		)
	content_parent.free()

func _test_failed_reload_is_atomic(
	definition,
	runtime,
	world: SimWorld,
	content_parent: Node3D,
	difficulty,
	failures: Array[String]
) -> void:
	var previous_content_root = runtime.content_root
	var previous_grid_origin := world.grid.origin
	var previous_chest_count := world.get_chest_count()
	var previous_next_entity_id := world.next_entity_id
	var invalid_definition = definition.duplicate()
	var invalid_fixed_spawns = definition.fixed_item_spawns.duplicate()
	var overlapping_spawn = definition.fixed_item_spawns[0].duplicate(true)
	overlapping_spawn.position_xz = definition.fixed_item_spawns[1].position_xz
	invalid_fixed_spawns[0] = overlapping_spawn
	invalid_definition.fixed_item_spawns = invalid_fixed_spawns
	var errors: PackedStringArray = runtime.load(
		invalid_definition,
		world,
		content_parent,
		difficulty,
		999999
	)
	_expect(not errors.is_empty(), "overlapping fixed items must fail assembly", failures)
	_expect(
		runtime.content_root == previous_content_root and is_instance_valid(previous_content_root),
		"failed reload must retain the prior content root",
		failures
	)
	_expect(world.grid.origin == previous_grid_origin, "failed reload must retain world grid", failures)
	_expect(
		world.get_chest_count() == previous_chest_count,
		"failed reload must retain simulated chests",
		failures
	)
	_expect(
		world.next_entity_id == previous_next_entity_id,
		"failed reload must not reset entity ids",
		failures
	)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_demo_map_data_driven: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
