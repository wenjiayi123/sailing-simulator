# 港口训练数据与环境交互契约

## `ship_port_dataset_v2`

顶层必须包含互不混用的 `train`、`validation`、`test` 三个非空 split：

```json
{
  "schema_version": "ship_port_dataset_v2",
  "coordinate_system": {
    "type": "local_cartesian_meters",
    "axes": "x_east_z_north",
    "origin_wgs84": {"latitude": 0.0, "longitude": 0.0}
  },
  "source": {},
  "splits": {"train": [], "validation": [], "test": []}
}
```

同一 AIS 船舶或航次不得跨 split。公开 AIS 适配器按 MMSI 的 SHA-256 稳定分组，小数据下载也只会移动完整任务，不会复制观测到多个 split。

## 任务结构

```json
{
  "id": "unique_task_id",
  "start": {"x": 0.0, "z": 0.0, "heading_degrees": 180.0},
  "route": [{"x": 0.0, "z": -100.0}],
  "arrival_radius": 12.0,
  "boundary_half_extent": 500.0,
  "obstacles": [
    {"name": "rock", "kind": "rock", "shape": "circle", "x": 50.0, "z": -40.0, "radius": 10.0},
    {"name": "pier", "kind": "pier", "shape": "box", "position": {"x": 80.0, "z": -20.0}, "size": {"x": 18.0, "z": 60.0}}
  ],
  "terrain": [
    {"name": "falling_cliff", "kind": "cliff", "shape": "circle", "x": -55.0, "z": -40.0, "radius": 16.0},
    {"name": "shoreline", "kind": "shoreline", "shape": "polygon", "points": [{"x": -100.0, "z": 20.0}, {"x": -50.0, "z": 20.0}, {"x": -50.0, "z": 80.0}]}
  ],
  "dynamic_obstacles": [
    {"name": "crossing_ferry", "kind": "traffic", "shape": "circle", "x": 10.0, "z": -60.0, "radius": 7.0, "course_degrees": 270.0, "speed_knots": 5.0}
  ],
  "sea_state": {"wind_speed_knots": 8.0, "current_speed_knots": 0.6, "current_direction_degrees": 90.0}
}
```

坐标单位是米，`x` 向东、`z` 向北。静态几何支持 `circle`、轴对齐 `box` 和 `polygon`。动态障碍可用 `course_degrees + speed_knots`，也可直接给 `velocity: {x, z}`（米/秒）。

`cliff`、`terrain`、`shoreline` 会在船体半径和通用障碍膨胀之外，再增加 `cliff_inflation_m`，用于表达悬岩、浅滩和岸线不能贴边通过。碰撞、地形碰撞、近失事件、最小净距、动态障碍数量均进入真实 episode 指标。

## 28 维观测与动作

观测按顺序包含：目标距离；航向误差正余弦；航速；油门；舵角；横向误差；最近障碍净距与方位正余弦；海流速度与相对方向正余弦；风速与相对方向正余弦；浪高与浪向正余弦；航点进度；最近目标闭合速度、TCPA、DCPA 与动态目标标识；边界净距；前、左舷、右舷三个扇区净距。所有分量归一化到 `[-1, 1]`。

PPO、SAC、TD3、LOS-PID 使用连续 `Box(-1, 1, shape=(2,))` 油门/舵角；DQN 使用相同控制量的 9 个离散组合。

## `ship_training_experiment_v3`

Godot 导出的训练配置分离保存：

- `rl_parameters`：优化器、采样、奖励和算法参数；
- `environment_parameters`：船体安全包络、悬岩净距、边界、传感器、碰撞终止和域随机化；
- `ships`：当前船舶动力学；
- `world`：当前 Godot 航线、海况、岩石、`落水悬岩` 和矩形障碍快照；
- `dataset`：绝对路径和明确的训练/测试 split。

训练 checkpoint 同时保存数据集 SHA-256 和实验配置 SHA-256。测试时任一指纹变化都会拒绝运行，必须重新训练，避免用不同安全半径或地形设置包装旧模型结果。

## 环境 GeoJSON 接入

AIS 轨迹不包含岸线、悬岩、礁石和码头几何。可将 WGS84 GeoJSON 与 AIS 一次性转换：

```bash
python3 tools/public_data_pipeline.py ais \
  --input /path/to/AccessAIS-export.zip \
  --origin-lat 33.73 --origin-lon -118.27 \
  --environment-geojson /path/to/port_environment.geojson \
  --dataset-output /path/to/port_training_dataset.json \
  --targets-output /path/to/ais_targets.json
```

GeoJSON `Point` 支持 `shape=circle|box`、`radius_m`、`width_m`、`length_m`；`Polygon`/`MultiPolygon` 转为训练多边形。属性 `category=terrain` 或 `kind=cliff|terrain|shoreline|land|reef|shoal` 会进入 `terrain`，其余进入 `obstacles`。转换器把 GeoJSON 文件名、SHA-256 和特征数写入数据来源元数据。

## 工程边界

更换符合本契约的数据集即可训练新的港口水域，不需要修改算法。但实港使用仍需从电子海图、测深或经核验的港区 GIS 生成地形 GeoJSON，并完成 COLREGs、潮汐水深、船型水动力、传感器标定和控制接口安全认证；本项目不能未经验证直接控制实船。
