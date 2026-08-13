extends SceneTree

const FireGate = preload("res://scripts/combat/fire_gate.gd")
const GroundBloodSplatScene = preload("res://scenes/fx/GroundBloodSplat.tscn")
const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const DemoMapScene = preload("res://scenes/maps/demo/DemoMap.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_test_large_frame_does_not_shorten_next_shot_interval(failures)
	_test_reused_ground_splat_keeps_its_material(failures)
	_test_ground_blood_queue_respects_frame_budget(failures)
	await _test_blood_impact_pool_reuses_bounded_nodes(failures)
	await _test_demo_map_queues_ground_blood_requests(failures)
	if failures.is_empty():
		print("validate_combat_frame_stability: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_large_frame_does_not_shorten_next_shot_interval(
	failures: Array[String]
) -> void:
	var gate := FireGate.new(0.25)
	_expect(gate.try_consume(true), "the first held shot must fire", failures)
	gate.tick(0.40)
	_expect(
		gate.try_consume(true),
		"a held shot must fire after a frame longer than its cooldown",
		failures
	)
	_expect(
		is_equal_approx(gate.remaining, 0.25),
		"a large frame must not shorten the cooldown after the next real shot",
		failures
	)

func _test_reused_ground_splat_keeps_its_material(
	failures: Array[String]
) -> void:
	var splat := GroundBloodSplatScene.instantiate() as GroundBloodSplat
	splat.setup(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	var first_material_id := splat.material_override.get_instance_id()
	splat.setup(
		Vector3.ONE,
		Vector3.UP,
		Vector2.ONE * 2.0,
		0.0,
		Color(0.38, 0.004, 0.008, 0.98),
		Color(0.55, 0.01, 0.016, 0.30),
		0.30
	)
	_expect(
		splat.material_override.get_instance_id() == first_material_id,
		"a reused ground splat must update its existing unique material",
		failures
	)
	splat.free()

func _test_ground_blood_queue_respects_frame_budget(
	failures: Array[String]
) -> void:
	var manager := GroundBloodManagerScript.new()
	_expect(
		manager.has_method(&"queue_hit_splat") and
		manager.has_method(&"get_pending_request_count"),
		"ground blood manager must expose queued hit requests for frame budgeting",
		failures
	)
	if (
		not manager.has_method(&"queue_hit_splat") or
		not manager.has_method(&"get_pending_request_count")
	):
		manager.free()
		return
	manager.max_requests_per_frame = 2
	for request_index in range(5):
		manager.queue_hit_splat(
			Vector3(request_index, 0.0, 0.0),
			1.0,
			false
		)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 3,
		"ground blood processing must consume no more than its per-frame budget",
		failures
	)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 1,
		"queued ground blood requests must continue on later frames",
		failures
	)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 0,
		"queued ground blood requests must eventually drain",
		failures
	)
	manager.free()

func _test_blood_impact_pool_reuses_bounded_nodes(
	failures: Array[String]
) -> void:
	var manager := GroundBloodManagerScript.new()
	var supports_pool := (
		"impact_pool_size" in manager and
		manager.has_method(&"spawn_blood_impact") and
		manager.has_method(&"get_impact_pool_count")
	)
	_expect(
		supports_pool,
		"blood FX manager must expose a bounded reusable impact pool",
		failures
	)
	if not supports_pool:
		manager.free()
		return
	manager.impact_pool_size = 3
	root.add_child(manager)
	await process_frame
	_expect(
		manager.get_impact_pool_count() == 3,
		"blood impact pool must preallocate its configured node count",
		failures
	)
	var pooled_ids: Array[int] = []
	for child in manager.get_children():
		if child is BloodImpact:
			pooled_ids.append(child.get_instance_id())
	for impact_index in range(5):
		manager.spawn_blood_impact(
			Vector3(impact_index, 0.0, 0.0),
			Vector3.FORWARD,
			1.0
		)
	var reused_ids: Array[int] = []
	for child in manager.get_children():
		if child is BloodImpact:
			reused_ids.append(child.get_instance_id())
	_expect(
		manager.get_impact_pool_count() == 3 and reused_ids == pooled_ids,
		"blood impacts beyond pool capacity must reuse existing nodes",
		failures
	)
	manager.queue_free()
	await process_frame

func _test_demo_map_queues_ground_blood_requests(
	failures: Array[String]
) -> void:
	var arena := DemoMapScene.instantiate()
	root.add_child(arena)
	await process_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	manager.process_mode = Node.PROCESS_MODE_DISABLED
	# 命中特效现在由模拟层的命中事件驱动。改接缝的理由是覆盖面：
	# 远处的僵尸没有节点可打，而一 tick 打死一整片正是帧预算要挡的场景。
	var active_impacts_before := _count_active_impacts(manager)
	var pending_requests_before := manager.get_pending_request_count()
	arena._on_sim_hit_event(_hit_event(false))
	_expect(
		_count_active_impacts(manager) == active_impacts_before + 1,
		"zombie hits must activate the scene-level blood impact pool",
		failures
	)
	arena._on_sim_hit_event(_hit_event(true))
	# 普通命中和击杀各排一条脚底圆形血迹，共 2 条。
	# 断言的是「排队」而不是「立即生成」——立即生成会在尸潮里把一帧顶爆。
	_expect(
		manager.get_pending_request_count() == pending_requests_before + 2,
		"GameplayArena must queue one foot-centered blood pool per hit",
		failures
	)
	arena.queue_free()
	await process_frame

func _hit_event(killed: bool) -> Dictionary:
	return {
		"zombie_id": 1,
		"position": Vector2(1.0, -1.0),
		"height": 1.1,
		"direction": Vector2.RIGHT,
		"damage": 25.0,
		"zone": &"body",
		"killed": killed,
	}

func _count_active_impacts(manager: GroundBloodManager) -> int:
	var active_count := 0
	for child in manager.get_children():
		if child is BloodImpact and (child as BloodImpact).is_active():
			active_count += 1
	return active_count

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
