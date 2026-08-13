extends RefCounted
class_name DeterministicRng

## 自实现 PCG32-XSH-RR。不使用 Godot 的 RandomNumberGenerator：
## 其内部实现不保证跨版本稳定，而帧同步要求逐位一致。
## 只能在末尾追加：每条流的初始 state 由 room_seed 加流下标派生，
## 往中间插一条会把它后面所有流的种子整体挪位，等于换了一局的随机序列。
enum Stream {
	ZOMBIE_WANDER,
	ZOMBIE_SPAWN,
	WEAPON_SPREAD,
	LOOT_DROP,
	SHOP,
	WEAPON_CRIT,
}

const STREAM_COUNT := 6
const UINT32_MASK := 0xFFFFFFFF
const INVERSE_UINT32 := 1.0 / 4294967296.0
const STREAM_SALT := 0x9E3779B1

# 0x5851F42D4C957F2D 的 16 位 limb（低位在前）
const MULTIPLIER_LIMB_0 := 0x7F2D
const MULTIPLIER_LIMB_1 := 0x4C95
const MULTIPLIER_LIMB_2 := 0xF42D
const MULTIPLIER_LIMB_3 := 0x5851
# 0x14057B7EF767814F 的 16 位 limb（低位在前）
const INCREMENT_LIMB_0 := 0x814F
const INCREMENT_LIMB_1 := 0xF767
const INCREMENT_LIMB_2 := 0x7B7E
const INCREMENT_LIMB_3 := 0x1405

var state_low := PackedInt64Array()
var state_high := PackedInt64Array()

func _init() -> void:
	state_low.resize(STREAM_COUNT)
	state_high.resize(STREAM_COUNT)
	seed_streams(0)

## 从房间种子加流 ID 派生每条流的初始 state。
## 任一子系统增删随机调用不会移动其他子系统的序列。
func seed_streams(room_seed: int) -> void:
	var seed_low := room_seed & UINT32_MASK
	var seed_high := (room_seed >> 32) & UINT32_MASK
	for stream_index in range(STREAM_COUNT):
		state_low[stream_index] = 0
		state_high[stream_index] = 0
		_advance(stream_index)
		_add(
			stream_index,
			(seed_high + stream_index) & UINT32_MASK,
			(seed_low + stream_index * STREAM_SALT) & UINT32_MASK
		)
		_advance(stream_index)
		_advance(stream_index)

func next_uint32(stream_index: int) -> int:
	var low := state_low[stream_index]
	var high := state_high[stream_index]
	_advance(stream_index)
	var shifted_low := ((low >> 18) | (high << 14)) & UINT32_MASK
	var shifted_high := high >> 18
	var xored_low := shifted_low ^ low
	var xored_high := shifted_high ^ high
	var xorshifted := ((xored_low >> 27) | (xored_high << 5)) & UINT32_MASK
	var rotation := (high >> 27) & 31
	return (
		(xorshifted >> rotation) | (xorshifted << ((32 - rotation) & 31))
	) & UINT32_MASK

## 返回 [0.0, 1.0) 区间的浮点数。
func next_unit_float(stream_index: int) -> float:
	return float(next_uint32(stream_index)) * INVERSE_UINT32

func next_range(stream_index: int, minimum: float, maximum: float) -> float:
	return minimum + (maximum - minimum) * next_unit_float(stream_index)

## 闭区间 [minimum, maximum]。取模偏置是可接受的：它是确定的。
func next_int_range(stream_index: int, minimum: int, maximum: int) -> int:
	var span := maxi(maximum - minimum + 1, 1)
	return minimum + next_uint32(stream_index) % span

## 供 SimHasher 纳入帧哈希：[low0, high0, low1, high1, ...]
func get_state_words() -> PackedInt64Array:
	var words := PackedInt64Array()
	words.resize(STREAM_COUNT * 2)
	for stream_index in range(STREAM_COUNT):
		words[stream_index * 2] = state_low[stream_index]
		words[stream_index * 2 + 1] = state_high[stream_index]
	return words

## state = state * MULTIPLIER + INCREMENT (mod 2^64)，用 16 位 limb 手工完成。
func _advance(stream_index: int) -> void:
	var low := state_low[stream_index]
	var high := state_high[stream_index]
	var limb_0 := low & 0xFFFF
	var limb_1 := (low >> 16) & 0xFFFF
	var limb_2 := high & 0xFFFF
	var limb_3 := (high >> 16) & 0xFFFF
	var column_0 := limb_0 * MULTIPLIER_LIMB_0 + INCREMENT_LIMB_0
	var column_1 := (
		limb_0 * MULTIPLIER_LIMB_1 +
		limb_1 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_1 +
		(column_0 >> 16)
	)
	var column_2 := (
		limb_0 * MULTIPLIER_LIMB_2 +
		limb_1 * MULTIPLIER_LIMB_1 +
		limb_2 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_2 +
		(column_1 >> 16)
	)
	var column_3 := (
		limb_0 * MULTIPLIER_LIMB_3 +
		limb_1 * MULTIPLIER_LIMB_2 +
		limb_2 * MULTIPLIER_LIMB_1 +
		limb_3 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_3 +
		(column_2 >> 16)
	)
	state_low[stream_index] = (column_0 & 0xFFFF) | ((column_1 & 0xFFFF) << 16)
	state_high[stream_index] = (column_2 & 0xFFFF) | ((column_3 & 0xFFFF) << 16)

func _add(stream_index: int, add_high: int, add_low: int) -> void:
	var total := state_low[stream_index] + add_low
	state_low[stream_index] = total & UINT32_MASK
	state_high[stream_index] = (
		state_high[stream_index] + add_high + (total >> 32)
	) & UINT32_MASK
