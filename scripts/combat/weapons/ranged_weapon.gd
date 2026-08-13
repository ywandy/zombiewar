extends WeaponBase
class_name RangedWeapon

const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")
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
	if visual_anchor != null:
		top_level = true
		_sync_to_visual_anchor()

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
	_sync_muzzle_to_capsule()

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
	var ray_origin := _sync_muzzle_to_capsule()
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
## 确定性解算之外又开了一条会分叉的路径。
func show_tracer(
	from_position: Vector3,
	to_position: Vector3,
	hit_blocker: bool = false
) -> void:
	var tracer := _acquire_tracer()
	tracer.setup(from_position, to_position)
	if not hit_blocker or spatial_sfx_pool == null:
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

func _sync_muzzle_to_capsule() -> Vector3:
	var origin := get_ray_origin()
	muzzle.global_position = origin
	# 位置与朝向都以弹道胶囊（WeaponCollision）为准——那才是子弹真正飞出的轴，
	# 与曳光、命中严格同源。不能用外观模型节点的朝向：内嵌武器网格的局部 -Z
	# 指向握把（建模习惯），并非枪管前向，压平后只是噪声方向，会把火光带偏。
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
