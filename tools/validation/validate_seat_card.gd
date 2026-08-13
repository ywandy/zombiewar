extends SceneTree

## 座位卡组件的校验。
##
## 卡片是纯展示件：它不知道网络存在，只接受一份已经解析好的座位数据。
## 这里断言的就是这条边界——以及每张卡必须有自己独立的 SubViewport，
## 四张卡共用一个 viewport 会让四个座位显示同一个角色。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_seat_card.gd

const SEAT_CARD_SCENE_PATH := "res://scenes/menu/SeatCard.tscn"
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(SEAT_CARD_SCENE_PATH), "SeatCard 场景必须存在", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(SEAT_CARD_SCENE_PATH) as PackedScene
	var catalog = ContentCatalogsScript.characters()
	var red = catalog.get_by_id(&"male_assault")
	var blue = catalog.get_by_id(&"male_medic")

	var card_a = scene.instantiate()
	var card_b = scene.instantiate()
	root.add_child(card_a)
	root.add_child(card_b)
	await process_frame

	# 空位态：不显示角色，显示等待文案。
	card_a.set_empty()
	await process_frame
	_expect(not card_a.get_node("%CharacterViewportContainer").visible, "空位卡不显示角色", failures)
	_expect(card_a.get_node("%NameLabel").text.strip_edges() != "", "空位卡要有等待文案", failures)
	_expect(not card_a.get_node("%ReadyBanner").visible, "空位卡不显示准备横幅", failures)
	_expect(not card_a.get_node("%PreviousButton").visible, "空位卡不显示切换箭头", failures)

	# 占位态。
	card_a.set_occupied("阿波", red, false, true, true)
	card_b.set_occupied("小明", blue, true, false, false)
	await process_frame
	_expect(card_a.get_node("%CharacterViewportContainer").visible, "占位卡要显示角色", failures)
	_expect(card_a.get_node("%NameLabel").text == "阿波", "占位卡要显示昵称", failures)
	_expect(card_a.get_node("%HostBadge").visible, "房主卡要显示房主徽标", failures)
	_expect(not card_b.get_node("%HostBadge").visible, "非房主卡不显示房主徽标", failures)
	_expect(not card_a.get_node("%ReadyBanner").visible, "未准备时不显示准备横幅", failures)
	_expect(card_b.get_node("%ReadyBanner").visible, "已准备时显示准备横幅", failures)

	# 箭头只在「本机 且 未准备」时出现。
	_expect(card_a.get_node("%PreviousButton").visible, "本机未准备时要能换角色", failures)
	_expect(not card_b.get_node("%PreviousButton").visible, "别人的卡不能有切换箭头", failures)
	card_a.set_occupied("阿波", red, true, true, true)
	await process_frame
	_expect(not card_a.get_node("%PreviousButton").visible, "本机已准备后必须锁定角色选择", failures)

	# 每张卡必须有自己的 SubViewport 与自己的角色实例。
	var viewport_a := card_a.get_node("%CharacterViewport") as SubViewport
	var viewport_b := card_b.get_node("%CharacterViewport") as SubViewport
	_expect(viewport_a != viewport_b, "每张卡必须有独立的 SubViewport", failures)
	_expect(
		viewport_a.find_child("LobbyPlayerPreview", true, false) != null,
		"卡片的 SubViewport 里必须有角色预览",
		failures
	)
	_expect(
		viewport_a.find_children("*", "Camera3D", true, false).size() == 1,
		"卡片的 SubViewport 里必须正好有一个相机",
		failures
	)

	_expect(viewport_a.own_world_3d, "每张卡必须有自己的 3D 世界，否则四个角色互相照亮", failures)

	# 配色必须真的传到卡里那个角色预览上。
	var preview_a = viewport_a.find_child("LobbyPlayerPreview", true, false)
	var preview_b = viewport_b.find_child("LobbyPlayerPreview", true, false)

	# 取景必须由代码按模型包围盒算出来，不是场景里写死的矩阵。
	# 断言角色真的落在相机视野内且占满大半个画面——写死的相机换个模型就错位，
	# 而错位只在人眼前现形，这里把它变成一条能失败的断言。
	var camera_a := card_a.get_node("%CharacterCamera") as Camera3D
	var bounds: AABB = preview_a.get_visual_aabb()
	_expect(bounds.size.y > 0.0, "角色必须有可见网格，否则卡片是空的", failures)
	if bounds.size.y > 0.0:
		var half_fov := deg_to_rad(camera_a.fov * 0.5)
		# 距离按包围盒中心量，与 _frame_character() 的基准一致。
		# 用前表面量会把半个盒深算漏，两边对不上就会得出一个假的占比。
		var distance: float = camera_a.position.z - bounds.get_center().z
		_expect(distance > 0.0, "相机必须在角色前方", failures)
		var half_height := distance * tan(half_fov)
		var fill := bounds.size.y / (2.0 * half_height)
		_expect(
			fill > 0.7 and fill <= 1.0,
			"角色应占卡片可视高度的 70%%-100%%，实际 %.0f%%" % (fill * 100.0),
			failures
		)
		# 最重要的一条：角色必须**完整**入镜。占比再好看，切掉脚也是废的。
		var aim_y: float = camera_a.position.y + distance * tan(camera_a.rotation.x)
		_expect(
			aim_y - half_height <= bounds.position.y and aim_y + half_height >= bounds.end.y,
			"角色必须完整入镜：视野 %.2f..%.2f 角色盒 %.2f..%.2f" % [
				aim_y - half_height, aim_y + half_height,
				bounds.position.y, bounds.end.y
			],
			failures
		)
	_expect(
		preview_a.accent_color.is_equal_approx(red.accent_color),
		"卡片必须把角色配色传给预览",
		failures
	)
	_expect(
		not preview_a.accent_color.is_equal_approx(preview_b.accent_color),
		"两张卡选了不同角色时配色必须不同",
		failures
	)

	# 箭头点击必须翻译成 step 信号，而不是自己去改选择——卡片不知道目录存在。
	var steps: Array[int] = []
	card_a.character_step_requested.connect(func(step: int): steps.append(step))
	card_a.set_occupied("阿波", red, false, true, true)
	await process_frame
	(card_a.get_node("%PreviousButton") as Button).pressed.emit()
	(card_a.get_node("%NextButton") as Button).pressed.emit()
	_expect(steps == [-1, 1], "箭头必须发出 -1 / +1 的 step 信号，实际 %s" % str(steps), failures)

	card_a.queue_free()
	card_b.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_seat_card: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_seat_card: %s" % failure)
	printerr("validate_seat_card: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
