# 程序化圆形地面血迹扩散 Implementation Plan（实施计划）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 移除命中血液效果中的 Kenney 飞溅贴图，让每次有效打击都以僵尸脚下为中心生成一片 1.6～2.15 米的程序化红色圆形血迹，中心浓、外缘渐隐，并在 0.30 秒内由中心向外扩散后永久保留到场景重开；空中命中反馈只保留少量 3D 血滴。

**架构：** `GroundBloodSplat` 继续作为贴地 `MeshInstance3D` 和对象池单元，但材质改为单份共享的无纹理 ShaderMaterial，通过 UV 距离场计算中心/边缘颜色和透明度，通过 instance uniform `reveal_radius` 驱动扩散。`GroundBloodManager` 继续负责排队、地面射线、空间合并和池化；`GameplayArena` 把模拟命中事件中的水平坐标作为脚底中心，每次命中只排一个圆形血迹请求，击杀通过同一请求的 `killed` 参数放大、加深，不再额外叠死亡血池。`BloodImpact` 删除瞬时 Sprite3D，只保留池化的 3D 血滴粒子。

**技术栈：** Godot 4.7.1、GDScript 2.0、GL Compatibility、spatial shader、MeshInstance3D、GPUParticles3D、现有 `GroundBloodManager` 对象池与源级验证脚本。

## 全局约束

- 血迹是表现层效果，不得修改 `scripts/sim/`、联机帧、命中判定、伤害、击退、死亡或 frame hash。
- 地面血迹不得使用 `assets/fx/blood/kenney_splat*.png`、其他新贴图、`Sprite3D` 或 `Decal3D`；圆形轮廓、中心到外缘渐变和扩散遮罩全部由 shader 计算。
- 地面血迹以模拟命中事件 `event["position"]` 的 XZ 坐标为中心，Y 固定为 `0.0` 后再交给 `_find_blood_surface()` 向下投影；不得以身体命中高度作为地面中心。
- 普通命中最终直径为 `1.60～1.90` 米；击杀命中最终直径为 `1.90～2.15` 米；扩散时长固定为 `0.30` 秒，完成后保持可见且不再 `_process()`，直到场景重开或对象池复用。
- 每次模拟命中只排一个持久血迹请求。击杀不得再调用 `queue_death_pool()`；已有死亡血池入口可以保留兼容，但当前 `GameplayArena` 不再使用它。
- 命中瞬时效果删除贴图飞溅，只保留 `9` 个小型 3D 血滴，粒子生命周期不超过 `0.45` 秒，并继续复用现有 bounded pool。
- 保留 `GroundBloodManager` 的帧预算、最旧请求丢弃、空间层数限制、地面 `blood_surface` 筛选、FIFO splat 复用和 FX 预热流程。
- 新增运行时 FX 仍必须满足 `warmup_for_render(context)` / `finish_render_warmup()` 或现有 manager 预热契约；预热只能触发渲染，不得播放音频或修改玩法状态。
- GDScript 使用 tabs、静态类型和 `res://` 路径；不提交 `.godot/`、`build/` 或用户已有的无关修改。
- 视觉验收不得使用 CUA 自动化。自动验证负责结构、材质、接口、队列和生命周期；最终渐变、尺寸和扩散观感使用人工游戏内验收与截图确认。
- 可在任务间建立 checkpoint commit；全部任务与最终评审完成后，只 squash 本计划产生的提交为一个 Conventional Commit：`feat(fx): add procedural expanding ground blood`。

## 文件结构与职责

- 新建 `tools/validation/validate_procedural_blood_fx.gd`：固定无贴图 shader、扩散生命周期、血滴数量、脚底队列坐标和“一次命中一个请求”的高价值契约。
- 修改 `scripts/fx/ground_blood_splat.gd`：共享程序化圆形 shader、每实例颜色/扩散参数、0.30 秒扩散状态和空间合并。
- 修改 `scenes/fx/GroundBloodSplat.tscn`：删除血迹贴图和 StandardMaterial3D，只保留无材质模板的 QuadMesh + 脚本。
- 修改 `scripts/fx/ground_blood_manager.gd`：去掉命中/拖痕/死亡血迹对 Kenney 贴图的依赖，接受 `killed` 参数，生成大尺寸圆形渐变血迹，并简化预热为一份共享 shader。
- 修改 `scripts/gameplay/gameplay_arena.gd`：命中瞬时血滴仍用身体命中点；持久血迹改用脚底中心；击杀不再额外排死亡血池。
- 修改 `scripts/fx/blood_impact.gd`：删除 Sprite3D 状态、缩放与淡出，只管理血滴粒子生命周期和池化。
- 修改 `scenes/fx/BloodImpact.tscn`：删除贴图 ext_resource 和 `Splat` 节点，把粒子数收敛为 9。
- 修改 `tools/validation/validate_combat_frame_stability.gd`：适配新 `GroundBloodSplat.setup()` / `queue_hit_splat()` 接口，断言普通命中和击杀各只增加一个请求。
- 修改 `tools/validation/validate_blood_request_budget.gd`：峰值模型从“每目标命中 + 死亡两个请求”改为“每目标一个命中请求”。
- 修改 `README.md`：把“Kenney splat + 192 instances”说明改为程序化圆形地面血迹和少量 3D 血滴，避免文档继续描述旧效果。

---

### 任务 1：先写程序化血迹契约验证

**文件：**
- 新建：`tools/validation/validate_procedural_blood_fx.gd`
- 新建：`tools/validation/validate_procedural_blood_fx.gd.uid`（由 Godot 导入生成后纳入提交）
- 修改：`tools/validation/validate_combat_frame_stability.gd:3-5,43-72,164-202`
- 修改：`tools/validation/validate_blood_request_budget.gd:38-52,109-132`

**接口：**
- 消费现有：`GroundBloodSplatScene.instantiate() -> GroundBloodSplat`。
- 预期新接口：`GroundBloodSplat.setup(surface_position: Vector3, surface_normal: Vector3, size: Vector2, rotation_radians: float, center_tint: Color, edge_tint: Color, duration_seconds: float = 0.30) -> void`。
- 预期新状态：`GroundBloodSplat.expansion_progress: float`，范围 `0.0～1.0`；扩散完成后为 `1.0` 且节点仍 `visible == true`。
- 预期新接口：`GroundBloodManager.queue_hit_splat(world_position: Vector3, intensity: float = 1.0, killed: bool = false) -> void`。
- 继续消费：`GroundBloodManager.get_pending_request_count() -> int`、`BloodImpact.is_active() -> bool`。

- [ ] **步骤 1：创建失败的专项验证入口**

创建 `tools/validation/validate_procedural_blood_fx.gd`，入口与断言骨架使用以下实际内容：

```gdscript
extends SceneTree

const GroundBloodSplatScene = preload("res://scenes/fx/GroundBloodSplat.tscn")
const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const BloodImpactScene = preload("res://scenes/fx/BloodImpact.tscn")
const DemoMapScene = preload("res://scenes/maps/demo/DemoMap.tscn")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_ground_splat_is_texture_free()
	await _test_ground_splat_expands_then_stays_visible()
	_test_blood_impact_contains_only_small_droplets()
	await _test_arena_queues_one_foot_centered_splat_per_hit()
	if failures.is_empty():
		print("validate_procedural_blood_fx: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

实现 `_test_ground_splat_is_texture_free()` 时读取两个运行时文件，锁定旧资源和旧采样器均不存在：

```gdscript
func _test_ground_splat_is_texture_free() -> void:
	var scene_source := FileAccess.get_file_as_string(
		"res://scenes/fx/GroundBloodSplat.tscn"
	)
	var script_source := FileAccess.get_file_as_string(
		"res://scripts/fx/ground_blood_splat.gd"
	)
	_check(
		"ground blood scene must not reference Kenney splat textures",
		not scene_source.contains("kenney_splat")
	)
	_check(
		"ground blood shader must be procedural instead of sampling a texture",
		not script_source.contains("sampler2D") and
		not script_source.contains("texture(splat_texture")
	)
	_check(
		"ground blood shader must expose radial reveal and edge fading",
		script_source.contains("reveal_radius") and
		script_source.contains("smoothstep")
	)
```

实现扩散测试，直接推进表现节点，不依赖物理世界：

```gdscript
func _test_ground_splat_expands_then_stays_visible() -> void:
	var splat := GroundBloodSplatScene.instantiate() as GroundBloodSplat
	root.add_child(splat)
	splat.setup(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	var shared_material_id := splat.material_override.get_instance_id()
	_check("a new ground pool must start at the center", splat.expansion_progress == 0.0)
	splat.call("_process", 0.15)
	_check(
		"ground blood must be mid-expansion after half its duration",
		splat.expansion_progress > 0.0 and splat.expansion_progress < 1.0
	)
	splat.call("_process", 0.20)
	_check(
		"ground blood must finish expansion and remain visible",
		is_equal_approx(splat.expansion_progress, 1.0) and splat.visible
	)
	splat.setup(
		Vector3.ONE,
		Vector3.UP,
		Vector2.ONE * 2.0,
		0.0,
		Color(0.38, 0.004, 0.008, 0.98),
		Color(0.55, 0.01, 0.016, 0.30),
		0.30
	)
	_check(
		"pooled ground blood must reuse the shared procedural material",
		splat.material_override.get_instance_id() == shared_material_id
	)
	splat.queue_free()
	await process_frame
```

实现血滴和接线测试：

```gdscript
func _test_blood_impact_contains_only_small_droplets() -> void:
	var impact := BloodImpactScene.instantiate() as BloodImpact
	var droplets := impact.get_node_or_null("Droplets") as GPUParticles3D
	_check("blood impact must remove the textured Splat node", impact.get_node_or_null("Splat") == null)
	_check("blood impact must keep a droplet particle node", droplets != null)
	if droplets != null:
		_check("blood impact must emit exactly 9 droplets", droplets.amount == 9)
	impact.free()

func _test_arena_queues_one_foot_centered_splat_per_hit() -> void:
	var arena := DemoMapScene.instantiate()
	root.add_child(arena)
	await process_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	manager.process_mode = Node.PROCESS_MODE_DISABLED
	var before := manager.get_pending_request_count()
	arena._on_sim_hit_event(_hit_event(false))
	arena._on_sim_hit_event(_hit_event(true))
	_check(
		"normal and killing hits must queue exactly one persistent pool each",
		manager.get_pending_request_count() == before + 2
	)
	var normal_request: Dictionary = manager.pending_requests[before]
	var kill_request: Dictionary = manager.pending_requests[before + 1]
	_check(
		"persistent blood must use zombie feet instead of body hit height",
		normal_request["position"] == Vector3(1.0, 0.0, -1.0)
	)
	_check("the kill request must carry its stronger visual tier", bool(kill_request["killed"]))
	arena.queue_free()
	await process_frame

func _hit_event(killed: bool) -> Dictionary:
	return {
		"zombie_id": 1,
		"position": Vector2(1.0, -1.0),
		"height": 1.1,
		"direction": Vector2.RIGHT,
		"damage": 25.0,
		"zone": &"body",
		"killed": killed,
	}

func _check(message: String, condition: bool) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **步骤 2：运行专项验证并确认它因旧实现失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_procedural_blood_fx.gd
```

预期：FAIL，至少包含以下旧实现差异：`GroundBloodSplat.tscn` 仍引用 `kenney_splat29.png`、`GroundBloodSplat.setup()` 参数不匹配、`BloodImpact/Splat` 仍存在、每次击杀仍额外排一个死亡血池请求。若先出现脚本解析错误，只修正验证脚本本身，直到失败落在这些产品契约上。

- [ ] **步骤 3：更新既有战斗稳定性验证的接口预期**

在 `validate_combat_frame_stability.gd` 中把复用材质测试改为新 `setup()` 签名，不再读取 `StandardMaterial3D.albedo_texture`：

```gdscript
	splat.setup(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
```

队列预算测试中的五次请求改为：

```gdscript
		manager.queue_hit_splat(
			Vector3(request_index, 0.0, 0.0),
			1.0,
			false
		)
```

Demo 接线断言改为普通命中和击杀共增加 `2` 个请求，并把错误文本改为 `GameplayArena must queue one foot-centered blood pool per hit`。

- [ ] **步骤 4：更新血迹请求预算模型**

在 `validate_blood_request_budget.gd` 中把峰值注释与计算改为“一颗弹丸命中的每个目标只排一个持久血迹请求”：

```gdscript
## 单发子弹能一次排进队列的最多血迹请求数，跨全部远程武器取最大。
## 每个被这一发打到的目标只出一个脚下圆形血迹；击杀强度通过同一请求的 killed
## 标记表达，不再额外排死亡血池。
func _peak_requests_per_shot() -> int:
	var peak := 0
	var directory := DirAccess.open(WEAPON_RESOURCE_DIRECTORY)
	if directory == null:
		return peak
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry.get_extension() == "tres":
			var definition = load(WEAPON_RESOURCE_DIRECTORY.path_join(entry))
			if definition != null and definition is RangedWeaponDefinition:
				var targets: int = definition.max_penetration_count + 1
				var pellets: int = definition.pellet_count
				peak = maxi(peak, targets * pellets)
		entry = directory.get_next()
	directory.list_dir_end()
	return peak
```

同步把 `_test_queue_is_bounded()` 的调用改为 `manager.queue_hit_splat(position, 1.0, false)`。

- [ ] **步骤 5：建立测试 checkpoint**

只暂存本任务文件，不包含当前工作区已有的 `scripts/menu/map_selection.gd` 和 `validate_enter_game_start.gd*`：

```bash
git add tools/validation/validate_procedural_blood_fx.gd \
  tools/validation/validate_procedural_blood_fx.gd.uid \
  tools/validation/validate_combat_frame_stability.gd \
  tools/validation/validate_blood_request_budget.gd
git commit -m "test(fx): define procedural blood effect contract"
```

预期：提交只包含验证契约；专项验证仍因生产代码未改而失败。

---

### 任务 2：把地面血迹改为无贴图的圆形渐变扩散

**文件：**
- 修改：`scripts/fx/ground_blood_splat.gd:4-137`
- 修改：`scenes/fx/GroundBloodSplat.tscn:1-21`
- 修改：`scripts/fx/ground_blood_manager.gd:4-20,52-101,138-252,261-327`

**接口：**
- 产出：`GroundBloodSplat.setup(surface_position: Vector3, surface_normal: Vector3, size: Vector2, rotation_radians: float, center_tint: Color, edge_tint: Color, duration_seconds: float = 0.30) -> void`。
- 产出：`GroundBloodSplat.expansion_progress: float`。
- 保留：`GroundBloodSplat.merge_limited(size_growth: float, darken_amount: float) -> void`、`surface_basis(...) -> Basis`、预热方法。
- 产出：`GroundBloodManager.queue_hit_splat(world_position: Vector3, intensity: float = 1.0, killed: bool = false) -> void`。
- 产出：`GroundBloodManager.spawn_hit_splat(world_position: Vector3, intensity: float = 1.0, killed: bool = false) -> GroundBloodSplat`。
- 保留兼容：`queue_trail_splat(...)`、`queue_death_pool(...)`、`spawn_trail_splat(...)`、`spawn_death_pool(...)`，但这些入口也必须使用程序化材质，不能继续引用贴图。

- [ ] **步骤 1：把 GroundBloodSplat 场景收敛为纯 QuadMesh**

将 `GroundBloodSplat.tscn` 改为：

```text
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/fx/ground_blood_splat.gd" id="1_script"]

[sub_resource type="QuadMesh" id="QuadMesh_blood"]
size = Vector2(1, 1)

[node name="GroundBloodSplat" type="MeshInstance3D"]
cast_shadow = 0
mesh = SubResource("QuadMesh_blood")
script = ExtResource("1_script")
```

确认场景不再包含 Texture2D ext_resource、StandardMaterial3D 或 `kenney_splat` 路径。

- [ ] **步骤 2：实现单份共享的程序化圆形 shader**

用以下 shader 契约替换 `SPLAT_SHADER_CODE` 和按贴图缓存的材质字典：

```gdscript
const SPLAT_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

instance uniform vec4 center_tint : source_color = vec4(0.42, 0.005, 0.01, 0.96);
instance uniform vec4 edge_tint : source_color = vec4(0.58, 0.012, 0.018, 0.26);
instance uniform float reveal_radius = 1.08;

void fragment() {
	vec2 centered_uv = (UV - vec2(0.5)) * 2.0;
	float radius = length(centered_uv);
	float center_weight = 1.0 - smoothstep(0.0, 0.88, radius);
	float outer_fade = 1.0 - smoothstep(0.55, 1.0, radius);
	float reveal_fade = 1.0 - smoothstep(
		max(reveal_radius - 0.08, 0.0),
		max(reveal_radius, 0.001),
		radius
	);
	vec4 blood = mix(edge_tint, center_tint, center_weight);
	ALBEDO = blood.rgb;
	ALPHA = blood.a * outer_fade * reveal_fade;
}
"""

static var _shared_shader: Shader
static var _shared_material: ShaderMaterial

static func _get_shared_material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = _get_shader()
	return _shared_material
```

继续使用 `instance uniform`，确保每片血迹可独立设色和扩散，而不会为每个对象复制材质或触发逐实例 shader 编译。

- [ ] **步骤 3：实现 0.30 秒 ease-out 扩散状态**

在 `GroundBloodSplat` 中加入实际状态：

```gdscript
const MIN_REVEAL_RADIUS := 0.08
const MAX_REVEAL_RADIUS := 1.08

var current_edge_tint := Color(0.58, 0.012, 0.018, 0.26)
var expansion_duration := 0.30
var expansion_elapsed := 0.0
var expansion_progress := 1.0

func _process(delta: float) -> void:
	expansion_elapsed = minf(expansion_elapsed + maxf(delta, 0.0), expansion_duration)
	expansion_progress = clampf(
		expansion_elapsed / maxf(expansion_duration, 0.001),
		0.0,
		1.0
	)
	var eased := 1.0 - pow(1.0 - expansion_progress, 3.0)
	set_instance_shader_parameter(
		"reveal_radius",
		lerpf(MIN_REVEAL_RADIUS, MAX_REVEAL_RADIUS, eased)
	)
	if expansion_progress >= 1.0:
		set_process(false)
```

`setup()` 必须重置池化实例并启动扩散：

```gdscript
func setup(
	surface_position: Vector3,
	surface_normal: Vector3,
	size: Vector2,
	rotation_radians: float,
	center_tint: Color,
	edge_tint: Color,
	duration_seconds: float = 0.30
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	base_size = Vector2(maxf(size.x, 0.05), maxf(size.y, 0.05))
	current_size = base_size
	current_tint = center_tint
	current_edge_tint = edge_tint
	current_surface_normal = normal
	current_rotation = rotation_radians
	expansion_duration = maxf(duration_seconds, 0.001)
	expansion_elapsed = 0.0
	expansion_progress = 0.0
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
	else:
		position = resolved_position
	_apply_size_basis()
	material_override = _get_shared_material()
	set_instance_shader_parameter("center_tint", current_tint)
	set_instance_shader_parameter("edge_tint", current_edge_tint)
	set_instance_shader_parameter("reveal_radius", MIN_REVEAL_RADIUS)
	visible = true
	set_process(true)
```

扩散完成后不能隐藏或释放。`finish_render_warmup()` 必须同时 `visible = false` 和 `set_process(false)`，避免预热实例继续更新。

- [ ] **步骤 4：让空间合并继续放大、加深程序化血迹**

保留现有最大 `15%` 的尺寸增长；`merge_limited()` 同时加深中心和边缘，但不把已经存在的血迹缩回中心重新播放：

```gdscript
	current_edge_tint = Color(
		maxf(current_edge_tint.r - darken_amount * 0.4, 0.32),
		maxf(current_edge_tint.g - darken_amount * 0.04, 0.002),
		maxf(current_edge_tint.b - darken_amount * 0.04, 0.006),
		minf(current_edge_tint.a + 0.025, 0.42)
	)
	_apply_size_basis()
	set_instance_shader_parameter("center_tint", current_tint)
	set_instance_shader_parameter("edge_tint", current_edge_tint)
```

若合并发生在原血迹仍扩散期间，保留当前 `expansion_progress`，只更新尺寸和颜色；不得重置为 `0.0`，否则连续射击会让血迹反复收缩闪烁。

- [ ] **步骤 5：重写 manager 的命中圆形尺寸与颜色**

删除 `HIT_TEXTURES` / `TRAIL_TEXTURES`，把 `queue_hit_splat()` 和 request 字典改为：

```gdscript
func queue_hit_splat(
	world_position: Vector3,
	intensity: float = 1.0,
	killed: bool = false
) -> void:
	_queue_blood_request({
		"type": BloodRequestType.HIT,
		"position": world_position,
		"intensity": intensity,
		"killed": killed,
	})
```

`_process_blood_request()` 的 HIT 分支调用：

```gdscript
		BloodRequestType.HIT:
			spawn_hit_splat(
				request["position"],
				request["intensity"],
				bool(request.get("killed", false))
			)
```

`spawn_hit_splat()` 使用脚底中心和固定尺寸档位：

```gdscript
func spawn_hit_splat(
	world_position: Vector3,
	intensity: float = 1.0,
	killed: bool = false
) -> GroundBloodSplat:
	var surface := _find_blood_surface(world_position)
	if surface.is_empty():
		return null
	var resolved_intensity := clampf(intensity, 0.85, 1.15)
	var diameter_range := Vector2(1.60, 1.90)
	var center_tint := Color(0.42, 0.005, 0.01, 0.96)
	var edge_tint := Color(0.58, 0.012, 0.018, 0.26)
	if killed:
		diameter_range = Vector2(1.90, 2.15)
		center_tint = Color(0.36, 0.003, 0.008, 0.98)
		edge_tint = Color(0.52, 0.008, 0.014, 0.32)
	var diameter := clampf(
		randf_range(diameter_range.x, diameter_range.y) * resolved_intensity,
		diameter_range.x,
		diameter_range.y
	)
	return place_splat(
		surface["position"],
		surface["normal"],
		Vector2.ONE * diameter,
		0.0,
		center_tint,
		edge_tint,
		0.30
	)
```

`place_splat()` 的末尾三个材质参数改成 `center_tint: Color, edge_tint: Color, duration_seconds: float` 并原样传给 `splat.setup()`。圆形命中血迹旋转角固定为 `0.0`；圆对旋转不敏感，不再使用射击方向和 `atan2()`。

- [ ] **步骤 6：让兼容入口也彻底脱离贴图**

`spawn_trail_splat()` 继续生成定向椭圆，但改用程序化中心色/边缘色和 `0.22` 秒扩散；`spawn_death_pool()` 改用直径 `2.00～2.30` 米的程序化圆，仅供兼容调用。两者不得接受 Texture2D 或 roughness 参数。

预热逻辑只需预建 `PREWARM_POOL_SIZE` 个实例，再取一个 splat 调用真实 `setup()`：

```gdscript
	var splat := splats[0] as GroundBloodSplat
	splat.setup(
		context.position_in_view(3.0, Vector2(0.0, -0.3)),
		-context.forward_direction(),
		Vector2.ONE * 1.8,
		0.0,
		Color(0.42, 0.005, 0.01, 0.96),
		Color(0.58, 0.012, 0.018, 0.26),
		0.30
	)
	_prewarmed_splats.append(splat)
```

不再遍历贴图或按贴图触发多次 shader 编译。同步把 `finish_prewarm()` 改为对每个预热实例调用 `finish_render_warmup()`，确保隐藏的实例同时 `set_process(false)`，然后清空 `_prewarmed_splats`。

- [ ] **步骤 7：运行地面血迹专项验证**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_procedural_blood_fx.gd
```

预期：编辑器导入无 scene/script parse error；专项验证中“无贴图”和“扩散后保持可见”通过，但 BloodImpact 和 GameplayArena 接线断言仍可能因任务 3 未完成而失败。

- [ ] **步骤 8：建立地面血迹实现 checkpoint**

```bash
git add scripts/fx/ground_blood_splat.gd \
  scenes/fx/GroundBloodSplat.tscn \
  scripts/fx/ground_blood_manager.gd
git commit -m "feat(fx): render procedural expanding ground blood"
```

---

### 任务 3：把命中接线改为脚底单圆，并精简为空中 3D 血滴

**文件：**
- 修改：`scripts/gameplay/gameplay_arena.gd:1020-1045`
- 修改：`scripts/fx/blood_impact.gd:4-94`
- 修改：`scenes/fx/BloodImpact.tscn:1-40`

**接口：**
- 消费：`GroundBloodManager.queue_hit_splat(world_position: Vector3, intensity: float = 1.0, killed: bool = false)`。
- 保留：`GroundBloodManager.spawn_blood_impact(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> BloodImpact`。
- 保留：`BloodImpact.setup(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> void`、`set_pooled()`、`is_active()`、`deactivate()` 和预热方法。
- 删除内部依赖：`BloodImpact.splat: Sprite3D`、`splat_start_scale`、`$Splat` 节点。

- [ ] **步骤 1：让 GameplayArena 分离身体命中点和脚底血迹点**

在 `_on_sim_hit_event()` 开头明确构造两个位置：

```gdscript
	var planar: Vector2 = event["position"]
	var hit_position := Vector3(planar.x, float(event["height"]), planar.y)
	var foot_position := Vector3(planar.x, 0.0, planar.y)
```

`hit_position` 继续用于近景僵尸受击反应、3D 血滴和伤害数字；持久地面血迹只使用 `foot_position`：

```gdscript
	manager.spawn_blood_impact(hit_position, direction, 1.0)
	manager.queue_hit_splat(foot_position, 1.0, bool(event["killed"]))
```

删除：

```gdscript
	if bool(event["killed"]):
		manager.queue_death_pool(Vector3(planar.x, 0.0, planar.y), 1.25)
```

保持击杀 hit-stop、伤害数字和 manager 缺失时的 `_spawn_blood_impact()` fallback 不变。

- [ ] **步骤 2：删除 BloodImpact 的贴图飞溅状态**

把 `blood_impact.gd` 收敛为只管理 `GPUParticles3D`：

```gdscript
@onready var droplets: GPUParticles3D = $Droplets

var remaining := 0.0
var pooled := false

func setup(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> void:
	_ensure_nodes()
	visible = true
	if is_inside_tree():
		global_position = hit_position
	else:
		position = hit_position
	var spray_direction := shot_direction.normalized()
	if spray_direction.length_squared() <= 0.000001:
		spray_direction = Vector3.FORWARD
	if is_inside_tree():
		var up_direction := Vector3.UP
		if absf(spray_direction.dot(up_direction)) > 0.98:
			up_direction = Vector3.RIGHT
		look_at(global_position + spray_direction, up_direction)
	droplets.amount_ratio = 1.0
	remaining = maxf(lifetime, 0.05)
	if is_inside_tree():
		droplets.restart()
		droplets.emitting = true
	set_process(true)
```

`_process(delta)` 只倒计时并在结束时复用现有 pooled/free 分支；删除 Sprite 缩放、随机旋转和 alpha 淡出。`_ensure_nodes()` 只补取 `Droplets`。

- [ ] **步骤 3：把 BloodImpact 场景改为 9 个小型血滴**

删除 `Texture2D` ext_resource、`Splat` Sprite3D 节点和对应 load step。保留现有红色 StandardMaterial3D 与 GPUParticles3D，并使用以下数值：

```text
[sub_resource type="SphereMesh" id="SphereMesh_droplet"]
material = SubResource("StandardMaterial3D_droplet")
radius = 0.026
height = 0.058

[sub_resource type="ParticleProcessMaterial" id="ParticleProcessMaterial_blood"]
direction = Vector3(0, 0.12, -1)
spread = 32.0
initial_velocity_min = 2.0
initial_velocity_max = 4.2
gravity = Vector3(0, -7.5, 0)
damping_min = 0.8
damping_max = 1.8
scale_min = 0.65
scale_max = 1.25
color = Color(0.5, 0.008, 0.012, 0.96)

[node name="Droplets" type="GPUParticles3D" parent="."]
emitting = false
amount = 9
lifetime = 0.45
one_shot = true
explosiveness = 1.0
randomness = 0.35
```

保持 `visibility_aabb`、`process_material` 和 `draw_pass_1` 绑定。

- [ ] **步骤 4：运行专项与既有稳定性验证**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_procedural_blood_fx.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_combat_frame_stability.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_blood_request_budget.gd
```

预期：三项均 PASS。`validate_combat_frame_stability` 继续证明 BloodImpact 池节点数量不增长；`validate_blood_request_budget` 使用每目标一个请求的新峰值模型；专项验证证明两个命中只排两个脚底血迹请求。

- [ ] **步骤 5：建立命中接线 checkpoint**

```bash
git add scripts/gameplay/gameplay_arena.gd \
  scripts/fx/blood_impact.gd \
  scenes/fx/BloodImpact.tscn
git commit -m "feat(fx): center hit blood at zombie feet"
```

---

### 任务 4：文档、完整验证、人工验收与最终 squash

**文件：**
- 修改：`README.md:47`
- 复核：本计划涉及的全部代码、场景和验证文件

**接口：**
- 不新增运行时接口。
- 验收最终组合：身体命中点只产生 3D 血滴；脚底中心只产生一个程序化圆形血迹；击杀通过同一请求变大变深；血迹扩散完成后永久保留。

- [ ] **步骤 1：更新 README 的血液表现说明**

把旧句：

```text
Every successful hit also spawns a short Kenney CC0 blood splat plus directional Godot droplets. Persistent ground blood is projected only onto the arena ground and reuses its oldest splat after 192 instances.
```

改为：

```text
Every successful hit emits a small directional burst of 3D blood droplets and grows a texture-free radial blood pool from the zombie's feet. Ground pools use a shared procedural shader, remain for the current scene, project only onto blood-surface geometry, and reuse the oldest pooled instance at the configured cap.
```

- [ ] **步骤 2：运行最终自动验证矩阵**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_procedural_blood_fx.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_combat_frame_stability.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_blood_request_budget.gd
```

预期：headless editor 退出码 `0`，三项验证均打印 `PASS`。若出现项目已有且与本计划无关的失败，记录完整命令和错误文本，不修改无关系统来换取通过。

- [ ] **步骤 3：执行源码级无贴图扫描**

```bash
rg -n -S "kenney_splat|splat_texture|Sprite3D" \
  scripts/fx/ground_blood_splat.gd \
  scenes/fx/GroundBloodSplat.tscn \
  scripts/fx/blood_impact.gd \
  scenes/fx/BloodImpact.tscn
```

预期：无输出。再确认 manager 运行时没有贴图常量：

```bash
rg -n -S "HIT_TEXTURES|TRAIL_TEXTURES|Texture2D" scripts/fx/ground_blood_manager.gd
```

预期：无输出。

- [ ] **步骤 4：人工游戏内验收普通命中**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

按以下固定步骤验收：

1. 进入默认 Demo，选择单发或低射速武器，朝一只站在平坦地面的僵尸身体射击一次。
2. 确认身体命中位置只喷出约 9 个小型 3D 血滴，不再出现面向相机的红色飞溅贴图。
3. 确认僵尸脚下为圆心出现一片明显大于角色脚掌范围的红色圆形血迹；命中身体上半部时，地面圆心仍在脚下，而不是在命中高度或朝射击方向偏移。
4. 确认血迹在约 `0.30` 秒内由中心快速向外扩展；中心深红且不透明度更高，外侧约最后 `45%` 半径逐渐淡到完全透明，没有方形 Quad 边缘。
5. 停止射击至少 10 秒，确认血迹保持完整，不自动淡出。

- [ ] **步骤 5：人工游戏内验收击杀、密集射击和重开**

1. 击杀一只僵尸，确认只出现一片较普通命中略大、略深的圆形血迹，没有第二张死亡贴图或双层突兀轮廓。
2. 对同一位置连续射击，确认空间合并只让已有血迹略微变大、变深，不会反复缩回中心闪烁。
3. 使用高射速武器对尸群射击，确认地面血迹不会造成明显首次命中卡顿；BloodImpact 节点总数保持池上限，不持续增长。
4. 按项目重开操作重载当前场景，确认上一局所有持久血迹被统一清空。
5. 若渐变、尺寸或扩散速度不符合观感，只允许在以下小范围调参后重复本步骤：普通直径仍限制在 `1.60～1.90`、击杀直径仍限制在 `1.90～2.15`、扩散时长保持 `0.30` 秒；可调整 center/edge tint 和 shader 的 `outer_fade` 起点，但不得恢复贴图。

- [ ] **步骤 6：复核 diff 并排除无关工作区改动**

```bash
git diff --check
git status --short
git diff -- README.md \
  scripts/fx/ground_blood_splat.gd \
  scenes/fx/GroundBloodSplat.tscn \
  scripts/fx/ground_blood_manager.gd \
  scripts/gameplay/gameplay_arena.gd \
  scripts/fx/blood_impact.gd \
  scenes/fx/BloodImpact.tscn \
  tools/validation/validate_procedural_blood_fx.gd \
  tools/validation/validate_combat_frame_stability.gd \
  tools/validation/validate_blood_request_budget.gd
```

预期：`git diff --check` 无输出；diff 只包含本计划内容。不得暂存或改写执行前已经存在的 `scripts/menu/map_selection.gd` 与 `tools/validation/validate_enter_game_start.gd*`。

- [ ] **步骤 7：提交文档 checkpoint，并在合并前 squash 本计划提交**

先提交 README：

```bash
git add README.md
git commit -m "docs(fx): describe procedural blood pools"
```

最终评审完成后，对本计划创建的 checkpoint commits 执行交互式 squash；只把以下逻辑提交合并为一个，不包含计划开始前的提交或用户无关改动：

- `test(fx): define procedural blood effect contract`
- `feat(fx): render procedural expanding ground blood`
- `feat(fx): center hit blood at zombie feet`
- `docs(fx): describe procedural blood pools`

最终提交主题固定为：

```text
feat(fx): add procedural expanding ground blood
```

完成后运行：

```bash
git status --short
git log -5 --oneline --decorate
```

预期：本计划在分支历史中表现为一个计划 Commit；用户原有未提交修改仍保持未暂存/未覆盖状态。

## 计划自审结论

- 规格覆盖：任务 2 覆盖无贴图圆形距离场、中心到外缘渐变、0.30 秒扩散和永久保留；任务 3 覆盖脚底中心、一次命中一个请求、击杀同片强化与 9 个 3D 血滴；任务 4 覆盖重开清空、池化性能、文档和人工视觉验收。
- 风险边界：改动只在表现层 FX 和接线层，不触碰模拟、伤害、联机协议或导航；自动测试投入集中在稳定接口和性能边界，渐变观感由人工验收承担。
- 类型一致：计划中 `GroundBloodSplat.setup(...)`、`GroundBloodManager.queue_hit_splat(...)`、request 字段 `position/intensity/killed` 在验证、manager 与 arena 三处保持同名同类型。
- 占位符检查：计划不含待定实现、模糊测试步骤或未定义接口。
