extends RefCounted
class_name GameMapRuntime

const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const InventoryProfileCatalog = preload("res://resources/inventory/inventory_profiles.tres")
const WeaponModTableScript = preload("res://scripts/sim/weapon_mod_table.gd")
const WEAPON_DIRECTORY := "res://resources/weapons"

var content_root: Node3D
var zombie_definitions: Array[ZombieDefinition] = []
var reward_definitions: Array[PickupDefinition] = []
var initial_chest_events: Array[Dictionary] = []

var _inventory_profiles: Array[InventoryProfile] = []
var _inventory_profile_indices_by_reward := PackedInt32Array()

var _player_spawn_positions: Array[Vector3] = []
var _camera_bounds := Rect2()
var _scene_barrels: Array[ExplosiveBarrel] = []

func load(
	definition: MapDefinition,
	world: SimWorld,
	content_parent: Node3D,
	zombie_difficulty: ZombieDifficultyProfile,
	seed: int
) -> PackedStringArray:
	if definition == null:
		return PackedStringArray(["map definition is required"])
	var definition_errors := definition.validate_configuration()
	if not definition_errors.is_empty():
		return definition_errors
	var dependency_errors := PackedStringArray()
	if world == null:
		dependency_errors.append("SimWorld is required")
	if content_parent == null:
		dependency_errors.append("content parent is required")
	if zombie_difficulty == null:
		dependency_errors.append("zombie difficulty is required")
	if not dependency_errors.is_empty():
		return dependency_errors

	var instance := definition.content_scene.instantiate()
	if not instance is Node3D:
		if instance != null:
			instance.free()
		return PackedStringArray(["content scene root must be Node3D"])
	var staged_content_root := instance as Node3D
	content_parent.add_child(staged_content_root)

	var errors := PackedStringArray()
	if definition.player_spawn_positions.is_empty():
		errors.append("player spawn positions must not be empty")
	if definition.spawn_points.is_empty():
		errors.append("spawn points must not be empty")

	var zombie_by_id: Dictionary = {}
	for wave in definition.waves:
		for entry in wave.zombie_entries:
			_collect_zombie_definition(entry.zombie, zombie_by_id, errors)
	for death_rule in definition.zombie_death_rules:
		_collect_zombie_definition(death_rule.zombie, zombie_by_id, errors)
	var sorted_zombies: Array[ZombieDefinition] = []
	for zombie in zombie_by_id.values():
		sorted_zombies.append(zombie as ZombieDefinition)
	sorted_zombies.sort_custom(_zombie_definition_less)
	var zombie_profile_indices: Dictionary = {}
	for profile_index in range(sorted_zombies.size()):
		zombie_profile_indices[sorted_zombies[profile_index].type_id] = profile_index

	var reward_by_path: Dictionary = {}
	for fixed_spawn in definition.fixed_item_spawns:
		_collect_reward_definition(fixed_spawn.pickup, reward_by_path, errors)
	for death_rule in definition.zombie_death_rules:
		for group in death_rule.groups:
			for event in group.events:
				if event.event_type == DeathEventDefinition.EventType.DROP_ITEM:
					_collect_reward_definition(event.pickup, reward_by_path, errors)
	var sorted_rewards: Array[PickupDefinition] = []
	for reward in reward_by_path.values():
		sorted_rewards.append(reward as PickupDefinition)
	sorted_rewards.sort_custom(_reward_definition_less)
	var reward_profile_indices: Dictionary = {}
	for profile_index in range(sorted_rewards.size()):
		reward_profile_indices[sorted_rewards[profile_index].resource_path] = profile_index
	# reward profile 的次序来自已按资源路径排序的 sorted_rewards；UI profile 的
	# StringName 身份独立保存于 inventory_profiles.tres，二者在此显式映射。
	var inventory_profile_compilation := _compile_inventory_profiles(sorted_rewards, errors)

	var compiled_waves: Array[Dictionary] = []
	for wave in definition.waves:
		var compiled_entries: Array[Dictionary] = []
		for entry in wave.zombie_entries:
			var type_id: StringName = entry.zombie.type_id
			if not zombie_profile_indices.has(type_id):
				errors.append("wave references unknown zombie type: %s" % type_id)
				continue
			compiled_entries.append({
				"profile_index": int(zombie_profile_indices[type_id]),
				"count": entry.count,
			})
		compiled_waves.append({
			"spawn_interval_ticks": wave.spawn_interval_ticks,
			"entries": compiled_entries,
		})

	var sorted_spawn_points: Array[MapSpawnPointDefinition] = []
	sorted_spawn_points.append_array(definition.spawn_points)
	sorted_spawn_points.sort_custom(_spawn_point_less)
	var compiled_spawn_points: Array[Dictionary] = []
	for spawn_point in sorted_spawn_points:
		compiled_spawn_points.append({
			"spawn_id": spawn_point.spawn_id,
			"position": spawn_point.position_xz,
			"radius": spawn_point.spawn_radius,
			"spacing": spawn_point.minimum_spacing,
		})

	var compiled_death_groups: Array[Array] = []
	for _profile_index in range(sorted_zombies.size()):
		compiled_death_groups.append([])
	for death_rule in definition.zombie_death_rules:
		var type_id: StringName = death_rule.zombie.type_id
		if not zombie_profile_indices.has(type_id):
			errors.append("death rule references unknown zombie type: %s" % type_id)
			continue
		var groups: Array[Dictionary] = []
		for group in death_rule.groups:
			var events: Array[Dictionary] = []
			for event in group.events:
				if event.event_type == DeathEventDefinition.EventType.DROP_MATERIAL:
					# 材料掉落：不依赖 pickup/reward_profile，直接用 min/max 区间。
					events.append({
						"event_type": int(event.event_type),
						"weight": event.weight,
						"material_drop_min": event.material_drop_min,
						"material_drop_max": event.material_drop_max,
					})
					continue
				if event.event_type != DeathEventDefinition.EventType.DROP_ITEM:
					errors.append("unsupported death event type for group: %s" % group.group_id)
					continue
				var reward_path := event.pickup.resource_path
				if not reward_profile_indices.has(reward_path):
					errors.append("death event references unknown reward: %s" % reward_path)
					continue
				events.append({
					"event_type": int(event.event_type),
					"weight": event.weight,
					"reward_profile_index": int(reward_profile_indices[reward_path]),
					"amount": event.amount,
				})
			groups.append({
				"group_id": group.group_id,
				"trigger_chance_per_10000": group.trigger_chance_per_10000,
				"events": events,
			})
		compiled_death_groups[int(zombie_profile_indices[type_id])] = groups

	var sorted_fixed_spawns: Array[FixedItemSpawnDefinition] = []
	sorted_fixed_spawns.append_array(definition.fixed_item_spawns)
	sorted_fixed_spawns.sort_custom(_fixed_spawn_less)

	var obstacle_records: Array[Dictionary] = []
	var barrel_records: Array[Dictionary] = []
	_collect_content_nodes(
		staged_content_root,
		staged_content_root,
		obstacle_records,
		barrel_records,
		errors
	)
	obstacle_records.sort_custom(_path_record_less)
	barrel_records.sort_custom(_path_record_less)
	var sorted_barrels: Array[ExplosiveBarrel] = []
	for record in barrel_records:
		sorted_barrels.append(record["node"] as ExplosiveBarrel)

	var validation_grid: FlowFieldGrid = FlowFieldGridScript.new()
	validation_grid.configure(
		definition.grid_origin,
		definition.grid_cell_size,
		definition.grid_width,
		definition.grid_height
	)
	for record in obstacle_records:
		var bounds: AABB = record["bounds"]
		validation_grid.set_blocked_world_rect(
			Vector2(bounds.position.x, bounds.position.z),
			Vector2(bounds.end.x, bounds.end.z),
			true
		)
	_validate_positions(
		definition,
		sorted_spawn_points,
		sorted_fixed_spawns,
		validation_grid,
		errors
	)

	if not errors.is_empty():
		staged_content_root.free()
		return errors

	# 提交阶段：从这里开始才允许改写模拟层。上面的收集、排序、编译和空间
	# 校验全部成功后才配置网格、清空旧局并注册实体，失败不会留下半张地图。
	var previous_content_root := content_root
	content_root = staged_content_root
	if previous_content_root != null and is_instance_valid(previous_content_root):
		previous_content_root.free()
	zombie_definitions = sorted_zombies
	reward_definitions = sorted_rewards
	_inventory_profiles = inventory_profile_compilation["profiles"] as Array[InventoryProfile]
	_inventory_profile_indices_by_reward = inventory_profile_compilation["indices"] as PackedInt32Array
	initial_chest_events.clear()
	_player_spawn_positions.clear()
	_player_spawn_positions.append_array(definition.player_spawn_positions)
	_camera_bounds = definition.camera_bounds
	_scene_barrels = sorted_barrels
	world.configure(
		definition.grid_origin,
		definition.grid_cell_size,
		definition.grid_width,
		definition.grid_height
	)
	world.reset(seed)
	for profile_index in range(zombie_definitions.size()):
		var zombie := zombie_definitions[profile_index]
		var move_speed := (
			zombie_difficulty.perception_move_speed
			* float(zombie.move_speed_scale_per_10000)
			/ 10000.0
		)
		world.configure_zombie_profile(
			profile_index,
			zombie.max_health,
			move_speed,
			zombie.explodes_on_death,
			zombie.explosion_radius,
			zombie.explosion_center_damage,
			zombie.explosion_edge_damage
		)
	world.set_perception_range(definition.zombie_perception_range)
	world.configure_wave_schedule(
		compiled_waves,
		compiled_spawn_points,
		definition.end_mode,
		definition.inter_wave_delay_ticks,
		definition.maximum_active_zombies
	)
	for profile_index in range(compiled_death_groups.size()):
		world.configure_zombie_death_groups(
			profile_index,
			compiled_death_groups[profile_index]
		)
	for record in obstacle_records:
		var bounds: AABB = record["bounds"]
		world.set_blocker_world_rect(
			Vector2(bounds.position.x, bounds.position.z),
			Vector2(bounds.end.x, bounds.end.z),
			true
		)
	for fixed_spawn in sorted_fixed_spawns:
		var reward_profile_index := int(
			reward_profile_indices[fixed_spawn.pickup.resource_path]
		)
		var blocker_min := fixed_spawn.position_xz - SimWorld.CHEST_BLOCKER_HALF_SIZE
		var blocker_max := fixed_spawn.position_xz + SimWorld.CHEST_BLOCKER_HALF_SIZE
		var chest_id := world.spawn_chest(
			fixed_spawn.position_xz,
			reward_profile_index,
			fixed_spawn.amount,
			fixed_spawn.respawn_delay_ticks,
			blocker_min,
			blocker_max,
			SimWorld.CHEST_CLAIM_RADIUS
		)
		initial_chest_events.append({
			"kind": &"chest_spawned",
			"chest_id": chest_id,
			"position": fixed_spawn.position_xz,
			"reward_profile_index": reward_profile_index,
			"amount": fixed_spawn.amount,
		})
	return PackedStringArray()

func reward_definition(profile_index: int) -> PickupDefinition:
	if profile_index < 0 or profile_index >= reward_definitions.size():
		return null
	return reward_definitions[profile_index]

func inventory_profiles() -> Array[InventoryProfile]:
	var result: Array[InventoryProfile] = []
	result.append_array(_inventory_profiles)
	return result

## 交给 SimWorld 的只有稳定 gameplay 身份；图标、文本和 Resource 引用不进模拟。
func inventory_profile_dictionaries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for profile in _inventory_profiles:
		result.append({
			"category": int(profile.category),
			"max_stack": profile.max_stack,
			"weapon_id": profile.weapon_id,
			"mod_id": WeaponModTableScript.mod_index_from_id(profile.mod_id),
		})
	return result

func reward_inventory_profile_indices() -> PackedInt32Array:
	return _inventory_profile_indices_by_reward.duplicate()

func inventory_profile_index_for(reward_profile_index: int) -> int:
	if reward_profile_index < 0 or reward_profile_index >= _inventory_profile_indices_by_reward.size():
		return -1
	return _inventory_profile_indices_by_reward[reward_profile_index]

func player_spawn_positions() -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append_array(_player_spawn_positions)
	return result

func camera_bounds() -> Rect2:
	return _camera_bounds

func scene_barrels() -> Array[ExplosiveBarrel]:
	var result: Array[ExplosiveBarrel] = []
	result.append_array(_scene_barrels)
	return result

func _collect_zombie_definition(
	zombie: ZombieDefinition,
	definitions_by_id: Dictionary,
	errors: PackedStringArray
) -> void:
	if zombie == null:
		return
	var key := String(zombie.type_id)
	if definitions_by_id.has(key):
		if definitions_by_id[key] != zombie:
			errors.append("conflicting zombie definition for type_id: %s" % key)
		return
	definitions_by_id[key] = zombie

func _collect_reward_definition(
	reward: PickupDefinition,
	definitions_by_path: Dictionary,
	errors: PackedStringArray
) -> void:
	if reward == null:
		return
	var path := reward.resource_path
	if path.is_empty():
		errors.append("reward definition must use an external resource")
		return
	if definitions_by_path.has(path) and definitions_by_path[path] != reward:
		errors.append("conflicting reward definition path: %s" % path)
		return
	definitions_by_path[path] = reward

func _compile_inventory_profiles(
	sorted_rewards: Array[PickupDefinition],
	errors: PackedStringArray
) -> Dictionary:
	var catalog := InventoryProfileCatalog as InventoryProfile
	if catalog == null:
		errors.append("inventory profile catalog must load as InventoryProfile")
		return {"profiles": [], "indices": PackedInt32Array()}
	var profiles: Array[InventoryProfile] = []
	profiles.append_array(catalog.profiles)
	profiles.sort_custom(_inventory_profile_less)
	var weapon_definitions_by_id := _load_inventory_weapon_definitions(errors)
	var profile_indices_by_id: Dictionary = {}
	for profile_index in range(profiles.size()):
		var profile := profiles[profile_index]
		if profile == null or profile.profile_id.is_empty():
			errors.append("inventory profile must have a non-empty id")
			continue
		_validate_inventory_profile(profile, weapon_definitions_by_id, errors)
		if profile_indices_by_id.has(profile.profile_id):
			errors.append("duplicate inventory profile id: %s" % profile.profile_id)
			continue
		profile_indices_by_id[profile.profile_id] = profile_index
	var indices := PackedInt32Array()
	indices.resize(sorted_rewards.size())
	indices.fill(-1)
	for reward_profile_index in range(sorted_rewards.size()):
		var reward := sorted_rewards[reward_profile_index]
		# 补血是即时效果，不进背包也就没有 inventory_key，留 -1 由 SimWorld 的
		# reward_heal_amount 表接管（见 SimWorld._plan_reward_acceptance）。
		if not reward.needs_inventory_profile():
			continue
		var key := reward.get_inventory_key()
		if key.is_empty() or not profile_indices_by_id.has(key):
			errors.append(
				"reward has unknown inventory key: %s (%s)" % [key, reward.resource_path]
			)
			continue
		var inventory_profile_index: int = profile_indices_by_id[key]
		var profile := profiles[inventory_profile_index]
		if reward.get_inventory_category() != profile.category:
			errors.append(
				"reward inventory category does not match profile: %s (%s)" % [key, reward.resource_path]
			)
			continue
		if reward.get_inventory_max_stack() != profile.max_stack:
			errors.append(
				"reward inventory max stack does not match profile: %s (%s)" % [key, reward.resource_path]
			)
			continue
		indices[reward_profile_index] = inventory_profile_index
	return {"profiles": profiles, "indices": indices}

func _load_inventory_weapon_definitions(errors: PackedStringArray) -> Dictionary:
	var directory := DirAccess.open(WEAPON_DIRECTORY)
	if directory == null:
		errors.append("inventory weapon directory is unavailable: %s" % WEAPON_DIRECTORY)
		return {}
	var paths: Array[String] = []
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not directory.current_is_dir() and entry.get_extension() == "tres":
			paths.append(WEAPON_DIRECTORY.path_join(entry))
		entry = directory.get_next()
	directory.list_dir_end()
	paths.sort()
	var definitions_by_id: Dictionary = {}
	for path in paths:
		var definition := load(path) as WeaponDefinition
		if definition == null or definition.weapon_id.is_empty():
			errors.append("inventory weapon definition is invalid: %s" % path)
			continue
		if definitions_by_id.has(definition.weapon_id):
			errors.append("duplicate inventory weapon id: %s" % definition.weapon_id)
			continue
		definitions_by_id[definition.weapon_id] = definition
	return definitions_by_id

func _validate_inventory_profile(
	profile: InventoryProfile,
	weapon_definitions_by_id: Dictionary,
	errors: PackedStringArray
) -> void:
	if profile.max_stack < 0 or (
		profile.max_stack == 0
		and not _allows_zero_ammo_max_stack(profile, weapon_definitions_by_id)
	):
		errors.append("inventory profile max stack must be positive: %s" % profile.profile_id)
	if not InventoryProfile.is_icon_region_inside_atlas(profile.icon_region):
		errors.append("inventory profile icon region must be a single atlas cell: %s" % profile.profile_id)
	if profile.category < InventoryProfile.Category.WEAPON or profile.category > InventoryProfile.Category.WEAPON_MOD:
		errors.append("invalid inventory profile category: %s" % profile.profile_id)
		return
	match profile.category:
		InventoryProfile.Category.WEAPON:
			_validate_inventory_weapon_profile(profile, weapon_definitions_by_id, errors)
		InventoryProfile.Category.AMMO:
			_validate_inventory_ammo_profile(profile, weapon_definitions_by_id, errors)
		InventoryProfile.Category.OIL:
			if not profile.weapon_id.is_empty() or not profile.mod_id.is_empty():
				errors.append("inventory oil profile must not declare weapon or mod id: %s" % profile.profile_id)
			if profile.max_stack <= 0:
				errors.append("inventory oil max stack must be positive: %s" % profile.profile_id)
		InventoryProfile.Category.WEAPON_MOD:
			_validate_inventory_weapon_mod_profile(profile, errors)

func _allows_zero_ammo_max_stack(
	profile: InventoryProfile,
	weapon_definitions_by_id: Dictionary
) -> bool:
	if (
		profile.max_stack != 0
		or profile.category != InventoryProfile.Category.AMMO
		or not weapon_definitions_by_id.has(profile.weapon_id)
	):
		return false
	var definition := weapon_definitions_by_id[profile.weapon_id] as WeaponDefinition
	var ranged_definition := definition as RangedWeaponDefinition
	return ranged_definition != null and ranged_definition.max_ammo == 0

func _validate_inventory_weapon_profile(
	profile: InventoryProfile,
	weapon_definitions_by_id: Dictionary,
	errors: PackedStringArray
) -> void:
	if not weapon_definitions_by_id.has(profile.weapon_id):
		errors.append("inventory profile references unknown weapon id: %s" % profile.profile_id)
	if not profile.mod_id.is_empty():
		errors.append("inventory weapon profile must not declare mod id: %s" % profile.profile_id)
	if profile.max_stack != 1:
		errors.append("inventory weapon max stack must be one: %s" % profile.profile_id)

func _validate_inventory_ammo_profile(
	profile: InventoryProfile,
	weapon_definitions_by_id: Dictionary,
	errors: PackedStringArray
) -> void:
	if not weapon_definitions_by_id.has(profile.weapon_id):
		errors.append("inventory profile references unknown weapon id: %s" % profile.profile_id)
		return
	var definition := weapon_definitions_by_id[profile.weapon_id] as WeaponDefinition
	if not definition is RangedWeaponDefinition:
		errors.append("inventory ammo profile must reference a ranged weapon: %s" % profile.profile_id)
		return
	var ranged_definition := definition as RangedWeaponDefinition
	if profile.max_stack != ranged_definition.max_ammo:
		errors.append("inventory ammo max stack must match weapon max_ammo: %s" % profile.profile_id)
	if not profile.mod_id.is_empty():
		errors.append("inventory ammo profile must not declare mod id: %s" % profile.profile_id)

func _validate_inventory_weapon_mod_profile(
	profile: InventoryProfile,
	errors: PackedStringArray
) -> void:
	var mod_index := WeaponModTableScript.mod_index_from_id(profile.mod_id)
	if mod_index < 0:
		errors.append("inventory profile references unknown weapon mod id: %s" % profile.profile_id)
		return
	if profile.max_stack != WeaponModTableScript.MAX_STACKS[mod_index]:
		errors.append("inventory weapon mod max stack must match WeaponModTable: %s" % profile.profile_id)
	if not profile.weapon_id.is_empty():
		errors.append("inventory weapon mod profile must not declare weapon id: %s" % profile.profile_id)

func _collect_content_nodes(
	root_node: Node3D,
	node: Node,
	obstacle_records: Array[Dictionary],
	barrel_records: Array[Dictionary],
	errors: PackedStringArray
) -> void:
	if node is ExplosiveBarrel:
		barrel_records.append({
			"path": String(root_node.get_path_to(node)),
			"node": node,
		})
	elif node is CollisionObject3D and node.is_in_group(&"place_item_obstacle"):
		var obstacle := node as CollisionObject3D
		var bounds := PlaceItemGridScript.collision_object_world_aabb(obstacle)
		var relative_path := String(root_node.get_path_to(obstacle))
		if bounds.size == Vector3.ZERO:
			errors.append("place item obstacle has no supported collision shape: %s" % relative_path)
		else:
			obstacle_records.append({
				"path": relative_path,
				"bounds": bounds,
			})
	for child in node.get_children():
		_collect_content_nodes(
			root_node,
			child,
			obstacle_records,
			barrel_records,
			errors
		)

func _validate_positions(
	definition: MapDefinition,
	spawn_points: Array[MapSpawnPointDefinition],
	fixed_spawns: Array[FixedItemSpawnDefinition],
	grid: FlowFieldGrid,
	errors: PackedStringArray
) -> void:
	var grid_min := definition.grid_origin
	var grid_max := definition.grid_origin + Vector2(
		definition.grid_width * definition.grid_cell_size,
		definition.grid_height * definition.grid_cell_size
	)
	for index in range(definition.player_spawn_positions.size()):
		var position_3d := definition.player_spawn_positions[index]
		_validate_clear_point(
			"player spawn %d" % index,
			Vector2(position_3d.x, position_3d.z),
			grid,
			errors
		)
	for spawn_point in spawn_points:
		_validate_clear_point(
			"zombie spawn %s" % spawn_point.spawn_id,
			spawn_point.position_xz,
			grid,
			errors
		)
		var radius_extents := Vector2.ONE * spawn_point.spawn_radius
		if not _rect_inside_grid(
			spawn_point.position_xz - radius_extents,
			spawn_point.position_xz + radius_extents,
			grid_min,
			grid_max
		):
			errors.append("zombie spawn radius exceeds grid: %s" % spawn_point.spawn_id)
	var occupied_fixed_cells: Dictionary = {}
	for fixed_spawn in fixed_spawns:
		var cell := grid.world_to_cell(fixed_spawn.position_xz)
		if not grid.is_inside(cell):
			errors.append("fixed item is outside grid: %s" % fixed_spawn.spawn_id)
			continue
		if occupied_fixed_cells.has(cell):
			errors.append(
				"fixed items share flow-field cell: %s and %s" % [
					occupied_fixed_cells[cell],
					fixed_spawn.spawn_id,
				]
			)
		else:
			occupied_fixed_cells[cell] = fixed_spawn.spawn_id
		var blocker_min := fixed_spawn.position_xz - SimWorld.CHEST_BLOCKER_HALF_SIZE
		var blocker_max := fixed_spawn.position_xz + SimWorld.CHEST_BLOCKER_HALF_SIZE
		if not _rect_inside_grid(blocker_min, blocker_max, grid_min, grid_max):
			errors.append("fixed item blocker exceeds grid: %s" % fixed_spawn.spawn_id)
			continue
		if _rect_overlaps_blocked_cell(blocker_min, blocker_max, grid):
			errors.append("fixed item overlaps static blocker: %s" % fixed_spawn.spawn_id)

func _validate_clear_point(
	label: String,
	position: Vector2,
	grid: FlowFieldGrid,
	errors: PackedStringArray
) -> void:
	var cell := grid.world_to_cell(position)
	if not grid.is_inside(cell):
		errors.append("%s is outside grid" % label)
		return
	if grid.is_blocked(cell):
		errors.append("%s occupies a blocked cell" % label)

func _rect_inside_grid(
	minimum: Vector2,
	maximum: Vector2,
	grid_minimum: Vector2,
	grid_maximum: Vector2
) -> bool:
	return (
		minimum.x >= grid_minimum.x and
		minimum.y >= grid_minimum.y and
		maximum.x <= grid_maximum.x and
		maximum.y <= grid_maximum.y
	)

func _rect_overlaps_blocked_cell(
	minimum: Vector2,
	maximum: Vector2,
	grid: FlowFieldGrid
) -> bool:
	var low_cell := grid.world_to_cell(minimum)
	var high_cell := grid.world_to_cell(
		maximum - Vector2(grid.cell_size * 0.001, grid.cell_size * 0.001)
	)
	high_cell = Vector2i(
		maxi(high_cell.x, low_cell.x),
		maxi(high_cell.y, low_cell.y)
	)
	for cell_z in range(low_cell.y, high_cell.y + 1):
		for cell_x in range(low_cell.x, high_cell.x + 1):
			if grid.is_blocked(Vector2i(cell_x, cell_z)):
				return true
	return false

func _zombie_definition_less(left: ZombieDefinition, right: ZombieDefinition) -> bool:
	return String(left.type_id) < String(right.type_id)

func _reward_definition_less(left: PickupDefinition, right: PickupDefinition) -> bool:
	return left.resource_path < right.resource_path

func _inventory_profile_less(left: InventoryProfile, right: InventoryProfile) -> bool:
	return String(left.profile_id) < String(right.profile_id)

func _spawn_point_less(
	left: MapSpawnPointDefinition,
	right: MapSpawnPointDefinition
) -> bool:
	return String(left.spawn_id) < String(right.spawn_id)

func _fixed_spawn_less(
	left: FixedItemSpawnDefinition,
	right: FixedItemSpawnDefinition
) -> bool:
	return String(left.spawn_id) < String(right.spawn_id)

func _path_record_less(left: Dictionary, right: Dictionary) -> bool:
	return String(left["path"]) < String(right["path"])
