extends SceneTree

const PlayerFixture = preload("res://tools/validation/support/player_fixture.gd")

const BOUNDS_PATH := "res://scripts/camera/player_screen_bounds.gd"
const PlayerScene = preload("res://scenes/player/Player.tscn")
const RawInputSource = preload("res://tools/validation/support/raw_input_source.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(BOUNDS_PATH), "PlayerScreenBounds script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return
	var bounds = load(BOUNDS_PATH)
	var camera_scene := load("res://scenes/camera/FollowCamera.tscn") as PackedScene
	var follow = camera_scene.instantiate()
	root.add_child(follow)
	await process_frame
	var camera := follow.get_node("VisualOffset/Camera3D") as Camera3D
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var margin := viewport_size * 0.10
	var safe_rect := Rect2(margin, viewport_size - margin * 2.0)
	var center_screen := viewport_size * 0.5
	var center_world: Vector3 = bounds.screen_to_plane(camera, center_screen, 0.0)
	var center_motion := Vector3(1.0, 0.0, 0.0)
	_expect(bounds.limit_motion(camera, center_world, center_motion, 0.10).is_equal_approx(center_motion), "screen-center motion must remain unchanged", failures)

	var right_screen := Vector2(safe_rect.end.x, center_screen.y)
	var right_world: Vector3 = bounds.screen_to_plane(camera, right_screen, 0.0)
	var outward_world: Vector3 = bounds.screen_to_plane(camera, right_screen + Vector2(100.0, 0.0), 0.0) - right_world
	var outward_limited: Vector3 = bounds.limit_motion(camera, right_world, outward_world, 0.10)
	_expect(outward_limited.length() < outward_world.length() * 0.05, "motion beyond right safe edge must be clipped", failures)

	var along_world: Vector3 = bounds.screen_to_plane(camera, right_screen + Vector2(0.0, 45.0), 0.0) - right_world
	_expect(bounds.limit_motion(camera, right_world, along_world, 0.10).is_equal_approx(along_world), "motion along right safe edge must remain", failures)
	var inward_world: Vector3 = bounds.screen_to_plane(camera, right_screen - Vector2(80.0, 0.0), 0.0) - right_world
	_expect(bounds.limit_motion(camera, right_world, inward_world, 0.10).is_equal_approx(inward_world), "motion back toward screen center must remain", failures)
	_expect(bounds.limit_motion(camera, right_world, outward_world, 0.10).is_equal_approx(outward_limited), "knockback must use the same deterministic limiter as ordinary motion", failures)

	var anchor := Vector3(4.0, 0.0, -2.0)
	var inside := Vector3(4.0, 0.0, -2.0)
	var free_motion := Vector3(1.0, 0.0, 1.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			anchor,
			inside,
			free_motion,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).is_equal_approx(free_motion),
		"world rect must not clip motion near the anchor",
		failures
	)
	var edge := Vector3(
		anchor.x + bounds.ONLINE_BOUNDS_HALF_WIDTH,
		0.0,
		anchor.z + bounds.ONLINE_BOUNDS_HALF_DEPTH
	)
	var outward := Vector3(3.0, 0.0, 3.0)
	var clipped: Vector3 = bounds.limit_motion_in_world_rect(
		anchor,
		edge,
		outward,
		bounds.ONLINE_BOUNDS_HALF_WIDTH,
		bounds.ONLINE_BOUNDS_HALF_DEPTH
	)
	_expect(
		clipped.is_equal_approx(Vector3.ZERO),
		"world rect must clip motion that leaves the fixed rectangle",
		failures
	)
	var inward := Vector3(-2.0, 0.0, -2.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			anchor,
			edge,
			inward,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).is_equal_approx(inward),
		"world rect must allow motion back toward the anchor",
		failures
	)
	var shifted_anchor := anchor + Vector3(5.0, 0.0, 0.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			shifted_anchor,
			edge,
			outward,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).x > 0.0,
		"the world rect must travel with the shared camera anchor",
		failures
	)
	var player_probe = PlayerScene.instantiate()
	PlayerFixture.apply_default_character(player_probe)
	root.add_child(player_probe)
	player_probe.set_physics_process(false)
	_expect(
		player_probe.has_method("set_world_bounds_anchor"),
		"PlayerController must accept a world bounds anchor",
		failures
	)
	_expect(
		not player_probe.uses_world_bounds(),
		"single player must keep the screen-space bounds",
		failures
	)
	player_probe.queue_free()

	var player = PlayerScene.instantiate()
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	player.set_physics_process(false)
	_expect(player.has_method("set_screen_camera"), "PlayerController must accept the shared screen camera", failures)
	if player.has_method("set_screen_camera"):
		var source := RawInputSource.new()
		player.set_input_source(source)
		player.set_movement_camera(camera)
		player.set_screen_camera(camera)
		player.screen_safe_margin_ratio = 0.10
		player.global_position = right_world
		source.move = Vector2.RIGHT
		player._physics_process(0.1)
		_expect(camera.unproject_position(player.global_position).x <= safe_rect.end.x + 0.01, "PlayerController ordinary movement must stay inside safe edge", failures)
		player.global_position = right_world
		source.move = Vector2.ZERO
		player.knockback_velocity = outward_world.normalized() * 10.0
		player._physics_process(0.1)
		_expect(camera.unproject_position(player.global_position).x <= safe_rect.end.x + 0.01, "PlayerController knockback must stay inside safe edge", failures)
	player.queue_free()
	follow.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_player_screen_bounds: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
