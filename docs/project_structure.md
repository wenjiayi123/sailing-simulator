# 航行模拟器项目结构

公开版只包含无人船航行、港区场景、遥测、训练评估和测试回放所需内容。

## 运行入口

- `main.tscn`：程序化海面、无人船和航行系统主场景。
- `player.gd`：船舶动力、舵角、碰撞、相机和舰队接口。
- `scripts/world/`：航线、障碍、港区场景和海况控制。
- `scripts/ui/`：遥测、RL、风险、规划、海况、AIS 和教员面板。
- `scripts/rl/`：舰队配置与独立测试策略回放。
- `scripts/audio/`：运行时程序化合成的风、水、发动机和舵机声。
- `scripts/visual/`：由着色器和基础网格生成的船尾流。

## 训练与数据

- `tools/ship_rl/`：21 维环境、四种 RL 基线与 LOS-PID。
- `tools/rl_train_baselines.py`：训练、评估和轨迹导出命令行入口。
- `tools/public_data_pipeline.py`：公开 AIS、GeoJSON 和天气数据适配器。
- `data/rl/`：项目原生可复现基准。
- `data/ports/`：可替换的港区场景配置。
- `tests/`：数据切分、环境、控制器与适配器测试。

## 发布边界

仓库不包含与航行无关的游戏系统，也不包含来源不明的纹理、照片、录音、缓存、申请材料或训练产物。新增二进制资产前必须更新 `ASSET_LICENSE_AUDIT.md` 和 `THIRD_PARTY_ASSETS.md`。
