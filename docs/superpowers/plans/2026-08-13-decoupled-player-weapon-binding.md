# 解耦玩家与武器绑定实施计划

> **给 agentic workers：** 按任务逐项执行，每项完成后运行对应验证。所有计划步骤使用复选框跟踪。

**目标：** 将玩家替换为独立人物+`WeaponSocket.L` 挂点，并让装备武器各自绑定独立 glTF 模型，同时提供可运行的绑定测试场景。

**架构：** `Player.tscn` 使用新人物 glTF；`WeaponBase` 保留战斗逻辑，新增 `WeaponVisualBinding` 负责把每把武器自己的 glTF 挂到角色 socket 并应用 manifest 的相对 TRS。大厅预览和测试场景复用同一套视觉绑定接口。

**技术栈：** Godot 4.7.1、GDScript 2.0、glTF 2.0、PackedScene、`AnimationPlayer`。

## 全局约束

- 不恢复 Godot Navigation；本次只改表现层模型绑定。
- 不把视觉绑定逻辑写入 `scripts/sim/`，不改变联机帧和模拟状态。
- 所有 GDScript 使用 tabs、静态类型和 `res://` 路径。
- 不提交 `.godot/`、`build/` 生成内容。
- 用户可见中文文本必须使用 `assets/fonts/NotoSansSC-UI.ttf` 覆盖；本次测试标签使用英文/ASCII，避免新增字体依赖。

---

### 任务 1：导入解耦模型资源

**文件：**
- 创建：`assets/characters/decoupled/Lis_WeaponSocket_L.gltf`、对应 `.bin` 和 `Zombie_Atlas.png`
- 创建：`assets/weapons/decoupled/{Pistol,SMG,Shotgun,Rifle,Knife}/` 下对应 glTF、`.bin`、`Zombie_Atlas.png`

**步骤：**

- [ ] 复制导出目录中的原始文件，保持 glTF 与相邻 bin/atlas 的相对引用不变。
- [ ] 用 `rg --files assets/characters/decoupled assets/weapons/decoupled` 确认五把当前装备武器和人物文件齐全。
- [ ] 运行 Godot headless editor import，确认 glTF 可被导入。

### 任务 2：增加武器视觉绑定数据与绑定器

**文件：**
- 创建：`scripts/combat/weapons/weapon_visual_binding.gd`
- 修改：`scripts/combat/weapons/weapon_definition.gd`
- 修改：`resources/weapons/pistol.tres`、`smg.tres`、`shotgun.tres`、`rifle.tres`、`knife.tres`

**接口：**
- `WeaponVisualBinding.bind(visual_root: Node3D, model_scene: PackedScene, socket_name: StringName, relative_transform: Transform3D) -> Node3D`
- `WeaponVisualBinding.set_visible(value: bool) -> void`
- `WeaponDefinition.visual_model_scene: PackedScene`、`visual_socket_name: StringName`、`visual_relative_transform: Transform3D`

**步骤：**

- [ ] 写绑定器：查找 `socket_name`，实例化模型，挂到 socket，应用 `relative_transform`；缺资源/挂点时只警告一次并返回 null。
- [ ] 给武器定义增加导出的模型场景、socket 名称和相对变换字段。
- [ ] 从 manifest 读取五把当前武器的 `relative_trs.position/rotation_quaternion/scale`，写入 `.tres`。
- [ ] 为绑定器写一个纯源级校验入口，确认声明的资源路径和 socket 名称。

### 任务 3：让 WeaponBase 使用独立模型

**文件：**
- 修改：`scripts/combat/weapons/weapon_base.gd`
- 修改：`scripts/player/equipment_controller.gd`
- 修改：`scenes/weapons/Pistol.tscn`、`Smg.tscn`、`Shotgun.tscn`、`Rifle.tscn`、`Knife.tscn`

**步骤：**

- [ ] 在 `WeaponBase.bind_context()` 中调用绑定器，保存绑定模型节点，并让逻辑武器节点跟随绑定模型的世界变换。
- [ ] 在 `set_equipped()` 中同步逻辑节点和模型节点显隐。
- [ ] 删除 `EquipmentController._hide_embedded_weapons()` 及其旧模型同名节点清单依赖。
- [ ] 更新五个武器场景的定义引用/模型资源，保持 `Muzzle`、音频和特效节点不变。
- [ ] 运行现有 `validate_weapon_assembly.gd` 与 `validate_equipment_cycle.gd`。

### 任务 4：替换 Player 与大厅预览

**文件：**
- 修改：`scenes/player/Player.tscn`
- 修改：`scripts/menu/lobby_player_preview.gd`
- 修改：`scenes/menu/LobbyPlayerPreview.tscn`

**步骤：**

- [ ] 用新人物 glTF 替换旧合并人物实例，保留 `VisualRoot` 的朝向和现有动画查找路径。
- [ ] 移除大厅预览对旧内嵌武器名清单的查找，改为实例化新的玩家视觉场景/绑定接口并默认显示 SMG。
- [ ] 确认预览动画仍播放 `Idle_Gun` 循环。
- [ ] 运行 `validate_lobby_player_preview.gd`、`validate_player_accent_color.gd`。

### 任务 5：创建 Player 绑定测试场景

**文件：**
- 创建：`scripts/player/player_binding_test.gd`
- 创建：`scenes/player/PlayerBindingTest.tscn`

**接口：**
- 键盘 `1`-`5` 切换手枪、冲锋枪、散弹枪、步枪、匕首。
- 测试脚本在 `_ready()` 后打印 socket 找到状态和当前绑定模型名称。

**步骤：**

- [ ] 创建包含 `Player` 实例、相机、灯光、地面和五个切换按钮/标签的测试场景。
- [ ] 测试脚本调用 `EquipmentController.equip_slot()`，不直接修改模型显隐。
- [ ] 为 `WeaponSocket.L` 添加可选的 `Marker3D`/小球辅助显示，便于人工确认挂点跟随手指骨骼。
- [ ] 运行场景并确认五把武器均能切换；无法自动稳定验证的视觉部分记录为人工验收步骤。

### 任务 6：添加验证脚本并完成检查

**文件：**
- 创建：`tools/validation/validate_decoupled_player_binding.gd`

**步骤：**

- [ ] 校验人物 glTF、五把武器 glTF 和对应 `.bin`/atlas 存在。
- [ ] 校验 `WeaponDefinition` 资源声明 `visual_model_scene`、socket 为 `WeaponSocket.L`，且 `Player.tscn` 不再引用旧合并模型。
- [ ] 运行 headless editor import、绑定校验、武器装配/装备循环校验。
- [ ] 汇总人工验收：打开 `PlayerBindingTest.tscn`，按 `1`-`5` 观察模型是否落在左手并随 Idle/Run 动画移动。

### 任务 7：迁移菜单背景角色并删除旧合并资源

**文件：**
- 修改：`scenes/player/PlayerVisual.tscn`
- 修改：`scenes/player/Player.tscn`
- 修改：`scenes/menu/MenuBackdrop.tscn`
- 修改：`scripts/menu/menu_backdrop.gd`
- 创建：`tools/validation/validate_menu_backdrop_player_binding.gd`
- 删除：`assets/characters/Characters_Lis_SingleWeapon.gltf`
- 删除：`assets/characters/Characters_Lis_SingleWeapon_Zombie_Atlas.png`

**步骤：**

- [x] 将 `Middle1.L` 的正确手持挂点收敛到复用场景 `PlayerVisual.tscn`，避免玩家、预览和菜单各自维护挂点。
- [x] 菜单背景角色改用 `PlayerVisual.tscn`，并通过 `WeaponVisualBinding` 绑定独立 SMG 模型。
- [x] 校验菜单背景运行时使用解耦人物、正确手持挂点和独立武器模型。
- [x] 确认仓库运行时不再引用旧合并模型后，删除旧 glTF 与专属 atlas。
- [x] 运行 Godot headless import 和解耦玩家、菜单背景、大厅预览相关验证。
