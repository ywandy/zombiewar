extends Resource
class_name WeaponDefinition

enum TriggerMode {
	PRESS,
	HOLD,
}

@export var weapon_id: StringName
@export var display_name: String
@export var visual_node_name: StringName

@export_group("表现")
@export var visual_scene: PackedScene
@export var visual_transform := Transform3D.IDENTITY

@export_group("玩法")
@export var trigger_mode := TriggerMode.PRESS
@export_range(0.1, 30.0, 0.1) var attacks_per_second := 1.0
@export_range(0.0, 500.0, 1.0) var damage := 1.0
@export var idle_animation: StringName = &"Idle"
@export var run_animation: StringName = &"Run"
@export var attack_animation: StringName
@export_range(0.0, 2.0, 0.01) var attack_lock_duration := 0.0
@export_range(0.0, 0.25, 0.01) var visual_recoil_kick := 0.0
@export_range(0.0, 0.12, 0.01) var camera_impulse_strength := 0.0
