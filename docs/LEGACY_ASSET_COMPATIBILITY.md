# 航行模拟器遗留资产兼容说明

本项目的当前产品身份是“航行模拟器”。早期“桃源山海”原型中的村落、建筑、NPC、对话、采集和生活冒险工具已于 2026-07-21 移出项目。当前只保留主场景实际依赖的水域、悬岩、远景纹理和水流着色器兼容路径。

## 为什么暂时保留旧路径

Godot 场景会按 `res://` 路径和 UID 关联资源。直接重命名仍在运行链路中的 `taoyuan_*` 文件，可能让场景失去材质、脚本或子场景。因此剩余兼容资源遵循以下规则：

- 当前主场景依赖的水域、悬岩、远景、水流和桥体资源继续保留，并把运行时节点、材质显示名改为航行模拟器语义。
- 未挂入 `main.tscn` 的村落、客栈、学堂、NPC、建筑生成器和对应测试工具已经移除。
- 旧文件名只作为资源路径兼容标识；新增节点、界面文案、输出文件和代码注释不得继续使用旧项目品牌。
- 删除必须同时满足：不在主场景依赖链中、全仓无有效引用、不是港区环境/障碍/水体的可复用资产，并通过 Godot 加载检查。

## 当前运行链路

```text
project.godot
└─ main.tscn
   └─ NavigationEnvironment
      └─ res://scenes/worlds/taoyuan_valley_terrain_skeleton.tscn
         ├─ 航行水面与远景
         ├─ 悬岩和水流效果
         └─ EmergencyAccessBridge
```

这里最后一个场景路径仍保留旧单词，是兼容性决定，不代表产品仍叫旧名称。场景根节点、主场景实例名和材质显示名已经使用航行模拟器语义。

## 已完成的清理

- 从 `main.tscn` 移除了未连接航行业务的交互探测器和采集背包节点。
- 移除了旧 BuildingKit、村落地图、客栈/学堂/NPC、对话采集数据、旧玩法脚本及对应生成/测试工具。
- 移除了旧交互调试插件和 `interact` 输入映射；船舶运动仍使用的 `PlayerActionLock` 保留。
- 共移出 1,385 个文件，约 19 MB；恢复位置记录在 `docs/CLEANUP_2026-07-21.md`。

## 后续新增内容的命名

- 航行环境：`navigation_environment`、`harbor_environment`、`waterway`。
- 障碍与岸线：`navigation_obstacle`、`cliff`、`breakwater`、`shoreline`。
- 港区设施：`port_facility`、`service_dock`、`operations_center`。
- 历史路径需要继续引用时，在代码旁写明“兼容路径保留”，不要复制旧品牌到新节点名或界面文案。
