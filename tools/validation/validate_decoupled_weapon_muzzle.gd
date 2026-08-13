extends SceneTree

## 解耦武器的枪口回归：每把独立远程武器必须自带 MuzzleSocket，枪火与可见
## 枪线始终从该挂点出发；伤害与联机输入的功能弹道起点仍由 WeaponCollision 提供。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_decoupled_weapon_muzzle.gd

const PlayerScene := preload("res://scenes/player/Player.tscn")
const SOCKET_NAME := "MuzzleSocket"
const EXPECTED_RANGED_IDS := [&"pistol", &"smg", &"shotgun", &"rifle"]

var failures: Array[String] = []


func _initialize() -> void:
	var player := PlayerScene.instantiate()
	root.add_child(player)
	await process_frame
	await process_frame

	var equipment := player.get_node_or_null("EquipmentController")
	_check("EquipmentController exists", equipment != null)
	if equipment == null:
		_report(player)
		return

	for weapon_id: StringName in EXPECTED_RANGED_IDS:
		var weapon = equipment.get_item_by_id(weapon_id)
		_check("%s: ranged weapon exists" % weapon_id, weapon is RangedWeapon)
		if not weapon is RangedWeapon:
			continue
		_test_weapon(weapon as RangedWeapon, String(weapon_id))

	_report(player)


func _test_weapon(weapon: RangedWeapon, label: String) -> void:
	var visual_anchor := weapon.visual_anchor
	_check(
		"%s: independent visual anchor exists" % label,
		visual_anchor != null and is_instance_valid(visual_anchor)
	)
	if visual_anchor == null or not is_instance_valid(visual_anchor):
		return

	var socket := visual_anchor.find_child(SOCKET_NAME, true, false) as Node3D
	_check("%s: visual model exposes MuzzleSocket" % label, socket != null)
	if socket == null:
		return

	var visual_bounds := _collect_visual_bounds(visual_anchor)
	_check("%s: visual mesh bounds are readable" % label, visual_bounds.size != Vector3.ZERO)
	if visual_bounds.size != Vector3.ZERO:
		var socket_local := visual_anchor.to_local(socket.global_position)
		_check(
			"%s: MuzzleSocket sits beyond the weapon +X front" % label,
			socket_local.x > visual_bounds.end.x
		)
		_check(
			"%s: MuzzleSocket remains inside the barrel Y span" % label,
			socket_local.y >= visual_bounds.position.y and
			socket_local.y <= visual_bounds.end.y
		)
		_check(
			"%s: MuzzleSocket remains inside the barrel Z span" % label,
			socket_local.z >= visual_bounds.position.z and
			socket_local.z <= visual_bounds.end.z
		)

	weapon._process(0.0)
	_check(
		"%s: muzzle flash origin follows MuzzleSocket" % label,
		weapon.muzzle.global_position.distance_to(socket.global_position) < 0.001
	)

	var before := socket.global_position
	visual_anchor.transform = Transform3D(
		Basis(Vector3.UP, 0.37) * visual_anchor.transform.basis,
		visual_anchor.transform.origin + Vector3(0.17, 0.09, -0.11)
	)
	weapon._process(0.0)
	_check("%s: transformed MuzzleSocket moved" % label, socket.global_position != before)
	_check(
		"%s: muzzle flash stays on the transformed weapon front" % label,
		weapon.muzzle.global_position.distance_to(socket.global_position) < 0.001
	)

	var captured_request := {}
	weapon.set_sim_request_sink(func(request: Dictionary) -> void:
		captured_request.assign(request)
	)
	var expected_functional_origin := weapon.get_ray_origin()
	weapon._fire(Vector3.FORWARD)
	_check("%s: firing emits a simulation request" % label, not captured_request.is_empty())
	if not captured_request.is_empty():
		_check(
			"%s: simulation origin remains the functional capsule muzzle" % label,
			(captured_request["origin"] as Vector3).distance_to(expected_functional_origin) < 0.001
		)
	_check(
		"%s: firing leaves the flash on MuzzleSocket" % label,
		weapon.muzzle.global_position.distance_to(socket.global_position) < 0.001
	)

	var tracer_index := weapon.tracer_pool_cursor
	var simulated_origin := expected_functional_origin + Vector3(0.31, -0.17, 0.23)
	var simulated_end := simulated_origin + Vector3(3.0, 0.0, -4.0)
	weapon.show_tracer(simulated_origin, simulated_end)
	var tracer := weapon.tracer_pool[tracer_index]
	var visible_tracer_start := tracer.to_global(Vector3(0.0, 0.0, 0.5))
	var visible_tracer_end := tracer.to_global(Vector3(0.0, 0.0, -0.5))
	_check(
		"%s: visible tracer starts at MuzzleSocket" % label,
		visible_tracer_start.distance_to(socket.global_position) < 0.001
	)
	_check(
		"%s: visible tracer still ends at the simulated hit point" % label,
		visible_tracer_end.distance_to(simulated_end) < 0.001
	)


func _collect_visual_bounds(anchor: Node3D) -> AABB:
	var has_bounds := false
	var min_point := Vector3.ZERO
	var max_point := Vector3.ZERO
	for child in anchor.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var local_to_anchor := anchor.global_transform.affine_inverse() * mesh_instance.global_transform
		var mesh_bounds := mesh_instance.get_aabb()
		for corner_index in range(8):
			var corner := Vector3(
				mesh_bounds.end.x if (corner_index & 1) != 0 else mesh_bounds.position.x,
				mesh_bounds.end.y if (corner_index & 2) != 0 else mesh_bounds.position.y,
				mesh_bounds.end.z if (corner_index & 4) != 0 else mesh_bounds.position.z
			)
			var point := local_to_anchor * corner
			if not has_bounds:
				min_point = point
				max_point = point
				has_bounds = true
			else:
				min_point = min_point.min(point)
				max_point = max_point.max(point)
	return AABB(min_point, max_point - min_point) if has_bounds else AABB()


func _check(label: String, condition: bool) -> void:
	if not condition:
		failures.append(label)
		printerr("  FAIL: %s" % label)


func _report(player: Node) -> void:
	player.queue_free()
	if failures.is_empty():
		print("validate_decoupled_weapon_muzzle: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_decoupled_weapon_muzzle: %s" % failure)
	printerr("validate_decoupled_weapon_muzzle: FAIL (%d)" % failures.size())
	quit(1)
