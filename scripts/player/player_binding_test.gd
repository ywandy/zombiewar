extends Node3D

const SinglePlayerInputSourceScript = preload(
	"res://scripts/input/single_player_input_source.gd"
)
const SLOT_LABELS: Array[String] = ["1 Pistol", "2 SMG", "3 Shotgun", "4 Rifle", "5 Knife"]

@onready var player: PlayerController = $Player
@onready var camera: Camera3D = $Camera3D
@onready var status_label: Label = $CanvasLayer/Status
@onready var socket_marker: MeshInstance3D = $SocketMarker

var selected_slot := 0
var input_source: SinglePlayerInputSource

func _ready() -> void:
	input_source = SinglePlayerInputSourceScript.new()
	player.set_input_source(input_source)
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	var socket := player.find_child("WeaponSocket.L", true, false) as Node3D
	if socket == null:
		socket = player.find_child("WeaponSocket_L", true, false) as Node3D
	if socket != null:
		socket_marker.visible = true
		socket_marker.top_level = true
		socket_marker.global_transform = socket.global_transform
	else:
		status_label.text = "WeaponSocket.L not found"
	_update_status()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var slot := (event as InputEventKey).keycode - KEY_1
	if slot < 0 or slot >= 5:
		return
	if player.equipment.equip_slot(slot):
		selected_slot = slot
		_update_status()

func _update_status() -> void:
	var current: Node = player.equipment.get_current_item() as Node
	var weapon_name: String = current.name if current != null else "None"
	var anchor_name := "Not bound"
	if current is WeaponBase and current.visual_anchor != null:
		anchor_name = "%s -> %s" % [current.visual_anchor.name, current.visual_anchor.get_parent().name]
	status_label.text = "Decoupled Player Binding Test\nMove: WASD / Arrow Keys | Switch: 1-5\nWeapons: %s\nCurrent: %s\nVisual: %s" % [
		" / ".join(SLOT_LABELS), weapon_name, anchor_name
	]
