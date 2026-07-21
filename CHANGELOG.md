# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，并使用语义化版本号。

## [Unreleased]

### Planned

- 可校准的六自由度船舶动力学接口。
- 更大规模的确定性 benchmark 配置与报告工具。
- 更多经过许可审计的公开港口数据示例。

## [0.1.0] - 2026-07-21

### Added

- Godot 4.7 程序化无人船场景、双语遥测 HUD、航线、天气、风险、AIS 与复盘面板。
- PPO、SAC、TD3、DQN 与 LOS-PID 五种共享数据契约的基线。
- 训练/验证/测试 split 隔离、实验指纹、checkpoint 与确定性测试轨迹。
- AccessAIS、GeoJSON 和 Open-Meteo 数据适配器。
- 中英双语 README、真实运行截图、架构图、复现说明与社区模板。

### Security

- 公开版移除与航行无关及来源不明的历史资产、工作材料、缓存与训练产物。
- 仓库界面只显示安全的 `res://`、`user://` 或外部配置文件名，不显示开发者绝对路径。

[Unreleased]: https://github.com/wenjiayi123/sailing-simulator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wenjiayi123/sailing-simulator/releases/tag/v0.1.0
