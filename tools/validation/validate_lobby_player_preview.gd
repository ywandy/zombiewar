extends SceneTree

const PREVIEW_SCENE_PATH := "res://scenes/menu/LobbyPlayerPreview.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(PREVIEW_SCENE_PATH), "LobbyPlayerPreview scene must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(PREVIEW_SCENE_PATH) as PackedScene
	var preview = scene.instantiate()
	root.add_child(preview)
	await process_frame
	var character_model := preview.get_node_or_null("ModelAnchor/CharacterModel")
	_expect(character_model != null, "preview must instantiate the real character GLTF", failures)
	if character_model != null:
		_expect(character_model.scene_file_path == "res://scenes/player/PlayerVisual.tscn", "preview character must come from the decoupled player visual scene", failures)
		_expect(character_model.find_child("AnimationPlayer", true, false) is AnimationPlayer, "real character preview must contain AnimationPlayer", failures)
		# 待机动画必须**循环**。GLTF 导进来的 Idle_Gun 是 loop_mode = NONE：
		# 长 1 秒、播完停死在最后一帧，而它幅度只有 0.034，停住就和静态图一样。
		var animation_player := character_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if animation_player != null:
			_expect(animation_player.is_playing(), "预览必须正在播放待机动画", failures)
			var playing := animation_player.get_animation(animation_player.current_animation)
			_expect(
				playing != null and playing.loop_mode != Animation.LOOP_NONE,
				"待机动画必须循环，否则一秒后就停死在最后一帧",
				failures
			)
			# 循环必须开在副本上：原来那份 Animation 由整个 GLTF 共享，
			# 直接改它会顺带把游戏里玩家角色的待机也改掉。
			var source := animation_player.get_animation(&"Idle_Gun")
			_expect(
				source != null and source.loop_mode == Animation.LOOP_NONE,
				"不得就地修改 GLTF 自带的 Idle_Gun，它是共享资源",
				failures
			)
		# 这个 GLTF 的正面朝 +Z，不是 Godot 惯例的 -Z：给 ModelAnchor 加 180°
		# 会让角色背对镜头。远景相机下看不出来，放大到座位卡尺寸就很明显。
		var model_anchor := preview.get_node("ModelAnchor") as Node3D
		_expect(
			is_zero_approx(model_anchor.rotation.y),
			"ModelAnchor 不得旋转，否则角色背对镜头",
			failures
		)
		var smg := character_model.find_child("SMGVisual", true, false) as Node3D
		_expect(smg != null and smg.visible, "preview must show the independently bound SMG", failures)
		var socket := character_model.find_child("WeaponSocket.L", true, false) as Node3D
		if socket == null:
			socket = character_model.find_child("WeaponSocket_L", true, false) as Node3D
		_expect(socket != null and smg != null and smg.get_parent() == socket, "preview SMG must be parented to WeaponSocket.L", failures)

	_expect(preview.find_children("*", "CollisionShape3D", true, false).is_empty(), "preview must not contain collision shapes", failures)
	_expect(preview.find_child("EquipmentController", true, false) == null, "preview must not contain EquipmentController", failures)
	_expect(preview.find_child("HealthBar3D", true, false) == null, "preview must not contain HealthBar3D", failures)
	preview.set_player_index(1)
	_expect((preview.get_node("PlayerLabel") as Label3D).text == "P2", "preview must display its player number", failures)
	var light := preview.get_node("PlayerLight") as OmniLight3D
	var label := preview.get_node("PlayerLabel") as Label3D
	# 配色是四个人唯一的区分手段，它必须真的落到灯光和名牌上。
	var accent := Color(0.243, 0.553, 0.925, 1.0)
	preview.set_accent_color(accent)
	_expect(light.light_color.is_equal_approx(accent), "accent color must reach the preview light", failures)
	_expect(
		label.outline_modulate.is_equal_approx(accent),
		"accent color must reach the label outline",
		failures
	)
	var online_energy := light.light_energy
	preview.set_online(false)
	_expect(light.light_energy < online_energy, "offline preview must be visibly dimmer", failures)
	# 变暗走的是 energy 与 modulate，不能把配色一起洗掉。
	_expect(
		light.light_color.is_equal_approx(accent),
		"going offline must not discard the accent color",
		failures
	)
	preview.set_label_visible(false)
	_expect(not label.visible, "preview label must be hideable for card layouts", failures)
	preview.set_label_visible(true)
	preview.queue_free()
	await process_frame

	var lobby_scene := load("res://scenes/menu/LocalMultiplayerLobby.tscn") as PackedScene
	var lobby = lobby_scene.instantiate()
	root.add_child(lobby)
	await process_frame
	_expect(lobby.get_node_or_null("LobbyWorld/Slots/P1/LobbyPlayerPreview") == null, "empty lobby slot must not contain a character preview", failures)
	lobby.join_state.try_join(0)
	lobby._sync_slots()
	_expect(lobby.get_node_or_null("LobbyWorld/Slots/P1/LobbyPlayerPreview") != null, "joined lobby slot must instantiate a character preview", failures)
	lobby.queue_free()
	await process_frame

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_lobby_player_preview: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
