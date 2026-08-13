extends Resource
class_name ZombieDefinition

@export var type_id: StringName
@export var display_name := "僵尸"
@export var view_scene: PackedScene
@export_range(1, 100000, 1) var max_health := 50
@export_range(1, 100000, 1) var move_speed_scale_per_10000 := 10000

@export_group("死亡爆炸")
## 死亡时是否爆炸。开启后这一型僵尸逼玩家改变打法：必须在远距离击杀，
## 绝不能贴脸清怪——这是它相对普通僵尸的唯一存在理由，不是"血更多"。
##
## 爆炸通过 SimWorld.queue_explosion_event() 走 pending_events，下一 tick 结算，
## 因此连锁引爆不会在同一 tick 内递归，与油桶连锁是同一套安全设计。
@export var explodes_on_death := false
## 爆炸半径（世界单位）。
@export_range(0.0, 20.0, 0.1) var explosion_radius := 3.0
## 爆心伤害。
@export_range(0.0, 10000.0, 1.0) var explosion_center_damage := 60.0
## 爆炸边缘伤害，应小于爆心伤害。
@export_range(0.0, 10000.0, 1.0) var explosion_edge_damage := 20.0

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if type_id.is_empty():
		errors.append("type_id is required")
	if view_scene == null:
		errors.append("view_scene is required")
	if max_health <= 0:
		errors.append("max_health must be positive")
	if move_speed_scale_per_10000 <= 0:
		errors.append("move_speed_scale_per_10000 must be positive")
	if explodes_on_death:
		if explosion_radius <= 0.0:
			errors.append("explosion_radius must be positive when explodes_on_death is true")
		if explosion_center_damage <= 0.0:
			errors.append("explosion_center_damage must be positive when explodes_on_death is true")
		if explosion_edge_damage > explosion_center_damage:
			errors.append("explosion_edge_damage must not exceed explosion_center_damage")
	return errors
