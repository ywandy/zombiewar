extends SceneTree

## 墙面弹着火花的回归。
##
## 守四件事，全是「跑起来不报错、看上去却不对」的那一类：
## 1. **火花朝弹道的反面喷**。碎屑撞墙是往回弹的，不是继续往墙里钻。
##    方向错了照样有粒子、照样有音效、日志一片干净，只是火花全喷进墙里看不见。
##    这里同时校验两半：节点朝向 + 粒子材质的局部方向。只校验一半会漏——
##    把材质 direction 的 Z 翻个号，节点朝向仍然是「对」的，火花却反向。
## 2. **池化生命周期**。set_pooled 之后耗尽寿命必须回到未激活而不是 queue_free，
##    否则池子里的对象会被释放掉，下一次取到的是已销毁实例。
## 3. **预热准入**。CombatFxPrewarmer 靠 warmup_for_render/finish_render_warmup
##    两个方法扫 res://scenes/fx。少一个就不会被预热，第一次打墙时现编译粒子管线，
##    在单线程的 Web 导出上是一次可见卡顿。
## 4. **一次开火不得实例化新粒子节点**。冲锋枪 10 发/秒贴墙扫射会把帧顶爆。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_wall_impact_spark.gd

const SPARK_SCENE_PATH := "res://scenes/fx/WallImpactSpark.tscn"
const PrewarmerScript = preload("res://scripts/fx/combat_fx_prewarmer.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_sparks_spray_back_toward_the_shooter()
	_test_pooled_sparks_deactivate_instead_of_freeing()
	_test_prewarmer_picks_it_up()
	_test_weapon_pools_sparks()
	_report()


func _make() -> WallImpactSpark:
	var scene: PackedScene = load(SPARK_SCENE_PATH)
	var spark := scene.instantiate() as WallImpactSpark
	get_root().add_child(spark)
	return spark


## 子弹朝 -Z 飞，打在墙上；火花必须朝 +Z（往回）喷。
func _test_sparks_spray_back_toward_the_shooter() -> void:
	var spark := _make()
	var travel := Vector3(0.0, 0.0, -1.0)
	var impact := Vector3(0.0, 1.0, -6.0)
	spark.setup(impact, travel)

	_check("the spark must sit at the impact point", spark.global_position.is_equal_approx(impact))

	# look_at 让局部 -Z 对准喷射方向，所以局部 +Z 应当与弹道同向。
	var local_forward := -spark.global_basis.z.normalized()
	var alignment := local_forward.dot(travel.normalized())
	_check(
		"the spark must face back along the bullet path (dot=%.3f, expected < 0)" % alignment,
		alignment < -0.9
	)

	# 另一半：粒子材质的发射方向必须落在局部 -Z 上，与 look_at 合起来才是往回喷。
	var particles := spark.get_node("Sparks") as GPUParticles3D
	_check("the spark scene must have a Sparks particle node", particles != null)
	if particles != null:
		var material := particles.process_material as ParticleProcessMaterial
		_check("Sparks must use a ParticleProcessMaterial", material != null)
		if material != null:
			_check(
				"the emission direction must point down local -Z (got %s)" % str(material.direction),
				material.direction.z < 0.0
			)
		_check("a one-shot impact must not loop", particles.one_shot)
		_check("the impact must burst, not trickle", particles.explosiveness > 0.5)
		# 世界坐标发射：局部发射会让粒子跟着节点走，命中点一移动整簇就跟着漂。
		_check("the spark must actually emit after setup", particles.emitting)

	_free_spark(spark)


func _test_pooled_sparks_deactivate_instead_of_freeing() -> void:
	var spark := _make()
	spark.set_pooled(true)
	_check("a pooled spark starts inactive", not spark.is_active())

	spark.setup(Vector3(0.0, 1.0, -6.0), Vector3(0.0, 0.0, -1.0))
	_check("setup must reactivate a pooled spark", spark.is_active())

	# 跑完整个寿命。_process 手动推进，避免依赖真实帧。
	spark._process(spark.lifetime + 0.01)
	_check("a pooled spark must go inactive when its life ends", not spark.is_active())
	_check(
		"a pooled spark must NOT be freed (the pool would hand out a dead instance)",
		is_instance_valid(spark)
	)
	_check("a spent spark must stop emitting", not spark.visible)

	# 回收之后必须能再用一次，否则池子转一圈就空了。
	spark.setup(Vector3(1.0, 1.0, -6.0), Vector3(0.0, 0.0, -1.0))
	_check("a recycled spark must be reusable", spark.is_active())
	_free_spark(spark)


func _test_prewarmer_picks_it_up() -> void:
	var spark := _make()
	_check("the spark must expose warmup_for_render", spark.has_method("warmup_for_render"))
	_check("the spark must expose finish_render_warmup", spark.has_method("finish_render_warmup"))
	_free_spark(spark)

	var prewarmer = PrewarmerScript.new()
	var discovered: Array = prewarmer.discover_warmup_scene_paths()
	_check(
		"CombatFxPrewarmer must discover the spark (found %d fx scenes)" % discovered.size(),
		discovered.has(SPARK_SCENE_PATH)
	)
	prewarmer.free()


## 每一枪都走 show_tracer；那条路径上不允许出现「新建一个粒子节点」。
func _test_weapon_pools_sparks() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/combat/weapons/ranged_weapon.gd")
	_check("ranged_weapon.gd must be readable", source != "")
	if source == "":
		return
	_check(
		"the weapon must keep a wall spark pool",
		source.contains("wall_spark_pool")
	)
	# 池对象必须 top_level，否则火花挂在枪下面会跟着玩家平移。
	_check(
		"pooled sparks must be top_level so they stay at the impact point",
		source.contains("spark.top_level = true")
	)
	# show_tracer 里只能取池对象，不能 instantiate。
	var tracer_section := source.substr(source.find("func show_tracer"))
	tracer_section = tracer_section.substr(0, tracer_section.find("\nfunc "))
	_check(
		"show_tracer must acquire a pooled spark, never instantiate one",
		tracer_section.contains("_acquire_wall_spark")
			and not tracer_section.contains("instantiate")
	)


func _free_spark(spark: WallImpactSpark) -> void:
	get_root().remove_child(spark)
	spark.free()


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_wall_impact_spark: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
