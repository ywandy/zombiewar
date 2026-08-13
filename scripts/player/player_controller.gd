extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const PlayerScreenBoundsScript = preload(
	"res://scripts/camera/player_screen_bounds.gd"
)
const HitResult = preload("res://scripts/combat/hit_result.gd")
const Health = preload("res://scripts/combat/health.gd")
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const RangedWeaponDefinition = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)
const PlayerInputStateScript = preload("res://scripts/input/player_input_state.gd")
const CharacterVisualHostScript = preload(
	"res://scripts/player/character_visual_host.gd"
)
const DEATH_VOICE_SOUNDS := [
	preload("res://assets/sfx/boxhead/player_scream_1.mp3"),
	preload("res://assets/sfx/boxhead/player_scream_2.mp3"),
]

signal attack_resolved(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
)
signal health_changed(current: float, maximum: float)
signal damaged(amount: float)
signal died

@export_group("Survivability")
@export var player_index := 0
@export var max_health: float = BASE_MAX_HEALTH
@export var hit_reaction_duration := 0.24
@export var hit_attack_lock_duration := 1.2
@export var hit_knockback_speed := 8.0
@export var hit_knockback_deceleration := 18.0

@export_group("Movement Feel")
@export var move_speed: float = BASE_MOVE_SPEED
@export var ground_acceleration: float = 30.0
@export var ground_deceleration: float = 42.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export_range(0.0, 0.25, 0.01) var screen_safe_margin_ratio := 0.08

@export_group("Weapon Feel")
@export var visual_recoil_recovery := 1.2

@onready var visual_root: Node3D = $VisualRoot
@onready var accent_ring: MeshInstance3D = $AccentRing
@onready var equipment: EquipmentController = $EquipmentController
@onready var functional_ray_origin: Marker3D = $FunctionalRayOrigin
@onready var weapon_clearance: WeaponClearanceController = $WeaponClearanceController
@onready var health_bar: HealthBar3D = get_node_or_null("HealthBar3D") as HealthBar3D
@onready var equipment_label = get_node_or_null(
	"PlayerEquipmentLabel"
)
@onready var death_voice_audio: AudioStreamPlayer3D = $DeathVoiceAudio
@onready var fall_audio: AudioStreamPlayer3D = $FallAudio

var movement_camera: Camera3D
var screen_camera: Camera3D
var world_bounds_anchor: Node3D
var animation_player: AnimationPlayer
var aim_direction := Vector3.FORWARD
var visual_rest_position := Vector3.ZERO
var visual_recoil_offset := 0.0
## 角色三围的基准值。spawner 的 apply_character_definition 从这里起算，
## 避免与 @export 默认值双写漂移。
const BASE_MAX_HEALTH := 100.0
const BASE_MOVE_SPEED := 5.0
var health: Health
var defeated := false
var hit_reaction_remaining := 0.0
var hit_attack_lock_remaining := 0.0
var knockback_velocity := Vector3.ZERO
var attack_animation_remaining := 0.0
var health_bar_initialized := false
var missing_health_bar_warned := false
var input_source
var last_input_state = PlayerInputStateScript.new()
var place_item_service
var sim_request_sink := Callable()
## 联机远端玩家的权威位置（Vector3 或 null）。
## 非空时本机不再让这具身体自己走：它的位置由帧里的量化坐标决定，
## 而输入仍然照常喂给装备与动画。位置若也交给 move_and_slide() 复算，
## 各端会各算各的，而僵尸追的是帧里那一份，于是「他明明躲开了却还是被咬」。
var network_position_target = null

func set_network_position_target(target) -> void:
	network_position_target = target

func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value
	if equipment != null:
		equipment.set_sim_request_sink(sim_request_sink)

## 当前角色定义（spawner 注入）。被动与伤害缩放在表现层读它。
var character_definition: CharacterDefinition = null
## 商店买来的运行时被动（覆盖角色自带）。被动读取处优先它。
## 不能直接改 character_definition（共享 Resource），所以单独存一份。
var runtime_passive_id: StringName = &""

## 商店购买被动时调用。
func set_runtime_passive(passive_id: StringName) -> void:
	runtime_passive_id = passive_id

## 当前生效的被动：优先商店买的 runtime，否则角色自带。
func effective_passive_id() -> StringName:
	if runtime_passive_id != &"":
		return runtime_passive_id
	if character_definition != null:
		return character_definition.passive_id
	return &""

## 当前生效的被动强度：runtime 被动用商店定义强度，角色自带用角色定义强度。
func effective_passive_strength() -> float:
	if runtime_passive_id != &"":
		return 1.0
	if character_definition != null:
		return character_definition.passive_strength
	return 1.0

## 应用角色三围与配色。必须在 set_input_source / 首次同步血条之前调用。
##
## 时序：spawner 在 add_child（触发 _ready）之前调用本方法，此时 health 仍为
## null——这里只更新 max_health / move_speed，真正的 Health 实例交给 _ready 的
## _ensure_health_initialized() 用新上限创建。若在运行时替换角色（health 已建），
## 则重建 Health 并重连信号，保证血条与死亡回调不丢。
func apply_character_definition(def: CharacterDefinition) -> void:
	if def == null or def.model_scene == null:
		push_error("PlayerController requires a character definition with model_scene")
		return
	character_definition = def
	max_health = maxf(1.0, BASE_MAX_HEALTH + def.max_health_bonus)
	move_speed = BASE_MOVE_SPEED * def.move_speed_mult
	if health != null:
		health.changed.disconnect(_on_health_changed)
		health.depleted.disconnect(_on_depleted)
		health = Health.new(max_health)
		health.changed.connect(_on_health_changed)
		health.depleted.connect(_on_depleted)
		health_changed.emit(health.current, health.maximum)
		_sync_health_bar(false)
	set_accent_color(def.accent_color)

func _ready() -> void:
	if character_definition == null or character_definition.model_scene == null:
		push_error("PlayerController initialization stopped: character model is missing")
		return
	var visual_host := visual_root as CharacterVisualHostScript
	if visual_host != null:
		visual_host.install(
			character_definition.model_scene if character_definition != null else null
		)
	_ensure_health_initialized()
	_sync_health_bar(false)
	health_bar_initialized = true
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	visual_rest_position = visual_root.position
	weapon_clearance.setup(self)
	equipment.attack_started.connect(_on_weapon_attack_started)
	equipment.attack_resolved.connect(_on_weapon_attack_resolved)
	equipment.weapon_changed.connect(_on_weapon_changed)
	equipment.equipment_changed.connect(_on_equipment_changed)
	equipment.setup(
		self,
		visual_root,
		functional_ray_origin,
		Callable(weapon_clearance, "try_bind_weapon")
	)
	equipment.set_place_item_service(place_item_service)
	equipment.set_sim_request_sink(sim_request_sink)
	_on_equipment_changed(
		equipment.get_current_display_name(),
		equipment.get_current_count_text()
	)
	# 先建一份材质：spawner 随后会用角色配色覆盖它。没有 spawner 的场合
	# （编辑器里单独跑 Player.tscn）也不该是一圈没有材质的白环。
	set_accent_color(Color.WHITE)

## 角色配色。四个人共用同一个模型，脚下这圈光环是场上唯一分得清谁是谁的东西。
##
## 材质在这里 new 出来而不是写进 Player.tscn：写进场景的话四个玩家实例
## 共用同一份 StandardMaterial3D，给第四个人上色会把前三个一起改掉。
func set_accent_color(color: Color) -> void:
	if accent_ring == null:
		return
	var material := accent_ring.material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		accent_ring.material_override = material
	material.albedo_color = color
	if equipment_label != null and equipment_label.has_method("set_accent_color"):
		equipment_label.set_accent_color(color)

func _process(delta: float) -> void:
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
	hit_attack_lock_remaining = maxf(hit_attack_lock_remaining - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	visual_recoil_offset = move_toward(
		visual_recoil_offset,
		0.0,
		visual_recoil_recovery * delta
	)
	visual_root.position = visual_rest_position + Vector3(0.0, 0.0, visual_recoil_offset)

func set_movement_camera(camera: Camera3D) -> void:
	movement_camera = camera

func set_screen_camera(camera: Camera3D) -> void:
	screen_camera = camera

func set_world_bounds_anchor(anchor: Node3D) -> void:
	world_bounds_anchor = anchor

## 只有联机模式才用世界坐标矩形；单人与本地多人保持现有屏幕安全区行为。
func uses_world_bounds() -> bool:
	if world_bounds_anchor == null or not is_instance_valid(world_bounds_anchor):
		return false
	var session := get_node_or_null("/root/GameSession")
	return (
		session != null and
		session.mode == GameSessionState.Mode.ONLINE_MULTIPLAYER
	)

func set_input_source(value) -> void:
	input_source = value
	if input_source != null:
		input_source.reset_edges()

func get_input_source():
	return input_source

func get_last_input_state():
	return last_input_state

func is_input_online() -> bool:
	return input_source != null and input_source.is_online()

func set_place_item_service(service) -> void:
	place_item_service = service
	if equipment != null:
		equipment.set_place_item_service(place_item_service)

func receive_equipment_pickup(
	item_id: StringName,
	amount: int,
	auto_equip: bool = false
) -> bool:
	if defeated:
		return false
	return equipment.grant_item(item_id, amount, auto_equip)

func receive_ammo_pickup(item_id: StringName, amount: int) -> bool:
	if defeated:
		return false
	return equipment.add_ammo(item_id, amount) > 0

## ---- 模拟层背包镜像 ----
## 单向：模拟层 → 装备节点。玩家侧不往回写，见 EquipmentController 的说明。
func bind_inventory_profiles(profiles: Array[Dictionary]) -> void:
	equipment.bind_inventory_profiles(profiles)

func apply_inventory_snapshot(
	slot_profiles: PackedInt32Array,
	slot_amounts: PackedInt32Array
) -> void:
	equipment.apply_inventory_snapshot(slot_profiles, slot_amounts)

func starting_inventory_entries() -> Array[Dictionary]:
	return equipment.starting_inventory_entries()

func _physics_process(delta: float) -> void:
	last_input_state = (
		input_source.sample() if input_source != null else PlayerInputStateScript.new()
	)
	if defeated:
		_update_defeated_motion(delta)
		return
	var knockback_active := knockback_velocity.length_squared() > 0.000001
	var input_vector: Vector2 = (
		Vector2.ZERO if knockback_active else last_input_state.move_vector
	)
	var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
	var move_direction := PlayerMotion.world_direction(input_vector, camera_basis)

	aim_direction = PlayerMotion.next_aim_direction(
		move_direction,
		aim_direction
	)
	var target_yaw := PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
	if last_input_state.previous_equipment_just_pressed:
		equipment.equip_previous()
	elif last_input_state.next_equipment_just_pressed:
		equipment.equip_next()

	var acceleration := ground_acceleration if is_on_floor() else air_acceleration
	var deceleration := ground_deceleration if is_on_floor() else air_acceleration
	var planar_velocity := knockback_velocity
	if not knockback_active:
		planar_velocity = PlayerMotion.next_planar_velocity(
			velocity,
			move_direction,
			move_speed,
			acceleration,
			deceleration,
			delta
		)
	velocity.x = planar_velocity.x
	velocity.z = planar_velocity.z
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		delta,
		gravity
	)
	var desired_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if _bounds_are_active():
		desired_motion = _limit_desired_motion(desired_motion)
		if delta > 0.000001:
			velocity.x = desired_motion.x / delta
			velocity.z = desired_motion.z / delta
			if knockback_active:
				knockback_velocity.x = velocity.x
				knockback_velocity.z = velocity.z
	weapon_clearance.update_clearance(
		delta,
		desired_motion,
		target_yaw
	)
	rotation.y = target_yaw
	var trigger_pressed: bool = last_input_state.use_pressed
	var trigger_just_pressed: bool = last_input_state.use_just_pressed
	var attack_locked := (
		hit_reaction_remaining > 0.0 or
		hit_attack_lock_remaining > 0.0
	)
	if attack_locked:
		trigger_pressed = false
		trigger_just_pressed = false
		equipment.cancel_use()
	var attack_direction := aim_direction
	if equipment.get_current_definition() is RangedWeaponDefinition:
		attack_direction = _actual_ranged_attack_direction()
	equipment.set_use_input(trigger_pressed, trigger_just_pressed, attack_direction)
	if network_position_target != null:
		_follow_network_position(delta)
		return
	move_and_slide()
	if knockback_active:
		knockback_velocity = PlayerMotion.next_knockback_velocity(
			Vector3(velocity.x, 0.0, velocity.z),
			hit_knockback_deceleration,
			delta
		)
		velocity.x = knockback_velocity.x
		velocity.z = knockback_velocity.z
	_update_animation(Vector2(velocity.x, velocity.z).length())

## 远端玩家的位移：向权威位置收敛，而不是自己走。
## 用平滑收敛而不是直接赋值，是因为帧以 20Hz 到达而渲染是 60Hz，
## 直接赋值会让远端角色以每秒 20 次的频率瞬移。
## 收敛速度按剩余距离给，差得越远追得越快；差到离谱（切后台回来、刚重连）
## 就直接瞬移，慢慢挪过去只会让这具身体在半路上被僵尸围殴一路。
const NETWORK_POSITION_SNAP_DISTANCE := 3.0
const NETWORK_POSITION_FOLLOW_RATE := 14.0

func _follow_network_position(delta: float) -> void:
	var target: Vector3 = network_position_target
	var previous := global_position
	var offset := target - previous
	offset.y = 0.0
	if offset.length() > NETWORK_POSITION_SNAP_DISTANCE:
		global_position = Vector3(target.x, previous.y, target.z)
	else:
		var weight := clampf(NETWORK_POSITION_FOLLOW_RATE * delta, 0.0, 1.0)
		global_position = Vector3(
			lerpf(previous.x, target.x, weight),
			previous.y,
			lerpf(previous.z, target.z, weight)
		)
	# 动画要的是「看上去走多快」，所以速度取实际位移而不是输入意图：
	# 远端玩家撞墙停下时输入仍然是满的，按输入播就会原地跑步。
	var travelled := global_position - previous
	velocity.x = travelled.x / delta if delta > 0.000001 else 0.0
	velocity.z = travelled.z / delta if delta > 0.000001 else 0.0
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _bounds_are_active() -> bool:
	if uses_world_bounds():
		return true
	return screen_camera != null and is_input_online()

func _limit_desired_motion(desired_motion: Vector3) -> Vector3:
	if uses_world_bounds():
		return PlayerScreenBoundsScript.limit_motion_in_world_rect(
			world_bounds_anchor.global_position,
			global_position,
			desired_motion,
			PlayerScreenBoundsScript.ONLINE_BOUNDS_HALF_WIDTH,
			PlayerScreenBoundsScript.ONLINE_BOUNDS_HALF_DEPTH
		)
	return PlayerScreenBoundsScript.limit_motion(
		screen_camera,
		global_position,
		desired_motion,
		screen_safe_margin_ratio
	)

func _actual_ranged_attack_direction() -> Vector3:
	return WeaponMath.flat_direction(-global_basis.z)

func _update_animation(horizontal_speed: float) -> void:
	if animation_player == null or defeated:
		return
	if hit_reaction_remaining > 0.0:
		return
	if attack_animation_remaining > 0.0:
		return
	var animation_name := equipment.get_idle_animation()
	if not is_on_floor():
		animation_name = &"Jump_Idle"
	elif horizontal_speed > 0.2:
		animation_name = equipment.get_run_animation()
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.15)

func _on_weapon_attack_started(
	animation_name: StringName,
	lock_duration: float
) -> void:
	if (
		defeated or
		hit_reaction_remaining > 0.0 or
		hit_attack_lock_remaining > 0.0
	):
		equipment.cancel_attack()
		attack_animation_remaining = 0.0
		return
	attack_animation_remaining = maxf(lock_duration, 0.0)
	if (
		animation_player != null and
		not animation_name.is_empty() and
		animation_player.has_animation(animation_name)
	):
		animation_player.play(animation_name, 0.05)

func _on_weapon_attack_resolved(
	_origin: Vector3,
	direction: Vector3,
	result: HitResult,
	recoil_kick: float,
	camera_impulse_strength: float
) -> void:
	visual_recoil_offset = minf(
		visual_recoil_offset + maxf(recoil_kick, 0.0),
		0.12
	)
	attack_resolved.emit(direction, result, camera_impulse_strength)

func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	attack_animation_remaining = 0.0
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _on_equipment_changed(display_name: String, count_text: String) -> void:
	if equipment_label != null:
		var class_prefix := ""
		if character_definition != null and String(character_definition.display_name) != "":
			class_prefix = "[%s] " % character_definition.display_name
		equipment_label.set_status(player_index, class_prefix + display_name, count_text)

## 由竞技场在模拟层判定改装件归属之后推过来。
## 玩家自己不持有改装状态——它住在 SimWorld 里、逐 tick 进帧哈希，
## 表现层只负责显示，读一份缓存反而会给"两边显示不一致"留口子。
func set_weapon_mod_summary(summary: String) -> void:
	if equipment_label != null:
		equipment_label.set_mod_summary(summary)

func apply_damage(amount: float, source_position := Vector3.ZERO) -> float:
	_ensure_health_initialized()
	if defeated:
		return 0.0
	var effective := amount
	# 防爆甲：减伤比例（0.3 = 减 30%）。优先商店买的 runtime 被动，否则角色自带。
	if effective_passive_id() == &"blast_armor":
		effective *= (1.0 - clampf(effective_passive_strength(), 0.0, 0.9))
	var applied := health.apply_damage(effective)
	if applied <= 0.0:
		return 0.0
	equipment.cancel_attack()
	attack_animation_remaining = 0.0
	damaged.emit(applied)
	if not defeated:
		hit_reaction_remaining = maxf(hit_reaction_duration, 0.0)
		hit_attack_lock_remaining = maxf(hit_attack_lock_duration, 0.0)
		var facing_direction := -global_basis.z
		var knockback_scale := 1.0
		if effective_passive_id() == &"blast_armor":
			knockback_scale = 0.5
		knockback_velocity = PlayerMotion.knockback_direction(
			global_position,
			source_position,
			facing_direction
		) * maxf(hit_knockback_speed, 0.0) * knockback_scale
		if animation_player != null and animation_player.has_animation(&"HitReact"):
			animation_player.play(&"HitReact", 0.05)
	return applied

func is_alive() -> bool:
	return not defeated

## 医疗光环回血入口。只改血量（表现层），不触发击退/受击反馈。
func heal(amount: float) -> void:
	_ensure_health_initialized()
	if defeated:
		return
	var applied := health.heal(amount)
	if applied > 0.0:
		health_changed.emit(health.current, health.maximum)

func _ensure_health_initialized() -> void:
	if health != null:
		return
	health = Health.new(max_health)
	health.changed.connect(_on_health_changed)
	health.depleted.connect(_on_depleted)
	health_changed.emit(health.current, health.maximum)

func _update_defeated_motion(delta: float) -> void:
	equipment.set_use_input(false, false, aim_direction)
	velocity.x = move_toward(velocity.x, 0.0, ground_deceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, ground_deceleration * delta)
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		delta,
		gravity
	)
	move_and_slide()

func _on_health_changed(current: float, maximum: float) -> void:
	health_changed.emit(current, maximum)
	_sync_health_bar(health_bar_initialized)

func _sync_health_bar(animate: bool) -> void:
	if health_bar == null:
		if not missing_health_bar_warned:
			push_warning("Player is missing HealthBar3D")
			missing_health_bar_warned = true
		return
	if health != null:
		health_bar.set_health(health.current, health.maximum, animate)

func _on_depleted() -> void:
	equipment.cancel_attack()
	weapon_clearance.reset()
	attack_animation_remaining = 0.0
	defeated = true
	hit_reaction_remaining = 0.0
	hit_attack_lock_remaining = 0.0
	knockback_velocity = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	if death_voice_audio != null:
		death_voice_audio.stream = DEATH_VOICE_SOUNDS.pick_random()
		death_voice_audio.play()
	if fall_audio != null:
		fall_audio.play()
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
	if equipment_label != null:
		equipment_label.set_status(player_index, "倒地", "")
	died.emit()
