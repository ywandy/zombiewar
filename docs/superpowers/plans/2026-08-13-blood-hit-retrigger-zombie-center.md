# 血迹重复命中重播与僵尸中心定位 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让每次有效命中都从模拟层僵尸实体中心对应的脚底位置重新播放地面血迹扩散，并把普通命中直径扩大到 `2.40～2.80` 米、击杀命中直径扩大到 `2.80～3.20` 米。

**Architecture:** `SimWorld` 在既有命中事件中同时保留身体命中点 `position` 与实体中心 `zombie_position`；`GameplayArena` 继续用命中点播放身体反馈和 3D 血滴，只用实体中心排队脚下血迹。`GroundBloodManager` 在同格层数已满时继续合并既有血迹，但显式调用 `GroundBloodSplat.retrigger_expansion()` 重播 0.30 秒程序化径向扩散，既保留永久血迹和池化上限，也保证每次命中都有可见反馈。

**Tech Stack:** Godot 4.7.1、GDScript、SceneTree headless 验证脚本、Git worktree。

## Global Constraints

- GDScript 使用 tab 缩进；运行时代码放在 `scripts/`，验证脚本放在 `tools/validation/`。
- `SimWorld.apply_zombie_damage()` 的参数列表保持不变；新增字段只进入表现事件，不进入联机帧协议或 frame hash。
- `position` 与 `height` 继续表示实际身体命中点；`zombie_position: Vector2` 只用于地面持久血迹定位。
- 普通命中最终直径必须在 `2.40～2.80` 米，击杀命中最终直径必须在 `2.80～3.20` 米；扩散时长保持 `0.30` 秒。
- 地面血迹继续使用程序化 Shader，不引入贴图；空中命中效果继续保持 9 个 3D 血滴。
- 血迹继续永久保留到场景重开；池上限、队列帧预算、`blood_surface` 射线规则保持不变。
- 不修改伤害、击退、死亡、导航、联机协议、frame hash 或模拟 tick 推进。
- 新 worktree 首次 Godot 导入必须串行执行；如导入改动 `docs/sounds_975 2/*.translation`，使用 `git restore -- 'docs/sounds_975 2'` 排除缓存噪声。
- 不使用 CUA 做视觉自动验证；自动验证无法覆盖的手感由最终人工验收步骤确认。
- 所有 Task 和最终验证完成后，将本轮 checkpoint squash 成一个 Conventional Commit：`fix(fx): retrigger blood pools from zombie centers`。

---

## 文件结构

- `tools/validation/validate_procedural_blood_fx.gd`：新增稳定行为契约，覆盖模拟事件字段、Arena 脚底定位、同格合并重播和普通/击杀尺寸范围。
- `scripts/sim/sim_world.gd`：在命中结算当刻把对应僵尸实体中心写入 `tick_hit_events`。
- `scripts/gameplay/gameplay_arena.gd`：区分身体命中点与脚下血迹中心，确保远近景僵尸都使用模拟坐标。
- `scripts/fx/ground_blood_splat.gd`：提供只重置扩散状态、不覆盖几何与颜色的 `retrigger_expansion()`。
- `scripts/fx/ground_blood_manager.gd`：同格合并后显式重播扩散，并扩大两档命中血迹直径。

### Task 1: 用失败验证锁定新增契约

**Files:**
- Modify: `tools/validation/validate_procedural_blood_fx.gd`

**Interfaces:**
- Consumes: `SimWorld.apply_zombie_damage(index, damage_points, hit_position, hit_height, direction, zone) -> bool`、`GameplayArena._on_sim_hit_event(event: Dictionary) -> void`、`GroundBloodManager.place_splat(...) -> GroundBloodSplat`、`GroundBloodManager.spawn_hit_splat(world_position, intensity, killed) -> GroundBloodSplat`。
- Produces: 对 `tick_hit_events[*].zombie_position: Vector2`、脚下请求坐标、同格重播状态和尺寸范围的回归契约。

- [ ] **Step 1: 为模拟事件新增实体中心断言**

在文件顶部加入模拟脚本预加载：

```gdscript
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
```

在 `_run()` 中、Arena 验证之前调用：

```gdscript
_test_sim_hit_event_includes_zombie_center()
```

新增验证函数，故意让身体命中点与实体中心不同：

```gdscript
func _test_sim_hit_event_includes_zombie_center() -> void:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-12.5, -12.5), 1.0, 25, 25)
	world.reset(20260813)
	world.configure_zombie_profile(0, 50, 1.3)
	world.spawn_zombie(Vector2(4.0, 6.0), 0.0, 0)
	world.apply_zombie_damage(
		0,
		100,
		Vector2(1.0, -1.0),
		1.1,
		Vector2.RIGHT,
		&"body"
	)
	_check("an applied hit must emit one hit event", world.tick_hit_events.size() == 1)
	if world.tick_hit_events.size() == 1:
		var event: Dictionary = world.tick_hit_events[0]
		_check(
			"hit events must carry the zombie entity center separately from the body hit",
			event.get("zombie_position") == Vector2(4.0, 6.0)
		)
```

- [ ] **Step 2: 让 Arena 验证证明脚下坐标不再偷用身体命中点**

把 `_hit_event()` 返回值扩展为：

```gdscript
func _hit_event(killed: bool) -> Dictionary:
	return {
		"zombie_id": 1,
		"position": Vector2(1.0, -1.0),
		"zombie_position": Vector2(4.0, 6.0),
		"height": 1.1,
		"direction": Vector2.RIGHT,
		"damage": 25.0,
		"zone": &"body",
		"killed": killed,
	}
```

把 `_test_arena_queues_one_foot_centered_splat_per_hit()` 中的位置断言改为：

```gdscript
_check(
	"persistent blood must use the simulated zombie center instead of the body hit",
	normal_request["position"] == Vector3(4.0, 0.0, 6.0)
)
```

- [ ] **Step 3: 新增同格合并后完整重播扩散的验证**

在 `_run()` 中、Arena 验证之前加入：

```gdscript
await _test_merged_ground_splat_retriggers_expansion()
```

新增验证函数；它把层数限制为 1，确保第二次放置必走合并路径：

```gdscript
func _test_merged_ground_splat_retriggers_expansion() -> void:
	var manager := GroundBloodManagerScript.new() as GroundBloodManager
	manager.max_layers_per_cell = 1
	root.add_child(manager)
	var first := manager.place_splat(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 2.4,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	first.call("_process", 0.30)
	var size_before_merge := first.current_size
	var base_size_before_merge := first.base_size
	var position_before_merge := first.position
	var normal_before_merge := first.current_surface_normal
	var tint_before_merge := first.current_tint
	var edge_tint_before_merge := first.current_edge_tint
	var merged := manager.place_splat(
		Vector3(0.1, 0.0, 0.1),
		Vector3.UP,
		Vector2.ONE * 2.6,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	_check("a full cell must merge into its existing layer", merged == first)
	_check(
		"a repeated hit must restart the merged layer from its center",
		is_equal_approx(merged.expansion_progress, 0.0)
	)
	_check(
		"retriggering expansion must not shrink the merged blood pool",
		merged.current_size.x >= size_before_merge.x and
		merged.current_size.y >= size_before_merge.y
	)
	_check(
		"retriggering expansion must preserve the original pool geometry and tints",
		merged.base_size == base_size_before_merge and
		merged.position == position_before_merge and
		merged.current_surface_normal == normal_before_merge and
		merged.current_tint != Color.WHITE and
		merged.current_tint.r <= tint_before_merge.r and
		merged.current_edge_tint.r <= edge_tint_before_merge.r
	)
	merged.call("_process", 0.30)
	_check(
		"a retriggered blood pool must complete another 0.30 second expansion",
		is_equal_approx(merged.expansion_progress, 1.0) and merged.visible
	)
	manager.queue_free()
	await process_frame
```

- [ ] **Step 4: 新增普通与击杀命中直径范围验证**

在 `_run()` 中、Arena 验证之后加入：

```gdscript
await _test_hit_splat_diameter_ranges()
```

新增真实场景验证，通过现有 `blood_surface` 射线调用公开入口：

```gdscript
func _test_hit_splat_diameter_ranges() -> void:
	var arena := DemoMapScene.instantiate()
	root.add_child(arena)
	await process_frame
	await physics_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	var normal := manager.spawn_hit_splat(Vector3(-4.0, 0.0, 4.0), 1.0, false)
	var killed := manager.spawn_hit_splat(Vector3(4.0, 0.0, 4.0), 1.0, true)
	_check("normal hits must find the demo map blood surface", normal != null)
	_check("killing hits must find the demo map blood surface", killed != null)
	if normal != null:
		_check(
			"normal hit diameter must stay within 2.40 to 2.80 meters",
			normal.base_size.x >= 2.40 and normal.base_size.x <= 2.80 and
			normal.base_size.y >= 2.40 and normal.base_size.y <= 2.80
		)
	if killed != null:
		_check(
			"killing hit diameter must stay within 2.80 to 3.20 meters",
			killed.base_size.x >= 2.80 and killed.base_size.x <= 3.20 and
			killed.base_size.y >= 2.80 and killed.base_size.y <= 3.20
		)
	arena.queue_free()
	await process_frame
```

- [ ] **Step 5: 运行聚焦验证并确认它因缺少实现而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_procedural_blood_fx.gd 2>&1 | tee /tmp/zombiewar-blood-red.log
```

Expected: 进程报告失败，日志至少包含以下契约失败：

```text
hit events must carry the zombie entity center separately from the body hit
persistent blood must use the simulated zombie center instead of the body hit
a repeated hit must restart the merged layer from its center
normal hit diameter must stay within 2.40 to 2.80 meters
killing hit diameter must stay within 2.80 to 3.20 meters
```

同时检查日志没有测试脚本自身的 `SCRIPT ERROR` 或 `Parse Error`；如果 Godot 返回码为 0，仍以日志中的失败信息为准。

- [ ] **Step 6: 提交 RED checkpoint**

```bash
git add tools/validation/validate_procedural_blood_fx.gd
git commit -m "test(fx): cover repeat-hit blood feedback"
```

### Task 2: 从模拟事件接通僵尸实体中心

**Files:**
- Modify: `scripts/sim/sim_world.gd:1135-1144`
- Modify: `scripts/gameplay/gameplay_arena.gd:1019-1044`
- Test: `tools/validation/validate_procedural_blood_fx.gd`

**Interfaces:**
- Consumes: `zombie_position: Array[Vector2]` 中命中索引对应的确定性实体中心。
- Produces: `tick_hit_events[*]["zombie_position"]: Vector2`，以及 `GroundBloodManager.queue_hit_splat(Vector3(zombie_x, 0.0, zombie_z), 1.0, killed)`。

- [ ] **Step 1: 在命中事件中加入僵尸实体中心**

把 `tick_hit_events.append()` 改为：

```gdscript
	tick_hit_events.append({
		"zombie_id": zombie_id[index],
		"position": hit_position,
		"zombie_position": zombie_position[index],
		"height": hit_height,
		"direction": direction,
		"damage": float(applied) / float(HEALTH_SCALE),
		"zone": zone,
		"killed": killed,
	})
```

字段必须在死亡分支把 `zombie_state` 改为 `STATE_DEAD` 前记录，且不得改变 `apply_zombie_damage()` 的签名。

- [ ] **Step 2: 让 Arena 只用新增字段定位脚下血迹**

把 `_on_sim_hit_event()` 开头改为：

```gdscript
func _on_sim_hit_event(event: Dictionary) -> void:
	var planar: Vector2 = event["position"]
	var hit_position := Vector3(planar.x, float(event["height"]), planar.y)
	var zombie_planar: Vector2 = event["zombie_position"]
	var foot_position := Vector3(zombie_planar.x, 0.0, zombie_planar.y)
	var planar_direction: Vector2 = event["direction"]
```

后续身体命中反应、3D 血滴和伤害数字继续使用 `hit_position`；只有 `manager.queue_hit_splat()` 使用 `foot_position`。

- [ ] **Step 3: 运行聚焦验证并确认定位契约转绿**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_procedural_blood_fx.gd 2>&1 | tee /tmp/zombiewar-blood-center-green.log
```

Expected: 不再出现以下两条失败：

```text
hit events must carry the zombie entity center separately from the body hit
persistent blood must use the simulated zombie center instead of the body hit
```

同格重播与扩大尺寸的断言仍应失败，证明本 Task 只接通坐标数据流。

- [ ] **Step 4: 提交模拟事件与 Arena 接线 checkpoint**

```bash
git add scripts/sim/sim_world.gd scripts/gameplay/gameplay_arena.gd
git commit -m "fix(fx): place hit blood at zombie centers"
```

### Task 3: 重播合并扩散并扩大命中血迹

**Files:**
- Modify: `scripts/fx/ground_blood_splat.gd:74-106`
- Modify: `scripts/fx/ground_blood_manager.gd:173-232`
- Test: `tools/validation/validate_procedural_blood_fx.gd`

**Interfaces:**
- Consumes: `GroundBloodManager.place_splat(..., duration_seconds: float)` 的当前调用参数。
- Produces: `GroundBloodSplat.retrigger_expansion(duration_seconds: float = 0.30) -> void`；普通与击杀命中扩大后的固定直径区间。

- [ ] **Step 1: 抽出可复用的扩散重播方法**

在 `GroundBloodSplat` 中、`_process()` 前新增：

```gdscript
func retrigger_expansion(duration_seconds: float = 0.30) -> void:
	expansion_duration = maxf(duration_seconds, 0.001)
	expansion_elapsed = 0.0
	expansion_progress = 0.0
	set_instance_shader_parameter("reveal_radius", MIN_REVEAL_RADIUS)
	visible = true
	set_process(true)
```

把 `setup()` 末尾的扩散重置逻辑收敛为：

```gdscript
	material_override = _get_shared_material()
	set_instance_shader_parameter("center_tint", current_tint)
	set_instance_shader_parameter("edge_tint", current_edge_tint)
	retrigger_expansion(duration_seconds)
```

并删除 `setup()` 中重复的 `expansion_duration`、`expansion_elapsed`、`expansion_progress`、`reveal_radius`、`visible`、`set_process(true)` 赋值。该方法不得修改 `base_size`、`current_size`、位置、表面法线、旋转或颜色。

- [ ] **Step 2: 在同格合并调用点显式重播扩散**

把 `GroundBloodManager.place_splat()` 的合并分支改为：

```gdscript
	if existing_layers.size() >= maxi(max_layers_per_cell, 1):
		var merged := _size_matched_layer(existing_layers, size)
		merged.merge_limited(1.15, 0.015)
		merged.retrigger_expansion(duration_seconds)
		return merged
```

保留 `merge_limited()` 的单一职责，不在该方法内部隐式调用重播。

- [ ] **Step 3: 扩大普通与击杀命中血迹直径**

把 `spawn_hit_splat()` 的尺寸区间改为：

```gdscript
	var diameter_range := Vector2(2.40, 2.80)
	var center_tint := Color(0.42, 0.005, 0.01, 0.96)
	var edge_tint := Color(0.58, 0.012, 0.018, 0.26)
	if killed:
		diameter_range = Vector2(2.80, 3.20)
		center_tint = Color(0.36, 0.003, 0.008, 0.98)
		edge_tint = Color(0.52, 0.008, 0.014, 0.32)
```

保持强度 clamp、0.30 秒时长、中心色和边缘色不变。

- [ ] **Step 4: 运行聚焦验证并确认全部转绿**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_procedural_blood_fx.gd 2>&1 | tee /tmp/zombiewar-blood-green.log
```

Expected:

```text
validate_procedural_blood_fx: PASS
```

日志中不得出现 `SCRIPT ERROR` 或 `Parse Error`。允许 Godot 退出时出现既有的资源仍在使用或 DummyRenderer RID leak 噪声，但目标验证必须明确打印 `PASS`。

- [ ] **Step 5: 提交扩散与尺寸 checkpoint**

```bash
git add scripts/fx/ground_blood_splat.gd scripts/fx/ground_blood_manager.gd
git commit -m "fix(fx): replay and enlarge merged blood pools"
```

### Task 4: 完整回归、人工验收说明与单提交整理

**Files:**
- Verify: `scripts/sim/sim_world.gd`
- Verify: `scripts/gameplay/gameplay_arena.gd`
- Verify: `scripts/fx/ground_blood_splat.gd`
- Verify: `scripts/fx/ground_blood_manager.gd`
- Verify: `tools/validation/validate_procedural_blood_fx.gd`

**Interfaces:**
- Consumes: Task 1～3 完成后的命中事件和血迹表现接口。
- Produces: 无解析错误、核心验证全部 PASS、可按固定步骤人工确认的单个计划提交。

- [ ] **Step 1: 串行运行 Godot headless 编辑器导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit \
	2>&1 | tee /tmp/zombiewar-blood-import.log
```

Expected: 日志不包含 `SCRIPT ERROR` 或 `Parse Error`。导入后执行：

```bash
git status --short
git restore -- 'docs/sounds_975 2'
```

Expected: 如果 `.translation` 缓存被首次导入改动，恢复后不再出现在工作区；不得恢复或删除本 Task 的源码和验证改动。

- [ ] **Step 2: 串行运行四个聚焦验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_procedural_blood_fx.gd \
	2>&1 | tee /tmp/zombiewar-validate-procedural-blood.log
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_combat_frame_stability.gd \
	2>&1 | tee /tmp/zombiewar-validate-combat-frame.log
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_blood_request_budget.gd \
	2>&1 | tee /tmp/zombiewar-validate-blood-budget.log
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
	--script tools/validation/validate_sim_determinism.gd \
	2>&1 | tee /tmp/zombiewar-validate-sim-determinism.log
```

Expected: 四份日志分别明确包含：

```text
validate_procedural_blood_fx: PASS
validate_combat_frame_stability: PASS
validate_blood_request_budget: PASS
validate_sim_determinism: PASS
```

并且四份日志都不包含 `SCRIPT ERROR` 或 `Parse Error`。

- [ ] **Step 3: 检查格式、范围和非目标改动**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD~3..HEAD
git log --oneline --decorate -6
```

Expected: `git diff --check` 无输出；工作区没有导入缓存或其他非目标文件；三个 checkpoint 只覆盖本计划列出的五个文件。

- [ ] **Step 4: 整理本轮 checkpoint 为一个计划提交**

先记录本功能分支创建时的基准提交：

```bash
git merge-base HEAD main
```

确认输出是创建 worktree 时的 `main` HEAD 后，执行可恢复的软重置并提交：

```bash
git reset --soft "$(git merge-base HEAD main)"
git commit -m "fix(fx): retrigger blood pools from zombie centers"
```

Expected: 本轮三个 checkpoint 被替换为一个提交，设计和计划提交仍位于共同基线历史中。

- [ ] **Step 5: 再次验证 squash 后工作区与提交内容**

Run:

```bash
git status --short --branch
git show --stat --oneline HEAD
git diff --check HEAD^ HEAD
```

Expected: 工作区干净；HEAD 主题为 `fix(fx): retrigger blood pools from zombie centers`；提交只包含：

```text
scripts/sim/sim_world.gd
scripts/gameplay/gameplay_arena.gd
scripts/fx/ground_blood_splat.gd
scripts/fx/ground_blood_manager.gd
tools/validation/validate_procedural_blood_fx.gd
```

- [ ] **Step 6: 提供固定人工验收步骤**

向用户交付以下操作，不使用 CUA：

```text
1. 启动 DemoMap，使用低射速远程武器连续命中同一只静止僵尸。
2. 确认每次命中都从僵尸实体脚下中心重新向外扩散，而不是从身体边缘或上一轮完整圆形直接加深。
3. 切换高射速武器持续命中同一位置，确认扩散可以连续重启，但没有贴图、方形边缘或无限放大。
4. 对比普通命中与击杀：普通圆直径约 2.40～2.80 米，击杀圆约 2.80～3.20 米且明显更大。
5. 走开再返回，确认血迹持续保留；重开场景后旧血迹清空。
6. 观察空中冲击，确认仍只有少量 3D 血滴，没有恢复 2D splat 贴图。
```

Expected: 六项均符合时，功能人工验收通过；如任一项不符合，记录武器、命中位置和截图后回到对应 Task 修正并重跑完整回归。
