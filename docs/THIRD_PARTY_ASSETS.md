# 第三方软件与数据

公开仓库不包含第三方图片、人物素材、3D 模型、字体或录音文件。

## 运行与训练依赖

| 名称 | 用途 | 许可证 | 项目是否打包其源码/二进制 |
|---|---|---|---|
| Godot Engine 4.7 | 3D 模拟器运行时 | MIT | 否 |
| Python | 训练与数据处理运行时 | PSF License | 否 |
| NumPy 1.26.4 | 数值计算 | BSD-3-Clause | 否 |
| Gymnasium 1.0.0 | 强化学习环境接口 | MIT | 否 |
| Stable-Baselines3 2.4.1 | PPO、SAC、TD3、DQN | MIT | 否 |

具体安装版本由 `requirements-rl.txt` 锁定，依赖由用户的 Python 包管理器下载。

## Open-Meteo 海况缓存

- 文件：`data/public_cache/marine_weather_singapore.json`
- 来源：Open-Meteo Marine Weather API
- 许可证：CC BY 4.0
- 署名：Weather data by Open-Meteo.com；波浪产品包含 DWD 模型数据时保留 DWD 说明。
- 边界：缓存是带时间戳的公开模型结果，不是实时传感器观测，也不是港口生产数据。

## 用户自行接入的数据

NOAA/BOEM/USCG AccessAIS、用户提供的 GeoJSON 和电子海图不随仓库分发。使用者必须自行核对具体下载文件的许可、隐私、精度和再分发条件。
