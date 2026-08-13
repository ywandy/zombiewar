extends Resource
class_name WeaponDefinition

enum TriggerMode {
	PRESS,
	HOLD,
}

@export var weapon_id: StringName
@export var display_name: String
## 旧字段保留给数据检查与 UI 显示；独立模型由 visual_model_scene 提供。
@export var visual_node_name: StringName
@export_group("独立模型绑定")
@export var visual_model_scene: PackedScene
@export var visual_socket_name: StringName = &"WeaponSocket.L"
## 四元数按 Vector4(x, y, z, w) 存储。manifest 的 rotation_quaternion 已转换为该顺序。
@export var visual_relative_position := Vector3.ZERO
@export var visual_relative_rotation := Vector4(0.0, 0.0, 0.0, 1.0)
@export var visual_relative_scale := Vector3.ONE
@export var trigger_mode := TriggerMode.PRESS
@export_range(0.1, 30.0, 0.1) var attacks_per_second := 1.0
@export_range(0.0, 500.0, 1.0) var damage := 1.0
@export var idle_animation: StringName = &"Idle"
@export var run_animation: StringName = &"Run"
@export var attack_animation: StringName
@export_range(0.0, 2.0, 0.01) var attack_lock_duration := 0.0
@export_range(0.0, 0.25, 0.01) var visual_recoil_kick := 0.0
@export_range(0.0, 0.12, 0.01) var camera_impulse_strength := 0.0

func get_visual_relative_transform() -> Transform3D:
	var rotation := Quaternion(
		visual_relative_rotation.x,
		visual_relative_rotation.y,
		visual_relative_rotation.z,
		visual_relative_rotation.w
	)
	return Transform3D(
		Basis(rotation).scaled(visual_relative_scale),
		visual_relative_position
	)
