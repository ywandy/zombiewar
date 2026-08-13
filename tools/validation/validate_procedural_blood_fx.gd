extends SceneTree

const GroundBloodSplatScene = preload("res://scenes/fx/GroundBloodSplat.tscn")
const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const BloodImpactScene = preload("res://scenes/fx/BloodImpact.tscn")
const DemoMapScene = preload("res://scenes/maps/demo/DemoMap.tscn")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_ground_splat_is_texture_free()
	await _test_ground_splat_expands_then_stays_visible()
	_test_blood_impact_contains_only_small_droplets()
	await _test_arena_queues_one_foot_centered_splat_per_hit()
	if failures.is_empty():
		print("validate_procedural_blood_fx: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_ground_splat_is_texture_free() -> void:
	var scene_source := FileAccess.get_file_as_string(
		"res://scenes/fx/GroundBloodSplat.tscn"
	)
	var script_source := FileAccess.get_file_as_string(
		"res://scripts/fx/ground_blood_splat.gd"
	)
	_check(
		"ground blood scene must not reference Kenney splat textures",
		not scene_source.contains("kenney_splat")
	)
	_check(
		"ground blood shader must be procedural instead of sampling a texture",
		not script_source.contains("sampler2D") and
		not script_source.contains("texture(splat_texture")
	)
	_check(
		"ground blood shader must expose radial reveal and edge fading",
		script_source.contains("reveal_radius") and
		script_source.contains("smoothstep")
	)

func _test_ground_splat_expands_then_stays_visible() -> void:
	var splat := GroundBloodSplatScene.instantiate() as GroundBloodSplat
	_check("a pooled ground blood instance must start hidden", not splat.visible)
	root.add_child(splat)
	splat.setup(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	var shared_material_id := splat.material_override.get_instance_id()
	_check("a new ground pool must start at the center", splat.expansion_progress == 0.0)
	splat.call("_process", 0.15)
	_check(
		"ground blood must be mid-expansion after half its duration",
		splat.expansion_progress > 0.0 and splat.expansion_progress < 1.0
	)
	splat.call("_process", 0.20)
	_check(
		"ground blood must finish expansion and remain visible",
		is_equal_approx(splat.expansion_progress, 1.0) and splat.visible
	)
	splat.setup(
		Vector3.ONE,
		Vector3.UP,
		Vector2.ONE * 2.0,
		0.0,
		Color(0.38, 0.004, 0.008, 0.98),
		Color(0.55, 0.01, 0.016, 0.30),
		0.30
	)
	_check(
		"pooled ground blood must reuse the shared procedural material",
		splat.material_override.get_instance_id() == shared_material_id
	)
	splat.queue_free()
	await process_frame

func _test_blood_impact_contains_only_small_droplets() -> void:
	var impact := BloodImpactScene.instantiate() as BloodImpact
	var droplets := impact.get_node_or_null("Droplets") as GPUParticles3D
	_check("blood impact must remove the textured Splat node", impact.get_node_or_null("Splat") == null)
	_check("blood impact must keep a droplet particle node", droplets != null)
	if droplets != null:
		_check("blood impact must emit exactly 9 droplets", droplets.amount == 9)
	impact.free()

func _test_arena_queues_one_foot_centered_splat_per_hit() -> void:
	var arena := DemoMapScene.instantiate()
	root.add_child(arena)
	await process_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	manager.process_mode = Node.PROCESS_MODE_DISABLED
	var before := manager.get_pending_request_count()
	arena._on_sim_hit_event(_hit_event(false))
	arena._on_sim_hit_event(_hit_event(true))
	_check(
		"normal and killing hits must queue exactly one persistent pool each",
		manager.get_pending_request_count() == before + 2
	)
	var normal_request: Dictionary = manager.pending_requests[before]
	var kill_request: Dictionary = manager.pending_requests[before + 1]
	_check(
		"persistent blood must use zombie feet instead of body hit height",
		normal_request["position"] == Vector3(1.0, 0.0, -1.0)
	)
	_check("the kill request must carry its stronger visual tier", bool(kill_request["killed"]))
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

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
