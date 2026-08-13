extends SceneTree

## 联机帧同步的源码级验证。三件事，每一件都是这套设计真正依赖的前提：
##
##   1. 客户端与服务端的协议常量一致（版本号、量化标度、输入位）。
##      两个仓库各存一份常量，靠这里对拍而不是靠自觉。
##   2. 量化往返不丢精度到影响模拟的程度：跨线的浮点必须以整数形式过网，
##      收端还原出的值要与发端**逐位**相同，否则各端喂进模拟层的就不是同一个数。
##   3. 同一串帧喂给两个独立的 SimWorld，逐 tick 哈希必须始终相等。
##      这一条就是「输入+位置广播」能替代全量帧同步的全部理由：
##      玩家位移不必确定，因为位置本身是输入。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_online_frame_sync.gd

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const SimWaveDirectorScript = preload("res://scripts/sim/sim_wave_director.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const PlayerInputStateScript = preload("res://scripts/input/player_input_state.gd")

const SERVER_PROTOCOL_PATH := "res://server/src/lib/protocol.ts"
const TICK_COUNT := 900
const ROOM_SEED := 20260810
const INPUT_SEED := 4399
const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const PLAYER_SLOT_COUNT := 4
const SHOT_INTERVAL_TICKS := 17
const WAVE_INTERVAL_TICKS := 150
const MUZZLE_HEIGHT := 1.1
const ZOMBIE_MAX_HEALTH := 50
const ZOMBIE_PROFILE := 0

const RIFLE_PROFILE := 0
const RIFLE_DAMAGE := 25.0
const RIFLE_RANGE := 28.0
const RIFLE_BASE_SPREAD := 0.5
const RIFLE_MAX_SPREAD := 5.0
const RIFLE_SPREAD_INCREASE := 0.65
const RIFLE_SPREAD_RECOVERY := 1.5

const BLOCKER_RECTS: Array[Rect2] = [
	Rect2(Vector2(-24.5, -19.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, 18.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(23.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(-14.1, -12.05), Vector2(6.2, 2.5)),
	Rect2(Vector2(7.9, 5.75), Vector2(6.2, 2.5)),
	Rect2(Vector2(-6.0, -2.0), Vector2(12.0, 1.0)),
]

static func spawn_points() -> Array[Dictionary]:
	return [
		{"spawn_id": &"north_east", "position": Vector2(19.0, -14.0), "radius": 1.75, "spacing": 1.1},
		{"spawn_id": &"north_west", "position": Vector2(-19.0, -14.0), "radius": 1.75, "spacing": 1.1},
		{"spawn_id": &"south_east", "position": Vector2(19.0, 14.0), "radius": 1.75, "spacing": 1.1},
		{"spawn_id": &"south_west", "position": Vector2(-19.0, 14.0), "radius": 1.75, "spacing": 1.1},
	]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	failures.append_array(_check_protocol_constants())
	failures.append_array(_check_quantization_round_trip())
	failures.append_array(_check_frame_replay_determinism())

	if failures.is_empty():
		print("validate_online_frame_sync: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_online_frame_sync: %s" % failure)
	printerr("validate_online_frame_sync: FAIL (%d)" % failures.size())
	quit(1)

## 1. 两个仓库的协议常量必须字面相等。
func _check_protocol_constants() -> Array[String]:
	var failures: Array[String] = []
	if not FileAccess.file_exists(SERVER_PROTOCOL_PATH):
		return ["找不到服务端协议文件 %s" % SERVER_PROTOCOL_PATH]
	var source := FileAccess.get_file_as_string(SERVER_PROTOCOL_PATH)

	var expected := {
		"PROTOCOL_VERSION": LobbyProtocolScript.PROTOCOL_VERSION,
		"QUANT": int(LobbyProtocolScript.QUANT),
		"TICK_HZ": LobbyProtocolScript.TICK_HZ,
		"BIT_USE_PRESSED": LobbyProtocolScript.BIT_USE_PRESSED,
		"BIT_USE_JUST_PRESSED": LobbyProtocolScript.BIT_USE_JUST_PRESSED,
		"BIT_PREV_EQUIPMENT": LobbyProtocolScript.BIT_PREV_EQUIPMENT,
		"BIT_NEXT_EQUIPMENT": LobbyProtocolScript.BIT_NEXT_EQUIPMENT,
		"BIT_CONFIRM": LobbyProtocolScript.BIT_CONFIRM,
		"BIT_ALIVE": LobbyProtocolScript.BIT_ALIVE,
		"BIT_PRESENT": LobbyProtocolScript.BIT_PRESENT,
		"EVENT_SHOT": LobbyProtocolScript.EVENT_SHOT,
		"EVENT_MELEE": LobbyProtocolScript.EVENT_MELEE,
		"EVENT_SPREAD_RESET": LobbyProtocolScript.EVENT_SPREAD_RESET,
		"EVENT_SHOP_PURCHASE": LobbyProtocolScript.EVENT_SHOP_PURCHASE,
		"EVENT_PLACE_ITEM": LobbyProtocolScript.EVENT_PLACE_ITEM,
		"CLOSE_PROTOCOL_MISMATCH": LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH,
		"CLOSE_ROOM_FULL": LobbyProtocolScript.CLOSE_ROOM_FULL,
		"CLOSE_RECONNECTED_ELSEWHERE": LobbyProtocolScript.CLOSE_RECONNECTED_ELSEWHERE,
		"CLOSE_CANNOT_RESUME": LobbyProtocolScript.CLOSE_CANNOT_RESUME,
		"FRAME_HISTORY_LIMIT": LobbyProtocolScript.FRAME_HISTORY_LIMIT,
		"CONTENT_ID_MAX_LENGTH": LobbyProtocolScript.CONTENT_ID_MAX_LENGTH,
	}
	for name in expected.keys():
		var server_value = _read_ts_constant(source, String(name))
		if server_value == null:
			failures.append("服务端协议里读不到常量 %s" % name)
			continue
		if int(server_value) != int(expected[name]):
			failures.append(
				"协议常量 %s 不一致：客户端 %d，服务端 %d" % [
					name, int(expected[name]), int(server_value)
				]
			)

	# 位掩码不能重叠，否则「刚按下」与「还活着」会互相顶掉。
	var seen_bits := 0
	for bit_name in [
		"BIT_USE_PRESSED", "BIT_USE_JUST_PRESSED", "BIT_PREV_EQUIPMENT",
		"BIT_NEXT_EQUIPMENT", "BIT_CONFIRM", "BIT_ALIVE", "BIT_PRESENT",
	]:
		var bit := int(expected[bit_name])
		if seen_bits & bit != 0:
			failures.append("输入位 %s 与其它位重叠" % bit_name)
		seen_bits |= bit

	# 量化标度必须与模拟层对玩家位置的舍入完全相同。不同的话，
	# 「发出去的整数」与「模拟层实际用的整数」就是两个数。
	if int(LobbyProtocolScript.QUANT) != int(SimWorldScript.POSITION_QUANTIZATION):
		failures.append(
			"QUANT %d 与 SimWorld.POSITION_QUANTIZATION %d 不一致" % [
				int(LobbyProtocolScript.QUANT),
				int(SimWorldScript.POSITION_QUANTIZATION),
			]
		)
	# 服务端按 TICK_HZ 泵帧，客户端按 TICK_SECONDS 走 tick，两者必须互为倒数。
	if not is_equal_approx(1.0 / float(LobbyProtocolScript.TICK_HZ), SimClockTickSeconds()):
		failures.append(
			"TICK_HZ %d 与 SimClock.TICK_SECONDS %f 不互为倒数" % [
				LobbyProtocolScript.TICK_HZ, SimClockTickSeconds()
			]
		)
	return failures

func SimClockTickSeconds() -> float:
	return preload("res://scripts/sim/sim_clock.gd").TICK_SECONDS

func _read_ts_constant(source: String, name: String):
	# 位移形式必须先认。`1 << 3` 的开头就是一个合法的十进制字面量，
	# 先跑字面量那条正则的话，每一个位标志都会被读成 1，而六个都读成 1
	# 看上去就像「服务端把所有位都设成了同一个值」——一个根本不存在的故障。
	var shift_regex := RegEx.new()
	shift_regex.compile("export const %s\\s*=\\s*1\\s*<<\\s*(\\d+)\\s*;" % name)
	var shift_found := shift_regex.search(source)
	if shift_found != null:
		return 1 << int(shift_found.get_string(1))
	var regex := RegEx.new()
	regex.compile("export const %s\\s*=\\s*(0x[0-9a-fA-F]+|\\d+)\\s*;" % name)
	var found := regex.search(source)
	if found == null:
		return null
	var raw := found.get_string(1)
	if raw.begins_with("0x"):
		return raw.hex_to_int()
	return int(raw)

## 2. 量化往返。位置、瞄准、伤害都要在还原后与「模拟层会用的那个值」相等。
func _check_quantization_round_trip() -> Array[String]:
	var failures: Array[String] = []
	var samples := [
		Vector2(0.0, 0.0),
		Vector2(1.0005, -2.4994),
		Vector2(-19.0, 14.0),
		Vector2(23.4999, -19.5001),
		Vector2(0.0004, -0.0004),
	]
	for sample in samples:
		var packed := LobbyProtocolScript.quantize_pair(sample)
		var restored: Vector2 = LobbyProtocolScript.dequantize_pair(packed)
		# 收端还原出的值，必须与模拟层对同一个原始坐标的舍入结果一致。
		var sim_rounded := Vector2(
			float(roundi(sample.x * SimWorldScript.POSITION_QUANTIZATION))
				/ SimWorldScript.POSITION_QUANTIZATION,
			float(roundi(sample.y * SimWorldScript.POSITION_QUANTIZATION))
				/ SimWorldScript.POSITION_QUANTIZATION
		)
		if restored != sim_rounded:
			failures.append(
				"量化往返 %s -> %s，模拟层却会用 %s" % [sample, restored, sim_rounded]
			)

	var input_state = PlayerInputStateScript.new()
	input_state.use_pressed = true
	input_state.use_just_pressed = true
	input_state.next_equipment_just_pressed = true
	var command := LobbyProtocolScript.pack_command(
		Vector2(0.6, -0.8), input_state, Vector2(3.125, -4.5), true, true, [], "", true
	)
	for expectation in [
		[LobbyProtocolScript.BIT_USE_PRESSED, true],
		[LobbyProtocolScript.BIT_USE_JUST_PRESSED, true],
		[LobbyProtocolScript.BIT_NEXT_EQUIPMENT, true],
		[LobbyProtocolScript.BIT_PREV_EQUIPMENT, false],
		[LobbyProtocolScript.BIT_CONFIRM, false],
		[LobbyProtocolScript.BIT_ALIVE, true],
		[LobbyProtocolScript.BIT_PRESENT, true],
	]:
		var has: bool = LobbyProtocolScript.command_has_bit(command, int(expectation[0]))
		if has != bool(expectation[1]):
			failures.append("命令位 %d 打包结果为 %s，应为 %s" % [
				int(expectation[0]), has, bool(expectation[1])
			])
	if command.get("w", false) != true:
		failures.append("请求开波的标记没有进命令")
	if LobbyProtocolScript.command_position(command) != Vector2(3.125, -4.5):
		failures.append("命令位置往返不一致")

	# JSON 是真正的线格式。经过一次编解码后所有字段必须原样还在：
	# 整数被 JSON 还原成浮点是这里最容易出事的地方。
	var round_tripped = JSON.parse_string(JSON.stringify(command))
	if typeof(round_tripped) != TYPE_DICTIONARY:
		failures.append("命令无法通过 JSON 往返")
	elif LobbyProtocolScript.command_position(round_tripped) != Vector2(3.125, -4.5):
		failures.append("命令经 JSON 往返后位置改变")
	return failures

## 3. 同一串帧 -> 两个独立世界 -> 逐 tick 哈希必须相等。
func _check_frame_replay_determinism() -> Array[String]:
	var failures: Array[String] = []
	var frames := _build_frames(TICK_COUNT)

	var hashes_a := _replay(frames)
	var hashes_b := _replay(frames)
	if hashes_a.size() != hashes_b.size():
		return ["两次回放的 tick 数不同：%d vs %d" % [hashes_a.size(), hashes_b.size()]]
	for index in range(hashes_a.size()):
		if hashes_a[index] != hashes_b[index]:
			failures.append(
				"第 %d tick 帧哈希分叉：%s vs %s" % [index, hashes_a[index], hashes_b[index]]
			)
			break

	# 只改一个 tick 里一个座位的一个毫米，哈希必须变。否则这套对拍
	# 根本发现不了不同步，「两次跑出来一样」也就没有任何意义。
	var mutated := frames.duplicate(true)
	var target: Dictionary = mutated[TICK_COUNT / 2]
	var slot_command: Dictionary = target["s"][0]
	slot_command["p"] = [int(slot_command["p"][0]) + 1, int(slot_command["p"][1])]
	var hashes_c := _replay(mutated)
	if hashes_c == hashes_a:
		failures.append("改动一个座位的一毫米后帧哈希没有变化，哈希对拍是无效的")
	return failures

func _replay(frames: Array) -> Array:
	var world = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	for rect in BLOCKER_RECTS:
		world.set_blocker_world_rect(rect.position, rect.end, true)
	world.reset(ROOM_SEED)
	world.configure_zombie_profile(ZOMBIE_PROFILE, ZOMBIE_MAX_HEALTH, 1.30)
	world.configure_weapon_profile(
		RIFLE_PROFILE,
		RIFLE_DAMAGE,
		RIFLE_RANGE,
		RIFLE_BASE_SPREAD,
		RIFLE_MAX_SPREAD,
		RIFLE_SPREAD_INCREASE,
		RIFLE_SPREAD_RECOVERY,
		2,
		0.65
	)
	world.set_perception_range(60.0)
	var waves: Array[Dictionary] = [{
		"spawn_interval_ticks": 0,
		"entries": [{"profile_index": ZOMBIE_PROFILE, "count": 300}],
	}]
	world.configure_wave_schedule(
		waves, spawn_points(), SimWaveDirectorScript.EndMode.LOOP, 30, 300
	)
	world.start_wave_schedule()

	var hashes: Array = []
	for frame in frames:
		var slot_commands: Array = frame["s"]
		for slot in range(SimWorldScript.MAX_PLAYER_SLOTS):
			var command = slot_commands[slot] if slot < slot_commands.size() else null
			if typeof(command) != TYPE_DICTIONARY:
				world.set_player_snapshot(slot, Vector2.ZERO, false, false)
				continue
			world.set_player_snapshot(
				slot,
				LobbyProtocolScript.command_position(command),
				LobbyProtocolScript.command_has_bit(command, LobbyProtocolScript.BIT_ALIVE),
				LobbyProtocolScript.command_has_bit(command, LobbyProtocolScript.BIT_PRESENT)
			)
			for event in LobbyProtocolScript.command_events(command):
				_apply_event(world, slot, event)
		if bool(frame.get("w", false)):
			world.request_advance_wave()
		world.step_tick()
		hashes.append(SimHasherScript.hash_world(world))
	return hashes

func _apply_event(world, slot: int, event: Dictionary) -> void:
	var kind := int(event.get("k", -1))
	if kind == LobbyProtocolScript.EVENT_SHOT:
		world.queue_fire_event(
			slot,
			int(event.get("w", -1)),
			LobbyProtocolScript.dequantize_pair(event.get("o", [0, 0])),
			LobbyProtocolScript.dequantize(int(event.get("oy", 0))),
			LobbyProtocolScript.dequantize_pair(event.get("a", [0, 0]))
		)
		return
	if kind == LobbyProtocolScript.EVENT_SPREAD_RESET:
		world.queue_spread_reset(slot, int(event.get("w", -1)))

## 造一串「像真的一样」的帧：四个玩家绕圈走、周期性开火、周期性开波。
## 位置直接以量化整数生成——线上本来就只有整数，测试也不该比线上更宽松。
func _build_frames(tick_count: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = INPUT_SEED
	var frames: Array = []
	for tick in range(tick_count):
		var slot_commands: Array = []
		for slot in range(PLAYER_SLOT_COUNT):
			var angle := float(tick) * 0.03 + float(slot) * (TAU / float(PLAYER_SLOT_COUNT))
			var radius := 6.0 + 2.0 * sin(float(tick) * 0.011 + float(slot))
			var position := Vector2(cos(angle) * radius, sin(angle) * radius)
			var move := Vector2(-sin(angle), cos(angle))
			var events: Array = []
			if tick % SHOT_INTERVAL_TICKS == slot:
				var aim := Vector2(
					rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)
				).normalized()
				events.append({
					"k": LobbyProtocolScript.EVENT_SHOT,
					"w": RIFLE_PROFILE,
					"o": LobbyProtocolScript.quantize_pair(position),
					"oy": LobbyProtocolScript.quantize(MUZZLE_HEIGHT),
					"a": LobbyProtocolScript.quantize_pair(aim),
				})
			var command := {
				"m": LobbyProtocolScript.quantize_pair(move),
				"b": LobbyProtocolScript.BIT_ALIVE | LobbyProtocolScript.BIT_PRESENT,
				"p": LobbyProtocolScript.quantize_pair(position),
			}
			if not events.is_empty():
				command["e"] = events
			slot_commands.append(command)
		var frame := {"t": tick, "s": slot_commands}
		if tick % WAVE_INTERVAL_TICKS == 0:
			frame["w"] = true
		frames.append(frame)
	return frames
