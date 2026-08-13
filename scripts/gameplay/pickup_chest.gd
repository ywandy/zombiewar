extends StaticBody3D
class_name PickupChest

const PickupDefinition = preload("res://scripts/gameplay/pickup_definition.gd")
const PICKUP_SOUND := preload("res://assets/sfx/boxhead/pickup.mp3")
## 改装件用另一个更"有获得感"的音，与普通补给区分开。
const MOD_PICKUP_SOUND := preload("res://assets/sfx/kenney_interface/confirmation_002.ogg")

@export var definition: PickupDefinition

@onready var claim_area: Area3D = $ClaimArea
@onready var marker_ring: MeshInstance3D = $MarkerRing
@onready var marker_beacon: MeshInstance3D = $MarkerBeacon
@onready var reward_label: Label3D = $RewardLabel
@onready var visual_root: Node3D = $Visual

var custom_visual: Node3D

var claim_locked := false
var spatial_sfx_pool: SpatialSfxPool
var reward_amount := -1
## 模拟层实体 id。0 表示还没注册（例如大厅预览里的箱子）。
var sim_chest_id := 0

func _ready() -> void:
	spatial_sfx_pool = SpatialSfxPool.find_for(self)
	# ClaimArea 不再驱动领取，只留着做碰撞外形；监听一律关掉。
	# 领取判定在 SimWorld._resolve_chest_claims() 里：物理重叠发生在表现层，
	# 而表现层各端的玩家位置本来就不一致（本机跑在前、远端是插值追上来的），
	# 用它来决定「谁拿到了这个箱子」必然分叉。
	claim_area.monitoring = false
	_apply_reward_visuals()

func configure(value: PickupDefinition, amount_override: int = -1) -> void:
	definition = value
	reward_amount = amount_override
	if is_node_ready():
		_apply_reward_visuals()

func bind_sim_chest(chest_id_value: int) -> void:
	sim_chest_id = chest_id_value

func get_sim_chest_id() -> int:
	return sim_chest_id

## 由竞技场在模拟层判定领取之后调用——「谁碰到了」和「拿到了什么」都已经判完，
## 这里只负责演出。
##
## **不在这里发货**：奖励已经由 SimWorld.accept_reward() 记进背包账本，竞技场随后
## 刷一次镜像就把它落到装备节点上。表现层再补发一次，就等于在账本之外又加了一笔，
## 正是「捡满弹药后再也捡不到子弹」那个 bug 的同一个病根。
##
## 箱子在兑现失败（弹药已满）时**不会**走到这里：模拟层拒绝时箱子保持 active。
func claim_by(_player: PlayerController) -> void:
	if claim_locked:
		return
	claim_locked = true
	if spatial_sfx_pool != null:
		spatial_sfx_pool.play_at(PICKUP_SOUND, global_position, -5.0, 1.0, 24.0)
	queue_free()

func _apply_reward_visuals() -> void:
	var color: Color = definition.marker_color if definition != null else Color.WHITE
	for mesh_instance in [marker_ring, marker_beacon]:
		var material := mesh_instance.get_active_material(0) as StandardMaterial3D
		if material == null:
			continue
		material = material.duplicate() as StandardMaterial3D
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 2.0
		mesh_instance.set_surface_override_material(0, material)
	reward_label.text = get_reward_label_text()
	reward_label.modulate = color
	_apply_custom_visual()

## 按掉落物类型换 3D 外观。
##
## 只换**视觉网格**，绝不动碰撞盒与领取半径：PickupChest 的 BoxShape3D 与 ClaimArea
## 的 CylinderShape3D 是 SimWorld.CHEST_BLOCKER_HALF_SIZE / CHEST_CLAIM_RADIUS 的
## 手工镜像，而掉落物是阻挡几何——阻挡矩形一旦跟着模型变，各端流场就会分叉，
## 僵尸集体走岔路。视觉大小只能靠 view_scale 调。
func _apply_custom_visual() -> void:
	if definition == null or definition.view_scene == null:
		return
	if custom_visual != null and is_instance_valid(custom_visual):
		custom_visual.queue_free()
		custom_visual = null
	var instance := definition.view_scene.instantiate() as Node3D
	if instance == null:
		return
	visual_root.visible = false
	instance.scale = Vector3.ONE * maxf(definition.view_scale, 0.01)
	add_child(instance)
	custom_visual = instance

func get_reward_label_text() -> String:
	return definition.get_label_text(reward_amount) if definition != null else "未配置补给"
