extends Node3D
class_name WallImpactSpark

## 子弹打在墙/掩体上的火花。纯表现，不进模拟。
##
## 触发点与墙面弹着音完全同源：RangedWeapon.show_tracer() 拿到模拟层射击事件里的
## `hit_blocker`，同一处既播音又放火花。**表现层绝不自己补一条射线去判断打没打到墙**
## ——那等于在确定性解算之外又开一条会分叉的判定路径。
##
## 【为什么火花朝射击方向的反面喷】
## 子弹撞墙后碎屑是往回弹的，不是继续往前钻。BloodImpact 沿弹道**正向**喷（血是
## 从身体另一侧溅出去的），这里必须反过来。传进来的是弹道方向，取反在 setup 里做，
## 免得调用方两处各写各的。
##
## 【池化】
## 由 RangedWeapon 持有对象池，和曳光同一套写法。冲锋枪 10 发/秒贴着墙扫射时
## 每发都会走到这里，逐发实例化 GPUParticles3D 会把帧顶爆——那正是这个项目
## 第五根支柱（高压下的帧稳定）要守的东西。

@export var lifetime: float = 0.32

@onready var sparks: GPUParticles3D = $Sparks

var remaining := 0.0
var pooled := false


func _ready() -> void:
	_ensure_nodes()
	set_process(remaining > 0.0)


## shot_direction 是**弹道方向**（子弹飞行的方向），火花会朝它的反面喷。
func setup(hit_position: Vector3, shot_direction: Vector3) -> void:
	_ensure_nodes()
	visible = true
	if is_inside_tree():
		global_position = hit_position
	else:
		position = hit_position

	var spray_direction := -shot_direction.normalized()
	if spray_direction.length_squared() <= 0.000001:
		spray_direction = Vector3.FORWARD
	if is_inside_tree():
		# look_at 让局部 -Z 对准目标，而粒子材质的 direction 就写在局部 -Z 上。
		# 弹道压平后是水平的，与 UP 平行的情况理论上不会出现，但兜底仍然要有：
		# look_at 在方向与 up 共线时会报错并留下一个非法基。
		var up_direction := Vector3.UP
		if absf(spray_direction.dot(up_direction)) > 0.98:
			up_direction = Vector3.RIGHT
		look_at(global_position + spray_direction, up_direction)

	remaining = maxf(lifetime, 0.05)
	if is_inside_tree():
		sparks.restart()
		sparks.emitting = true
	set_process(true)


func set_pooled(value: bool) -> void:
	pooled = value
	if pooled:
		deactivate()


func is_active() -> bool:
	return remaining > 0.0 and visible


func deactivate() -> void:
	remaining = 0.0
	if sparks != null:
		sparks.emitting = false
	visible = false
	set_process(false)


## 这两个方法的存在就是 CombatFxPrewarmer 的准入条件：它扫 res://scenes/fx，
## 谁同时有 warmup_for_render 与 finish_render_warmup 谁就会被开局真画一帧，
## 把粒子/材质管线提前编译掉。少写一个，这套火花就会在第一次打墙时现编译，
## 在单线程的 Web 导出上就是一次可见的卡顿。
func warmup_for_render(context: FxWarmupContext) -> void:
	setup(
		context.position_in_view(3.0, Vector2(0.0, -0.2)),
		context.forward_direction()
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
	if sparks == null:
		sparks = get_node("Sparks") as GPUParticles3D
