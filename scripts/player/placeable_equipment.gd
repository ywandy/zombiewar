extends "res://scripts/player/equipment_item.gd"
class_name PlaceableEquipment

@export var display_name := "油桶"
@export var item_id: StringName = &"oil_barrel"
@export_range(0, 999999, 1) var initial_count := 999
@export_range(0, 999999, 1) var max_count := 999
@export var item_scene: PackedScene
@export var placement_direction_scale := 1.0

var remaining_count := -1
var place_item_service
var requester: CharacterBody3D
## 放置成功后把「扣一个油桶」交给上层翻译成模拟层账本的支出。
## 与武器一样，这个节点不认识玩家槽位，也不认识背包 profile 下标。
var sim_request_sink := Callable()

func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value

func _ready() -> void:
	_ensure_count_initialized()

func bind_context(
	wielder: CharacterBody3D,
	_visual_root: Node3D,
	_functional_ray_origin: Marker3D
) -> void:
	requester = wielder
	_ensure_count_initialized()

func set_place_item_service(service) -> void:
	place_item_service = service

func set_use_input(_pressed: bool, just_pressed: bool, aim: Vector3) -> void:
	if not just_pressed or not is_available():
		return
	if place_item_service == null or item_scene == null:
		return
	var origin := Vector3.ZERO
	if requester != null and requester.is_inside_tree():
		origin = requester.global_position
	elif is_inside_tree():
		origin = global_position
	# 本机只决定「往哪个格子放」，放置本身与扣账都交给上层走帧：
	# 联机下各端必须在同一 tick 上得到同一个桶，否则油桶既是阻挡几何、
	# 又是进帧哈希的模拟实体，只在一端出现就等于当场分叉。
	var cell: Vector2i = place_item_service.resolve_placement_cell(
		requester, origin, aim * placement_direction_scale
	)
	if cell == PlaceItemService.INVALID_CELL:
		return
	if sim_request_sink.is_valid():
		sim_request_sink.call({
			"kind": &"place_item",
			"item_id": item_id,
			"cell": cell,
		})

## 放下去的是哪个场景。竞技场按帧落地时要取它——包括远端座位的放置：
## 各端为同一座位建的是同一份 loadout，因此取到的是同一个场景。
func get_place_item_scene() -> PackedScene:
	return item_scene

## 模拟层账本刷下来的权威数量。
func apply_authoritative_count(value: int) -> void:
	var next_count := clampi(value, 0, maxi(max_count, 0))
	if next_count == remaining_count:
		return
	remaining_count = next_count
	count_changed.emit(remaining_count)

func is_available() -> bool:
	_ensure_count_initialized()
	return remaining_count > 0

func get_item_id() -> StringName:
	return item_id

func add_count(amount: int) -> int:
	_ensure_count_initialized()
	if amount <= 0:
		return 0
	var before := remaining_count
	remaining_count = clampi(remaining_count + amount, 0, maxi(max_count, 0))
	if remaining_count != before:
		count_changed.emit(remaining_count)
	return remaining_count - before

func receive_pickup(amount: int) -> bool:
	return add_count(amount) > 0

func get_display_name() -> String:
	return display_name

func get_remaining_count() -> int:
	_ensure_count_initialized()
	return remaining_count

func get_count_text() -> String:
	return str(get_remaining_count())

func _ensure_count_initialized() -> void:
	if remaining_count < 0:
		remaining_count = clampi(initial_count, 0, maxi(max_count, 0))
