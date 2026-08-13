extends SceneTree

## 诊断：打印枪口链路各环节的世界坐标/朝向，定位「火光偏上」的偏差来源。
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/debug_muzzle_positions.gd

const PlayerScene := preload("res://scenes/player/Player.tscn")
const PlayerFixture := preload("res://tools/validation/support/player_fixture.gd")

func _initialize() -> void:
	var player := PlayerScene.instantiate()
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	await process_frame
	await process_frame

	var equipment := player.get_node_or_null("EquipmentController")
	var weapon: RangedWeapon = null
	for child in equipment.find_children("*", "RangedWeapon", true, false):
		weapon = child
		break
	if weapon == null:
		printerr("no ranged weapon")
		quit(1)
		return

	var clearance := player.get_node_or_null("WeaponClearanceController")
	var weapon_collision := player.get_node_or_null("WeaponCollision")
	var muzzle: Marker3D = weapon.muzzle
	var anchor: Node3D = weapon.visual_anchor

	print("=== weapon: %s ===" % weapon.definition.weapon_id)
	print("  player yaw (deg)               %.1f" % rad_to_deg(player.rotation.y))
	_p("player(global)", player.global_position)
	_p("FunctionalRayOrigin", (player.get_node("FunctionalRayOrigin") as Node3D).global_position)
	_p("WeaponCollision center", (weapon_collision as Node3D).global_position)
	if clearance != null:
		_p("clearance.get_weapon_muzzle_origin", clearance.get_weapon_muzzle_origin(Vector3.ZERO))
		_p("  capsule -Y (barrel) dir", -(weapon_collision as Node3D).global_basis.y.normalized())
	_p("weapon.get_ray_origin()", weapon.get_ray_origin())
	_p("visual_anchor pos", anchor.global_position)
	_p("visual_anchor fwd(-Z)", -anchor.global_basis.z.normalized())
	_p("visual_anchor fwd flat", WeaponMath.flat_direction(-anchor.global_basis.z))

	var origin := weapon._sync_muzzle_to_weapon_front()
	_p(">>> synced muzzle pos", muzzle.global_position)
	_p(">>> synced muzzle -Z", -muzzle.global_basis.z.normalized())
	_p(">>> returned origin", origin)

	# MuzzleFlash quad：父节点 Muzzle，子节点 Flash MeshInstance3D
	var flash_mesh := muzzle.get_node_or_null("MuzzleFlash/Flash") as MeshInstance3D
	if flash_mesh != null:
		_p("MuzzleFlash node pos", (muzzle.get_node("MuzzleFlash") as Node3D).global_position)
		_p("Flash quad local pos", flash_mesh.position)
		_p("Flash quad global pos", flash_mesh.global_position)
		print("  Flash quad cast_shadow=%d" % int(flash_mesh.cast_shadow))
		var q := flash_mesh.mesh as QuadMesh
		if q != null:
			print("  quad size=%s orientation=%s" % [q.size, q.orientation])

	quit(0)


func _p(label: String, v: Vector3) -> void:
	print("  %-34s (%.3f, %.3f, %.3f)" % [label, v.x, v.y, v.z])
