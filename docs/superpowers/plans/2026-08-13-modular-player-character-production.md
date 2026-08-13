# 模块化玩家角色资产生产 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 生产十个共享现有骨架与动画的正式玩家角色和七件独立武器模型，以新角色替换四个占位目录条目，并让角色选择、游戏内模型和现有武器表现真正使用新资产。

**Architecture:** 先打通 `CharacterDefinition.model_scene` 与独立武器 `visual_scene` 的运行时装配契约，再完成“男性突击手 + AK-47”样板门槛。样板通过后，四视图与 Tripo3D 任务受控并发，Blender MCP 统一完成骨架、挂点、权重、减面和 GLB 导出，最后一次性替换角色目录并做 Godot 验收。

**Tech Stack:** Godot 4.7.1 / GDScript / GLTF 2.0 (`.glb`) / Blender 4.4.3 + Blender MCP / `gpt-image-2` / Tripo3D `multiview_to_model` / headless Godot validation.

## Global Constraints

- 交付范围固定为十个角色主体（男女 × 机枪手、突击手、医疗兵、爆破兵、防爆兵）和七件独立武器（RPG、AK-47、M4A1、战术匕首、HK-45C、地雷、MP-5）。
- 视觉采用 B「可玩漫画」：约 4.5 头身、大头、块面塑形、粗黑轮廓、手绘磨损、紫黑军装与红色识别元素。
- 每个角色必须使用现有 `Characters_Lis_SingleWeapon.gltf` 的 43 骨骼，并保留其 20 个动画名称。
- 角色四视图统一为中性 A-Pose、正交、同尺度、无透视、纯色背景；Tripo3D 输入顺序固定为前、左、后、右。
- Tripo3D 使用实测成功的 `multiview_to_model`，同时运行不超过 3 个任务；不得把四视图拼为单图。
- 每个最终角色不超过 30,000 三角面；每件武器不超过 5,000 三角面；以 Web 导出为性能基线。
- 七件武器都交付独立模型。现有玩法只映射 HK-45C→`pistol`、MP-5→`smg`、AK-47→`rifle`、战术匕首→`knife`；RPG、M4A1 和地雷仅作预览、挂件和后续储备，不新增玩法。
- 不修改模拟 tick、伤害公式、弹道、联机协议、导航或阻挡逻辑。
- 在线仍只传稳定 `StringName` 角色 ID；未知/旧 ID 拒绝，不静默回退。
- 新增用户可见中文时，必须运行字体覆盖校验并确认 Control 实际绑定 `NotoSansSC-UI.ttf`。
- 不用 Computer Use 做自动验证；视觉结果通过固定机位截图交由用户复核。
- 所有生成提示词、四视图、Tripo task ID、源 GLB、`.blend`、最终 GLB 和 QA 记录都保留。

## File Map

**Production records**

- Create: `docs/assets/player-characters/manifest.json` — 10 个最终角色、2 个共享基体、10 套兵种分件与 7 件武器的 ID、视图、Tripo 任务和验收状态。
- Create: `docs/assets/player-characters/prompt-style.md` — 全批次共享视觉约束及明确禁用项。
- Create: `docs/assets/player-characters/sample-male-assault.md` — 样板提示词、任务 ID、Blender 操作与 QA 记录。
- Create: `docs/assets/player-characters/final-qa.md` — 全批次机器验收与人工截图结果。

**Source art and models**

- Create: `assets/source_art/player_characters/bases/male_base/{front,left,right,back}.png` and `female_base/{front,left,right,back}.png` — two undecorated rig-carrier bodies.
- Create: `assets/source_art/player_characters/kits/{male,female}_{gunner,assault,medic,demolition,riot}/{front,left,right,back}.png` — ten isolated head/hair/armor/backpack/waist-leg kits, laid out as separated parts with matching registration guides.
- Create: `assets/source_art/weapons/{rpg,ak47,m4a1,tactical_knife,hk45c,landmine,mp5}/{front,left,right,back}.png`.
- Create: `assets/characters/generated/source/{male_base,female_base}_tripo.glb`.
- Create: `assets/characters/generated/source/{male,female}_{gunner,assault,medic,demolition,riot}_kit_tripo.glb`.
- Create: `assets/characters/generated/blend/{male,female}_{gunner,assault,medic,demolition,riot}.blend`.
- Create: `assets/characters/generated/{male,female}_{gunner,assault,medic,demolition,riot}.glb`.
- Create: `assets/weapons/generated/source/{rpg,ak47,m4a1,tactical_knife,hk45c,landmine,mp5}_tripo.glb`.
- Create: `assets/weapons/generated/blend/{rpg,ak47,m4a1,tactical_knife,hk45c,landmine,mp5}.blend`.
- Create: `assets/weapons/generated/{rpg,ak47,m4a1,tactical_knife,hk45c,landmine,mp5}.glb`.
- Create: `assets/weapons/generated/shotgun_legacy.glb` — 从现有模型拆出的兼容武器表现，不计入七件新生成武器。

**Runtime integration**

- Create: `scripts/player/character_visual_host.gd` — 安装角色 `model_scene`，管理默认回退模型。
- Modify: `scenes/player/Player.tscn` — `VisualRoot` 改用 `CharacterVisualHost`。
- Modify: `scripts/player/player_controller.gd` — 在动画和装备初始化前安装角色模型。
- Modify: `scripts/menu/lobby_player_preview.gd` — 支持按 `CharacterDefinition` 热换预览模型。
- Modify: `scripts/menu/seat_card.gd` — 将完整角色定义传给预览。
- Modify: `scripts/combat/weapons/weapon_definition.gd` — 新增独立武器表现资源与装配变换。
- Modify: `scripts/combat/weapons/weapon_base.gd` — 优先在角色 `WeaponHandSocket` 下实例化独立表现。
- Modify: `scripts/player/equipment_controller.gd` — 隐藏 `PreviewWeapon` 并保持旧内嵌武器兼容。
- Modify: `resources/weapons/{pistol,smg,rifle,knife,shotgun}.tres` — 绑定独立表现 GLB。

**Catalog and validation**

- Create: `resources/characters/{male,female}_{gunner,assault,medic,demolition,riot}.tres`.
- Modify: `resources/characters/character_catalog.tres` — 以十角色替换四占位角色。
- Modify: `tools/validation/validate_character_catalog.gd` — 精确要求十个新 ID 与非空 `model_scene`。
- Modify: `tools/validation/validate_character_stats_apply.gd` — 使用新角色 ID。
- Modify: `tools/validation/validate_weapon_assembly.gd` — 从独立 `visual_scene` 检查表现与 socket。
- Create: `tools/validation/validate_character_model_switching.gd` — 锁定模型安装时序。
- Create: `tools/validation/validate_generated_character_models.gd` — 骨架、动画、socket、三角面与材质契约。
- Create: `tools/fixtures/character_model_probe.tscn` — 不依赖生成资产的模型切换测试夹具。

---

### Task 1: 建立生产清单与不可变命名

**Files:**
- Create: `docs/assets/player-characters/manifest.json`
- Create: `docs/assets/player-characters/prompt-style.md`

**Interfaces:**
- Produces: 后续所有图片、Tripo、Blender 和 Godot 任务共用的 10 个角色 ID、7 个武器 ID、视图顺序与验收状态字段。

- [ ] **Step 1: 写清单**

`manifest.json` 使用以下完整结构；`views` 的数组顺序是 Tripo 接口顺序，不是 UI 展示顺序：

```json
{
  "schema_version": 1,
  "tripo_view_order": ["front", "left", "back", "right"],
  "character_budget_triangles": 30000,
  "weapon_budget_triangles": 5000,
  "bases": [
    {"id":"male_base","sex":"male","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_base","sex":"female","views":{},"tripo":{},"qa":"pending"}
  ],
  "kits": [
    {"id":"male_gunner_kit","character_id":"male_gunner","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_gunner_kit","character_id":"female_gunner","views":{},"tripo":{},"qa":"pending"},
    {"id":"male_assault_kit","character_id":"male_assault","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_assault_kit","character_id":"female_assault","views":{},"tripo":{},"qa":"pending"},
    {"id":"male_medic_kit","character_id":"male_medic","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_medic_kit","character_id":"female_medic","views":{},"tripo":{},"qa":"pending"},
    {"id":"male_demolition_kit","character_id":"male_demolition","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_demolition_kit","character_id":"female_demolition","views":{},"tripo":{},"qa":"pending"},
    {"id":"male_riot_kit","character_id":"male_riot","views":{},"tripo":{},"qa":"pending"},
    {"id":"female_riot_kit","character_id":"female_riot","views":{},"tripo":{},"qa":"pending"}
  ],
  "characters": [
    {"id":"male_gunner","sex":"male","class":"gunner","display_name":"男·机枪手","preview_weapon":"mp5","accent":"#C04A3D"},
    {"id":"female_gunner","sex":"female","class":"gunner","display_name":"女·机枪手","preview_weapon":"mp5","accent":"#C66B55"},
    {"id":"male_assault","sex":"male","class":"assault","display_name":"男·突击手","preview_weapon":"ak47","accent":"#D63B32"},
    {"id":"female_assault","sex":"female","class":"assault","display_name":"女·突击手","preview_weapon":"ak47","accent":"#E25E70"},
    {"id":"male_medic","sex":"male","class":"medic","display_name":"男·医疗兵","preview_weapon":"hk45c","accent":"#3188D8"},
    {"id":"female_medic","sex":"female","class":"medic","display_name":"女·医疗兵","preview_weapon":"hk45c","accent":"#55A3E6"},
    {"id":"male_demolition","sex":"male","class":"demolition","display_name":"男·爆破兵","preview_weapon":"rpg","accent":"#D68A2F"},
    {"id":"female_demolition","sex":"female","class":"demolition","display_name":"女·爆破兵","preview_weapon":"rpg","accent":"#E2AA47"},
    {"id":"male_riot","sex":"male","class":"riot","display_name":"男·防爆兵","preview_weapon":"tactical_knife","accent":"#3AA45B"},
    {"id":"female_riot","sex":"female","class":"riot","display_name":"女·防爆兵","preview_weapon":"tactical_knife","accent":"#55BD72"}
  ],
  "weapons": [
    {"id":"rpg","display_name":"RPG","gameplay_id":null},
    {"id":"ak47","display_name":"AK-47","gameplay_id":"rifle"},
    {"id":"m4a1","display_name":"M4A1 卡宾枪","gameplay_id":null},
    {"id":"tactical_knife","display_name":"战术匕首","gameplay_id":"knife"},
    {"id":"hk45c","display_name":"HK-45C 紧凑型战术手枪","gameplay_id":"pistol"},
    {"id":"landmine","display_name":"地雷","gameplay_id":null},
    {"id":"mp5","display_name":"MP-5 冲锋枪","gameplay_id":"smg"}
  ]
}
```

- [ ] **Step 2: 写共享视觉约束**

`prompt-style.md` 必须逐字包含以下约束，后续每次生成都引用并重复关键项：

```text
Use case: stylized-concept
Asset type: orthographic multi-view source art for image-to-3D
Style: original chunky 2.5D survival-game character; 4.5-head proportion; bold dark ink-like silhouette; hand-painted wear; angular readable shapes; purple-black tactical clothing with restrained red identifiers; based on the supplied Zombie War menu image only as an art-direction reference.
Camera: true orthographic front/left/right/back view, eye-level, no perspective, identical scale and crop.
Pose: neutral A-pose, straight spine, feet parallel, fingers relaxed and separated, no held weapon.
Backdrop: flat uniform light gray, no horizon, no floor, no cast shadow.
Constraints: one complete subject; same identity, garment seams, pouches, damage marks and colors across all views; generous padding; no text; no watermark.
Avoid: photorealism, realistic military photography, chibi below 4 heads, fisheye, three-quarter view, dramatic pose, weapon in hands, extra limbs, fused fingers, floating accessories, gradients, scenery.
```

- [ ] **Step 3: 校验 JSON 与提交**

Run:

```bash
python3 -m json.tool docs/assets/player-characters/manifest.json >/dev/null
git add docs/assets/player-characters/
git commit -m "docs(assets): define player character production manifest"
```

Expected: JSON command exits 0; commit contains only the two production documents.

---

### Task 2: 用 TDD 接通 `CharacterDefinition.model_scene`

**Files:**
- Create: `scripts/player/character_visual_host.gd`
- Create: `tools/fixtures/character_model_probe.tscn`
- Create: `tools/validation/validate_character_model_switching.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/menu/lobby_player_preview.gd`
- Modify: `scripts/menu/seat_card.gd`

**Interfaces:**
- Produces: `CharacterVisualHost.install(scene: PackedScene) -> Node3D`；`LobbyPlayerPreview.set_character_definition(definition: CharacterDefinition) -> void`。
- Consumes: 现有 `CharacterDefinition.model_scene`。

- [ ] **Step 1: 写最小模型夹具**

`tools/fixtures/character_model_probe.tscn`：

```ini
[gd_scene format=3]

[node name="ProbeCharacter" type="Node3D"]

[node name="AnimationPlayer" type="AnimationPlayer" parent="."]

[node name="WeaponHandSocket" type="Node3D" parent="."]
```

- [ ] **Step 2: 写失败校验**

`validate_character_model_switching.gd` 实例化 `Player.tscn`，构造 `CharacterDefinition.new()` 并把 `model_scene` 设为 probe；在 `add_child(player)` 前调用 `apply_character_definition()`，两帧后断言：

```gdscript
var host := player.get_node("VisualRoot") as CharacterVisualHost
_expect(host.current_model != null, "model_scene must install before equipment setup", failures)
_expect(host.current_model.name == "CharacterModel", "installed model has stable name", failures)
_expect(host.current_model.get_node_or_null("WeaponHandSocket") != null, "socket survives install", failures)
_expect(player.animation_player != null, "animation lookup runs against installed model", failures)
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_model_switching.gd
```

Expected: FAIL because `CharacterVisualHost` does not exist or `model_scene` remains unused.

- [ ] **Step 3: 实现视觉宿主**

`character_visual_host.gd`：

```gdscript
extends Node3D
class_name CharacterVisualHost

@export var fallback_scene: PackedScene
var current_model: Node3D

func install(scene: PackedScene) -> Node3D:
	if current_model != null and is_instance_valid(current_model):
		current_model.free()
	current_model = null
	var selected := scene if scene != null else fallback_scene
	if selected == null:
		return null
	current_model = selected.instantiate() as Node3D
	if current_model == null:
		return null
	current_model.name = "CharacterModel"
	add_child(current_model)
	return current_model
```

把 `Player.tscn` 的默认 GLTF 实例移除，令 `VisualRoot` 使用该脚本并把旧 GLTF 配成 `fallback_scene`。

- [ ] **Step 4: 固定玩家初始化顺序**

在 `PlayerController._ready()` 的第一行安装模型，然后才查动画和初始化装备：

```gdscript
	var visual_host := visual_root as CharacterVisualHost
	if visual_host != null:
		visual_host.install(character_definition.model_scene if character_definition != null else null)
```

保留 `apply_character_definition()` 在进树前只缓存定义和应用数值的现有时序。

- [ ] **Step 5: 让大厅预览切换完整角色模型**

给 `LobbyPlayerPreview` 增加 `set_character_definition()`：先释放旧 `character_model`，选择 `definition.model_scene`（空时用导出的 `character_scene` 回退），实例化、播放 `Idle_Gun`、重算包围盒。把 `SeatCard.set_occupied()` 的 `preview.set_accent_color(accent)` 前加入：

```gdscript
	preview.set_character_definition(character)
```

- [ ] **Step 6: 验证与提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_model_switching.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_stats_apply.gd
```

Expected: both print `PASS`.

Commit:

```bash
git add scripts/player/character_visual_host.gd scenes/player/Player.tscn scripts/player/player_controller.gd scripts/menu/lobby_player_preview.gd scripts/menu/seat_card.gd tools/fixtures/character_model_probe.tscn tools/validation/validate_character_model_switching.gd
git commit -m "feat(character): load per-definition player models"
```

---

### Task 3: 用 TDD 接通独立武器表现和骨骼 socket

**Files:**
- Modify: `scripts/combat/weapons/weapon_definition.gd`
- Modify: `scripts/combat/weapons/weapon_base.gd`
- Modify: `scripts/player/equipment_controller.gd`
- Modify: `tools/fixtures/character_model_probe.tscn`
- Modify: `tools/validation/validate_weapon_assembly.gd`

**Interfaces:**
- Produces: `WeaponDefinition.visual_scene: PackedScene`、`WeaponDefinition.visual_transform: Transform3D`、`WeaponBase.visual_instance: Node3D`。
- Socket contract: 每个正式角色包含 `WeaponHandSocket`；大厅默认武器名为 `PreviewWeapon`。

- [ ] **Step 1: 扩展夹具并写失败校验**

在 probe 的 `WeaponHandSocket` 下加入一个 `Marker3D`；在 `validate_weapon_assembly.gd` 中把旧的内嵌武器节点检查改为独立表现检查：

```gdscript
_check("character exposes WeaponHandSocket", model.find_child("WeaponHandSocket", true, false) != null)
if definition.visual_scene != null:
	_check("%s: independent visual is instanced" % label, weapon.visual_instance != null)
	_check("%s: independent visual is parented to hand socket" % label,
		weapon.visual_instance.get_parent().name == "WeaponHandSocket")
else:
	_check("%s: legacy embedded fallback resolves" % label, weapon.visual_anchor != null)
```

Run the validation and expect FAIL because `visual_scene` and `visual_instance` do not exist.

- [ ] **Step 2: 扩展数据模型**

在 `weapon_definition.gd` 加：

```gdscript
@export_group("表现")
@export var visual_scene: PackedScene
@export var visual_transform := Transform3D.IDENTITY
```

- [ ] **Step 3: 实现独立表现装配**

在 `WeaponBase.bind_context()` 中：

1. 清理上一次 `visual_instance`；
2. 若 `definition.visual_scene != null`，查找 `WeaponHandSocket`；
3. 实例化 visual scene，命名为 `String(definition.weapon_id) + "_visual"`，加到 socket，应用 `visual_transform`；
4. 将 `visual_anchor` 指向实例；
5. 若无独立 scene，则沿用现有 `visual_node_name` 搜索逻辑。

`set_equipped()` 继续统一切 `visual_anchor.visible`。`EquipmentController.EMBEDDED_WEAPON_NAMES` 加入 `&"PreviewWeapon"`，保证游戏内隐藏大厅展示件。

- [ ] **Step 4: 保持枪口契约**

不移动现有逻辑武器场景的 `Muzzle`、`MuzzleFlash` 或弹道原点；视觉枪管位置在 Blender/`visual_transform` 中对齐现有 clearance capsule。这样不触碰模拟层。

- [ ] **Step 5: 验证与提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_weapon_assembly.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: weapon assembly PASS; editor import exits 0 with no parse error.

Commit:

```bash
git add scripts/combat/weapons/weapon_definition.gd scripts/combat/weapons/weapon_base.gd scripts/player/equipment_controller.gd tools/fixtures/character_model_probe.tscn tools/validation/validate_weapon_assembly.gd
git commit -m "feat(weapon): mount independent visuals on character sockets"
```

---

### Task 4: 生成男性基体、突击手分件与 AK-47 正式四视图

**Files:**
- Create: `assets/source_art/player_characters/bases/male_base/{front,left,right,back}.png`
- Create: `assets/source_art/player_characters/kits/male_assault/{front,left,right,back}.png`
- Create: `assets/source_art/weapons/ak47/{front,left,right,back}.png`
- Create: `docs/assets/player-characters/sample-male-assault.md`

**Interfaces:**
- Consumes: 用户提供的开始页截图作为“art-direction reference”；`prompt-style.md`。
- Produces: 三套独立、同尺度的四视图 PNG，供 Task 5 的三个 Tripo 多视图请求。

- [ ] **Step 1: 准备目录并生成男性基体正视图**

用户明确要求 `image-2`，因此使用 43Coding 的正式 CLI/API 路径并显式指定 `gpt-image-2`。把开始页截图作为第一参考图：

```bash
python /Users/liangpingbo/Desktop/4399/frontend/43Coding/resources/skills/image-gen/scripts/image_gen.py edit \
  --model gpt-image-2 \
  --image /var/folders/c4/212btq_16qb7p6bpb_59pb_m0000gn/T/codex-clipboard-2cf03a6e-4255-4a5a-a490-f7fd03d56ded.png \
  --quality high --size 2048x2048 --output-format png \
  --prompt-file docs/assets/player-characters/prompts/male_base_front.txt \
  --out assets/source_art/player_characters/bases/male_base/front.png
```

`male_base_front.txt` 在共享约束后补充：男性、无兵种装备的贴身紫黑训练服、无头盔、无背包、无胸挂、无武器、正视图、A-Pose；不得带开始页 logo、菜单文字或背景。这个基体是权重载体，外表会被兵种分件覆盖。

- [ ] **Step 2: 以前视图锁定基体，分别派生左、右、后**

每个 edit 调用都传两张参考图：开始页截图负责风格，已通过的 `male_base/front.png` 负责身份与身体比例。三个提示词逐一指定“只改变相机到 left profile / right profile / exact rear；人物、A-Pose、服装裁片、颜色、磨损和尺度不变”。每次输出到对应文件，不用 `n=3`。

- [ ] **Step 3: 生成男性突击手独立兵种分件四视图**

以男性基体为尺寸注册参考，生成不带人体的分件陈列：头脸/头带、发型、中型胸挂、护肘、背包、腰包和膝垫彼此分离，围绕不可见的 4.5 头身 A-Pose 注册位置排列；不能生成皮肤、手脚、武器或把衣甲粘成完整人体。四个视图保持相同零件数量、相同注册位置和相同颜色。输出到 `kits/male_assault/`。

- [ ] **Step 4: 生成 AK-47 四视图**

先生成无手、无背带、无弹壳、无枪火的正视图，再以前视图为参考派生左、右、后。武器必须水平放置、正交、枪口朝画面右侧（后视图仍保持物体世界朝向，不镜像构造）、纯浅灰背景。

- [ ] **Step 5: 图片 QA 门槛**

用本地图像查看工具逐张核对：基体完整、分件数量一致、背景统一、方向正确、四图同一身份/装备/武器、零件没有互相粘连、无手持粘连、无额外装备、左右没有意外镜像文字。任一失败只重做该视图；把最终提示词和选择理由写入 `sample-male-assault.md`。

- [ ] **Step 6: 提交源图**

```bash
git add assets/source_art/player_characters/bases/male_base assets/source_art/player_characters/kits/male_assault assets/source_art/weapons/ak47 docs/assets/player-characters/
git commit -m "feat(assets): generate male assault and AK-47 turnarounds"
```

---

### Task 5: 用真实四视图生成样板的三个 Tripo GLB

**Files:**
- Create: `assets/characters/generated/source/male_base_tripo.glb`
- Create: `assets/characters/generated/source/male_assault_kit_tripo.glb`
- Create: `assets/weapons/generated/source/ak47_tripo.glb`
- Modify: `docs/assets/player-characters/sample-male-assault.md`

**Interfaces:**
- Consumes: Task 4 的八张 PNG。
- Produces: 三个真实 `multiview_to_model` task ID、原始 GLB 和预览 URL。

- [ ] **Step 1: Tripo/COS 预检**

从 `~/Library/Application Support/43Coding/settings.json` 只在进程内读取 `aihubApiUrl`/`aihubApiKey`，不得打印密钥。上传正式 PNG 前必须取得 Filebed `COS_TOKEN`；如果 43Coding 当前会话和本机配置都没有该 token，立即停止本 Task 并告诉用户在 43Coding 配置上传令牌，不能把本地路径或 `file://` 伪装成远程 URL。

- [ ] **Step 2: 上传并提交男性基体四图**

上传四图取得 URL 后，向：

```text
{AIHUB_HOST}/api/aihub/v1/rawproxy/tripo3d/v2/openapi/task
```

提交：

```json
{
  "type":"multiview_to_model",
  "files":[
    {"type":"png","url":"FRONT_UPLOADED_URL"},
    {"type":"png","url":"LEFT_UPLOADED_URL"},
    {"type":"png","url":"BACK_UPLOADED_URL"},
    {"type":"png","url":"RIGHT_UPLOADED_URL"}
  ],
  "model_version":"v2.5-20250123",
  "texture":true,
  "texture_quality":"detailed",
  "texture_alignment":"original_image",
  "pbr":true,
  "quad":true,
  "auto_size":false
}
```

- [ ] **Step 3: 提交突击手分件和 AK-47 四图并轮询**

同样提交分件与武器任务。三个任务可以并发，但每 10 秒轮询一次，最多 60 次。只在 `status == success` 时下载；失败保留 task ID 和错误，不盲目重提。

- [ ] **Step 4: 下载与校验**

立即下载签名 URL，使用 `file` 和 Godot/Blender 导入确认是 GLB；在 `sample-male-assault.md` 记录 task ID、消耗 credits、原 URL、下载时间和本地路径。

- [ ] **Step 5: 提交原始模型**

```bash
git add assets/characters/generated/source/male_base_tripo.glb assets/characters/generated/source/male_assault_kit_tripo.glb assets/weapons/generated/source/ak47_tripo.glb docs/assets/player-characters/sample-male-assault.md
git commit -m "feat(assets): generate male assault Tripo source models"
```

---

### Task 6: 用 Blender MCP 完成样板骨架、武器和导出

**Files:**
- Create: `assets/characters/generated/blend/male_assault.blend`
- Create: `assets/weapons/generated/blend/ak47.blend`
- Create: `assets/characters/generated/male_assault.glb`
- Create: `assets/weapons/generated/ak47.glb`
- Modify: `docs/assets/player-characters/sample-male-assault.md`

**Interfaces:**
- Consumes: 现有 43 骨骼/20 动画 GLTF 与 Task 5 三个源 GLB。
- Produces: `male_assault.glb`（含 `WeaponHandSocket`、`WeaponBackSocket`、`MineHipSocket`、`PreviewWeapon`）和独立 `ak47.glb`。

- [ ] **Step 1: Blender MCP 连接门槛**

确认 Blender 4.4.3 正在运行、`blender_mcp_addon.py` 已启用且 MCP server 返回 scene info。若当前 Codex 工具列表没有 `blender` server，先在 43Coding 启用 Blender MCP 并重开任务；不得用 shell Blender Python 冒充用户要求的 Blender MCP 装配。

- [ ] **Step 2: 建立母版场景**

通过 Blender MCP 的 Python 执行能力：清空临时场景；导入 `Characters_Lis_SingleWeapon.gltf`、`male_base_tripo.glb`、`male_assault_kit_tripo.glb`、`ak47_tripo.glb`；把源文件分别放入 `REFERENCE_RIG`、`BODY_SOURCE`、`KIT_SOURCE`、`WEAPON_SOURCE` collection。所有对象应用 scale/rotation，单位为米，角色脚底落在 Z=0。

- [ ] **Step 3: 清理与减面**

删除生成网格内部孤岛、非流形碎片和不可见重复面；保留脸、手指、衣服外轮廓。AK-47 先减至 ≤5,000 triangles；角色与默认预览武器合计 ≤30,000 triangles。记录清理前后统计。

- [ ] **Step 4: 绑定现有骨架与动画**

保留参考 GLTF 的 armature、43 骨骼和 20 个 animation actions；将男性基体对齐参考 bind pose，转移权重后对头、肩、肘、腕、髋、膝手工修正。再把突击手分件逐件贴合基体：头脸/头发替换可见基体头部，贴身胸挂与护具转移邻近身体权重，背包和腰包用骨骼刚性绑定。删除旧人物网格和被完全覆盖的基体表面，但保留 armature/actions。

- [ ] **Step 5: 建立挂点并装配默认展示武器**

在现有持枪手骨 `Middle1.L` 下建立 `WeaponHandSocket`，在 torso/back 骨建立 `WeaponBackSocket`，在 hips 骨建立 `MineHipSocket`。复制经过清理的 AK-47 到角色文件，命名 `PreviewWeapon` 并挂到 `WeaponHandSocket`；独立 AK-47 文件保持原点为握把基准、+Y/up 与 Godot 导入规则一致。

- [ ] **Step 6: 动画抽检与固定视角截图**

依次播放 `Idle`、`Idle_Gun`、`Walk_Gun`、`Run_Gun`、`Slash`、`Stab`、`HitReact`、`Death`；重点检查手掌、胸挂、肩肘、背包、膝部和枪托。通过 Blender MCP 获取正面、左侧、背面和 2.5D 俯视截图；不合格就修权重或附件形状。

- [ ] **Step 7: 保存与导出**

用 Blender MCP 保存两个 `.blend`，导出 GLB，包含 armature、skin、materials、animations 和 empties，不导出参考 collection。用 Blender scene info 确认名字和统计后提交：

```bash
git add assets/characters/generated/blend/male_assault.blend assets/weapons/generated/blend/ak47.blend assets/characters/generated/male_assault.glb assets/weapons/generated/ak47.glb docs/assets/player-characters/sample-male-assault.md
git commit -m "feat(assets): rig and assemble male assault sample"
```

---

### Task 7: 样板 Godot 接入与人工视觉门槛

**Files:**
- Create: `resources/characters/male_assault.tres`
- Modify: `resources/weapons/rifle.tres`
- Create: `tools/validation/validate_generated_character_models.gd`
- Modify: `docs/assets/player-characters/sample-male-assault.md`

**Interfaces:**
- Produces: 可在 Godot 实例化、播放动画并持 AK-47 的单角色垂直切片；批量生产放行信号。

- [ ] **Step 1: 写模型契约校验**

校验脚本加载 `male_assault.glb`，递归统计：Skeleton3D 恰有 43 bones；动画名集合等于当前参考 GLTF 的 20 个名称；存在三个 socket；三角面 ≤30,000；每个 MeshInstance3D 的材质可加载。加载 `ak47.glb` 并断言三角面 ≤5,000。

- [ ] **Step 2: 先运行并修复导入问题**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_generated_character_models.gd
```

Expected: `validate_generated_character_models: PASS`。

- [ ] **Step 3: 临时接入样板**

`male_assault.tres` 迁移现有突击数值：`move_speed_mult=0.92`、`signature_weapon_id=&"rifle"`、`signature_weapon_damage_mult=1.25`、`passive_id=&"suppression"`、`model_scene=male_assault.glb`。`rifle.tres.visual_scene` 指向 `ak47.glb`，用 `visual_transform` 对齐手和枪口。

- [ ] **Step 4: 运行回归**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_model_switching.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_weapon_assembly.gd
```

Expected: both PASS。

- [ ] **Step 5: 用户视觉验收**

启动单机，选择样板角色，依次执行：静止、移动、持步枪移动、贴墙抬枪、攻击、受击、死亡；再进入大厅观察 `Idle_Gun`。请用户截取大厅全身图和游戏内持枪俯视图。只有用户确认角色比例、漫画感、枪手关系与穿模可接受，才能进入 Task 8。

- [ ] **Step 6: 提交垂直切片**

```bash
git add resources/characters/male_assault.tres resources/weapons/rifle.tres tools/validation/validate_generated_character_models.gd docs/assets/player-characters/sample-male-assault.md
git commit -m "feat(character): integrate male assault vertical slice"
```

---

### Task 8: 并发生成剩余角色与武器四视图

**Files:**
- Create: `assets/source_art/player_characters/bases/female_base/{front,left,right,back}.png`.
- Create: remaining 9 kit view folders under `assets/source_art/player_characters/kits/`.
- Create: remaining 6 weapon view folders under `assets/source_art/weapons/`.
- Modify: `docs/assets/player-characters/manifest.json`.

**Interfaces:**
- Consumes: 用户通过的 `male_assault/front.png` 作为全家族比例/材质参考；各性别基体通过的正视图作为身份参考。
- Produces: 64 张最终 PNG（1 个女性基体×4 + 9 套分件×4 + 6 件武器×4）。

- [ ] **Step 1: 先生成女性突击手正视图作为 female base**

使用开始页截图、男性基体和 B 风格约束；保持同骨架兼容比例，但明确女性肩宽、腰胯和贴身训练服裁片，不做男性模型简单缩放。女性角色的可见脸型与发型放在各自兵种分件中。

- [ ] **Step 2: 按角色独立并发**

不同兵种分件的正视图任务可以并发；同一套分件的左/右/后必须等正视图通过后再并发派生。每个调用显式使用 `gpt-image-2`，每个资产独立调用，不用 `n` 代替不同提示词。每套分件都只生成头脸/发型/头盔/护甲/背包/腰腿附件，不重复生成完整人体。

- [ ] **Step 3: 完整兵种差异**

机枪手加入弹匣袋与紧凑背带；医疗兵加入医疗包和止血带但不依赖字形符号；爆破兵加入肩垫、工具包、腰挂地雷；防爆兵加入宽肩重甲和护臂。所有角色仍不持武器。

- [ ] **Step 4: 并发生成剩余武器**

RPG、M4A1、战术匕首、HK-45C、地雷、MP-5 分别完成四视图。长枪水平枪口朝右；匕首刀尖朝右；地雷以正面/侧面/背面/另一侧展示，保持世界朝向一致。

- [ ] **Step 5: 全量图像 QA 与提交**

逐项在 manifest 标记四视图通过。任何身份漂移只重做失败视角。确认 76 张总源图（样板 12 + 本 Task 64）齐全后：

```bash
git add assets/source_art/player_characters assets/source_art/weapons docs/assets/player-characters/manifest.json
git commit -m "feat(assets): generate complete character and weapon turnarounds"
```

---

### Task 9: 受控并发生成全部剩余 Tripo 源模型

**Files:**
- Create: `assets/characters/generated/source/female_base_tripo.glb` and remaining 9 `*_kit_tripo.glb`.
- Create: remaining `assets/weapons/generated/source/*_tripo.glb`.
- Modify: `docs/assets/player-characters/manifest.json`.

**Interfaces:**
- Produces: 16 个剩余 Tripo task ID 与 GLB（1 个女性基体 + 9 套兵种分件 + 6 件武器）。

- [ ] **Step 1: 建立待处理队列**

只从 manifest 读取 ID，并验证每项四张 PNG 都存在且非空；不满足就不提交。

- [ ] **Step 2: 以 3 个任务为上限并发**

每项都用正式四图 `multiview_to_model` 载荷，顺序前、左、后、右。保持一个三槽任务池：某任务 success/failed 后才补下一个，不一次性发 16 个。

- [ ] **Step 3: 每个成功任务立即下载**

下载到明确的 `*_tripo.glb`，记录 task ID、credits、预览 URL 与 SHA-256。失败项保留错误并只重试一次；第二次失败停止该项并报告用户。

- [ ] **Step 4: 完整性校验与提交**

```bash
find assets/characters/generated/source assets/weapons/generated/source -name '*_tripo.glb' -size +0 | wc -l
```

Expected: `19`（2 个基体 + 10 套兵种分件 + 7 件武器）。然后提交源模型与更新后的 manifest。

---

### Task 10: Blender MCP 批量清理、共骨架、装配与导出

**Files:**
- Create: remaining character/weapon `.blend` and final `.glb` files.
- Create: `assets/weapons/generated/shotgun_legacy.glb`.
- Modify: `docs/assets/player-characters/manifest.json`.

**Interfaces:**
- Consumes: 样板 `.blend` 的 collection、命名、材质、socket 和导出设置。
- Produces: 10 个可动画角色 GLB、7 个独立武器 GLB、1 个旧 shotgun 兼容 GLB。

- [ ] **Step 1: 从样板建立男女母版**

男性角色复用 `male_base` 骨架/权重；女性突击手先用 `female_base` 完成一遍完整权重修整，作为女性母版。不得直接复制男性身体权重后不检查肩、胸、髋。十套兵种分件保持独立 collection，便于只返工失败部件。

- [ ] **Step 2: 武器清理可并行准备**

七件武器分别归一化尺寸、握把原点、朝向、材质和面数。AK-47/HK-45C/MP-5/匕首对齐现有四个 gameplay archetype；M4A1/RPG/地雷保留标准 socket transform 供预览和未来使用。

- [ ] **Step 3: 拆出现有 shotgun**

从 `Characters_Lis_SingleWeapon.gltf` 提取现有 `Shotgun` 网格为独立 GLB，使新角色仍能显示现有散弹枪玩法，而不额外生成用户未要求的新武器。

- [ ] **Step 4: 装配十角色**

每个角色保留相同 43 骨骼、20 动画和三个 socket；装入其默认展示武器副本并命名 `PreviewWeapon`。对装备做刚性骨骼绑定或局部蒙皮，不把背包权重扩散到手臂。

- [ ] **Step 5: 全动画与预算检查**

每个角色机器检查 20 个动画存在；人工抽检 Task 6 的八个动画。任何角色 >30k 或武器 >5k 时只处理该资产。所有 Blender MCP viewport 截图与统计写入 manifest。

- [ ] **Step 6: 保存、导出与提交**

保存全部 `.blend`，导出最终 GLB；确认 10+7+1 个最终模型齐全，再提交：

```bash
git add assets/characters/generated assets/weapons/generated docs/assets/player-characters/manifest.json
git commit -m "feat(assets): assemble complete modular character roster"
```

---

### Task 11: 替换十角色目录并绑定玩法表现

**Files:**
- Create: remaining 9 `resources/characters/*.tres`.
- Modify: `resources/characters/character_catalog.tres`.
- Modify: `resources/weapons/{pistol,smg,rifle,knife,shotgun}.tres`.
- Modify: `tools/validation/validate_character_catalog.gd`.
- Modify: `tools/validation/validate_character_stats_apply.gd`.
- Modify: `tools/validation/validate_generated_character_models.gd`.

**Interfaces:**
- Produces: 只含十个新 ID 的角色目录；五个现有 gameplay weapon 都有独立表现。

- [ ] **Step 1: 写十个角色资源**

男女同兵种使用相同玩法基线，仅 `character_id`、`display_name`、`accent_color`、`model_scene` 不同：

- gunner：迁移原突击 `suppression`，`signature_weapon_id=&"smg"`；
- assault：迁移原突击数值，但 `signature_weapon_id=&"rifle"` 以匹配 AK-47 表现；
- medic：迁移原医疗 `pistol`/`medic_aura`；
- demolition：迁移原工兵 `rifle`/`fortify`，RPG 只作预览；
- riot：迁移原防爆 `shotgun`/`blast_armor`，匕首只作预览。

不得创建 `rpg`、`landmine` 或 `m4a1` gameplay ID。

- [ ] **Step 2: 替换目录**

`character_catalog.tres.entries` 的第一个角色固定为 `male_assault`（默认 ID），随后按 female assault、男女 gunner、男女 medic、男女 demolition、男女 riot 排列。删除对四个 `survivor_*` 资源的目录引用，但此时不删除文件。

- [ ] **Step 3: 绑定现有武器表现**

设置：`pistol→hk45c.glb`、`smg→mp5.glb`、`rifle→ak47.glb`、`knife→tactical_knife.glb`、`shotgun→shotgun_legacy.glb`。逐把校准 `visual_transform`。

- [ ] **Step 4: 更新稳定验证**

`validate_character_catalog.gd` 将最小数量改为精确 `10`，断言 ID 集合与 manifest 完全相等、每个 `model_scene != null`、旧 `survivor_*` 查找返回 null。`validate_character_stats_apply.gd` 用新 medic/riot/assault ID 验证原有数值与被动。

- [ ] **Step 5: 运行目录与角色回归**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_catalog.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_stats_apply.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_signature_weapon_scale.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_generated_character_models.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_weapon_assembly.gd
```

Expected: all PASS。

- [ ] **Step 6: 引用检查后处理旧资源并提交**

用 `rg` 检查 `survivor_*.tres` 和旧 GLTF 的引用。旧 GLTF 仍作为 fallback/动画源或 shotgun 提取源时保留；四个旧 `.tres` 若零引用则删除并说明可从 git 恢复。

Commit:

```bash
git add resources/characters resources/weapons tools/validation
git commit -m "feat(character): replace placeholder roster with ten generated characters"
```

---

### Task 12: 最终导入、联机内容、Web 与视觉验收

**Files:**
- Modify: `docs/assets/player-characters/final-qa.md`

**Interfaces:**
- Produces: 可复现的最终验收记录与用户视觉确认。

- [ ] **Step 1: 全量 headless 导入**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0; no scene/script/import parse errors.

- [ ] **Step 2: 运行聚焦验证矩阵**

```bash
for script in \
  validate_character_catalog.gd \
  validate_character_model_switching.gd \
  validate_generated_character_models.gd \
  validate_character_stats_apply.gd \
  validate_signature_weapon_scale.gd \
  validate_weapon_assembly.gd \
  validate_online_room_panel.gd \
  validate_online_frame_sync.gd \
  validate_ui_font_coverage.gd; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script "res://tools/validation/$script" || exit 1
done
```

Expected: every script PASS. `online_frame_sync` guards that no accidental protocol drift occurred.

- [ ] **Step 3: Web 导出**

```bash
mkdir -p build/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
```

Expected: export exits 0. Do not commit `build/`.

- [ ] **Step 4: 用户完成最终视觉矩阵**

请用户在本地大厅依次切换十角色，截取至少一张包含男女各一、五兵种覆盖的角色卡组合；进入单机后依次检查五个 gameplay weapon 的持握、跑动、贴墙抬枪、攻击和收起。对 RPG、M4A1、地雷检查 Blender 转台或角色预览装配，不声称它们已有玩法。

- [ ] **Step 5: 填写 QA 记录并最终提交**

`final-qa.md` 记录：所有命令与结果、10 角色/7 武器三角面、43 bones、20 animations、Tripo task IDs、Blender 文件、截图路径、用户确认和已知限制。

```bash
git add docs/assets/player-characters/final-qa.md
git commit -m "test(assets): record generated character acceptance"
```

---

## Completion Criteria

- 10 个新角色 ID 替换 4 个占位 ID，目录未知 ID 不回退。
- 10 个角色各自加载正确 `model_scene`，大厅与游戏内都显示所选角色。
- 每个角色 43 bones、20 animations、≤30k triangles、三个 socket 完整。
- 7 件武器各自有独立 GLB 和 `.blend`，≤5k triangles；五个现有 gameplay weapon 有可用表现。
- RPG、M4A1、地雷只作为资产/预览，不修改模拟或协议。
- 所有聚焦 headless 验证通过，Web 导出成功，用户完成视觉截图复核。
