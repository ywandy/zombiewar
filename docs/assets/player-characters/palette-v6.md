# 玩家角色配色识别体系 v6

取代 v5 的「全员 purple-black + red accents」。源数据是 [`palette-v6.json`](palette-v6.json)，
提示词由 `tools/assets/gen_character_prompts_v6.py` 从该 JSON 展开，**改配色只改 JSON，不手改提示词**。

## 为什么要重做

v5 的 10 套 kit 提示词逐字都写着 `purple-black, dirty off-white and red accents`，两套基体也是紫黑
连体服。结果是 10 个角色 = 同 2 张脸 + 同 1 套配色，只有装备件形状不同，缩略图和俯视视角下认不出人。

v6 改三件事：

1. **主色按角色变**，占 kit 面积 40–50%，不再是全员紫黑；
2. **10 张不同的脸**（肤色 / 发色 / 发型 / 年龄 / 面部特征各不相同），头脸本来就是 kit 的一个分件，
   所以不额外增加建模成本；
3. **基体从 2 套增加到 4 套**（加 `male_heavy` 和 `female_slim`），轮廓差异不只靠装备。

统一项不变，风格才不会散：粗黑不均匀墨线、平涂两阶 cel shading、手绘磨损、米白皮件、深棕皮带。

## 配色矩阵

| 角色 | 基体 | 主色 40–50% | 次色 | 强调色 | 底衣 | 兵种标记 |
| --- | --- | --- | --- | --- | --- | --- |
| male_gunner | male_standard | 深橄榄绿军装 `#4F5B32` | 芥末黄弹链 `#C9A227` | 焦橙胶带 `#B5551F` | `#2F3620` | 弹链/齿轮喷印 |
| female_gunner | female_slim | 浅鼠尾草橄榄 `#6E7A43` | 亮芥末黄 `#D9B94A` | 焦橙胶带 `#B5551F` | `#3A4227` | 弹链/齿轮喷印 |
| male_assault | male_standard | 深砖红夹克 `#8E3B2E` | 米白护具 `#E8DFC8` | 暗红识别带 `#B3231E` | `#3A211C` | 小骷髅 |
| female_assault | female_standard | 亮陶土红夹克 `#B24A38` | 米白护具 `#E8DFC8` | 暗红识别带 `#B3231E` | `#46261F` | 小骷髅 |
| male_medic | male_standard | 灰白医疗外套 `#D6D3C4` | 深青绿滚边 `#2E7D6B` | 血红十字 `#B3231E` | `#2B3038` | 几何十字 |
| female_medic | female_slim | 亮米白医疗外套 `#E4E2D6` | 浅青绿滚边 `#3D9B85` | 血红十字 `#B3231E` | `#333842` | 几何十字 |
| male_demolition | male_heavy | 焦橙工装 `#B45A18` | 深棕皮革 `#4A3728` | 警示黄条 `#D9A521` | `#3A2415` | 危险条纹 + 三角爆炸标 |
| female_demolition | female_standard | 亮橙工装 `#D4762A` | 深棕皮革 `#4A3728` | 警示黄条 `#D9A521` | `#452B19` | 危险条纹 + 三角爆炸标 |
| male_riot | male_heavy | 钴蓝重甲 `#2B4C7E` | 银灰金属 `#A8ADB4` | 冰蓝标记 `#8FB6DC` | `#1E2A3D` | 盾形徽记 |
| female_riot | female_standard | 亮钴蓝重甲 `#3A639E` | 银灰金属 `#A8ADB4` | 冰蓝标记 `#8FB6DC` | `#26344A` | 盾形徽记 |

同兵种男女共享色相，用**明度**（女性更亮一档）和**裁片**区分，不靠换色相区分，
否则兵种识别会被破坏。

全员共通中性色：米白 `#E8DFC8` 皮件织带、深棕 `#4A3728` 皮带、灰 `#8C9096` 金属件、近黑 `#141216` 墨线。

**硬性禁止**：紫、violet、magenta、lavender 出现在任何服装、护甲、织带和配件上。

## 十张不同的脸

头脸是 kit 的分件，配色和身份写在同一条提示词里，一次出图解决。

| 角色 | 身份 |
| --- | --- |
| male_gunner | 四十多岁，风吹日晒的小麦肤 `#C89A6B`，铁灰色寸头，断过的鼻梁，方下巴，深眼角纹，浓胡茬 |
| female_gunner | 三十多岁，小麦肤 `#CB9A6E`，深棕高马尾配剃鬓，高颧骨，眉骨一道小疤 |
| male_assault | 三十多岁，奶白肤 `#E0BB93`，红头带下的黑色刺猬头，颊上刀疤，浅胡茬（沿用已过门槛的样板脸） |
| female_assault | 二十多岁，浅肤 `#EBC49A`，凌乱赭红短波波头，鼻梁雀斑，颈间暗红头巾 |
| male_medic | 二十多岁，深棕肤 `#7A4B2A`，紧卷黑短发，无胡须，脸型更圆更柔，布带小头灯 |
| female_medic | 三十多岁，浅橄榄肤 `#E3C09A`，黑色低发髻带碎发，细长平静的眼睛，小圆脸，口罩拉到下巴 |
| male_demolition | 五十多岁，晒红肤 `#D08A62`，顶秃 + 灰色浓鬓角，灰色海象胡，额头上推的焊接护目镜 |
| female_demolition | 四十多岁，深棕肤 `#6E4326`，粗玉米辫束在脑后，方下颌，额头上推的焊接护目镜 |
| male_riot | 三十多岁，橄榄肤 `#B5804F`，光头，浓密黑络腮胡，重眉骨，掀起面罩的头盔下可见 |
| female_riot | 三十多岁，白皙肤 `#F0D2B0`，灰金色底剃编发，脸型硬朗，鼻梁一道细疤，掀起面罩的头盔下可见 |

## 基体分配

| 基体 | 来源 | 归属角色 |
| --- | --- | --- |
| male_standard | **复用现有网格**，不重出 | male_gunner / male_assault / male_medic |
| male_heavy | 新出 4 视图 | male_demolition / male_riot |
| female_standard | **复用现有网格**，不重出 | female_assault / female_demolition / female_riot |
| female_slim | 新出 4 视图 | female_gunner / female_medic |

新基体的硬约束：**只改躯干和四肢围度**。总身高、头身比、肩关节高度、肘/腕/髋/膝/踝位置必须与
参考基体一致，否则 43 骨骼的权重转移和 20 个动画会破。这条已写进 `male_heavy` / `female_slim`
的提示词。

## 底衣不用重出图

`tools/assets/tint_base_albedo.py` 按色相选区把底衣改成角色色，皮肤、头发、手套、靴子色相不同，
不受影响，手绘磨损和明暗全部保留。已在现有 `male_base/front_final.png` 上验证：选区覆盖 13.2%
画布像素，只落在连体服上。

```bash
# 先看选区（白 = 会被改色），确认没吃到皮肤和靴子
python3 tools/assets/tint_base_albedo.py <base_view>.png --target '#2F3620' --mask-out mask.png

# 按 palette-v6.json 一次导出该基体下所有角色的底衣
python3 tools/assets/tint_base_albedo.py --from-palette \
    --base-image assets/source_art/player_characters/bases/male_base/front_final.png \
    --base-id male_standard -o out/
```

两套现有基体是紫黑的，走默认色相窗口 250–330。两套新基体按提示词出中性深炭灰 `#33323A`，
处理时加 `--gray-source` 改走亮度选区。

同一套做法也适用于 Blender 里已烘焙的 albedo 贴图：改贴图，不改网格、不改权重、不改动画。

## 出图批次

共 48 张，顺序有依赖，不能全部并发：

1. **门槛（先做，通过再往下）**：`male_gunner` kit 正视图。这是第一个非紫非红的角色，
   用它确认新配色在既有画风下站得住。不通过就调 JSON 里的色值重出，不要往下铺。
2. **10 张 kit 正视图**：门槛通过后并发，`prompts-v6/kits/*_front.txt`。
   逐张确认无紫色、主色面积够、脸是设计的那个人。
3. **30 张 kit 侧背视图**：每个角色的正视图通过后，用它作 Image 1 派生 left / back / right。
   同一角色的三张要一起看，分件数量、扣具数量、磨损位置必须和正视图一致。
4. **8 张新基体视图**：`prompts-v6/bases/*.txt`，与第 2、3 步并行，互不依赖。

Tripo3D 同时运行任务仍然控制在 2–3 个，`multiview_to_model` 输入顺序仍是**前、左、后、右**。

## 验收增补

在现有验收项之外，v6 加三条：

- **无紫**：每张成品图采样服装区域，色相不落在 250–330 且饱和度 > 0.15 的紫色区间；
- **缩略图可辨**：10 个角色缩到 96×96 并排，能靠颜色区分出 5 个兵种；
- **同兵种男女可辨**：不能只靠明度差，裁片或发型必须有肉眼可见差异。

## 需要同步改的地方

- `manifest.json` 的 `characters[]` 补 `base` 和配色字段，`accent` 现有值与 v6 不一致，以
  `palette-v6.json` 为准；
- `prompt-style.md` 里 `purple-black tactical clothing with restrained red identifiers` 这句必须删掉，
  它是 v5 全员同色的根因；
- `bases[]` 从 2 项扩到 4 项。
