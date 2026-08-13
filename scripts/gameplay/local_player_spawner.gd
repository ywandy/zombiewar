extends Node
class_name LocalPlayerSpawner

const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
const PlayerScreenBoundsScript = preload(
	"res://scripts/camera/player_screen_bounds.gd"
)
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const PLAYER_SHAPE_RADIUS := 0.45
const PLAYER_SHAPE_HEIGHT := 1.8
const PLAYER_SHAPE_CENTER_Y := 0.93
const FALLBACK_OFFSETS := [
	Vector3.ZERO,
	Vector3(1.2, 0.0, 0.0),
	Vector3(-1.2, 0.0, 0.0),
	Vector3(0.0, 0.0, 1.2),
	Vector3(0.0, 0.0, -1.2),
]

@export var player_scene: PackedScene = preload("res://scenes/player/Player.tscn")

func spawn_players(
	container: Node3D,
	spawn_points: Array[Marker3D],
	place_item_service,
	single_player_input
) -> Array[PlayerController]:
	var spawned: Array[PlayerController] = []
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return _fail_spawn(spawned, "GameSession is unavailable")
	session.last_error = ""
	var descriptors: Array = session.local_players
	if descriptors.is_empty() or descriptors.size() > spawn_points.size():
		return _fail_spawn(spawned, "Local player session has no valid spawn slots")
	if player_scene == null:
		return _fail_spawn(spawned, "Player scene is unavailable")
	var screen_camera := container.get_viewport().get_camera_3d()
	if screen_camera == null:
		return _fail_spawn(spawned, "Shared screen camera is unavailable")
	var safe_margin_ratio := _resolve_safe_margin_ratio(screen_camera)

	for index in range(descriptors.size()):
		var input_source = single_player_input
		var descriptor = descriptors[index]
		if session.mode == GameSessionScript.Mode.SINGLE:
			input_source = single_player_input
		elif descriptor != null:
			# 联机的本机座位刻意返回 null：它要复用竞技场那一个已经接好触屏
			# 摇杆的输入源实例，而不是新建一个没人给它喂输入的。
			# 只认 is_local 这一条替换理由——本地多人下 create_input_source()
			# 返回 null 的意思是「手柄不见了」，那必须照旧失败，不能被顶替掉。
			var wants_shared_input: bool = "is_local" in descriptor and descriptor.is_local
			input_source = single_player_input if wants_shared_input else descriptor.create_input_source()
		if input_source == null:
			return _fail_spawn(spawned, "Player %d has an invalid input source" % (index + 1))
		if not PlayerScreenBoundsScript.limit_motion(
			screen_camera,
			spawn_points[index].global_position,
			Vector3.ZERO,
			safe_margin_ratio
		).is_zero_approx():
			return _fail_spawn(spawned, "Player %d spawn is outside the shared safe view" % (index + 1))
		var spawn_position = _find_open_spawn_position(container, spawn_points[index])
		if spawn_position == null:
			return _fail_spawn(spawned, "Player %d has no open spawn position" % (index + 1))
		var player := player_scene.instantiate() as PlayerController
		if player == null:
			return _fail_spawn(spawned, "Player %d could not be instantiated" % (index + 1))
		player.name = "P%d" % (index + 1)
		player.player_index = index
		# 三种模式的描述符同形，都带 character_id；只有输入源创建按模式分叉。
		var catalog = ContentCatalogsScript.characters()
		var character_id: StringName = catalog.default_id()
		if descriptor != null and "character_id" in descriptor and String(descriptor.character_id) != "":
			character_id = descriptor.character_id
		var character = catalog.get_by_id(character_id)
		if character != null:
			player.apply_character_definition(character)
		player.screen_safe_margin_ratio = safe_margin_ratio
		player.set_input_source(input_source)
		player.set_place_item_service(place_item_service)
		player.set_screen_camera(screen_camera)
		container.add_child(player)
		# 自动装备本命武器。add_child 之后 equipment 才初始化（@onready），
		# 所以放在这里而不是 apply_character_definition 里。武器本就在
		# Player.tscn 的 loadout 里；get_slot_for_item 拿不到（未知 id）则跳过。
		if character != null and String(character.signature_weapon_id) != "":
			var sig_slot := player.equipment.get_slot_for_item(character.signature_weapon_id)
			if sig_slot >= 0:
				player.equipment.equip_slot(sig_slot)
		player.global_position = spawn_position
		spawned.append(player)
	return spawned

func _resolve_safe_margin_ratio(camera: Camera3D) -> float:
	var follow_camera := camera.get_parent().get_parent() as FollowCamera
	return follow_camera.safe_margin_ratio if follow_camera != null else 0.08

func _find_open_spawn_position(container: Node3D, marker: Marker3D):
	var world := container.get_world_3d()
	if world == null:
		return marker.global_position
	var shape := CapsuleShape3D.new()
	shape.radius = PLAYER_SHAPE_RADIUS
	shape.height = PLAYER_SHAPE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.collide_with_areas = true
	query.collide_with_bodies = true
	for offset in FALLBACK_OFFSETS:
		var candidate: Vector3 = marker.global_position + offset
		query.transform = Transform3D(
			Basis.IDENTITY,
			candidate + Vector3(0.0, PLAYER_SHAPE_CENTER_Y, 0.0)
		)
		if world.direct_space_state.intersect_shape(query, 1).is_empty():
			return candidate
	return null

func _fail_spawn(
	spawned: Array[PlayerController],
	message: String
) -> Array[PlayerController]:
	for player in spawned:
		if is_instance_valid(player):
			player.free()
	var session := get_node_or_null("/root/GameSession")
	if session != null:
		session.last_error = message
	return []
