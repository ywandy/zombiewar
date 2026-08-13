extends Node3D
class_name BloodImpact

@export var lifetime: float = 0.45
@export var minimum_intensity: float = 0.75
@export var maximum_intensity: float = 1.35

@onready var droplets: GPUParticles3D = $Droplets

var remaining := 0.0
var pooled := false

func _ready() -> void:
	_ensure_nodes()
	set_process(remaining > 0.0)

func setup(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> void:
	_ensure_nodes()
	visible = true
	if is_inside_tree():
		global_position = hit_position
	else:
		position = hit_position

	var spray_direction := shot_direction.normalized()
	if spray_direction.length_squared() <= 0.000001:
		spray_direction = Vector3.FORWARD
	if is_inside_tree():
		var up_direction := Vector3.UP
		if absf(spray_direction.dot(up_direction)) > 0.98:
			up_direction = Vector3.RIGHT
		look_at(global_position + spray_direction, up_direction)

	# 强度仍限制在现有范围内，但粒子数量固定为少量 9 滴；强度只保留接口兼容。
	var _resolved_intensity := clampf(intensity, minimum_intensity, maximum_intensity)
	droplets.amount_ratio = 1.0
	remaining = maxf(lifetime, 0.05)
	if is_inside_tree():
		droplets.restart()
		droplets.emitting = true
	set_process(true)

func set_pooled(value: bool) -> void:
	pooled = value
	if pooled:
		deactivate()

func is_active() -> bool:
	return remaining > 0.0 and visible

func deactivate() -> void:
	remaining = 0.0
	if droplets != null:
		droplets.emitting = false
	visible = false
	set_process(false)

func warmup_for_render(context: FxWarmupContext) -> void:
	setup(
		context.position_in_view(3.0, Vector2(0.0, -0.2)),
		context.forward_direction(),
		1.0
	)
	set_process(false)

func finish_render_warmup() -> void:
	deactivate()

func _process(delta: float) -> void:
	remaining -= delta
	if remaining <= 0.0:
		if pooled:
			deactivate()
		else:
			queue_free()

func _ensure_nodes() -> void:
	if droplets == null:
		droplets = get_node("Droplets") as GPUParticles3D
