# 数据来源与许可

## Open-Meteo 海况与天气

- 接口文档：https://open-meteo.com/en/docs/marine-weather-api
- 数据许可：CC BY 4.0，需要署名。
- 项目署名：`Weather data by Open-Meteo.com`；波浪产品包含 DWD 模型数据时同时保留 DWD 说明。
- 缓存文件：`data/public_cache/marine_weather_singapore.json`，内部保留请求 URL、位置、观测时间和抓取时间。

实时接口失败时，系统显示 `cache_fallback`，不会把缓存标成实时数据。点击场景天气预设或手动调参后，来源会显示为覆盖值。

## NOAA/BOEM/USCG AccessAIS

- 数据目录：https://coast.noaa.gov/digitalcoast/data/vesseltraffic.html
- 下载工具：https://marinecadastre.gov/accessais/
- 提供方：NOAA Office for Coastal Management、Bureau of Ocean Energy Management、U.S. Coast Guard。

项目不把大型 AIS 原始文件提交到 Git。`tools/public_data_pipeline.py ais` 流式读取用户下载的 CSV/ZIP，保留原文件 SHA-256、目录链接和 MMSI 级切分。是否可以再次分发某个具体导出文件，应以下载时随附的元数据和条款为准。

AIS 只负责历史航迹，不提供岸线、悬岩、礁石或码头几何。`--environment-geojson` 可把用户提供的 WGS84 港区 GIS 特征投影到同一局部坐标系；转换结果会保存 GeoJSON 文件名、SHA-256 和特征数量。原始 GIS/电子海图的授权与精度仍由数据提供者负责。

## 项目原生默认基准

`data/rl/default_port_dataset.json` 是项目自带的数值基准，`source.observed_ais=false`，不声称是实测 AIS 或官方港口电子海图。它包含项目原生的圆形、矩形、多边形地形和动态交通任务，仅用于安装后验证算法链路。生产实验应换成来源明确的港口数据集。

`data/ports/default_port_profile.json` 同样是项目原生场景几何，负责离线演示与回退，不冒充真实港口测绘数据。
