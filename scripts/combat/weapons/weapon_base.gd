extends "res://scripts/player/equipment_item.gd"
class_name WeaponBase

const HitResult = preload("res://scripts/combat/hit_result.gd")
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const WeaponVisualBindingScript = preload(
	"res://scripts/combat/weapons/weapon_visual_binding.gd"
)

signal attack_started(animation_name: StringName, lock_duration: float)
signal attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
)

@export var definition: WeaponDefinition
@export var initially_owned := false

var wielder: CharacterBody3D
var character_visual_root: Node3D
var functional_ray_origin: Marker3D
var visual_anchor: Node3D
var visual_binding: WeaponVisualBinding
var trigger_pressed := false
var trigger_just_pressed := false
var aim_direction := Vector3.FORWARD
var owned := false
var sim_request_sink := Callable()

## 武器不认识玩家槽位，也不认识模拟层的武器档案下标：
## 它只把「我要开火 / 我要挥击」的原始意图交给上层，
## 由竞技场翻译成 SimWorld 事件。武器因此不依赖 scripts/sim/。
func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value

func emit_sim_request(request: Dictionary) -> void:
	if sim_request_sink.is_valid():
		sim_request_sink.call(request)

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	owned = initially_owned
	wielder = value_wielder
	character_visual_root = value_visual_root
	functional_ray_origin = value_functional_ray_origin
	_clear_visual_instance()
	visual_anchor = null
	if definition == null:
		return
	visual_binding = WeaponVisualBindingScript.new()
	visual_anchor = visual_binding.bind(
		character_visual_root,
		definition.visual_scene,
		definition.visual_transform
	)

func _exit_tree() -> void:
	_clear_visual_instance()

func _clear_visual_instance() -> void:
	if visual_binding != null:
		visual_binding.clear()
	visual_binding = null
	visual_anchor = null

func set_attack_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	trigger_pressed = value_trigger_pressed
	trigger_just_pressed = value_trigger_just_pressed
	aim_direction = WeaponMath.flat_direction(value_aim_direction)

func set_use_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	set_attack_input(
		value_trigger_pressed,
		value_trigger_just_pressed,
		value_aim_direction
	)

func set_equipped(value: bool) -> void:
	visible = value
	set_process(value)
	set_physics_process(value)
	if visual_anchor != null:
		visual_anchor.visible = value
	if visual_binding != null:
		visual_binding.set_visible(value)
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	trigger_pressed = false
	trigger_just_pressed = false

func cancel_use() -> void:
	cancel_attack()

func get_display_name() -> String:
	return definition.display_name if definition != null else ""

func get_item_id() -> StringName:
	return definition.weapon_id if definition != null else &""

func is_available() -> bool:
	return owned

func is_owned() -> bool:
	return owned

func set_owned(value: bool) -> bool:
	if owned == value:
		return false
	owned = value
	return true

func receive_pickup(_amount: int) -> bool:
	return set_owned(true)

func get_remaining_count() -> int:
	return -1

func get_idle_animation() -> StringName:
	return definition.idle_animation

func get_run_animation() -> StringName:
	return definition.run_animation
