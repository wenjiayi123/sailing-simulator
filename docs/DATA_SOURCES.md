# 数据来源与许可

## Open-Meteo 海况与天气

- 接口文档：https://open-meteo.com/en/docs/marine-weather-api
- 历史天气接口：https://open-meteo.com/en/docs/historical-weather-api
- 数据许可：CC BY 4.0，需要署名。
- 项目署名：`Weather data by Open-Meteo.com`；波浪产品包含 DWD 模型数据时同时保留 DWD 说明。
- 缓存文件：`data/public_cache/marine_weather_singapore.json`，内部保留请求 URL、位置、观测时间和抓取时间。

实时接口失败时，系统显示 `cache_fallback`，不会把缓存标成实时数据。点击场景天气预设或手动调参后，来源会显示为覆盖值。

### 长滩固定可靠性基准

`data/public/long_beach_open_meteo_2024_01_04_hourly.csv` 包含长滩邻近水域 2024-01-01 至 2024-04-30 的 2,904 个连续 UTC 小时。风来自历史天气再分析接口；浪高、浪向、周期和表层流来自海洋归档/模式接口。来源清单、原始请求 URL、抓取时间和许可写入同名 `.provenance.json`。

固定小时 CSV SHA-256：

```text
cdc9c9ddc22b0cd83cafb56a9cc4d46c6670bbb0280f0465a0c20533ed0e38bd
```

数据按日派生 121 个仿真场景，并按来源日期切分：

| Split | 日期 | 场景数 | 用途 |
|---|---|---:|---|
| train | 2024-01-01—2024-02-29 | 60 | 四种 RL 训练 |
| validation | 2024-03-01—2024-03-31 | 31 | 参数/模型验证，不生成可渲染测试证据 |
| test | 2024-04-01—2024-04-30 | 30 | 模型与配置冻结后的最终评估 |

这里的“公开数据”只覆盖环境强迫。航线模板、障碍、动态交通、船舶动力学和反事实动作响应均为项目仿真设定；`observed_ais=false`。Open-Meteo 也明确提示海流与潮汐等模式产品不适合沿海导航，因此不能将本基准描述为真实航行记录、实船控制效果或导航认证。

## NOAA/BOEM/USCG AccessAIS

- 数据目录：https://coast.noaa.gov/digitalcoast/data/vesseltraffic.html
- 下载工具：https://marinecadastre.gov/accessais/
- 提供方：NOAA Office for Coastal Management、Bureau of Ocean Energy Management、U.S. Coast Guard。

项目不把大型 AIS 原始文件提交到 Git。`tools/public_data_pipeline.py ais` 流式读取用户下载的 CSV/ZIP，保留原文件 SHA-256、目录链接和 MMSI 级切分。是否可以再次分发某个具体导出文件，应以下载时随附的元数据和条款为准。

AIS 只负责历史航迹，不提供岸线、悬岩、礁石或码头几何。`--environment-geojson` 可把用户提供的 WGS84 港区 GIS 特征投影到同一局部坐标系；转换结果会保存 GeoJSON 文件名、SHA-256 和特征数量。原始 GIS/电子海图的授权与精度仍由数据提供者负责。

### 长滩 AIS + ENC 港口基准 v2

`data/rl/long_beach_ais_port_ops_benchmark_v2.json` 是更大、现实因素更完整的比较基准：

- NOAA 2025-01-01 至 2025-01-07 全国日级 AccessAIS 压缩档。构建器流式解压并只保留长滩港边界内记录；七个原档不提交 Git，官方 URL、字节数和 SHA-256 写入 `data/public/long_beach_ais_2025_w01.provenance.json`。
- NOAA ENC Direct to GIS 港区派生几何：岸线、岸工、障碍、沉船、航道、限制/警戒区、TSS 航道和水深区。紧凑归一化结果保存在 `data/public/long_beach_noaa_enc_harbour_v1.json`。
- Open-Meteo 同期逐小时风、能见度、浪、流和模式海平面，保存在 `data/public/long_beach_open_meteo_2025_w01_hourly.csv`。
- 任务来自真实 AIS 航迹分段，保留 MMSI 级来源、时间戳、船型、船长、船宽、吃水、实测航速和邻近动态交通快照。切分严格按日期前后，不随机打散。

固定构建结果为 85,435 条港区 AIS 运动记录、137 个任务内唯一 MMSI、409 个航迹任务、2,280 个航迹点和 646 个动态目标实例。任务按来源时间切分为 207 train、72 validation、130 test；船型尺寸、吃水、风浪流、能见度、潮位和速度代理字段覆盖率均为 100%。共享 ENC 派生层包含 11 个地形、50 个固定障碍、32 个水深区、12 个航道、3 个限制区和 1 个 TSS 几何。

NOAA AccessAIS 是历史 NAIS 派生数据，不是实时船舶交通。ENC Direct 是 NOAA ENC 的 GIS 派生服务，不是经认证的船上导航产品。Open-Meteo 明确提示其海洋模式不适合沿海导航。数据包适用于离线研究训练与可复核评测；`live_control_ready=false`。

长滩/洛杉矶港群的 VTS、引航、拖轮、无线电、泊位和地方规则只作为来源明确的部署检查项。模型目前只实现保守 COLREG 会遇代理、历史交通回放、航道/警戒区几何、UKC 和经验航速上限；未把参考规则伪装成可执行控制许可。详见 [港口替换与上线门禁](PORT_ADAPTER_GUIDE.md)。

## 项目原生默认基准

`data/rl/default_port_dataset.json` 是项目自带的数值 smoke fixture，`source.observed_ais=false`，不声称是实测 AIS 或官方港口电子海图。它包含项目原生的圆形、矩形、多边形地形和动态交通任务，仅用于安装后快速验证算法链路。正式可靠性数字应引用上面的固定公开海况基准；港口研究则应换成来源明确的港口数据集。

`data/ports/default_port_profile.json` 同样是项目原生场景几何，负责离线演示与回退，不冒充真实港口测绘数据。
