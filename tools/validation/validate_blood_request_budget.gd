extends SceneTree

## 地面血迹的帧预算回归。
##
## 血迹请求是排队的，每帧只落地 max_requests_per_frame 个。这个预算必须跟得上
## **最快的那把枪**乘以同屏可能同时中弹的僵尸数，否则队列持续积压，血迹会在几帧
## 之后才落在当时的命中点上——而玩家那时已经转身或走开，现象就是
## 「明明打的是前面的僵尸，血却出现在角色身后」，外加地面血迹成片闪烁。
##
## 这类缺陷不会报错、不影响判定、也不会让任何既有测试变红：它只是看起来不对。
## 提高任何一把枪的射速、或抬高波次的同屏僵尸数，都可能重新打破这个平衡，
## 所以预算与射速的关系必须由回归守住，而不是靠记得去调。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_blood_request_budget.gd

const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const ARENA_SCENE_PATH := "res://scenes/gameplay/GameplayArena.tscn"
const WEAPON_RESOURCE_DIRECTORY := "res://resources/weapons"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = GroundBloodManagerScript.new()
	var peak := _peak_requests_per_shot()
	_check(
		"must find at least one ranged weapon to size the budget against",
		peak > 0
	)

	# 按**瞬时峰值**而不是每秒均值来定预算。均值永远看着够用——10 发/秒也才 20 个
	# 请求/秒，而 2 个/帧就有 120 个/秒的名义吞吐——但血迹是一枪一批涌进来的：
	# 一发穿透弹同一 tick 就能排满 (穿透数+1) × 2 个请求（每个目标一个命中血点，
	# 打死了再加一滩尸血）。排空这一批要花几帧，延迟就是几帧，血就落在几帧前的
	# 命中点上。所以要求：单发子弹造成的血迹必须在两帧内落完。
	var frames_for_one_shot := float(peak) / float(maxi(manager.max_requests_per_frame, 1))
	_check(
		"one shot queues up to %d blood requests; at %d/frame that takes %.1f frames to land" % [
			peak, manager.max_requests_per_frame, frames_for_one_shot
		],
		frames_for_one_shot <= 2.0
	)

	_test_queue_is_bounded(manager)
	_test_scene_pool_size()
	manager.free()
	_report()


## 队列必须有上限，且丢弃的是**最旧**的请求——保留最新的才对得上玩家正在看的画面。
func _test_queue_is_bounded(manager) -> void:
	var flood := 500
	for index in range(flood):
		manager.queue_hit_splat(
			Vector3(float(index), 0.0, 0.0),
			1.0,
			false
		)
	_check(
		"queue must stay bounded under a flood (%d pending after %d requests)" % [
			manager.get_pending_request_count(), flood
		],
		manager.get_pending_request_count() <= manager.max_pending_requests
	)
	var newest = manager.pending_requests[manager.pending_requests.size() - 1]
	var newest_position: Vector3 = newest["position"]
	_check(
		"the queue must drop the oldest requests, not the newest",
		is_equal_approx(newest_position.x, float(flood - 1))
	)
	# 积压超过半秒就已经不是「稍微延迟」了，上限必须比这更紧。
	var frames_to_drain := (
		float(manager.max_pending_requests) / float(manager.max_requests_per_frame)
	)
	_check(
		"a full queue must drain in well under half a second (%.1f frames)" % frames_to_drain,
		frames_to_drain <= 6.0
	)


## 血迹是永久的（见 persistent ground blood 的设计），池满之后每一次落地都会回收一片
## 仍然显示在地上的旧血迹——回收得越频繁，地面看起来就越像在闪。池子必须至少能
## 撑住一整波尸潮的击杀数。
func _test_scene_pool_size() -> void:
	var arena_scene := load(ARENA_SCENE_PATH) as PackedScene
	_check("gameplay arena scene must load", arena_scene != null)
	if arena_scene == null:
		return
	var arena := arena_scene.instantiate()
	var manager = arena.get_node_or_null("GroundBloodManager")
	_check("arena must host a GroundBloodManager", manager != null)
	if manager != null:
		_check(
			"splat pool (%d) must outlast a heavy wave" % manager.max_splats,
			manager.max_splats >= 256
		)
	var detached_team_state = arena.get("local_team_state")
	arena.free()
	if detached_team_state != null and is_instance_valid(detached_team_state):
		detached_team_state.free()


## 单发子弹能一次排进队列的最多血迹请求数，跨全部远程武器取最大。
## 每个被这一发打到的目标出一个命中血点，被打死的再加一滩尸血。
func _peak_requests_per_shot() -> int:
	var peak := 0
	var directory := DirAccess.open(WEAPON_RESOURCE_DIRECTORY)
	if directory == null:
		return peak
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry.get_extension() == "tres":
			var definition = load(WEAPON_RESOURCE_DIRECTORY.path_join(entry))
			if definition != null and definition is RangedWeaponDefinition:
				# 一枪 = 弹丸数 × 每颗能穿透的目标数；每个目标只排一个脚下圆形血迹，
				# 击杀强度通过同一请求的 killed 标记表达。
				var targets: int = definition.max_penetration_count + 1
				var pellets: int = definition.pellet_count
				peak = maxi(peak, targets * pellets)
		entry = directory.get_next()
	directory.list_dir_end()
	return peak


func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)


func _report() -> void:
	if failures.is_empty():
		print("validate_blood_request_budget: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
