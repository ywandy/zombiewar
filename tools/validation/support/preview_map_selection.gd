extends SceneTree

## 离屏渲染一张 MapSelection 截图，用来肉眼核对排版（不是自动化校验，跑完即可删）。
## 用法：/Applications/Godot.app/Contents/MacOS/Godot --path . --script \
##   tools/validation/support/preview_map_selection.gd -- <输出绝对路径>

const WARMUP_FRAMES := 20

var _frames := 0
var _out_path := "/tmp/map_selection_preview.png"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_path = args[0]
	var scene := load("res://scenes/menu/MapSelection.tscn") as PackedScene
	root.add_child(scene.instantiate())

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < WARMUP_FRAMES:
		return false
	var image := root.get_texture().get_image()
	image.save_png(_out_path)
	print("map selection preview saved: %s (%dx%d)" % [_out_path, image.get_width(), image.get_height()])
	return true
