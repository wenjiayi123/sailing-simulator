# 船舶网络安全功能可信度报告 V1

**功能状态：** `FUNCTIONAL_CYBER_CONTROLS_COMPLETE_EXTERNAL_SECURITY_ASSURANCE_BLOCKED`

本层面向强化学习航行模拟器，提供离线船桥网络安全训练与控制验证。它不会转发网络报文到执行器，也不会修改船舶运动模型、观测空间、动作空间、奖励函数或任何既有策略。

| 项目 | 当前证据 |
|---|---:|
| 网络安全分区 | 7/7 |
| 许可数据流 | 8/8 |
| Godot 运行验收 | 61/61 |
| 软件启动哈希清单 | 7 文件 |
| 既有策略哈希 | 10/10 |
| 功能控制层 | PASS |
| 生产网络安全认可 | BLOCKED |

## 已实现

- 七区默认拒绝网络策略、八条显式许可流、禁止外部交换区直接控制安全关键区。
- 四类训练身份、角色权限、会话时限、三次失败锁定和随机数重放检测。
- RSA PKCS#1 v1.5 / SHA-256 离线签名更新验证；合法包只进入隔离区，不安装；篡改包被阻断并告警；私钥不在仓库。
- 七文件软件哈希启动清单；明确不是硬件安全启动、可信平台模块或度量启动证据。
- 八类入侵检测规则、SHA-256 链式审计、告警确认、人工确认恢复点。
- 八类攻击用例：错误口令、重放、越权、越区直控、篡改更新、启动哈希异常、审计篡改、未确认恢复。

## 强制阻断

- `production_network_segmentation_verified=false`
- `hardware_secure_boot_verified=false`
- `production_signed_update_verified=false`
- `production_ids_verified=false`
- `disaster_recovery_field_verified=false`
- `independent_penetration_test_completed=false`
- `class_or_flag_cyber_approval=false`
- `production_authority=false`

外部证据模板当前为 `BLOCKED_EXTERNAL_CYBERSECURITY_EVIDENCE_INCOMPLETE`。生产网络实建图、身份源和多因素认证、硬件信任根、签名密钥仪式、安全运营中心链路、离线备份/裸机恢复、恢复时间目标/恢复点目标、独立渗透测试复测及船旗国或船级社决定必须由外部主体提交并逐文件校验；项目自身声明不能解锁。

## 复现

```bash
make GODOT="/Applications/Godot.app/Contents/MacOS/Godot" godot-bridge-cybersecurity-smoke
.venv/bin/python tools/run_maritime_cybersecurity_assurance.py verify
.venv/bin/python -m unittest tests.test_maritime_cybersecurity -v
```
