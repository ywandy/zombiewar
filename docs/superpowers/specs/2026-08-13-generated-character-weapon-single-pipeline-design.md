# 生成角色与生成武器单通道设计

## 目标

移除 Lis 旧角色与 `assets/weapons/decoupled/` 旧武器的运行时兼容链，角色和武器统一使用现有生成资源：

- 角色只从 `resources/characters/character_catalog.tres` 解析 `CharacterDefinition.model_scene`，模型只允许来自 `assets/characters/generated/`。
- 武器只从 `WeaponDefinition.visual_scene` 加载，模型只允许来自 `assets/weapons/generated/`。
- 所有手持武器统一挂到生成角色的 `WeaponHandSocket`。
- 远程武器的枪火与可见枪线继续从生成武器自己的 `MuzzleSocket` 出发；模拟层弹道起点继续由 `WeaponCollision` 提供。
- 缺角色模型、武器模型或必要 socket 时明确失败，不再静默加载旧模型。

## 现状与问题

当前工程已经有 10 个可选生成角色，每个 `CharacterDefinition` 都配置了 `model_scene`；手枪、冲锋枪、步枪和匕首也已经优先使用生成武器。但项目仍保留两套兼容路径：

1. `Player.tscn → PlayerVisual.tscn → Lis_WeaponSocket_L.gltf` 作为角色默认/回退模型。
2. `WeaponDefinition.visual_model_scene + visual_socket_name + visual_relative_*` 作为旧武器装配路径，通过 `WeaponVisualBinding` 挂到 `WeaponSocket.L`。

这使同一把武器可能根据角色模型走不同的资源、socket 与变换，菜单、预览和游戏实体也可能加载不同角色。继续维护两套路径会让挂点、枪口和换枪问题难以稳定验证。

## 资源映射

现有武器 ID 和玩法语义保持不变，只替换表现模型：

| 武器 ID | 生成模型 | 说明 |
|---|---|---|
| `pistol` | `assets/weapons/generated/hk45c.glb` | 手枪 |
| `smg` | `assets/weapons/generated/mp5.glb` | 冲锋枪 |
| `rifle` | `assets/weapons/generated/ak47.glb` | 步枪 |
| `shotgun` | `assets/weapons/generated/m4a1.glb` | 临时代替散弹枪外观；弹丸、伤害、射速等玩法仍按散弹枪定义 |
| `knife` | `assets/weapons/generated/tactical_knife.glb` | 匕首 |

角色映射继续由现有 10 个 `CharacterDefinition` 决定，默认角色仍是目录首项 `male_assault`，对应 `assets/characters/generated/male_assault.glb`。

## 架构

### 角色加载

`CharacterCatalog` 是角色内容的唯一来源：

```text
character_id
  → CharacterCatalog.get_by_id()
  → CharacterDefinition.model_scene
  → CharacterVisualHost.install(model_scene)
  → CharacterModel
```

- `CharacterVisualHost` 删除 `fallback_scene`，`install()` 只接受明确传入的非空 `PackedScene`。
- `Player.tscn` 不再引用 `PlayerVisual.tscn`，`VisualRoot` 只保留宿主脚本。
- `LocalPlayerSpawner` 在实例化玩家前验证角色 ID 和 `model_scene`；无效内容使整次生成失败并返回明确错误。
- `PlayerController` 在进入树时再次守卫 `character_definition/model_scene`，防止编辑器直接运行或测试误用时继续初始化一个没有视觉模型的玩家。
- 未知 `character_id` 继续返回 `null`，绝不回退到目录默认角色。

### 武器加载与挂点

`WeaponDefinition.visual_scene` 成为唯一武器模型字段，保留 `visual_transform` 作为生成模型相对 `WeaponHandSocket` 的校准变换。删除以下旧字段和辅助方法：

- `visual_node_name`
- `visual_model_scene`
- `visual_socket_name`
- `visual_relative_position`
- `visual_relative_rotation`
- `visual_relative_scale`
- `get_visual_relative_transform()`

`WeaponVisualBinding` 保留为共享的生成武器挂载器，但删除旧回退语义，接口收敛为：

```gdscript
bind(
    visual_root: Node3D,
    model_scene: PackedScene,
    relative_transform: Transform3D
) -> Node3D
```

绑定器只查找 `WeaponHandSocket`，实例化 `model_scene` 并应用 `relative_transform`。缺模型或 socket 时返回 `null` 并给出明确错误。`WeaponBase`、大厅预览和主菜单背景复用同一接口，不再各自判断新旧角色。

装备切换仍由 `WeaponBase.set_equipped()` 控制当前生成武器的可见性；`WeaponClearanceController` 继续保存并恢复 `visual_anchor.transform`，因此举枪、收枪和贴墙姿态不改变。

### 枪口与弹道职责

远程武器保持已经修复的双起点职责：

- 表现起点：当前生成武器的 `MuzzleSocket.global_position`，用于枪口火焰和可见枪线起点。
- 功能起点：`WeaponClearanceController.get_weapon_muzzle_origin()`，用于模拟层射击请求。

生成武器必须包含 `MuzzleSocket`。枪线终点仍使用模拟层返回的命中点，不进行表现层二次射线。

### 大厅预览

`LobbyPlayerPreview.tscn` 删除 `character_scene` 默认资源，不在 `_ready()` 中先创建旧角色。调用方必须先解析当前 `character_id`，再调用 `set_character_definition()`：

- `definition == null` 或 `definition.model_scene == null` 时不显示角色，并记录明确错误。
- 角色切换时释放旧 `CharacterModel`，实例化新生成角色。
- 展示武器固定使用 `smg.tres.visual_scene`，通过生成角色的 `WeaponHandSocket` 挂载。
- 待机动画仍使用 `Idle_Gun` 的循环副本，不修改 GLB 共享动画资源。

### 主菜单背景

`MenuBackdrop` 不再在场景文件中实例化 `PlayerVisual.tscn`。运行时通过 `ContentCatalogs.characters().default_id()` 解析默认角色，实例化其 `model_scene` 到 `SetDressing/PlayerHero` 宿主下，再通过同一生成武器绑定器挂载展示用冲锋枪。

目录、默认 ID、角色模型或 `WeaponHandSocket` 缺失时记录明确错误，菜单背景保留其他布景，但不加载旧角色替代。

## 失败策略

本改造采用严格失败，不做静默回退：

- 角色目录为空、角色 ID 未知或 `model_scene` 为空：拒绝对应玩家生成。
- `PlayerController` 未在入树前收到有效角色定义：停止该玩家初始化并记录错误。
- 武器 `visual_scene` 为空或角色缺少 `WeaponHandSocket`：武器绑定失败，装备切换守卫拒绝切换到该武器。
- 远程生成武器缺少 `MuzzleSocket`：专项校验失败；运行时保留功能弹道兜底，但不把错误伪装成正常装配。
- 菜单或大厅内容缺失：不显示错误角色/武器，仅记录一次明确错误。

联机仍按 `character_id` 传输，并在入局前通过本机目录校验未知 ID；角色与武器玩法 ID 均不变化，因此不修改协议常量。

## 删除与保留

删除运行时旧链及其专属资产：

- `scenes/player/PlayerVisual.tscn`
- `assets/characters/decoupled/`
- `assets/weapons/decoupled/`
- 只验证 Lis/`WeaponSocket.L` 旧链的校验脚本
- 源码中 `WeaponSocket.L`、`visual_model_scene` 和旧相对 TRS 兼容分支

历史设计文档保留，作为已经发生过的架构演进记录，不回写旧文档。未进入当前角色目录的 `resources/characters/survivor_*.tres` 是退役数据文件，不参与本次运行时单通道改造；本次不扩大范围删除它们。

## 验证设计

### 自动验证

1. 角色目录验证：10 个角色都必须有 `model_scene`，资源路径必须位于 `assets/characters/generated/`。
2. 生成角色资源验证：10 个 GLB 都必须包含动画、`WeaponHandSocket`、`WeaponBackSocket` 和 `MineHipSocket`。
3. 生成武器目录验证：当前五把武器的 `visual_scene` 路径必须匹配资源映射，并位于 `assets/weapons/generated/`。
4. 装配矩阵：对 10 个真实生成角色逐一装配完整武器栏，断言每把武器的父节点是该角色的 `WeaponHandSocket`，切换后只有当前武器可见。
5. 枪口验证：四把远程武器必须存在 `MuzzleSocket`，枪火和枪线起点必须与其全局位置一致。
6. 严格失败验证：缺角色模型、缺武器模型或缺 socket 时不得加载 Lis 或旧武器。
7. 菜单与预览验证：两者加载目录角色和生成冲锋枪，不引用 `PlayerVisual.tscn`、`assets/characters/decoupled/` 或 `assets/weapons/decoupled/`。
8. Godot headless 编辑器导入检查，确保删除资产后没有场景、脚本或资源引用残留。

### 人工验收

自动检查只能证明挂点链和变换契约，手部穿模仍需人工观察：

1. 在选角界面依次切换 10 个角色，确认模型和冲锋枪随选择更新，没有旧 Lis 闪现。
2. 进入游戏依次切换手枪、冲锋枪、散弹枪、步枪和匕首，确认只有当前武器可见。
3. 站立、移动和贴墙举枪时观察武器是否持续跟随手部。
4. 四把远程武器各开火一次，确认枪火和枪线从枪管前端出现。
5. 确认散弹枪暂时显示为 M4A1，但射击仍为散弹扇面。

## 非目标

- 本次不生成新的散弹枪美术；`m4a1.glb` 只是临时外观映射。
- 不修改武器伤害、射速、弹丸数量、弹药、穿透或模拟层档案顺序。
- 不修改角色数值、被动、本命武器或角色目录顺序。
- 不删除历史文档，也不清理与当前运行时无关的退役 `survivor_*.tres`。
- 不修改 `WeaponBackSocket`、`MineHipSocket` 的玩法用途。
