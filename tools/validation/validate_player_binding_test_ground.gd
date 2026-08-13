extends SceneTree

const TEST_SCENE := preload("res://scenes/player/PlayerBindingTest.tscn")

func _init() -> void:
	var test_scene := TEST_SCENE.instantiate()
	root.add_child(test_scene)
	await process_frame
	var collision := test_scene.get_node_or_null("GroundBody/CollisionShape3D") as CollisionShape3D
	if collision == null or collision.shape == null:
		push_error("PlayerBindingTest must provide a collidable GroundBody/CollisionShape3D")
		quit(1)
		return
	var player := test_scene.get_node_or_null("Player") as PlayerController
	if player == null or player.get_input_source() == null:
		push_error("PlayerBindingTest must inject a playable input source into Player")
		quit(1)
		return
	print("validate_player_binding_test_ground: PASS")
	quit(0)
