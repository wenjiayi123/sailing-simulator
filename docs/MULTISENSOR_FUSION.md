# 多源传感闭环（研究模拟器）

本模块面向强化学习航行模拟器，提供雷达、自动识别系统（AIS）、光电（EO）、红外（IR）、全球卫星导航系统（GNSS）和惯性导航系统（INS）六类独立观测通道。它不会修改船舶运动模型、执行器或任何既有策略。

## 已实现

- 统一传感数据包：测量时间、接收时间、延迟、坐标系、来源身份、来源模式、质量、完整性、标定引用和硬件验证状态。
- 独立通道：雷达目标量测、AIS 身份/运动报告、EO/IR 目标探测、GNSS 位置和 INS 位置/首向/速度。
- 融合状态：GNSS/INS 组合导航、跨模态最近邻目标关联、来源链、置信度、确认/未确认目标和决策输入门禁。
- 故障注入：雷达掉线/误报、AIS 掉线/延迟/身份欺骗、EO 掉线/遮挡、IR 掉线/误报、GNSS 掉线/延迟/位置欺骗、INS 掉线/首向偏差和时钟失步。
- 失效降级：GNSS 欺骗时使用 INS 航位推算并报警；GNSS 与 INS 同时失效时阻断决策输入。
- 船桥面板：按 `K` 打开，可查看六通道健康、组合导航差异、融合目标来源、强化学习观测出口和审计回执，并可注入典型故障。

## 强化学习边界

融合快照已经提供版本化观测出口，但 `wired_to_existing_policy=false`。当前策略和运动模型保持冻结；以后统一训练时，应增加新的观测适配器和版本号，再训练/验证兼容策略，不能把新维度静默塞给旧策略。

## 真实性边界

当前通道来自 Godot 场景真值生成的声明式传感器仿真，以及既有历史 AIS 回放。物理传感接入默认拒绝，且下列状态保持为假：

- `real_sensor_data_verified=false`
- `physical_sensor_calibration_verified=false`
- `production_authority=false`

只有在现场提供设备身份、单调时间戳、时钟同步、标定记录、原始数据、遮挡/误报/延迟/欺骗测试和独立见证材料后，才能另行开放外部接入并评估真实性；软件模拟通过不等于实传感验证。

## 验收

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-multisensor-fusion-smoke
.venv/bin/python -m unittest tests.test_multisensor_fusion -v
```

专项报告写入 `reports/godot_multisensor_fusion_smoke_v1.json`，并包含既有策略/模型文件测试前后的 SHA-256 哈希。
