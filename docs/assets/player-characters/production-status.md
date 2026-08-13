# 玩家角色与武器批量生产状态

更新时间：2026-08-13

## 已完成

- 使用 `gpt-image-2` 并发生成并校验 76 张最终四视图（全部 2048×2048 PNG）。
- 两个共享基体：`male_base`、`female_base`。
- 十套独立兵种分件：男女各含机枪手、突击手、医疗兵、爆破兵、防爆兵。
- 七件独立武器：RPG、AK-47、M4A1 卡宾枪、战术匕首、HK-45C、地雷、MP-5。
- 固定 Tripo 输入顺序：`front`、`left`、`back`、`right`。
- 最终图片统一使用上述四个稳定文件名。旧的 `*_vN.png` 与 `*_final.png` 是生成溯源，不是 Tripo 输入。
- 角色基体保持约 3.2–3.5 头身的紧凑卡通比例，没有单独放大头、手或靴子。
- QA 总览：
  - `qa/bases-four-view-v5.jpg`
  - `qa/kits-four-view-v5.jpg`
  - `qa/weapons-four-view-v5.jpg`

## Tripo3D 实测

- 当前网关确实支持 `multiview_to_model`。
- 成功任务：`de851dff-07ec-4a19-9135-a89ee3a02e57`。
- 实测顺序：前、左、后、右。
- 实测耗时约 22 秒，消耗 20 credits，并成功产出 GLB。
- 正式生产必须维持最多三个同时运行任务的任务池。

## 正式 Tripo3D 生产

- 使用 `/Users/liangpingbo/Desktop/4399/frontend/43Coding/resources/skills/model3d-gen/SKILL.md` 指定的网关与 `multiview_to_model`。
- 并发上限 3，输入顺序固定为前、左、后、右。
- 19/19 任务成功，0 失败，总消耗 760 credits。
- 角色基体约 18k 三角面，独立套件约 12k，武器约 5k。
- 任务、下载地址与参数记录：`tripo-production.json` 与 `tripo/*.json`。
- GLB 与预览已立即下载到 `assets/generated_models/tripo/`。

## Blender MCP 装配

- 通过标准 Blender MCP 服务连接 Blender 4.4（`127.0.0.1:9876`），所有拼装、蒙皮、挂点、导出与母文件清理均由 MCP 的 `execute_blender_code` 完成。
- 10/10 角色已装配为独立基体网格 + 独立职业套件网格，并继承参考角色的 43 骨骼与 20 套动画。
- 每个角色包含 `WeaponHandSocket`、`WeaponBackSocket`、`MineHipSocket`。
- 7/7 武器已统一尺寸、朝向与原点；枪械/匕首使用主握把原点，地雷使用底面中心原点。
- 最终角色：`assets/characters/generated/*.glb`；母文件：`assets/characters/generated/blend/*.blend`。
- 最终武器：`assets/weapons/generated/*.glb`；母文件：`assets/weapons/generated/blend/*.blend`。
- Blender 批次、面数与清理记录：`blender/character-batch-report.json`、`weapon-batch-report.json`、`blend-cleanup-report.json`。

## Godot 接入与验证

- `character_catalog.tres` 已从 4 个占位角色替换为 10 个新角色，默认角色为 `male_assault`。
- 联机、单人和本地多人现在都显式传递稳定 `character_id`；单人和本地多人复用同一个 3D 角色大厅。
- 单人自动建立 P1；本地多人每个已加入设备可用自己的左右选择键并发切换角色，允许重复选择。
- 大厅预览、角色名称、强调色与实际出生角色统一读取描述符的同一个 `character_id`，未知 ID 会阻止开始而不静默回退。
- 现有玩法武器已接独立表现：`rifle→ak47`、`pistol→hk45c`、`smg→mp5`、`knife→tactical_knife`。
- M4A1、RPG 与地雷按当前范围仅交付规范化模型，不新增未设计完成的玩法 ID。
- `validate_generated_character_models.gd` 已验证 10 个角色与 7 把武器的 Godot 导入、骨骼、动画、挂点、分件与三角面预算。
- 角色目录、角色数值、联机内容路由、武器装配、音效、装备轮换、枪口方向、碰撞与标志武器缩放校验均通过。
- Godot headless editor 导入/解析通过；统一选角、本地输入/断线、地图路由、玩家生成、预览、目录、模型、字体、联机房间与武器装配共 19 项聚焦校验串行通过。

## 仍需视觉复核

- 角色功能、模型结构与动画契约已经通过源码级校验，但最终 bind pose 总览仍可见部分 Tripo 套件分件悬浮。
- `male_assault` 的最近表面吸附样板仍有护臂与头饰位置错误，未批量覆盖最终 GLB；因此不可将模型美术标记为最终验收完成。

## R2 归档

- 76 张标准化最终四视图已上传到 `zombiewar/player-character-production/2026-08-13/`。
- 76/76 对象通过匿名 range GET 验证。
- 对象键与校验记录：`r2-upload-manifest.json`。

## 已解决的原环境阻塞

1. COS 上传缺失改为使用用户指定的 lumen 项目 R2 对象存储，正式输入 URL 已可用。
2. 当前会话通过 Blender MCP 的标准 stdio 客户端连接既有 MCP 服务，未使用 Blender CLI/后台 Python 冒充 MCP。
