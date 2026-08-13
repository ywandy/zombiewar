extends Resource
class_name CharacterDefinition

## 一个可选角色。
##
## A 阶段四个角色共用同一个 GLTF，只靠 accent_color 区分——它落在脚下光环、
## 名牌描边和座位卡描边三处，而不是给模型整体染色：角色用的是单张 atlas，
## material_override 会把脸和武器一并染了。
##
## B 阶段的三围与被动直接往这个类上加字段，不另起资源——已落地：
## 三围（max_health_bonus / move_speed_mult / damage_mult）、本命武器
## （signature_weapon_*）、被动（passive_id / passive_strength）、可选模型
## （model_scene）。后三者的生效逻辑见 PlayerController / spawner / sim_world。

@export var character_id: StringName
@export var display_name := "幸存者"
@export var accent_color := Color(1.0, 1.0, 1.0, 1.0)

@export_group("三围")
## 生命加成（绝对值，可为负）。spawner 把它加到 PlayerController.max_health。
@export var max_health_bonus := 0.0
## 移速倍率。spawner 把它乘到 PlayerController.move_speed。
@export var move_speed_mult := 1.0
## 全局伤害倍率。预留；本命武器加成走 signature_weapon_damage_mult。
@export var damage_mult := 1.0

@export_group("本命武器")
## 本命武器 id（对应 resources/weapons/*.tres 的 weapon_id）。空串 = 无本命武器。
## 加成：出生自动装备 + 该武器伤害 × signature_weapon_damage_mult（逐玩家缩放）。
@export var signature_weapon_id: StringName = &""
@export var signature_weapon_damage_mult := 1.0

@export_group("被动")
## 被动标识：suppression / fortify / medic_aura / blast_armor / 空。
@export var passive_id: StringName = &""
## 被动强度标量，各被动自行解释（增伤上限 / 范围加成 / 回血速率 / 减伤比例）。
@export var passive_strength := 1.0

@export_group("生成模型")
## 角色模型场景。目录条目必须显式配置，空值会拒绝玩家生成。
@export var model_scene: PackedScene = null
