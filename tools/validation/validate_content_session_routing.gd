extends SceneTree

## 会话 -> 地图 -> 竞技场这条路由的校验。
##
## 它守的是一件事：竞技场拿到哪张图，只能由 GameSession 里的 map_id 决定，
## 而 map_id 在联机下来自服务端的 start 消息。任何「竞技场自己挑一张图」的回退
## 都是一次静默的分叉——各端会各挑各的。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_content_session_routing.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
const OnlinePlayerDescriptorScript = preload("res://scripts/net/online_player_descriptor.gd")
const LocalPlayerDescriptorScript = preload("res://scripts/input/local_player_descriptor.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var maps = ContentCatalogsScript.maps()
	var characters = ContentCatalogsScript.characters()

	var session = GameSessionScript.new()
	root.add_child(session)
	await process_frame

	session.configure_single()
	_expect(
		session.map_id == maps.default_id(),
		"单机会话必须落在默认地图，实际 %s" % session.map_id,
		failures
	)
	_expect(
		session.local_players.size() == 1,
		"单机会话必须保存显式 P1 描述符",
		failures
	)
	if session.local_players.size() == 1:
		_expect(
			session.local_players[0].character_id == characters.default_id(),
			"直接建立单机会话时必须使用默认角色",
			failures
		)
	var selected_single = LocalPlayerDescriptorScript.new()
	selected_single.character_id = &"female_medic"
	session.configure_single(selected_single)
	_expect(
		session.local_players.size() == 1 and
			session.local_players[0].character_id == &"female_medic",
		"单机会话必须保留大厅选定的角色",
		failures
	)

	var local_descriptor = LocalPlayerDescriptorScript.new()
	_expect(
		local_descriptor.character_id == &"",
		"本地描述符的角色 id 默认为空，由大厅填",
		failures
	)
	local_descriptor.character_id = characters.default_id()
	session.configure_local([local_descriptor])
	_expect(
		session.map_id == maps.default_id(),
		"本地多人会话必须落在默认地图",
		failures
	)

	var online_descriptor = OnlinePlayerDescriptorScript.new()
	online_descriptor.player_index = 0
	online_descriptor.character_id = &"female_medic"
	session.configure_online([online_descriptor], &"demo")
	_expect(session.map_id == &"demo", "联机会话的地图必须来自 start 消息", failures)
	_expect(
		session.local_players[0].character_id == &"female_medic",
		"联机描述符必须带上角色 id",
		failures
	)

	# 两个描述符必须保持同形：LocalPlayerSpawner 靠鸭子类型同时消费它们，
	# 一边有 character_id 另一边没有，联机和本地就会走出两条路。
	_expect(
		"character_id" in online_descriptor and "character_id" in local_descriptor,
		"两个玩家描述符都必须有 character_id 字段",
		failures
	)

	session.clear()
	_expect(
		session.map_id == maps.default_id(),
		"clear() 之后必须回到默认地图而不是空 id",
		failures
	)
	_expect(session.local_players.is_empty(), "clear() 必须清空单机描述符", failures)

	session.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_content_session_routing: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_content_session_routing: %s" % failure)
	printerr("validate_content_session_routing: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
