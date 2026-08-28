# 强化学习安全策略效果论证

## 主体对象

该模拟器的核心对象是强化学习算法。本论证只以真实训练的 Soft Actor-Critic（SAC）策略为被测控制策略，LOS-PID、LQR 和 MPC 仅继续作为历史对照，不参与本项准入。

被测组合为 `sac_pure_20k+safety_v5`。SAC 检查点、权重、训练记录和原始失败回合全部保留；Safety V5 作为独立、可移除的动作约束层加入，不回写 SAC 权重，也不修改三自由度船舶运动模型。

## 两个结论不能混淆

1. 安全效果准入：判断安全层是否降低碰撞、搁浅和避碰规则代理违例，同时保持无碰撞到达、港口合规和 SAC 动作控制权。
2. 完整策略准入：判断 SAC 与安全层组合的绝对到达率、港口合规率、安全率、动作权威和延迟是否全部达到更严格门槛。

安全效果通过不自动等于完整策略通过。历史失败结论不会被覆盖。

## 跨场景流程

1. 使用 72 场历史自动识别系统验证场景确认安全效果。
2. 在读取新结果前，冻结 SAC 检查点、模型权重、安全配置、效果门槛和 72 场反事实压力留出集哈希。
3. 在留出集中使用相同种子逐场运行原始 SAC 和 SAC+Safety V5，形成可配对的回合证据。
4. 覆盖小型、中型、大型船舶，单目标、多目标交通，以及低浪、中浪条件。
5. 检查碰撞降低、到达与港口合规非劣、搁浅和避碰规则代理违例不恶化、危险监督干预预算、失效安全频率、计算延迟及 SAC 舵角/任一动作维度保留率。

## 运行

```bash
.venv/bin/python tools/audit_rl_safety_effectiveness_v1.py prepare
.venv/bin/python tools/audit_rl_safety_effectiveness_v1.py smoke
.venv/bin/python tools/audit_rl_safety_effectiveness_v1.py verify-smoke
```

功能建设阶段只运行上述两条命令：冻结接口和门槛，然后用少量 validation 回合验证真实 SAC 推理、安全投影、动作执行和审计回执。该阶段不访问最终反事实留出集，也不声称算法已经收敛或通过安全效果准入。

全部模拟器功能完成并统一训练后，再执行：

```bash
.venv/bin/python tools/audit_rl_safety_effectiveness_v1.py finalize
.venv/bin/python tools/audit_rl_safety_effectiveness_v1.py verify
```

功能烟雾报告为 `reports/rl_safety_effectiveness_smoke_v1.json`。最终机器可读报告为 `reports/rl_safety_effectiveness_v1.json`，逐回合配对证据位于 `reports/artifacts/rl_safety_effectiveness_v1/paired_episodes.json`。

## 边界

这是流程分离、跨场景的离线仿真证据。“流程分离”不等于已经完成独立第三方机构审查。报告不授予实船控制权，也不替代船级社认可、型式认可、硬件联锁见证或海试。
