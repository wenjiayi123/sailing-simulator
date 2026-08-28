# 执行控制闭环（研究模拟器）

该模块在不修改船舶运动模型和既有策略的前提下，为仿真船补充自动舵、推进指令、执行器反馈、控制权仲裁、看门狗、人工立即接管和急停锁存。

## 控制链

`RL/自动舵请求 → 控制权门禁 → 数值与序列校验 → 幅值限幅 → 斜率限幅 → 仿真船公开控制接口 → 目标回读/实际反馈 → 审计回执`

- 默认状态为人工直控和执行层未武装，避免静默改变既有策略行为。
- 强化学习使用版本化 `submit_rl_action(throttle, rudder, sequence)` 接口；现有策略没有被重接。
- 自动舵根据首向误差生成有界舵令，并根据目标航速生成有界推进指令。
- 指令超时、反馈丢失和执行器卡滞均有可见降级状态；watchdog 超时及反馈丢失会输出中性指令。
- 控制权优先级为急停、人工、远程控制中心、自动舵、强化学习。人工接管会停止活动回放控制器并立即归还直接操船权。
- 急停独立于普通控制请求进行软件锁存；必须人工确认复位，复位后仍需重新武装。

## 真实性边界

当前闭环实际驱动 Godot 仿真船，但没有连接物理自动舵、舵机反馈、主机/喷水推进控制器或船桥操纵系统。远程控制中心默认阻断，独立硬件急停也未验证：

- `physical_actuator_feedback_verified=false`
- `physical_emergency_stop_verified=false`
- `production_authority=false`

软件急停通过不代表独立双通道硬件急停通过；仿真执行器反馈也不能替代现场输入输出、掉电安全状态和见证测试。

## 验收

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-execution-control-smoke
.venv/bin/python -m unittest tests.test_execution_control -v
```

专项报告位于 `reports/godot_execution_control_smoke_v1.json`，包含运动模型、动力学参数、既有策略和模型文件测试前后的 SHA-256 哈希。
