extends RefCounted
class_name LobbyProtocol

## 线协议的客户端副本。服务端的那一份是 `server/src/lib/protocol.ts`，
## 两边各自硬编码版本号，靠握手当场比对而不是靠信任：
## 版本不符时服务端立刻以 4001 关闭并在原因里写出双方版本号。
##
## 这条规则的价值不在于兼容，恰恰在于**拒绝兼容**：把「两个仓库悄悄漂移」
## 从一个会在半年后以诡异同步 bug 现身的静默缺陷，变成握手当场的一次响亮失败。
## v5：新增 EVENT_SHOP_PURCHASE（波间商店购买事件），与 server/src/lib/protocol.ts 同步。
## v6：新增 EVENT_PLACE_ITEM（放置油桶），同样与服务端那一份同步。
const PROTOCOL_VERSION := 6

## 大厅与控制消息号段。
const OPCODE_LOBBY_MIN := 0x00
const OPCODE_LOBBY_MAX := 0x7F
## 整段预留给同步层的二进制帧。
const OPCODE_SYNC_MIN := 0x80
const OPCODE_SYNC_MAX := 0xFF

## WebSocket 关闭码。4000-4999 是应用自定义段。
const CLOSE_PROTOCOL_MISMATCH := 4001
const CLOSE_ROOM_FULL := 4002
const CLOSE_BAD_MESSAGE := 4003
const CLOSE_KICKED := 4004
const CLOSE_ROOM_CLOSED := 4005
const CLOSE_RECONNECTED_ELSEWHERE := 4006
## 掉线太久，房间的帧历史已经覆盖不到本机停下的那个 tick。
## 补不全就不放进来：补一半等于把本机丢到一个它从没模拟过的 tick 上，
## 而那正是重连想避免的不同步本身。
const CLOSE_CANNOT_RESUME := 4007

## 模拟节拍。必须等于 1 / SimClock.TICK_SECONDS：服务端按这个频率泵帧，
## 客户端一帧一 tick，绝不自行推进服务端没发过的 tick。
const TICK_HZ := 20

## 房间为重连保留的帧数（30 秒）。客户端的帧队列上限不能小于它，
## 否则一次完整回放会在入队时就被自己丢掉几帧。
const FRAME_HISTORY_LIMIT := 600

## 一切跨线并进入模拟层的浮点的定点标度。
## 它刻意等于 SimWorld.POSITION_QUANTIZATION：模拟层本来就把玩家位置
## 舍入到毫米，把舍入后的整数发出去，就意味着各端喂进模拟层的值逐位相同，
## 谁也不必信任自己那一端的浮点格式化。
const QUANT := 1000.0

## PlayerCommand.b 里打包的输入位。
const BIT_USE_PRESSED := 1 << 0
const BIT_USE_JUST_PRESSED := 1 << 1
const BIT_PREV_EQUIPMENT := 1 << 2
const BIT_NEXT_EQUIPMENT := 1 << 3
const BIT_CONFIRM := 1 << 4
const BIT_ALIVE := 1 << 5
const BIT_PRESENT := 1 << 6

## 一个 tick 内玩家抬起的模拟层请求种类。
const EVENT_SHOT := 0
const EVENT_MELEE := 1
const EVENT_SPREAD_RESET := 2
const EVENT_SHOP_PURCHASE := 3
const EVENT_PLACE_ITEM := 4

const MAX_PLAYER_SLOTS := 4

## 跨线内容标识（角色 id、地图 id）的长度上限。
## 服务端存着同一个数字并按同样的形状拒收，双向常量对拍守护两者相等。
## 之所以是「形状校验」而不是「白名单」：服务端不认识游戏内容，
## 维护一份 id 白名单意味着每加一个角色都要发一次 Worker。
const CONTENT_ID_MAX_LENGTH := 32

static func is_valid_content_id(value: String) -> bool:
	if value.length() == 0 or value.length() > CONTENT_ID_MAX_LENGTH:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var is_lower := code >= 97 and code <= 122
		var is_digit := code >= 48 and code <= 57
		var is_underscore := code == 95
		if not (is_lower or is_digit or is_underscore):
			return false
	return true

static func quantize(value: float) -> int:
	return roundi(value * QUANT)

static func dequantize(value: int) -> float:
	return float(value) / QUANT

static func quantize_pair(value: Vector2) -> Array:
	return [roundi(value.x * QUANT), roundi(value.y * QUANT)]

static func dequantize_pair(value) -> Vector2:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		return Vector2.ZERO
	var pair := value as Array
	return Vector2(float(pair[0]) / QUANT, float(pair[1]) / QUANT)

## 把一份输入状态压成位。
##
## 边沿位（*_just_pressed）必须由调用方**跨物理帧累积**后再打包：
## 玩家层每物理帧采样一次（60Hz），命令每 tick 才发一次（20Hz），
## 直接取「发送那一刻的那一次采样」会丢掉三分之二的边沿——按下换枪键
## 有很大概率根本传不出去，远端看到的武器就和本机不是同一把。
static func bits_from_state(input_state, alive: bool, present: bool) -> int:
	var bits := 0
	if input_state != null:
		if input_state.use_pressed:
			bits |= BIT_USE_PRESSED
		if input_state.use_just_pressed:
			bits |= BIT_USE_JUST_PRESSED
		if input_state.previous_equipment_just_pressed:
			bits |= BIT_PREV_EQUIPMENT
		if input_state.next_equipment_just_pressed:
			bits |= BIT_NEXT_EQUIPMENT
		if input_state.confirm_just_pressed:
			bits |= BIT_CONFIRM
	if alive:
		bits |= BIT_ALIVE
	if present:
		bits |= BIT_PRESENT
	return bits

## 一次性的位：广播后服务端会把它们抹掉，本机也必须在发出后清掉。
## 「按住」与存活/在场则可以安全重复。
const ONE_SHOT_BITS := (
	BIT_USE_JUST_PRESSED | BIT_PREV_EQUIPMENT | BIT_NEXT_EQUIPMENT | BIT_CONFIRM
)

## 把一份本地输入打包成一个 tick 的命令。
## 只有「按住」类状态会在丢包时被服务端重复；边沿与事件是一次性的，
## 服务端在广播后就把它们抹掉。
static func pack_command(
	move_vector: Vector2,
	input_state,
	world_position: Vector2,
	alive: bool,
	present: bool,
	events: Array,
	frame_hash: String,
	wave_requested: bool
) -> Dictionary:
	return pack_command_bits(
		move_vector,
		bits_from_state(input_state, alive, present),
		world_position,
		events,
		frame_hash,
		wave_requested
	)

static func pack_command_bits(
	move_vector: Vector2,
	bits: int,
	world_position: Vector2,
	events: Array,
	frame_hash: String,
	wave_requested: bool
) -> Dictionary:
	var command := {
		"m": quantize_pair(move_vector),
		"b": bits,
		"p": quantize_pair(world_position),
	}
	if not events.is_empty():
		command["e"] = events
	if frame_hash != "":
		command["h"] = frame_hash
	if wave_requested:
		command["w"] = true
	return command

## 模拟层请求 -> 线上事件。所有数值在这里就量化，收端一律按同一标度还原，
## 于是「谁发的」不影响「算出什么」。
static func pack_shot_event(
	profile_index: int,
	origin: Vector3,
	aim_direction: Vector3
) -> Dictionary:
	return {
		"k": EVENT_SHOT,
		"w": profile_index,
		"o": quantize_pair(Vector2(origin.x, origin.z)),
		"oy": quantize(origin.y),
		"a": quantize_pair(Vector2(aim_direction.x, aim_direction.z)),
	}

static func pack_melee_event(
	damage: float,
	reach: float,
	half_width: float,
	origin: Vector3,
	aim_direction: Vector3
) -> Dictionary:
	return {
		"k": EVENT_MELEE,
		"d": quantize(damage),
		"r": quantize(reach),
		"hw": quantize(half_width),
		"o": quantize_pair(Vector2(origin.x, origin.z)),
		"oy": quantize(origin.y),
		"a": quantize_pair(Vector2(aim_direction.x, aim_direction.z)),
	}

static func pack_spread_reset_event(profile_index: int) -> Dictionary:
	return {"k": EVENT_SPREAD_RESET, "w": profile_index}

## 波间商店购买事件（联机装备/被动/弹药购买）。
## 属性/回血购买不走网络事件——它们直接进模拟（各端从同一商店种子的同一次购买
## 命令算出同一结果）。
##
## 协议只透传最小 int 字段，数据内容用**商品索引 si**承载：各端对同一波有同一份
## _shop_offers（确定性生成），收端用 si 反查商品定义，服务端无需理解商品内容。
## t = offer_type int（0=weapon/1=passive/2=ammo，与 ShopOfferDefinition 对齐）。
static func pack_shop_purchase_event(
	offer_type: int,
	price: int,
	offer_index: int
) -> Dictionary:
	return {
		"k": EVENT_SHOP_PURCHASE,
		"t": offer_type,
		"p": price,
		"si": offer_index,
	}

## 放置事件（油桶）。
##
## 带的是**格子号**而不是世界坐标：格子是整数，本来就不需要量化，而且「放哪一格」
## 是放置者当场决定的——那个判断要做物理查询（那格上此刻有没有人站着），各端
## 本来就算不出同一个答案。把结论发出去，各端照着放，才是同一个桶。
##
## pi = 放置者装备栏里这件可放置物的下标；各端为同一座位建的是同一份 loadout，
## 因此收端用它就能取回同一个 item_scene，协议不必认识「油桶」是什么。
static func pack_place_item_event(
	placeable_index: int,
	cell: Vector2i
) -> Dictionary:
	return {
		"k": EVENT_PLACE_ITEM,
		"pi": placeable_index,
		"ci": cell.x,
		"cj": cell.y,
	}

static func command_has_bit(command: Dictionary, bit: int) -> bool:
	return (int(command.get("b", 0)) & bit) != 0

static func command_move_vector(command: Dictionary) -> Vector2:
	return dequantize_pair(command.get("m", [0, 0]))

static func command_position(command: Dictionary) -> Vector2:
	return dequantize_pair(command.get("p", [0, 0]))

static func command_events(command: Dictionary) -> Array:
	var events = command.get("e", [])
	return events if typeof(events) == TYPE_ARRAY else []
