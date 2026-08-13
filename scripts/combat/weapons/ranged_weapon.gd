extends WeaponBase
class_name RangedWeapon

const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const WALL_IMPACT_SPARK_SCENE := preload("res://scenes/fx/WallImpactSpark.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")
const VISUAL_MUZZLE_SOCKET_NAME := "MuzzleSocket"
const WALL_IMPACT_SOUNDS := [
	preload("res://assets/sfx/boxhead/bullet_wall_1.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_2.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_3.mp3"),
]

@onready var muzzle: Marker3D = $Muzzle
@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var weapon_trigger: WeaponTrigger
var tracer_pool: Array[ShotTracer] = []
var tracer_pool_cursor := 0
var wall_spark_pool: Array[WallImpactSpark] = []
var wall_spark_pool_cursor := 0
var current_ammo := 0
## 模拟层账本里这把枪的弹药数。current_ammo 是它减去本地预扣后的显示值，
## 不是独立的第二本账。
var authoritative_ammo := 0
## 已经在本地打出去、但模拟层还没兑现的发数。
##
## 单机也需要它：武器的 _physics_process 可能排在竞技场之后，那一枪要等下一个
## tick 才解算；联机更是要等一个 RTT。没有预扣，扳机按下去到数字变化之间会空一拍，
## 自动武器上就是数字来回跳。
var predicted_spend := 0
var predicted_spend_frames := 0
## 预扣的兜底寿命（物理帧）。模拟层因任何原因没兑现这一枪（例如服务端把这一
## tick 超出 8 条的事件丢了），预扣必须自己过期，否则显示值会永远比账本少几发。
const PREDICTION_TTL_FRAMES := 120
var spatial_sfx_pool: SpatialSfxPool
var visual_muzzle_socket: Node3D
## 音高与选音是纯表现，不进模拟层：散布已经由 Stream.WEAPON_SPREAD
## 在各端确定性地算过了，这里再摇一次骰子不影响任何判定。
var audio_rng := RandomNumberGenerator.new()

func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	audio_rng.randomize()
	spatial_sfx_pool = SpatialSfxPool.find_for(self)
	_prewarm_tracers()
	_prewarm_wall_sparks()

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	super.bind_context(
		value_wielder,
		value_visual_root,
		value_functional_ray_origin
	)
	visual_muzzle_socket = null
	if visual_anchor != null:
		visual_muzzle_socket = visual_anchor.find_child(
			VISUAL_MUZZLE_SOCKET_NAME,
			true,
			false
		) as Node3D
		if visual_muzzle_socket == null:
			push_warning(
				"Weapon %s visual model has no %s" % [
					String(definition.weapon_id),
					VISUAL_MUZZLE_SOCKET_NAME,
				]
			)
		top_level = true
		_sync_to_visual_anchor()
		_sync_muzzle_to_weapon_front()

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	_expire_prediction()
	if (
		has_ammo_for_shot() and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed) and
		try_consume_ammo()
	):
		_fire(aim_direction)
	trigger_just_pressed = false

## 模拟层账本刷下来的权威弹药数。显示值 = 账本 − 还没兑现的本地预扣。
func apply_authoritative_ammo(value: int) -> void:
	if not _uses_ammo():
		return
	var next_value := maxi(value, 0)
	# 账本掉了几发，就说明我们预扣的那几发已经被兑现，抵掉等量的预扣，
	# 否则同一枪会被扣两次、显示值一路比账本少。
	# 账本上涨（捡到/买到弹药）不是我们预测的事，预扣照旧生效。
	if next_value < authoritative_ammo:
		predicted_spend = maxi(
			predicted_spend - (authoritative_ammo - next_value), 0
		)
	authoritative_ammo = next_value
	if predicted_spend <= 0:
		predicted_spend_frames = 0
	set_ammo_count(maxi(authoritative_ammo - predicted_spend, 0))

func _expire_prediction() -> void:
	if predicted_spend <= 0:
		return
	predicted_spend_frames -= 1
	if predicted_spend_frames > 0:
		return
	predicted_spend = 0
	set_ammo_count(authoritative_ammo)

func set_ammo_count(amount: int) -> void:
	var next_ammo := clampi(amount, 0, get_max_ammo()) if _uses_ammo() else 0
	if next_ammo == current_ammo:
		return
	current_ammo = next_ammo
	count_changed.emit(current_ammo)

func add_ammo(amount: int) -> int:
	if not _uses_ammo() or amount <= 0:
		return 0
	var before := current_ammo
	set_ammo_count(current_ammo + amount)
	return current_ammo - before

func receive_pickup(amount: int) -> bool:
	var ownership_changed := set_owned(true)
	var added_ammo := add_ammo(amount)
	return ownership_changed or added_ammo > 0

func get_ammo_count() -> int:
	return current_ammo

func get_max_ammo() -> int:
	var ranged_definition := definition as RangedWeaponDefinition
	return maxi(ranged_definition.max_ammo, 0) if ranged_definition != null else 0

func get_remaining_count() -> int:
	return current_ammo if _uses_ammo() else -1

func get_count_text() -> String:
	return str(get_ammo_count()) if _uses_ammo() else "∞"

func has_ammo_for_shot() -> bool:
	return not _uses_ammo() or current_ammo > 0

func try_consume_ammo() -> bool:
	if not _uses_ammo():
		return true
	if current_ammo <= 0:
		return false
	# 本地先扣，等模拟层解算完这一枪再由 apply_authoritative_ammo() 抵掉。
	predicted_spend += 1
	predicted_spend_frames = PREDICTION_TTL_FRAMES
	set_ammo_count(current_ammo - 1)
	return true

func _uses_ammo() -> bool:
	var ranged_definition := definition as RangedWeaponDefinition
	return ranged_definition != null and ranged_definition.uses_ammo

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	# 在「换上」时发，不在「换下」时发：基线里每把枪各自持有一个 WeaponSpreadState，
	# 收起时 reset() 回自己的 base，因此换上的那把枪当前散布恒为它自己的 base。
	# 模拟层每个槽位只有一份散布状态，只有携带新武器的 weapon_id 才能重置到正确的 base。
	# EquipmentController.equip_slot() 先 old.set_equipped(false) 再 new.set_equipped(true)，
	# 顺序天然正确。
	if value:
		var ranged_definition := definition as RangedWeaponDefinition
		emit_sim_request({
			"kind": &"spread_reset",
			"weapon_id": ranged_definition.weapon_id,
		})
		return
	# 收起时清掉预扣：_expire_prediction() 挂在 _physics_process 上，而收起的武器
	# 不跑 _physics_process，留着的预扣会在下次换回来时压低显示值。
	if predicted_spend > 0:
		predicted_spend = 0
		predicted_spend_frames = 0
		set_ammo_count(authoritative_ammo)

func _process(_delta: float) -> void:
	_sync_to_visual_anchor()
	_sync_muzzle_to_weapon_front()

func cancel_attack() -> void:
	super.cancel_attack()
	if weapon_trigger != null:
		weapon_trigger.reset()

func get_ray_origin() -> Vector3:
	var fallback := global_position
	if functional_ray_origin != null and is_instance_valid(functional_ray_origin):
		fallback = functional_ray_origin.global_position
	elif wielder != null:
		fallback = wielder.global_position
	if wielder != null:
		var clearance := wielder.get_node_or_null(
			"WeaponClearanceController"
		) as WeaponClearanceController
		if clearance != null:
			return clearance.get_weapon_muzzle_origin(fallback)
	return fallback

func _fire(shot_direction: Vector3) -> void:
	_sync_to_visual_anchor()
	var ranged_definition := definition as RangedWeaponDefinition
	var ray_origin := get_ray_origin()
	_sync_muzzle_to_weapon_front()
	var aim := WeaponMath.flat_direction(shot_direction)
	# 开火事件只携带玩家的瞄准方向，不携带散布后的方向：
	# 散布由各客户端在 Stream.WEAPON_SPREAD 上各自确定性地算出。
	emit_sim_request({
		"kind": &"shot",
		"weapon_id": ranged_definition.weapon_id,
		"origin": ray_origin,
		"aim_direction": aim,
	})
	# 枪口火焰与射击音高是纯表现，立即播放；曳光的终点要等模拟层解算。
	muzzle_flash.flash()
	shot_audio.pitch_scale = audio_rng.randf_range(0.97, 1.03)
	shot_audio.play()
	attack_resolved.emit(
		ray_origin,
		aim,
		HitResult.miss(ray_origin),
		ranged_definition.visual_recoil_kick,
		ranged_definition.camera_impulse_strength
	)

## 由竞技场在模拟层解算出本次射击的终点后调用。
##
## 墙面弹着音也在这里播，而不是在 _fire() 里：开火那一刻本机还不知道子弹
## 会停在哪——那是模拟层的判定。表现层再补一次射线来自己判断，就等于在
## 确定性解算之外又开了一条会分叉的路径。模拟层提供命中终点；可见枪线的
## 起点重新读取独立武器的实时 MuzzleSocket，避免从功能胶囊旁边冒出来。
func show_tracer(
	from_position: Vector3,
	to_position: Vector3,
	hit_blocker: bool = false
) -> void:
	_sync_to_visual_anchor()
	var visual_from := from_position
	if visual_muzzle_socket != null and is_instance_valid(visual_muzzle_socket):
		visual_from = _sync_muzzle_to_weapon_front()
	var tracer := _acquire_tracer()
	tracer.setup(visual_from, to_position)
	if not hit_blocker:
		return
	# 打中墙的完整反馈：火花 + 弹着音，同一个判定、同一处代码。
	# 火花朝弹道反面喷，方向取 from_position->to_position 而**不是**
	# visual_from->to_position：前者是模拟层射线本身，后者是独立武器模型的
	# 枪口插槽，只用来画可见枪线。火花贴在命中点上，朝向必须跟真正的弹道
	# 一致，否则枪口插槽偏出去多少，墙上的火花就歪多少。
	# 表现层不另外求一次方向。
	var travel := to_position - from_position
	if travel.length_squared() > 0.000001:
		_acquire_wall_spark().setup(to_position, travel.normalized())
	if spatial_sfx_pool == null:
		return
	spatial_sfx_pool.play_at(
		WALL_IMPACT_SOUNDS[audio_rng.randi_range(0, WALL_IMPACT_SOUNDS.size() - 1)],
		to_position,
		-7.0,
		audio_rng.randf_range(0.96, 1.04),
		24.0
	)

func _sync_to_visual_anchor() -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform

func _sync_muzzle_to_weapon_front() -> Vector3:
	var origin := get_ray_origin()
	if visual_muzzle_socket != null and is_instance_valid(visual_muzzle_socket):
		origin = visual_muzzle_socket.global_position
	muzzle.global_position = origin
	# 火光位置属于表现层，必须跟随独立武器模型的真实前端；朝向仍以
	# 功能弹道轴为准，避免 glTF 网格的局部建模轴影响水平射击表现。
	muzzle.global_basis = Basis.looking_at(_get_barrel_direction(), Vector3.UP)
	return origin

## 枪管前向 = 弹道胶囊轴线。收枪/举枪时胶囊绕 X 俯仰（见
## WeaponClearanceController），与曳光同源，跟模拟层水平弹道一致。
func _get_barrel_direction() -> Vector3:
	if wielder != null:
		var clearance := wielder.get_node_or_null(
			"WeaponClearanceController"
		) as WeaponClearanceController
		if clearance != null and clearance.weapon_collision != null:
			return -clearance.weapon_collision.global_basis.y.normalized()
	return WeaponMath.flat_direction(-global_basis.z)

func _prewarm_tracers() -> void:
	if not tracer_pool.is_empty():
		return
	var ranged_definition := definition as RangedWeaponDefinition
	for tracer_index in range(maxi(ranged_definition.tracer_pool_size, 1)):
		var tracer := TRACER_SCENE.instantiate() as ShotTracer
		tracer.top_level = true
		add_child(tracer)
		tracer.deactivate()
		tracer_pool.append(tracer)

func _acquire_tracer() -> ShotTracer:
	if tracer_pool.is_empty():
		_prewarm_tracers()
	var tracer := tracer_pool[tracer_pool_cursor]
	tracer_pool_cursor = (tracer_pool_cursor + 1) % tracer_pool.size()
	return tracer

## 火花池比曳光池小：每一枪都有曳光，但只有打中墙的那些才有火花。
## 下限 4 是给霰弹枪那种「一次扣扳机多颗弹丸同时打墙」留的余量。
func _prewarm_wall_sparks() -> void:
	if not wall_spark_pool.is_empty():
		return
	var ranged_definition := definition as RangedWeaponDefinition
	var pool_size := maxi(ranged_definition.tracer_pool_size / 2, 4)
	for spark_index in range(pool_size):
		var spark := WALL_IMPACT_SPARK_SCENE.instantiate() as WallImpactSpark
		# top_level：火花留在命中点，不跟着枪走。漏了这一行，
		# 火花会挂在枪口上跟着玩家平移，看起来像枪在漏火星。
		spark.top_level = true
		add_child(spark)
		spark.set_pooled(true)
		wall_spark_pool.append(spark)

func _acquire_wall_spark() -> WallImpactSpark:
	if wall_spark_pool.is_empty():
		_prewarm_wall_sparks()
	var spark := wall_spark_pool[wall_spark_pool_cursor]
	wall_spark_pool_cursor = (wall_spark_pool_cursor + 1) % wall_spark_pool.size()
	return spark
