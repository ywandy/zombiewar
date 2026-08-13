# 生成角色与生成武器单通道实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 删除 Lis 与 `assets/weapons/decoupled/` 兼容链，让游戏、选角预览和主菜单背景只通过内容目录加载生成角色，并只把生成武器挂到 `WeaponHandSocket`；远程表现继续从 `MuzzleSocket` 发出。

**架构：** 角色由 `CharacterCatalog → CharacterDefinition.model_scene → CharacterVisualHost.install()` 单向加载；缺目录条目、模型或宿主时明确失败。武器由 `WeaponDefinition.visual_scene → WeaponVisualBinding.bind()` 单向装配，绑定器只接受 `WeaponHandSocket`，枪口表现仍由武器模型内的 `MuzzleSocket` 驱动。

**技术栈：** Godot 4.7.1、GDScript、`.tscn`/`.tres` 资源、Godot headless 校验脚本、Git。

## 全局约束

- 角色模型只允许来自 `res://assets/characters/generated/`，当前目录的 10 个角色都必须有模型。
- 武器模型映射固定为：`pistol → hk45c.glb`、`smg → mp5.glb`、`rifle → ak47.glb`、`shotgun → m4a1.glb`、`knife → tactical_knife.glb`。
- 所有武器只挂到 `WeaponHandSocket`；四把远程武器必须包含 `MuzzleSocket`。
- 不修改玩法数值、武器/角色 ID、目录顺序、模拟层档案顺序或联机协议。
- 删除旧角色场景、`assets/characters/decoupled/`、`assets/weapons/decoupled/` 和只服务旧链的验证。
- 历史文档与 `resources/characters/survivor_*.tres` 保留。
- 每个生产行为变更前先写或修改校验，确认它因缺少目标行为而失败，再做最小实现。
- 不提交 `.godot/`、`build/`，也不提交 Godot 导入意外改写的无关翻译元数据。

---

### Task 1：锁定角色目录与严格失败契约

**文件：**
- 修改：`tools/validation/validate_character_catalog.gd`
- 修改：`tools/validation/validate_character_model_switching.gd`
- 修改：`scripts/gameplay/local_player_spawner.gd`
- 修改：`scripts/player/player_controller.gd`

**接口：**
- 消费：`ContentCatalogs.characters() -> CharacterCatalog`、`CharacterCatalog.get_by_id(id) -> CharacterDefinition`
- 产出：生成玩家前必须取得非空 `CharacterDefinition.model_scene`；`PlayerController.apply_character_definition(def)` 只接受有效模型定义。

- [x] **Step 1：写失败校验**

在角色目录校验中逐项断言 10 个目录条目的 `model_scene.resource_path` 以 `res://assets/characters/generated/` 开头；在角色切换校验中新增未知 ID、空 `model_scene` 时不生成玩家且 `GameSession.last_error` 包含角色 ID/模型缺失原因的断言。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_character_catalog.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_character_model_switching.gd
```

预期：至少严格生成失败契约校验失败，现状会静默使用默认角色或继续生成无模型玩家。

- [x] **Step 3：最小实现**

在 `LocalPlayerSpawner.spawn_players()` 中解析角色后立即检查条目和 `model_scene`，任何失败统一走 `_fail_spawn()`；在 `PlayerController.apply_character_definition()` 与 `_ready()` 中拒绝空定义/空模型，且不得继续初始化装备到无角色宿主。

- [x] **Step 4：确认 GREEN**

重复运行两个校验，预期均 `PASS`。

- [x] **Step 5：提交**

```bash
git add tools/validation/validate_character_catalog.gd tools/validation/validate_character_model_switching.gd scripts/gameplay/local_player_spawner.gd scripts/player/player_controller.gd
git commit -m "fix: enforce generated character definitions"
```

### Task 2：删除 Player 的旧角色回退链

**文件：**
- 修改：`tools/validation/validate_generated_character_models.gd`
- 修改：`scripts/player/character_visual_host.gd`
- 修改：`scenes/player/Player.tscn`
- 删除：`scenes/player/PlayerVisual.tscn`

**接口：**
- 消费：`CharacterDefinition.model_scene: PackedScene`
- 产出：`CharacterVisualHost.install(scene: PackedScene) -> Node3D`，传入 `null` 时返回 `null` 并报错，不读取任何 fallback。

- [x] **Step 1：写失败校验**

扩展生成角色校验：断言 `Player.tscn` 不引用 `PlayerVisual.tscn` 或 decoupled 角色资源；实例化 `CharacterVisualHost` 后调用 `install(null)` 不产生 `CharacterModel`，传入每个目录模型时都只生成对应模型。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_generated_character_models.gd
```

预期：因 `fallback_scene`、`PlayerVisual.tscn` 引用仍存在而失败。

- [x] **Step 3：最小实现**

删除 `CharacterVisualHost.fallback_scene` 和 fallback 选择逻辑；从 `Player.tscn` 删除旧场景 ext_resource 与赋值；删除 `PlayerVisual.tscn`。

- [x] **Step 4：确认 GREEN**

重复运行生成角色校验，预期 `PASS`。

- [x] **Step 5：提交**

```bash
git add tools/validation/validate_generated_character_models.gd scripts/player/character_visual_host.gd scenes/player/Player.tscn scenes/player/PlayerVisual.tscn
git commit -m "refactor: remove legacy player visual fallback"
```

### Task 3：收敛武器定义与生成武器绑定器

**文件：**
- 修改：`tools/validation/validate_weapon_assembly.gd`
- 修改：`scripts/combat/weapons/weapon_definition.gd`
- 修改：`scripts/combat/weapons/weapon_visual_binding.gd`
- 修改：`scripts/combat/weapons/weapon_base.gd`
- 修改：`resources/weapons/pistol.tres`
- 修改：`resources/weapons/smg.tres`
- 修改：`resources/weapons/rifle.tres`
- 修改：`resources/weapons/shotgun.tres`
- 修改：`resources/weapons/knife.tres`

**接口：**
- 消费：`WeaponDefinition.visual_scene: PackedScene`、`WeaponDefinition.visual_transform: Transform3D`
- 产出：`WeaponVisualBinding.bind(visual_root: Node3D, model_scene: PackedScene, relative_transform: Transform3D) -> Node3D`，只寻找 `WeaponHandSocket`。

- [x] **Step 1：写失败校验**

把武器装配校验改为断言五把定义只暴露 `visual_scene`/`visual_transform`，路径精确匹配生成资源映射；断言绑定器面对无模型或无 `WeaponHandSocket` 返回 `null`，面对合法生成角色时模型父节点就是 `WeaponHandSocket`。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_weapon_assembly.gd
```

预期：因五把资源仍引用 decoupled 模型、定义仍暴露旧字段、绑定器仍接受旧 socket 参数而失败。

- [x] **Step 3：最小实现**

从 `WeaponDefinition` 删除 `visual_node_name`、`visual_model_scene`、`visual_socket_name`、旧相对 TRS 与 `get_visual_relative_transform()`；将 `WeaponVisualBinding` 固定查找 `WeaponHandSocket`；将 `WeaponBase` 仅调用新绑定接口；更新五把 `.tres` 的 `visual_scene` 映射并保留已有 `visual_transform` 校准。

- [x] **Step 4：确认 GREEN**

重复运行武器装配校验，预期 `PASS`。

- [x] **Step 5：提交**

```bash
git add tools/validation/validate_weapon_assembly.gd scripts/combat/weapons/weapon_definition.gd scripts/combat/weapons/weapon_visual_binding.gd scripts/combat/weapons/weapon_base.gd resources/weapons/pistol.tres resources/weapons/smg.tres resources/weapons/rifle.tres resources/weapons/shotgun.tres resources/weapons/knife.tres
git commit -m "refactor: use generated weapon models only"
```

### Task 4：覆盖十角色完整武器装配与枪口链

**文件：**
- 修改：`tools/validation/validate_weapon_assembly.gd`
- 修改：`tools/validation/validate_equipment_cycle.gd`
- 重命名并修改：`tools/validation/validate_decoupled_weapon_muzzle.gd` → `tools/validation/validate_generated_weapon_muzzle.gd`
- 修改：`tools/validation/validate_muzzle_flash_orientation.gd`

**接口：**
- 消费：10 个目录角色、五把 `WeaponDefinition`、`EquipmentController.equip_slot()`、远程武器 `MuzzleSocket`
- 产出：10 × 5 真实装配矩阵；换装后只有当前武器可见；枪火与枪线从当前生成武器的 `MuzzleSocket` 出发。

- [x] **Step 1：写失败校验**

扩展装配校验逐角色安装完整武器栏，断言每个视觉锚点的父节点均为对应角色的 `WeaponHandSocket`；扩展装备循环校验断言每次换装只有当前武器可见；将枪口校验措辞与资源断言改为 generated，并精确检查四把远程武器都包含 `MuzzleSocket`。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_weapon_assembly.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_generated_weapon_muzzle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_muzzle_flash_orientation.gd
```

预期：新矩阵至少在旧装配分支、默认无角色 Player 或旧资源断言上失败。

- [x] **Step 3：最小实现**

只修正矩阵暴露的运行时装配、可见性或枪口同步缺口；不得修改弹道、伤害、射速、弹丸数等玩法值。

- [x] **Step 4：确认 GREEN**

重复运行四个校验，预期全部 `PASS`。

- [x] **Step 5：提交**

```bash
git add tools/validation/validate_weapon_assembly.gd tools/validation/validate_equipment_cycle.gd tools/validation/validate_generated_weapon_muzzle.gd tools/validation/validate_muzzle_flash_orientation.gd scripts scenes resources
git commit -m "test: cover generated weapon assembly matrix"
```

### Task 5：迁移大厅预览和主菜单背景

**文件：**
- 修改：`tools/validation/validate_lobby_player_preview.gd`
- 修改：`tools/validation/validate_menu_backdrop_player_binding.gd`
- 修改：`scripts/menu/lobby_player_preview.gd`
- 修改：`scenes/menu/LobbyPlayerPreview.tscn`
- 修改：`scripts/menu/menu_backdrop.gd`
- 修改：`scenes/menu/MenuBackdrop.tscn`

**接口：**
- 消费：`LobbyPlayerPreview.set_character_definition(definition)`、`ContentCatalogs.characters().default_id()`、`smg.tres.visual_scene`
- 产出：预览只显示传入目录角色；菜单背景只显示默认目录角色；两处展示武器都通过 `WeaponVisualBinding` 挂到 `WeaponHandSocket`。

- [x] **Step 1：写失败校验**

将两个校验改为断言场景文本不含 `PlayerVisual.tscn`/decoupled 路径；预览的 10 个角色切换均装配生成 MP5；空定义清空角色且不回退；菜单背景实例化 `male_assault` 并装配生成 MP5。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_menu_backdrop_player_binding.gd
```

预期：因两个场景仍引用 `PlayerVisual.tscn`，脚本仍读取旧武器字段而失败。

- [x] **Step 3：最小实现**

从预览场景删除默认角色资源，脚本只实例化 `definition.model_scene` 并调用新绑定接口；菜单背景把 `PlayerHero` 改为纯 `Node3D` 宿主，运行时解析默认目录定义并安装角色和 MP5。

- [x] **Step 4：确认 GREEN**

重复运行两个校验，预期均 `PASS`。

- [x] **Step 5：提交**

```bash
git add tools/validation/validate_lobby_player_preview.gd tools/validation/validate_menu_backdrop_player_binding.gd scripts/menu/lobby_player_preview.gd scenes/menu/LobbyPlayerPreview.tscn scripts/menu/menu_backdrop.gd scenes/menu/MenuBackdrop.tscn
git commit -m "refactor: load generated characters in menu previews"
```

### Task 6：删除旧资产、扫清引用并完成回归

**文件：**
- 删除：`assets/characters/decoupled/`
- 删除：`assets/weapons/decoupled/`
- 删除：`tools/validation/validate_decoupled_player_binding.gd`
- 修改或删除：`scripts/player/player_binding_test.gd`（若仍只服务旧 Lis 调试链则删除）
- 修改：本计划中所有受删除资源影响的场景、资源和校验

**接口：**
- 消费：前五个任务形成的角色/武器单通道
- 产出：运行时代码、场景、资源与有效校验中不存在旧资产、`WeaponSocket.L` 或旧武器字段引用。

- [x] **Step 1：写失败校验**

在 `validate_weapon_assembly.gd` 或新的源级检查段中扫描 `scripts/`、`scenes/`、`resources/`、有效 `tools/validation/`，断言不存在 `PlayerVisual.tscn`、`assets/characters/decoupled/`、`assets/weapons/decoupled/`、`WeaponSocket.L`、`visual_model_scene`、`visual_socket_name`、`visual_relative_`。

- [x] **Step 2：确认 RED**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_weapon_assembly.gd
```

预期：删除前残留扫描失败并列出旧资源或旧字段引用。

- [x] **Step 3：最小实现**

删除两个 decoupled 资产目录和旧角色绑定验证；删除或迁移 `player_binding_test.gd`；清除所有运行时残留引用。历史 `docs/` 不纳入残留扫描。

- [x] **Step 4：完整验证**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_character_catalog.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_generated_character_models.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_character_model_switching.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_weapon_assembly.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_menu_backdrop_player_binding.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_generated_weapon_muzzle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/validation/validate_muzzle_flash_orientation.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
rg -n "PlayerVisual\.tscn|assets/characters/decoupled|assets/weapons/decoupled|WeaponSocket\.L|visual_model_scene|visual_socket_name|visual_relative_|get_visual_relative_transform" scripts scenes resources tools/validation
```

预期：九个专项校验和 editor import 全部成功；`rg` 无输出（历史文档不扫描）。

- [x] **Step 5：提交并压缩为一个计划提交**

```bash
git add -A assets/characters/decoupled assets/weapons/decoupled scripts scenes resources tools/validation docs/superpowers/plans/2026-08-13-generated-character-weapon-single-pipeline.md
git commit -m "chore: remove legacy decoupled assets"
git reset --soft 562b4fc
git commit -m "refactor: unify generated character weapon pipeline"
```

压缩前确认暂存区不包含 `.godot/`、`build/` 或无关翻译元数据；若工作树存在用户修改，不能用 reset/checkout 覆盖，改用交互式 rebase 或重新整理明确的实现提交。
