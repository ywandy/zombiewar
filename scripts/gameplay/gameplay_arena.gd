extends Node3D

signal restart_requested
## 波间商店阶段开始/结束。ShopPanel 连这两个信号控制显隐。
signal shop_phase_started(wave_number: int)
signal shop_phase_ended

const HitResult = preload("res://scripts/combat/hit_result.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const SinglePlayerInputSourceScript = preload(
	"res://scripts/input/single_player_input_source.gd"
)
const LocalTeamStateScript = preload("res://scripts/gameplay/local_team_state.gd")
const BARREL_PLACE_SOUND := preload("res://assets/sfx/boxhead/barrel_place.mp3")
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
const BLOOD_IMPACT_SCENE := preload("res://scenes/fx/BloodImpact.tscn")
const DAMAGE_POPUP_SCENE := preload("res://scenes/fx/DamagePopup.tscn")
const PICKUP_CHEST_SCENE := preload("res://scenes/gameplay/PickupChest.tscn")
const DEFAULT_SIM_SEED := 20260807
## 延迟 HUD 的刷新节流（秒）。RTT 本身更新更慢，更频繁地读没有信息量。
const PING_HUD_INTERVAL_SECONDS := 0.5
const PISTOL_DEFINITION := preload("res://resources/weapons/pistol.tres")
const SMG_DEFINITION := preload("res://resources/weapons/smg.tres")
const SHOTGUN_DEFINITION := preload("res://resources/weapons/shotgun.tres")
const RIFLE_DEFINITION := preload("res://resources/weapons/rifle.tres")
const WeaponModTableScript = preload("res://scripts/sim/weapon_mod_table.gd")
const HitStopStateScript = preload("res://scripts/fx/hit_stop_state.gd")
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const MetaBankerScript = preload("res://scripts/meta/meta_banker.gd")
const PauseMenuScript = preload("res://scripts/ui/pause_menu.gd")

@export var map_definition: MapDefinition
@export var zombie_difficulty: ZombieDifficultyProfile
@export var random_seed: int = 0

@onready var game_over_audio: AudioStreamPlayer = $GameOverAudio

var damage_flash_tween: Tween
var sim_clock = SimClockScript.new()
var sim_world = SimWorldScript.new()
## 表现层顿帧。只影响画面，模拟层照常按 tick 推进（见 HitStopState 的说明）。
var hit_stop = HitStopStateScript.new()
var map_runtime := GameMapRuntime.new()
var zombie_renderer: ZombieRenderer
var weapon_profile_indices: Dictionary = {}
## 模拟层油桶 id -> 表现节点。只做按 id 的键值查找，不遍历它驱动任何判定。
var barrel_views: Dictionary = {}
## 模拟层补给箱 id -> 表现节点，同上。
var chest_views: Dictionary = {}
## 伤害飘字生成序号，只用来给连续飘字取横向偏移错开，不参与任何判定。
var _damage_popup_spawn_index := 0
## 每个座位上一次弹出 MISS 的墙钟毫秒，用于限流（见 _spawn_miss_popup）。
var _last_miss_popup_msec: Dictionary = {}
var wave_number := 0
var team_defeated := false
var _ping_hud_timer := 0.0
var restart_pending := false
var startup_pending := false
var warmup_overlay_tween: Tween
## 波间商店：当前展示的商品（本波生成一次）。购买后重新计算金钱刷新 UI。
var _shop_offers: Array[ShopOfferDefinition] = []
var single_player_input = SinglePlayerInputSourceScript.new()
var players: Array[PlayerController] = []
## 背包镜像的复用缓冲。每 tick 逐座位刷一次，不能每次都新建数组。
var inventory_mirror_profiles := PackedInt32Array()
var inventory_mirror_amounts := PackedInt32Array()
var local_team_state = LocalTeamStateScript.new()

## 每隔这么多 tick 附一次帧哈希给服务端对拍。每 tick 都发是浪费，
## 隔太久则不同步会在被发现前先积累出一整场错误的战斗。
const ONLINE_HASH_INTERVAL_TICKS := 20

## 单个物理帧最多花在追帧上的墙钟毫秒数。见 _advance_online_ticks()：
## 重连补帧可能一次送来几百帧，没有这个预算就是一次几秒的冻结。
const CATCHUP_BUDGET_MSEC := 8

var online_mode := false
var online_slot := -1
var online_accumulator := 0.0
## 本机这一 tick 抬起的模拟层请求。联机下它们不直接进模拟层，
## 而是发给服务端、等它随帧回来再统一应用——各端于是在同一个 tick 上开火。
var pending_local_events: Array = []
var pending_wave_request := false
var online_started := false
var online_result_reported := false
var net_input_sources: Dictionary = {}
var online_kills: Dictionary = {}
## 自上一条命令发出以来累积的本机输入位与最新移动向量。
## 玩家层每物理帧采样一次而命令每 tick 才发一次，边沿位必须在这里攒着，
## 否则三次采样里只有一次能上网，换枪键按了往往传不出去。
var pending_input_bits := 0
var pending_move_vector := Vector2.ZERO

func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_wire_dependencies()

func _enter_tree() -> void:
	_wire_dependencies()

func _ready() -> void:
	startup_pending = true
	add_child(local_team_state)
	_detect_online_mode()
	_wire_dependencies()
	var map_errors := _setup_simulation()
	if not map_errors.is_empty():
		_handle_startup_failure("; ".join(map_errors))
		return
	if not _setup_map_renderer():
		_handle_startup_failure("GameplayArena renderer nodes are missing")
		return
	_register_map_entities()
	if not _spawn_session_players():
		_handle_player_spawn_failure()
		return
	local_team_state.all_players_defeated.connect(_on_all_players_defeated)
	local_team_state.setup(players)
	_wire_pause_menu()
	_set_touch_game_over_active(false)
	_wire_runtime_dependencies()
	sim_world.start_wave_schedule()
	_update_wave_hud()
	_sync_command_controls()
	if DisplayServer.get_name() == "headless":
		_complete_combat_startup(false)
		return
	for player in players:
		player.set_physics_process(false)
	call_deferred("_run_combat_startup")

func _process(delta: float) -> void:
	if (
		team_defeated and
		not restart_pending and
		local_team_state.sample_restart_requested()
	):
		request_restart()
	_update_ping_hud(delta)
	_sync_shop_hud()
	hit_stop.advance(delta)
	if zombie_renderer != null:
		var frozen := hit_stop.is_frozen()
		zombie_renderer.set_visual_frozen(frozen)
		# 顿帧期间整个跳过 render_frame：僵尸的插值位置、远景 MultiMesh 变换与
		# 淡入淡出都停在触发的那一帧。模拟层不受影响——它在 _physics_process 里
		# 照常推进，顿帧结束后画面直接对齐到那时的真实状态。
		if not frozen:
			zombie_renderer.render_frame(
				sim_world,
				_interpolation_alpha(),
				delta
			)

func _physics_process(delta: float) -> void:
	if startup_pending or zombie_renderer == null:
		return
	if online_mode:
		_advance_online_ticks(delta)
		return
	var ticks := sim_clock.consume_frame(delta)
	for _tick_offset in range(ticks):
		_push_player_snapshot()
		sim_world.step_tick()
		_consume_sim_events()
		zombie_renderer.sync_lod(sim_world)

func get_sim_world() -> SimWorld:
	return sim_world

func _interpolation_alpha() -> float:
	if online_mode:
		return clampf(online_accumulator / SimClockScript.TICK_SECONDS, 0.0, 1.0)
	return sim_clock.get_interpolation_alpha()

func _detect_online_mode() -> void:
	var session := get_node_or_null("/root/GameSession")
	online_mode = (
		session != null and
		session.mode == GameSessionScript.Mode.ONLINE_MULTIPLAYER
	)
	if not online_mode:
		return
	var net := get_node_or_null("/root/NetSession")
	online_slot = net.local_slot if net != null else -1

## 联机的推进入口。
##
## 墙钟只决定「什么时候想推进一个 tick」，能不能推进由服务端的帧说了算：
## 队列空就原地等。客户端自行补一个服务端没发过的 tick，等于凭空发明了
## 一段其他人都没有的历史，而那正是不同步的定义。
func _advance_online_ticks(delta: float) -> void:
	var net := get_node_or_null("/root/NetSession")
	if net == null or net.room == null:
		return
	var room = net.room
	_accumulate_local_input()
	online_accumulator += delta
	var spent := 0
	while (
		online_accumulator >= SimClockScript.TICK_SECONDS and
		spent < SimClockScript.MAX_CATCHUP_TICKS
	):
		var frame = room.pop_frame()
		if frame == null:
			# 欠账钳到一个 tick：不钳会在断流期间攒出一大笔，等帧一到就
			# 连推 MAX_CATCHUP_TICKS 个 tick，画面直接跳一大段。
			online_accumulator = minf(online_accumulator, SimClockScript.TICK_SECONDS)
			return
		online_accumulator -= SimClockScript.TICK_SECONDS
		spent += 1
		_apply_online_frame(frame)
	# 落后太多（切后台、长卡顿、重连补帧）时额外追帧：按正常节奏一帧一 tick
	# 永远追不上，因为帧还在以同样的速度到来。
	#
	# 但也不能一口气追完。重连时房间会把断线期间的整段帧一次补齐，那可能是
	# 几百帧；几百个 tick 挤进一个物理帧会把画面冻住好几秒，在 Web 上足够
	# 触发浏览器的无响应提示。分摊到多个物理帧上仍然一定追得上——回放一个
	# tick 远快于 50 毫秒，只要每帧多吐几个就在净收敛。
	var catchup: int = room.catchup_frames()
	var deadline := Time.get_ticks_msec() + CATCHUP_BUDGET_MSEC
	while catchup > 0:
		var frame = room.pop_frame()
		if frame == null:
			break
		_apply_online_frame(frame)
		catchup -= 1
		if Time.get_ticks_msec() >= deadline:
			break

func _apply_online_frame(frame: Dictionary) -> void:
	var slot_commands = frame.get("s", [])
	if typeof(slot_commands) != TYPE_ARRAY:
		slot_commands = []
	for slot in range(SimWorldScript.MAX_PLAYER_SLOTS):
		var command = slot_commands[slot] if slot < slot_commands.size() else null
		if typeof(command) != TYPE_DICTIONARY:
			sim_world.set_player_snapshot(slot, Vector2.ZERO, false, false)
			var idle_source = net_input_sources.get(slot)
			if idle_source != null:
				idle_source.clear()
			continue
		_apply_slot_command(slot, command as Dictionary)
	if bool(frame.get("w", false)):
		sim_world.request_advance_wave()
	sim_world.step_tick()
	_consume_sim_events()
	zombie_renderer.sync_lod(sim_world)
	_tally_online_kills()
	_send_online_command(int(frame.get("t", -1)))

## 一个座位在这一 tick 做了什么。
##
## 位置进模拟层的是**帧里那一份**，本机玩家也不例外：本机的身体可以跑在
## 前面（那是手感），但僵尸追谁、谁被咬到，全世界必须读同一个坐标。
func _apply_slot_command(slot: int, command: Dictionary) -> void:
	var position := LobbyProtocolScript.command_position(command)
	var alive := LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_ALIVE
	)
	var present := LobbyProtocolScript.command_has_bit(
		command, LobbyProtocolScript.BIT_PRESENT
	)
	sim_world.set_player_snapshot(slot, position, alive, present)
	var source = net_input_sources.get(slot)
	if source != null:
		source.apply_command(command)
	var player := _player_for_slot(slot)
	if player != null and slot != online_slot:
		player.set_network_position_target(
			Vector3(position.x, player.global_position.y, position.y)
		)
	for event in LobbyProtocolScript.command_events(command):
		if typeof(event) == TYPE_DICTIONARY:
			_queue_online_event(slot, event as Dictionary)

func _queue_online_event(slot: int, event: Dictionary) -> void:
	var kind := int(event.get("k", -1))
	if kind == LobbyProtocolScript.EVENT_SHOT:
		sim_world.queue_fire_event(
			slot,
			int(event.get("w", -1)),
			LobbyProtocolScript.dequantize_pair(event.get("o", [0, 0])),
			LobbyProtocolScript.dequantize(int(event.get("oy", 0))),
			LobbyProtocolScript.dequantize_pair(event.get("a", [0, 0]))
		)
		return
	if kind == LobbyProtocolScript.EVENT_MELEE:
		sim_world.queue_melee_event(
			slot,
			LobbyProtocolScript.dequantize(int(event.get("d", 0))),
			LobbyProtocolScript.dequantize(int(event.get("r", 0))),
			LobbyProtocolScript.dequantize(int(event.get("hw", 0))),
			LobbyProtocolScript.dequantize_pair(event.get("o", [0, 0])),
			LobbyProtocolScript.dequantize(int(event.get("oy", 0))),
			LobbyProtocolScript.dequantize_pair(event.get("a", [0, 0]))
		)
		return
	if kind == LobbyProtocolScript.EVENT_SPREAD_RESET:
		sim_world.queue_spread_reset(slot, int(event.get("w", -1)))
		return
	if kind == LobbyProtocolScript.EVENT_SHOP_PURCHASE:
		# 联机商店购买落地：各端从同一份确定性 _shop_offers 反查商品，应用同一效果。
		# 属性/回血/改装件购买不走这里（它们进模拟命令）；这里只处理背包身份类：
		# 武器/被动/弹药/油桶。新增 offer_type 时这份白名单要跟着加，漏了的表现是
		# 「联机买了不生效、单机正常」。
		var offer_index := int(event.get("si", -1))
		if offer_index >= 0 and offer_index < _shop_offers.size():
			var offer := _shop_offers[offer_index]
			if offer.offer_type == ShopOfferDefinition.OfferType.WEAPON \
					or offer.offer_type == ShopOfferDefinition.OfferType.PASSIVE \
					or offer.offer_type == ShopOfferDefinition.OfferType.AMMO \
					or offer.offer_type == ShopOfferDefinition.OfferType.OIL:
				_buy_equipment_local(slot, offer)
		return
	if kind == LobbyProtocolScript.EVENT_PLACE_ITEM:
		# 放置落地：各端在同一 tick 上按同一个格子号执行，因此得到同一个桶。
		# 「能不能放」是放置者当场决定的（含物理查询），这里不再复核。
		_apply_place_item(
			slot,
			int(event.get("pi", -1)),
			Vector2i(int(event.get("ci", 0)), int(event.get("cj", 0)))
		)

## 击杀归属取射击事件的 slot。带穿透的一枪可能带走多个目标而这里只记一次，
## 是刻意的取舍：所有客户端读的是同一批事件，因此少算得**一模一样**，
## 而服务端的多数投票要的正是「大家算出同一个数」，不是「算得绝对准」。
func _tally_online_kills() -> void:
	for event in sim_world.tick_shot_events:
		if bool(event.get("killed", false)):
			var slot := int(event.get("slot", -1))
			if slot >= 0:
				online_kills[slot] = int(online_kills.get(slot, 0)) + 1

## 把本机这一 tick 的输入、位置与请求发出去。
## 发送频率天然等于服务端泵帧频率：每消费一帧就回一条。
func _send_online_command(tick_index: int) -> void:
	var net := get_node_or_null("/root/NetSession")
	if net == null or net.room == null:
		return
	var player := _player_for_slot(online_slot)
	var position := Vector2.ZERO
	if player != null:
		position = Vector2(player.global_position.x, player.global_position.z)
	var bits := pending_input_bits
	if player != null:
		bits |= LobbyProtocolScript.BIT_PRESENT
		if player.is_alive():
			bits |= LobbyProtocolScript.BIT_ALIVE
	var frame_hash := ""
	var hash_tick := -1
	if tick_index >= 0 and tick_index % ONLINE_HASH_INTERVAL_TICKS == 0:
		frame_hash = SimHasherScript.hash_world(sim_world)
		hash_tick = tick_index
	var command := LobbyProtocolScript.pack_command_bits(
		pending_move_vector,
		bits,
		position,
		pending_local_events,
		frame_hash,
		pending_wave_request
	)
	pending_local_events = []
	pending_wave_request = false
	# 一次性的位发出去就清掉，「按住」类的留着：留着边沿会让远端把一次
	# 换枪看成每 tick 都在换枪。
	pending_input_bits &= ~LobbyProtocolScript.ONE_SHOT_BITS
	net.room.send_command(command, hash_tick)

## 每物理帧把本机玩家的输入并进待发缓冲。边沿位用「或」累积，
## 移动向量与「按住」取最新一次采样。
func _accumulate_local_input() -> void:
	var player := _player_for_slot(online_slot)
	if player == null:
		return
	var state = player.get_last_input_state()
	if state == null:
		return
	pending_move_vector = state.move_vector
	pending_input_bits |= LobbyProtocolScript.bits_from_state(state, false, false)
	if not state.use_pressed:
		pending_input_bits &= ~LobbyProtocolScript.BIT_USE_PRESSED

## 联机结束时上报本机看到的成绩。服务端收齐后做多数投票再写榜，
## 客户端没有任何直接写榜路径。
func _report_online_result() -> void:
	if online_result_reported:
		return
	online_result_reported = true
	var net := get_node_or_null("/root/NetSession")
	if net == null or net.room == null:
		return
	var kills := {}
	for slot in online_kills.keys():
		kills[str(slot)] = int(online_kills[slot])
	net.room.report_result(wave_number, kills)

func _setup_simulation() -> PackedStringArray:
	var map_resolve_errors := _resolve_map_definition()
	if not map_resolve_errors.is_empty():
		return map_resolve_errors
	# 联机的种子来自房间，不是任何一个客户端：每端的 DeterministicRng 都由它
	# 派生，谁自己挑一个都必然分叉。
	var resolved_seed := DEFAULT_SIM_SEED if random_seed == 0 else random_seed
	if online_mode:
		var net := get_node_or_null("/root/NetSession")
		if net != null and net.match_seed != 0:
			resolved_seed = net.match_seed
	var errors := map_runtime.load(
		map_definition,
		sim_world,
		get_node_or_null("World/MapContent") as Node3D,
		zombie_difficulty,
		resolved_seed
	)
	if not errors.is_empty():
		return errors
	sim_world.configure_inventory_profiles(
		map_runtime.inventory_profile_dictionaries(),
		map_runtime.reward_inventory_profile_indices()
	)
	var place_grid := get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	if place_grid == null:
		return PackedStringArray(["GameplayArena PlaceItemGrid is missing"])
	place_grid.cell_size = map_definition.grid_cell_size
	var first_cell_center := (
		map_definition.grid_origin
		+ Vector2.ONE * map_definition.grid_cell_size * 0.5
	)
	place_grid.grid_origin = Vector3(
		first_cell_center.x, 0.0, first_cell_center.y
	)
	register_weapon_profiles()
	register_reward_mods()
	sim_clock.reset()
	# 上一局若正好在顿帧里结束，残留的冻结会让新一局开场僵尸静止不动。
	hit_stop.reset()
	return PackedStringArray()

func _setup_map_renderer() -> bool:
	zombie_renderer = get_node_or_null(
		"World/Targets/ZombieRenderer"
	) as ZombieRenderer
	var follow_camera := get_node_or_null("FollowCamera") as Node3D
	if zombie_renderer == null or follow_camera == null:
		return false
	var zombie_scenes: Array[PackedScene] = []
	for definition in map_runtime.zombie_definitions:
		zombie_scenes.append(definition.view_scene)
	zombie_renderer.configure_zombie_scenes(zombie_scenes)
	zombie_renderer.setup(follow_camera)
	return true

func _register_map_entities() -> void:
	barrel_views = {}
	for barrel in map_runtime.scene_barrels():
		_register_barrel(barrel)
	for event in map_runtime.initial_chest_events:
		_create_chest_view(event)

## 模拟层只认档案下标；这里把 weapon_id 映射到下标，顺序即注册顺序。
## 地图来源有两条：场景里直接绑好的（DemoMap.tscn 那样的调试壳），
## 和会话里带来的 map_id（菜单与联机走这条）。
##
## 解析不到时**失败**，不回退到目录里的第一张图：联机下回退意味着
## 缺这张图的那一端悄悄跑了另一张，而其他人不会知道。
func _resolve_map_definition() -> PackedStringArray:
	if map_definition != null:
		return PackedStringArray()
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return PackedStringArray(["GameplayArena 找不到 GameSession，无法确定地图"])
	var requested: StringName = session.map_id
	if String(requested) == "":
		return PackedStringArray(["会话里没有地图 id"])
	var resolved := ContentCatalogsScript.maps().get_by_id(requested)
	if resolved == null:
		return PackedStringArray(["地图目录里没有 %s" % requested])
	map_definition = resolved
	return PackedStringArray()

func register_weapon_profiles() -> void:
	weapon_profile_indices = {}
	# 新武器一律**追加在末尾**，不要插进中间：下标就是模拟层认的武器档案号，
	# 重排会让同一发子弹在不同版本的客户端上打出不同的伤害档案。
	#
	# 这份清单必须覆盖 Player.tscn 的 loadout 里每一把远程武器。漏一把不会报错，
	# 只会让 get_weapon_profile_index() 返回 -1，_on_sim_request() 把那把枪的每一次
	# 开火**静默丢弃**——枪口火光与射击音仍然照常播放（它们是表现层直接做的），
	# 于是现象是「枪能举起来、有声有光、就是打不死任何东西」。
	# validate_weapon_assembly.gd 会逐把枪核对这份清单。
	var definitions: Array[RangedWeaponDefinition] = [
		PISTOL_DEFINITION,
		SMG_DEFINITION,
		SHOTGUN_DEFINITION,
		RIFLE_DEFINITION,
	]
	for profile_index in range(definitions.size()):
		var definition := definitions[profile_index]
		weapon_profile_indices[definition.weapon_id] = profile_index
		sim_world.configure_weapon_profile(
			profile_index,
			definition.damage,
			definition.attack_range,
			definition.base_spread_degrees,
			definition.max_spread_degrees,
			definition.spread_increase_per_shot_degrees,
			definition.spread_recovery_degrees_per_second,
			definition.max_penetration_count,
			definition.penetration_damage_coefficient,
			definition.pellet_count,
			# 模拟层靠这个 id 把开火扣到对应的背包弹药档案上。漏传不会报错，
			# 只会让那把枪的弹药在背包里只增不减，捡满一次之后再也捡不到子弹。
			definition.weapon_id,
			definition.crit_chance_percent,
			definition.crit_multiplier
		)

## 把某个座位当前的改装件摘要刷到它的头顶标签上。
##
## 数据源是 SimWorld 而不是表现层的缓存：改装层数逐 tick 进帧哈希，从它读就
## 不可能出现「显示的和实际生效的不是一回事」。
## 上一次下发过的改装摘要，逐座位缓存。这个函数现在每 tick 都被调用，
## 没有这层比较就是每 tick 往 UI 推一遍同样的字符串。
var _weapon_mod_summaries := PackedStringArray()

func _refresh_weapon_mod_summary(slot: int) -> void:
	var player := _player_for_slot(slot)
	if player == null:
		return
	var parts := PackedStringArray()
	for mod_id in range(WeaponModTableScript.COUNT):
		var level := sim_world.get_weapon_mod_level(slot, mod_id)
		if level <= 0:
			continue
		parts.append("%s%d" % [WeaponModTableScript.MOD_LABELS_CN[mod_id], level])
	var summary := "" if parts.is_empty() else "改装 · " + " ".join(parts)
	# 初值就是空串，和「一个改装都没有」同值——所以开局那次相同的空摘要不会下发，
	# 而标签本来就是空的，结果一致。不要拿特殊字符当哨兵：
	# validate_ui_font_coverage 扫的是源码里的字符串，会把它当成要渲染的字形。
	while _weapon_mod_summaries.size() <= slot:
		_weapon_mod_summaries.append("")
	if _weapon_mod_summaries[slot] == summary:
		return
	_weapon_mod_summaries[slot] = summary
	player.set_weapon_mod_summary(summary)

## 把「哪个奖励下标是改装件、给几层」告诉模拟层。
##
## 必须在 map_runtime 建好奖励目录之后调用：reward_profile_index 是 GameMapRuntime
## 按 resource_path 字典序排出来的，模拟层只认这个 int。这里灌的是同一套下标，
## 因此各端只要地图资源相同就必然一致。
##
## 改装件 id 写错（不在 WeaponModTable.MOD_IDS 里）会拿到 -1，那件掉落就退化成
## 「捡起来什么也不发生」——不会报错，所以 validate_weapon_mod_catalog.gd 会逐件核对。
func register_reward_mods() -> void:
	for profile_index in range(map_runtime.reward_definitions.size()):
		var definition := map_runtime.reward_definitions[profile_index]
		if definition == null:
			continue
		# 补血奖励没有背包身份，靠这张表让模拟层认出它（见 SimWorld.configure_reward_heal）。
		if definition.is_heal():
			sim_world.configure_reward_heal(profile_index, roundi(definition.heal_amount))
			continue
		if not definition.is_weapon_mod():
			continue
		var mod_id := WeaponModTableScript.mod_index_from_id(definition.weapon_mod_id)
		if mod_id < 0:
			push_warning(
				"未知的改装件 id '%s'（%s），这件掉落将没有任何效果"
				% [definition.weapon_mod_id, definition.resource_path]
			)
			continue
		sim_world.configure_reward_mod(
			profile_index, mod_id, definition.weapon_mod_stacks
		)

func get_weapon_profile_index(weapon_id: StringName) -> int:
	return int(weapon_profile_indices.get(weapon_id, -1))

func _on_sim_request(request: Dictionary, slot: int) -> void:
	var kind: StringName = request["kind"]
	# 联机下**没有任何座位**可以从这里直接进模拟层。
	#
	# 本机座位：先缓冲、随命令上行，等它随帧回来再由 _queue_online_event()
	# 统一应用。直接进模拟层就意味着本机比别人早一个 RTT 开枪。
	#
	# 远端座位：它的身体也在本机跑着，输入由 NetworkInputSource 喂，于是它的
	# 武器同样会在本机开火并抬起请求——而同一枪的效果已经随帧到过一次了。
	# 两条路都放行，远端玩家的每一枪就会在别人的客户端上打两遍：僵尸掉血翻倍、
	# 死得更快，而在开枪者自己的客户端上只打一遍。这正是「两边存活数对不上」。
	# 所以这里直接丢弃：远端武器保留枪口火焰与音效（纯表现），判定只认帧。
	if online_mode:
		if slot == online_slot:
			_buffer_local_sim_request(request)
		return
	if kind == &"shot":
		var profile_index := get_weapon_profile_index(request["weapon_id"])
		if profile_index < 0:
			return
		var shot_origin: Vector3 = request["origin"]
		var shot_aim: Vector3 = request["aim_direction"]
		sim_world.queue_fire_event(
			slot,
			profile_index,
			Vector2(shot_origin.x, shot_origin.z),
			shot_origin.y,
			Vector2(shot_aim.x, shot_aim.z)
		)
		return
	if kind == &"melee":
		var melee_origin: Vector3 = request["origin"]
		var melee_aim: Vector3 = request["aim_direction"]
		sim_world.queue_melee_event(
			slot,
			float(request["damage"]),
			float(request["reach"]),
			float(request["half_width"]),
			Vector2(melee_origin.x, melee_origin.z),
			melee_origin.y,
			Vector2(melee_aim.x, melee_aim.z)
		)
		return
	if kind == &"spread_reset":
		# 传「换上」的那把武器的档案下标；传旧下标会把新武器重置到上一把枪的 base。
		sim_world.queue_spread_reset(
			slot, get_weapon_profile_index(request["weapon_id"])
		)
		return
	if kind == &"place_item":
		_apply_place_item(
			slot, _placeable_index_for(slot, request["item_id"]), request["cell"]
		)

## 联机下把本机的模拟层请求量化后攒起来，等下一条命令一起发。
## 一个 tick 内最多攒 8 条，与服务端 parseCommand 的上限一致：
## 超出的部分服务端会丢，本机若照旧应用就会比别人多打几枪。
func _buffer_local_sim_request(request: Dictionary) -> void:
	if pending_local_events.size() >= 8:
		return
	var kind: StringName = request["kind"]
	if kind == &"shot":
		var profile_index := get_weapon_profile_index(request["weapon_id"])
		if profile_index < 0:
			return
		pending_local_events.append(
			LobbyProtocolScript.pack_shot_event(
				profile_index, request["origin"], request["aim_direction"]
			)
		)
		return
	if kind == &"melee":
		pending_local_events.append(
			LobbyProtocolScript.pack_melee_event(
				float(request["damage"]),
				float(request["reach"]),
				float(request["half_width"]),
				request["origin"],
				request["aim_direction"]
			)
		)
		return
	if kind == &"spread_reset":
		var reset_index := get_weapon_profile_index(request["weapon_id"])
		if reset_index >= 0:
			pending_local_events.append(
				LobbyProtocolScript.pack_spread_reset_event(reset_index)
			)
		return
	if kind == &"place_item":
		var placeable_index := _placeable_index_for(online_slot, request["item_id"])
		if placeable_index >= 0:
			pending_local_events.append(
				LobbyProtocolScript.pack_place_item_event(
					placeable_index, request["cell"]
				)
			)

## 可放置物在该座位装备栏里的下标。跨线只发这个下标：各端为同一座位建的是
## 同一份 loadout，收端据此取回同一个 item_scene，协议因此不必认识「油桶」。
func _placeable_index_for(slot: int, item_id: StringName) -> int:
	var player := _player_for_slot(slot)
	if player == null:
		return -1
	return player.equipment.get_slot_for_item(item_id)

## 放置落地：单机在请求当场执行，联机在帧到达时由各端同时执行。
##
## 账本是这里唯一的闸门——有油桶才放得下。少了它，一个客户端在一个 RTT 内
## 连按几次就能用一个油桶放出好几个桶：本地的可用性判断读的是还没扣账的镜像值。
func _apply_place_item(slot: int, placeable_index: int, cell: Vector2i) -> void:
	var player := _player_for_slot(slot)
	if player == null or placeable_index < 0:
		return
	var items: Array = player.equipment.equipment_items
	if placeable_index >= items.size():
		return
	var placeable = items[placeable_index]
	if placeable == null or not placeable.has_method(&"get_place_item_scene"):
		return
	var oil_profile_index := sim_world.inventory_oil_profile_index()
	if oil_profile_index < 0:
		return
	if sim_world.spend_inventory(slot, oil_profile_index, 1) <= 0:
		return
	var place_item_service = get_node_or_null("PlaceItemService")
	if place_item_service == null:
		return
	if not place_item_service.place_item_at_cell(
		cell, slot, placeable.get_place_item_scene()
	):
		# 落地失败（格子在这一 tick 已经被占）：把扣掉的那个还回去，
		# 否则玩家会丢一个油桶却什么也没放下。各端拒绝的条件相同，退款也相同。
		sim_world.accept_inventory(slot, oil_profile_index, 1)
		return
	_push_inventory_mirror(slot)

func _on_sim_shot_event(event: Dictionary) -> void:
	var origin: Vector2 = event["origin"]
	var end_point: Vector2 = event["end"]
	var from_position := Vector3(origin.x, float(event["origin_height"]), origin.y)
	var to_position := Vector3(end_point.x, float(event["end_height"]), end_point.y)
	var shooter := _player_for_slot(int(event["slot"]))
	if shooter != null:
		var weapon = shooter.equipment.get_current_weapon()
		if weapon is RangedWeapon:
			(weapon as RangedWeapon).show_tracer(
				from_position, to_position, bool(event.get("hit_blocker", false))
			)
	if shot_event_is_true_miss(event):
		# 打空：在弹道终点弹一个 MISS。多弹丸武器一次扣扳机会走这里 pellet_count 次，
		# 限流器保证只出一个（霰弹枪六颗全落空时不该刷出六个 MISS）。
		_spawn_miss_popup(int(event["slot"]), to_position)
	# 命中确认不在这里做。屏幕中上曾经有一个固定位置的 HIT/KILL 文字，
	# 它和僵尸头顶的伤害飘字说的是同一件事，只是说得更差：它离交火点很远，
	# 不带数值，也不告诉你打的是哪一只。飘字上线之后它就只是重复的噪音。

## 运行时增删阻挡几何的统一入口。任何调用都会置脏对应 cell，
## 下一 tick 的 FlowField.update() 会同步重算。
func mark_blocker(obstacle: CollisionObject3D, blocked: bool) -> void:
	var bounds := PlaceItemGridScript.collision_object_world_aabb(obstacle)
	if bounds.size == Vector3.ZERO:
		return
	sim_world.set_blocker_world_rect(
		Vector2(bounds.position.x, bounds.position.z),
		Vector2(bounds.end.x, bounds.end.z),
		blocked
	)

## 把一个爆炸桶节点注册成模拟层实体。幂等：已注册过的桶直接返回。
## 阻挡矩形取自碰撞体世界 AABB；拿不到（形状被禁用等）时退回按桶半径的方形，
## 绝不能传空矩形——SimWorld 会把它当成退化矩形至少标一格。
## 注册**只能**挂在 PlaceItemService.item_placed 上，不能挂在 child_entered_tree 上：
## request_place_item() 是先 add_child() 再写 global_position 的，
## child_entered_tree 触发时节点还停在原点。
func _register_barrel(barrel: ExplosiveBarrel) -> void:
	if barrel == null or barrel.get_sim_barrel_id() != 0:
		return
	var origin := barrel.global_position
	var minimum := Vector2(
		origin.x - SimHitGeometryScript.BARREL_RADIUS,
		origin.z - SimHitGeometryScript.BARREL_RADIUS
	)
	var maximum := Vector2(
		origin.x + SimHitGeometryScript.BARREL_RADIUS,
		origin.z + SimHitGeometryScript.BARREL_RADIUS
	)
	var bounds := PlaceItemGridScript.collision_object_world_aabb(barrel)
	if bounds.size != Vector3.ZERO:
		minimum = Vector2(bounds.position.x, bounds.position.z)
		maximum = Vector2(bounds.end.x, bounds.end.z)
	# 工兵「加固」被动：放置者的油桶爆炸范围与伤害 ×passive_strength。
	# owner_slot 由 PlaceItemService 在放置时写到桶的 meta（来自玩家的 player_index）。
	# 各端从同一份角色目录算出同一 owner/scale，油桶爆炸在模拟层，确定性成立。
	var fortify_scale := 1.0
	var owner_slot: int = barrel.get_meta("owner_slot", -1) if barrel.has_meta("owner_slot") else -1
	if owner_slot >= 0 and owner_slot < players.size():
		var owner := players[owner_slot]
		if owner != null and owner.character_definition != null \
				and owner.character_definition.passive_id == &"fortify":
			fortify_scale = owner.character_definition.passive_strength
	var barrel_id_value := sim_world.spawn_barrel(
		Vector2(origin.x, origin.z),
		origin.y,
		minimum,
		maximum,
		barrel.firearm_hits_to_explode,
		barrel.firearm_hits_to_damage,
		barrel.chain_delay_seconds,
		barrel.explosion_radius * fortify_scale,
		barrel.explosion_center_damage * fortify_scale,
		barrel.explosion_edge_damage * fortify_scale
	)
	barrel.bind_sim_barrel(barrel_id_value)
	barrel_views[barrel_id_value] = barrel

func _barrel_view(barrel_id_value: int) -> ExplosiveBarrel:
	var view = barrel_views.get(barrel_id_value, null)
	if view == null or not is_instance_valid(view):
		barrel_views.erase(barrel_id_value)
		return null
	return view as ExplosiveBarrel

## 表现层只是把模拟层已经做完的判定演出来：受损换外观，引爆播特效并打玩家。
func _on_sim_barrel_event(event: Dictionary) -> void:
	var barrel_id_value := int(event["barrel_id"])
	var barrel := _barrel_view(barrel_id_value)
	if barrel == null:
		return
	var kind: StringName = event["kind"]
	if kind == &"barrel_damaged":
		barrel.play_damaged()
		return
	if kind == &"barrel_exploded":
		var planar: Vector2 = event["position"]
		barrel_views.erase(barrel_id_value)
		# 爆炸绕过静默期：它通常紧跟在一串击杀之后，被静默期吃掉的话，
		# 整场最该被看见的一次清场反而是唯一没有顿帧的那次。
		hit_stop.request(HitStopStateScript.EXPLOSION_SECONDS, true)
		barrel.play_explosion(
			Vector3(planar.x, float(event["height"]), planar.y)
		)

## 油桶的阻挡格由 SimWorld 在 spawn_barrel() / 引爆时独占维护，
## 所以这里**不**再调 mark_blocker()：阻挡格是布尔量，重复标记本身无害，
## 但把生命周期收在模拟层一处，「哪一 tick 清的格」才是确定的。
func _on_item_placed(item: Node3D) -> void:
	var pool := SpatialSfxPool.find_for(self)
	if pool != null:
		pool.play_at(BARREL_PLACE_SOUND, item.global_position, -4.0, 1.0, 24.0)
	var barrel := item as ExplosiveBarrel
	if barrel != null:
		_register_barrel(barrel)
		return
	var obstacle := item as CollisionObject3D
	if obstacle != null:
		mark_blocker(obstacle, true)

func _on_item_removed(item: Node3D, world_aabb: AABB) -> void:
	var barrel := item as ExplosiveBarrel
	if barrel != null:
		var barrel_id_value := barrel.get_sim_barrel_id()
		if barrel_id_value != 0:
			barrel_views.erase(barrel_id_value)
			# 已引爆的桶在模拟层早就是 DESTROYED，这里是幂等兜底：
			# 只有「没炸就离场」的桶才真的需要它来清掉阻挡格。
			sim_world.queue_barrel_removal(barrel_id_value)
		return
	_apply_blocker_bounds(world_aabb, false)

func _on_sim_chest_event(event: Dictionary) -> void:
	var kind: StringName = event.get("kind", StringName())
	if kind == &"chest_spawned" or kind == &"chest_respawned":
		_create_chest_view(event)
		return
	if kind != &"chest_claimed":
		return
	# 改装件的效果已经在模拟层当场生效了，这里只刷新显示。
	# 即使下面因为找不到表现节点提前 return，摘要也必须先更新——
	# 效果是模拟层给的，跟表现节点在不在无关。
	if int(event.get("weapon_mod_id", -1)) >= 0:
		_refresh_weapon_mod_summary(int(event["slot"]))
	# 奖励已经记进模拟层账本，这里立刻刷一次镜像而不等下一 tick：
	# 自动切枪必须在同一帧就看到「这把枪已经归我了」。
	_push_inventory_mirror(int(event["slot"]))
	_auto_equip_claimed_reward(
		int(event["slot"]), int(event.get("reward_profile_index", -1))
	)
	var chest_id_value := int(event["chest_id"])
	var view = chest_views.get(chest_id_value, null)
	chest_views.erase(chest_id_value)
	if view == null or not is_instance_valid(view):
		return
	var place_grid := get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	if place_grid != null:
		# queue_free() 要到帧末才触发 tree_exiting；catch-up 可在同一渲染帧
		# 先消费 claimed、再消费 respawned，所以旧 owner 必须在这里同步释放。
		place_grid.release_owner(view as Node)
	# 领取已成定局，表现层没有否决权：能不能兑现取决于各端并不同步的弹药状态，
	# 让它回写模拟层就是把分叉重新引进来。
	(view as PickupChest).claim_by(_player_for_slot(int(event["slot"])))

## 捡到标了自动装备的武器就切过去。这是纯表现动作：拿没拿到由账本决定，
## 这里只决定手上举着哪一把，因此各端不一致也只影响本机画面。
func _auto_equip_claimed_reward(slot: int, reward_profile_index: int) -> void:
	var definition := map_runtime.reward_definition(reward_profile_index)
	if definition == null or not definition.auto_equip:
		return
	if definition.reward_mode != PickupDefinition.RewardMode.EQUIPMENT:
		return
	var player := _player_for_slot(slot)
	if player == null or not player.is_alive():
		return
	player.equipment.equip_item(definition.item_id)

func _create_chest_view(event: Dictionary) -> void:
	var chest_id_value := int(event.get("chest_id", 0))
	var reward_profile_index := int(event.get("reward_profile_index", -1))
	var definition := map_runtime.reward_definition(reward_profile_index)
	var pickups := get_node_or_null("World/Pickups") as Node3D
	var place_grid := get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	if chest_id_value <= 0 or definition == null or pickups == null or place_grid == null:
		push_error("cannot create simulated pickup chest view")
		return
	var view := PICKUP_CHEST_SCENE.instantiate() as PickupChest
	if view == null:
		push_error("PickupChest scene root must be PickupChest")
		return
	pickups.add_child(view)
	var position: Vector2 = event["position"]
	view.global_position = Vector3(position.x, 0.0, position.y)
	view.configure(definition, int(event["amount"]))
	view.bind_sim_chest(chest_id_value)
	if not place_grid.register_shared_obstacle(view):
		push_error(
			"cannot reserve simulated pickup chest view: %d" % chest_id_value
		)
		view.free()
		return
	chest_views[chest_id_value] = view

func _apply_blocker_bounds(world_aabb: AABB, blocked: bool) -> void:
	if world_aabb.size == Vector3.ZERO:
		return
	sim_world.set_blocker_world_rect(
		Vector2(world_aabb.position.x, world_aabb.position.z),
		Vector2(world_aabb.end.x, world_aabb.end.z),
		blocked
	)

func _player_for_slot(slot: int) -> PlayerController:
	if slot < 0 or slot >= players.size():
		return null
	var player := players[slot]
	return player if is_instance_valid(player) else null

## 玩家状态以量化后的快照进入 SimWorld；玩家自身位移仍由玩家层决定。
func _push_player_snapshot() -> void:
	for slot in range(SimWorldScript.MAX_PLAYER_SLOTS):
		var player := _player_for_slot(slot)
		if player == null:
			sim_world.set_player_snapshot(slot, Vector2.ZERO, false, false)
			continue
		sim_world.set_player_snapshot(
			slot,
			Vector2(player.global_position.x, player.global_position.z),
			player.is_alive(),
			true
		)

func _consume_sim_events() -> void:
	for event in sim_world.tick_wave_events:
		_on_sim_wave_event(event)
	for event in sim_world.tick_shot_events:
		_on_sim_shot_event(event)
	for event in sim_world.tick_barrel_events:
		_on_sim_barrel_event(event)
	for event in sim_world.tick_chest_events:
		_on_sim_chest_event(event)
	for event in sim_world.tick_hit_events:
		_on_sim_hit_event(event)
	_spawn_damage_popups(sim_world.tick_hit_events)
	for event in sim_world.tick_player_damage_events:
		_on_sim_player_damage_event(event)
	for event in sim_world.tick_player_heal_events:
		_on_sim_player_heal_event(event)
	if sim_world.tick_death_events.size() > 0:
		zombie_renderer.notify_deaths(sim_world)
		call_deferred("_refresh_wave_state_after_deaths")
	# 背包镜像每 tick 刷一次：拾取、购买、开火扣弹、放油桶都在这一步落到装备节点上。
	# 内容没变时 EquipmentController 会自己跳过，所以这里不需要再判一次。
	#
	# 改装摘要也在这里刷：原来只有开箱拾取那条路径刷它，商店买的改装件走的是
	# 模拟命令队列、下一 tick 才生效，永远碰不到那个刷新点。文本没变就不下发。
	for slot in range(players.size()):
		_push_inventory_mirror(slot)
		_refresh_weapon_mod_summary(slot)
	_update_wave_hud()
	_sync_command_controls()

func _on_sim_wave_event(event: Dictionary) -> void:
	var kind: StringName = event.get("kind", StringName())
	if kind == &"wave_started":
		wave_number = int(event.get("wave_number", wave_number))
		_close_shop()
		shop_phase_ended.emit()
		_update_wave_hud()
	elif kind == &"intermission_started":
		wave_number = int(event.get("wave_number", wave_number))
		_open_shop()
		shop_phase_started.emit(wave_number)
		_update_wave_hud()

## 波间打开商店：生成商品（确定性 RNG，各端一致）+ 显示当前材料。
func _open_shop() -> void:
	var panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if panel == null:
		return
	_shop_offers = _generate_shop_offers(3)
	panel.set_offers(_shop_offers)
	panel.set_material_count(sim_world.get_player_material(_local_slot()))
	panel.show()

## 波开始/结束关闭商店。
func _close_shop() -> void:
	var panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if panel == null:
		return
	panel.hide()
	_shop_offers = []

## 从商店目录确定性选 count 个不重复条目（用 DeterministicRng 的 SHOP 流）。
## 种子 = 房间种子 + 波次号，各端独立派生、必然一致；不碰共享 RNG（那会打乱
## 僵尸 AI / 掉落的随机序列）。
func _generate_shop_offers(count: int) -> Array[ShopOfferDefinition]:
	var catalog := ContentCatalogsScript.shop()
	if catalog == null or catalog.count() == 0:
		return []
	var store_rng := DeterministicRngScript.new()
	store_rng.seed_streams(_shop_seed())
	var pool: Array = []
	for i in range(catalog.count()):
		pool.append(catalog.entry_at(i))
	var result: Array[ShopOfferDefinition] = []
	for _i in range(mini(count, pool.size())):
		var idx := store_rng.next_uint32(DeterministicRngScript.Stream.SHOP) % pool.size()
		result.append(pool[idx])
		pool.remove_at(idx)
	return result

## 商店 RNG 种子：房间种子 + 波次号。联机各端从同一房间种子派生同一商店。
## room_seed 存于 sim_world（reset 时接收），get_room_seed() 返回它。
func _shop_seed() -> int:
	var base := sim_world.get_room_seed() if sim_world != null else DEFAULT_SIM_SEED
	return base + wave_number

## 本机玩家的座位号：单机是 slot 0，联机是 online_slot。
func _local_slot() -> int:
	if online_slot >= 0:
		return online_slot
	return 0 if not players.is_empty() else 0

## 玩家点了商店里的一个商品。按 offer_type 分派：
##   stat/heal  —— 进模拟（确定性，T5 实现）
##   weapon/passive/ammo —— 表现层 grant（单机直接处理，联机走命令事件，T6 实现）
func _on_shop_buy(offer_index: int) -> void:
	if offer_index < 0 or offer_index >= _shop_offers.size():
		return
	var offer := _shop_offers[offer_index]
	var slot := _local_slot()
	# stat/heal/weapon_mod 的效果都落在进帧哈希的模拟状态上，走确定性购买队列；
	# weapon/passive/ammo/oil 是背包与装备身份，走 _buy_equipment。
	if offer.offer_type == ShopOfferDefinition.OfferType.STAT \
			or offer.offer_type == ShopOfferDefinition.OfferType.HEAL \
			or offer.offer_type == ShopOfferDefinition.OfferType.WEAPON_MOD:
		_buy_sim_stat(slot, offer)
		return
	if _buy_equipment(slot, offer):
		return
	# 没成交就告诉面板，别让卡片放完「买到了」的动画。buy_requested 是同步 emit 的，
	# 所以这一步一定发生在面板决定播哪套动画之前。
	var panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if panel != null:
		panel.notify_purchase_rejected(offer_index)

## 属性/回血/改装件购买：发确定性命令进模拟层（扣费 + 生效进帧哈希）。
## 单机直接进模拟；联机走命令事件上行（T6 的协议层），这里统一走队列——
## 模拟层自己保证确定性应用。
##
## queue_shop_purchase 的 (stat_index, amount) 两个位置按 kind 各表各的意思：
##   stat       —— (统计种类, 倍率/加值)
##   heal       —— (忽略, 回血量)
##   weapon_mod —— (WeaponModTable 下标, 层数)
## 之前这里对三种 kind 一律传 stat_amount，于是回血商品全部按 stat_amount 的
## 默认值 1.0 结算——「回血 +80」实际只回 1 点血，扣费却照收。
func _buy_sim_stat(slot: int, offer: ShopOfferDefinition) -> void:
	var kind := &"stat"
	var index := offer.stat_index
	var amount := offer.stat_amount
	match offer.offer_type:
		ShopOfferDefinition.OfferType.HEAL:
			kind = &"heal"
			amount = offer.heal_amount
		ShopOfferDefinition.OfferType.WEAPON_MOD:
			var mod_index := offer.weapon_mod_index()
			if mod_index < 0:
				push_warning("shop offer '%s' has unknown weapon_mod_id" % offer.display_name)
				return
			kind = &"weapon_mod"
			index = mod_index
			amount = float(offer.weapon_mod_stacks)
	sim_world.queue_shop_purchase(slot, kind, index, amount, offer.price)
	_refresh_shop_material(slot)

## 购买后刷新商店金钱显示。
##
## 这里**不能**再调 set_offers()：那会整排重建卡片，把正在播的选中动画连节点一起
## 销毁；而且没必要——set_material_count() 里的 _refresh_cards() 已经重算了每张卡
## 的可买状态。
func _refresh_shop_material(slot: int) -> void:
	var panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if panel == null:
		return
	panel.set_material_count(sim_world.get_player_material(slot))

## 商店开着时逐帧同步材料数与波间倒计时。
##
## 逐帧同步不是偷懒：stat/heal/weapon_mod 三种购买走的是模拟命令队列，**下一 tick
## 才真正扣费**，而买完当场调用的 _refresh_shop_material() 读到的还是扣费前的旧值。
## 结果是材料数字永远不减，玩家照着旧数字点第二次，第二笔在模拟层被静默拒绝——
## 表现就是「波间商店一次只能买一件」。
func _sync_shop_hud() -> void:
	var panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if panel == null or not panel.visible:
		return
	var slot := _local_slot()
	panel.set_material_count(sim_world.get_player_material(slot))
	panel.set_seconds_remaining(
		float(sim_world.intermission_ticks_remaining()) * SimClockScript.TICK_SECONDS
	)
	panel.set_offer_levels(_shop_offer_levels(slot))

## 每个商品买下去之后会到达的等级。只有改装件是真的会叠层的，其余一律 LV.1。
func _shop_offer_levels(slot: int) -> PackedInt32Array:
	var levels := PackedInt32Array()
	for offer in _shop_offers:
		if offer == null or offer.offer_type != ShopOfferDefinition.OfferType.WEAPON_MOD:
			levels.append(1)
			continue
		var mod_index := offer.weapon_mod_index()
		if mod_index < 0:
			levels.append(1)
			continue
		levels.append(
			sim_world.get_weapon_mod_level(slot, mod_index) + offer.weapon_mod_stacks
		)
	return levels

## 武器/被动/弹药购买。
## 单机：表现层直接处理（扣费 + grant/附加）。
## 联机：发购买事件走命令通道上行，服务端透传回各端，各端按 offer_index 反查
## 同一份 _shop_offers（确定性生成）应用同一效果——保证扣费与 grant 各端一致。
## 返回这次购买有没有真的成交。联机下只是把请求发上去，当作已受理。
func _buy_equipment(slot: int, offer: ShopOfferDefinition) -> bool:
	if online_mode:
		if pending_local_events.size() < 8:
			pending_local_events.append(
				LobbyProtocolScript.pack_shop_purchase_event(
					int(offer.offer_type), offer.price, _offer_index_of(offer)
				)
			)
		return true
	return _buy_equipment_local(slot, offer)

## 联机收到购买事件后的落地（由 _on_online_shop_purchase 调用）。
##
## 返回 false = 这笔没成交（材料不够、已有这把枪、弹匣满、没空槽位……）。
## 以前这些分支一律静默 return，玩家点了卡片什么都不发生，只能理解成「坏了」。
## 现在把结果回给调用方，由商店面板给一个明确的拒绝反馈。
func _buy_equipment_local(slot: int, offer: ShopOfferDefinition) -> bool:
	var player := _player_for_slot(slot)
	if player == null:
		return false
	# 买到的东西写进模拟层账本，不写进装备节点：钱早就是模拟层扣的，货也必须落在
	# 同一本账上，否则买来的枪不进背包、买来的子弹背包不知道。装备节点由紧接着的
	# 镜像刷新拿到结果。
	match offer.offer_type:
		ShopOfferDefinition.OfferType.WEAPON:
			var weapon_profile_index := sim_world.inventory_weapon_profile_index(
				offer.weapon_id
			)
			if weapon_profile_index < 0:
				return false
			# 已经有这把枪就别收钱：重复武器在拾取语义里会折算成 1 发子弹，
			# 拿整把枪的价钱换一发是坑。
			if sim_world.inventory_amount_of(slot, weapon_profile_index) > 0:
				return false
			if not sim_world.spend_player_material(slot, offer.price):
				return false
			var weapon_result: Dictionary = sim_world.accept_inventory(
				slot, weapon_profile_index, 1
			)
			if not bool(weapon_result.get("accepted", false)):
				sim_world.add_player_material(slot, offer.price)  # 退款
				return false
			_push_inventory_mirror(slot)
			player.equipment.equip_item(offer.weapon_id)
		ShopOfferDefinition.OfferType.PASSIVE:
			if not sim_world.spend_player_material(slot, offer.price):
				return false
			player.set_runtime_passive(offer.passive_id)
		ShopOfferDefinition.OfferType.AMMO:
			var ammo_profile_index := sim_world.inventory_ammo_profile_index(
				offer.weapon_id
			)
			if ammo_profile_index < 0:
				return false
			# 没有这把枪就不卖它的子弹，与改造前 add_ammo() 要求 is_available() 一致。
			var owner_profile_index := sim_world.inventory_weapon_profile_index(
				offer.weapon_id
			)
			if sim_world.inventory_amount_of(slot, owner_profile_index) <= 0:
				return false
			if not sim_world.spend_player_material(slot, offer.price):
				return false
			var ammo_result: Dictionary = sim_world.accept_inventory(
				slot, ammo_profile_index, offer.ammo_amount
			)
			if not bool(ammo_result.get("accepted", false)):
				sim_world.add_player_material(slot, offer.price)  # 退款（弹匣已满）
				return false
			_push_inventory_mirror(slot)
		ShopOfferDefinition.OfferType.OIL:
			var oil_profile_index := sim_world.inventory_oil_profile_index()
			if oil_profile_index < 0:
				return false
			if not sim_world.spend_player_material(slot, offer.price):
				return false
			var oil_result: Dictionary = sim_world.accept_inventory(
				slot, oil_profile_index, offer.oil_amount
			)
			if not bool(oil_result.get("accepted", false)):
				sim_world.add_player_material(slot, offer.price)  # 退款（槽位已满）
				return false
			_push_inventory_mirror(slot)
	_refresh_shop_material(slot)
	return true

func _offer_index_of(offer: ShopOfferDefinition) -> int:
	for i in range(_shop_offers.size()):
		if _shop_offers[i] == offer:
			return i
	return -1

func _on_sim_hit_event(event: Dictionary) -> void:
	var planar: Vector2 = event["position"]
	var hit_position := Vector3(planar.x, float(event["height"]), planar.y)
	var zombie_planar: Vector2 = event["zombie_position"]
	var foot_position := Vector3(zombie_planar.x, 0.0, zombie_planar.y)
	var planar_direction: Vector2 = event["direction"]
	var direction := Vector3(planar_direction.x, 0.0, planar_direction.y)
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if view != null:
		view.play_hit_reaction(
			hit_position,
			direction * SimWorldScript.ZOMBIE_KNOCKBACK_IMPULSE
		)
	# 只在击杀时顿帧，不是每发命中都顿：冲锋枪 10 发/秒逐发顿帧会让画面接近
	# 一半时间静止，那时顿帧读起来是掉帧而不是打击感。HitStopState 自带静默期，
	# 一 tick 内打死一片僵尸也只会顿一次。
	if bool(event["killed"]):
		hit_stop.request(HitStopStateScript.KILL_SECONDS)
	var manager := get_node_or_null("GroundBloodManager") as GroundBloodManager
	if manager == null:
		_spawn_blood_impact(hit_position, direction)
		return
	# 走池化的冲击特效与**排队**的地面血迹，而不是立即生成。
	# 模拟层一 tick 能打死一整片僵尸，逐个立刻实例化血迹会把这一帧顶爆；
	# GroundBloodManager 的帧预算就是为这个场景准备的。
	manager.spawn_blood_impact(hit_position, direction, 1.0)
	manager.queue_hit_splat(foot_position, 1.0, bool(event["killed"]))

## 伤害数字飘字：肉鸽爽点核心。数值来自模拟层（已确定），表现层只负责飘升淡出。
##
## 逐条命中事件各飘一个数字是错的：一次开火可以在同一 tick 内对同一只僵尸产生
## 多条命中（霰弹枪 6 颗弹丸、步枪穿透、爆炸叠加），六个 "16" 会在同一个点互相
## 遮挡，读出来是一团糊字而不是「这一枪很重」——而 6×16=96 恰恰是霰弹枪区别于
## 手枪 35 的全部理由。按 zombie_id 合并到一条，数字才等于玩家感知到的那一击。
func _spawn_damage_popups(events: Array) -> void:
	if events.is_empty():
		return
	var merged := {}
	var order: Array[int] = []
	for event in events:
		var damage := float(event.get("damage", 0.0))
		if damage <= 0.0:
			continue
		var zombie := int(event["zombie_id"])
		if not merged.has(zombie):
			order.append(zombie)
			merged[zombie] = {
				"damage": damage,
				"position": event["position"],
				"height": float(event["height"]),
				"max_health": float(event.get("max_health", 0.0)),
				"critical": bool(event.get("critical", false)),
				# 预埋：模拟层还不会填 element，缺省即普通伤害。等燃烧弹/毒之类做出来、
				# 命中事件开始带 element，飘字这条链路不用再改一行就有颜色。
				"element": StringName(event.get("element", DamagePopup.ELEMENT_NORMAL)),
				"killed": bool(event["killed"]),
			}
			continue
		var entry: Dictionary = merged[zombie]
		entry["damage"] = float(entry["damage"]) + damage
		entry["critical"] = bool(entry["critical"]) or bool(event.get("critical", false))
		# 合并里出现过任何非普通伤害就用那一种：一次开火同时打出普通与燃烧时，
		# 玩家要看见的是「这里有燃烧」，而不是被普通伤害盖回白色。
		if StringName(entry["element"]) == DamagePopup.ELEMENT_NORMAL:
			entry["element"] = StringName(event.get("element", DamagePopup.ELEMENT_NORMAL))
		# 这一串命中里只要有一条打死了，合并后的数字就该显示成击杀。
		entry["killed"] = bool(entry["killed"]) or bool(event["killed"])
	for zombie in order:
		var entry: Dictionary = merged[zombie]
		var planar: Vector2 = entry["position"]
		var popup := DAMAGE_POPUP_SCENE.instantiate() as DamagePopup
		add_child(popup)
		popup.setup(
			float(entry["damage"]),
			Vector3(planar.x, float(entry["height"]), planar.y),
			float(entry["max_health"]),
			bool(entry["critical"]),
			bool(entry["killed"]),
			_damage_popup_spawn_index,
			StringName(entry.get("element", DamagePopup.ELEMENT_NORMAL))
		)
		_damage_popup_spawn_index += 1

## 这一枪算不算「打空」。
##
## `did_hit` 单独用是不够的：它只回答「有没有伤到僵尸或油桶」，对「子弹飞完全程
## 什么都没碰到」和「子弹被墙截断」给出同一个 false。只看它就会在打中墙时飘 MISS——
## 而同一帧 RangedWeapon.show_tracer() 正在用 `hit_blocker` 播墙面弹着音，
## 于是音效说「打中墙」、文字说「打空」，自相矛盾。
##
## 打中墙不是打空：子弹确实撞上了东西，只是那东西不掉血。
static func shot_event_is_true_miss(event: Dictionary) -> bool:
	if bool(event.get("did_hit", false)):
		return false
	return not bool(event.get("hit_blocker", false))

## 打空飘字。数据源是射击事件的 did_hit，不是命中事件——只有射击事件知道
## 「这一枪存在过但没打到任何东西」。
##
## 【为什么要限流】
## 这是个横扫僵尸潮的射击游戏，不是回合制 RPG：子弹打空是常态而不是事件。
## 冲锋枪 10 发/秒对着空处扫一梭子，逐发飘字会在半秒内糊出十个 MISS，
## 把真正要读的伤害数字全挤掉。所以每个座位设一个最小间隔，只让「你这一下
## 打空了」这个信息露一次头。
##
## 限流用墙钟而不是 tick：它纯粹是显示节流，不产生任何模拟状态，
## 各端节流得不一样也不会让对局分叉。
const MISS_POPUP_INTERVAL_MSEC := 400

func _spawn_miss_popup(slot: int, world_position: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var last := int(_last_miss_popup_msec.get(slot, -MISS_POPUP_INTERVAL_MSEC))
	if now - last < MISS_POPUP_INTERVAL_MSEC:
		return
	_last_miss_popup_msec[slot] = now
	var popup := DAMAGE_POPUP_SCENE.instantiate() as DamagePopup
	add_child(popup)
	popup.setup_miss(world_position, _damage_popup_spawn_index)
	_damage_popup_spawn_index += 1

func _on_sim_player_damage_event(event: Dictionary) -> void:
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if event["kind"] == &"zombie_windup":
		if view != null:
			view.play_attack_windup()
		return
	var target := _player_for_slot(int(event["slot"]))
	if target == null or not target.is_alive():
		return
	var origin: Vector2 = event["origin"]
	target.apply_damage(float(event["damage"]), Vector3(origin.x, 0.0, origin.y))

## 医疗光环回血落地。事件由模拟层 tick 结算产生（各端一致），这里只把回血量
## 应用到表现层玩家的 Health 上。血量本身在表现层，回血不产生新的模拟状态。
func _on_sim_player_heal_event(event: Dictionary) -> void:
	var target := _player_for_slot(int(event["slot"]))
	if target == null or not target.is_alive():
		return
	target.heal(float(event["amount"]))

func _spawn_blood_impact(hit_position: Vector3, direction: Vector3) -> void:
	var effect := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
	add_child(effect)
	effect.setup(hit_position, direction, 1.0)

func _refresh_wave_state_after_deaths() -> void:
	_update_wave_hud()
	_sync_command_controls()

func _exit_tree() -> void:
	_set_touch_game_over_active(false)

func _unhandled_input(event: InputEvent) -> void:
	if startup_pending:
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if event.is_action_pressed(&"spawn_wave"):
		request_spawn_wave()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_demo"):
		request_restart()
		get_viewport().set_input_as_handled()
		return
	# B 键打开背包：直接检测物理键码（和 WASD 同路径，不依赖 action 系统）。
	# 注意：project.godot 里**不要**给 toggle_inventory 配 action 绑定——
	# 绑定会抢走按下事件（action 被触发但没人处理），导致只有松开事件漏到这里。
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).keycode == KEY_B:
		_toggle_inventory_panel()
		get_viewport().set_input_as_handled()
		return
	# ESC 呼出/关闭暂停菜单。
	if event.is_action_pressed(&"ui_cancel"):
		_toggle_pause_menu()
		get_viewport().set_input_as_handled()

## Tab 打开/关闭背包。数据从模拟层读（确定性），表现层只显示。
func _toggle_inventory_panel() -> void:
	var panel := get_node_or_null("HUD/InventoryPanel") as InventoryPanel
	if panel == null:
		return
	if panel.visible:
		panel.hide()
		return
	# 打开时 setup 当前数据：模拟层 + 本机座位 + 背包物品目录。
	# 玩家对象（角色属性）在背包面板内部从 PlayerRegistry 读，不在这里传——
	# 避免 setup 签名变更导致的编辑器缓存问题。
	panel.setup(sim_world, _local_slot(), map_runtime.inventory_profiles())
	panel.show()

## 离线休整可被跳过时返回 1；其余情况（含联机仅上行请求）返回 0。
func request_spawn_wave() -> int:
	if startup_pending or team_defeated or not sim_world.can_advance_wave():
		return 0
	# 联机下玩家按 T 只是提出请求：它随下一条命令上行，服务端把它 OR 进某一帧，
	# 各端于是在**同一个 tick** 上排队同一波。本机自己先开一波就是分叉。
	if online_mode:
		pending_wave_request = true
		return 0
	return spawn_wave()

func request_restart() -> void:
	if startup_pending or not team_defeated or restart_pending:
		return
	restart_pending = true
	_set_touch_game_over_active(false)
	restart_requested.emit()
	# 联机不能就地重开：种子、tick 与座位都由房间发放，本机重载场景只会
	# 得到一个谁也不认识的模拟。回大厅，由房主再开一局。
	if online_mode:
		get_tree().change_scene_to_file.call_deferred(
			"res://scenes/menu/OnlineLobby.tscn"
		)
		return
	call_deferred("_reload_current_scene")

func _reload_current_scene() -> void:
	var scene_tree := get_tree()
	if scene_tree != null:
		scene_tree.reload_current_scene()

func _run_combat_startup() -> void:
	var prewarmer := get_node_or_null(
		"CombatFxPrewarmer"
	) as CombatFxPrewarmer
	var camera := get_node_or_null("FollowCamera/VisualOffset/Camera3D") as Camera3D
	var warmup_layer := get_node_or_null("WarmupLayer") as CanvasLayer
	if prewarmer != null:
		await get_tree().process_frame
		await get_tree().process_frame
		if warmup_layer != null:
			warmup_layer.hide()
		prewarmer.prewarm(camera)
		if warmup_layer != null:
			warmup_layer.show()
	_complete_combat_startup(true)

func _complete_combat_startup(animate_overlay: bool) -> void:
	if not startup_pending:
		return
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		mobile_controls.cancel_all_input()
	_release_startup_actions()
	for player in players:
		player.set_physics_process(true)
	startup_pending = false
	_sync_command_controls()
	var warmup_layer := get_node_or_null("WarmupLayer") as CanvasLayer
	var overlay := get_node_or_null("WarmupLayer/Overlay") as ColorRect
	if warmup_layer == null or overlay == null:
		return
	if not animate_overlay:
		warmup_layer.hide()
		return
	if warmup_overlay_tween != null and warmup_overlay_tween.is_valid():
		warmup_overlay_tween.kill()
	warmup_overlay_tween = create_tween()
	warmup_overlay_tween.tween_property(overlay, "color:a", 0.0, 0.16)
	await warmup_overlay_tween.finished
	if is_instance_valid(warmup_layer):
		warmup_layer.hide()
	# 操作说明开局后 8 秒自动淡出——新手看一眼就够，不该常驻挡视线。
	# 纯 UI 表现（Tween），不进模拟层，不影响确定性。
	_fade_out_controls_panel()

## 操作说明面板开局后自动淡出。
func _fade_out_controls_panel() -> void:
	var panel := get_node_or_null("HUD/ControlsPanel") as PanelContainer
	if panel == null:
		return
	var tween := create_tween()
	tween.tween_interval(8.0)
	tween.tween_property(panel, "modulate:a", 0.0, 0.6)
	await tween.finished
	if is_instance_valid(panel):
		panel.visible = false

func _release_startup_actions() -> void:
	for action in [
		&"spawn_wave",
		&"restart_demo",
	]:
		Input.action_release(action)

func _wire_dependencies() -> void:
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null and not spawn_button.pressed.is_connected(request_spawn_wave):
		spawn_button.pressed.connect(request_spawn_wave)
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null and not restart_button.pressed.is_connected(request_restart):
		restart_button.pressed.connect(request_restart)
	_sync_command_controls()
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		single_player_input.set_touch_source(mobile_controls.get_input_source())
	var status_timer := get_node_or_null("WaveStatusTimer") as Timer
	if (
		status_timer != null and
		not status_timer.timeout.is_connected(_hide_wave_status)
	):
		status_timer.timeout.connect(_hide_wave_status)

func _wire_runtime_dependencies() -> void:
	var place_item_service = get_node_or_null("PlaceItemService")
	if place_item_service != null:
		if not place_item_service.item_placed.is_connected(_on_item_placed):
			place_item_service.item_placed.connect(_on_item_placed)
		if not place_item_service.item_removed.is_connected(_on_item_removed):
			place_item_service.item_removed.connect(_on_item_removed)
	var shop_panel := get_node_or_null("HUD/ShopPanel") as ShopPanel
	if shop_panel != null and not shop_panel.buy_requested.is_connected(_on_shop_buy):
		shop_panel.buy_requested.connect(_on_shop_buy)
	var follow_camera := get_node_or_null("FollowCamera") as FollowCamera
	var movement_camera := get_node_or_null(
		"FollowCamera/VisualOffset/Camera3D"
	) as Camera3D
	var current_players := _get_spawned_players()
	if current_players.is_empty() or follow_camera == null or movement_camera == null:
		return
	var player_registry := get_node_or_null("PlayerRegistry") as PlayerRegistry
	follow_camera.set_player_registry(player_registry)
	follow_camera.set_world_bounds(map_runtime.camera_bounds())
	for slot_index in range(current_players.size()):
		var player := current_players[slot_index]
		player.set_movement_camera(movement_camera)
		player.set_place_item_service(place_item_service)
		player.set_world_bounds_anchor(follow_camera)
		player.set_sim_request_sink(
			Callable(self, "_on_sim_request").bind(slot_index)
		)
		if not player.attack_resolved.is_connected(_on_player_attack):
			player.attack_resolved.connect(_on_player_attack)
		if not player.damaged.is_connected(_on_player_damaged):
			player.damaged.connect(_on_player_damaged)

func _spawn_session_players() -> bool:
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		single_player_input.set_touch_source(mobile_controls.get_input_source())
	var spawner = get_node_or_null("LocalPlayerSpawner")
	var container := get_node_or_null("Players") as Node3D
	var place_item_service = get_node_or_null("PlaceItemService")
	if spawner == null or container == null:
		var session := get_node_or_null("/root/GameSession")
		if session != null:
			session.last_error = "GameplayArena player spawning nodes are missing"
		return false
	players = spawner.spawn_players(
		container,
		_get_player_spawn_points(),
		place_item_service,
		single_player_input
	)
	var player_registry := get_node_or_null("PlayerRegistry") as PlayerRegistry
	if player_registry != null:
		for player in players:
			player_registry.register_player(player)
	_register_player_signatures()
	_seed_starting_inventory()
	_collect_network_input_sources()
	return not players.is_empty()

## 把开局自带的装备记进模拟层账本，并立刻刷一次镜像。
##
## 必须在玩家生成之后、第一个 tick 之前：从这一刻起「拥有哪把枪、有几发子弹」
## 由账本说了算，账本里没有的东西下一次镜像刷新就会被收走。漏掉这一步的现象是
## 开局手里的刀和手枪凭空消失。
##
## 各端都会为**所有座位**跑一遍（远端玩家的身体也在本机存在），读的是同一份
## 场景与角色目录，因此结果一致，不需要走网络帧——与 _register_player_signatures()
## 同性质。
func _seed_starting_inventory() -> void:
	var profiles := map_runtime.inventory_profile_dictionaries()
	for slot in range(players.size()):
		var player := players[slot]
		if player == null:
			continue
		player.bind_inventory_profiles(profiles)
		for entry in player.starting_inventory_entries():
			var profile_index := _inventory_profile_index_for_entry(entry)
			if profile_index < 0:
				push_warning(
					"开局装备 %s 在背包目录里没有对应档案" % entry.get("item_id", &"")
				)
				continue
			sim_world.accept_inventory(slot, profile_index, int(entry["amount"]))
		_push_inventory_mirror(slot)

func _inventory_profile_index_for_entry(entry: Dictionary) -> int:
	match int(entry.get("category", -1)):
		EquipmentController.INVENTORY_CATEGORY_WEAPON:
			return sim_world.inventory_weapon_profile_index(entry["item_id"])
		EquipmentController.INVENTORY_CATEGORY_OIL:
			return sim_world.inventory_oil_profile_index()
	return -1

## 把某个座位的 12 格账本推给它的装备节点。单向，表现层没有否决权。
func _push_inventory_mirror(slot: int) -> void:
	var player := _player_for_slot(slot)
	if player == null:
		return
	if inventory_mirror_profiles.size() != SimWorldScript.INVENTORY_SLOT_COUNT:
		inventory_mirror_profiles.resize(SimWorldScript.INVENTORY_SLOT_COUNT)
		inventory_mirror_amounts.resize(SimWorldScript.INVENTORY_SLOT_COUNT)
	for inventory_slot in range(SimWorldScript.INVENTORY_SLOT_COUNT):
		inventory_mirror_profiles[inventory_slot] = sim_world.get_inventory_slot_profile(
			slot, inventory_slot
		)
		inventory_mirror_amounts[inventory_slot] = sim_world.get_inventory_slot_amount(
			slot, inventory_slot
		)
	player.apply_inventory_snapshot(
		inventory_mirror_profiles, inventory_mirror_amounts
	)

## 把每名玩家的本命武器伤害缩放 + 医疗光环登记进模拟层。
##
## 必须在玩家生成后调用：register_weapon_profiles 跑在玩家之前，那时还没有
## player.character_definition 可读。本方法依赖 weapons profiles 已注册（
## weapon_profile_count() 非零）。各端从同一份角色目录独立算出同一张表，
## 因此不进网络帧；sim_hasher 已把缩放表混入帧哈希做哨兵。
func _register_player_signatures() -> void:
	for slot in range(players.size()):
		var player := players[slot]
		if player == null or player.character_definition == null:
			continue
		var def := player.character_definition
		if String(def.signature_weapon_id) != "":
			var profile_index := get_weapon_profile_index(def.signature_weapon_id)
			if profile_index >= 0:
				sim_world.set_player_signature_scale(
					slot, profile_index, def.signature_weapon_damage_mult
				)
		sim_world.set_slot_medic(
			slot, def.passive_id == &"medic_aura", def.passive_strength
		)

## 记下每个远端座位的输入源，之后每一帧都靠它把命令喂给对应的身体。
## 本机座位不在表里：它由真实设备驱动。
func _collect_network_input_sources() -> void:
	net_input_sources.clear()
	if not online_mode:
		return
	for slot in range(players.size()):
		if slot == online_slot:
			continue
		var source = players[slot].get_input_source()
		if source is NetworkInputSource:
			net_input_sources[slot] = source

func _get_player_spawn_points() -> Array[Marker3D]:
	var points: Array[Marker3D] = []
	var marker_root := get_node_or_null("RuntimePlayerSpawnPoints") as Node3D
	if marker_root == null:
		marker_root = Node3D.new()
		marker_root.name = "RuntimePlayerSpawnPoints"
		add_child(marker_root)
	for child in marker_root.get_children():
		child.free()
	var positions := map_runtime.player_spawn_positions()
	for index in range(positions.size()):
		var marker := Marker3D.new()
		marker.name = "P%d" % (index + 1)
		marker_root.add_child(marker)
		marker.global_position = positions[index]
		points.append(marker)
	return points

func _get_spawned_players() -> Array[PlayerController]:
	var result: Array[PlayerController] = []
	var container := get_node_or_null("Players")
	if container == null:
		return result
	for child in container.get_children():
		if child is PlayerController:
			result.append(child)
	players = result
	return result

func _handle_player_spawn_failure() -> void:
	startup_pending = false
	if DisplayServer.get_name() == "headless":
		return
	var session := get_node_or_null("/root/GameSession")
	var destination := "res://scenes/menu/MainMenu.tscn"
	if session != null:
		if session.mode == GameSessionScript.Mode.LOCAL_MULTIPLAYER:
			destination = "res://scenes/menu/LocalMultiplayerLobby.tscn"
		elif session.mode == GameSessionScript.Mode.ONLINE_MULTIPLAYER:
			destination = "res://scenes/menu/OnlineLobby.tscn"
	get_tree().change_scene_to_file.call_deferred(destination)

## ---- 暂停菜单 / 返回大厅 ----

func _wire_pause_menu() -> void:
	var menu := get_node_or_null("HUD/PauseMenu") as Control
	if menu == null:
		return
	if not menu.resume_requested.is_connected(_on_pause_resume):
		menu.resume_requested.connect(_on_pause_resume)
	if not menu.return_to_lobby_requested.is_connected(_on_pause_return_to_lobby):
		menu.return_to_lobby_requested.connect(_on_pause_return_to_lobby)

func _toggle_pause_menu() -> void:
	var menu := get_node_or_null("HUD/PauseMenu") as Control
	if menu == null:
		return
	if menu.is_open():
		_on_pause_resume()
	else:
		menu.open()
		# 单人局冻结游戏；联机不能冻结（会断 tick 同步），只弹菜单。
		if not online_mode:
			get_tree().paused = true

func _on_pause_resume() -> void:
	var menu := get_node_or_null("HUD/PauseMenu") as Control
	if menu != null:
		menu.close()
	# 只有单人局被我们冻结过，才需要解冻；联机本就没冻结，别动。
	if not online_mode:
		get_tree().paused = false

func _on_pause_return_to_lobby() -> void:
	get_tree().paused = false
	_bank_run_material_to_meta()
	get_tree().change_scene_to_file.call_deferred(
		"res://scenes/menu/MainMenu.tscn"
	)

## 把本局本机座位的材料累加进跨局银行。仅单人局生效（本地/联机由
## MetaBanker.compute_banked 判 0，避免刷币 + 不碰网络同步确定性）。
func _bank_run_material_to_meta() -> void:
	var meta := get_node_or_null("/root/MetaProgression")
	var session := get_node_or_null("/root/GameSession")
	if meta == null or sim_world == null or session == null:
		return
	var amount: int = MetaBankerScript.compute_banked(
		session.mode, online_mode, sim_world.get_player_material(_local_slot())
	)
	if amount > 0:
		meta.add_banked_material(amount)

func _handle_startup_failure(message: String) -> void:
	var session := get_node_or_null("/root/GameSession")
	if session != null:
		session.last_error = message
	_handle_player_spawn_failure()

## 镜头后坐力是纯表现，命中确认改由模拟层的射击事件驱动。
func _on_player_attack(
	direction: Vector3,
	_result: HitResult,
	camera_impulse_strength: float
) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction, camera_impulse_strength)

func _on_player_damaged(_amount: float) -> void:
	var flash := get_node_or_null("HUD/DamageFlash") as ColorRect
	if flash == null:
		return
	if damage_flash_tween != null and damage_flash_tween.is_valid():
		damage_flash_tween.kill()
	var flash_color := flash.color
	flash_color.a = 0.30
	flash.color = flash_color
	damage_flash_tween = create_tween()
	damage_flash_tween.tween_property(flash, "color:a", 0.0, 0.20)

func _on_all_players_defeated() -> void:
	if team_defeated:
		return
	team_defeated = true
	if game_over_audio != null:
		game_over_audio.play()
	var game_over := get_node_or_null("HUD/GameOver") as Label
	if game_over != null:
		game_over.text = "全员倒地"
		game_over.visible = true
	_set_touch_game_over_active(true)
	_sync_command_controls()
	_update_wave_hud()
	if online_mode:
		_report_online_result()

func _set_touch_game_over_active(active: bool) -> void:
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls == null:
		return
	var touch_source = mobile_controls.get_input_source()
	if touch_source != null:
		touch_source.set_game_over_active(active)

func _sync_command_controls() -> void:
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null:
		spawn_button.visible = not team_defeated
		spawn_button.disabled = (
			startup_pending or
			team_defeated or
			not sim_world.can_advance_wave()
		)
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null:
		restart_button.visible = team_defeated

## 手动请求只跳过模拟层的休整状态；生成中和等待清场时不会叠加下一波。
func spawn_wave() -> int:
	if startup_pending or team_defeated or not sim_world.can_advance_wave():
		return 0
	sim_world.request_advance_wave()
	_update_wave_hud()
	_sync_command_controls()
	return 1

func get_active_zombie_count() -> int:
	return sim_world.get_zombie_count()

func _update_wave_hud() -> void:
	var objective := get_node_or_null("HUD/Objective") as Label
	if objective == null:
		return
	# 肉鸽式结算牌：波次 + 存活 + 材料。材料是「我在变富」的可视化——
	# 玩家一眼看到这局攒了多少购买力，比纯 WAVE/ALIVE 更有爽感。
	var material := sim_world.get_player_material(_local_slot()) if sim_world != null else 0
	objective.text = "第 %d 波 · 存活 %d · 材料 %d" % [
		wave_number,
		get_active_zombie_count(),
		material,
	]

## 王者荣耀式延迟显示：联机时右上角一个会按质量变色的毫秒数。
## 节流更新——延迟本身每 2s 才刷新一次，没必要每帧去查 NetSession。
## 阈值与封顶都用 NetSession 上那份共享定义，和大厅显示保持一致。
func _update_ping_hud(delta: float) -> void:
	_ping_hud_timer -= delta
	if _ping_hud_timer > 0.0:
		return
	_ping_hud_timer = PING_HUD_INTERVAL_SECONDS
	var label := get_node_or_null("HUD/Ping") as Label
	if label == null:
		return
	if not online_mode:
		label.visible = false
		return
	var net := get_node_or_null("/root/NetSession")
	var rtt: int = net.latency_display_ms() if net != null else -1
	if rtt < 0:
		label.visible = false
		return
	label.visible = true
	label.text = "%dms" % rtt
	label.add_theme_color_override("font_color", net.latency_color(rtt))

func _show_wave_status(message: String) -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label == null:
		return
	label.text = message
	label.visible = true
	var timer := get_node_or_null("WaveStatusTimer") as Timer
	if timer != null:
		timer.start()

func _hide_wave_status() -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label != null:
		label.visible = false
