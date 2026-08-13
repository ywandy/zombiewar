# 解耦玩家与武器挂点设计

## 目标

将现有玩家从旧的“人物+内嵌武器”模型切换为新导出的“独立人物+骨骼武器挂点+独立武器模型”组合，并保留现有移动、战斗、装备切换和大厅预览行为。

## 现状与约束

- `scenes/player/Player.tscn` 当前实例化 `Characters_Lis_SingleWeapon.gltf`，装备逻辑依靠在人物树中查找旧武器节点。
- `EquipmentController` 负责装备项生命周期和切换；`WeaponBase` 负责战斗逻辑和武器视觉锚点。
- 新人物为 `Lis_WeaponSocket_L.gltf`，包含 `WeaponSocket.L` 节点，节点由骨骼 `Middle1.L` 驱动。
- 新武器各自是独立 glTF。`export_manifest.json` 给出每把武器相对 `WeaponSocket.L` 的位置、四元数旋转和缩放；当前导出值均为单位旋转/缩放，仅位置有细微差异。
- 武器战斗逻辑节点必须继续保留 `Muzzle`、枪口火焰、音频和弹道胶囊的现有职责。
- 运行时状态和联机模拟不能因视觉换绑而改变；挂点绑定属于表现层。

## 方案

采用“逻辑武器节点 + 独立视觉模型子节点”的组合：

1. `Player.tscn` 的 `VisualRoot` 实例化新人物 glTF。
2. 新增 `WeaponVisualBinding`，在人物视觉树中定位 `WeaponSocket.L`，并把独立武器 glTF 实例化为逻辑武器节点的子节点；绑定器将模型的局部变换设为 manifest 的相对 TRS。
3. `WeaponBase.bind_context()` 接收玩家视觉树，并通过显式模型场景/节点声明创建视觉模型，不再查找旧人物中的同名内嵌网格。
4. `set_equipped()` 只控制逻辑武器节点和独立视觉模型的显隐；武器逻辑仍以自己的节点变换同步枪口、射线和特效。
5. 没有模型声明或找不到 socket 时，武器逻辑仍可运行，同时输出一次警告；不会静默回退到旧内嵌武器。
6. 大厅预览改为实例化新的玩家视觉场景，默认显示 SMG，并复用同一个绑定器。

## 文件边界

- `assets/characters/decoupled/`：复制新人物 glTF/bin/atlas。
- `assets/weapons/decoupled/<Weapon>/`：复制独立武器 glTF/bin/atlas。
- `resources/weapons/*.tres`：增加独立模型资源路径和 manifest 相对变换字段。
- `scripts/combat/weapons/weapon_visual_binding.gd`：通用 socket 查找、模型实例化和相对 TRS 应用。
- `scripts/combat/weapons/weapon_base.gd`：调用绑定器并管理视觉模型显隐。
- `scenes/weapons/*.tscn`：给当前武器声明对应的独立模型场景/资源。
- `scenes/player/Player.tscn`：替换人物 glTF，移除旧内嵌武器隐藏逻辑依赖。
- `scenes/menu/LobbyPlayerPreview.tscn`、`scripts/menu/lobby_player_preview.gd`：使用新的玩家视觉组合。
- `scenes/player/PlayerBindingTest.tscn`、`scripts/player/player_binding_test.gd`：可视化测试人物、挂点和武器切换。
- `tools/validation/validate_decoupled_player_binding.gd`：源级校验资源存在、socket 名称和声明映射。

## 数据流

```text
Player.tscn
  -> VisualRoot/Lis_WeaponSocket_L.gltf
  -> WeaponSocket.L (由 Middle1.L 骨骼驱动)
  -> EquipmentController 实例化 WeaponBase
  -> WeaponVisualBinding 载入对应独立 glTF
  -> 设置 manifest.relative_trs
  -> set_equipped() 控制当前武器显示
```

## 验收标准

- 运行 `Player.tscn` 时能看到新人物，默认手枪显示在左手挂点，切换装备后旧武器隐藏、新武器正确显示。
- 运行 `PlayerBindingTest.tscn` 时能看到人物、挂点辅助标记和至少五把当前装备武器的切换结果。
- 大厅预览不再引用 `Characters_Lis_SingleWeapon.gltf`。
- 现有武器逻辑验证和 Godot headless 导入检查通过。
- 绑定缺失时有清晰警告，且不会崩溃或回退到旧模型。
