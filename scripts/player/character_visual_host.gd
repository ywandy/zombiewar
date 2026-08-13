extends Node3D
class_name CharacterVisualHost

@export var fallback_scene: PackedScene
var current_model: Node3D

func install(scene: PackedScene) -> Node3D:
	if current_model != null and is_instance_valid(current_model):
		current_model.free()
	current_model = null
	var selected := scene if scene != null else fallback_scene
	if selected == null:
		return null
	current_model = selected.instantiate() as Node3D
	if current_model == null:
		return null
	current_model.name = "CharacterModel"
	add_child(current_model)
	return current_model
