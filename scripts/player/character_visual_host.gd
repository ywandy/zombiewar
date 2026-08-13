extends Node3D
class_name CharacterVisualHost

var current_model: Node3D

func install(scene: PackedScene) -> Node3D:
	if current_model != null and is_instance_valid(current_model):
		current_model.free()
	current_model = null
	if scene == null:
		push_error("CharacterVisualHost requires an explicit character model scene")
		return null
	current_model = scene.instantiate() as Node3D
	if current_model == null:
		return null
	current_model.name = "CharacterModel"
	add_child(current_model)
	return current_model
