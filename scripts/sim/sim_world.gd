extends RefCounted
class_name SimWorld

## 全部模拟状态的唯一持有者。结构化数组（SoA），不持有任何 Node。
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const FlowFieldScript = preload("res://scripts/sim/flow_field.gd")
const WeaponModTableScript = preload("res://scripts/sim/weapon_mod_table.gd")
const WeaponModMathScript = preload("res://scripts/sim/weapon_mod_math.gd")
const SimCollisionScript = preload("res://scripts/sim/sim_collision.gd")
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")
const SimMathScript = preload("res://scripts/sim/sim_math.gd")
const MeleeAttackCycleScript = preload("res://scripts/combat/melee_attack_cycle.gd")
const HitResponseMathScript = preload("res://scripts/combat/hit_response_math.gd")
const WeaponSpreadStateScript = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)
const SimCombatScript = preload("res://scripts/sim/sim_combat.gd")
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")
const SimWaveDirectorScript = preload("res://scripts/sim/sim_wave_director.gd")

const MAX_PLAYER_SLOTS := 4
const INVENTORY_SLOT_COUNT := 12
const INVENTORY_CATEGORY_WEAPON := 0
const INVENTORY_CATEGORY_AMMO := 1
const INVENTORY_CATEGORY_OIL := 2
const INVENTORY_CATEGORY_WEAPON_MOD := 3
const NO_TARGET_SLOT := 255
const STATE_DEAD := 3
const HEALTH_SCALE := 100
const POSITION_QUANTIZATION := 1000.0
const DROP_ITEM := 0
const DROP_MATERIAL := 1

## 与 Godot 的 physics/3d/default_gravity 引擎缺省值一致；project.godot 未覆盖该项
## （基线的 zombie_target.gd 是用 ProjectSettings.get_setting(..., 9.8) 读到同一个缺省值的），
## 模拟层不读 ProjectSettings，因此在此固化。
const SIM_GRAVITY := 9.8

const ZOMBIE_RADIUS := 0.42
const PLAYER_RADIUS := 0.45
const ZOMBIE_SEPARATION_RATIO := 0.5

## 感知半径不是常量：基线地图使用 MapDefinition.zombie_perception_range（默认 60.0）
## 覆盖 ZombieTarget.tscn 的导出默认值 7.0，波次僵尸实际用的是 60.0。
## 若在此把 7.0 固化成常量，僵尸只会在 7 m 内才注意到玩家，
## 而生成角在 (±19, ±14)、场地 48 × 38，新生成的僵尸会原地游荡不再汇聚。
## 因此由地图运行时装配层通过 set_perception_range() 注入。
const DEFAULT_PERCEPTION_RANGE := 60.0
var perception_range := DEFAULT_PERCEPTION_RANGE

# 下列数值逐字取自 scenes/targets/ZombieTarget.tscn 与 zombie_target.gd 的导出默认值。
const ZOMBIE_PERCEPTION_EXIT_MARGIN := 1.0
const ZOMBIE_TARGET_SWITCH_MARGIN := 0.5
const ZOMBIE_ATTACK_RANGE := 1.45
const ZOMBIE_ATTACK_DAMAGE := 10.0
const ZOMBIE_WANDER_SPEED := 0.55
const ZOMBIE_WANDER_RADIUS := 3.5
const ZOMBIE_WANDER_ARRIVE_RANGE := 0.25
const ZOMBIE_WANDER_SLOW_RADIUS := 0.8
const ZOMBIE_PERCEPTION_SLOW_RADIUS := 1.5
## 流场重建的最小间隔（tick）。
##
## 重建是一次覆盖全网格的 BFS，由玩家跨越格子边界触发。玩家 5 m/s、格边长 1 m，
## 单人就是每秒五次；四人同场时任一玩家跨格都会触发，最坏接近每 tick 一次，
## 而模拟每秒只有 20 tick——那意味着每一拍都在重建整张图。
##
## 节流把上限压到每 0.3 秒一次。代价是流场最多滞后玩家 1.5 米，但这个滞后只影响
## **远处**僵尸的绕行路线；近身僵尸走的是 ZOMBIE_DIRECT_CHASE_RANGE 内的直接追击，
## 根本不看流场，所以贴身的追击精度不受影响。
const FLOW_FIELD_REBUILD_INTERVAL_TICKS := 6
## 这个距离内的僵尸直接朝目标走，不查流场。
##
## 既是精度也是性能：流场按节流间隔更新，贴脸时用它会追着玩家 1.5 米前的位置；
## 而这么近的距离上，绕障碍的需求也基本消失了——真撞上东西还有碰撞推挤兜底。
const ZOMBIE_DIRECT_CHASE_RANGE := 3.5
## 黄金角（弧度）。按实体 id 乘它给每只僵尸分配一条侧翼车道，连续 id 的僵尸会
## 均匀铺开；换成等分角会让同一波刷出的僵尸整齐扎堆在少数几个方向上。
const ZOMBIE_FLANK_ANGLE_STEP := 2.399963
## 远距离绕行的侧向强度（相对流场前向分量）。0.7 大约是 35 度的偏航：
## 足以让尸群铺成扇面，又不至于让僵尸看起来在绕圈而不是扑过来。
const ZOMBIE_FLANK_STRENGTH := 0.7
## 侧向偏移的衰减距离。超出 ZOMBIE_DIRECT_CHASE_RANGE 这么远时偏移拉满，
## 越靠近越收敛，进入直接追击范围时归零。
const ZOMBIE_FLANK_FALLOFF_RANGE := 6.0
const ZOMBIE_MOVE_ACCELERATION := 5.0
const ZOMBIE_GROUND_DRAG := 11.0
const ZOMBIE_KNOCKBACK_IMPULSE := 6.0
const ZOMBIE_KNOCKBACK_VERTICAL_BIAS := 0.05
const DEFAULT_PERCEPTION_MOVE_SPEED := 1.30

# 秒 -> tick（TICK_SECONDS = 0.05）
const ZOMBIE_ATTACK_COOLDOWN_TICKS := 28   # 1.40 s
const ZOMBIE_ATTACK_WINDUP_TICKS := 10     # 0.50 s
const ZOMBIE_WANDER_PAUSE_MIN_TICKS := 8   # 0.40 s
const ZOMBIE_WANDER_PAUSE_MAX_TICKS := 24  # 1.20 s

# 下列常量新增，基线无对应导出项：被击中后的短暂僵直，用于取消攻击蓄力。
# 基线的 ZombieTarget 只有 _play_hit_reaction() 的纯视觉反馈，没有僵直状态。
const ZOMBIE_HIT_STUN_TICKS := 4           # 0.20 s

# ---- 爆炸桶（模拟层实体） ----
## 状态机逐条对应基线 explosive_barrel.gd 的 State，只把 EXPLODING 拆成
## 「引信倒计时（PENDING）」+「已销毁（DESTROYED）」两段：基线用
## await 定时器计时，那是墙钟，各端会落在不同 tick 上。
const BARREL_STATE_INTACT := 0
const BARREL_STATE_DAMAGED := 1
const BARREL_STATE_PENDING := 2
const BARREL_STATE_DESTROYED := 3

## apply_barrel_hit() 的返回值。REGISTERED 表示「打中了但没到任何阈值」——
## 基线 apply_hit() 对完好的桶一律返回 HitResult.resolved()，HUD 会显示 HIT，
## 所以这一档也必须与「没打中」区分开。
const BARREL_HIT_NONE := 0
const BARREL_HIT_REGISTERED := 1
const BARREL_HIT_DAMAGED := 2
const BARREL_HIT_EXPLODED := 3

## 连锁引信至少 1 tick。基线的 _begin_explosion() 走 call_deferred + 计时器，
## 连锁一定落在后面的帧上，绝不会在同一帧内把一整串桶递归炸完。
const BARREL_MIN_CHAIN_TICKS := 1

# ---- spec 指定的 SoA 字段 ----
var zombie_id := PackedInt32Array()
var zombie_profile_index := PackedInt32Array()
var zombie_position := PackedVector2Array()
var zombie_height := PackedFloat32Array()
var zombie_facing := PackedFloat32Array()
var zombie_health := PackedInt32Array()
var zombie_state := PackedByteArray()
var zombie_target_slot := PackedByteArray()

# ---- 推进与插值所需的内部字段 ----
var zombie_max_health := PackedInt32Array()
var zombie_previous_position := PackedVector2Array()
var zombie_previous_height := PackedFloat32Array()
var zombie_previous_facing := PackedFloat32Array()
var zombie_velocity := PackedVector2Array()
var zombie_vertical_velocity := PackedFloat32Array()
var zombie_radius := PackedFloat32Array()
var zombie_home := PackedVector2Array()
var zombie_wander_target := PackedVector2Array()
var zombie_wander_pause_ticks := PackedInt32Array()
var zombie_hit_stun_ticks := PackedInt32Array()
var zombie_move_speed := PackedFloat32Array()
var zombie_attack_state := PackedInt32Array()

# ---- 僵尸档案 ----
## 装配层只在每局 reset() 后以稳定下标注册数值；模拟层不读取 Resource。
var zombie_profiles: Array[Dictionary] = []
## 装配层将地图 Resource 编译为整数/字典后按僵尸档案下标注入；模拟层不读取 Resource。
var zombie_death_groups: Array[Array] = []

# ---- 爆炸桶 SoA ----
## 油桶**不做压缩删除**：数量是个位数，且引爆是在 tick 中途发生的
## （射击结算与引信推进都会引爆），中途重排下标会让同一 tick 内已经取到的
## 下标失效。已销毁的桶留在数组里，state 恒为 DESTROYED，射线与连锁都跳过它。
var barrel_id := PackedInt32Array()
var barrel_position := PackedVector2Array()
var barrel_base_height := PackedFloat32Array()
var barrel_state := PackedByteArray()
var barrel_hit_count := PackedInt32Array()
var barrel_fuse_ticks := PackedInt32Array()
var barrel_hits_to_explode := PackedInt32Array()
var barrel_hits_to_damage := PackedInt32Array()
var barrel_chain_ticks := PackedInt32Array()
var barrel_radius := PackedFloat32Array()
var barrel_center_damage := PackedFloat32Array()
var barrel_edge_damage := PackedFloat32Array()
var barrel_blocker_min := PackedVector2Array()
var barrel_blocker_max := PackedVector2Array()

# ---- 玩家量化快照（只读输入） ----
var player_position_quantized := PackedInt32Array()
var player_alive := PackedByteArray()
var player_present := PackedByteArray()

# ---- 子系统 ----
var rng: DeterministicRng
var grid: FlowFieldGrid
var flow_field: FlowField
var wave_director

var tick_index := 0
## 本局房间种子。reset(room_seed) 时存入，供商店等表现层确定性派生用。
var _room_seed := 0
var last_flow_field_rebuild_tick := -1000
var next_entity_id := 1
var default_move_speed := DEFAULT_PERCEPTION_MOVE_SPEED
var pending_spawn_requests: Array[Dictionary] = []

# ---- 本 tick 产生的表现层事件（每 tick 开头清空） ----
var tick_hit_events: Array = []
var tick_death_events := PackedInt32Array()
var tick_spawn_events := PackedInt32Array()
var tick_player_damage_events: Array = []
var tick_player_heal_events: Array = []
var tick_shot_events: Array = []
var tick_barrel_events: Array = []
var tick_chest_events: Array = []
## 背包事件是纯模拟结果，表现层只能消费它们，不能用来反写容量或箱子状态。
var tick_inventory_events: Array[Dictionary] = []
var tick_inventory_feedback: Array[Dictionary] = []
var tick_wave_events: Array[Dictionary] = []
var tick_death_rule_events: Array[Dictionary] = []

## 补给箱的领取判定住在模拟层，理由与爆炸桶完全相同：它改变对局状态。
##
## 基线把领取交给 ClaimArea 的 body_entered——一个**表现层的物理重叠**。
## 联机下这必然分叉：本机玩家的身体跑在前面，远端玩家的身体是插值追上来的，
## 于是同一个箱子在各端被不同的人、在不同的帧领走。更糟的是箱子本身是阻挡
## 几何，它消失的时刻不同，各端的流场就在不同的 tick 上重算，僵尸从此分道扬镳。
## 那正是「两边刷出来的道具不一样、存活数也不一样」的成因。
const CHEST_STATE_ACTIVE := 0
const CHEST_STATE_WAITING_RESPAWN := 1
const CHEST_STATE_CONSUMED := 2
## 与 scenes/gameplay/PickupChest.tscn 里 ClaimArea 的圆柱半径一致。
## 改了那边就必须改这里，否则领取手感与判定对不上。
const CHEST_CLAIM_RADIUS := 1.15
## 与 PickupChest.tscn 的 StaticBody3D BoxShape3D 半尺寸一致。
const CHEST_BLOCKER_HALF_SIZE := Vector2(0.24, 0.18)

var chest_id := PackedInt32Array()
var chest_position := PackedVector2Array()
var chest_radius := PackedFloat32Array()
var chest_state := PackedByteArray()
var chest_reward_profile := PackedInt32Array()
var chest_amount := PackedInt32Array()
var chest_respawn_delay_ticks := PackedInt32Array()
var chest_respawn_at_tick := PackedInt32Array()
## 这个箱子占不占阻挡格。固定补给箱是场景家具、要挡；僵尸死后掉的战利品不挡。
##
## 掉落物占阻挡格会造成三件事，密度一上来全都很明显：地上的箱子把战场织成迷宫、
## 玩家的子弹被自己刚打出来的战利品挡住、以及每掉一件就标脏一次流场触发全网格
## BFS 重建（而重建是这套模拟里最贵的一步）。
var chest_blocks_movement := PackedByteArray()
var chest_blocker_min := PackedVector2Array()
var chest_blocker_max := PackedVector2Array()

# ---- 武器档案与逐槽位散布状态 ----
var weapon_profiles: Array = []
## 每个武器档案打的是哪种弹药，按 weapon_id 存，下标与 weapon_profiles 对齐。
##
## 刻意**不放进 weapon_profiles 的字典**：那份字典是「武器数值」，每次读都要先过
## WeaponModMath.derive_profile() 派生改装效果，而派生只重建它认识的数值键，
## 身份键会在那一步被丢掉。分开存也让 validate_weapon_mods.gd 的「数值必须走
## _effective_weapon_profile」闸门继续成立：弹药身份不是数值，不该被改装件改。
var weapon_profile_ammo_ids: Array[StringName] = []
var player_spread_degrees := PackedFloat32Array()
var player_spread_profile := PackedInt32Array()
## 每个座位持有的武器改装层数，展平成 [slot * WeaponModTable.COUNT + mod_id]。
##
## 用 PackedByteArray 有两个理由：层数恒不超过 MAX_STACKS（远小于 255），
## 以及 SimHasher.mix_bytes() 能直接吃它、不必先 to_byte_array()。
## 逐座位而不是全局，是因为四人局里每个人的构筑各自独立。
var player_mod_level := PackedByteArray()
## 逐玩家本命武器伤害缩放，展平成 [slot * weapon_profile_count + profile_index]。
##
## 装配期由表现层按角色目录灌入（与 weapon_profiles 同性质）：联机各端从同一份
## 角色目录独立算出同一张表，因此**不随网络帧传输**，但**进帧哈希**做哨兵——
## 目录不一致时（例如两端角色文件不同步）哈希立刻暴露。值 1.0 = 无加成。
## reset() 只把值复位为 1.0，保留尺寸分配（profile 数在装配期才确定）。
var player_signature_scale := PackedFloat32Array()

# ---- 逐玩家属性成长表（波间商店买的属性升级） ----
## 统计种类：0=伤害  1=最大生命  2=移速。
const STAT_DAMAGE := 0
const STAT_MAX_HEALTH := 1
const STAT_MOVE_SPEED := 2
const STAT_COUNT := 3
## 展平为 [slot * STAT_COUNT + stat]，初始 1.0（无加成）。进帧哈希。
## 伤害/移速是倍率（相乘）；最大生命是加值（加算，arena 应用到 max_health）。
var player_upgrade_scale := PackedFloat32Array()
## 「压制」被动：持续开火时散布增长的削减比例，0 = 无削减。
## 与 blast_armor 的 passive_strength 用法一致（0.3 即减 30%）。
var player_suppression_relief := PackedFloat32Array()

# ---- 逐玩家材料（货币） ----
## 波间商店的购买力。僵尸死亡掉落积累。进帧哈希，各端必须一致。
var player_material := PackedInt32Array()

# ---- 逐玩家背包槽位 ----
## 展平为 [slot * INVENTORY_SLOT_COUNT + inventory_slot]。
## profile 为稳定的 inventory profile 下标，空槽为 -1；amount 为数量或等级。
var inventory_profiles: Array[Dictionary] = []
## reward_profile_index -> inventory_profiles 下标。两边都由地图运行时的稳定目录排序产生。
var reward_inventory_profile := PackedInt32Array()
var inventory_slot_profile := PackedInt32Array()
var inventory_slot_amount := PackedInt32Array()

# ---- 医疗光环状态 ----
## 医疗光环半径（世界单位）。光环影响**别的玩家**，因此必须进模拟层 tick 结算，
## 各端才对齐"谁在光环里、回多少血"——放表现层用 Area3D 或各自计时会 desync。
const MEDIC_AURA_RADIUS := 6.0
## 每多少个 tick 结算一次回血。
const MEDIC_AURA_INTERVAL_TICKS := 30
## 每次结算的基准回血量（×passive_strength）。
const MEDIC_AURA_HEAL_PER_PROC := 5.0
## 逐座位：是否医疗 + 光环强度。装配期由 arena 按角色目录登记（各端一致）。
var slot_is_medic := PackedByteArray()
var slot_medic_strength := PackedFloat32Array()
## reward_profile_index -> 该奖励授予的改装件下标（-1 表示它不是改装件）与层数。
## 与 weapon_profiles 同性质：装配期由表现层灌入，**不进帧哈希、reset() 不清空**。
var reward_mod_id := PackedInt32Array()
var reward_mod_stacks := PackedInt32Array()
## 每个地图奖励下标对应的回血量（0 = 不是补血奖励）。
## 补血不占背包槽，所以它没有 reward_inventory_profile 映射，只有这一张表。
var reward_heal_amount := PackedInt32Array()
var pending_events: Array = []

func _init() -> void:
	rng = DeterministicRngScript.new()
	grid = FlowFieldGridScript.new()
	flow_field = FlowFieldScript.new()
	wave_director = SimWaveDirectorScript.new()
	player_position_quantized.resize(MAX_PLAYER_SLOTS * 2)
	player_position_quantized.fill(0)
	player_alive.resize(MAX_PLAYER_SLOTS)
	player_alive.fill(0)
	player_present.resize(MAX_PLAYER_SLOTS)
	player_present.fill(0)
	player_material.resize(MAX_PLAYER_SLOTS)
	player_material.fill(0)
	inventory_slot_profile.resize(MAX_PLAYER_SLOTS * INVENTORY_SLOT_COUNT)
	inventory_slot_profile.fill(-1)
	inventory_slot_amount.resize(MAX_PLAYER_SLOTS * INVENTORY_SLOT_COUNT)
	inventory_slot_amount.fill(0)
	player_upgrade_scale.resize(MAX_PLAYER_SLOTS * STAT_COUNT)
	player_upgrade_scale.fill(1.0)
	player_spread_degrees.resize(MAX_PLAYER_SLOTS)
	player_spread_degrees.fill(0.0)
	player_suppression_relief.resize(MAX_PLAYER_SLOTS)
	player_suppression_relief.fill(0.0)
	player_spread_profile.resize(MAX_PLAYER_SLOTS)
	player_spread_profile.fill(-1)
	player_mod_level.resize(MAX_PLAYER_SLOTS * WeaponModTableScript.COUNT)
	player_mod_level.fill(0)

func configure(
	grid_origin_xz: Vector2,
	grid_cell_size: float,
	grid_width: int,
	grid_height: int
) -> void:
	grid.configure(grid_origin_xz, grid_cell_size, grid_width, grid_height)
	flow_field.setup(grid)

## 清空全部实体状态并按房间种子重置随机流。阻挡网格保留（静态几何不随开局变化）。
func reset(room_seed: int) -> void:
	rng.seed_streams(room_seed)
	_room_seed = room_seed
	tick_index = 0
	# 负值保证开局第一 tick 一定重建，而不是等节流间隔走完。
	last_flow_field_rebuild_tick = -1000
	next_entity_id = 1
	zombie_id = PackedInt32Array()
	zombie_profile_index = PackedInt32Array()
	zombie_position = PackedVector2Array()
	zombie_height = PackedFloat32Array()
	zombie_facing = PackedFloat32Array()
	zombie_health = PackedInt32Array()
	zombie_state = PackedByteArray()
	zombie_target_slot = PackedByteArray()
	zombie_max_health = PackedInt32Array()
	zombie_previous_position = PackedVector2Array()
	zombie_previous_height = PackedFloat32Array()
	zombie_previous_facing = PackedFloat32Array()
	zombie_velocity = PackedVector2Array()
	zombie_vertical_velocity = PackedFloat32Array()
	zombie_radius = PackedFloat32Array()
	zombie_home = PackedVector2Array()
	zombie_wander_target = PackedVector2Array()
	zombie_wander_pause_ticks = PackedInt32Array()
	zombie_hit_stun_ticks = PackedInt32Array()
	zombie_move_speed = PackedFloat32Array()
	zombie_attack_state = PackedInt32Array()
	zombie_profiles = []
	zombie_death_groups = []
	barrel_id = PackedInt32Array()
	barrel_position = PackedVector2Array()
	barrel_base_height = PackedFloat32Array()
	barrel_state = PackedByteArray()
	barrel_hit_count = PackedInt32Array()
	barrel_fuse_ticks = PackedInt32Array()
	barrel_hits_to_explode = PackedInt32Array()
	barrel_hits_to_damage = PackedInt32Array()
	barrel_chain_ticks = PackedInt32Array()
	barrel_radius = PackedFloat32Array()
	barrel_center_damage = PackedFloat32Array()
	barrel_edge_damage = PackedFloat32Array()
	barrel_blocker_min = PackedVector2Array()
	barrel_blocker_max = PackedVector2Array()
	chest_id = PackedInt32Array()
	chest_position = PackedVector2Array()
	chest_radius = PackedFloat32Array()
	chest_state = PackedByteArray()
	chest_reward_profile = PackedInt32Array()
	chest_amount = PackedInt32Array()
	chest_respawn_delay_ticks = PackedInt32Array()
	chest_respawn_at_tick = PackedInt32Array()
	chest_blocks_movement = PackedByteArray()
	chest_blocker_min = PackedVector2Array()
	chest_blocker_max = PackedVector2Array()
	player_position_quantized.fill(0)
	player_alive.fill(0)
	player_present.fill(0)
	wave_director = SimWaveDirectorScript.new()
	pending_spawn_requests = []
	pending_events = []
	player_spread_degrees.fill(0.0)
	player_spread_profile.fill(-1)
	player_suppression_relief.fill(0.0)
	# 单局清零：改装件只在本局有效，reset() 即开新局。
	player_mod_level.fill(0)
	# 签名表复位为 1.0（无加成），保留尺寸分配。
	player_signature_scale.fill(1.0)
	# 医疗登记复位（保留尺寸分配）。
	slot_is_medic.fill(0)
	slot_medic_strength.fill(1.0)
	# 材料是局内货币，reset() 即开新局，清零。
	player_material.fill(0)
	# 背包槽位是局内状态：profile 清空、数量归零。
	inventory_slot_profile.fill(-1)
	inventory_slot_amount.fill(0)
	# 属性成长表复位为 1.0（无加成）。
	player_upgrade_scale.fill(1.0)
	_clear_tick_events()
	grid.mark_dirty()
	flow_field.setup(grid)

func set_default_move_speed(value: float) -> void:
	default_move_speed = maxf(value, 0.0)

## 感知半径由地图运行时装配层从 MapDefinition 注入（基线默认 60.0）。
func set_perception_range(value: float) -> void:
	perception_range = maxf(value, 0.0)

func get_rng() -> DeterministicRng:
	return rng

## 本局房间种子。表现层用它确定性派生商店等（各端同一房间种子 → 同一结果）。
func get_room_seed() -> int:
	return _room_seed

## 装配层按稳定顺序注入背包 profile；模拟层只保存轻量字典，不读取 Resource。
func configure_inventory_profiles(
	profiles: Array[Dictionary],
	reward_profile_indices: PackedInt32Array
) -> void:
	inventory_profiles.clear()
	for profile in profiles:
		inventory_profiles.append(profile.duplicate(true))
	reward_inventory_profile = reward_profile_indices.duplicate()

func can_accept_reward(slot: int, reward_profile_index: int, amount: int) -> bool:
	return bool(_plan_reward_acceptance(slot, reward_profile_index, amount).get("accepted", false))

## 只在模拟层兑现奖励。返回值既给 chest 领取流程做原子提交依据，也让未来的
## InventoryComponent 能镜像同一结果；失败绝不写槽位、改装层数或 chest 状态。
func accept_reward(slot: int, reward_profile_index: int, amount: int) -> Dictionary:
	var plan: Dictionary = _plan_reward_acceptance(slot, reward_profile_index, amount)
	if not bool(plan.get("accepted", false)):
		var rejected := {
			"kind": &"inventory_rejected",
			"slot": slot,
			"reward_profile_index": reward_profile_index,
			"reason": plan.get("reason", &"rejected"),
		}
		tick_inventory_feedback.append(rejected)
		return rejected
	_apply_reward_acceptance(slot, plan)
	# 补血奖励没有背包 profile / 槽位，这三项取 -1/0——直接下标取会 KeyError。
	var accepted := {
		"kind": &"inventory_accepted",
		"accepted": true,
		"slot": slot,
		"reward_profile_index": reward_profile_index,
		"inventory_profile_index": int(plan.get("inventory_profile_index", -1)),
		"inventory_slot": int(plan.get("inventory_slot", -1)),
		"amount": int(plan.get("accepted_amount", 0)),
		"weapon_mod_id": int(plan.get("weapon_mod_id", -1)),
		"heal_amount": int(plan.get("heal_amount", 0)),
	}
	tick_inventory_events.append(accepted)
	return accepted

## 记一笔背包收入，键是稳定的**背包 profile 下标**而不是地图奖励下标。
##
## 商店购买与开局携带走这里：它们没有对应的地图奖励，但必须和箱子拾取落进
## 同一本账，否则又会长出第二本。返回值与 accept_reward() 同构。
func accept_inventory(slot: int, inventory_profile_index: int, amount: int) -> Dictionary:
	var plan: Dictionary = _plan_inventory_acceptance(slot, inventory_profile_index, amount)
	if not bool(plan.get("accepted", false)):
		var rejected := {
			"kind": &"inventory_rejected",
			"slot": slot,
			"reward_profile_index": -1,
			"reason": plan.get("reason", &"rejected"),
		}
		tick_inventory_feedback.append(rejected)
		return rejected
	_apply_reward_acceptance(slot, plan)
	var accepted := {
		"kind": &"inventory_accepted",
		"accepted": true,
		"slot": slot,
		"reward_profile_index": -1,
		"inventory_profile_index": int(plan["inventory_profile_index"]),
		"inventory_slot": int(plan["inventory_slot"]),
		"amount": int(plan["accepted_amount"]),
		"weapon_mod_id": int(plan.get("weapon_mod_id", -1)),
	}
	tick_inventory_events.append(accepted)
	return accepted

## 记一笔背包支出（放置油桶）。返回实际扣掉的数量，槽位不够就只扣到 0。
## 开火扣弹不走这里：它在 _resolve_shot_event() 里逐发扣，见 _spend_inventory_ammo()。
func spend_inventory(slot: int, inventory_profile_index: int, amount: int) -> int:
	if amount <= 0:
		return 0
	var inventory_slot := _find_inventory_slot(slot, inventory_profile_index)
	if inventory_slot < 0:
		return 0
	var current := get_inventory_slot_amount(slot, inventory_slot)
	var spent := mini(amount, current)
	if spent <= 0:
		return 0
	_set_inventory_slot(slot, inventory_slot, inventory_profile_index, current - spent)
	return spent

## 某个座位当前持有多少这种东西（没有对应槽位就是 0）。
func inventory_amount_of(slot: int, inventory_profile_index: int) -> int:
	var inventory_slot := _find_inventory_slot(slot, inventory_profile_index)
	return get_inventory_slot_amount(slot, inventory_slot) if inventory_slot >= 0 else 0

## ---- 装配层按身份反查背包 profile 下标 ----
## 表现层只认 weapon_id 这类稳定 id，模拟层只认下标，转换统一收在这里，
## 免得每个调用点各自遍历一遍 profile 表、各自写一份分类判断。
func inventory_weapon_profile_index(weapon_id: StringName) -> int:
	return _find_inventory_profile(INVENTORY_CATEGORY_WEAPON, weapon_id)

func inventory_ammo_profile_index(weapon_id: StringName) -> int:
	return _find_ammo_profile_for_weapon(weapon_id)

func inventory_oil_profile_index() -> int:
	return _find_inventory_profile(INVENTORY_CATEGORY_OIL, StringName())

## 改装件 profile 按 mod_id 反查（改装件的 profile 不带 weapon_id，是全武器生效的）。
func inventory_mod_profile_index(mod_id: StringName) -> int:
	return _find_mod_profile_index(WeaponModTableScript.MOD_IDS.find(mod_id))

func _find_mod_profile_index(mod_index: int) -> int:
	if mod_index < 0:
		return -1
	for profile_index in range(inventory_profiles.size()):
		var profile := _inventory_profile(profile_index)
		if int(profile.get("category", -1)) != INVENTORY_CATEGORY_WEAPON_MOD:
			continue
		if int(profile.get("mod_id", -1)) == mod_index:
			return profile_index
	return -1

func _find_inventory_profile(category: int, weapon_id: StringName) -> int:
	for profile_index in range(inventory_profiles.size()):
		var profile := _inventory_profile(profile_index)
		if int(profile.get("category", -1)) != category:
			continue
		if category == INVENTORY_CATEGORY_OIL:
			return profile_index
		if profile.get("weapon_id", StringName()) == weapon_id:
			return profile_index
	return -1

func _plan_reward_acceptance(slot: int, reward_profile_index: int, amount: int) -> Dictionary:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return {"accepted": false, "reason": &"invalid_slot"}
	if amount <= 0:
		return {"accepted": false, "reason": &"invalid_amount"}
	# 补血先判：它没有背包身份，走 _inventory_profile_index_for_reward 必然是 -1，
	# 会被当成 unknown_reward 拒掉。
	#
	# 这里不判「满血就别捡」：玩家血量不在模拟层（它在 PlayerController，回血靠
	# tick_player_heal_events 下发），模拟层无从判断。满血捡到会浪费，和商店的
	# 回血商品是同一套语义。
	var heal := heal_amount_for_reward(reward_profile_index)
	if heal > 0:
		return {"accepted": true, "heal_amount": heal}
	var inventory_profile_index := _inventory_profile_index_for_reward(reward_profile_index)
	if inventory_profile_index < 0:
		return {"accepted": false, "reason": &"unknown_reward"}
	return _plan_inventory_acceptance(slot, inventory_profile_index, amount)

func _plan_inventory_acceptance(
	slot: int,
	inventory_profile_index: int,
	amount: int
) -> Dictionary:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return {"accepted": false, "reason": &"invalid_slot"}
	if amount <= 0:
		return {"accepted": false, "reason": &"invalid_amount"}
	var profile := _inventory_profile(inventory_profile_index)
	if profile.is_empty():
		return {"accepted": false, "reason": &"unknown_profile"}
	match int(profile.get("category", -1)):
		INVENTORY_CATEGORY_WEAPON:
			return _plan_weapon_reward(slot, inventory_profile_index, profile, amount)
		INVENTORY_CATEGORY_AMMO, INVENTORY_CATEGORY_OIL:
			return _plan_finite_stack(slot, inventory_profile_index, amount)
		INVENTORY_CATEGORY_WEAPON_MOD:
			return _plan_weapon_mod_reward(slot, inventory_profile_index, profile, amount)
	return {"accepted": false, "reason": &"invalid_category"}

func _plan_weapon_reward(
	slot: int,
	weapon_profile_index: int,
	weapon_profile: Dictionary,
	amount: int
) -> Dictionary:
	var weapon_slot := _find_inventory_slot(slot, weapon_profile_index)
	var ammo_profile_index := _find_ammo_profile_for_weapon(
		weapon_profile.get("weapon_id", StringName())
	)
	if weapon_slot >= 0:
		if ammo_profile_index < 0:
			return {"accepted": false, "reason": &"duplicate_weapon"}
		return _plan_finite_stack(slot, ammo_profile_index, amount)
	weapon_slot = _find_empty_inventory_slot(slot)
	if weapon_slot < 0:
		return {"accepted": false, "reason": &"inventory_full"}
	var plan := {
		"accepted": true,
		"inventory_profile_index": weapon_profile_index,
		"inventory_slot": weapon_slot,
		"accepted_amount": 1,
		"weapon_slot": weapon_slot,
		"weapon_profile_index": weapon_profile_index,
	}
	if ammo_profile_index < 0:
		return plan
	var ammo_profile := _inventory_profile(ammo_profile_index)
	if int(ammo_profile.get("max_stack", 0)) <= 0:
		return plan
	var ammo_plan := _plan_finite_stack(slot, ammo_profile_index, amount, weapon_slot)
	if not bool(ammo_plan.get("accepted", false)):
		return ammo_plan
	plan["ammo_slot"] = int(ammo_plan["inventory_slot"])
	plan["ammo_profile_index"] = ammo_profile_index
	plan["ammo_amount"] = int(ammo_plan["accepted_amount"])
	return plan

func _plan_finite_stack(
	slot: int,
	profile_index: int,
	amount: int,
	excluded_slot: int = -1
) -> Dictionary:
	var profile := _inventory_profile(profile_index)
	var capacity := int(profile.get("max_stack", 0))
	if capacity <= 0:
		return {"accepted": false, "reason": &"full"}
	var inventory_slot := _find_inventory_slot(slot, profile_index)
	if inventory_slot < 0:
		inventory_slot = _find_empty_inventory_slot(slot, excluded_slot)
		if inventory_slot < 0:
			return {"accepted": false, "reason": &"inventory_full"}
	var current := get_inventory_slot_amount(slot, inventory_slot)
	var accepted_amount := mini(amount, capacity - current)
	if accepted_amount <= 0:
		return {"accepted": false, "reason": &"full"}
	return {
		"accepted": true,
		"inventory_profile_index": profile_index,
		"inventory_slot": inventory_slot,
		"accepted_amount": accepted_amount,
	}

func _plan_weapon_mod_reward(
	slot: int,
	profile_index: int,
	profile: Dictionary,
	amount: int
) -> Dictionary:
	var mod_id := int(profile.get("mod_id", -1))
	if mod_id < 0 or mod_id >= WeaponModTableScript.COUNT:
		return {"accepted": false, "reason": &"invalid_mod"}
	var inventory_slot := _find_inventory_slot(slot, profile_index)
	if inventory_slot < 0:
		inventory_slot = _find_empty_inventory_slot(slot)
		if inventory_slot < 0:
			return {"accepted": false, "reason": &"inventory_full"}
	var current := get_weapon_mod_level(slot, mod_id)
	var capacity := mini(int(profile.get("max_stack", 0)), WeaponModTableScript.MAX_STACKS[mod_id])
	var accepted_amount := mini(amount, capacity - current)
	if accepted_amount <= 0:
		return {"accepted": false, "reason": &"full"}
	return {
		"accepted": true,
		"inventory_profile_index": profile_index,
		"inventory_slot": inventory_slot,
		"accepted_amount": accepted_amount,
		"weapon_mod_id": mod_id,
	}

func _apply_reward_acceptance(slot: int, plan: Dictionary) -> void:
	# 补血奖励没有背包 profile / 槽位，直接下发回血事件走人。
	if plan.has("heal_amount"):
		tick_player_heal_events.append({
			"slot": slot,
			"amount": float(plan["heal_amount"]),
		})
		return
	var profile_index := int(plan["inventory_profile_index"])
	var inventory_slot := int(plan["inventory_slot"])
	var profile := _inventory_profile(profile_index)
	match int(profile.get("category", -1)):
		INVENTORY_CATEGORY_WEAPON:
			_set_inventory_slot(slot, inventory_slot, profile_index, 1)
			if plan.has("ammo_slot"):
				var ammo_slot := int(plan["ammo_slot"])
				var ammo_profile_index := int(plan["ammo_profile_index"])
				var ammo_amount := int(plan["ammo_amount"])
				_set_inventory_slot(
					slot,
					ammo_slot,
					ammo_profile_index,
					get_inventory_slot_amount(slot, ammo_slot) + ammo_amount
				)
		INVENTORY_CATEGORY_AMMO, INVENTORY_CATEGORY_OIL:
			_set_inventory_slot(
				slot,
				inventory_slot,
				profile_index,
				get_inventory_slot_amount(slot, inventory_slot) + int(plan["accepted_amount"])
			)
		INVENTORY_CATEGORY_WEAPON_MOD:
			var mod_id := int(plan["weapon_mod_id"])
			grant_weapon_mod(slot, mod_id, int(plan["accepted_amount"]))
			_set_inventory_slot(slot, inventory_slot, profile_index, get_weapon_mod_level(slot, mod_id))

func _inventory_profile_index_for_reward(reward_profile_index: int) -> int:
	if reward_profile_index < 0 or reward_profile_index >= reward_inventory_profile.size():
		return -1
	return reward_inventory_profile[reward_profile_index]

func _inventory_profile(profile_index: int) -> Dictionary:
	if profile_index < 0 or profile_index >= inventory_profiles.size():
		return {}
	return inventory_profiles[profile_index]

func _find_inventory_slot(slot: int, profile_index: int) -> int:
	for inventory_slot in range(INVENTORY_SLOT_COUNT):
		if get_inventory_slot_profile(slot, inventory_slot) == profile_index:
			return inventory_slot
	return -1

func _find_empty_inventory_slot(slot: int, excluded_slot: int = -1) -> int:
	for inventory_slot in range(INVENTORY_SLOT_COUNT):
		if inventory_slot != excluded_slot and get_inventory_slot_profile(slot, inventory_slot) < 0:
			return inventory_slot
	return -1

func _find_ammo_profile_for_weapon(weapon_id: StringName) -> int:
	for profile_index in range(inventory_profiles.size()):
		var profile := _inventory_profile(profile_index)
		if (
			int(profile.get("category", -1)) == INVENTORY_CATEGORY_AMMO
			and profile.get("weapon_id", StringName()) == weapon_id
		):
			return profile_index
	return -1

func _set_inventory_slot(slot: int, inventory_slot: int, profile_index: int, amount: int) -> void:
	var index := slot * INVENTORY_SLOT_COUNT + inventory_slot
	inventory_slot_profile[index] = profile_index
	inventory_slot_amount[index] = amount

func get_inventory_slot_profile(slot: int, inventory_slot: int) -> int:
	if (
		slot < 0
		or slot >= MAX_PLAYER_SLOTS
		or inventory_slot < 0
		or inventory_slot >= INVENTORY_SLOT_COUNT
	):
		return -1
	return inventory_slot_profile[slot * INVENTORY_SLOT_COUNT + inventory_slot]

func get_inventory_slot_amount(slot: int, inventory_slot: int) -> int:
	if (
		slot < 0
		or slot >= MAX_PLAYER_SLOTS
		or inventory_slot < 0
		or inventory_slot >= INVENTORY_SLOT_COUNT
	):
		return 0
	return inventory_slot_amount[slot * INVENTORY_SLOT_COUNT + inventory_slot]

func get_grid() -> FlowFieldGrid:
	return grid

func get_flow_field() -> FlowField:
	return flow_field

func get_tick() -> int:
	return tick_index

## 波间还剩多少 tick（不在波间返回 0）。表现层拿它画商店倒计时。
## 只读，不推进任何状态——倒计时是 tick 的函数，不需要第二个计时器，
## 也就不会和模拟层跑出两套时间。
func intermission_ticks_remaining() -> int:
	if wave_director == null or not wave_director.can_advance():
		return 0
	return maxi(wave_director.intermission_end_tick - tick_index, 0)

func get_zombie_count() -> int:
	return zombie_id.size()

func get_next_entity_id() -> int:
	return next_entity_id

func get_zombie_id_array() -> PackedInt32Array:
	return zombie_id

## id 单调递增且数组保持顺序，因此可以直接二分。
func index_of_zombie(zombie_id_value: int) -> int:
	var index := zombie_id.bsearch(zombie_id_value, true)
	if index < 0 or index >= zombie_id.size():
		return -1
	return index if zombie_id[index] == zombie_id_value else -1

func get_zombie_position(index: int) -> Vector2:
	return zombie_position[index]

func get_zombie_previous_position(index: int) -> Vector2:
	return zombie_previous_position[index]

func get_zombie_height(index: int) -> float:
	return zombie_height[index]

func get_zombie_previous_height(index: int) -> float:
	return zombie_previous_height[index]

func get_zombie_facing(index: int) -> float:
	return zombie_facing[index]

func get_zombie_previous_facing(index: int) -> float:
	return zombie_previous_facing[index]

func get_zombie_state(index: int) -> int:
	return zombie_state[index]

func get_zombie_health(index: int) -> int:
	return zombie_health[index]

func get_zombie_max_health(index: int) -> int:
	return zombie_max_health[index]

func get_zombie_profile_index(index: int) -> int:
	return zombie_profile_index[index]

## ---- 爆炸桶 ----
## 注册一个爆炸桶实体。id 与僵尸共用同一个单调递增计数器，永不复用。
## 装配方必须在 reset() **之后**、按固定顺序注册（GameMapRuntime 按当前
## content root 下的稳定相对路径排序），否则各端的 id 分配会分叉。
## 阻挡矩形的生命周期由模拟层独占：注册即标为阻挡，引爆/移除时清除。
## 这样「哪一 tick 清掉的格」本身就是确定的，流场重算也逐 tick 对齐。
func spawn_barrel(
	position_xz: Vector2,
	base_height: float,
	blocker_min_xz: Vector2,
	blocker_max_xz: Vector2,
	hits_to_explode: int,
	hits_to_damage: int,
	chain_delay_seconds: float,
	explosion_radius: float,
	center_damage: float,
	edge_damage: float
) -> int:
	var new_id := next_entity_id
	next_entity_id += 1
	# 阈值口径逐字取自基线 apply_hit()：引爆阈值至少 1，
	# 损伤阈值夹在 [1, 引爆阈值] 内。
	var explode_threshold := maxi(hits_to_explode, 1)
	barrel_id.append(new_id)
	barrel_position.append(position_xz)
	barrel_base_height.append(base_height)
	barrel_state.append(BARREL_STATE_INTACT)
	barrel_hit_count.append(0)
	barrel_fuse_ticks.append(0)
	barrel_hits_to_explode.append(explode_threshold)
	barrel_hits_to_damage.append(clampi(hits_to_damage, 1, explode_threshold))
	# 秒 -> tick 用既有的 MeleeAttackCycle.ticks_for_seconds()（就是 ceil），
	# 不另造一份换算：0.12 s / 0.05 s = 2.4 -> 3 tick = 0.15 s。
	barrel_chain_ticks.append(maxi(
		MeleeAttackCycleScript.ticks_for_seconds(
			chain_delay_seconds, SimClockScript.TICK_SECONDS
		),
		BARREL_MIN_CHAIN_TICKS
	))
	barrel_radius.append(maxf(explosion_radius, 0.0))
	barrel_center_damage.append(maxf(center_damage, 0.0))
	barrel_edge_damage.append(maxf(edge_damage, 0.0))
	barrel_blocker_min.append(blocker_min_xz)
	barrel_blocker_max.append(blocker_max_xz)
	set_barrel_blocker_world_rect(blocker_min_xz, blocker_max_xz, true)
	return new_id

## 注册一个补给箱。id 由与僵尸、油桶共用的实体计数器分配，所以各端只要
## 按同样的顺序注册，就拿到同样的 id。
func spawn_chest(
	position_xz: Vector2,
	reward_profile_index: int,
	amount: int,
	respawn_delay_ticks: int,
	blocker_min_xz: Vector2,
	blocker_max_xz: Vector2,
	claim_radius: float,
	blocks_movement: bool = true
) -> int:
	var new_id := next_entity_id
	next_entity_id += 1
	chest_id.append(new_id)
	chest_position.append(position_xz)
	chest_radius.append(maxf(claim_radius, 0.0))
	chest_state.append(CHEST_STATE_ACTIVE)
	chest_reward_profile.append(reward_profile_index)
	chest_amount.append(amount)
	chest_respawn_delay_ticks.append(respawn_delay_ticks)
	chest_respawn_at_tick.append(-1)
	chest_blocker_min.append(blocker_min_xz)
	chest_blocker_max.append(blocker_max_xz)
	chest_blocks_movement.append(1 if blocks_movement else 0)
	if blocks_movement:
		set_blocker_world_rect(blocker_min_xz, blocker_max_xz, true)
	tick_chest_events.append({
		"kind": &"chest_spawned",
		"chest_id": new_id,
		"position": position_xz,
		"reward_profile_index": reward_profile_index,
		"amount": amount,
	})
	return new_id

## 刻意**没有** release_chest()。
##
## 曾经有过：表现层兑现奖励失败（弹药已满）时把箱子放回地上，好让玩家不至于
## 白白吃掉一箱补给。它复现了它本该修掉的那个 bug——「能不能收下」取决于
## 玩家当前的弹药与存活，而这两个量在各端本来就差着一个 RTT：开火的人自己的
## 客户端立刻扣弹，别人的客户端要等帧到了才扣。于是同一个箱子在一端被消耗、
## 在另一端被放回，chest_state 分叉，而箱子是阻挡几何，流场跟着分叉，
## 最后表现为「他捡走了我这边还看得见」和「两边血量对不上」。
##
## 规矩因此是硬的：**表现层永远不写模拟层的箱子状态**。模拟层判归谁就是谁的，
## 兑现不了就浪费掉。要把「满弹不浪费」找回来，唯一正确的做法是把
## 「这个座位还收不收得下」做成随帧上行的输入，让各端读到同一个值。

func get_chest_count() -> int:
	return chest_id.size()

func index_of_chest(chest_id_value: int) -> int:
	for index in range(chest_id.size()):
		if chest_id[index] == chest_id_value:
			return index
	return -1

func get_chest_state(index: int) -> int:
	if index < 0 or index >= chest_state.size():
		return CHEST_STATE_CONSUMED
	return chest_state[index]

func _update_chest_respawns() -> void:
	for index in range(chest_id.size()):
		if chest_state[index] != CHEST_STATE_WAITING_RESPAWN:
			continue
		if tick_index < chest_respawn_at_tick[index]:
			continue
		chest_state[index] = CHEST_STATE_ACTIVE
		chest_respawn_at_tick[index] = -1
		if chest_blocks_movement[index] == 1:
			set_blocker_world_rect(
				chest_blocker_min[index], chest_blocker_max[index], true
			)
		tick_chest_events.append({
			"kind": &"chest_respawned",
			"chest_id": chest_id[index],
			"position": chest_position[index],
			"reward_profile_index": chest_reward_profile[index],
			"amount": chest_amount[index],
		})

## 领取判定：箱子按注册顺序、玩家按槽位升序扫描，第一个够得着的活人拿走。
##
## 「按槽位升序」是刻意的确定性平局规则。两个玩家同时踩上同一个箱子在
## 现实里会发生，而只要各端都从槽位 0 数起，谁拿到就在所有端上是同一个答案。
## 换成「离得最近的拿」也可以，但那要比浮点距离，恰恰是最容易在各端算出
## 不同结果的东西。
func _resolve_chest_claims() -> void:
	for index in range(chest_id.size()):
		if chest_state[index] != CHEST_STATE_ACTIVE:
			continue
		var claim_range := chest_radius[index] + PLAYER_RADIUS
		var claim_range_squared := claim_range * claim_range
		for slot in range(MAX_PLAYER_SLOTS):
			if player_alive[slot] == 0 or player_present[slot] == 0:
				continue
			var offset := get_player_position(slot) - chest_position[index]
			if offset.length_squared() > claim_range_squared:
				continue
			var accepted_reward := accept_reward(
				slot, chest_reward_profile[index], chest_amount[index]
			)
			if not bool(accepted_reward.get("accepted", false)):
				continue
			if chest_blocks_movement[index] == 1:
				set_blocker_world_rect(
					chest_blocker_min[index], chest_blocker_max[index], false
				)
			tick_chest_events.append({
				"kind": &"chest_claimed",
				"chest_id": chest_id[index],
				"slot": slot,
				"position": chest_position[index],
				"reward_profile_index": chest_reward_profile[index],
				"amount": chest_amount[index],
				"weapon_mod_id": int(accepted_reward.get("weapon_mod_id", -1)),
			})
			if chest_respawn_delay_ticks[index] >= 0:
				chest_state[index] = CHEST_STATE_WAITING_RESPAWN
				chest_respawn_at_tick[index] = (
					tick_index + chest_respawn_delay_ticks[index]
				)
			else:
				chest_state[index] = CHEST_STATE_CONSUMED
				chest_respawn_at_tick[index] = -1
			break

func get_barrel_count() -> int:
	return barrel_id.size()

func get_barrel_id(index: int) -> int:
	return barrel_id[index]

## id 单调递增且油桶数组永不重排，因此可以直接二分。
func index_of_barrel(barrel_id_value: int) -> int:
	var index := barrel_id.bsearch(barrel_id_value, true)
	if index < 0 or index >= barrel_id.size():
		return -1
	return index if barrel_id[index] == barrel_id_value else -1

func get_barrel_position(index: int) -> Vector2:
	return barrel_position[index]

func get_barrel_base_height(index: int) -> float:
	return barrel_base_height[index]

func get_barrel_state(index: int) -> int:
	return barrel_state[index]

func get_barrel_hit_count(index: int) -> int:
	return barrel_hit_count[index]

func get_barrel_fuse_ticks(index: int) -> int:
	return barrel_fuse_ticks[index]

## 实体 id 由单调递增计数器分配，永不复用。
func spawn_zombie(
	position_xz: Vector2,
	facing_yaw: float,
	profile_index: int
) -> int:
	var profile: Dictionary = zombie_profiles[profile_index]
	var new_id := next_entity_id
	next_entity_id += 1
	var health_points := maxi(
		roundi(float(profile["max_health"]) * float(HEALTH_SCALE)),
		1
	)
	zombie_id.append(new_id)
	zombie_profile_index.append(profile_index)
	zombie_position.append(position_xz)
	zombie_height.append(0.0)
	zombie_facing.append(facing_yaw)
	zombie_health.append(health_points)
	zombie_state.append(ZombieBehaviorMathScript.State.WANDER)
	zombie_target_slot.append(NO_TARGET_SLOT)
	zombie_max_health.append(health_points)
	zombie_previous_position.append(position_xz)
	zombie_previous_height.append(0.0)
	zombie_previous_facing.append(facing_yaw)
	zombie_velocity.append(Vector2.ZERO)
	zombie_vertical_velocity.append(0.0)
	zombie_radius.append(ZOMBIE_RADIUS)
	zombie_home.append(position_xz)
	zombie_wander_target.append(position_xz)
	zombie_wander_pause_ticks.append(0)
	zombie_hit_stun_ticks.append(0)
	zombie_move_speed.append(float(profile["move_speed"]))
	for _state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
		zombie_attack_state.append(0)
	tick_spawn_events.append(new_id)
	_select_wander_target(zombie_id.size() - 1)
	return new_id

func configure_wave_schedule(
	waves: Array[Dictionary],
	spawn_points: Array[Dictionary],
	end_mode: int,
	inter_wave_delay_ticks: int,
	maximum_active_zombies: int
) -> void:
	wave_director.configure(
		waves,
		spawn_points,
		end_mode,
		inter_wave_delay_ticks,
		maximum_active_zombies
	)
	pending_spawn_requests = []

func start_wave_schedule() -> void:
	wave_director.start(tick_index)

func request_advance_wave() -> void:
	wave_director.request_advance(tick_index)

func can_advance_wave() -> bool:
	return wave_director.can_advance()

func get_wave_state_words() -> PackedInt32Array:
	return wave_director.get_state_words()

func set_player_snapshot(
	slot: int,
	position_xz: Vector2,
	alive: bool,
	present: bool
) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_position_quantized[slot * 2] = roundi(position_xz.x * POSITION_QUANTIZATION)
	player_position_quantized[slot * 2 + 1] = roundi(position_xz.y * POSITION_QUANTIZATION)
	player_alive[slot] = 1 if alive else 0
	player_present[slot] = 1 if present else 0

func get_player_position(slot: int) -> Vector2:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return Vector2.ZERO
	return Vector2(
		float(player_position_quantized[slot * 2]) / POSITION_QUANTIZATION,
		float(player_position_quantized[slot * 2 + 1]) / POSITION_QUANTIZATION
	)

func is_player_alive(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_alive[slot] == 1

func is_player_present(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_present[slot] == 1

## 任何运行时增删**静态**阻挡几何（墙、集装箱、路障、放置件、拾取箱）的系统都必须调用它，
## 否则流场会停留在过期的通行图上。静态几何同时进通行图与静态阻挡图，
## 因此它既挡僵尸也截子弹。
func set_blocker_world_rect(min_xz: Vector2, max_xz: Vector2, blocked: bool) -> void:
	if blocked:
		grid.add_static_blocker_world_rect(min_xz, max_xz)
	else:
		grid.remove_static_blocker_world_rect(min_xz, max_xz)

## 爆炸桶专用：只进通行图，不进静态阻挡图。
## 桶仍然挡住僵尸的移动与视线（`line_is_clear()` 走通行图），但**不参与**
## `ray_blocked_distance()` 的射程截断——截断点是 cell 中心，比桶的碰撞圆表面更近，
## 桶自己的格若参与截断，射线会停在桶前面，桶就永远打不爆。
## 子弹在哪里被桶挡下由 `SimCombat.resolve_ray_hits()` 用桶的解析圆决定：
## 它排序后遇到第一个 KIND_BARREL 就收尾，等价于基线物理射线停在圆柱面上。
func set_barrel_blocker_world_rect(
	min_xz: Vector2, max_xz: Vector2, blocked: bool
) -> void:
	if blocked:
		grid.add_entity_blocker_world_rect(min_xz, max_xz)
	else:
		grid.remove_entity_blocker_world_rect(min_xz, max_xz)

## 整数 Bresenham 逐 cell 判定视线；终点 cell 自身不算阻挡。
func line_is_clear(from_xz: Vector2, to_xz: Vector2) -> bool:
	var from_cell := grid.world_to_cell(from_xz)
	var to_cell := grid.world_to_cell(to_xz)
	var delta_x := absi(to_cell.x - from_cell.x)
	var delta_y := absi(to_cell.y - from_cell.y)
	var step_x := 1 if to_cell.x >= from_cell.x else -1
	var step_y := 1 if to_cell.y >= from_cell.y else -1
	var error := delta_x - delta_y
	var current := from_cell
	for _step_index in range(delta_x + delta_y + 1):
		if current == to_cell:
			return true
		if current != from_cell and grid.is_blocked(current):
			return false
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return true

## 沿射线走与 line_is_clear() 完全相同的 Bresenham 格序列，
## 返回到第一个**静态**阻挡 cell 中心的距离；一路无阻挡时返回 max_distance。
## 豁免规则也保持一致（起点 cell 与终点 cell 都不算阻挡），
## 这样「命中被墙挡掉」与「曳光停在墙上」不会给出互相矛盾的结论。
##
## 只查静态阻挡图（`is_static_blocked()`）而不是通行图：截断点取的是 cell **中心**，
## 它比 cell 里那件几何的真实表面更近。墙与集装箱铺满整格，这个保守量无害；
## 但爆炸桶只有 0.88 m 宽且中心不一定落在 cell 中心（场景里的 ChainA/ChainB 压在
## z = -3.5 的 cell 边界上），桶自己的格若参与截断，射程会被截到桶的碰撞圆之前，
## 桶就永远打不爆。桶由 `SimCombat.resolve_ray_hits()` 用解析圆自行终止射线。
func ray_blocked_distance(origin: Vector2, direction: Vector2, max_distance: float) -> float:
	if max_distance <= 0.0 or direction.length_squared() <= 0.000001:
		return maxf(max_distance, 0.0)
	var unit_direction := direction.normalized()
	var from_cell := grid.world_to_cell(origin)
	var to_cell := grid.world_to_cell(origin + unit_direction * max_distance)
	var delta_x := absi(to_cell.x - from_cell.x)
	var delta_y := absi(to_cell.y - from_cell.y)
	var step_x := 1 if to_cell.x >= from_cell.x else -1
	var step_y := 1 if to_cell.y >= from_cell.y else -1
	var error := delta_x - delta_y
	var current := from_cell
	for _step_index in range(delta_x + delta_y + 1):
		if current == to_cell:
			return max_distance
		if current != from_cell and grid.is_static_blocked(current):
			return minf(origin.distance_to(grid.cell_to_world(current)), max_distance)
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return max_distance

## 唯一的僵尸掉血入口。damage_points 已是 HEALTH_SCALE 单位的整数。
func apply_zombie_damage(
	index: int,
	damage_points: int,
	hit_position: Vector2,
	hit_height: float,
	direction: Vector2,
	zone: StringName,
	critical: bool = false
) -> bool:
	if index < 0 or index >= zombie_id.size():
		return false
	if zombie_state[index] == STATE_DEAD:
		return false
	var applied := mini(maxi(damage_points, 0), zombie_health[index])
	if applied <= 0:
		return false
	zombie_health[index] -= applied
	var impulse := HitResponseMathScript.knockback_velocity(
		Vector3(direction.x, 0.0, direction.y),
		ZOMBIE_KNOCKBACK_IMPULSE,
		1.0,
		ZOMBIE_KNOCKBACK_VERTICAL_BIAS
	)
	zombie_velocity[index] += Vector2(impulse.x, impulse.z)
	zombie_vertical_velocity[index] += impulse.y
	var killed := zombie_health[index] <= 0
	if not killed:
		zombie_hit_stun_ticks[index] = ZOMBIE_HIT_STUN_TICKS
		MeleeAttackCycleScript.cancel_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE
		)
	tick_hit_events.append({
		"zombie_id": zombie_id[index],
		"position": hit_position,
		"zombie_position": zombie_position[index],
		"height": hit_height,
		"direction": direction,
		"damage": float(applied) / float(HEALTH_SCALE),
		# 表现层的伤害飘字按「打掉了最大生命的百分之多少」分档，所以基数得跟着
		# 事件一起走：同样 14 点伤害打普通僵尸和打坦克是两种不同的读数。
		# 只是随事件下发的展示数据，不进 SimHasher，也不产生新的模拟状态。
		"max_health": float(zombie_max_health[index]) / float(HEALTH_SCALE),
		"zone": zone,
		"critical": critical,
		"killed": killed,
	})
	if killed:
		zombie_state[index] = STATE_DEAD
		zombie_radius[index] = 0.0
		zombie_velocity[index] = Vector2.ZERO
		_resolve_zombie_death_groups(index)
		_queue_zombie_death_explosion(index)
		tick_death_events.append(zombie_id[index])
	return true

## 爆破型僵尸死亡时入队一次爆炸。
##
## 走 queue_explosion_event() 而不是直接结算，有两个原因：
## 一是爆炸在下一 tick 处理，连锁引爆不会在本 tick 内递归，与油桶连锁同一套设计；
## 二是入队后与油桶爆炸共用同一条确定性结算路径，不引入第二套伤害逻辑。
func _queue_zombie_death_explosion(index: int) -> void:
	var profile_index := zombie_profile_index[index]
	if profile_index < 0 or profile_index >= zombie_profiles.size():
		return
	var profile: Dictionary = zombie_profiles[profile_index]
	if not bool(profile.get("explodes_on_death", false)):
		return
	var radius := float(profile.get("explosion_radius", 0.0))
	if radius <= 0.0:
		return
	queue_explosion_event(
		zombie_position[index],
		zombie_height[index],
		radius,
		float(profile.get("explosion_center_damage", 0.0)),
		float(profile.get("explosion_edge_damage", 0.0))
	)

## 唯一的油桶命中入口，语义逐条对应基线 ExplosiveBarrel.apply_hit()：
##   - 已上引信或已销毁的桶算未命中（基线 `state >= State.EXPLODING` 返回 miss）；
##   - 命中数封顶在引爆阈值；
##   - 达到引爆阈值立即引爆（基线是 _request_explosion(0.0)，零延时）；
##   - 达到损伤阈值只切表现状态，且只从 INTACT 切一次。
func apply_barrel_hit(index: int) -> int:
	if index < 0 or index >= barrel_id.size():
		return BARREL_HIT_NONE
	if barrel_state[index] >= BARREL_STATE_PENDING:
		return BARREL_HIT_NONE
	barrel_hit_count[index] = mini(
		barrel_hit_count[index] + 1, barrel_hits_to_explode[index]
	)
	if barrel_hit_count[index] >= barrel_hits_to_explode[index]:
		_detonate_barrel(index)
		return BARREL_HIT_EXPLODED
	if (
		barrel_hit_count[index] >= barrel_hits_to_damage[index] and
		barrel_state[index] == BARREL_STATE_INTACT
	):
		barrel_state[index] = BARREL_STATE_DAMAGED
		tick_barrel_events.append({
			"kind": &"barrel_damaged",
			"barrel_id": barrel_id[index],
			"position": barrel_position[index],
			"height": barrel_base_height[index],
		})
		return BARREL_HIT_DAMAGED
	return BARREL_HIT_REGISTERED

## 油桶节点在**未引爆**的情况下离场（例如被别的系统回收）时由装配方排队。
## 不排队的话模拟层会留下一块永远阻挡的幽灵 cell。
func queue_barrel_removal(barrel_id_value: int) -> void:
	pending_events.append({
		"kind": &"barrel_removed",
		"barrel_id": barrel_id_value,
	})

## 引信推进。分两趟是必须的：引爆会给别的桶上引信，
## 若边减边引爆，本 tick 刚被点燃的桶会在同一趟里被误减一格。
func _update_barrel_fuses() -> void:
	var ready_indices := PackedInt32Array()
	for index in range(barrel_id.size()):
		if barrel_state[index] != BARREL_STATE_PENDING:
			continue
		var remaining := maxi(barrel_fuse_ticks[index] - 1, 0)
		barrel_fuse_ticks[index] = remaining
		if remaining <= 0:
			ready_indices.append(index)
	for index in ready_indices:
		_detonate_barrel(index)

## 引爆：清阻挡 -> 广播表现事件 -> 结算僵尸波及 -> 给邻桶上引信。
## 先清阻挡再结算，复刻基线 ExplosionResolver 把 source 的 RID 排除在遮挡射线
## 之外的效果——爆炸不会被自己挡住，也不该再挡住别人的视线。
func _detonate_barrel(index: int) -> void:
	if barrel_state[index] == BARREL_STATE_DESTROYED:
		return
	barrel_state[index] = BARREL_STATE_DESTROYED
	barrel_fuse_ticks[index] = 0
	barrel_hit_count[index] = barrel_hits_to_explode[index]
	var origin := barrel_position[index]
	var origin_height := SimHitGeometryScript.barrel_aim_height(
		barrel_base_height[index]
	)
	var radius := barrel_radius[index]
	var center_damage := barrel_center_damage[index]
	var edge_damage := barrel_edge_damage[index]
	set_barrel_blocker_world_rect(
		barrel_blocker_min[index], barrel_blocker_max[index], false
	)
	tick_barrel_events.append({
		"kind": &"barrel_exploded",
		"barrel_id": barrel_id[index],
		"position": origin,
		"height": origin_height,
		"radius": radius,
		"center_damage": center_damage,
		"edge_damage": edge_damage,
	})
	_apply_explosion_to_zombies(
		origin, origin_height, radius, center_damage, edge_damage
	)
	# 连锁只上引信，不立刻炸：延时换算成 tick，各端逐 tick 对齐。
	var chained := SimCombatScript.resolve_explosion_barrels(
		self, origin, origin_height, radius, center_damage, edge_damage, index
	)
	for chained_index in chained:
		barrel_state[chained_index] = BARREL_STATE_PENDING
		barrel_fuse_ticks[chained_index] = barrel_chain_ticks[chained_index]

## 爆炸对僵尸的结算。油桶引爆与 queue_explosion_event() 共用这一份，
## 保证两条入口的波及口径逐字一致。
func _apply_explosion_to_zombies(
	origin: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> void:
	var targets := SimCombatScript.resolve_explosion_targets(
		self, origin, origin_height, radius, center_damage, edge_damage
	)
	for target in targets:
		apply_zombie_damage(
			int(target["index"]),
			roundi(float(target["damage"]) * float(HEALTH_SCALE)),
			target["point"],
			float(target["height"]),
			target["direction"],
			SimHitGeometryScript.ZONE_BODY
		)

func _resolve_barrel_removal_event(event: Dictionary) -> void:
	var index := index_of_barrel(int(event["barrel_id"]))
	if index < 0 or barrel_state[index] == BARREL_STATE_DESTROYED:
		return
	barrel_state[index] = BARREL_STATE_DESTROYED
	barrel_fuse_ticks[index] = 0
	set_barrel_blocker_world_rect(
		barrel_blocker_min[index], barrel_blocker_max[index], false
	)

## 推进一个模拟 tick。不接收任何真实帧时长形参：时间步长恒为 SimClock.TICK_SECONDS。
## 顺序固定：清事件 -> 波次状态机 -> 生成 -> 补给重生/领取 -> 散布回复 ->
## 油桶与玩家事件 -> 死亡掉落物化 -> 流场 -> 僵尸推进 -> 碰撞 -> 攻击 -> 压缩删除。
##
## 引信推进排在事件结算**之前**是刻意的：本 tick 里被射击引爆的桶会给邻桶上引信，
## 若引信先减后点，实际连锁延时会比 chain_delay_seconds 短一整 tick。
## 引爆会清掉油桶占的阻挡格，因此这两步都必须排在 _update_flow_field() 之前，
## 让同一 tick 的流场就看到新的通行图。
func step_tick() -> void:
	tick_index += 1
	_clear_tick_events()
	_queue_wave_spawn_requests()
	_apply_pending_spawn_requests()
	_update_chest_respawns()
	_resolve_chest_claims()
	_recover_spread()
	_update_barrel_fuses()
	_resolve_pending_events()
	_update_medic_auras()
	_materialize_death_rule_drops()
	_update_flow_field()
	_update_zombies()
	_resolve_collisions()
	_resolve_zombie_attacks()
	_compact_dead()

func _materialize_death_rule_drops() -> void:
	for event in tick_death_rule_events:
		if event.get("kind", StringName()) == &"drop_item":
			var position: Vector2 = event["position"]
			spawn_chest(
				position,
				int(event["reward_profile_index"]),
				int(event["amount"]),
				-1,
				position - CHEST_BLOCKER_HALF_SIZE,
				position + CHEST_BLOCKER_HALF_SIZE,
				CHEST_CLAIM_RADIUS,
				# 战利品不占阻挡格。它落在僵尸死亡的那一点上、没有任何可通行性校验，
				# 占格的后果是：地上的战利品把战场织成迷宫、玩家的子弹被自己刚打出来的
				# 战利品挡住（阻挡格同时进 ray_blocked_distance 的静态图）、
				# 以及每掉一件就标脏流场触发一次全网格 BFS 重建。
				false
			)
		elif event.get("kind", StringName()) == &"material_drop":
			# 材料归属：僵尸死亡时它在追的玩家（zombie_target_slot）。这是确定性
			# 判定——各端对「这只僵尸在追谁」的答案一致，于是材料给谁也一样。
			# 用 max/min 区间 + 确定性 RNG 定实际掉落数。
			var index := index_of_zombie(int(event["zombie_id"]))
			if index < 0:
				continue
			var target_slot := int(zombie_target_slot[index])
			if target_slot < 0 or target_slot >= MAX_PLAYER_SLOTS:
				continue
			var min_amount := maxi(int(event.get("min_amount", 1)), 1)
			var max_amount := maxi(int(event.get("max_amount", 1)), min_amount)
			var amount := rng.next_uint32(
				DeterministicRngScript.Stream.LOOT_DROP
			) % (max_amount - min_amount + 1) + min_amount
			add_player_material(target_slot, amount)

func _clear_tick_events() -> void:
	tick_hit_events = []
	tick_death_events = PackedInt32Array()
	tick_spawn_events = PackedInt32Array()
	tick_player_damage_events = []
	tick_player_heal_events = []
	tick_shot_events = []
	tick_barrel_events = []
	tick_chest_events = []
	tick_inventory_events = []
	tick_inventory_feedback = []
	tick_wave_events = []
	tick_death_rule_events = []

func _queue_wave_spawn_requests() -> void:
	var commands_and_events: Array[Dictionary] = wave_director.step_tick(
		tick_index, zombie_id.size(), pending_spawn_requests.size()
	)
	for command_or_event in commands_and_events:
		if command_or_event.get("kind", StringName()) == &"spawn_zombie":
			pending_spawn_requests.append(command_or_event)
		else:
			tick_wave_events.append(command_or_event)

func _apply_pending_spawn_requests() -> void:
	if pending_spawn_requests.is_empty():
		return
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	var requests := pending_spawn_requests
	pending_spawn_requests = []
	var occupied := zombie_position.duplicate()
	for request in requests:
		var spawn_position = _sample_spawn_position(
			request["center"],
			float(request["radius"]),
			float(request["minimum_spacing"]),
			occupied
		)
		if spawn_position == null:
			pending_spawn_requests.append(request)
			continue
		var facing := rng.next_range(spawn_stream, 0.0, TAU)
		spawn_zombie(spawn_position, facing, int(request["profile_index"]))
		occupied.append(spawn_position)

func _sample_spawn_position(
	center: Vector2,
	radius: float,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> Variant:
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	for _attempt in range(16):
		var angle := rng.next_range(spawn_stream, 0.0, TAU)
		# sqrt 保留内置的：IEEE 754 要求它正确舍入，跨平台本来就逐位相同。
		# 三角函数不是，见 SimMath。
		var sample_radius := sqrt(rng.next_unit_float(spawn_stream)) * radius
		var candidate := center + SimMathScript.direction_from_angle(angle) * sample_radius
		if _has_spawn_clearance(candidate, minimum_spacing, occupied):
			return candidate
	if not grid.is_blocked(grid.world_to_cell(center)):
		return center
	return null

func _has_spawn_clearance(
	candidate: Vector2,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> bool:
	if grid.is_blocked(grid.world_to_cell(candidate)):
		return false
	for position in occupied:
		if candidate.distance_to(position) < minimum_spacing:
			return false
	return true

func _update_flow_field() -> void:
	var sources := PackedInt32Array()
	for slot in range(MAX_PLAYER_SLOTS):
		if player_present[slot] == 0 or player_alive[slot] == 0:
			continue
		var cell_index := grid.cell_index(grid.world_to_cell(get_player_position(slot)))
		if cell_index >= 0 and not sources.has(cell_index):
			sources.append(cell_index)
	sources.sort()
	var elapsed := tick_index - last_flow_field_rebuild_tick
	var allow_source_rebuild := elapsed >= FLOW_FIELD_REBUILD_INTERVAL_TICKS
	if flow_field.update(sources, allow_source_rebuild):
		last_flow_field_rebuild_tick = tick_index

func _update_zombies() -> void:
	var count := zombie_id.size()
	var tick_seconds := SimClockScript.TICK_SECONDS
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		zombie_previous_position[index] = zombie_position[index]
		zombie_previous_facing[index] = zombie_facing[index]
		zombie_previous_height[index] = zombie_height[index]
		# 生成命令的中心是本 tick 的确定性落点；新实体从下一 tick 才开始移动，
		# 否则生成事件刚发出时位置已经被游荡推进改写。
		if tick_spawn_events.has(zombie_id[index]):
			continue
		zombie_hit_stun_ticks[index] = maxi(zombie_hit_stun_ticks[index] - 1, 0)

		var position := zombie_position[index]
		var target_slot := _select_target_slot(position, int(zombie_target_slot[index]))
		zombie_target_slot[index] = target_slot
		var target_alive := target_slot != NO_TARGET_SLOT
		var target_position := Vector2.ZERO
		var direction_to_target := Vector2.ZERO
		var distance_to_target := INF
		if target_alive:
			target_position = get_player_position(target_slot)
			direction_to_target = target_position - position
			distance_to_target = direction_to_target.length()
			if distance_to_target > 0.001:
				direction_to_target /= distance_to_target
		var attack_path_clear := (
			target_alive and
			distance_to_target <= ZOMBIE_ATTACK_RANGE and
			line_is_clear(position, target_position)
		)

		var previous_state := int(zombie_state[index])
		var next_state := ZombieBehaviorMathScript.next_state(
			previous_state,
			distance_to_target,
			target_alive,
			perception_range,
			ZOMBIE_PERCEPTION_EXIT_MARGIN,
			ZOMBIE_ATTACK_RANGE,
			attack_path_clear
		)
		zombie_state[index] = next_state
		if (
			previous_state == ZombieBehaviorMathScript.State.ATTACK and
			next_state != ZombieBehaviorMathScript.State.ATTACK
		):
			MeleeAttackCycleScript.cancel_state(
				zombie_attack_state,
				index * MeleeAttackCycleScript.STATE_SIZE
			)

		var target_velocity := Vector2.ZERO
		if zombie_hit_stun_ticks[index] <= 0:
			if next_state == ZombieBehaviorMathScript.State.WANDER:
				target_velocity = _wander_velocity(index)
			elif next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH:
				target_velocity = _approach_velocity(
					index,
					distance_to_target,
					direction_to_target,
					target_position
				)

		var facing_direction := direction_to_target
		if (
			next_state == ZombieBehaviorMathScript.State.WANDER or
			(
				next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH and
				target_velocity.length_squared() > 0.0001
			)
		):
			facing_direction = target_velocity
		if facing_direction.length_squared() > 0.0001:
			zombie_facing[index] = ZombieBehaviorMathScript.facing_yaw(
				Vector3(facing_direction.x, 0.0, facing_direction.y),
				zombie_facing[index]
			)

		var moving := target_velocity.length_squared() > 0.0001
		var rate := ZOMBIE_MOVE_ACCELERATION if moving else ZOMBIE_GROUND_DRAG
		var velocity := zombie_velocity[index]
		velocity.x = move_toward(velocity.x, target_velocity.x, rate * tick_seconds)
		velocity.y = move_toward(velocity.y, target_velocity.y, rate * tick_seconds)
		zombie_velocity[index] = velocity
		zombie_position[index] = position + velocity * tick_seconds

		var vertical_velocity := zombie_vertical_velocity[index]
		var height := zombie_height[index]
		if height > 0.0 or vertical_velocity > 0.0:
			vertical_velocity -= SIM_GRAVITY * tick_seconds
			height += vertical_velocity * tick_seconds
			if height <= 0.0:
				height = 0.0
				vertical_velocity = 0.0
		zombie_height[index] = height
		zombie_vertical_velocity[index] = vertical_velocity

## ZombieTargetSelector 语义在玩家槽位快照上的复刻：最近优先，
## 切换必须比当前目标近出 ZOMBIE_TARGET_SWITCH_MARGIN 才生效。
func _select_target_slot(position: Vector2, current_slot: int) -> int:
	var best_slot := NO_TARGET_SLOT
	var best_distance := INF
	if _slot_is_candidate(current_slot, position):
		best_slot = current_slot
		best_distance = position.distance_to(get_player_position(current_slot))
	for slot in range(MAX_PLAYER_SLOTS):
		if not _slot_is_candidate(slot, position):
			continue
		var distance := position.distance_to(get_player_position(slot))
		if distance + ZOMBIE_TARGET_SWITCH_MARGIN < best_distance:
			best_slot = slot
			best_distance = distance
	return best_slot

func _slot_is_candidate(slot: int, position: Vector2) -> bool:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return false
	if player_present[slot] == 0 or player_alive[slot] == 0:
		return false
	return position.distance_to(get_player_position(slot)) <= perception_range

func _select_wander_target(index: int) -> void:
	var wander_stream: int = DeterministicRngScript.Stream.ZOMBIE_WANDER
	var angle := rng.next_range(wander_stream, 0.0, TAU)
	var distance_ratio := rng.next_range(wander_stream, 0.35, 1.0)
	var home := zombie_home[index]
	var point := ZombieBehaviorMathScript.wander_point(
		Vector3(home.x, 0.0, home.y),
		angle,
		distance_ratio,
		ZOMBIE_WANDER_RADIUS
	)
	zombie_wander_target[index] = Vector2(point.x, point.z)

func _wander_velocity(index: int) -> Vector2:
	if zombie_wander_pause_ticks[index] > 0:
		zombie_wander_pause_ticks[index] -= 1
		if zombie_wander_pause_ticks[index] <= 0:
			_select_wander_target(index)
		return Vector2.ZERO
	var position := zombie_position[index]
	var target := zombie_wander_target[index]
	var velocity_3d := ZombieBehaviorMathScript.arrive_velocity(
		Vector3(position.x, 0.0, position.y),
		Vector3(target.x, 0.0, target.y),
		ZOMBIE_WANDER_ARRIVE_RANGE,
		ZOMBIE_WANDER_SPEED,
		ZOMBIE_WANDER_SLOW_RADIUS
	)
	var velocity := Vector2(velocity_3d.x, velocity_3d.z)
	if velocity == Vector2.ZERO:
		zombie_wander_pause_ticks[index] = rng.next_int_range(
			DeterministicRngScript.Stream.ZOMBIE_WANDER,
			ZOMBIE_WANDER_PAUSE_MIN_TICKS,
			ZOMBIE_WANDER_PAUSE_MAX_TICKS
		)
	return velocity

## 追击只查自己所在 cell 的方向向量，成本与僵尸数量无关。
## 流场不可达（例如被临时封死）时退回直线方向，行为与旧的导航不可用回退一致。
##
## 直线追击（ZOMBIE_DIRECT_CHASE_RANGE 内）只在**视线通畅**时用：视线被墙挡住还直冲，
## 僵尸会沿直线贴到玩家背后的墙上，被 `resolve_circle_push()` 的纯径向推离顶住——
## 前进速度与推离完全抵消，又因为直线区不查流场而永远绕不回去，永久死锁。所以贴身
## 但看不见玩家时落回流场绕行，流场会把它带回能直视玩家的位置再收拢。
func _approach_velocity(
	index: int,
	distance_to_target: float,
	direction_to_target: Vector2,
	target_position: Vector2
) -> Vector2:
	var attack_path_clear := (
		distance_to_target <= ZOMBIE_ATTACK_RANGE and
		line_is_clear(zombie_position[index], target_position)
	)
	var stop_range := ZombieBehaviorMathScript.approach_stop_range(
		distance_to_target, ZOMBIE_ATTACK_RANGE, attack_path_clear
	)
	var gap := distance_to_target - stop_range
	if gap <= 0.0:
		return Vector2.ZERO
	var speed_factor := clampf(gap / ZOMBIE_PERCEPTION_SLOW_RADIUS, 0.25, 1.0)
	var chase_directly := (
		distance_to_target <= ZOMBIE_DIRECT_CHASE_RANGE and
		line_is_clear(zombie_position[index], target_position)
	)
	# 贴身范围内且看得见才直线追，不查流场：流场是节流重建的，近距离用它会追着玩家
	# 一个重建间隔之前的位置跑。看不见就走亚格平滑流场方向绕行。
	var direction := direction_to_target
	if not chase_directly:
		# 用亚格平滑方向而不是单格量化方向：贴墙僵尸的方向会随亚格位置连续偏成
		# 沿墙切向，配合径向推离就能顺墙滑出死角，而不是被钉在墙上原地抖。
		direction = flow_field.get_direction_smooth(zombie_position[index])
		# 给流场方向叠一个侧向偏移，让尸群沿不同弧线逼近。
		#
		# 流场对所有僵尸给出同一条最短路径，于是整群会压成一条线鱼贯而来，玩家
		# 一直后退就能持续拉开。到跟前再分散是来不及的——僵尸互相不能穿过，
		# 前排占住位置后，后排在物理上就绕不过去了。所以必须在**远处**就分头走。
		#
		# 偏移量随距离衰减，进入 ZOMBIE_FLANK_FALLOFF_RANGE 后归零，保证最后仍然
		# 收拢到玩家身上而不是绕着圈跑。方向盘由实体 id 决定，各端一致。
		if direction.length_squared() > 0.0001:
			var lane := SimMathScript.direction_from_angle(
				float(zombie_id[index]) * ZOMBIE_FLANK_ANGLE_STEP
			).x
			var falloff := clampf(
				(distance_to_target - ZOMBIE_DIRECT_CHASE_RANGE)
				/ ZOMBIE_FLANK_FALLOFF_RANGE,
				0.0,
				1.0
			)
			var lateral := Vector2(-direction.y, direction.x)
			direction = (
				direction + lateral * lane * falloff * ZOMBIE_FLANK_STRENGTH
			)
	if direction.length_squared() <= 0.0001:
		direction = direction_to_target
	if direction.length_squared() <= 0.0001:
		return Vector2.ZERO
	return direction.normalized() * zombie_move_speed[index] * speed_factor

func _resolve_collisions() -> void:
	var count := zombie_id.size()
	# 波次生成只会按 id 顺序追加实体，tick_spawn_events 因而对应数组尾部。
	# 新实体从下一 tick 才参与碰撞配对，避免它只推动旧实体而自身不接收位移。
	var collision_count := count - tick_spawn_events.size()
	if collision_count <= 0:
		return
	var displacement := SimCollisionScript.accumulate_separation(
		zombie_position,
		zombie_radius,
		collision_count,
		SimCollisionScript.DEFAULT_HASH_CELL_SIZE,
		ZOMBIE_SEPARATION_RATIO
	)
	for index in range(collision_count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var radius := zombie_radius[index]
		var position := zombie_position[index] + displacement[index]
		for slot in range(MAX_PLAYER_SLOTS):
			if player_present[slot] == 0 or player_alive[slot] == 0:
				continue
			position += SimCollisionScript.resolve_circle_push(
				position, radius, get_player_position(slot), PLAYER_RADIUS
			)
		position += SimCollisionScript.resolve_blocker(position, radius, grid)
		zombie_position[index] = position

func _resolve_zombie_attacks() -> void:
	var count := zombie_id.size()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var target_slot := int(zombie_target_slot[index])
		var target_alive := target_slot != NO_TARGET_SLOT and is_player_alive(target_slot)
		var target_in_range := false
		if target_alive:
			target_in_range = (
				zombie_state[index] == ZombieBehaviorMathScript.State.ATTACK and
				zombie_position[index].distance_to(get_player_position(target_slot))
					<= ZOMBIE_ATTACK_RANGE and
				zombie_hit_stun_ticks[index] <= 0
			)
		var outcome := MeleeAttackCycleScript.tick_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE,
			ZOMBIE_ATTACK_COOLDOWN_TICKS,
			ZOMBIE_ATTACK_WINDUP_TICKS,
			target_in_range,
			target_alive
		)
		if outcome == MeleeAttackCycleScript.TickOutcome.WINDUP_STARTED:
			tick_player_damage_events.append({
				"kind": &"zombie_windup",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": 0.0,
				"origin": zombie_position[index],
			})
		elif outcome == MeleeAttackCycleScript.TickOutcome.ATTACK_LANDED:
			tick_player_damage_events.append({
				"kind": &"zombie_hit",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": ZOMBIE_ATTACK_DAMAGE,
				"origin": zombie_position[index],
			})

## 按顺序压缩删除，保证下标顺序始终等于 id 升序。
func _compact_dead() -> void:
	var count := zombie_id.size()
	var survivor_count := 0
	for index in range(count):
		if zombie_state[index] != STATE_DEAD:
			survivor_count += 1
	if survivor_count == count:
		return
	var new_id := PackedInt32Array()
	var new_profile_index := PackedInt32Array()
	var new_position := PackedVector2Array()
	var new_height := PackedFloat32Array()
	var new_facing := PackedFloat32Array()
	var new_health := PackedInt32Array()
	var new_state := PackedByteArray()
	var new_target_slot := PackedByteArray()
	var new_max_health := PackedInt32Array()
	var new_previous_position := PackedVector2Array()
	var new_previous_height := PackedFloat32Array()
	var new_previous_facing := PackedFloat32Array()
	var new_velocity := PackedVector2Array()
	var new_vertical_velocity := PackedFloat32Array()
	var new_radius := PackedFloat32Array()
	var new_home := PackedVector2Array()
	var new_wander_target := PackedVector2Array()
	var new_wander_pause_ticks := PackedInt32Array()
	var new_hit_stun_ticks := PackedInt32Array()
	var new_move_speed := PackedFloat32Array()
	var new_attack_state := PackedInt32Array()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		new_id.append(zombie_id[index])
		new_profile_index.append(zombie_profile_index[index])
		new_position.append(zombie_position[index])
		new_height.append(zombie_height[index])
		new_facing.append(zombie_facing[index])
		new_health.append(zombie_health[index])
		new_state.append(zombie_state[index])
		new_target_slot.append(zombie_target_slot[index])
		new_max_health.append(zombie_max_health[index])
		new_previous_position.append(zombie_previous_position[index])
		new_previous_height.append(zombie_previous_height[index])
		new_previous_facing.append(zombie_previous_facing[index])
		new_velocity.append(zombie_velocity[index])
		new_vertical_velocity.append(zombie_vertical_velocity[index])
		new_radius.append(zombie_radius[index])
		new_home.append(zombie_home[index])
		new_wander_target.append(zombie_wander_target[index])
		new_wander_pause_ticks.append(zombie_wander_pause_ticks[index])
		new_hit_stun_ticks.append(zombie_hit_stun_ticks[index])
		new_move_speed.append(zombie_move_speed[index])
		for state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
			new_attack_state.append(
				zombie_attack_state[index * MeleeAttackCycleScript.STATE_SIZE + state_slot]
			)
	zombie_id = new_id
	zombie_profile_index = new_profile_index
	zombie_position = new_position
	zombie_height = new_height
	zombie_facing = new_facing
	zombie_health = new_health
	zombie_state = new_state
	zombie_target_slot = new_target_slot
	zombie_max_health = new_max_health
	zombie_previous_position = new_previous_position
	zombie_previous_height = new_previous_height
	zombie_previous_facing = new_previous_facing
	zombie_velocity = new_velocity
	zombie_vertical_velocity = new_vertical_velocity
	zombie_radius = new_radius
	zombie_home = new_home
	zombie_wander_target = new_wander_target
	zombie_wander_pause_ticks = new_wander_pause_ticks
	zombie_hit_stun_ticks = new_hit_stun_ticks
	zombie_move_speed = new_move_speed
	zombie_attack_state = new_attack_state

## 爆炸参数是可选的，缺省即不爆炸，因此现有三个调用点无需改动。
func configure_zombie_profile(
	profile_index: int,
	max_health: int,
	move_speed: float,
	explodes_on_death: bool = false,
	explosion_radius: float = 0.0,
	explosion_center_damage: float = 0.0,
	explosion_edge_damage: float = 0.0
) -> void:
	if profile_index < 0:
		return
	while zombie_profiles.size() <= profile_index:
		zombie_profiles.append({})
	zombie_profiles[profile_index] = {
		"max_health": maxi(max_health, 1),
		"move_speed": maxf(move_speed, 0.0),
		"explodes_on_death": explodes_on_death,
		"explosion_radius": maxf(explosion_radius, 0.0),
		"explosion_center_damage": maxf(explosion_center_damage, 0.0),
		"explosion_edge_damage": maxf(explosion_edge_damage, 0.0),
	}

## 每个组独立掷触发概率；单个命中组仅按正整数权重选择一个事件。
func configure_zombie_death_groups(profile_index: int, groups: Array[Dictionary]) -> void:
	if profile_index < 0:
		return
	while zombie_death_groups.size() <= profile_index:
		zombie_death_groups.append([])
	zombie_death_groups[profile_index] = groups

func _resolve_zombie_death_groups(index: int) -> void:
	var profile_index := zombie_profile_index[index]
	if profile_index < 0 or profile_index >= zombie_death_groups.size():
		return
	for group_variant in zombie_death_groups[profile_index]:
		var group: Dictionary = group_variant
		var trigger_chance_per_10000 := int(group.get("trigger_chance_per_10000", 0))
		var chance_roll := rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP) % 10000
		if chance_roll >= trigger_chance_per_10000:
			continue
		var events: Array = group.get("events", [])
		var total_weight := 0
		for event_variant in events:
			var event: Dictionary = event_variant
			total_weight += maxi(int(event.get("weight", 0)), 0)
		if total_weight <= 0:
			continue
		var choice := rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP) % total_weight
		var accumulated_weight := 0
		for event_variant in events:
			var event: Dictionary = event_variant
			var weight := int(event.get("weight", 0))
			if weight <= 0:
				continue
			accumulated_weight += weight
			if choice >= accumulated_weight:
				continue
			var event_type := int(event.get("event_type", -1))
			if event_type == DROP_ITEM:
				tick_death_rule_events.append({
					"kind": &"drop_item",
					"zombie_id": zombie_id[index],
					"profile_index": zombie_profile_index[index],
					"group_id": group["group_id"],
					"reward_profile_index": event["reward_profile_index"],
					"amount": event["amount"],
					"position": zombie_position[index],
				})
			elif event_type == DROP_MATERIAL:
				tick_death_rule_events.append({
					"kind": &"material_drop",
					"zombie_id": zombie_id[index],
					"profile_index": zombie_profile_index[index],
					"group_id": group["group_id"],
					"min_amount": event.get("material_drop_min", 1),
					"max_amount": event.get("material_drop_max", 1),
					"position": zombie_position[index],
				})
			else:
				push_error("unsupported zombie death event type: %d" % event_type)
			break

## ---- 武器档案 ----
## 由表现层在装配时按 weapon_id 注册；模拟层只认下标，不认资源。
func configure_weapon_profile(
	profile_index: int,
	damage: float,
	attack_range: float,
	base_spread_degrees: float,
	max_spread_degrees: float,
	spread_increase_degrees: float,
	spread_recovery_degrees_per_second: float,
	max_penetration_count: int,
	penetration_damage_coefficient: float,
	pellet_count: int = 1,
	weapon_id: StringName = &"",
	crit_chance_percent: float = 0.0,
	crit_multiplier: float = 1.0
) -> void:
	if profile_index < 0:
		return
	while weapon_profiles.size() <= profile_index:
		weapon_profiles.append({})
	while weapon_profile_ammo_ids.size() <= profile_index:
		weapon_profile_ammo_ids.append(&"")
	weapon_profile_ammo_ids[profile_index] = weapon_id
	weapon_profiles[profile_index] = {
		"damage": maxf(damage, 0.0),
		"attack_range": maxf(attack_range, 0.0),
		"base_spread_degrees": maxf(base_spread_degrees, 0.0),
		"max_spread_degrees": maxf(max_spread_degrees, maxf(base_spread_degrees, 0.0)),
		"spread_increase_degrees": maxf(spread_increase_degrees, 0.0),
		"spread_recovery_degrees_per_second": maxf(spread_recovery_degrees_per_second, 0.0),
		"max_penetration_count": clampi(max_penetration_count, 0, 16),
		"penetration_damage_coefficient": clampf(penetration_damage_coefficient, 0.0, 1.0),
		"pellet_count": clampi(pellet_count, 1, 32),
		# 百分比/倍率在这里一次性转成整数，之后判定与结算全走整数：
		# 暴击掷点是 `uint32 % 10000 < chance`，伤害是 `points * permille / 1000`，
		# 全程没有浮点比较也没有浮点连乘，四台机器逐位一致。
		"crit_chance_per_10000": clampi(roundi(crit_chance_percent * 100.0), 0, 10000),
		"crit_multiplier_permille": maxi(roundi(crit_multiplier * 1000.0), 1000),
	}

## 已注册的武器档案数。profile 下标 0..count-1 都是合法武器。
## 配置某个座位的「压制」被动强度。relief 是散布增长的削减比例。
func configure_player_suppression(slot: int, relief: float) -> void:
	if slot < 0 or slot >= player_suppression_relief.size():
		return
	player_suppression_relief[slot] = clampf(relief, 0.0, 0.9)

## 已注册的武器档案数。profile 下标 0..count-1 都是合法武器。
func weapon_profile_count() -> int:
	return weapon_profiles.size()

## 登记某座位本命武器的伤害缩放。非本命武器档案的 scale 恒为 1.0。
## 各端从同一份角色目录独立调用，结果必然一致；进帧哈希做哨兵。
func set_player_signature_scale(slot: int, profile_index: int, scale: float) -> void:
	var count := weapon_profile_count()
	if slot < 0 or slot >= MAX_PLAYER_SLOTS or profile_index < 0 or profile_index >= count:
		return
	if player_signature_scale.size() != MAX_PLAYER_SLOTS * count:
		player_signature_scale.resize(MAX_PLAYER_SLOTS * count)
		player_signature_scale.fill(1.0)
	player_signature_scale[slot * count + profile_index] = maxf(scale, 0.0)

## 读取本命武器缩放。未登记时返回 1.0（无加成）。
func get_player_signature_scale(slot: int, profile_index: int) -> float:
	var count := weapon_profile_count()
	if count == 0 or slot < 0 or slot >= MAX_PLAYER_SLOTS or profile_index < 0 or profile_index >= count:
		return 1.0
	if player_signature_scale.size() != MAX_PLAYER_SLOTS * count:
		return 1.0
	return player_signature_scale[slot * count + profile_index]

## ---- 逐玩家材料（货币） ----

## 给某座位增加材料。amount 可为负（退款用），结果钳到非负。
func add_player_material(slot: int, amount: int) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_material[slot] = maxi(0, player_material[slot] + amount)

func get_player_material(slot: int) -> int:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0
	return player_material[slot]

## 扣费。够才扣并返回 true；不够不动并返回 false。
func spend_player_material(slot: int, amount: int) -> bool:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return false
	if player_material[slot] < amount:
		return false
	player_material[slot] -= amount
	return true

## ---- 属性成长（波间商店买的 stat/heal 升级） ----

## 读取某座位某属性的成长倍率/加值。未初始化时返回 1.0。
func get_upgrade_scale(slot: int, stat_index: int) -> float:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS or stat_index < 0 or stat_index >= STAT_COUNT:
		return 1.0
	if player_upgrade_scale.size() != MAX_PLAYER_SLOTS * STAT_COUNT:
		return 1.0
	return player_upgrade_scale[slot * STAT_COUNT + stat_index]

## 属性/回血购买命令。进 pending_events，由 _resolve_shop_purchase 确定性应用
## （扣费 + 生效）。stat 的 amount 是倍率（伤害/移速）或加值（最大生命）：
## 伤害/移速乘进 player_upgrade_scale；最大生命也乘进该座位自己的表，
## 由 arena 在表现层把基准 max_health × 该加值应用到玩家血条。
func queue_shop_purchase(
	slot: int,
	offer_type: StringName,
	stat_index: int,
	amount: float,
	price: int
) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	pending_events.append({
		"kind": &"shop_purchase",
		"slot": slot,
		"offer_type": offer_type,
		"stat_index": stat_index,
		"amount": amount,
		"price": price,
	})

func _resolve_shop_purchase(event: Dictionary) -> void:
	var slot := int(event["slot"])
	if not spend_player_material(slot, int(event["price"])):
		return
	var type: StringName = event["offer_type"]
	if type == &"stat":
		var stat_index := int(event["stat_index"])
		if stat_index >= 0 and stat_index < STAT_COUNT:
			player_upgrade_scale[slot * STAT_COUNT + stat_index] *= maxf(float(event["amount"]), 0.0)
	elif type == &"heal":
		tick_player_heal_events.append({
			"slot": slot,
			"amount": maxf(float(event["amount"]), 0.0),
		})
	elif type == &"weapon_mod":
		# 改装件层数进 player_mod_level，而那个数组逐 tick 进帧哈希——所以买改装件
		# 必须和拾取改装件走同一条模拟入口，不能在表现层 grant 完事。
		# stat_index 复用为 WeaponModTable 下标，amount 复用为层数。
		if not _grant_weapon_mod_with_ledger(
			slot, int(event["stat_index"]), int(event["amount"])
		):
			add_player_material(slot, int(event["price"]))  # 已满/无槽位，退款

## 登记某座位是否为医疗、及其光环强度。各端从同一份角色目录独立调用，
## 结果必然一致（无需进网络帧）；回血量取决于它，进帧哈希间接覆盖。
func set_slot_medic(slot: int, is_medic: bool, strength: float) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	if slot_is_medic.size() != MAX_PLAYER_SLOTS:
		slot_is_medic.resize(MAX_PLAYER_SLOTS)
		slot_is_medic.fill(0)
		slot_medic_strength.resize(MAX_PLAYER_SLOTS)
		slot_medic_strength.fill(1.0)
	slot_is_medic[slot] = 1 if is_medic else 0
	slot_medic_strength[slot] = maxf(strength, 0.0)

## 医疗光环结算。复用 _resolve_chest_claims 的距离判定模式：用 get_player_position
## 反量化 + length_squared 比较，绝不直接比较浮点距离（各端可能算出不同结果）。
func _update_medic_auras() -> void:
	if get_tick() % MEDIC_AURA_INTERVAL_TICKS != 0:
		return
	if slot_is_medic.size() != MAX_PLAYER_SLOTS:
		return
	for healer in range(MAX_PLAYER_SLOTS):
		if slot_is_medic[healer] == 0:
			continue
		if not is_player_alive(healer) or not is_player_present(healer):
			continue
		var healer_position := get_player_position(healer)
		var radius_squared := MEDIC_AURA_RADIUS * MEDIC_AURA_RADIUS
		for target in range(MAX_PLAYER_SLOTS):
			if target == healer:
				continue
			if not is_player_alive(target) or not is_player_present(target):
				continue
			var offset := get_player_position(target) - healer_position
			if offset.length_squared() > radius_squared:
				continue
			tick_player_heal_events.append({
				"slot": target,
				"amount": MEDIC_AURA_HEAL_PER_PROC * slot_medic_strength[healer],
			})

## 开火事件只携带玩家的瞄准方向，不携带散布后的方向。
## 散布由各客户端在 Stream.WEAPON_SPREAD 上各自确定性地算出。
func queue_fire_event(
	slot: int,
	profile_index: int,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"shot",
		"slot": slot,
		"profile_index": profile_index,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_melee_event(
	slot: int,
	damage: float,
	reach: float,
	half_width: float,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"melee",
		"slot": slot,
		"damage": damage,
		"reach": reach,
		"half_width": half_width,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_explosion_event(
	origin_xz: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> void:
	pending_events.append({
		"kind": &"explosion",
		"origin": origin_xz,
		"origin_height": origin_height,
		"radius": radius,
		"center_damage": center_damage,
		"edge_damage": edge_damage,
	})

## profile_index 必须是「换上」的那把武器的档案下标，不是被换下的那把。
func queue_spread_reset(slot: int, profile_index: int) -> void:
	pending_events.append({
		"kind": &"spread_reset",
		"slot": slot,
		"profile_index": profile_index,
	})

## 把槽位的散布重置为 profile_index 这把武器自己的基础散布。
## 必须先落档案再取 base：player_spread_profile[slot] 记录的是「上一次开火用的档案」，
## 换装后若沿用旧下标，就会把新武器重置到旧武器的 base。
## 基线里每把 RangedWeapon 各自持有一个 WeaponSpreadState（构造即 current = base，
## 收起时 reset() 回 base），所以换上任何一把枪，它的当前散布都恰为自己的 base。
func reset_spread(slot: int, profile_index: int) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_spread_profile[slot] = profile_index
	player_spread_degrees[slot] = float(
		_effective_weapon_profile(slot, profile_index).get("base_spread_degrees", 0.0)
	)

func get_spread_degrees(slot: int) -> float:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0.0
	return player_spread_degrees[slot]

func _weapon_profile(profile_index: int) -> Dictionary:
	if profile_index < 0 or profile_index >= weapon_profiles.size():
		return {}
	return weapon_profiles[profile_index]

## 某个座位实际生效的武器档案 = 基础档案 + 该座位的改装层数。
##
## 所有读武器数值的地方都必须走这里，而不是 _weapon_profile()。三个读点分别是
## reset_spread（换枪把散布拉回 base）、_recover_spread（每 tick 回复散布）、
## _resolve_shot_event（开火解算）。漏掉任何一个的现象都不是崩溃，而是
## 「装了补偿器，开火时算改装后的散布、松手回复时按没装算」——各端一致地怪异，
## 帧哈希不会报，只有源码断言抓得住。
##
## 没有任何改装时 derive_profile 返回基础档案本身，因此这条路径在未捡到改装件时
## 与改造前逐位等价。
func _effective_weapon_profile(slot: int, profile_index: int) -> Dictionary:
	var base := _weapon_profile(profile_index)
	if base.is_empty() or slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return base
	return WeaponModMathScript.derive_profile(
		base, player_mod_level, slot * WeaponModTableScript.COUNT
	)

## 加改装层数**并把层数写回背包槽**。成功返回 true；已满或没空槽返回 false（调用方退款）。
##
## 背包面板读的是槽位，不是 player_mod_level。只调 grant_weapon_mod() 的话，改装
## 效果确实生效了，但背包里查无此物、再买一次显示的等级也不动——这正是拾取路径
## 在 _apply_reward_acceptance() 的 WEAPON_MOD 分支里额外写一次 _set_inventory_slot
## 的原因。商店必须和拾取写同一本账，否则两边各记各的。
func _grant_weapon_mod_with_ledger(slot: int, mod_id: int, stacks: int) -> bool:
	var profile_index := _find_mod_profile_index(mod_id)
	if profile_index < 0:
		return false
	var inventory_slot := _find_inventory_slot(slot, profile_index)
	if inventory_slot < 0:
		inventory_slot = _find_empty_inventory_slot(slot)
	if inventory_slot < 0:
		return false
	if grant_weapon_mod(slot, mod_id, stacks) <= 0:
		return false
	_set_inventory_slot(
		slot, inventory_slot, profile_index, get_weapon_mod_level(slot, mod_id)
	)
	return true

## 给某个座位追加改装层数，夹到该改装件的上限。返回实际生效的层数（0 = 已满）。
func grant_weapon_mod(slot: int, mod_id: int, stacks: int) -> int:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0
	if mod_id < 0 or mod_id >= WeaponModTableScript.COUNT or stacks <= 0:
		return 0
	var index := slot * WeaponModTableScript.COUNT + mod_id
	var current := int(player_mod_level[index])
	var limit := WeaponModTableScript.MAX_STACKS[mod_id]
	var next_level := mini(current + stacks, limit)
	player_mod_level[index] = next_level
	return next_level - current

func get_weapon_mod_level(slot: int, mod_id: int) -> int:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0
	if mod_id < 0 or mod_id >= WeaponModTableScript.COUNT:
		return 0
	return int(player_mod_level[slot * WeaponModTableScript.COUNT + mod_id])

## 装配期登记：某个奖励下标对应哪种改装件、给几层。表现层在注册奖励目录时调用。
## 登记某个地图奖励下标是「补血 N 点」。各端从同一份地图资源独立调用，
## 结果必然一致；实际回血在 _resolve_chest_claims 那一 tick 进模拟并进帧哈希。
func configure_reward_heal(reward_profile_index: int, amount: int) -> void:
	if reward_profile_index < 0:
		return
	while reward_heal_amount.size() <= reward_profile_index:
		reward_heal_amount.append(0)
	reward_heal_amount[reward_profile_index] = maxi(amount, 0)

func heal_amount_for_reward(reward_profile_index: int) -> int:
	if reward_profile_index < 0 or reward_profile_index >= reward_heal_amount.size():
		return 0
	return reward_heal_amount[reward_profile_index]

func configure_reward_mod(reward_profile_index: int, mod_id: int, stacks: int) -> void:
	if reward_profile_index < 0:
		return
	while reward_mod_id.size() <= reward_profile_index:
		reward_mod_id.append(-1)
		reward_mod_stacks.append(0)
	reward_mod_id[reward_profile_index] = mod_id
	reward_mod_stacks[reward_profile_index] = maxi(stacks, 0)

func reward_mod_for(reward_profile_index: int) -> int:
	if reward_profile_index < 0 or reward_profile_index >= reward_mod_id.size():
		return -1
	return reward_mod_id[reward_profile_index]

func _recover_spread() -> void:
	for slot in range(MAX_PLAYER_SLOTS):
		var profile := _effective_weapon_profile(slot, player_spread_profile[slot])
		if profile.is_empty():
			continue
		player_spread_degrees[slot] = WeaponSpreadStateScript.recovered_degrees(
			player_spread_degrees[slot],
			float(profile["base_spread_degrees"]),
			float(profile["spread_recovery_degrees_per_second"]),
			SimClockScript.TICK_SECONDS
		)

func _resolve_pending_events() -> void:
	if pending_events.is_empty():
		return
	var events := pending_events
	pending_events = []
	for event in events:
		var kind: StringName = event["kind"]
		if kind == &"shot":
			_resolve_shot_event(event)
		elif kind == &"melee":
			_resolve_melee_event(event)
		elif kind == &"explosion":
			_resolve_explosion_event(event)
		elif kind == &"barrel_removed":
			_resolve_barrel_removal_event(event)
		elif kind == &"spread_reset":
			reset_spread(int(event["slot"]), int(event["profile_index"]))
		elif kind == &"shop_purchase":
			_resolve_shop_purchase(event)

func _resolve_shot_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	var profile_index := int(event["profile_index"])
	var profile := _effective_weapon_profile(slot, profile_index)
	if profile.is_empty():
		return
	# 该槽位第一次用这个档案开火（或换装事件没排上队就直接开火）时，
	# 散布必须先落到这把武器自己的 base：基线的 WeaponSpreadState 构造即
	# current = base，第一发绝不可能是 0 度。
	if player_spread_profile[slot] != profile_index:
		reset_spread(slot, profile_index)
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()

	var spread_degrees := player_spread_degrees[slot]
	var pellet_count := maxi(int(profile["pellet_count"]), 1)
	# 伤害 = 武器档案 × 本命武器加成 × 属性成长（商店买的伤害升级）。
	var damage_scale := get_player_signature_scale(slot, profile_index) * get_upgrade_scale(slot, STAT_DAMAGE)
	# 暴击按「扣一次扳机」掷一次，不按弹丸掷（理由见 RangedWeaponDefinition
	# 的 crit_chance_percent）。掷点无条件执行，不因为这把枪暴击率是 0 就跳过：
	# WEAPON_CRIT 流的序列因此只取决于开了几枪，调武器数值不会移动它。
	var crit_roll := rng.next_uint32(DeterministicRngScript.Stream.WEAPON_CRIT) % 10000
	var critical := crit_roll < int(profile.get("crit_chance_per_10000", 0))
	for pellet_index in range(pellet_count):
		var pellet_direction := WeaponSpreadStateScript.spread_direction(
			aim,
			spread_degrees,
			_pellet_spread_offset(pellet_index, pellet_count)
		)
		_resolve_pellet(
			slot, profile, origin, origin_height, pellet_direction, damage_scale, critical
		)
	# 散布按「扣一次扳机」增长一次，不按弹丸数增长：
	# 否则一发霰弹就把散布顶到上限，第二枪起等于在盲射。
	# 「压制」被动在这里生效：削减每次扣扳机的散布增长，让持续开火更可控。
	# 放在增长处而不是改武器档案，因为档案是全局共享的，被动必须逐玩家生效。
	var relief := clampf(player_suppression_relief[slot], 0.0, 0.9) if slot < player_suppression_relief.size() else 0.0
	player_spread_degrees[slot] = WeaponSpreadStateScript.increased_degrees(
		spread_degrees,
		float(profile["spread_increase_degrees"]) * (1.0 - relief),
		float(profile["max_spread_degrees"])
	)
	# 背包里的弹药也按「扣一次扳机」扣一发，与 RangedWeapon.try_consume_ammo() 同口径
	# （霰弹一枪 = 一发，不按弹丸数扣）。
	_spend_inventory_ammo(slot, profile_index)

## 开火消耗背包里的弹药。
##
## 少了这一步，模拟层的弹药只增不减：弹匣一旦装满就永远是「满」，打空之后每一个
## 弹药箱都会被 _plan_finite_stack() 以 &"full" 拒绝——现象是「捡满、打光、
## 从此再也捡不到子弹」，而箱子还老老实实立在地上。
##
## 扣减放在模拟层而不是表现层，是因为背包槽位进帧哈希：开火事件本来就逐帧到达
## 各端，在这里扣，各端扣的是同一发。
func _spend_inventory_ammo(slot: int, weapon_profile_index: int) -> void:
	if weapon_profile_index < 0 or weapon_profile_index >= weapon_profile_ammo_ids.size():
		return
	var weapon_id := weapon_profile_ammo_ids[weapon_profile_index]
	if weapon_id.is_empty():
		return
	var ammo_profile_index := _find_ammo_profile_for_weapon(weapon_id)
	if ammo_profile_index < 0:
		return
	# 上限 0 = 无限弹武器（手枪）：它从来不占背包槽位，开火也不该凭空建一个。
	if int(_inventory_profile(ammo_profile_index).get("max_stack", 0)) <= 0:
		return
	var inventory_slot := _find_inventory_slot(slot, ammo_profile_index)
	if inventory_slot < 0:
		return
	_set_inventory_slot(
		slot,
		inventory_slot,
		ammo_profile_index,
		maxi(get_inventory_slot_amount(slot, inventory_slot) - 1, 0)
	)

## 一颗弹丸在散布锥内的归一化偏角（-1..1）。
##
## 单弹丸武器走原来的路径：整发取一次随机。rng 的调用序列必须与引入多弹丸之前
## 逐次一致，否则手枪与冲锋枪的每一发都会偏到别处，既有的帧哈希与回放全部分叉。
##
## 多弹丸把散布锥**均分**给每颗弹丸、每颗再在自己那一份里抖动，而不是每颗独立
## 取整锥随机：独立随机会让弹丸扎堆，还会时不时整簇挤到一侧，看起来像这一枪打偏了，
## 而不像一把霰弹枪。
func _pellet_spread_offset(pellet_index: int, pellet_count: int) -> float:
	if pellet_count <= 1:
		return rng.next_range(
			DeterministicRngScript.Stream.WEAPON_SPREAD, -1.0, 1.0
		)
	var slice := 2.0 / float(pellet_count)
	var slice_center := -1.0 + slice * (float(pellet_index) + 0.5)
	var jitter := rng.next_range(
		DeterministicRngScript.Stream.WEAPON_SPREAD,
		-slice * 0.5,
		slice * 0.5
	)
	return clampf(slice_center + jitter, -1.0, 1.0)

## 解算一颗弹丸：截断射程、按穿透逐个结算伤害、并抬出一条曳光事件。
## 多弹丸武器一次扣扳机会走这里 pellet_count 次，每颗各自命中、各自画线。
func _resolve_pellet(
	slot: int,
	profile: Dictionary,
	origin: Vector2,
	origin_height: float,
	direction: Vector2,
	damage_scale: float,
	critical: bool = false
) -> void:
	# 射程被第一堵墙截断：基线的物理射线命中层 1 静态体就 break，
	# 未命中僵尸时曳光终点也停在墙上而不是穿墙飞满射程。
	# 注：Step 8 的物理闸门按被禁 API 的字面名 grep 整个 scripts/sim 且不区分代码与注释，
	# 所以这里写「物理射线」而不是那几个类名/方法名。
	# 截断只看静态几何：油桶不占静态阻挡图，它在射线上的终止位置由
	# SimCombat.resolve_ray_hits() 用桶的解析圆给出（详见 ray_blocked_distance()）。
	var weapon_range := float(profile["attack_range"])
	var attack_range := minf(
		weapon_range, ray_blocked_distance(origin, direction, weapon_range)
	)
	var maximum_targets := int(profile["max_penetration_count"]) + 1
	var coefficient := float(profile["penetration_damage_coefficient"])
	var hits := SimCombatScript.resolve_ray_hits(
		self, origin, origin_height, direction, attack_range, maximum_targets
	)
	var end_position := origin + direction * attack_range
	var did_hit := false
	var killed := false
	var total_damage := 0.0
	var zone: StringName = &""
	var current_damage := float(profile["damage"]) * damage_scale
	var crit_multiplier_permille := int(profile.get("crit_multiplier_permille", 1000))
	for hit in hits:
		var index := int(hit["index"])
		var hit_zone: StringName = hit["zone"]
		# 油桶终止射线。基线 ranged_weapon.gd 的 _find_damage_target() 对油桶返回
		# null（油桶不在 damageable_targets 组里），于是走 _apply_damage() 把
		# **武器原始 damage**（不是穿透衰减后的 current_damage）递给 apply_hit()
		# 再 break——这里逐条复刻，包括不消耗穿透名额。
		if hit["kind"] == SimCombatScript.KIND_BARREL:
			var barrel_outcome := apply_barrel_hit(index)
			if barrel_outcome != BARREL_HIT_NONE:
				did_hit = true
				zone = hit_zone
				total_damage += float(profile["damage"])
				killed = killed or barrel_outcome == BARREL_HIT_EXPLODED
			end_position = hit["point"]
			break
		var multiplier := SimHitGeometryScript.damage_multiplier(hit_zone)
		var damage_points := roundi(current_damage * multiplier * float(HEALTH_SCALE))
		# 暴击是整数千分比放大，落在**穿透衰减之后的这一段**上：
		# 一颗暴击弹丸穿过去的每一个目标都吃暴击，衰减照旧逐层生效。
		if critical:
			damage_points = damage_points * crit_multiplier_permille / 1000
		var before_health := zombie_health[index]
		if apply_zombie_damage(
			index, damage_points, hit["point"], hit["height"], direction, hit_zone, critical
		):
			did_hit = true
			zone = hit_zone
			total_damage += float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
			killed = killed or zombie_state[index] == STATE_DEAD
		# 曳光终点始终落在最后一个被处理的命中点；穿透关闭时即第一个命中点。
		end_position = hit["point"]
		if coefficient <= 0.0:
			break
		current_damage *= coefficient
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": direction,
		"end": end_position,
		"end_height": origin_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": total_damage,
		"zone": zone,
		# 这一枪暴击了。表现层可以据此换曳光/枪声，判定本身留在模拟层。
		"critical": critical,
		# 射线被阻挡几何截断了：表现层据此播墙面弹着音。判定留在模拟层，
		# 因为「打没打到墙」只有这里知道——表现层再补一次射线，就等于在
		# 确定性解算之外又开了一条会分叉的判定路径。
		"hit_blocker": attack_range < weapon_range,
	})

func _resolve_melee_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()
	var index := SimCombatScript.resolve_melee_target(
		self,
		origin,
		origin_height,
		aim,
		float(event["reach"]),
		float(event["half_width"])
	)
	var did_hit := false
	var killed := false
	var damage_dealt := 0.0
	var end_position := origin + aim * float(event["reach"])
	var end_height := origin_height
	if index >= 0:
		var hit_height := SimHitGeometryScript.aim_point_height(
			get_zombie_height(index)
		)
		var before_health := zombie_health[index]
		var damage_points := roundi(float(event["damage"]) * float(HEALTH_SCALE))
		if apply_zombie_damage(
			index,
			damage_points,
			get_zombie_position(index),
			hit_height,
			aim,
			SimHitGeometryScript.ZONE_BODY
		):
			did_hit = true
			killed = zombie_state[index] == STATE_DEAD
			damage_dealt = float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
		end_position = get_zombie_position(index)
		end_height = hit_height
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": aim,
		"end": end_position,
		"end_height": end_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": damage_dealt,
		"zone": SimHitGeometryScript.ZONE_BODY if did_hit else &"",
	})

func _resolve_explosion_event(event: Dictionary) -> void:
	_apply_explosion_to_zombies(
		event["origin"],
		float(event["origin_height"]),
		float(event["radius"]),
		float(event["center_damage"]),
		float(event["edge_damage"])
	)
