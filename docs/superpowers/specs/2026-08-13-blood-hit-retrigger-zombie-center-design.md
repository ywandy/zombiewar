# 血迹重复命中扩散与僵尸中心定位设计

## 目标

修复地面血迹“有时有、有时没有”的观感：每次有效命中都必须产生清晰的中心向外扩散反馈；地面血迹中心必须来自模拟层中的僵尸实体中心，而不是子弹击中身体表面的坐标。同时扩大血迹范围，使普通命中与击杀在当前 2.5D 镜头下更明显。

## 现状与原因

`SimWorld.apply_zombie_damage()` 目前只把 `hit_position` 写入 `tick_hit_events`。`GameplayArena` 将该坐标直接作为地面血迹中心，因此命中僵尸身体边缘时，血迹圆心也偏到身体边缘。

`GroundBloodManager` 按 `0.7` 米空间格管理血迹，每格最多两层。超过层数后，`place_splat()` 只调用 `merge_limited()`：旧血迹略微放大和加深，但不会重置 `reveal_radius` 或重新启动 `_process()`。连续命中同一只僵尸时，玩家因此看不到新的扩散动画，误以为该次命中没有生成血迹。

## 方案

采用“模拟事件同时携带命中点与僵尸中心 + 合并血迹重播扩散”的方案。

- `position` 与 `height` 保持原语义：子弹实际命中位置，用于僵尸受击反应、3D 血滴、伤害数字和曳光。
- 新增 `zombie_position: Vector2`：扣血结算当刻的僵尸实体中心，专供脚下地面血迹定位。
- `GameplayArena` 使用 `zombie_position` 构造 `Vector3(x, 0.0, z)` 并排入 `GroundBloodManager`。
- 新血迹继续执行正常的 0.30 秒中心向外扩散。
- 同格超过层数时，先保留现有的有限尺寸增长和颜色加深，再把扩散进度重置到中心并重新启动 0.30 秒扩散；每次有效命中都能看到反馈。

不采用表现层通过 `ZombieRenderer` 查找节点中心。远处僵尸可能没有近景节点，且表现节点会插值，不能作为所有客户端一致的事件坐标来源。

## 范围与视觉参数

- 普通命中最终直径：`2.40～2.80` 米。
- 击杀命中最终直径：`2.80～3.20` 米。
- 扩散时长保持 `0.30` 秒，使用现有 cubic ease-out。
- 中心色、边缘色和中心到外缘渐变保持现有程序化 shader 配置。
- 空中命中效果仍只保留 9 个 3D 血滴，不恢复贴图。
- 血迹永久保留到场景重开；池上限、队列帧预算和地面射线规则保持不变。

## 数据流

1. 武器射线解析得到子弹命中点和僵尸索引。
2. `apply_zombie_damage()` 在修改僵尸位置之前读取 `zombie_position[index]`，将其以 `zombie_position` 字段写入 `tick_hit_events`。
3. `GameplayArena._on_sim_hit_event()`：
   - 用 `position + height` 播放身体命中反馈；
   - 用 `zombie_position` 排地面血迹请求。
4. `GroundBloodManager` 投影到 `blood_surface`：
   - 未超过格子层数时取得池实例并播放首次扩散；
   - 已超过层数时合并到尺寸最接近的一层，并重新播放扩散。

新增字段只进入表现事件，不进入帧协议或 frame hash，也不改变模拟结果。所有客户端从各自确定性模拟的同一 tick 读取相同僵尸中心。

## 接口调整

### `SimWorld.apply_zombie_damage()`

保持函数参数不变。事件字典新增：

```gdscript
"zombie_position": zombie_position[index]
```

### `GroundBloodSplat`

新增：

```gdscript
func retrigger_expansion(duration_seconds: float = 0.30) -> void
```

该方法将 `expansion_duration` 更新为合法正值，将 `expansion_elapsed` 和 `expansion_progress` 重置为 `0.0`，把 instance uniform `reveal_radius` 设回 `MIN_REVEAL_RADIUS`，保证节点可见并重新启用 `_process()`。它不得重置尺寸、位置、表面法线或颜色。

`setup()` 复用该方法启动首次扩散，避免维护两套重置逻辑。

### `GroundBloodSplat.merge_limited()`

保持尺寸和颜色合并职责，不在内部隐式重播。`GroundBloodManager.place_splat()` 在命中合并分支显式执行：

```gdscript
merged.merge_limited(1.15, 0.015)
merged.retrigger_expansion(duration_seconds)
```

这样调用点明确控制重播时长，兼容命中、拖痕和死亡血池入口。

## 边界情况

- 连续射击发生在上一轮扩散尚未结束时：新命中从中心重新开始一次完整扩散，优先保证“每发有反馈”。
- 击杀请求合并到普通血迹时：沿用现有尺寸匹配与有限增长规则，不允许无限扩大；该次仍重新扩散。
- 僵尸死亡：事件在状态改为 `STATE_DEAD` 前记录实体中心，因此坐标准确有效。
- 远处僵尸没有表现节点：仍由模拟事件提供中心，不依赖场景节点。
- 一发穿透命中多只僵尸：每个命中事件分别携带对应实体中心，各自在自己的空间格产生或重播血迹。
- 找不到 `blood_surface`：仍跳过持久血迹。本轮只修复定位和合并反馈，不扩大地面投影规则。

## 验证

扩展 `validate_procedural_blood_fx.gd`：

- 模拟命中事件必须包含 `zombie_position`，且 `GameplayArena` 排队的位置来自该字段，而不是 `position`。
- 同一格达到层数上限后再次 `place_splat()`，返回同一实例；该实例的 `expansion_progress` 重置为 `0.0`，尺寸不缩小，随后推进 0.30 秒可再次到达 `1.0`。
- 普通命中尺寸范围为 `2.40～2.80` 米，击杀范围为 `2.80～3.20` 米。
- 原有无贴图、9 个血滴、永久可见和共享材质契约继续通过。

运行 headless editor import、`validate_procedural_blood_fx.gd`、`validate_combat_frame_stability.gd`、`validate_blood_request_budget.gd` 和 `validate_sim_determinism.gd`。虽然事件字段不进入哈希，仍用确定性验证确保未误改模拟推进。

人工验收：用低射速武器连续命中同一只静止僵尸，每一发都应看到从实体脚下中心扩出的圆形反馈；切换高射速武器后反馈可以连续重启，但不得出现贴图、方形边缘或血迹无限增大。击杀血迹应明显大于普通命中。

## 不在本轮范围

- 修改 `blood_surface` 查询的碰撞层、射线次数或障碍排除规则。
- 恢复命中贴图、增加额外粒子或修改 3D 血滴数量。
- 改动伤害、击退、死亡、导航、联机协议或 frame hash。
- 自动清理、按波次清理或改变血迹永久保留规则。
