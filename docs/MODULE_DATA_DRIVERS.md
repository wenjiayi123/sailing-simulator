# 模块数据驱动边界

本文档区分“观测数据”、“数值模型计算”与“人工场景注入”。界面不应把预设值或估算值标成实时观测。

| 模块 | 驱动源 | 真实性边界 | 替换入口 |
|---|---|---|---|
| RL 训练 | Gymnasium 数值环境 + `train` split + Godot 地形快照 | 圆/矩形/多边形障碍、悬岩额外净距、动态交通、域随机化、真实 timestep/reward/checkpoint；不启动 Godot 渲染 | `SHIP_RL_DATASET`，可配 `--environment-geojson` 生成 |
| RL 测试与回放 | `test` split + 训练 checkpoint + 实验配置指纹 | 测试完成后才生成轨迹；动态障碍随记录移动；碰撞、地形碰撞、近失和超时不被改写 | 同一数据集的 `test` split |
| AIS 态势 | NOAA/BOEM AccessAIS 导出的历史 AIS | 只读历史目标，不声称是当前船舶监控 | `SHIP_AIS_TARGETS` |
| 气象与海况 | Open-Meteo 实时接口或带时间戳缓存 | 界面显示 `live`/`cache_fallback`/`manual_override`/`scenario_override` | 缓存 JSON 或网络接口 |
| 港口场景 | `ship_port_profile_v1` | 默认是项目原生几何，`observed_port_data=false`，不冒充电子海图 | `SHIP_PORT_PROFILE` 或 `user://port_profile.json` |
| 航行任务 | port profile 中的 `navigation_missions` | 航线、出生点、到达半径和计划航速都从配置读取 | 同上 |
| 风险决策 | 船舶实时遥测 + 航线 + 障碍物 | CPA/TCPA、横向偏差和距离由本地确定性公式计算；阈值预设是配置，不是传感器数据 | 面板阈值或代码配置 |
| 教员控制台 | 用户明确触发 | 天气、事故和临时障碍都标记为“教员场景注入”，不冒充外部告警 | 教员控制台 |
| 复盘 | 运行时遥测累计 | 航程、时间和事件为运行记录；油耗/碳排如无流量计输入，只能标为模型估算 | 遥测接口或外部传感器适配器 |

## 不可混用的两类数据

- `data/rl/*.json` 是算法实验任务，必须有固定的 train/validation/test 切分。
- `data/ports/*.json` 是 Godot 可视化场景和人工航行任务配置。

两者可以由同一个港口数据管道生成，但不应在运行时用可视化预设覆盖独立测试任务。
