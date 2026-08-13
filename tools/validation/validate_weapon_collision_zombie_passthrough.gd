extends SceneTree

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const PlayerFixture := preload("res://tools/validation/support/player_fixture.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	var player := PLAYER_SCENE.instantiate() as PlayerController
	PlayerFixture.apply_default_character(player)
	_expect(player != null, "Player scene must instantiate", failures)
	if player == null:
		_finish(failures)
		return

	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	var clearance := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var normal_probe := player.get_node_or_null(
		"WeaponClearanceController/NormalProbe"
	) as ShapeCast3D
	var raised_probe := player.get_node_or_null(
		"WeaponClearanceController/RaisedProbe"
	) as ShapeCast3D

	_expect(
		weapon_collision != null,
		"Player must retain weapon capsule metadata",
		failures
	)
	_expect(
		clearance != null,
		"Player must retain weapon clearance controller",
		failures
	)
	_expect(
		normal_probe != null,
		"Player must retain normal clearance probe",
		failures
	)
	_expect(
		raised_probe != null,
		"Player must retain raised clearance probe",
		failures
	)
	if weapon_collision != null:
		_expect(
			weapon_collision.disabled,
			"weapon capsule must start disabled so zombies can cross its space",
			failures
		)

	root.add_child(player)
	await process_frame
	await physics_frame
	player.set_process(false)
	player.set_physics_process(false)

	_expect(
		player.collision_layer == 2,
		"player must remain on collision layer 2",
		failures
	)
	_expect(
		player.collision_mask == 9,
		"player body must keep colliding with world and ZombieBlocker layers",
		failures
	)
	if weapon_collision != null:
		_expect(
			weapon_collision.disabled,
			"binding a ranged weapon must not add its capsule to player collision",
			failures
		)
		_expect(
			weapon_collision.shape is CapsuleShape3D,
			"disabled weapon capsule must retain its shape for muzzle math",
			failures
		)
	if normal_probe != null:
		_expect(
			normal_probe.collision_mask == 1,
			"normal probe must only query world layer 1",
			failures
		)
	if raised_probe != null:
		_expect(
			raised_probe.collision_mask == 1,
			"raised probe must only query world layer 1",
			failures
		)
	if clearance != null:
		var fallback := Vector3(99.0, 99.0, 99.0)
		_expect(
			not clearance.get_weapon_muzzle_origin(fallback).is_equal_approx(fallback),
			"disabled weapon capsule must still provide the muzzle endpoint",
			failures
		)

	var zombie_blocker := _create_zombie_blocker()
	root.add_child(zombie_blocker)
	await physics_frame
	zombie_blocker.global_position = Vector3(0.0, 0.0, -1.55)
	await physics_frame
	_expect(
		not player.test_move(
			player.global_transform,
			Vector3(0.0, 0.0, -0.1)
		),
		"zombie blocker inside weapon space must not stop player movement",
		failures
	)
	zombie_blocker.global_position = Vector3(0.0, 0.0, -1.0)
	await physics_frame
	_expect(
		player.test_move(
			player.global_transform,
			Vector3(0.0, 0.0, -0.1)
		),
		"zombie blocker entering body range must still stop player movement",
		failures
	)

	zombie_blocker.queue_free()
	player.queue_free()
	camera.queue_free()
	await process_frame
	_finish(failures)

func _create_zombie_blocker() -> StaticBody3D:
	var blocker := StaticBody3D.new()
	blocker.collision_layer = 8
	blocker.collision_mask = 0
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 1.9
	collision.position = Vector3(0.0, 0.95, 0.0)
	collision.shape = capsule
	blocker.add_child(collision)
	return blocker

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_weapon_collision_zombie_passthrough: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
