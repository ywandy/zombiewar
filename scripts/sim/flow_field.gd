extends RefCounted
class_name FlowField

## 替代 300 个逐僵尸导航代理：以全部存活玩家为源做多源 BFS，
## 整数代价，生成到最近玩家的方向场。僵尸只查自己所在 cell，寻路成本与僵尸数量无关。
const UNREACHABLE := 0x7FFFFFFF

const ORTHOGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]

var grid: FlowFieldGrid
var cost := PackedInt32Array()
var direction_x := PackedFloat32Array()
var direction_z := PackedFloat32Array()
var direction_ready := PackedByteArray()
var last_sources := PackedInt32Array()
var rebuild_count := 0
## BFS 的工作队列。作为成员保留而不是每次重建现开：重建由玩家跨格触发，
## 移动中每秒会发生数次，每次现开就是每秒数次 cell_count 大小的堆分配。
var queue := PackedInt32Array()

func setup(value_grid: FlowFieldGrid) -> void:
	grid = value_grid
	var cell_count := grid.get_cell_count()
	cost = PackedInt32Array()
	cost.resize(cell_count)
	cost.fill(UNREACHABLE)
	direction_x = PackedFloat32Array()
	direction_x.resize(cell_count)
	direction_x.fill(0.0)
	direction_z = PackedFloat32Array()
	direction_z.resize(cell_count)
	direction_z.fill(0.0)
	direction_ready = PackedByteArray()
	direction_ready.resize(cell_count)
	direction_ready.fill(0)
	last_sources = PackedInt32Array()
	queue = PackedInt32Array()
	queue.resize(cell_count)
	rebuild_count = 0

## 重算时机：任一玩家跨越 cell 边界（source 集合变化），或阻挡集合变脏。
## 调用方必须传入升序去重后的 cell index 数组。返回是否真的重算过。
##
## `allow_source_rebuild` 是调用方的节流闸：为 false 时，仅由玩家移动引起的重建
## 会被推迟到下一次允许时（source 不写回 last_sources，因此下一 tick 仍然判定为
## 需要重建，到期即重算）。**阻挡集合变脏不受这个闸控制**——推迟它会让僵尸绕开
## 已经消失的障碍、或者径直走进刚出现的障碍，那是逻辑错误而不是精度损失。
func update(
	source_cell_indices: PackedInt32Array,
	allow_source_rebuild: bool = true
) -> bool:
	var grid_changed := grid.consume_dirty()
	var sources_changed := source_cell_indices != last_sources
	if not grid_changed and not sources_changed:
		return false
	if not grid_changed and not allow_source_rebuild:
		return false
	rebuild(source_cell_indices)
	return true

## 多源 BFS。
##
## 这里刻意展开成一维索引运算，而不是用 Vector2i 邻居配合 grid.cell_index() /
## grid.is_blocked()：重建覆盖全网格，每格四个邻居意味着上万次跨对象函数调用与
## 临时 Vector2i 构造，而它们全都可以由 index ± 1 / ± width 直接算出。
## 越界判定同样内联——网格外一律视为阻挡，与 grid.is_blocked() 的语义一致。
##
## 结果与展开前逐位相同：BFS 的最短代价与访问顺序无关，邻居顺序也保持
## ORTHOGONAL_OFFSETS 的上、右、下、左。
func rebuild(source_cell_indices: PackedInt32Array) -> void:
	rebuild_count += 1
	last_sources = source_cell_indices.duplicate()
	var cell_count := grid.get_cell_count()
	if queue.size() != cell_count:
		queue.resize(cell_count)
	cost.fill(UNREACHABLE)
	direction_ready.fill(0)
	var queue_end := 0
	for source_index in source_cell_indices:
		if source_index < 0 or source_index >= cell_count:
			continue
		if cost[source_index] == 0:
			continue
		cost[source_index] = 0
		queue[queue_end] = source_index
		queue_end += 1
	var queue_head := 0
	var grid_width := grid.get_width()
	var grid_height := grid.get_height()
	var blocked_bytes := grid.get_blocked_bytes()
	while queue_head < queue_end:
		var current_index := queue[queue_head]
		queue_head += 1
		var next_cost := cost[current_index] + 1
		var column := current_index % grid_width
		var row := current_index / grid_width
		# 上、右、下、左，与 ORTHOGONAL_OFFSETS 同序。
		if row > 0:
			var up_index := current_index - grid_width
			if blocked_bytes[up_index] != 1 and cost[up_index] > next_cost:
				cost[up_index] = next_cost
				queue[queue_end] = up_index
				queue_end += 1
		if column < grid_width - 1:
			var right_index := current_index + 1
			if blocked_bytes[right_index] != 1 and cost[right_index] > next_cost:
				cost[right_index] = next_cost
				queue[queue_end] = right_index
				queue_end += 1
		if row < grid_height - 1:
			var down_index := current_index + grid_width
			if blocked_bytes[down_index] != 1 and cost[down_index] > next_cost:
				cost[down_index] = next_cost
				queue[queue_end] = down_index
				queue_end += 1
		if column > 0:
			var left_index := current_index - 1
			if blocked_bytes[left_index] != 1 and cost[left_index] > next_cost:
				cost[left_index] = next_cost
				queue[queue_end] = left_index
				queue_end += 1

func get_cost(cell: Vector2i) -> int:
	var index := grid.cell_index(cell)
	return UNREACHABLE if index < 0 else cost[index]

func is_reachable(cell: Vector2i) -> bool:
	return get_cost(cell) != UNREACHABLE

func get_direction(cell: Vector2i) -> Vector2:
	var index := grid.cell_index(cell)
	if index < 0:
		return Vector2.ZERO
	if direction_ready[index] == 0:
		_compute_direction(index, cell)
	return Vector2(direction_x[index], direction_z[index])

## 亚格平滑方向：取僵尸所在世界点周围 4 个 cell 的方向做双线性插值。
##
## `get_direction()` 每格只存坡度最陡的**单个量化方向**。僵尸贴着墙时，这个方向常常
## 正指墙面，而碰撞推离是纯径向的、不提供任何切向滑动——两者叠加就把僵尸钉在墙上
## 原地抖。业界流场游戏（Planetary Annihilation / SupCom2 一路下来）都会对相邻格方向
## 做插值，得到随亚格位置连续变化的方向场；插值后贴墙方向会自然偏成沿墙切向，僵尸
## 被推开的同时仍在「顺墙往前」，从而绕出死角而不是卡死。
##
## 数学上只用加、减、乘（无除法、无三角），保持跨端逐位一致。
func get_direction_smooth(world_xz: Vector2) -> Vector2:
	var gx := (world_xz.x - grid.origin.x) / grid.cell_size - 0.5
	var gz := (world_xz.y - grid.origin.y) / grid.cell_size - 0.5
	var base_x := floori(gx)
	var base_z := floori(gz)
	var frac_x := clampf(gx - float(base_x), 0.0, 1.0)
	var frac_z := clampf(gz - float(base_z), 0.0, 1.0)
	var c00 := Vector2i(base_x, base_z)
	var c10 := Vector2i(base_x + 1, base_z)
	var c01 := Vector2i(base_x, base_z + 1)
	var c11 := Vector2i(base_x + 1, base_z + 1)
	var top := get_direction(c00).lerp(get_direction(c10), frac_x)
	var bottom := get_direction(c01).lerp(get_direction(c11), frac_x)
	var blended := top.lerp(bottom, frac_z)
	# 源点附近四格方向相互抵消时，退回所在格的量化方向，避免近距离出零向量。
	if blended.length_squared() <= 0.0001:
		return get_direction(grid.world_to_cell(world_xz))
	return blended.normalized()

func get_rebuild_count() -> int:
	return rebuild_count

func _compute_direction(index: int, cell: Vector2i) -> void:
	direction_ready[index] = 1
	direction_x[index] = 0.0
	direction_z[index] = 0.0
	var current_cost := cost[index]
	if current_cost == UNREACHABLE or current_cost == 0:
		return
	var best_cost := current_cost
	var best_offset := Vector2i.ZERO
	for offset in NEIGHBOR_OFFSETS:
		var neighbor := cell + offset
		var neighbor_index := grid.cell_index(neighbor)
		if neighbor_index < 0 or grid.is_blocked(neighbor):
			continue
		if offset.x != 0 and offset.y != 0:
			if grid.is_blocked(Vector2i(cell.x + offset.x, cell.y)):
				continue
			if grid.is_blocked(Vector2i(cell.x, cell.y + offset.y)):
				continue
		var neighbor_cost := cost[neighbor_index]
		if neighbor_cost < best_cost:
			best_cost = neighbor_cost
			best_offset = offset
	if best_offset == Vector2i.ZERO:
		return
	var direction := Vector2(float(best_offset.x), float(best_offset.y)).normalized()
	direction_x[index] = direction.x
	direction_z[index] = direction.y
