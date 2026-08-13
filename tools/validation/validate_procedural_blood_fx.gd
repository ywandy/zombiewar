extends SceneTree

const GroundBloodSplatScene = preload("res://scenes/fx/GroundBloodSplat.tscn")
const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const BloodImpactScene = preload("res://scenes/fx/BloodImpact.tscn")
const DemoMapScene = preload("res://scenes/maps/demo/DemoMap.tscn")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_ground_splat_is_texture_free()
	await _test_ground_splat_expands_then_stays_visible()
	_test_blood_impact_contains_only_small_droplets()
	_test_sim_hit_event_includes_zombie_center()
	await _test_merged_ground_splat_retriggers_expansion()
	await _test_arena_queues_one_foot_centered_splat_per_hit()
	await _test_hit_splat_diameter_ranges()
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

func _test_sim_hit_event_includes_zombie_center() -> void:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-12.5, -12.5), 1.0, 25, 25)
	world.reset(20260813)
	world.configure_zombie_profile(0, 50, 1.3)
	world.spawn_zombie(Vector2(4.0, 6.0), 0.0, 0)
	world.apply_zombie_damage(
		0,
		100,
		Vector2(1.0, -1.0),
		1.1,
		Vector2.RIGHT,
		&"body"
	)
	_check("an applied hit must emit one hit event", world.tick_hit_events.size() == 1)
	if world.tick_hit_events.size() == 1:
		var event: Dictionary = world.tick_hit_events[0]
		_check(
			"hit events must carry the zombie entity center separately from the body hit",
			event.get("zombie_position") == Vector2(4.0, 6.0)
		)

func _test_merged_ground_splat_retriggers_expansion() -> void:
	var manager := GroundBloodManagerScript.new() as GroundBloodManager
	manager.max_layers_per_cell = 1
	root.add_child(manager)
	var first := manager.place_splat(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 2.4,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	first.call("_process", 0.30)
	var size_before_merge := first.current_size
	var base_size_before_merge := first.base_size
	var position_before_merge := first.position
	var normal_before_merge := first.current_surface_normal
	var tint_before_merge := first.current_tint
	var edge_tint_before_merge := first.current_edge_tint
	var merged := manager.place_splat(
		Vector3(0.1, 0.0, 0.1),
		Vector3.UP,
		Vector2.ONE * 2.6,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	_check("a full cell must merge into its existing layer", merged == first)
	_check(
		"a repeated hit must restart the merged layer from its center",
		is_equal_approx(merged.expansion_progress, 0.0)
	)
	_check(
		"retriggering expansion must not shrink the merged blood pool",
		merged.current_size.x >= size_before_merge.x and
		merged.current_size.y >= size_before_merge.y
	)
	_check(
		"retriggering expansion must preserve the original pool geometry and tints",
		merged.base_size == base_size_before_merge and
		merged.position == position_before_merge and
		merged.current_surface_normal == normal_before_merge and
		merged.current_tint != Color.WHITE and
		merged.current_tint.r <= tint_before_merge.r and
		merged.current_edge_tint.r <= edge_tint_before_merge.r
	)
	merged.call("_process", 0.30)
	_check(
		"a retriggered blood pool must complete another 0.30 second expansion",
		is_equal_approx(merged.expansion_progress, 1.0) and merged.visible
	)
	manager.queue_free()
	await process_frame

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
		"persistent blood must use the simulated zombie center instead of the body hit",
		normal_request["position"] == Vector3(4.0, 0.0, 6.0)
	)
	_check("the kill request must carry its stronger visual tier", bool(kill_request["killed"]))
	arena.queue_free()
	await process_frame

func _test_hit_splat_diameter_ranges() -> void:
	var arena := DemoMapScene.instantiate()
	root.add_child(arena)
	await process_frame
	await physics_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	var normal := manager.spawn_hit_splat(Vector3(-4.0, 0.0, 4.0), 1.0, false)
	var killed := manager.spawn_hit_splat(Vector3(4.0, 0.0, 4.0), 1.0, true)
	_check("normal hits must find the demo map blood surface", normal != null)
	_check("killing hits must find the demo map blood surface", killed != null)
	if normal != null:
		_check(
			"normal hit diameter must stay within 2.40 to 2.80 meters",
			normal.base_size.x >= 2.40 and normal.base_size.x <= 2.80 and
			normal.base_size.y >= 2.40 and normal.base_size.y <= 2.80
		)
	if killed != null:
		_check(
			"killing hit diameter must stay within 2.80 to 3.20 meters",
			killed.base_size.x >= 2.80 and killed.base_size.x <= 3.20 and
			killed.base_size.y >= 2.80 and killed.base_size.y <= 3.20
		)
	arena.queue_free()
	await process_frame

func _hit_event(killed: bool) -> Dictionary:
	return {
		"zombie_id": 1,
		"position": Vector2(1.0, -1.0),
		"zombie_position": Vector2(4.0, 6.0),
		"height": 1.1,
		"direction": Vector2.RIGHT,
		"damage": 25.0,
		"zone": &"body",
		"killed": killed,
	}

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
