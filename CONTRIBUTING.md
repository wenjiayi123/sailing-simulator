# 贡献指南

## 开发环境

```bash
bash tools/setup_rl_env.sh
.venv/bin/python -m unittest tests.test_ship_rl -v
```

Godot 改动还应运行：

```bash
/path/to/Godot --headless --path /path/to/sailing-simulator --quit-after 8
```

## 算法与数据要求

- 新算法必须使用同一 `ship_port_dataset_v2`、21 维观测、动作和评估契约。
- 训练只得读取 `train`；模型选择可读取 `validation`；最终报告才读取 `test`。
- 不接受写死进度、预制成功轨迹、在测试阶段修改失败结果，或把场景预设冒充观测数据。
- 数据转换必须保留来源 URL、抓取/观测时间、许可说明、坐标系和原始文件 SHA-256。
- AIS 航次不得跨 train/validation/test split，避免轨迹泄漏。
- 港区训练必须提供可审计的地形/障碍来源；GeoJSON 转换需保留文件 SHA-256。不得把 AIS 航迹误称为电子海图或岸线数据。
- 环境参数变化会改变实验指纹；不得绕过检查点指纹校验复用旧测试结果。

## 界面真实性

新面板必须在字段或状态中明确区分：

- 实时观测；
- 带时间戳缓存；
- 数值模型估算；
- 人工场景注入；
- 不可用或未接入。

如果没有实体传感器或校准模型，界面应显示 `N/A`，不得用动画或常量伪造数值。

## 素材与许可

请勿提交来源不明的图片、音频、字体、模型或数据。第三方内容必须同时提交作者、原始链接、许可证和必要署名，并同步更新 `docs/ASSET_LICENSE_AUDIT.md` 与 `docs/THIRD_PARTY_ASSETS.md`。
