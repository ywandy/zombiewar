extends SceneTree

## 枪口火光变换的回归：位置必须来自独立武器的 MuzzleSocket，朝向必须与
## WeaponCollision 的功能弹道轴一致，并压平到水平匹配模拟层弹道。
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_muzzle_flash_orientation.gd

const PlayerScene := preload("res://scenes/player/Player.tscn")
const WeaponMathScript := preload("res://scripts/combat/weapon_math.gd")

var failures: Array[String] = []


func _initialize() -> void:
	var player := PlayerScene.instantiate()
	root.add_child(player)
	# 等一帧让 @onready / _ready / bind_context 完成。
	await process_frame
	await process_frame

	var equipment := player.get_node_or_null("EquipmentController")
	if equipment == null:
		failures.append("EquipmentController missing")
		_report()
		return

	var weapon := _find_ranged_weapon(equipment)
	if weapon == null:
		failures.append("no RangedWeapon found in loadout")
		_report()
		return

	# 强制走同步路径一次，模拟开火前的对齐。
	var visual_origin: Vector3 = weapon._sync_muzzle_to_weapon_front()
	var functional_origin: Vector3 = weapon.get_ray_origin()
	_check("visual origin is finite", visual_origin.is_finite())
	_check("functional origin is finite", functional_origin.is_finite())

	var muzzle: Marker3D = weapon.muzzle
	var visual_socket := weapon.visual_anchor.find_child(
		"MuzzleSocket",
		true,
		false
	) as Node3D
	if visual_socket == null:
		failures.append("MuzzleSocket missing from independent weapon model")
		_report()
		return
	var weapon_collision := player.get_node_or_null("WeaponCollision") as CollisionShape3D
	if weapon_collision == null:
		failures.append("WeaponCollision missing")
		_report()
		return

	var barrel_dir := -weapon_collision.global_basis.y.normalized()
	var muzzle_dir := -muzzle.global_basis.z

	_check(
		"muzzle direction matches WeaponCollision barrel axis",
		muzzle_dir.distance_to(barrel_dir) < 0.001,
		"muzzle_dir=%s barrel=%s" % [muzzle_dir, barrel_dir]
	)
	_check(
		"muzzle direction is horizontal (matches flat trajectory)",
		absf(muzzle_dir.y) < 0.001,
		"muzzle_dir.y=%f" % muzzle_dir.y
	)
	_check(
		"muzzle sits at independent weapon MuzzleSocket",
		muzzle.global_position.distance_to(visual_socket.global_position) < 0.001,
		"muzzle_pos=%s socket=%s" % [muzzle.global_position, visual_socket.global_position]
	)

	_report()
	player.queue_free()


func _find_ranged_weapon(equipment: Node) -> RangedWeapon:
	for child in equipment.get_children():
		if child is RangedWeapon:
			return child
	# 有的实现把武器放在别处；递归兜底。
	for child in equipment.find_children("*", "RangedWeapon", true, false):
		return child
	return null


func _check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("  ok: %s" % label)
	else:
		failures.append("%s  %s" % [label, detail])
		printerr("  FAIL: %s  %s" % [label, detail])


func _report() -> void:
	if failures.is_empty():
		print("validate_muzzle_flash_orientation: PASS")
	else:
		for failure in failures:
			printerr("validate_muzzle_flash_orientation: %s" % failure)
		printerr("validate_muzzle_flash_orientation: FAIL (%d)" % failures.size())
	quit(0 if failures.is_empty() else 1)
