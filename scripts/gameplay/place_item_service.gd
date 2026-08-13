extends Node
class_name PlaceItemService

signal placement_rejected(reason: StringName)
## 运行时放置的物件是新的阻挡几何，必须标脏对应 cell；
## 若它是爆炸桶，还要由 GameplayArena 注册成模拟层实体
## （见 GameplayArena._on_item_placed()）。
signal item_placed(item: Node3D)
## 移除时把节点与消失前采集的世界 AABB 一起广播：
## 爆炸桶要靠节点本身拿到模拟层 id，光有 AABB 不够。
signal item_removed(item: Node3D, world_aabb: AABB)

@export var default_item_scene: PackedScene
@export_node_path("PlaceItemGrid") var grid_path: NodePath
@export_node_path("Node3D") var placed_items_path: NodePath

## 放不下时 resolve_placement_cell() 返回它。格子坐标本身没有「无效值」，
## 用一个不可能被 target_cell() 算出来的极值当哨兵。
const INVALID_CELL := Vector2i(0x7FFFFFFF, 0x7FFFFFFF)

var tracked_items: Dictionary = {}

## 第一步：**本机**决定这一下能不能放，返回目标格。
##
## 这一步刻意允许各端算出不同答案：它要做物理查询（那个格子上此刻站没站着人或
## 僵尸），而僵尸与玩家的身体在各端是各自插值/预测的，同一 tick 上本来就不在同
## 一个像素。因此它只是**放置者自己的决定**，与「我有没有子弹开这一枪」同性质。
##
## 决定之后走帧：真正落地由 place_item_at_cell() 在各端按同一个格子号执行。
func resolve_placement_cell(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
) -> Vector2i:
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	var container := get_node_or_null(placed_items_path) as Node3D
	if grid == null or container == null:
		push_warning("PlaceItemService has invalid scene, grid, or container configuration")
		_reject(&"invalid_configuration")
		return INVALID_CELL
	if Vector2(direction.x, direction.z).length_squared() <= 0.000001:
		_reject(&"invalid_direction")
		return INVALID_CELL
	var cell := grid.target_cell(origin, direction)
	if grid.is_cell_reserved(cell):
		_reject(&"reserved_cell")
		return INVALID_CELL
	var excluded: Array[RID] = []
	if requester != null and is_instance_valid(requester):
		excluded.append(requester.get_rid())
	if grid.has_dynamic_blocker(grid.get_world_3d(), cell, excluded):
		_reject(&"dynamic_blocker")
		return INVALID_CELL
	return cell

## 第二步：在给定格子上落地。**不做任何物理查询**——各端在同一 tick 上按同一个
## 格子号执行，因此结果一致。owner_slot 由调用方给出（帧里带着放置者座位），
## 而不是从 requester 节点上读：远端座位的放置在本机也要落地。
func place_item_at_cell(
	cell: Vector2i,
	owner_slot: int,
	item_scene: PackedScene = null
) -> bool:
	var resolved_scene := item_scene if item_scene != null else default_item_scene
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	var container := get_node_or_null(placed_items_path) as Node3D
	if grid == null or container == null or resolved_scene == null:
		push_warning("PlaceItemService has invalid scene, grid, or container configuration")
		return _reject(&"invalid_configuration")
	if cell == INVALID_CELL:
		return _reject(&"invalid_cell")
	var instance := resolved_scene.instantiate()
	if not instance is Node3D:
		instance.free()
		return _reject(&"invalid_scene_root")
	var item := instance as Node3D
	# 记下放置者座位：工兵「加固」被动需要知道这桶是谁放的，才能确定性缩放
	# 爆炸范围/伤害。
	if owner_slot >= 0:
		item.set_meta("owner_slot", owner_slot)
	container.add_child(item)
	item.global_position = grid.cell_to_world(cell)
	if not grid.reserve_cells(item, [cell]):
		item.free()
		return _reject(&"reserved_cell")
	tracked_items[item.get_instance_id()] = item
	item.tree_exiting.connect(_on_item_tree_exiting.bind(item), CONNECT_ONE_SHOT)
	# 必须在 item.global_position 落位之后再发：注册方要按它读世界坐标。
	item_placed.emit(item)
	return true

func _reject(reason: StringName) -> bool:
	placement_rejected.emit(reason)
	return false

func _on_item_tree_exiting(item: Node3D) -> void:
	var item_id := item.get_instance_id()
	if not tracked_items.erase(item_id):
		return
	var bounds := PlaceItemGrid.collision_object_world_aabb(
		item as CollisionObject3D
	)
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	if grid != null:
		grid.release_owner(item)
	item_removed.emit(item, bounds)
