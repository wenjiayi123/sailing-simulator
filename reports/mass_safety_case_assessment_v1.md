# RL 航行模拟器安全案例评估 V1

**功能安全案例：** `PASS`

**外部准入状态：** `FUNCTIONAL_SAFETY_CASE_COMPLETE_EXTERNAL_ACCEPTANCE_BLOCKED`

本报告把运行设计域、危险日志、控制措施、最小风险状态、故障树、远程控制中心、人员责任、法规适用性路由和证据注册表连接为可机读安全案例。通过只适用于模拟器研究功能，不是主管机关、船级或型式认可结论。

| 安全案例模块 | 结果 | 数量/状态 |
|---|---:|---|
| 运行设计域 | PASS | 12 个维度 |
| 危险日志与控制 | PASS | 12 项危险 / 24 项控制 |
| 最小风险状态 | PASS | 6 项 |
| 故障树 | PASS | 5 棵，覆盖全部危险 |
| 远程控制中心合同 | PASS | 现场授权 false |
| 人员责任矩阵 | PASS | 9 角色 / 7 项职责 |
| 法规适用性路由 | PASS | 5 类，均待外部决定 |
| 证据注册表 | PASS | 10 项哈希绑定证据 |
| 运行时 ODD 越界映射 | PASS | 12 个越界案例均映射 MRC |

## 外部证据缺口

当前清单缺失 40 项现场、责任、法规决定、独立审查和支持证据。前十项为：

- `deployment.vessel_name`
- `deployment.official_number_or_mmsi`
- `deployment.flag_state`
- `deployment.operating_area`
- `deployment.operator_organization`
- `deployment.rcc_site`
- `deployment.approved_odd_reference`
- `deployment.configuration_baseline_reference`
- `deployment.change_control_record_reference`
- `regulatory_determinations.COLREG`

## 强制状态

- `independent_review_complete=false`
- `flag_state_approval=false`
- `coastal_state_approval=false`
- `class_approval=false`
- `type_approval=false`
- `mass_safety_certificate=false`
- `sea_trial_completed=false`
- `production_authority=false`

## 复现

```bash
.venv/bin/python tools/run_mass_safety_case.py verify
.venv/bin/python -m unittest tests.test_mass_safety_case -v
```
