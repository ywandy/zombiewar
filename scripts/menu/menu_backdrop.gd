extends Node3D

const WeaponVisualBindingScript = preload(
	"res://scripts/combat/weapons/weapon_visual_binding.gd"
)
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const DISPLAY_WEAPON_DEFINITION = preload("res://resources/weapons/smg.tres")

## The menu backdrop is a living diorama: the camera never stops drifting, the
## red warning light sweeps and breathes like an alarm state, and ash motes rise
## through the frame. All of it is cheap ambient motion so the menu feels alive
## without fighting the UI for attention.

@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var warning_light: OmniLight3D = $WarningLight
@onready var warning_light_fill: OmniLight3D = $WarningLightFill

var elapsed := 0.0
var base_camera_yaw := 0.0
var base_light_energy := 6.2
var base_fill_energy := 3.0
var player_weapon_binding: WeaponVisualBinding

func _ready() -> void:
	base_camera_yaw = camera_rig.rotation.y
	camera.look_at(Vector3(0.0, 1.35, -1.5), Vector3.UP)
	_install_player_hero()
	_play_model_animation($SetDressing/ZombieBasic, &"Walk")
	_play_model_animation($SetDressing/ZombieChubby, &"Idle_Attack")

func _install_player_hero() -> void:
	var catalog = ContentCatalogsScript.characters()
	if catalog == null:
		push_error("Menu backdrop character catalog is unavailable")
		return
	var definition = catalog.get_by_id(catalog.default_id())
	if definition == null or definition.model_scene == null:
		push_error("Menu backdrop default character model is unavailable")
		return
	var character_model := definition.model_scene.instantiate() as Node3D
	if character_model == null:
		push_error("Menu backdrop default character model could not instantiate")
		return
	character_model.name = "CharacterModel"
	$SetDressing/PlayerHero.add_child(character_model)
	player_weapon_binding = WeaponVisualBindingScript.new()
	player_weapon_binding.bind(
		character_model,
		DISPLAY_WEAPON_DEFINITION.visual_scene,
		DISPLAY_WEAPON_DEFINITION.visual_transform
	)
	_play_model_animation(character_model, &"Idle_Gun")

func _process(delta: float) -> void:
	elapsed += delta
	_drift_camera()
	_pulse_warning_light()

func _drift_camera() -> void:
	# A slow yaw sway plus a tiny breathing push so the frame never sits still.
	camera_rig.rotation.y = base_camera_yaw + deg_to_rad(sin(elapsed * 0.22) * 0.9)
	var push := sin(elapsed * 0.13) * 0.22
	camera_rig.position = Vector3(0.0, sin(elapsed * 0.17) * 0.1, push)

func _pulse_warning_light() -> void:
	# Layered sines read as a flickering rotating beacon rather than a metronome.
	var sweep := sin(elapsed * 2.1) * 0.45
	var flicker := sin(elapsed * 9.3) * sin(elapsed * 3.7) * 0.35
	warning_light.light_energy = base_light_energy + sweep + flicker
	if warning_light_fill != null:
		warning_light_fill.light_energy = base_fill_energy + (sweep + flicker) * 0.5
	# The light slowly circles the set so red light rakes across the props.
	var orbit := elapsed * 0.35
	warning_light.position.x = -3.5 + cos(orbit) * 1.6
	warning_light.position.z = -1.0 + sin(orbit) * 1.6

func _play_model_animation(model_root: Node, animation_name: StringName) -> void:
	var animation_player := model_root.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player != null and animation_player.has_animation(animation_name):
		animation_player.play(animation_name, 0.2)
