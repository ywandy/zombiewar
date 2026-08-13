extends SceneTree

const DescriptorScript = preload("res://scripts/input/local_player_descriptor.gd")
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var session = root.get_node("GameSession")
	var selected_single = _descriptor(DescriptorScript.SourceKind.KEYBOARD_WASD)
	selected_single.character_id = &"female_medic"
	session.configure_single(selected_single)
	var single_arena = await _spawn_arena()
	_validate_players(single_arena, 1, failures)
	if (
		single_arena != null and
		single_arena.get_node_or_null("Players") != null and
		single_arena.get_node("Players").get_child_count() > 0
	):
		var single_player = single_arena.get_node("Players").get_child(0)
		_expect(single_player.get_input_source() == single_arena.single_player_input, "single-player spawn must reuse GameplayArena composite input", failures)
		_expect(
			single_player.character_definition != null and
				single_player.character_definition.character_id == &"female_medic",
			"single-player spawn must apply its explicit character id",
			failures
		)
	await _free_arena(single_arena)

	session.configure_local([
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_WASD),
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_ARROWS),
	])
	var two_player_arena = await _spawn_arena()
	_validate_players(two_player_arena, 2, failures)
	await _free_arena(two_player_arena)

	session.configure_local([
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_WASD),
		_descriptor(DescriptorScript.SourceKind.KEYBOARD_ARROWS),
		_descriptor(DescriptorScript.SourceKind.GAMEPAD, 0),
		_descriptor(DescriptorScript.SourceKind.GAMEPAD, 1),
	])
	var four_player_arena = await _spawn_arena()
	_validate_players(four_player_arena, 4, failures)
	if four_player_arena != null and four_player_arena.get_node_or_null("Players") != null:
		var input_ids: Dictionary = {}
		for player in four_player_arena.get_node("Players").get_children():
			input_ids[player.get_input_source().get_instance_id()] = true
		_expect(input_ids.size() == 4, "local multiplayer must create a unique input source per player", failures)
		var controls := four_player_arena.get_node("HUD/ControlsPanel/Controls") as Label
		_expect(controls.text == "键盘：WASD 移动 / Q E 切换 / Space 使用 | 方向键移动 / < > 切换 / / 使用\n手柄：LS 移动 / LB RB 切换 / RT 使用", "desktop controls must use the fixed two-line instructions", failures)
	await _free_arena(four_player_arena)

	var invalid = _descriptor(DescriptorScript.SourceKind.KEYBOARD_WASD)
	var invalid_second = _descriptor(999)
	session.configure_local([invalid, invalid_second])
	var invalid_arena = await _spawn_arena()
	if invalid_arena != null and invalid_arena.get_node_or_null("Players") != null:
		_expect(invalid_arena.get_node("Players").get_child_count() == 0, "failed session spawn must leave no partial players", failures)
	_expect(not session.last_error.is_empty(), "failed session spawn must report GameSession.last_error", failures)
	await _free_arena(invalid_arena)

	session.clear()
	_finish(failures)

func _spawn_arena():
	var scene := load("res://scenes/maps/demo/DemoMap.tscn") as PackedScene
	if scene == null:
		return null
	var arena = scene.instantiate()
	root.add_child(arena)
	await process_frame
	return arena

func _free_arena(arena) -> void:
	if arena != null:
		arena.queue_free()
		await process_frame

func _descriptor(source_kind: int, device_id: int = -1):
	var descriptor = DescriptorScript.new()
	descriptor.source_kind = source_kind
	descriptor.gamepad_device_id = device_id
	descriptor.character_id = ContentCatalogsScript.characters().default_id()
	return descriptor

func _validate_players(arena, expected_count: int, failures: Array[String]) -> void:
	_expect(arena != null, "DemoMap scene must load", failures)
	if arena == null:
		return
	var container: Node = arena.get_node_or_null("Players")
	_expect(container != null, "GameplayArena must contain Players container", failures)
	if container == null:
		return
	_expect(
		container.get_child_count() == expected_count,
		"GameplayArena must spawn %d player(s)" % expected_count,
		failures
	)
	for index in range(container.get_child_count()):
		var player = container.get_child(index)
		_expect(player.player_index == index, "spawned player must retain sequential player index", failures)
		_expect(player.collision_layer == 2, "spawned players must remain on collision layer 2", failures)
		_expect(player.collision_mask == 9, "spawned players must collide with world layer 1 and zombie blocker layer 4", failures)
		_expect(player.get_input_source() != null, "spawned player must receive an input source", failures)
		var equipment_label := player.get_node_or_null("PlayerEquipmentLabel") as Label3D
		_expect(equipment_label != null, "spawned player must contain persistent equipment label", failures)
		if equipment_label != null:
			var display_name: String = player.equipment.get_current_display_name()
			var count_text: String = player.equipment.get_current_count_text()
			_expect(player.equipment.get_current_item() != null, "spawned player must start with an available equipment item", failures)
			var character_prefix := ""
			if player.character_definition != null:
				character_prefix = "[%s] " % player.character_definition.display_name
			var expected_text := "P%d · %s%s" % [index + 1, character_prefix, display_name]
			if not count_text.is_empty():
				expected_text += ":%s" % count_text
			_expect(equipment_label.text == expected_text, "equipment label must initialize with player number and current equipment, expected \"%s\" but got \"%s\"" % [expected_text, equipment_label.text], failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_player_spawning: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
