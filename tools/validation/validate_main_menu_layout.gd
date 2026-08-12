extends SceneTree

## headless：实例化 MainMenu，断言 Brotato 布局的关键节点与货币显示。
## 运行: godot --headless -s tools/validation/validate_main_menu_layout.gd

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed: PackedScene = load("res://scenes/menu/MainMenu.tscn")
	if packed == null:
		printerr("FAIL: 无法加载 MainMenu.tscn")
		quit(1)
		return
	var menu: Node = packed.instantiate()
	root.add_child(menu)
	var ok := true
	for path: String in ["BgTex", "HeroTex", "UILayer/TopBar", "UILayer/LeftRail",
			"UILayer/RightRail", "UILayer/StartButton", "UILayer/FadeOverlay",
			"UILayer/ToastLabel"]:
		ok = ok and _c(menu.get_node_or_null(path) != null, "缺节点 %s" % path)
	var start := menu.get_node_or_null("UILayer/StartButton") as Button
	ok = ok and _c(start != null and start.text == "开始游戏", "开始游戏按钮文案")
	var mv := menu.get_node_or_null("%MaterialValue") as Label
	ok = ok and _c(mv != null, "货币数值 Label 存在")
	print("MAINMENU LAYOUT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _c(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
