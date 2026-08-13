extends Node3D
class_name LobbyPlayerPreview

const DISPLAY_WEAPON := "SMG"
const LEGACY_LONG_GUN_MODEL_NAME := "Ri" + "fle"
const WEAPON_NAMES := [
	"Axe",
	"Guitar",
	"Knife",
	"Pistol",
	LEGACY_LONG_GUN_MODEL_NAME,
	"Shotgun",
	"SMG",
	"Spear",
	"WoodenBat_Barbed",
	"WoodenBat_Saw",
]

@export var character_scene: PackedScene

var player_index := 0
var online := true
var accent_color := Color(1.0, 0.43, 0.24, 1.0)
var character_model: Node3D
var missing_resource_warned := false
var missing_animation_warned := false

func _ready() -> void:
	_instantiate_character()
	_apply_status()

func set_player_index(index: int) -> void:
	player_index = maxi(index, 0)
	_apply_status()

func set_online(value: bool) -> void:
	online = value
	_apply_status()

## 角色配色。落在灯光颜色与名牌描边上，不碰模型材质——
## 角色用的是单张 atlas，整体染色会把脸和武器一并染了。
func set_accent_color(value: Color) -> void:
	accent_color = value
	_apply_status()

func set_character_definition(definition: CharacterDefinition) -> void:
	if character_model != null and is_instance_valid(character_model):
		character_model.free()
	character_model = null
	var selected := (
		definition.model_scene
		if definition != null and definition.model_scene != null
		else character_scene
	)
	_instantiate_character(selected)

## 座位卡里名字由卡片自己的 2D 标签画，Label3D 要能关掉，
## 否则同一个名字会在卡里出现两次。
func set_label_visible(value: bool) -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.visible = value

## 角色可见网格的合并包围盒（本节点局部坐标）。
##
## 座位卡靠它反算相机距离，而不是把一个手调好的相机矩阵写死在场景里：
## 手调的值只对"当前这个模型 + 当前这个卡片尺寸"成立，换任何一个都会错位，
## 而错位在 headless 校验里看不出来——它只在人眼前现形。
func get_visual_aabb() -> AABB:
	var result := AABB()
	var found := false
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		# 只看自己那一位不够：收起来的武器是把父 Node3D 关掉的，网格自身仍是
		# visible。但也不能用 is_visible_in_tree()——空位卡会把整张卡藏起来，
		# 那样算出来的是个空盒。所以只向上走到本节点为止。
		if mesh_instance == null or not _visible_within_preview(mesh_instance):
			continue
		var box: AABB = mesh_instance.get_aabb()
		if box.size == Vector3.ZERO:
			continue
		# 转到本节点的局部坐标：模型挂在 ModelAnchor 下且被旋转过 180°，
		# 直接用网格自己的 AABB 会把那次旋转丢掉。
		box = (global_transform.affine_inverse() * mesh_instance.global_transform) * box
		result = box if not found else result.merge(box)
		found = true
	return result

func _visible_within_preview(node: Node3D) -> bool:
	var cursor: Node = node
	while cursor != null and cursor != self:
		if cursor is Node3D and not (cursor as Node3D).visible:
			return false
		cursor = cursor.get_parent()
	return true

func _instantiate_character(scene: PackedScene = null) -> void:
	var selected := scene if scene != null else character_scene
	if selected == null:
		_warn_missing_resource()
		return
	var instance := selected.instantiate() as Node3D
	if instance == null:
		_warn_missing_resource()
		return
	character_model = instance
	character_model.name = "CharacterModel"
	$ModelAnchor.add_child(character_model)
	_configure_weapons()
	_play_idle_animation()

func _configure_weapons() -> void:
	if character_model == null:
		return
	for weapon_name in WEAPON_NAMES:
		var weapon := character_model.find_child(weapon_name, true, false) as Node3D
		if weapon != null:
			weapon.visible = weapon_name == DISPLAY_WEAPON

## 待机动画必须循环播放。
##
## GLTF 导进来的 Idle_Gun 是 loop_mode = NONE：长 1 秒，播完就停死在最后一帧。
## 而它本身幅度极小（骨骼位移合计变化 0.034），停住之后和一张静态图没有区别——
## 这正是「模型没有动」的成因，而且在本地多人大厅那个远景相机下一直没被发现。
##
## 循环开在一份**副本**上，不改 AnimationPlayer 原来那份：那份 Animation 资源
## 由整个 GLTF 共享，直接改它会顺带影响游戏里的玩家角色。
const IDLE_ANIMATION := &"Idle_Gun"
const LOBBY_LIBRARY := &"lobby"

func _play_idle_animation() -> void:
	var animation_player := character_model.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player == null or not animation_player.has_animation(IDLE_ANIMATION):
		if not missing_animation_warned:
			push_warning("Lobby character preview is missing Idle_Gun animation")
			missing_animation_warned = true
		return
	var source := animation_player.get_animation(IDLE_ANIMATION)
	var looping := source.duplicate() as Animation
	looping.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation(IDLE_ANIMATION, looping)
	animation_player.add_animation_library(LOBBY_LIBRARY, library)
	animation_player.play(StringName("%s/%s" % [LOBBY_LIBRARY, IDLE_ANIMATION]), 0.15)

func _apply_status() -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.text = "P%d" % (player_index + 1)
		# modulate 表达在线/离线，outline_modulate 表达角色配色。
		# 两者分开，才能让「离线变暗」不把配色一起洗掉。
		label.modulate = Color.WHITE if online else Color(0.5, 0.53, 0.55, 1.0)
		label.outline_modulate = accent_color
	var light := get_node_or_null("PlayerLight") as OmniLight3D
	if light != null:
		light.light_color = accent_color
		light.light_energy = 1.25 if online else 0.28

func _warn_missing_resource() -> void:
	if missing_resource_warned:
		return
	push_warning("Lobby character preview could not instantiate its character scene")
	missing_resource_warned = true
