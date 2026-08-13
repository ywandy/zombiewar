extends SceneTree

const RawInputSource = preload("res://tools/validation/support/raw_input_source.gd")
const FakePlaceItemService = preload("res://tools/validation/support/fake_place_item_service.gd")
const PlayerFixture = preload("res://tools/validation/support/player_fixture.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load("res://scenes/player/Player.tscn") as PackedScene
	_expect(scene != null, "Player scene must load", failures)
	if scene == null:
		_finish(failures)
		return
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	var player = scene.instantiate()
	PlayerFixture.apply_default_character(player)
	root.add_child(player)
	await process_frame
	player.set_physics_process(false)
	var source := RawInputSource.new()
	player.set_input_source(source)
	_expect(player.get_input_source() == source, "Player must retain injected input source", failures)
	var equipment = player.get_node("EquipmentController")
	_expect(equipment.get_current_display_name() == "手枪", "Player must start with the owned pistol", failures)

	source.next_pressed = true
	player._physics_process(0.016)
	_expect(equipment.get_current_display_name() == "匕首", "next edge must skip the unowned smg", failures)
	player._physics_process(0.016)
	_expect(equipment.get_current_display_name() == "匕首", "held next input must not switch repeatedly", failures)

	source.next_pressed = false
	player._physics_process(0.016)
	equipment.equip_slot(0)
	source.use_pressed = true
	player._physics_process(0.016)
	var weapon = equipment.get_current_weapon()
	_expect(weapon != null and weapon.trigger_pressed, "use input must reach current weapon", failures)

	var place_service := FakePlaceItemService.new()
	player.set_place_item_service(place_service)
	equipment.grant_item(&"oil_barrel", 1)
	# 按 item_id 取槽位而不是写死索引：loadout 每加一把枪，油桶的槽号就会后移，
	# 写死索引时脚本会拿到旁边那件装备并在属性访问上直接崩掉——崩在这里还不会
	# 走到 quit()，进程挂住，整批验证跟着一起超时。
	var oil_slot: int = equipment.get_slot_for_item(&"oil_barrel")
	_expect(oil_slot >= 0, "oil barrel must exist in the loadout", failures)
	equipment.equip_slot(oil_slot)
	var placeable = equipment.get_current_item()
	_expect(placeable.place_item_service == place_service, "place item service must reach placeable equipment", failures)

	var property_names: Array[StringName] = []
	for property in player.get_property_list():
		property_names.append(property["name"])
	for removed_property in [
		&"place_item_action",
		&"primary_attack_action",
		&"pistol_action",
		&"rifle_action",
		&"knife_action",
		&"slot_four_action",
	]:
		_expect(not property_names.has(removed_property), "%s must be removed from Player input API" % removed_property, failures)
	_expect(not player.has_signal("place_item_requested"), "legacy place_item_requested signal must be removed", failures)

	player.queue_free()
	camera.queue_free()
	await process_frame
	place_service.free()
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_single_player_input_wiring: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
