extends RefCounted
class_name WeaponVisualBinding

var model_instance: Node3D
var socket: Node3D
var warned_missing_socket := false
var warned_missing_model := false

func bind(
	visual_root: Node3D,
	model_scene: PackedScene,
	socket_name: StringName,
	relative_transform: Transform3D
) -> Node3D:
	if model_instance != null and is_instance_valid(model_instance):
		model_instance.queue_free()
	model_instance = null
	socket = null
	if visual_root == null or not is_instance_valid(visual_root):
		_warn_missing_socket("visual root is invalid")
		return null
	if model_scene == null:
		_warn_missing_model()
		return null
	socket = _find_socket(visual_root, socket_name)
	if socket == null:
		_warn_missing_socket("socket '%s' was not found" % String(socket_name))
		return null
	model_instance = model_scene.instantiate() as Node3D
	if model_instance == null:
		_warn_missing_model()
		return null
	var model_name := model_scene.resource_path.get_file().get_basename()
	model_instance.name = "%sVisual" % model_name if not model_name.is_empty() else "%sVisual" % model_instance.name
	socket.add_child(model_instance)
	model_instance.transform = relative_transform
	return model_instance

func _find_socket(visual_root: Node3D, socket_name: StringName) -> Node3D:
	var exact := visual_root.find_child(String(socket_name), true, false) as Node3D
	if exact != null:
		return exact
	# Godot's glTF importer sanitizes Blender names containing dots to underscores
	# (WeaponSocket.L -> WeaponSocket_L). Keep the authored socket id in resources,
	# but accept the importer spelling at runtime.
	var imported_name := String(socket_name).replace(".", "_")
	return visual_root.find_child(imported_name, true, false) as Node3D

func set_visible(value: bool) -> void:
	if model_instance != null and is_instance_valid(model_instance):
		model_instance.visible = value

func _warn_missing_socket(reason: String) -> void:
	if warned_missing_socket:
		return
	warned_missing_socket = true
	push_warning("Weapon visual binding skipped: %s" % reason)

func _warn_missing_model() -> void:
	if warned_missing_model:
		return
	warned_missing_model = true
	push_warning("Weapon visual binding skipped: model scene is missing or invalid")
