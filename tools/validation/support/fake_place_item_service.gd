extends "res://scripts/gameplay/place_item_service.gd"

## 放置服务的替身：不建节点、不查物理，只记下这一次「本机决定放哪一格」。
##
## next_result 现在表达的是**决定能不能放**，而不是「放成功了」——真正的落地
## 由竞技场按帧驱动 place_item_at_cell()，不再发生在装备节点这条路径上。

var next_result := false
var request_count := 0
var last_direction := Vector3.ZERO
var next_cell := Vector2i(3, -2)

func resolve_placement_cell(
	_requester: CollisionObject3D,
	_origin: Vector3,
	direction: Vector3
) -> Vector2i:
	request_count += 1
	last_direction = direction
	return next_cell if next_result else INVALID_CELL
