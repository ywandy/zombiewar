extends SceneTree

const CHARACTER_IDS: Array[StringName] = [
	&"male_assault", &"female_assault",
	&"male_gunner", &"female_gunner",
	&"male_medic", &"female_medic",
	&"male_demolition", &"female_demolition",
	&"male_riot", &"female_riot",
]
const WEAPON_IDS: Array[StringName] = [
	&"rpg", &"ak47", &"m4a1", &"tactical_knife", &"hk45c", &"landmine", &"mp5",
]
const REQUIRED_ANIMATIONS: Array[StringName] = [
	&"Death", &"Duck", &"HitReact", &"Idle", &"Idle_Gun",
	&"Jump", &"Jump_Idle", &"Jump_Land", &"No", &"Punch",
	&"Run", &"Run_Gun", &"Run_Slash", &"Run_Stab", &"Slash",
	&"Stab", &"Walk", &"Walk_Gun", &"Wave", &"Yes",
]
const REQUIRED_SOCKETS: Array[StringName] = [
	&"WeaponHandSocket", &"WeaponBackSocket", &"MineHipSocket",
]

var failures: Array[String] = []


func _initialize() -> void:
	for character_id in CHARACTER_IDS:
		_validate_character(character_id)
	for weapon_id in WEAPON_IDS:
		_validate_weapon(weapon_id)
	if failures.is_empty():
		print("validate_generated_character_models: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_generated_character_models: %s" % failure)
	printerr("validate_generated_character_models: FAIL (%d)" % failures.size())
	quit(1)


func _validate_character(character_id: StringName) -> void:
	var path := "res://assets/characters/generated/%s.glb" % character_id
	var scene := load(path) as PackedScene
	_expect(scene != null, "%s must load as PackedScene" % path)
	if scene == null:
		return
	var instance := scene.instantiate()
	var skeleton := _find_first_skeleton(instance)
	_expect(skeleton != null, "%s must expose a Skeleton3D" % character_id)
	if skeleton != null:
		_expect(
			skeleton.get_bone_count() == 43,
			"%s must have 43 bones, got %d" % [character_id, skeleton.get_bone_count()]
		)
	var animation_player := instance.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_expect(animation_player != null, "%s must expose AnimationPlayer" % character_id)
	if animation_player != null:
		for animation_name in REQUIRED_ANIMATIONS:
			_expect(
				animation_player.has_animation(animation_name),
				"%s missing animation %s" % [character_id, animation_name]
			)
	for socket_name in REQUIRED_SOCKETS:
		_expect(
			instance.find_child(String(socket_name), true, false) != null,
			"%s missing socket %s" % [character_id, socket_name]
		)
	var meshes := instance.find_children("*", "MeshInstance3D", true, false)
	_expect(meshes.size() == 2, "%s must keep base and kit as 2 mesh parts" % character_id)
	var triangle_count := _triangle_count(meshes)
	_expect(
		triangle_count <= 30_000,
		"%s exceeds 30k triangles: %d" % [character_id, triangle_count]
	)
	instance.free()


func _validate_weapon(weapon_id: StringName) -> void:
	var path := "res://assets/weapons/generated/%s.glb" % weapon_id
	var scene := load(path) as PackedScene
	_expect(scene != null, "%s must load as PackedScene" % path)
	if scene == null:
		return
	var instance := scene.instantiate()
	var meshes := instance.find_children("*", "MeshInstance3D", true, false)
	_expect(meshes.size() == 1, "%s must contain exactly one weapon mesh" % weapon_id)
	_expect(
		_triangle_count(meshes) <= 5_000,
		"%s exceeds 5k triangles" % weapon_id
	)
	var socket_name := "GroundSocket" if weapon_id == &"landmine" else "MuzzleSocket"
	_expect(
		instance.find_child(socket_name, true, false) != null,
		"%s missing %s" % [weapon_id, socket_name]
	)
	instance.free()


func _triangle_count(mesh_nodes: Array[Node]) -> int:
	var total := 0
	for mesh_node in mesh_nodes:
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if not indices.is_empty():
				total += indices.size() / 3
			else:
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				total += vertices.size() / 3
	return total


func _find_first_skeleton(root_node: Node) -> Skeleton3D:
	if root_node is Skeleton3D:
		return root_node as Skeleton3D
	for node in root_node.find_children("*", "Skeleton3D", true, false):
		return node as Skeleton3D
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
