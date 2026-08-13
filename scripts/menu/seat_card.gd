extends PanelContainer
class_name SeatCard

## 一张座位卡。纯展示件——它不知道网络存在，只接受一份解析好的座位数据。
##
## 角色切换在这里只表达为「往前一个/往后一个」，由房间面板去查目录、发消息。
## 卡片自己去查目录的话，四张卡就有四份对「下一个角色是谁」的判断。

signal character_step_requested(step: int)

const EMPTY_TEXT := "等待玩家加入"
const EMPTY_RULE_COLOR := Color(0.28, 0.30, 0.32, 1.0)
const EMPTY_NAME_COLOR := Color(0.62, 0.65, 0.68, 1.0)
## 角色应当占卡片可视高度的比例。留一点余量，免得头顶和脚尖贴着边。
const CHARACTER_FILL_RATIO := 0.86
## 相机相对角色中心抬高多少（按取景距离的比例）。纯平视显得呆，
## 微微俯一点和本地多人大厅那个远景相机的观感一致。
const CAMERA_ELEVATION_RATIO := 0.16

@onready var viewport_container: SubViewportContainer = %CharacterViewportContainer
@onready var preview = %LobbyPlayerPreview
@onready var name_label: Label = %NameLabel
@onready var host_badge: Label = %HostBadge
@onready var ready_banner: Label = %ReadyBanner
@onready var previous_button: Button = %PreviousButton
@onready var next_button: Button = %NextButton
@onready var accent_rule: ColorRect = %AccentRule
@onready var camera: Camera3D = %CharacterCamera
@onready var viewport: SubViewport = %CharacterViewport

func _ready() -> void:
	previous_button.pressed.connect(func(): character_step_requested.emit(-1))
	next_button.pressed.connect(func(): character_step_requested.emit(1))
	preview.set_label_visible(false)
	viewport_container.resized.connect(_on_stage_resized)
	_frame_character()
	set_empty()

## 按模型自己的包围盒摆相机，而不是在场景里写死一个手调过的矩阵。
##
## 写死的值只对「当前这个模型 + 当前这个卡片尺寸」成立：换个角色模型、
## 或者卡片在窄屏上被压扁，角色就会缩到角落里去——而这种错位 headless 校验
## 看不出来，只在人眼前现形。让代码去算，就不存在「忘了重新调相机」这件事。
func _frame_character() -> void:
	if camera == null or preview == null:
		return
	var bounds: AABB = preview.get_visual_aabb()
	if bounds.size.y <= 0.0:
		return
	var center := bounds.get_center()
	# 只按高度反算距离（Camera3D 默认 KEEP_HEIGHT，竖直视野与宽高比无关）。
	#
	# 刻意不按宽度适配：蒙皮网格报的是**绑定姿势**的包围盒，而这个模型的绑定
	# 姿势是张开双臂的 T-pose，宽 2.04 比高还大——按它适配会把相机推远一截，
	# 角色反而缩成一小团。高度不受绑定姿势影响，是这里唯一可信的那一维。
	var half_fov := deg_to_rad(camera.fov * 0.5)
	var distance := (bounds.size.y / CHARACTER_FILL_RATIO) * 0.5 / tan(half_fov)
	# 距离从包围盒**中心**量，不是从前表面：相机看的是角色整体，
	# 按前表面量会让主体实际距离多出半个盒深，角色于是比设定值小一圈。
	var eye := Vector3(
		center.x,
		center.y + distance * CAMERA_ELEVATION_RATIO,
		center.z + distance
	)
	camera.position = eye
	camera.look_at(center, Vector3.UP)

## 卡片被重新布局（窗口缩放、竖屏）后重新取景。
## 竖直视野与宽高比无关，所以这里其实只是在换过角色模型后兜底刷新一次。
func _on_stage_resized() -> void:
	_frame_character()

func set_empty() -> void:
	viewport_container.visible = false
	# 空位卡不渲染：SubViewportContainer 会把子 viewport 顶成 UPDATE_ALWAYS，
	# 不显式关掉的话，四个空座位也在每帧各渲染一遍 3D。
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	name_label.text = EMPTY_TEXT
	name_label.modulate = EMPTY_NAME_COLOR
	host_badge.visible = false
	ready_banner.visible = false
	previous_button.visible = false
	next_button.visible = false
	accent_rule.color = EMPTY_RULE_COLOR

func set_occupied(
	nickname: String,
	character: CharacterDefinition,
	is_ready: bool,
	is_host: bool,
	is_local: bool
) -> void:
	viewport_container.visible = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	name_label.text = nickname
	name_label.modulate = Color.WHITE
	host_badge.visible = is_host
	ready_banner.visible = is_ready
	# 准备之后锁定选择：别人是对着当前这套阵容点的准备。
	var can_switch := is_local and not is_ready
	previous_button.visible = can_switch
	next_button.visible = can_switch
	var accent := character.accent_color if character != null else Color.WHITE
	accent_rule.color = accent
	preview.set_character_definition(character)
	preview.set_accent_color(accent)
	preview.set_online(true)
	# 本机那张卡靠更亮的描边区分，不做单独的放大预览。
	self_modulate = Color(1.15, 1.15, 1.15, 1.0) if is_local else Color.WHITE
	# 取景放在最后：_ready() 里那次是在座位状态定下来之前算的，此刻的可见网格
	# 才是真正要入镜的那一组，用它重算才能保证角色真的按设定比例占满卡片。
	_frame_character()
