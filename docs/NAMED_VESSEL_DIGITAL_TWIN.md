# 指定船舶数字孪生校准工作流

本工作流在不修改当前三自由度船舶模型及既有策略的前提下，补齐指定船舶数据采集合同、操纵性试验解析、参数辨识、冻结模型重放、逐试验误差和跨装载工况误差包络。

## 必需实船试验

- 左、右回转圈；
- 10°/10° 与 20°/20° Z 字试验；
- 全速前进至停船；
- 加速和减速试验；
- `lightship`、`design_payload`、`maximum_operating` 三种装载工况，每种至少两项有效试验。

原始 CSV 必须包含单调时间戳、东/北位置、首向、纵荡/横荡速度、艏摇角速度、推进与转向指令、实测转向角，以及可选的流、风、浪和环境力矩。配套清单还要求船舶身份、排水量/重心/吃水、GNSS/INS 与指令记录器身份、时钟同步、传感与执行器标定、天气海况、操作者、见证人和原始文件 SHA-256。

## 计算结果

- 回转进距、横距、战术直径和 180° 完成状态；
- Z 字操舵反转次数和首向超越峰值；
- 停船时间和停船距离；
- 加减速 90% 响应时间；
- 纵向一阶响应与 Nomoto 一阶模型辨识；
- 位置、首向、纵向速度和艏摇角速度的 RMSE、P95 与最大误差；
- 逐试验、逐装载工况和跨试验误差包络。

## 严格边界

当前报告状态是 `BLOCKED_NAMED_VESSEL_EVIDENCE_INCOMPLETE`。软件冒烟覆盖全部七类试验和三个装载标签，但数据由冻结模型生成，只证明读取、重放、指标计算和辨识功能，不能证明指定船舶校准。

即使实船证据齐全并满足阈值，工具也只输出 `CALIBRATION_CANDIDATE_READY_FOR_INDEPENDENT_ACCEPTANCE`：

- 不自动写回动力学参数；
- `named_vessel_dynamics_calibrated=false`；
- `production_authority=false`；
- 必须经过独立审查、见证试验和用户批准，才能另行产生版本化参数候选。

## 使用

```bash
make named-vessel-twin-readiness
make named-vessel-twin-smoke
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-named-vessel-twin-smoke
```

模拟器内按 `G` 打开数字孪生校准面板；“导出实船证据模板”会把清单和 CSV 模板复制到 `user://named_vessel_twin_evidence/`。
