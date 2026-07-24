# 航行模拟器项目结构

当前结构服务无人船航行、港口场景、遥测、训练评估和测试回放。早期村落、建筑、NPC、对话和采集模块已经从项目移除；仍保留的旧单词只存在于主场景实际依赖的水域、悬岩、纹理和着色器兼容路径中。

## 当前运行目录

- `main.tscn`：航行模拟器主场景。
- `player.gd`：船舶操控和船舶视觉入口。
- `scenes/worlds/`：当前航行水域场景。
- `scenes/objects/terrain/`：悬岩、岸线和地形障碍组件。
- `scripts/world/`：航线、障碍、场景、海况与水流控制。
- `scripts/ui/`：遥测、RL、风险、规划、海况、AIS 和教员面板。
- `scripts/rl/`：船队状态与测试策略回放。
- `tools/ship_rl/`：数值环境、五种基线和训练/测试实现。
- `data/ports/`、`data/rl/`：港口场景配置和训练数据集。

## 保留的兼容路径

- `scenes/worlds/taoyuan_valley_terrain_skeleton.tscn`：当前主场景使用的航行水域和悬岩环境。
- `shaders/taoyuan_lake_floor.gdshader`：当前水面材质依赖。
- `shaders/taoyuan_cliff_water_flow.gdshader`：当前悬岩水流依赖。
- `shaders/taoyuan_premium_waterfall_ribbon.gdshader`：当前瀑布带材质依赖。
- `assets/textures/backgrounds/` 下两张旧命名纹理：当前远景和水底材质依赖。

这些路径暂不重命名，以免破坏 Godot UID 和资源引用；它们的节点名和材质显示名已经改为航行模拟器语义。详见 `docs/LEGACY_ASSET_COMPATIBILITY.md`。

## 开发规则

1. 先维护 `main.tscn` 的船舶、航行水域、障碍、遥测和测试回放闭环。
2. 新场景优先使用港口、航道、岸线、码头和航标语义命名。
3. 不再向仓库加入村落、客栈、学堂、NPC、战斗、采集或生活冒险模块。
4. 修改兼容路径前必须执行全仓引用检查、Godot 加载检查和短时运行验证。

## 命名规则

- 场景文件用小写英文和下划线，例如 `harbor_channel_01.tscn`。
- 脚本文件用小写英文和下划线，例如 `navigation_obstacle.gd`。
- 资源可以使用中文名，但关键资源应描述航行用途，例如 `港池水面_01.png`、`航道障碍_01.tscn`。
