extends SceneTree

## RoomClient 的大厅消息校验。不开 socket——这些断言问的是「消息长什么样」
## 和「收到消息后本机状态变成什么」，两者都不需要一台真服务器。
##
## join_payload 单独可断言这一点是既有设计（见 room_client.gd 里的注释）：
## 握手里少报一个字段，服务端就少知道一件事，而这类错误不会当场炸。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_room_client_lobby_messages.gd

const RoomClientScript = preload("res://scripts/net/room_client.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var client = RoomClientScript.new()
	root.add_child(client)
	await process_frame

	client.connect_to_room("ABCDEF", "token-1", "阿波", &"female_medic")
	var payload: Dictionary = client.join_payload()
	_expect(
		int(payload.get("protocol_version", -1)) == LobbyProtocolScript.PROTOCOL_VERSION,
		"握手必须带当前协议版本",
		failures
	)
	_expect(
		String(payload.get("character_id", "")) == "female_medic",
		"握手必须带入房时选定的角色 id，实际 %s" % String(payload.get("character_id", "")),
		failures
	)
	_expect(
		int(payload.get("resume_tick", 0)) == -1,
		"未消费过帧时 resume_tick 必须是 -1",
		failures
	)

	# roster 携带的 map_id 必须落到本机状态上，而且要在 roster_changed 发出**之前**
	# 落好：面板是在那个信号里读 room_map_id 的，晚一步就会画上一次的地图。
	# 用字典接住信号里读到的值：GDScript 的 lambda 按**值**捕获局部变量，
	# 直接写一个 String 局部变量只会改到 lambda 自己那份副本。字典是引用类型。
	var observed := {"roster_map_id": "", "started_map_id": "", "started_slots": []}
	client.roster_changed.connect(
		func(_players, _host_slot, _state): observed["roster_map_id"] = client.room_map_id
	)
	client._handle_packet(JSON.stringify({
		"type": "roster",
		"state": "lobby",
		"host_slot": 0,
		"map_id": "demo",
		"players": [
			{
				"slot": 0,
				"player_id": "p0",
				"nickname": "阿波",
				"ready": false,
				"connected": true,
				"character_id": "male_assault",
			},
		],
	}).to_utf8_buffer())
	_expect(client.room_map_id == "demo", "roster 的 map_id 必须落到 room_map_id", failures)
	_expect(
		observed["roster_map_id"] == "demo",
		"room_map_id 必须在 roster_changed 发出前就更新，实际 %s" % observed["roster_map_id"],
		failures
	)
	_expect(client.roster.size() == 1, "roster 必须存下座位表", failures)
	_expect(
		String(client.roster[0].get("character_id", "")) == "male_assault",
		"roster 条目必须保留 character_id",
		failures
	)

	# start 同样携带 map_id，并且要在 match_started 发出前落好。
	client.match_started.connect(
		func(_seed, slots):
			observed["started_map_id"] = client.room_map_id
			observed["started_slots"] = slots
	)
	client._handle_packet(JSON.stringify({
		"type": "start",
		"seed": 123,
		"tick": 0,
		"map_id": "demo",
		"slots": [
			{"slot": 0, "nickname": "阿波", "player_id": "p0", "character_id": "male_assault"},
		],
	}).to_utf8_buffer())
	_expect(
		observed["started_map_id"] == "demo",
		"start 的 map_id 必须在 match_started 前落好",
		failures
	)
	var started_slots: Array = observed["started_slots"]
	_expect(
		started_slots.size() == 1 and String(started_slots[0].get("character_id", "")) == "male_assault",
		"match_started 必须透出每个座位的 character_id",
		failures
	)

	# 未连接时发选择请求必须是空操作，而不是崩溃。
	client.select_character(&"female_riot")
	client.select_map(&"demo")
	_expect(
		client.character_id == &"female_riot",
		"select_character 必须记住本机选择，便于重连时随握手重发",
		failures
	)

	client.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_room_client_lobby_messages: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_room_client_lobby_messages: %s" % failure)
	printerr("validate_room_client_lobby_messages: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
