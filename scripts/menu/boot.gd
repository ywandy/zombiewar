extends Control
## DOGWALK-style boot splash: flash a generated emblem for a moment, then hand
## off to the main menu. Any key / click skips.
##
## Frames are produced by tools/bootlogo/generate_boot_logos.py and live under
## res://assets/ui/boot/. If they are missing (not generated yet) the splash
## skips straight to the menu so the game always boots.
##
## On top of the crossfade, the emblem runs an electric-glitch treatment: a
## shader (assets/ui/boot/boot_glitch.gdshader) for slice/RGB/static, plus a
## small trauma-based position/scale jitter in code. A sub-bass drone and a
## heartbeat sit underneath for the zombie-crisis dread.

@export_file("*.tscn") var next_scene_path := "res://scenes/menu/MainMenu.tscn"

## How long each flash frame stays on screen, in seconds.
@export var frame_durations: Array[float] = [1.6, 0.18, 0.9, 0.18, 0.6]
## Frame textures in play order. Index lines up with frame_durations.
@export var frame_textures: Array[Texture2D] = []
## Glitch intensity per frame (0 = clean, 1 = full interference). Same indexing.
@export var frame_glitch: Array[float] = [0.12, 0.95, 0.55, 1.0, 0.2]

## Peak positional shake in pixels at full trauma.
@export var shake_pixels := 9.0
## Peak extra scale wobble at full trauma.
@export var shake_scale := 0.04

@onready var _logo: TextureRect = %Logo
@onready var _hint: Label = %SkipHint
@onready var _heartbeat: AudioStreamPlayer = %Heartbeat
@onready var _drone: AudioStreamPlayer = %Drone

var _frame_index := -1
var _time_in_frame := 0.0
var _finished := false
var _glitch := 0.0
var _trauma := 0.0
var _base_scale := Vector2.ONE
var _base_position := Vector2.ZERO
var _noise := FastNoiseLite.new()
var _noise_time := 0.0


func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 4.0
	# Shake around the emblem's own centre so scale/offset wobble stays anchored.
	_logo.resized.connect(func() -> void: _logo.pivot_offset = _logo.size * 0.5)
	_logo.pivot_offset = _logo.size * 0.5
	_base_scale = _logo.scale
	# The container leaves the logo at position (0,0); shake adds a small offset
	# on top of that baseline so the emblem never drifts off-centre.
	_base_position = Vector2.ZERO
	_logo.position = _base_position
	_load_frames()
	if frame_textures.is_empty():
		_finish()  # Nothing generated yet: don't block startup.
		return
	_logo.modulate.a = 0.0
	_advance_frame()
	_fade_in_hint()
	_play_sfx()


func _load_frames() -> void:
	if not frame_textures.is_empty():
		return
	for path in [
		"res://assets/ui/boot/boot_logo_main.png",
		"res://assets/ui/boot/boot_logo_glitch.png",
		"res://assets/ui/boot/boot_logo_pulse.png",
		"res://assets/ui/boot/boot_logo_glitch.png",
		"res://assets/ui/boot/boot_logo_main.png",
	]:
		if ResourceLoader.exists(path):
			frame_textures.append(load(path))


func _process(delta: float) -> void:
	if _finished or frame_textures.is_empty():
		return
	_time_in_frame += delta
	_noise_time += delta
	var dur: float = frame_durations[min(_frame_index, frame_durations.size() - 1)]
	_logo.modulate.a = minf(_time_in_frame / 0.25, 1.0)

	# Trauma eases toward the frame's glitch level; shake uses trauma^2 so the
	# clean frames stay nearly still and the flicker frames snap hard.
	_trauma = lerpf(_trauma, _glitch, minf(delta * 8.0, 1.0))
	_apply_shake(_trauma * _trauma)

	if _time_in_frame >= dur:
		_advance_frame()


func _apply_shake(amount: float) -> void:
	# Smooth-noise jitter reads as electric buzz rather than random teleporting.
	# Rotation + scale wobble around pivot_offset keeps the emblem centred while
	# still feeling like the signal is tearing.
	var rot := _noise.get_noise_1d(_noise_time * 60.0) * 0.05 * amount
	var ox := _noise.get_noise_1d(_noise_time * 60.0 + 1000.0) * shake_pixels * amount
	var oy := _noise.get_noise_1d(_noise_time * 60.0 + 2000.0) * shake_pixels * amount
	_logo.rotation = rot
	# Position shake is a small offset around the layout-assigned centre — do NOT
	# add pivot_offset here (pivot is a rotation/scale anchor, not a translation).
	_logo.position = _base_position + Vector2(ox, oy)
	var s := 1.0 + _noise.get_noise_1d(_noise_time * 45.0 + 3000.0) * shake_scale * amount
	_logo.scale = _base_scale * s
	# Drive the shader's interference from the same amount.
	if _logo.material:
		_logo.material.set_shader_parameter("intensity", amount)


func _advance_frame() -> void:
	_frame_index += 1
	_time_in_frame = 0.0
	if _frame_index >= frame_textures.size():
		_finish()
		return
	_logo.texture = frame_textures[_frame_index]
	_glitch = frame_glitch[min(_frame_index, frame_glitch.size() - 1)]


func _fade_in_hint() -> void:
	_hint.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_interval(0.8)
	tween.tween_property(_hint, "modulate:a", 0.55, 0.4)


## Kick off the heartbeat + drone if their players are wired up. Silent no-op
## when an audio file hasn't been generated, so the splash never blocks on sfx.
func _play_sfx() -> void:
	if _heartbeat != null and _heartbeat.stream != null:
		_heartbeat.play()
	if _drone != null and _drone.stream != null:
		_drone.play()


func _unhandled_input(event: InputEvent) -> void:
	if _finished:
		return
	var pressed := false
	if event is InputEventKey and event.pressed and not event.echo:
		pressed = true
	elif event is InputEventMouseButton and event.pressed:
		pressed = true
	elif event is InputEventScreenTouch and event.pressed:
		pressed = true
	if pressed:
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	set_process(false)
	get_tree().change_scene_to_file(next_scene_path)
